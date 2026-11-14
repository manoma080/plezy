import 'dart:convert';

import 'video_equalizer.dart';

/// Named snapshots stored together as JSON; names are case-sensitive.
class VideoFilterPresets {
  VideoFilterPresets({required this.read, required this.write});
  final String Function() read;
  final Future<void> Function(String) write;

  Map<String, Map<String, int>> _load() {
    try {
      final raw = jsonDecode(read());
      if (raw is! Map) return {};
      final result = <String, Map<String, int>>{};
      for (final entry in raw.entries) {
        if (entry.key is! String || entry.value is! Map) continue;
        final values = <String, int>{};
        for (final control in VideoEqualizerControl.values) {
          final value = (entry.value as Map)[control.name];
          if (value is! int) break;
          values[control.name] = control.clamp(value);
        }
        if (values.length == VideoEqualizerControl.values.length) result[entry.key as String] = values;
      }
      return result;
    } on FormatException {
      return {};
    }
  }

  List<String> get names => _load().keys.toList();
  Map<String, int>? values(String name) => _load()[name];

  static Future<void> _pending = Future.value();

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.then<void>((_) {}, onError: (Object error, StackTrace stack) {});
    return result;
  }

  Future<void> save(String name, Map<String, int> values) async {
    if (name.trim().isEmpty) throw const FormatException('A preset name is required');
    final snapshot = Map<String, int>.of(values);
    return _enqueue(() async {
      final presets = _load();
      presets[name] = snapshot;
      await write(jsonEncode(presets));
    });
  }

  Future<void> delete(String name) => _enqueue(() async {
    final presets = _load()..remove(name);
    await write(jsonEncode(presets));
  });
}
