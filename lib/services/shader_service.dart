import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/shader_preset.dart';
import '../mpv/player/player.dart';
import '../utils/app_logger.dart';
import 'ambient_lighting_service.dart';
import 'shader_asset_loader.dart';
import 'shader_chain_coordinator.dart';

/// Service for applying GLSL shaders to the MPV video player.
///
/// Handles shader chain building, HDR detection, and runtime switching.
/// When ambient lighting is active, the ambient lighting shader is always appended last
/// in the chain after any upscaling/processing shaders.
class ShaderService {
  final Player _player;

  /// The preset in mpv's chain. Differs from [_requestedPreset] only while
  /// NVScaler is auto-skipped on HDR content.
  ShaderPreset _currentPreset = ShaderPreset.none;

  /// The preset the caller last asked for; what [reapplyForContent]
  /// re-decides against the picture mpv actually presents.
  ShaderPreset _requestedPreset = ShaderPreset.none;
  final List<String> _appliedPaths = [];
  Future<T> _enqueue<T>(Future<T> Function() operation) => ShaderChainCoordinator.forPlayer(_player).run(operation);

  /// Reference to ambient lighting service for re-appending its shader after chain rebuilds.
  AmbientLightingService? ambientLightingService;

  ShaderService(this._player);

  static final Expando<ShaderService> _services = Expando<ShaderService>();
  static ShaderService forPlayer(Player player) => _services[player] ??= ShaderService(player);

  String? _colorPath;
  _GeneratedShaders? _colorFiles;
  _GeneratedShaders? _presetFiles;
  int _saturation = 0;
  int _hue = 0;

  Future<void> setColorControl(String property, int value) => _enqueue(() async {
    final saturation = property == 'saturation' ? value : _saturation;
    final hue = property == 'hue' ? value : _hue;
    await _setColorEqualizer(saturation, hue);
  });

  Future<void> setColorEqualizer({required int saturation, required int hue}) =>
      _enqueue(() => _setColorEqualizer(saturation, hue));

  Future<void> _setColorEqualizer(int saturation, int hue) async {
    saturation = saturation.clamp(-100, 100);
    hue = hue.clamp(-100, 100);
    final coordinator = ShaderChainCoordinator.forPlayer(_player);
    coordinator.ensureCertain();
    String? next;
    _GeneratedShaders? staged;
    try {
      if (saturation != 0 || hue != 0) {
        final root = await getTemporaryDirectory();
        final dir = await root.createTemp('plezy-color-');
        staged = _GeneratedShaders(dir);
        final file = staged.file('color.glsl');
        await file.writeAsString('''
//!HOOK MAIN
//!BIND HOOKED
vec4 hook() {
  vec4 c = HOOKED_tex(HOOKED_pos);
  float y = dot(c.rgb, vec3(0.299, 0.587, 0.114));
  float i = dot(c.rgb, vec3(0.596, -0.274, -0.322));
  float q = dot(c.rgb, vec3(0.211, -0.523, 0.312));
  float angle = 3.14159265 * ${hue.toDouble()} / 100.0;
  float s = 1.0 + ${saturation.toDouble()} / 100.0;
  float ii = (i * cos(angle) - q * sin(angle)) * s;
  float qq = (i * sin(angle) + q * cos(angle)) * s;
  return vec4(y + 0.956 * ii + 0.621 * qq, y - 0.272 * ii - 0.647 * qq, y - 1.106 * ii + 1.703 * qq, c.a);
}
''');
        next = file.path;
      }
    } catch (_) {
      await staged?.delete();
      rethrow;
    }
    final ambient = ambientLightingService?.activeShaderPath;
    try {
      await coordinator.replace(remove: [?_colorPath, ?ambient], add: [?next, ?ambient]);
    } catch (_) {
      coordinator.quarantine();
      rethrow;
    }
    final oldFiles = _colorFiles;
    _colorFiles = staged;
    _colorPath = next;
    _saturation = saturation;
    _hue = hue;
    await oldFiles?.delete();
  }

  /// The preset applied to the chain — none while NVScaler is auto-skipped.
  ShaderPreset get currentPreset => _currentPreset;

  /// Check if the player is MPV (shaders are MPV-only)
  bool get isSupported => _player.playerType == 'mpv';

  /// Apply a shader preset to the video player.
  ///
  /// For NVScaler with auto-HDR skip enabled, will check video colorspace
  /// and skip shader application for HDR content. That check reads the
  /// decoded picture, so a call before the item's first frame (the start
  /// flow, an in-place swap) decides on stale or absent params;
  /// [reapplyForContent] settles it once a frame exists.
  Future<void> applyPreset(ShaderPreset preset) => _enqueue(() => _applyPreset(preset));

  Future<void> _applyPreset(ShaderPreset preset) async {
    if (!isSupported) {
      appLogger.d('ShaderService: Shaders not supported on ${_player.playerType}');
      return;
    }

    try {
      if (_skipsOnHdr(preset) && await _isHdrContent()) {
        appLogger.d('ShaderService: Skipping NVScaler on HDR content');
        await _applyChain(ShaderPreset.none);
        _requestedPreset = preset;
        return;
      }
      await _applyChain(preset);
      _requestedPreset = preset;
    } catch (e, st) {
      appLogger.w('ShaderService: Failed to apply preset', error: e, stackTrace: st);
      // Don't rethrow - shader failure shouldn't stop playback
    }
  }

  /// Re-decide the requested preset against the picture now decoded. Only
  /// an HDR-skipping NVScaler request depends on the content; anything else
  /// is a no-op. Returns whether the applied preset changed.
  Future<bool> reapplyForContent() => _enqueue(_reapplyForContent);

  Future<bool> _reapplyForContent() async {
    final requested = _requestedPreset;
    if (!isSupported || !_skipsOnHdr(requested)) return false;

    try {
      final target = await _isHdrContent() ? ShaderPreset.none : requested;
      if (target == _currentPreset) return false;
      appLogger.d(
        target.isEnabled
            ? 'ShaderService: Applying ${requested.name}, content is SDR'
            : 'ShaderService: Skipping ${requested.name} on HDR content',
      );
      await _applyChain(target);
      return true;
    } catch (e, st) {
      appLogger.w('ShaderService: Failed to re-apply preset for content', error: e, stackTrace: st);
      return false;
    }
  }

  static bool _skipsOnHdr(ShaderPreset preset) =>
      preset.type == ShaderPresetType.nvscaler && preset.nvscalerConfig?.autoHdrSkip == true;

  /// Replace only this service's shaders; other chain owners must survive.
  Future<void> _applyChain(ShaderPreset preset) async {
    final coordinator = ShaderChainCoordinator.forPlayer(_player);
    coordinator.ensureCertain();
    var shaderPaths = await ShaderAssetLoader.getShadersForPreset(preset);
    _GeneratedShaders? staged;
    // Each Anime4K pass needs its own identity: some modes intentionally use
    // the same file twice, and consecutive modes share source files.
    try {
      if (preset.type == ShaderPresetType.anime4k && shaderPaths.isNotEmpty) {
        final root = await getTemporaryDirectory();
        final dir = await root.createTemp('plezy-anime4k-');
        staged = _GeneratedShaders(dir);
        final aliases = <String>[];
        for (var i = 0; i < shaderPaths.length; i++) {
          final target = staged.file('$i.glsl');
          await File(shaderPaths[i]).copy(target.path);
          aliases.add(target.path);
        }
        shaderPaths = aliases;
      }
    } catch (_) {
      await staged?.delete();
      rethrow;
    }

    final ambient = ambientLightingService?.activeShaderPath;
    try {
      await coordinator.replace(
        remove: [..._appliedPaths, ?_colorPath, ?ambient],
        add: [...shaderPaths, ?_colorPath, ?ambient],
      );
    } catch (_) {
      coordinator.quarantine();
      rethrow;
    }
    final oldFiles = _presetFiles;
    _presetFiles = staged;
    _appliedPaths
      ..clear()
      ..addAll(shaderPaths);
    _currentPreset = preset;
    await oldFiles?.delete();
    if (shaderPaths.isNotEmpty) {
      appLogger.d('ShaderService: Applied ${preset.name} with ${shaderPaths.length} shaders');
    }
  }

  /// Check if the current video content is HDR.
  Future<bool> _isHdrContent() async {
    try {
      // Check video color matrix for BT.2020 (HDR indicator)
      final colormatrix = await _player.getProperty('video-params/colormatrix');
      if (colormatrix?.contains('bt.2020') == true) {
        return true;
      }

      // Also check color primaries
      final primaries = await _player.getProperty('video-params/primaries');
      if (primaries?.contains('bt.2020') == true) {
        return true;
      }

      // Check for HDR transfer characteristics
      final gamma = await _player.getProperty('video-params/gamma');
      if (gamma?.contains('pq') == true || gamma?.contains('hlg') == true) {
        return true;
      }

      return false;
    } catch (e) {
      appLogger.d('ShaderService: HDR detection failed', error: e);
      return false;
    }
  }

  Future<void> disable() async {
    await applyPreset(ShaderPreset.none);
  }
}

/// Records only paths created by this operation. Never enumerate a directory
/// or delete recursively: another actor may have placed files inside it.
class _GeneratedShaders {
  _GeneratedShaders(this.directory);
  final Directory directory;
  final List<File> _files = [];

  File file(String name) {
    final result = File('${directory.path}/$name');
    _files.add(result);
    return result;
  }

  Future<void> delete() async {
    for (final file in _files) {
      try {
        await file.delete();
      } on FileSystemException catch (e) {
        appLogger.d('Could not remove generated shader', error: e);
      }
    }
    try {
      await directory.delete();
    } on FileSystemException catch (e) {
      appLogger.d('Could not remove generated shader directory', error: e);
    }
  }
}
