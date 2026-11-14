import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:os_media_controls/os_media_controls.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/gamepad_service.dart';
import 'package:universal_gamepad/universal_gamepad.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/media_items.dart';
import '../../test_helpers/mock_player_channels.dart';
import '../../test_helpers/prefs.dart';

/// Regression coverage for #1375: OS media-session skip commands arrive in
/// bursts (a held remote key, a mashed lock-screen button). Dispatched one
/// native seek per event they all rebase off the same not-yet-applied
/// position and re-seek the same target, which pins the playhead.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.seekTimeSmall, 10);
  });

  testWidgets('a burst of OS skip commands commits one seek at the configured step', (tester) async {
    final player = _SeekRecordingPlayer(position: const Duration(minutes: 2));

    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      testBody: () async {
        final screenKey = GlobalKey<VideoPlayerScreenState>();
        await tester.pumpWidget(_screen(screenKey));
        screenKey.currentState!.player = player;

        final router = screenKey.currentState!.debugMediaControlRouterForTesting();
        // The interval Android reports is its own hardcoded 15s; the viewer's
        // configured step is what must move the playhead.
        for (var i = 0; i < 4; i++) {
          router.route(const SkipForwardEvent(Duration(seconds: 15)));
        }
        expect(player.seekTargets, isEmpty, reason: 'nothing is dispatched while the burst is still arriving');

        await tester.pump(const Duration(milliseconds: 400));

        expect(player.seekTargets, [
          const Duration(minutes: 2, seconds: 40),
        ], reason: 'four steps of 10s, as one seek — not four seeks onto a stale target');

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });

  testWidgets('a backward burst mirrors the forward one', (tester) async {
    final player = _SeekRecordingPlayer(position: const Duration(minutes: 2));

    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      testBody: () async {
        final screenKey = GlobalKey<VideoPlayerScreenState>();
        await tester.pumpWidget(_screen(screenKey));
        screenKey.currentState!.player = player;

        final router = screenKey.currentState!.debugMediaControlRouterForTesting();
        for (var i = 0; i < 4; i++) {
          router.route(const SkipBackwardEvent(Duration(seconds: 15)));
        }
        await tester.pump(const Duration(milliseconds: 400));

        expect(player.seekTargets, [const Duration(minutes: 1, seconds: 20)]);

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });

  testWidgets('right stick seeks with configured small and large intervals', (tester) async {
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.seekTimeLarge, 45);
    final player = _SeekRecordingPlayer(position: const Duration(minutes: 2));
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      testBody: () async {
        final key = GlobalKey<VideoPlayerScreenState>();
        await tester.pumpWidget(_screen(key));
        key.currentState!.player = player;
        final service = GamepadService.forTesting();
        for (final entry in [
          (GamepadAxis.rightStickX, -1.0, 110),
          (GamepadAxis.rightStickX, 1.0, 120),
          (GamepadAxis.rightStickY, -1.0, 165),
          (GamepadAxis.rightStickY, 1.0, 120),
        ]) {
          service.debugHandleGamepadEvent(
            GamepadAxisEvent(gamepadId: 1, timestamp: 0, axis: entry.$1, value: entry.$2),
          );
          service.debugHandleGamepadEvent(GamepadAxisEvent(gamepadId: 1, timestamp: 0, axis: entry.$1, value: 0));
          await tester.pump(const Duration(milliseconds: 400));
          expect(player.seekTargets.last, Duration(seconds: entry.$3));
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });
}

Widget _screen(GlobalKey<VideoPlayerScreenState> key) {
  return ChangeNotifierProvider(
    create: (_) => PlaybackStateProvider(),
    child: MaterialApp(
      home: VideoPlayerScreen(
        key: key,
        metadata: testMediaItem(title: 'Media control skip burst'),
        isOffline: true,
      ),
    ),
  );
}

class _SeekRecordingPlayer implements Player {
  _SeekRecordingPlayer({required Duration position})
    : _state = PlayerState(position: position, duration: const Duration(minutes: 45), seekable: true);

  PlayerState _state;
  final List<Duration> seekTargets = [];

  @override
  PlayerState get state => _state;

  @override
  Future<void> seek(Duration position) async {
    seekTargets.add(position);
    _state = _state.copyWith(position: position);
  }

  @override
  Future<void> dispose({bool preserveDisplayMode = false}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
