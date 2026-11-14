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
import 'package:plezy/media/media_item.dart';
import 'package:plezy/providers/account_preferences_controller.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/models/download_models.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/screens/media_detail_screen.dart';
import 'package:plezy/services/plex_api_cache.dart';
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
  @override
  AccountPreferences? get activePreferences => const AccountPreferences(preferredSubtitleLanguage: 'en');
  @override
  Future<void> ensureActiveLoaded() async {}
}

void main() {
  testWidgets('opening a Plex movie saves its preferred subtitle', (tester) async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.subtitlePreferenceOverride, SubtitlePreferenceOverride.cc);
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
    final servers = testMultiServer(clients: [client]);
    final preferences = _Preferences();
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
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(writes, hasLength(1));
    expect(writes.single.url.path, '/library/parts/99');
    expect(writes.single.url.queryParameters['subtitleStreamID'], '402');
  });
}
