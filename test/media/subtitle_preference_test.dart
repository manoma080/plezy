import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/media/subtitle_preference.dart';
import 'package:plezy/services/file_info_parser.dart';

MediaSubtitleTrack track(
  int id, {
  String? languageCode = 'eng',
  String? title,
  bool forced = false,
  bool hearingImpaired = false,
  String? filePath,
}) => MediaSubtitleTrack(
  id: id,
  selected: false,
  forced: forced,
  languageCode: languageCode,
  title: title,
  hearingImpaired: hearingImpaired,
  filePath: filePath,
);

void main() {
  test('selects requested kind only in preferred language', () {
    final tracks = [track(1, title: '[CC]', languageCode: 'fra'), track(2, title: '[CC]'), track(3)];
    expect(selectPreferredSubtitle(tracks, languageCode: 'en-US', kind: SubtitleKind.cc)?.id, 2);
    expect(selectPreferredSubtitle(tracks, languageCode: 'de', kind: SubtitleKind.cc), isNull);
    expect(selectPreferredSubtitle(tracks, languageCode: 'en', kind: SubtitleKind.standard)?.id, 3);
  });
  test('classification recognises bounded tokens and independent flags', () {
    expect(
      classifySubtitle(track(1, title: '[Signs]', forced: true)),
      containsAll([SubtitleKind.signs, SubtitleKind.forced]),
    );
    expect(classifySubtitle(track(2, title: 'English [CC]')), contains(SubtitleKind.cc));
    expect(classifySubtitle(track(3, title: 'English -ff')), contains(SubtitleKind.forced));
    expect(classifySubtitle(track(4, title: 'English -ss')), contains(SubtitleKind.signs));
    expect(classifySubtitle(track(5, title: 'Offices and assigned')), {SubtitleKind.standard});
    expect(classifySubtitle(track(6, title: 'Hindi', languageCode: 'hi')), {SubtitleKind.standard});
    expect(classifySubtitle(track(7, title: 'SDH')), contains(SubtitleKind.cc));
    expect(classifySubtitle(track(8, title: 'foreign')), contains(SubtitleKind.forced));
  });
  test('sidecar basename only and language code hi is not HI marker', () {
    expect(classifySubtitle(track(1, filePath: '/forced/Film.hi.srt', languageCode: 'hi')), {SubtitleKind.standard});
    expect(classifySubtitle(track(2, filePath: '/shows/Film.en.sdh.srt')), contains(SubtitleKind.cc));
    expect(classifySubtitle(track(3, filePath: '/shows/Film.en.forced.srt')), contains(SubtitleKind.forced));
    expect(classifySubtitle(track(4, filePath: '/shows/Film.en-ff.srt')), contains(SubtitleKind.forced));
    expect(classifySubtitle(track(5, filePath: '/shows/Film.en.hi.srt')), contains(SubtitleKind.cc));
    expect(classifySubtitle(track(6, filePath: '/shows/Signs.en.srt')), {SubtitleKind.standard});
  });
  test('server metadata survives parsing and track rebuilds', () {
    final plex = const PlexFileInfoStreamReader().toSubtitleTrack({
      'id': 42,
      'hearingImpaired': '1',
      'file': '/movie.en.sdh.srt',
    }, 1);
    expect(plex.hearingImpaired, isTrue);
    expect(plex.filePath, '/movie.en.sdh.srt');
    expect(plex.withSelected(true).withoutSidecarIdentity().hearingImpaired, isTrue);
    final jellyfin = const JellyfinFileInfoStreamReader().toSubtitleTrack({
      'Index': 1,
      'IsHearingImpaired': true,
      'Path': '/movie.en.srt',
    }, 1);
    expect(jellyfin.hearingImpaired, isTrue);
    expect(jellyfin.filePath, '/movie.en.srt');
  });
}
