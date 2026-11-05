import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/video_equalizer.dart';

void main() {
  test('concurrent changes execute in invocation order', () async {
    final gate = Completer<void>();
    final stored = <String, int>{};
    final applied = <int>[];
    final equalizer = VideoEqualizer(
      read: (key) => stored[key],
      write: (key, value) async { stored[key] = value; },
      apply: (_, value) async {
        if (value == 1) await gate.future;
        applied.add(value);
      },
    );
    final first = equalizer.set(VideoEqualizerControl.brightness, 1);
    final second = equalizer.set(VideoEqualizerControl.brightness, 2);
    await Future<void>.delayed(Duration.zero);
    expect(applied, isEmpty);
    gate.complete();
    await Future.wait([first, second]);
    expect(applied, [1, 2]);
    expect(stored['filter_brightness'], 2);
  });
  test('reset waits for an earlier change across instances', () async {
    final gate = Completer<void>();
    final stored = <String, int>{};
    VideoEqualizer make() => VideoEqualizer(
      read: (key) => stored[key],
      write: (key, value) async { stored[key] = value; },
      apply: (_, value) async { if (value == 12) await gate.future; },
    );
    final first = make().set(VideoEqualizerControl.brightness, 12);
    final reset = make().reset();
    await Future<void>.delayed(Duration.zero);
    gate.complete();
    await Future.wait([first, reset]);
    expect(stored['filter_brightness'], 0);
  });

  test('failed operation does not block later operations', () async {
    final stored = <String, int>{};
    final equalizer = VideoEqualizer(
      read: (key) => stored[key],
      write: (key, value) async { stored[key] = value; },
      apply: (_, value) async { if (value == 1) throw StateError('failed'); },
    );
    final failed = equalizer.set(VideoEqualizerControl.brightness, 1);
    final next = equalizer.set(VideoEqualizerControl.brightness, 2);
    await expectLater(failed, throwsStateError);
    await next;
    expect(stored['filter_brightness'], 2);
  });

  test('active tracks stored non-neutral values', () {
    final stored = <String, int>{};
    final equalizer = VideoEqualizer(read: (key) => stored[key], write: (_, __) async {}, apply: (_, __) async {});
    expect(equalizer.active, isFalse);
    stored['filter_gamma'] = 1;
    expect(equalizer.active, isTrue);
  });
  test('each control maps to the mpv property and clamps to its range', () {
    expect(VideoEqualizerControl.values.map((e) => e.property), [
      'brightness',
      'saturation',
      'gamma',
      'contrast',
      'hue',
      'sharpen',
    ]);
    for (final control in VideoEqualizerControl.values) {
      final bound = control == VideoEqualizerControl.sharpness ? 5 : 100;
      expect(control.clamp(-1000), -bound);
      expect(control.clamp(1000), bound);
      expect(control.clamp(0), 0);
    }
  });

  test('changes persist and apply, restore and reset all properties', () async {
    final stored = <String, int>{};
    final applied = <String, int>{};
    final equalizer = VideoEqualizer(
      read: (key) => stored[key],
      write: (key, value) async {
        stored[key] = value;
      },
      apply: (name, value) async {
        applied[name] = value;
      },
    );
    await equalizer.set(VideoEqualizerControl.sharpness, 12);
    expect(stored['filter_sharpness'], 5);
    expect(applied['sharpen'], 5);
    applied.clear();
    await equalizer.restore();
    expect(applied.length, 6);
    expect(applied['sharpen'], 5);
    await equalizer.reset();
    expect(stored.values.every((value) => value == 0), isTrue);
    expect(applied.values.every((value) => value == 0), isTrue);
  });
}
