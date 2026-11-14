import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/account_preferences.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_browser_dialect.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/providers/account_preferences_controller.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/models/download_models.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/screens/media_detail_screen.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/jellyfin_api_cache.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:provider/provider.dart';

import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/profile_navigation.dart';

class _Downloads extends ChangeNotifier implements DownloadProvider {
  @override
  DownloadProgress? getProgress(String globalKey) => null;
  @override
  bool isQueueing(String globalKey) => false;
  @override
  bool isDownloaded(String globalKey) => false;
  @override
  String syncRuleKeyForClient(MediaServerClient client, String ratingKey, {ServerId? serverId}) => ratingKey;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Preferences extends AccountPreferencesController {
  _Preferences({this.gate});
  final Completer<void>? gate;
  @override
  AccountPreferences? get activePreferences => const AccountPreferences(preferredSubtitleLanguage: 'en');
  @override
  Future<void> ensureActiveLoaded() async {
    if (gate != null) await gate!.future;
  }
}

void main() {
  for (final scenario in [
    'success',
    'no match',
    'already selected',
    'override off',
    'write failure',
    'navigate away',
  ]) {
    testWidgets('Plex detail subtitle: $scenario', (tester) async {
      resetSharedPreferencesForTest();
      SettingsService.resetForTesting();
      final settings = await SettingsService.getInstance();
      await settings.write(
        SettingsService.subtitlePreferenceOverride,
        scenario == 'override off' ? SubtitlePreferenceOverride.off : SubtitlePreferenceOverride.cc,
      );
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      PlexApiCache.initialize(db);
      final writes = <http.Request>[];
      final requests = <http.Request>[];
      final gate = scenario == 'navigate away' ? Completer<void>() : null;
      final client = testPlexClient(
        serverId: ServerId('server-id'),
        handler: (request) async {
          requests.add(request);
          if (request.method == 'PUT') {
            writes.add(request);
            return http.Response('', scenario == 'write failure' ? 500 : 200);
          }
          return http.Response(
            jsonEncode({
              'MediaContainer': {
                'Metadata': [
                  {
                    'ratingKey': '42',
                    'type': 'movie',
                    'title': 'Movie',
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
                              {
                                'streamType': 3,
                                'id': 401,
                                'codec': 'srt',
                                'languageCode': 'eng',
                                'selected': scenario != 'already selected',
                              },
                              {
                                'streamType': 3,
                                'id': 402,
                                'codec': 'srt',
                                'languageCode': scenario == 'no match' ? 'fra' : 'eng',
                                'title': 'SDH',
                                'selected': scenario == 'already selected',
                              },
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
      final servers = testMultiServer(clients: [client]);
      final preferences = _Preferences(gate: gate);
      addTearDown(() async {
        preferences.dispose();
        client.close();
        await db.close();
      });
      final movie = MediaItem.plex(id: '42', kind: MediaKind.movie, title: 'Movie', serverId: ServerId('server-id'));
      await tester.pumpWidget(
        TranslationProvider(
          child: MultiProvider(
            providers: [
              ChangeNotifierProvider<MultiServerProvider>.value(value: servers.provider),
              ChangeNotifierProvider<AccountPreferencesController>.value(value: preferences),
              ChangeNotifierProvider<DownloadProvider>(create: (_) => _Downloads()),
            ],
            child: MaterialApp(
              theme: monoTheme(MonoPalette.dark),
              home: withProfileNavigationScope(child: MediaDetailScreen(metadata: movie)),
            ),
          ),
        ),
      );
      if (gate != null) {
        for (var i = 0; i < 10; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
          await tester.pump(const Duration(milliseconds: 50));
        }
        final context = tester.element(find.byType(MediaDetailScreen));
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Next route'))));
        await tester.pumpAndSettle();
        gate.complete();
      }
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      final expectWrite = scenario == 'success' || scenario == 'write failure';
      expect(writes, hasLength(expectWrite ? 1 : 0));
      if (expectWrite) {
        expect(writes.single.url.path, '/library/parts/99');
        expect(writes.single.url.queryParameters['subtitleStreamID'], '402');
        expect(writes.single.url.queryParameters['allParts'], '0');
      }
      final playbackReads = requests
          .where(
            (request) =>
                request.url.path == '/library/metadata/42' && request.url.queryParameters['includeStreams'] == '1',
          )
          .length;
      if (scenario == 'success') expect(playbackReads, greaterThanOrEqualTo(3));
      if (scenario == 'navigate away') expect(find.text('Next route'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  for (final dialect in MediaBrowserDialect.values) {
    testWidgets('$dialect detail does not write Plex subtitle selection', (tester) async {
      resetSharedPreferencesForTest();
      SettingsService.resetForTesting();
      final settings = await SettingsService.getInstance();
      await settings.write(SettingsService.subtitlePreferenceOverride, SubtitlePreferenceOverride.cc);
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      JellyfinApiCache.initialize(db);
      addTearDown(db.close);
      final requests = <http.Request>[];
      final client = testJellyfinClient(
        connection: testJellyfinConnection(dialect: dialect),
        handler: (request) async {
          requests.add(request);
          return http.Response(
            jsonEncode({'Id': '42', 'Name': 'Movie', 'Type': 'Movie', 'Items': [], 'TotalRecordCount': 0}),
            200,
            headers: {'content-type': 'application/json'},
          );
        },
      );
      final servers = testMultiServer(clients: [client]);
      final preferences = _Preferences();
      addTearDown(() {
        preferences.dispose();
        client.close();
      });
      final movie = MediaItem.jellyfin(
        id: '42',
        kind: MediaKind.movie,
        title: 'Movie',
        serverId: client.serverId,
        dialect: dialect,
      );
      await tester.pumpWidget(
        TranslationProvider(
          child: MultiProvider(
            providers: [
              ChangeNotifierProvider<MultiServerProvider>.value(value: servers.provider),
              ChangeNotifierProvider<AccountPreferencesController>.value(value: preferences),
              ChangeNotifierProvider<DownloadProvider>(create: (_) => _Downloads()),
            ],
            child: MaterialApp(
              theme: monoTheme(MonoPalette.dark),
              home: withProfileNavigationScope(child: MediaDetailScreen(metadata: movie)),
            ),
          ),
        ),
      );
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(requests, isNotEmpty);
      expect(requests.where((r) => r.method != 'GET'), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}
