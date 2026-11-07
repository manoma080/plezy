import 'dart:io';

import '../mpv/player/player.dart';
import 'shader_service.dart';

/// The libmpv equalizer properties and their integer UI ranges.
enum VideoEqualizerControl {
  brightness('brightness', 100),
  saturation('saturation', 100),
  gamma('gamma', 100),
  contrast('contrast', 100),
  hue('hue', 100),
  sharpness('sharpen', 5);

  const VideoEqualizerControl(this.property, this.bound);
  final String property;
  final int bound;

  int clamp(int value) => value.clamp(-bound, bound);
  String get key => 'filter_$name';
}

/// Coordinates persistent values with a live libmpv property sink.
class VideoEqualizer {
  VideoEqualizer({required this.read, required this.write, required this.apply});

  static final Expando<VideoEqualizer> _players = Expando<VideoEqualizer>();

  /// Restore and live UI controls for one player share the same queue and sink.
  static VideoEqualizer forPlayer(
    Player player, {
    required int? Function(String) read,
    required Future<void> Function(String, int) write,
  }) => _players[player] ??= VideoEqualizer(
    read: read,
    write: write,
    apply: (property, value) async {
      if (Platform.isAndroid && (property == 'saturation' || property == 'hue')) {
        await ShaderService.forPlayer(player).setColorControl(property, value);
      } else {
        await player.setProperty(property, value.toString());
      }
    },
  );

  final int? Function(String key) read;
  final Future<void> Function(String key, int value) write;
  final Future<void> Function(String property, int value) apply;

  int value(VideoEqualizerControl control) => control.clamp(read(control.key) ?? 0);

  bool get active => VideoEqualizerControl.values.any((control) => value(control) != 0);

  // All instances share the same preferences and player properties.
  static Future<void> _pending = Future.value();

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.then<void>((_) {}, onError: (Object error, StackTrace stack) {});
    return result;
  }

  Future<void> _set(VideoEqualizerControl control, int raw) async {
    final next = control.clamp(raw);
    await apply(control.property, next);
    await write(control.key, next);
  }

  Future<void> set(VideoEqualizerControl control, int raw) => _enqueue(() => _set(control, raw));

  Future<void> restore() => _enqueue(() async {
    for (final control in VideoEqualizerControl.values) {
      await apply(control.property, value(control));
    }
  });

  Future<void> reset() => _enqueue(() async {
    for (final control in VideoEqualizerControl.values) {
      await _set(control, 0);
    }
  });
}
