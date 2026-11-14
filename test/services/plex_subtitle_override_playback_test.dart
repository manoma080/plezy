import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/models/transcode_quality_preset.dart';
import 'package:plezy/services/subtitle_preference.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/settings_service.dart';

import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/media_items.dart';

void main() {
  for (final kind in [MediaKind.movie, MediaKind.clip, MediaKind.photo, MediaKind.track]) {
    test('automatic subtitle override respects playback scope for ${kind.name}', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      PlexApiCache.initialize(db);
      final writes = <http.Request>[];
      final client = testPlexClient(
        serverId: ServerId('server-id'),
        handler: (request) async {
          if (request.method == 'PUT') {
            writes.add(request);
            return http.Response('', 200);
          }
          return http.Response(
            jsonEncode({
              'MediaContainer': {
                'Metadata': [
                  {
                    'ratingKey': '42',
                    'type': kind.id,
                    'title': 'Item',
                    'Media': [
                      {
                        'id': 7,
                        'container': 'mkv',
                        'Part': [
                          {
                            'id': 99,
                            'key': '/library/parts/99/file.mkv',
                            'Stream': [
                              {'streamType': 1, 'id': 300, 'codec': 'h264'},
                              {'streamType': 3, 'id': 401, 'codec': 'srt', 'languageCode': 'eng', 'selected': true},
                              {'streamType': 3, 'id': 402, 'codec': 'srt', 'languageCode': 'eng', 'title': 'SDH'},
                            ],
                          },
                        ],
                      },
                    ],
                  },
                ],
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        },
      );
      addTearDown(() async {
        client.close();
        await db.close();
      });
      final result = await client.getPlaybackInitialization(
        PlaybackInitializationOptions(
          metadata: testMediaItem(id: '42', backend: MediaBackend.plex, kind: kind, serverId: 'server-id'),
          selectedMediaIndex: 0,
          subtitleOverride: SubtitlePreferenceOverride.cc,
          subtitleOverrideLanguage: 'en',
        ),
      );
      expect(writes.length, kind == MediaKind.movie ? 1 : 0);
      expect(result.mediaInfo!.subtitleTracks.where((s) => s.selected).single.id, kind == MediaKind.movie ? 402 : 401);
    });
  }

  test('playback saves and selects matching subtitle on the chosen part', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    final writes = <http.Request>[];
    final client = testPlexClient(
      serverId: ServerId('server-id'),
      handler: (request) async {
        if (request.method == 'PUT') {
          writes.add(request);
          return http.Response('', 200);
        }
        return http.Response(
          jsonEncode({
            'MediaContainer': {
              'Metadata': [
                {
                  'ratingKey': '42',
                  'type': 'episode',
                  'title': 'Episode',
                  'Media': [
                    {
                      'id': 7,
                      'container': 'mkv',
                      'Part': [
                        {
                          'id': 99,
                          'key': '/library/parts/99/file.mkv',
                          'Stream': [
                            {'streamType': 1, 'id': 300, 'codec': 'h264'},
                            {'streamType': 3, 'id': 401, 'codec': 'srt', 'languageCode': 'eng', 'selected': true},
                            {'streamType': 3, 'id': 402, 'codec': 'srt', 'languageCode': 'eng', 'title': 'SDH'},
                          ],
                        },
                      ],
                    },
                  ],
                },
              ],
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      },
    );
    addTearDown(() async {
      client.close();
      await db.close();
    });
    final result = await client.getPlaybackInitialization(
      PlaybackInitializationOptions(
        metadata: testMediaItem(id: '42', backend: MediaBackend.plex, kind: MediaKind.episode, serverId: 'server-id'),
        selectedMediaIndex: 0,
        subtitleOverride: SubtitlePreferenceOverride.cc,
        subtitleOverrideLanguage: 'en',
      ),
    );
    expect(writes, hasLength(1));
    expect(writes.single.url.path, '/library/parts/99');
    expect(writes.single.url.queryParameters['allParts'], '0');
    expect(writes.single.url.queryParameters['subtitleStreamID'], '402');
    expect(result.mediaInfo!.subtitleTracks.where((s) => s.selected).single.id, 402);
  });
  test('manual off wins over the automatic preference', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    final writes = <http.Request>[];
    final client = testPlexClient(
      serverId: ServerId('server-id'),
      handler: (request) async {
        if (request.method == 'PUT') {
          writes.add(request);
          return http.Response('', 200);
        }
        return http.Response(
          jsonEncode({
            'MediaContainer': {
              'Metadata': [
                {
                  'ratingKey': '42',
                  'type': 'episode',
                  'title': 'Episode',
                  'Media': [
                    {
                      'id': 7,
                      'container': 'mkv',
                      'Part': [
                        {
                          'id': 99,
                          'key': '/library/parts/99/file.mkv',
                          'Stream': [
                            {'streamType': 1, 'id': 300, 'codec': 'h264'},
                            {'streamType': 3, 'id': 401, 'codec': 'srt', 'languageCode': 'eng', 'selected': true},
                            {'streamType': 3, 'id': 402, 'codec': 'srt', 'languageCode': 'eng', 'title': 'SDH'},
                          ],
                        },
                      ],
                    },
                  ],
                },
              ],
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      },
    );
    addTearDown(() async {
      client.close();
      await db.close();
    });
    final result = await client.getPlaybackInitialization(
      PlaybackInitializationOptions(
        metadata: testMediaItem(id: '42', backend: MediaBackend.plex, kind: MediaKind.episode, serverId: 'server-id'),
        selectedMediaIndex: 0,
        subtitleOverride: SubtitlePreferenceOverride.cc,
        subtitleOverrideLanguage: 'en',
        preferredSubtitleTrack: const SubtitlePreference.off(),
      ),
    );
    expect(writes, isEmpty);
    expect(result.mediaInfo!.subtitleTracks.where((s) => s.selected).single.id, 401);
  });
  test('no matching language leaves the server choice unchanged', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    final writes = <http.Request>[];
    final client = testPlexClient(
      serverId: ServerId('server-id'),
      handler: (request) async {
        if (request.method == 'PUT') {
          writes.add(request);
          return http.Response('', 200);
        }
        return http.Response(
          jsonEncode({
            'MediaContainer': {
              'Metadata': [
                {
                  'ratingKey': '42',
                  'type': 'episode',
                  'title': 'Episode',
                  'Media': [
                    {
                      'id': 7,
                      'container': 'mkv',
                      'Part': [
                        {
                          'id': 99,
                          'key': '/library/parts/99/file.mkv',
                          'Stream': [
                            {'streamType': 1, 'id': 300, 'codec': 'h264'},
                            {'streamType': 3, 'id': 401, 'codec': 'srt', 'languageCode': 'eng', 'selected': true},
                            {'streamType': 3, 'id': 402, 'codec': 'srt', 'languageCode': 'eng', 'title': 'SDH'},
                          ],
                        },
                      ],
                    },
                  ],
                },
              ],
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      },
    );
    addTearDown(() async {
      client.close();
      await db.close();
    });
    final result = await client.getPlaybackInitialization(
      PlaybackInitializationOptions(
        metadata: testMediaItem(id: '42', backend: MediaBackend.plex, kind: MediaKind.episode, serverId: 'server-id'),
        selectedMediaIndex: 0,
        subtitleOverride: SubtitlePreferenceOverride.cc,
        subtitleOverrideLanguage: 'fr',
      ),
    );
    expect(writes, isEmpty);
    expect(result.mediaInfo!.subtitleTracks.where((s) => s.selected).single.id, 401);
  });
  test('transcode burns the overridden stream on the selected part', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    final writes = <http.Request>[];
    final client = testPlexClient(
      serverId: ServerId('server-id'),
      handler: (request) async {
        if (request.url.path == '/video/:/transcode/universal/decision') {
          expect(request.url.queryParameters['subtitles'], 'burn');
          return http.Response(
            jsonEncode({
              'MediaContainer': {
                'transcodeDecisionCode': 1001,
                'Metadata': [
                  {
                    'Media': [
                      {'container': 'mp4', 'protocol': 'hls', 'selected': true},
                    ],
                  },
                ],
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'PUT') {
          writes.add(request);
          return http.Response('', 200);
        }
        return http.Response(
          jsonEncode({
            'MediaContainer': {
              'Metadata': [
                {
                  'ratingKey': '42',
                  'type': 'episode',
                  'title': 'Episode',
                  'Media': [
                    {
                      'id': 7,
                      'container': 'mkv',
                      'Part': [
                        {
                          'id': 99,
                          'key': '/library/parts/99/file.mkv',
                          'Stream': [
                            {'streamType': 1, 'id': 300, 'codec': 'h264'},
                            {'streamType': 3, 'id': 401, 'codec': 'srt', 'languageCode': 'eng', 'selected': true},
                            {'streamType': 3, 'id': 402, 'codec': 'srt', 'languageCode': 'eng', 'title': 'SDH'},
                          ],
                        },
                      ],
                    },
                  ],
                },
              ],
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      },
    );
    addTearDown(() async {
      client.close();
      await db.close();
    });
    final result = await client.getPlaybackInitialization(
      PlaybackInitializationOptions(
        metadata: testMediaItem(id: '42', backend: MediaBackend.plex, kind: MediaKind.episode, serverId: 'server-id'),
        selectedMediaIndex: 0,
        subtitleOverride: SubtitlePreferenceOverride.cc,
        subtitleOverrideLanguage: 'en',
        qualityPreset: TranscodeQualityPreset.p720_3mbps,
        sessionIdentifier: 'session',
        transcodeSessionId: 'transcode',
      ),
    );
    expect(result.isTranscoding, isTrue);
    expect(writes, hasLength(2));
    expect(
      writes.every(
        (r) => r.url.queryParameters['allParts'] == '0' && r.url.queryParameters['subtitleStreamID'] == '402',
      ),
      isTrue,
    );
    expect(writes.first.url.path, '/library/parts/99');
    expect(writes.first.url.queryParameters['allParts'], '0');
    expect(writes.first.url.queryParameters['subtitleStreamID'], '402');
    expect(result.mediaInfo!.subtitleTracks.where((s) => s.selected).single.id, 402);
  });
}
