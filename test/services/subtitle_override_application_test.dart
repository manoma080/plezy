import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/subtitle_override_application.dart';
import 'package:plezy/utils/app_logger.dart';

void main() {
  test('does not change selection on failed or throwing server write', () async {
    final source = MediaSourceInfo(
      videoUrl: '',
      audioTracks: [],
      chapters: [],
      partId: 12,
      subtitleTracks: [
        MediaSubtitleTrack(id: 1, selected: true, forced: false, languageCode: 'eng'),
        MediaSubtitleTrack(id: 2, selected: false, forced: false, languageCode: 'eng', title: 'SDH'),
      ],
    );
    for (final save in <Future<bool> Function(int, int)>[
      (_, _) async => false,
      (_, _) async => throw StateError('unavailable'),
    ]) {
      MemoryLogOutput.clearLogs();
      final result = await applySubtitleOverride(
        source,
        preference: SubtitlePreferenceOverride.cc,
        language: 'en',
        save: save,
      );
      expect(result, same(source));
      expect(
        MemoryLogOutput.getLogs().any((entry) => entry.message.contains('Failed to save subtitle override')),
        isTrue,
      );
    }
  });
  test('off, missing language or part, and no matching track never write', () async {
    var writes = 0;
    Future<bool> save(int part, int stream) async {
      writes++;
      return true;
    }

    final source = MediaSourceInfo(
      videoUrl: '',
      audioTracks: [],
      chapters: [],
      partId: 12,
      subtitleTracks: [MediaSubtitleTrack(id: 1, selected: true, forced: false, languageCode: 'eng')],
    );
    for (final (preference, language) in [
      (SubtitlePreferenceOverride.off, 'en'),
      (SubtitlePreferenceOverride.standard, null),
      (SubtitlePreferenceOverride.cc, 'en'),
      (SubtitlePreferenceOverride.standard, 'fr'),
    ]) {
      expect(await applySubtitleOverride(source, preference: preference, language: language, save: save), same(source));
    }
    final noPart = MediaSourceInfo(videoUrl: '', audioTracks: [], chapters: [], subtitleTracks: source.subtitleTracks);
    expect(
      await applySubtitleOverride(noPart, preference: SubtitlePreferenceOverride.standard, language: 'en', save: save),
      same(noPart),
    );
    expect(writes, 0);
  });
  test('persists the matching language and type on the actual part', () async {
    final source = MediaSourceInfo(
      videoUrl: '',
      audioTracks: [],
      chapters: [],
      partId: 12,
      subtitleTracks: [
        MediaSubtitleTrack(id: 1, selected: true, forced: false, languageCode: 'eng'),
        MediaSubtitleTrack(id: 2, selected: false, forced: false, languageCode: 'eng', title: 'SDH'),
      ],
    );
    final writes = <(int, int)>[];
    final result = await applySubtitleOverride(
      source,
      preference: SubtitlePreferenceOverride.cc,
      language: 'en',
      save: (part, stream) async {
        writes.add((part, stream));
        return true;
      },
    );
    expect(writes, [(12, 2)]);
    expect(result.subtitleTracks.map((s) => s.selected), [false, true]);
  });
}
