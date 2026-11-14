import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/video_equalizer.dart';
import 'package:plezy/services/video_filter_presets.dart';

void main() {
  test('overlapping saves from different instances preserve both presets', () async {
    var data = '{}';
    final firstWrite = Completer<void>();
    var writes = 0;
    VideoFilterPresets create() => VideoFilterPresets(
      read: () => data,
      write: (value) async {
        if (writes++ == 0) await firstWrite.future;
        data = value;
      },
    );
    final values = {for (final control in VideoEqualizerControl.values) control.name: 0};
    final first = create().save('Day', values);
    final second = create().save('Night', values);
    firstWrite.complete();
    await Future.wait([first, second]);
    expect(create().names, ['Day', 'Night']);
  });
  test('overwrite preserves other names and malformed data is ignored', () async {
    String data = 'not json';
    final presets = VideoFilterPresets(read: () => data, write: (v) async => data = v);
    expect(presets.names, isEmpty);
    final values = {for (final control in VideoEqualizerControl.values) control.name: 0};
    await presets.save('Day', values);
    await presets.save('day', values);
    await presets.save('Day', {...values, 'gamma': 35});
    expect(presets.names, ['Day', 'day']);
    expect(presets.values('Day')!['gamma'], 35);
    expect(presets.values('day')!['gamma'], 0);
    await expectLater(presets.save('  ', values), throwsFormatException);
  });

  test('presets persist with case-sensitive names and restore all controls', () async {
    String data = '';
    final stored = <String, int>{};
    final applied = <String, int>{};
    final eq = VideoEqualizer(
      read: (k) => stored[k],
      write: (k, v) async {
        stored[k] = v;
      },
      apply: (k, v) async {
        applied[k] = v;
      },
    );
    final presets = VideoFilterPresets(
      read: () => data,
      write: (v) async {
        data = v;
      },
    );
    await eq.set(VideoEqualizerControl.brightness, 20);
    await presets.save('Day', await eq.snapshot());
    await eq.set(VideoEqualizerControl.brightness, -10);
    await presets.save('day', await eq.snapshot());
    expect(presets.names, ['Day', 'day']);
    await eq.applyValues(presets.values('Day')!);
    expect(stored['filter_brightness'], 20);
    expect(applied['brightness'], 20);
    expect(applied.length, VideoEqualizerControl.values.length);
    await presets.delete('Day');
    expect(VideoFilterPresets(read: () => data, write: (_) async {}).names, ['day']);
  });
}
