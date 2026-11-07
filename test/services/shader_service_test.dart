import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/models/shader_preset.dart';
import 'package:plezy/mpv/player/player.dart';
import 'package:plezy/services/shader_asset_loader.dart';
import 'package:plezy/services/ambient_lighting_service.dart';
import 'package:plezy/services/shader_service.dart';

import '../test_helpers/io_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PathProviderPlatform originalPathProvider;
  late Directory root;

  setUp(() async {
    originalPathProvider = PathProviderPlatform.instance;
    root = await Directory.systemTemp.createTemp('plezy_shader_service_test_');
    PathProviderPlatform.instance = FakePathProvider(root);
    ShaderAssetLoader.clearCache();
  });

  tearDown(() async {
    PathProviderPlatform.instance = originalPathProvider;
    ShaderAssetLoader.clearCache();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Iterable<List<String>> appends(_RecordingPlayer player) =>
      player.commands.where((command) => command.length > 2 && command[2] == 'append');

  test('Anime4K repeated passes and shared-path transitions preserve external shaders', () async {
    final player = _RecordingPlayer()..shaderChain.add('/external/custom.glsl');
    final service = ShaderService(player);
    final a = ShaderPreset.anime4kPreset(Anime4KQuality.fast, Anime4KMode.modeA);
    final b = ShaderPreset.anime4kPreset(Anime4KQuality.fast, Anime4KMode.modeB);
    final aa = ShaderPreset.anime4kPreset(Anime4KQuality.fast, Anime4KMode.modeAA);
    await service.applyPreset(a);
    await service.applyPreset(b);
    expect(service.currentPreset, b);
    await service.applyPreset(aa);
    expect(service.currentPreset, aa);
    final sources = await ShaderAssetLoader.getShadersForPreset(aa);
    expect(player.shaderChain.length, sources.length + 1);
    expect(player.shaderChain.first, '/external/custom.glsl');
    for (var i = 0; i < sources.length; i++) {
      expect(await File(player.shaderChain[i + 1]).readAsBytes(), await File(sources[i]).readAsBytes());
    }
    expect(player.shaderChain.toSet().length, player.shaderChain.length);
  });

  test('partial preset removal restores the original order', () async {
    final player = _RecordingPlayer()..shaderChain.add('/external/custom.glsl');
    final service = ShaderService(player);
    await service.applyPreset(ShaderPreset.anime4kPreset(Anime4KQuality.fast, Anime4KMode.modeB));
    final before = List<String>.of(player.shaderChain);
    player.failRemovalNumber = 2;
    await service.applyPreset(ShaderPreset.none);
    expect(player.shaderChain, before);
  });

  test('color updates replace only their shader with a new path and neutral removes it', () async {
    final player = _RecordingPlayer()..shaderChain.add('/external/custom.glsl');
    final service = ShaderService(player);
    await service.setColorEqualizer(saturation: 40, hue: 0);
    final first = player.shaderChain.last;
    expect(await File(first).readAsString(), contains('40.0'));
    await service.setColorEqualizer(saturation: 40, hue: 25);
    final second = player.shaderChain.last;
    expect(second, isNot(first));
    expect(player.shaderChain, ['/external/custom.glsl', second]);
    await service.setColorEqualizer(saturation: 0, hue: 0);
    expect(player.shaderChain, ['/external/custom.glsl']);
  });

  test('superseded generated color files are removed only after replacement', () async {
    final player = _RecordingPlayer();
    final service = ShaderService(player);
    await service.setColorControl('saturation', 20);
    final old = player.shaderChain.single;
    final gate = Completer<void>();
    player.shaderWriteGate = gate;
    final update = service.setColorControl('saturation', 30);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(await File(old).exists(), isTrue);
    gate.complete();
    await update;
    expect(await File(old).exists(), isFalse);
    expect(await Directory(path.dirname(old)).exists(), isFalse);
    final current = player.shaderChain.single;
    expect(await File(current).exists(), isTrue);
    await service.setColorControl('saturation', 0);
    expect(await File(current).exists(), isFalse);
  });

  test('preset aliases are cleaned without deleting foreign files or cached sources', () async {
    final player = _RecordingPlayer();
    final service = ShaderService(player);
    final preset = ShaderPreset.anime4kPreset(Anime4KQuality.fast, Anime4KMode.modeB);
    await service.applyPreset(preset);
    final old = List<String>.of(player.shaderChain);
    final foreign = File(path.join(path.dirname(old.first), 'foreign.glsl'));
    await foreign.writeAsString('foreign');
    final sources = await ShaderAssetLoader.getShadersForPreset(preset);
    await service.applyPreset(ShaderPreset.none);
    for (final file in old) {
      expect(await File(file).exists(), isFalse);
    }
    expect(await foreign.readAsString(), 'foreign');
    for (final source in sources) {
      expect(await File(source).exists(), isTrue);
    }
  });

  test('quarantine retains both possible active files and stops further staging', () async {
    final player = _RecordingPlayer();
    final service = ShaderService(player);
    await service.setColorControl('saturation', 20);
    final old = player.shaderChain.single;
    player.failOperation = 'remove';
    await expectLater(service.setColorControl('saturation', 30), throwsStateError);
    final attempted = player.commands.lastWhere((c) => c[2] == 'append')[3];
    expect(await File(old).exists(), isTrue);
    expect(await File(attempted).exists(), isTrue);
    final temp = Directory(path.join(root.path, 'temp'));
    final count = temp.listSync().length;
    for (var i = 0; i < 5; i++) {
      await expectLater(service.setColorControl('hue', i + 1), throwsStateError);
    }
    expect(temp.listSync().length, count);
  });

  test('rapid color updates keep only the last generated shader', () async {
    final player = _RecordingPlayer();
    final service = ShaderService(player);
    await Future.wait(List.generate(12, (i) => service.setColorControl('hue', i + 1)));
    final dirs = Directory(
      path.join(root.path, 'temp'),
    ).listSync().whereType<Directory>().where((d) => path.basename(d.path).startsWith('plezy-color-'));
    expect(dirs, hasLength(1));
    expect(await File(player.shaderChain.single).readAsString(), contains('12.0'));
  });

  test('external paths with separators and backslashes survive color changes', () async {
    final player = _RecordingPlayer()..shaderChain.addAll([r'/external/a:b.glsl', r'/external/a\b.glsl']);
    final service = ShaderService(player);
    await service.setColorControl('saturation', 20);
    await service.setColorControl('saturation', 30);
    await service.setColorControl('saturation', 0);
    expect(player.shaderChain, [r'/external/a:b.glsl', r'/external/a\b.glsl']);
    expect(player.commands.every((c) => c[2] != 'set' && c[2] != 'clr'), isTrue);
  });

  test('replacing color never publishes an empty shader chain', () async {
    final player = _RecordingPlayer();
    final service = ShaderService(player);
    await service.setColorEqualizer(saturation: 20, hue: 0);
    player.snapshots.clear();
    await service.setColorEqualizer(saturation: 30, hue: 0);
    expect(player.snapshots, isNotEmpty);
    expect(player.snapshots.every((chain) => chain.isNotEmpty), isTrue);
  });

  test('a failed removal compensates the newly appended color and quarantines updates', () async {
    final player = _RecordingPlayer();
    final service = ShaderService(player);
    await service.setColorControl('saturation', 20);
    final old = List<String>.of(player.shaderChain);
    player.failOperation = 'remove';
    await expectLater(service.setColorControl('saturation', 30), throwsStateError);
    expect(player.shaderChain, old);
    await expectLater(service.setColorControl('hue', 10), throwsStateError);
    expect(player.shaderChain, old);
  });

  test('a duplicate owned path is treated as a collision and not removed', () async {
    final player = _RecordingPlayer();
    final service = ShaderService(player);
    await service.setColorControl('saturation', 20);
    player.shaderChain.add(player.shaderChain.single);
    final before = List<String>.of(player.shaderChain);
    await expectLater(service.setColorControl('saturation', 0), throwsStateError);
    expect(player.shaderChain, before);
  });

  test('failed color replacement keeps the previous shader and values', () async {
    final player = _RecordingPlayer();
    final service = ShaderService(player);
    await service.setColorControl('saturation', 20);
    final old = List<String>.of(player.shaderChain);
    player.failNextShaderWrite = true;
    await expectLater(service.setColorControl('saturation', 60), throwsStateError);
    expect(player.shaderChain, old);
    await expectLater(service.setColorControl('hue', 10), throwsStateError);
    expect(player.shaderChain, old);
  });

  test('failed preset replacement retains the committed preset and chain', () async {
    final player = _RecordingPlayer();
    final service = ShaderService(player);
    await service.applyPreset(ShaderPreset.nvscalerDefault);
    final old = List<String>.of(player.shaderChain);
    player.failNextShaderWrite = true;
    await service.applyPreset(ShaderPreset.none);
    expect(player.shaderChain, old);
    expect(service.currentPreset, ShaderPreset.nvscalerDefault);
    player.properties['video-params/primaries'] = 'bt.2020';
    expect(await service.reapplyForContent(), isFalse);
    expect(player.shaderChain, old);
  });

  test('ambient enable is serialized behind a pending color update', () async {
    final player = _RecordingPlayer();
    final service = ShaderService(player);
    final ambient = AmbientLightingService(player);
    service.ambientLightingService = ambient;
    final gate = Completer<void>();
    player.shaderWriteGate = gate;
    final color = service.setColorControl('saturation', 20);
    await Future<void>.delayed(Duration.zero);
    final enable = ambient.enable(1.5);
    await Future<void>.delayed(Duration.zero);
    expect(ambient.isEnabled, isFalse);
    gate.complete();
    await Future.wait([color, enable]);
    expect(ambient.isEnabled, isTrue);
    expect(player.shaderChain, hasLength(2));
    expect(player.shaderChain.last, endsWith('ambient_lighting.glsl'));
  });

  test('failed ambient fill restores the previous chain', () async {
    final player = _RecordingPlayer();
    final service = ShaderService(player);
    await service.setColorControl('saturation', 20);
    final old = List<String>.of(player.shaderChain);
    final ambient = AmbientLightingService(player);
    player.failKeepaspect = true;
    await ambient.enable(1.5);
    expect(ambient.isEnabled, isFalse);
    expect(player.shaderChain, old);
  });

  test('preset changes keep the color shader after the preset', () async {
    final player = _RecordingPlayer();
    final service = ShaderService(player);
    await service.setColorEqualizer(saturation: 40, hue: 0);
    final color = player.shaderChain.single;
    await service.applyPreset(ShaderPreset.nvscalerDefault);
    expect(player.shaderChain, hasLength(2));
    expect(player.shaderChain.last, color);
  });

  test('a later preset change wins while the earlier HDR check is pending', () async {
    final player = _RecordingPlayer();
    final gate = Completer<void>();
    player.propertyGate = gate;
    final service = ShaderService(player);

    final first = service.applyPreset(ShaderPreset.nvscalerDefault);
    await Future<void>.delayed(Duration.zero);
    final second = service.applyPreset(ShaderPreset.none);
    gate.complete();
    await Future.wait([first, second]);

    expect(service.currentPreset, ShaderPreset.none);
    expect(player.shaderChain, isEmpty);
  });

  test('rebuilding a preset does not clear shaders owned by other services', () async {
    final player = _RecordingPlayer();
    player.shaderChain.add('/external/custom.glsl');
    final service = ShaderService(player);
    await service.applyPreset(ShaderPreset.nvscalerDefault);
    final original = player.shaderChain.last;
    player.commands.clear();

    await service.applyPreset(ShaderPreset.none);

    expect(player.shaderChain, isNot(contains(original)));
    expect(player.shaderChain, ['/external/custom.glsl']);
  });

  test('an escaped custom preset never reaches the MPV shader append command', () async {
    final supportDirectory = Directory(path.join(root.path, 'support'))..createSync(recursive: true);
    final sentinel = File(path.join(supportDirectory.path, 'sentinel.glsl'))..writeAsStringSync('sentinel');
    final player = _RecordingPlayer();
    final service = ShaderService(player);
    const preset = ShaderPreset(
      id: 'custom_traversal',
      name: 'Traversal',
      type: ShaderPresetType.custom,
      fileName: '../sentinel.glsl',
    );

    await service.applyPreset(preset);

    expect(player.commands.where((command) => command.length > 2 && command[2] == 'append'), isEmpty);
    expect(player.commands, isEmpty);
    expect(await sentinel.readAsString(), 'sentinel');
  });

  group('reapplyForContent', () {
    test('drops an NVScaler applied before decode once the frame proves HDR content', () async {
      final player = _RecordingPlayer();
      final service = ShaderService(player);

      // Nothing decoded yet: mpv answers no colour params, so the HDR skip
      // cannot fire and the chain gets NVScaler.
      await service.applyPreset(ShaderPreset.nvscalerDefault);
      expect(player.shaderChain, hasLength(1));
      final shaderPath = player.shaderChain.single;
      expect(service.currentPreset, ShaderPreset.nvscalerDefault);

      player.properties['video-params/colormatrix'] = 'bt.2020-ncl';
      player.commands.clear();

      expect(await service.reapplyForContent(), isTrue);
      expect(player.shaderChain, isNot(contains(shaderPath)));
      expect(service.currentPreset, ShaderPreset.none);
    });

    test('brings a skipped NVScaler back when the next item is SDR', () async {
      final player = _RecordingPlayer()..properties['video-params/primaries'] = 'bt.2020';
      final service = ShaderService(player);

      await service.applyPreset(ShaderPreset.nvscalerDefault);
      expect(appends(player), isEmpty);
      expect(service.currentPreset, ShaderPreset.none);

      player.properties['video-params/primaries'] = 'bt.709';
      player.commands.clear();

      expect(await service.reapplyForContent(), isTrue);
      expect(player.shaderChain, hasLength(1));
      expect(service.currentPreset, ShaderPreset.nvscalerDefault);
    });

    test('leaves the chain alone when the decision stands', () async {
      final player = _RecordingPlayer();
      final service = ShaderService(player);

      await service.applyPreset(ShaderPreset.nvscalerDefault);
      player.commands.clear();

      expect(await service.reapplyForContent(), isFalse);
      expect(player.commands, isEmpty);
    });

    test('does not resurrect a preset the viewer switched off', () async {
      final player = _RecordingPlayer()..properties['video-params/primaries'] = 'bt.2020';
      final service = ShaderService(player);

      await service.applyPreset(ShaderPreset.nvscalerDefault);
      await service.applyPreset(ShaderPreset.none);
      player.properties['video-params/primaries'] = 'bt.709';
      player.commands.clear();

      expect(await service.reapplyForContent(), isFalse);
      expect(player.commands, isEmpty);
      expect(service.currentPreset, ShaderPreset.none);
    });
  });
}

class _RecordingPlayer implements Player {
  final commands = <List<String>>[];
  final shaderChain = <String>[];
  final snapshots = <List<String>>[];
  Completer<void>? propertyGate;
  Completer<void>? shaderWriteGate;
  bool failNextShaderWrite = false;
  String? failOperation;
  int? failRemovalNumber;
  bool failKeepaspect = false;

  /// mpv property answers; anything absent is unavailable (null), which is
  /// what a core answers before it has decoded a frame.
  final properties = <String, String>{};

  @override
  String get playerType => 'mpv';

  @override
  Future<void> command(List<String> args) async {
    commands.add(List.unmodifiable(args));
    if (args.length > 2 && args[1] == 'glsl-shaders') {
      final gate = shaderWriteGate;
      shaderWriteGate = null;
      if (gate != null) await gate.future;
      if (args[2] == 'remove' && failRemovalNumber != null) {
        failRemovalNumber = failRemovalNumber! - 1;
        if (failRemovalNumber == 0) {
          failRemovalNumber = null;
          throw StateError('shader removal failed');
        }
      }
      if (failOperation == args[2]) {
        failOperation = null;
        throw StateError('shader operation failed');
      }
      if (failNextShaderWrite) {
        failNextShaderWrite = false;
        throw StateError('shader write failed');
      }
    }
    if (args.length >= 4 && args[0] == 'change-list' && args[1] == 'glsl-shaders') {
      switch (args[2]) {
        case 'set':
          shaderChain
            ..clear()
            ..addAll(args[3].isEmpty ? <String>[] : args[3].split(Platform.isWindows ? ';' : ':'));
        case 'append':
          shaderChain.add(args[3]);
        case 'remove':
          shaderChain.remove(args[3]);
        case 'clr':
          shaderChain.clear();
      }
      snapshots.add(List.of(shaderChain));
    }
  }

  @override
  Future<void> setProperty(String name, String value) async {
    if (name == 'keepaspect' && failKeepaspect) throw StateError('fill failed');
  }

  @override
  Future<String?> getProperty(String name) async {
    await propertyGate?.future;
    if (name == 'glsl-shaders') return shaderChain.join(Platform.isWindows ? ';' : ':');
    return properties[name];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
