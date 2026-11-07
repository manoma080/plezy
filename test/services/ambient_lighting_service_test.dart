import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/mpv/player/player.dart';
import 'package:plezy/mpv/player/player_state.dart';
import 'package:plezy/services/ambient_lighting_service.dart';

import '../test_helpers/io_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PathProviderPlatform originalPathProvider;
  late Directory temporaryRoot;

  setUp(() {
    originalPathProvider = PathProviderPlatform.instance;
    temporaryRoot = Directory.systemTemp.createTempSync('plezy_ambient_test_');
    PathProviderPlatform.instance = FakePathProvider(temporaryRoot);
  });

  tearDown(() {
    PathProviderPlatform.instance = originalPathProvider;
    temporaryRoot.deleteSync(recursive: true);
  });

  test('failed fill write restores keepaspect even if shader cleanup fails', () async {
    final player = _AmbientPlayer()
      ..failFillAfterWrite = true
      ..failShaderRemoval = true;
    final service = AmbientLightingService(player);
    await service.enable(1.5);
    expect(service.isEnabled, isFalse);
    expect(player.keepaspect, 'yes');
  });

  test('enable hands mpv the picture aspect for subtitle placement before stretching the frame', () async {
    final player = _AmbientPlayer();
    final service = AmbientLightingService(player);

    await service.enable(16 / 9);

    final subRect = player.propertyWrites.indexWhere((write) => write.$1 == 'sub-video-rect-aspect');
    final fill = player.propertyWrites.indexOf(('keepaspect', 'no'));
    expect(subRect, isNot(-1));
    expect(fill, isNot(-1));
    expect(subRect, lessThan(fill));
    expect(double.parse(player.propertyWrites[subRect].$2), closeTo(16 / 9, 0.0001));
  });

  test('disable restores the letterbox and subtitle placement to the displayed video rect', () async {
    final player = _AmbientPlayer();
    final service = AmbientLightingService(player);

    await service.enable(16 / 9);
    player.propertyWrites.clear();
    await service.disable();

    expect(service.isEnabled, isFalse);
    expect(player.propertyWrites, containsAll([('keepaspect', 'yes'), ('sub-video-rect-aspect', 'no')]));
  });

  test('a rejected subtitle rect write leaves the frame untouched', () async {
    final player = _AmbientPlayer()..setPropertyError = StateError('unknown property');
    final service = AmbientLightingService(player);

    await service.enable(16 / 9);

    expect(service.isEnabled, isFalse);
    expect(player.propertyWrites.map((write) => write.$1), isNot(contains('keepaspect')));
    expect(player.commands, isEmpty);
  });

  test('a swapped picture re-points subtitle placement without touching the frame fill', () async {
    final player = _AmbientPlayer();
    final service = AmbientLightingService(player);

    await service.enable(16 / 9);
    player.propertyWrites.clear();
    await service.updateVideoAspect(2.39);

    expect(player.propertyWrites, [('sub-video-rect-aspect', '2.39')]);
  });

  test('the subtitle placement refresh is inert while ambient lighting is off', () async {
    final player = _AmbientPlayer();
    final service = AmbientLightingService(player);

    await service.updateVideoAspect(2.39);

    expect(player.propertyWrites, isEmpty);
  });
}

class _AmbientPlayer implements Player {
  final List<(String, String)> propertyWrites = [];
  final List<List<String>> commands = [];
  Object? setPropertyError;
  bool failFillAfterWrite = false;
  bool failShaderRemoval = false;
  String keepaspect = 'yes';
  final shaderChain = <String>[];

  @override
  PlayerState get state => const PlayerState();

  @override
  String get playerType => 'mpv';

  @override
  Future<void> command(List<String> command) async {
    commands.add(command);
    if (command[2] == 'append') shaderChain.add(command[3]);
    if (command[2] == 'remove' && failShaderRemoval) throw StateError('remove failed');
    if (command[2] == 'remove') shaderChain.remove(command[3]);
  }

  @override
  Future<void> setProperty(String name, String value) {
    propertyWrites.add((name, value));
    final error = setPropertyError;
    if (error != null) return Future<void>.error(error);
    if (name == 'keepaspect') {
      keepaspect = value;
      if (value == 'no' && failFillAfterWrite) return Future<void>.error(StateError('fill failed after write'));
    }
    return Future<void>.value();
  }

  @override
  Future<String?> getProperty(String name) async =>
      name == 'glsl-shaders' ? shaderChain.join(Platform.isWindows ? ';' : ':') : null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
