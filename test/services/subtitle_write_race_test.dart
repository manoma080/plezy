import 'dart:async';

import 'package:drift/native.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/media/ids.dart';
import 'package:plezy/utils/active_client_scope.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/mpv/mpv.dart';

import '../test_helpers/backend_client_fixtures.dart';

void main() {
  test('queued subtitle writes are dropped after a profile switch', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    addTearDown(db.close);
    final server = ServerId('profile-switch');
    final scopeA = buildPlexProfileScopeId(serverId: server, profileId: 'a');
    final scopeB = buildPlexProfileScopeId(serverId: server, profileId: 'b');
    final started = Completer<void>();
    final release = Completer<void>();
    final writes = <String>[];
    final client = testPlexClient(
      serverId: server,
      profileScopeId: scopeA,
      token: 'token-a',
      handler: (request) async {
        if (request.url.path == '/') {
          return http.Response(
            '{"MediaContainer":{"machineIdentifier":"profile-switch"}}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path == '/media/providers') {
          return http.Response('{"MediaContainer":{}}', 200, headers: {'content-type': 'application/json'});
        }
        final id = request.url.queryParameters['subtitleStreamID']!;
        writes.add('$id:${request.headers['X-Plex-Token'] ?? request.headers['x-plex-token']}');
        if (id == '401') {
          started.complete();
          await release.future;
        }
        return http.Response('', 200);
      },
    );
    addTearDown(client.close);
    const endpoint = '/library/metadata/42';
    await client.cache.put(scopeA.cacheServerId, endpoint, {'profile': 'a'});
    await client.cache.put(scopeB.cacheServerId, endpoint, {'profile': 'b'});
    final first = client.selectSubtitleForPart(99, 401, ratingKey: '42');
    await started.future;
    final automatic = client.selectSubtitleForPart(99, 402, ratingKey: '42');
    final manual = client.selectStreams(99, subtitleStreamID: 0);
    await client.applyProfileUpdate(newToken: 'token-b', newProfileScopeId: scopeB);
    release.complete();
    // The server accepted the in-flight write, but its result is stale for UI
    // purposes after switching profiles. Its original cache still must expire.
    expect(await first, isFalse);
    expect(await automatic, isFalse);
    expect(await manual, isFalse);
    expect(writes, ['401:token-a']);
    expect(await client.cache.getIfFresh(scopeA.cacheServerId, endpoint, maxAge: const Duration(days: 1)), isNull);
    expect(await client.cache.getIfFresh(scopeB.cacheServerId, endpoint, maxAge: const Duration(days: 1)), {
      'profile': 'b',
    });
  });

  test('automatic choice is not carried over an enabled episode override', () {
    expect(
      subtitlePreferenceForItemChange(
        hasCommittedSelection: true,
        committedTrack: const SubtitleTrack(id: '1', language: 'eng'),
        nativeTrack: const SubtitleTrack(id: '1', language: 'eng'),
        automaticOverrideEnabled: true,
      ),
      isNull,
    );
  });

  test('a stale automatic intent cannot write after a later manual choice', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    addTearDown(db.close);
    final writes = <String>[];
    final client = testPlexClient(
      serverId: ServerId('stale-test'),
      handler: (request) async {
        writes.add(request.url.queryParameters['subtitleStreamID']!);
        return http.Response('', 200);
      },
    );
    addTearDown(client.close);
    final old = client.beginSubtitleIntent('42');
    await client.selectStreams(99, subtitleStreamID: 0);
    expect(await client.selectSubtitleForPart(99, 402, ratingKey: '42', generation: old), isFalse);
    expect(writes, ['0']);
  });

  test('writes on different parts serialize for allParts safety', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    addTearDown(db.close);
    final started = Completer<void>();
    final release = Completer<void>();
    final second = Completer<void>();
    final client = testPlexClient(
      serverId: ServerId('independent-parts'),
      handler: (request) async {
        if (request.url.path.endsWith('/99')) {
          started.complete();
          await release.future;
        } else {
          second.complete();
        }
        return http.Response('', 200);
      },
    );
    addTearDown(client.close);
    final first = client.selectSubtitleForPart(99, 402, ratingKey: '42');
    await started.future;
    final other = client.selectSubtitleForPart(100, 403, ratingKey: '43');
    final independent = await Future.any([
      second.future.then((_) => true),
      Future.delayed(const Duration(milliseconds: 100), () => false),
    ]);
    release.complete();
    await Future.wait([first, other]);
    expect(independent, isFalse);
  });

  test('unrelated item intent does not cancel an earlier burn selection', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    addTearDown(db.close);
    final client = testPlexClient(serverId: ServerId('item-isolation'), handler: (_) async => http.Response('', 200));
    addTearDown(client.close);
    final old = client.beginSubtitleIntent('42');
    client.beginSubtitleIntent('43');
    expect(await client.selectSubtitleForPart(99, 402, ratingKey: '42', generation: old), isTrue);
  });

  test('off-default snapshot does not supersede an active item intent', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    addTearDown(db.close);
    final client = testPlexClient(serverId: ServerId('off-snapshot'), handler: (_) async => http.Response('', 200));
    addTearDown(client.close);
    final active = client.beginSubtitleIntent('42');
    client.beginSubtitleIntent('42', supersede: false);
    expect(await client.selectSubtitleForPart(99, 402, ratingKey: '42', generation: active), isTrue);
  });

  test('manual allParts invalidates a delayed automatic sibling selection', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    addTearDown(db.close);
    final writes = <String>[];
    final client = testPlexClient(
      serverId: ServerId('sibling'),
      handler: (request) async {
        writes.add(request.url.queryParameters['subtitleStreamID']!);
        return http.Response('', 200);
      },
    );
    addTearDown(client.close);
    await client.selectSubtitleForPart(99, 401, ratingKey: '42');
    final automatic = client.beginSubtitleIntent('42');
    await client.selectStreams(99, subtitleStreamID: 0);
    expect(await client.selectSubtitleForPart(100, 402, ratingKey: '42', generation: automatic), isFalse);
    expect(writes, ['401', '0']);
  });

  test('an unrelated manual choice does not cancel an automatic selection', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    addTearDown(db.close);
    final client = testPlexClient(serverId: ServerId('manual-isolation'), handler: (_) async => http.Response('', 200));
    addTearDown(client.close);
    final automatic = client.beginSubtitleIntent('42');
    await client.selectStreams(100, subtitleStreamID: 0, ratingKey: '43');
    expect(await client.selectSubtitleForPart(99, 402, ratingKey: '42', generation: automatic), isTrue);
  });

  test('successful server selection survives cache invalidation failure', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    await db.customSelect('SELECT 1').get();
    await db.close();
    await expectLater(
      PlexApiCache.instance.invalidateFreshness(ServerId('cache-failure'), '/library/metadata/42'),
      throwsA(anything),
    );
    final client = testPlexClient(serverId: ServerId('cache-failure'), handler: (_) async => http.Response('', 200));
    addTearDown(client.close);
    expect(await client.selectSubtitleForPart(99, 402, ratingKey: '42'), isTrue);
  });

  test('delayed manual write takes priority over an automatic intent started while pending', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    addTearDown(db.close);
    final started = Completer<void>();
    final release = Completer<void>();
    final writes = <String>[];
    final client = testPlexClient(
      serverId: ServerId('delayed-manual'),
      handler: (request) async {
        final id = request.url.queryParameters['subtitleStreamID']!;
        writes.add(id);
        if (id == '0') {
          started.complete();
          await release.future;
        }
        return http.Response('', 200);
      },
    );
    addTearDown(client.close);
    final manual = client.selectStreams(99, subtitleStreamID: 0);
    await started.future;
    final token = client.beginSubtitleIntent('42');
    final automatic = client.selectSubtitleForPart(99, 402, ratingKey: '42', generation: token);
    release.complete();
    expect(await manual, isTrue);
    expect(await automatic, isFalse);
    expect(writes, ['0']);
  });

  test('later manual subtitle choice persists after an in-flight automatic write', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    addTearDown(db.close);
    final started = Completer<void>();
    final release = Completer<void>();
    var serverSelection = -1;
    final client = testPlexClient(
      serverId: ServerId('race-test'),
      handler: (request) async {
        final id = int.parse(request.url.queryParameters['subtitleStreamID']!);
        if (id == 402) {
          started.complete();
          await release.future;
        }
        serverSelection = id;
        return http.Response('', 200);
      },
    );
    addTearDown(client.close);
    final automatic = client.selectSubtitleForPart(99, 402, ratingKey: '42');
    await started.future;
    final manual = client.selectStreams(99, subtitleStreamID: 0);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    release.complete();
    await Future.wait([automatic, manual]);
    expect(serverSelection, 0);
  });
}
