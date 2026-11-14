import '../utils/language_codes.dart';
import 'media_source_info.dart';

/// Types are not mutually exclusive: a track may be both forced and CC.
enum SubtitleKind { standard, cc, forced, signs }

final _words = RegExp(r'[a-z0-9]+');
final _shortForced = RegExp(r'(?:^|\s)-(?:f|ff)(?:$|[^a-z0-9])', caseSensitive: false);
final _shortSigns = RegExp(r'(?:^|\s)-ss(?:$|[^a-z0-9])', caseSensitive: false);

/// Classifies metadata, treating unmarked tracks as standard. Filename markers
/// are read only after the language suffix, never from parent directories.
Set<SubtitleKind> classifySubtitle(MediaSubtitleTrack track) {
  final result = <SubtitleKind>{};
  if (track.forced) result.add(SubtitleKind.forced);
  if (track.hearingImpaired) result.add(SubtitleKind.cc);

  void read(String text, {bool filename = false}) {
    final lower = text.toLowerCase();
    final tokens = _words.allMatches(lower).map((m) => m.group(0)!).toSet();
    if (tokens.contains('cc') ||
        tokens.contains('sdh') ||
        (tokens.contains('hi') && (filename || _language(track.languageCode) != 'hi')) ||
        lower.contains('hearing impaired') ||
        lower.contains('closed captions')) {
      result.add(SubtitleKind.cc);
    }
    if (tokens.contains('forced') ||
        tokens.contains('foreign') ||
        _shortForced.hasMatch(lower) ||
        (filename && (tokens.contains('f') || tokens.contains('ff')))) {
      result.add(SubtitleKind.forced);
    }
    if (tokens.contains('signs') || _shortSigns.hasMatch(lower) || (filename && tokens.contains('ss'))) {
      result.add(SubtitleKind.signs);
    }
  }

  for (final text in [track.title, track.displayTitle]) {
    if (text != null) read(text);
  }
  final path = track.filePath;
  if (path != null) {
    final basename = path.split(RegExp(r'[/\\]')).last;
    final parts = basename.split('.');
    final language = _language(track.languageCode);
    final index = parts.lastIndexWhere((part) => language != null && _language(part.split('-').first) == language);
    if (index >= 0 && index < parts.length - 1) {
      final suffix = parts[index].split('-').skip(1).followedBy(parts.skip(index + 1)).join('.');
      read(suffix, filename: true);
    }
  }
  if (result.isEmpty) result.add(SubtitleKind.standard);
  return result;
}

String? _language(String? code) {
  if (code == null) return null;
  final normalized = code.trim().toLowerCase().split(RegExp('[-_]')).first;
  if (!RegExp(r'^[a-z]{2,3}$').hasMatch(normalized) || normalized == 'und') return null;
  return LanguageCodes.getIso6391Code(normalized);
}

/// Prefers an exact kind over a multi-kind match, preserving server order
/// within each class. Unknown languages never match.
MediaSubtitleTrack? selectPreferredSubtitle(
  Iterable<MediaSubtitleTrack> tracks, {
  required String languageCode,
  required SubtitleKind kind,
}) {
  final language = _language(languageCode);
  if (language == null) return null;
  MediaSubtitleTrack? fallback;
  for (final track in tracks) {
    if (_language(track.languageCode) != language) continue;
    final kinds = classifySubtitle(track);
    if (!kinds.contains(kind)) continue;
    if (kinds.length == 1) return track;
    fallback ??= track;
  }
  return fallback;
}
