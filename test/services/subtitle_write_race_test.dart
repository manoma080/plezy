import 'dart:async';

import 'package:drift/native.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/media/ids.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/mpv/mpv.dart';

import '../test_helpers/backend_client_fixtures.dart';

void main() {
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
    final old = client.beginSubtitleIntent();
    await client.selectStreams(99, subtitleStreamID: 0);
    expect(await client.selectSubtitleForPart(99, 402, ratingKey: '42', generation: old), isFalse);
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
