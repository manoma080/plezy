import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/utils/active_client_scope.dart';

import '../test_helpers/backend_client_fixtures.dart';

void main() {
  test('first-use manual allParts defeats delayed automatic sibling', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    addTearDown(db.close);
    final started = Completer<void>();
    final release = Completer<void>();
    final writes = <String>[];
    final client = testPlexClient(
      serverId: ServerId('first-use-sibling'),
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
    final generation = client.beginSubtitleIntent('42');
    final manual = client.selectStreams(99, subtitleStreamID: 0);
    await started.future;
    final automatic = client.selectSubtitleForPart(100, 402, ratingKey: '42', generation: generation);
    release.complete();
    expect(await manual, isTrue);
    expect(await automatic, isFalse);
    expect(writes, ['0']);
  });

  test('known manual item cancels only its siblings across profiles', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    addTearDown(db.close);
    final server = ServerId('first-use-cross-profile');
    final writes = <String>[];
    final started = Completer<void>();
    final release = Completer<void>();
    final a = testPlexClient(
      serverId: server,
      profileScopeId: buildPlexProfileScopeId(serverId: server, profileId: 'a'),
      handler: (request) async {
        writes.add(request.url.queryParameters['subtitleStreamID']!);
        started.complete();
        await release.future;
        return http.Response('', 200);
      },
    );
    final b = testPlexClient(
      serverId: server,
      profileScopeId: buildPlexProfileScopeId(serverId: server, profileId: 'b'),
      handler: (request) async {
        writes.add(request.url.queryParameters['subtitleStreamID']!);
        return http.Response('', 200);
      },
    );
    addTearDown(a.close);
    addTearDown(b.close);
    final sibling = b.beginSubtitleIntent('42');
    final unrelated = b.beginSubtitleIntent('43');
    final manual = a.selectStreams(99, subtitleStreamID: 0, ratingKey: '42');
    await started.future;
    final pendingSibling = b.selectSubtitleForPart(100, 402, ratingKey: '42', generation: sibling);
    final pendingOther = b.selectSubtitleForPart(101, 403, ratingKey: '43', generation: unrelated);
    release.complete();
    expect(await manual, isTrue);
    expect(await pendingSibling, isFalse);
    expect(await pendingOther, isTrue);
    expect(writes, ['0', '403']);
  });
}
