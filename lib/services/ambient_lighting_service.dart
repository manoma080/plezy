import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

import '../mpv/player/player.dart';
import '../utils/app_logger.dart';
import 'shader_chain_coordinator.dart';

/// Generates and manages an ambient lighting GLSL shader that fills letterbox/pillarbox
/// bars with a blurred, dimmed version of the video edges.
///
/// `keepaspect=no` makes mpv scale the frame to the whole window; the shader
/// then composites the sharp picture, centered at its own aspect, over a
/// blurred background. It reads mpv's `input_size` (the picture) and
/// `target_size` (the rect mpv scales into — here the window) every frame, so
/// neither a resize nor an in-place item swap needs a write for the fill.
///
/// The fill deliberately avoids `video-aspect-override`, which stretches the
/// same way but rewrites the picture's aspect in mpv's video params: every
/// `dwidth`/`dheight` read — the next item's subtitle placement, PiP — then
/// answered the window's aspect instead of the picture's (#2447).
///
/// mpv places subtitles against the displayed video rect, which the fill turns
/// into the whole window; `sub-video-rect-aspect` (a Plezy mpv patch) hands it
/// the picture's real aspect so corner-anchored ASS events and PGS bitmaps stay
/// on the picture the shader composites (#2120).
///
/// On Apple (vo=avfoundation) `keepaspect=no` stretches only the shaded output
/// over the display layer: a frame the VO presents without shaders (Dolby
/// Vision, for one) stays letterboxed rather than stretched.
class AmbientLightingService {
  final Player _player;
  String? _shaderPath;
  bool _enabled = false;

  /// Brightness multiplier for the blurred background (0.0-1.0).
  static const double _brightness = 0.5;

  AmbientLightingService(this._player);

  bool get isEnabled => _enabled;

  bool get isSupported => _player.playerType == 'mpv';

  /// The committed ambient path, used when composing the complete chain.
  String? get activeShaderPath => _enabled ? _shaderPath : null;

  Future<void> enable(double videoAspect) => ShaderChainCoordinator.forPlayer(_player).run(() async {
    if (!isSupported) return;
    if (_enabled) {
      await _updateVideoAspect(videoAspect);
      return;
    }
    final coordinator = ShaderChainCoordinator.forPlayer(_player);
    var shaderInstalled = false;
    var subtitleChanged = false;
    var fillAttempted = false;
    String? oldSubtitleAspect;
    try {
      oldSubtitleAspect = await _player.getProperty('sub-video-rect-aspect');
      _shaderPath ??= await _writeShaderToTemp(_generateShader());
      await _player.setProperty('sub-video-rect-aspect', videoAspect.toString());
      subtitleChanged = true;
      await coordinator.replace(remove: const [], add: [_shaderPath!]);
      shaderInstalled = true;
      fillAttempted = true;
      await _player.setProperty('keepaspect', 'no');
      _enabled = true;
    } catch (e, st) {
      // A failed property write may already have taken effect. Restore the
      // safe aspect independently of shader cleanup, which may also fail.
      if (fillAttempted) {
        try {
          await _player.setProperty('keepaspect', 'yes');
        } catch (rollback, stack) {
          appLogger.w('AmbientLightingService: Aspect rollback failed', error: rollback, stackTrace: stack);
        }
      }
      try {
        if (shaderInstalled) await coordinator.replace(remove: [_shaderPath!], add: const []);
      } catch (rollback, stack) {
        appLogger.w('AmbientLightingService: Shader rollback failed', error: rollback, stackTrace: stack);
      }
      try {
        if (subtitleChanged) await _player.setProperty('sub-video-rect-aspect', oldSubtitleAspect ?? 'no');
      } catch (rollback, stack) {
        appLogger.w('AmbientLightingService: Subtitle rollback failed', error: rollback, stackTrace: stack);
      }
      appLogger.w('AmbientLightingService: Failed to enable', error: e, stackTrace: st);
    }
  });

  Future<void> disable() => ShaderChainCoordinator.forPlayer(_player).run(() async {
    if (!_enabled) return;
    final coordinator = ShaderChainCoordinator.forPlayer(_player);
    var letterboxed = false;
    var shaderRemoved = false;
    try {
      await _player.setProperty('keepaspect', 'yes');
      letterboxed = true;
      await coordinator.replace(remove: [_shaderPath!], add: const []);
      shaderRemoved = true;
      await _player.setProperty('sub-video-rect-aspect', 'no');
      _enabled = false;
    } catch (e, st) {
      try {
        if (shaderRemoved) await coordinator.replace(remove: const [], add: [_shaderPath!]);
        if (letterboxed) await _player.setProperty('keepaspect', 'no');
      } catch (rollback, stack) {
        appLogger.w('AmbientLightingService: Disable rollback failed', error: rollback, stackTrace: stack);
      }
      appLogger.w('AmbientLightingService: Failed to disable', error: e, stackTrace: st);
    }
  });

  Future<void> updateVideoAspect(double videoAspect) =>
      ShaderChainCoordinator.forPlayer(_player).run(() => _updateVideoAspect(videoAspect));

  Future<void> _updateVideoAspect(double videoAspect) async {
    if (!_enabled) return;
    try {
      await _player.setProperty('sub-video-rect-aspect', videoAspect.toString());
    } catch (error, stackTrace) {
      appLogger.w('AmbientLightingService: Failed to update video aspect', error: error, stackTrace: stackTrace);
    }
  }

  /// Generate a static multi-pass GLSL shader.
  ///
  /// Uses MPV's built-in `input_size` (video dimensions) and `target_size`
  /// (output dimensions) uniforms which update automatically on resize.
  /// No baked-in aspect constants — fully adaptive.
  ///
  /// Pipeline (all MAIN hooks):
  /// 1. Save original video as ORIGINAL
  /// 2. Downscale to 1/8 as SMALL (center 60% zoom)
  /// 3-5. Three Kawase blur passes at 1/8 -> BLUR8C
  /// 6. Downscale BLUR8C to 1/64 as TINY
  /// 7-8. Two more Kawase blur passes at 1/64 -> GLOW
  /// 9. Composite: video rect -> ORIGINAL, bars -> GLOW
  String _generateShader() {
    final br = _brightness.toStringAsFixed(2);
    final buf = StringBuffer();

    // Pass 1: Save original video
    buf.writeln('//!HOOK MAIN');
    buf.writeln('//!BIND HOOKED');
    buf.writeln('//!SAVE ORIGINAL');
    buf.writeln('//!DESC Ambient Lighting Save');
    buf.writeln('vec4 hook() {');
    buf.writeln('    return HOOKED_tex(HOOKED_pos);');
    buf.writeln('}');
    buf.writeln();

    // Pass 2: Downscale to 1/8 with center zoom.
    buf.writeln('//!HOOK MAIN');
    buf.writeln('//!BIND ORIGINAL');
    buf.writeln('//!SAVE SMALL');
    buf.writeln('//!WIDTH ORIGINAL.w 8 /');
    buf.writeln('//!HEIGHT ORIGINAL.h 8 /');
    buf.writeln('//!DESC Ambient Lighting Downscale');
    buf.writeln('vec4 hook() {');
    buf.writeln('    vec2 uv = ORIGINAL_pos * 0.6 + 0.2;');
    buf.writeln('    return ORIGINAL_tex(uv);');
    buf.writeln('}');
    buf.writeln();

    // Pass 3-5: Three Kawase blur passes at 1/8 resolution.
    const blur8Steps = [
      ('SMALL', 'BLUR8A', '2.0', 'Blur1'),
      ('BLUR8A', 'BLUR8B', '6.0', 'Blur2'),
      ('BLUR8B', 'BLUR8C', '12.0', 'Blur3'),
    ];
    for (final step in blur8Steps) {
      _writeKawasePass(buf, step.$1, step.$2, step.$3, step.$4);
    }

    // Pass 6: Downscale the already-blurred 1/8 texture to 1/64.
    buf.writeln('//!HOOK MAIN');
    buf.writeln('//!BIND BLUR8C');
    buf.writeln('//!SAVE TINY');
    buf.writeln('//!WIDTH BLUR8C.w 8 /');
    buf.writeln('//!HEIGHT BLUR8C.h 8 /');
    buf.writeln('//!DESC Ambient Lighting Downscale2');
    buf.writeln('vec4 hook() {');
    buf.writeln('    return BLUR8C_tex(BLUR8C_pos);');
    buf.writeln('}');
    buf.writeln();

    // Pass 7-8: Two more Kawase blur passes at 1/64 for maximum diffusion.
    const blur64Steps = [('TINY', 'GLOW1', '3.0', 'Blur4'), ('GLOW1', 'GLOW', '6.0', 'Blur5')];
    for (final step in blur64Steps) {
      _writeKawasePass(buf, step.$1, step.$2, step.$3, step.$4);
    }

    // Pass 9: Composite — no //!SAVE so this replaces MAIN.
    // Uses built-in input_size (video coded dims) and target_size (output dims)
    // to dynamically compute where the video rect sits. These auto-update on resize.
    buf.writeln('//!HOOK MAIN');
    buf.writeln('//!BIND ORIGINAL');
    buf.writeln('//!BIND GLOW');
    buf.writeln('//!DESC Ambient Lighting Composite');
    buf.writeln('vec4 hook() {');
    buf.writeln('    float vid_aspect = input_size.x / input_size.y;');
    buf.writeln('    float out_aspect = target_size.x / target_size.y;');
    buf.writeln();
    buf.writeln('    vec2 scale, off;');
    buf.writeln('    if (vid_aspect > out_aspect) {');
    buf.writeln('        float s = out_aspect / vid_aspect;');
    buf.writeln('        scale = vec2(1.0, s);');
    buf.writeln('        off = vec2(0.0, (1.0 - s) * 0.5);');
    buf.writeln('    } else {');
    buf.writeln('        float s = vid_aspect / out_aspect;');
    buf.writeln('        scale = vec2(s, 1.0);');
    buf.writeln('        off = vec2((1.0 - s) * 0.5, 0.0);');
    buf.writeln('    }');
    buf.writeln();
    buf.writeln('    vec2 vid_pos = (ORIGINAL_pos - off) / scale;');
    buf.writeln();
    buf.writeln('    if (all(greaterThanEqual(vid_pos, vec2(0.0))) &&');
    buf.writeln('        all(lessThanEqual(vid_pos, vec2(1.0)))) {');
    buf.writeln('        return ORIGINAL_tex(vid_pos);');
    buf.writeln('    }');
    buf.writeln();
    buf.writeln('    return GLOW_tex(ORIGINAL_pos) * $br;');
    buf.writeln('}');

    return buf.toString();
  }

  void _writeKawasePass(StringBuffer buf, String input, String output, String offset, String desc) {
    buf.writeln('//!HOOK MAIN');
    buf.writeln('//!BIND $input');
    buf.writeln('//!SAVE $output');
    buf.writeln('//!WIDTH $input.w');
    buf.writeln('//!HEIGHT $input.h');
    buf.writeln('//!DESC Ambient Lighting $desc');
    buf.writeln('vec4 hook() {');
    buf.writeln('    vec2 ps = ${input}_pt;');
    buf.writeln('    vec4 s = ${input}_tex(${input}_pos + vec2( $offset,  $offset) * ps)');
    buf.writeln('           + ${input}_tex(${input}_pos + vec2( $offset, -$offset) * ps)');
    buf.writeln('           + ${input}_tex(${input}_pos + vec2(-$offset,  $offset) * ps)');
    buf.writeln('           + ${input}_tex(${input}_pos + vec2(-$offset, -$offset) * ps);');
    buf.writeln('    return s * 0.25;');
    buf.writeln('}');
    buf.writeln();
  }

  /// Write the shader to a temp file and return the path.
  Future<String> _writeShaderToTemp(String shader) async {
    final cacheDir = await getTemporaryDirectory();
    final shaderDir = Directory(path.join(cacheDir.path, 'shaders'));
    if (!shaderDir.existsSync()) {
      shaderDir.createSync(recursive: true);
    }
    final file = File(path.join(shaderDir.path, 'ambient_lighting.glsl'));
    await file.writeAsString(shader);
    return file.path;
  }
}
