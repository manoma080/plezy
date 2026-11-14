import '../media/media_source_info.dart';
import '../media/subtitle_preference.dart';
import 'settings_service.dart';

/// Applies an automatic selection only after the server confirms the write.
/// The caller must provide fresh source data and coordinate manual choices.
Future<MediaSourceInfo> applySubtitleOverride(
  MediaSourceInfo source, {
  required SubtitlePreferenceOverride preference,
  required String? language,
  required Future<bool> Function(int partId, int streamId) save,
  bool confirmSelected = false,
}) async {
  final kind = switch (preference) {
    SubtitlePreferenceOverride.off => null,
    SubtitlePreferenceOverride.standard => SubtitleKind.standard,
    SubtitlePreferenceOverride.cc => SubtitleKind.cc,
    SubtitlePreferenceOverride.forced => SubtitleKind.forced,
    SubtitlePreferenceOverride.signs => SubtitleKind.signs,
  };
  if (kind == null || language == null || source.partId == null) return source;
  final match = selectPreferredSubtitle(source.subtitleTracks, languageCode: language, kind: kind);
  if (match == null || (match.selected && !confirmSelected)) return source;
  try {
    if (!await save(source.partId!, match.id)) return source;
  } catch (_) {
    return source;
  }
  return source.copyWith(
    subtitleTracks: [for (final row in source.subtitleTracks) row.withSelected(row.id == match.id)],
  );
}
