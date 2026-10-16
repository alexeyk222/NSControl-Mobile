import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/data/trip_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const wall = '2026-10-15T10:00:00Z';

void main() {
  late TripRepository repository;
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    repository = await TripRepository.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    await repository.insertTrip({'id': 'trip', 'started_at': wall});
    await repository.insertSession({
      'id': 'session',
      'trip_id': 'trip',
      'started_at': wall,
      'settings_json': {'eyeThreshold': 0.4},
      'calibration_json': {'pitch': 1.2},
      'algorithm_version': '1',
    });
  });
  tearDown(() async => repository.close());

  Row event(String id, {String type = 'eyes', String session = 'session'}) => {
    'id': id,
    'trip_id': 'trip',
    'session_id': session,
    'type': type,
    'channel': type,
    'started_us': 100000,
    'threshold_us': 1600000,
    'started_at': wall,
    'threshold_at': '2026-10-15T10:00:01.500Z',
  };

  Future<void> transition(String id, String channel, int at, bool available) =>
      repository.insertTransition({
        'id': id,
        'trip_id': 'trip',
        'session_id': 'session',
        'channel': channel,
        'at_us': at,
        'state': available ? 'normal' : 'unavailable',
        'available': available ? 1 : 0,
      });

  test(
    'sleep refresh deduplicates by provider key and preserves local id',
    () async {
      await repository.upsertSleepRecord({
        'id': 'sleep1',
        'source': 'HealthKit',
        'provider_id': 'provider1',
        'started_at': '2026-10-14T22:00:00+03:00',
        'ended_at': wall,
        'duration_seconds': 20000,
      });
      await repository.upsertSleepRecord({
        'id': 'different',
        'source': 'HealthKit',
        'provider_id': 'provider1',
        'started_at': '2026-10-14T22:00:00+03:00',
        'ended_at': wall,
        'duration_seconds': 22000,
      });
      final records = await repository.listSleepRecords();
      expect(records, hasLength(1));
      expect(records.single['id'], 'sleep1');
      expect(records.single['duration_seconds'], 22000);
      expect(
        DateTime.parse(records.single['started_at'] as String),
        DateTime.utc(2026, 10, 14, 19),
      );
    },
  );

  test(
    'UTC sorting preserves microsecond boundaries and accepts native nanoseconds',
    () async {
      for (final pair in [
        ('later', '2026-10-14T22:00:00.000001Z'),
        ('earlier', '2026-10-14T22:00:00.000Z'),
      ]) {
        await repository.upsertSleepRecord({
          'id': pair.$1,
          'source': 'native',
          'provider_id': pair.$1,
          'started_at': pair.$2,
          'ended_at': wall,
        });
      }
      expect((await repository.listSleepRecords()).map((r) => r['id']), [
        'earlier',
        'later',
      ]);
      await repository.upsertSleepRecord({
        'id': 'nano',
        'source': 'native',
        'provider_id': 'nano',
        'started_at': '2026-10-14T23:00:00.123456789Z',
        'ended_at': wall,
        'source_modified_at': '2026-10-15T01:00:00.123456789Z',
      });
      expect(
        DateTime.parse(
          (await repository.listSleepRecords()).last['started_at'] as String,
        ).microsecond,
        456,
      );
    },
  );

  test(
    'sleep stage groups replace atomically and reject cross-source rows',
    () async {
      Row stage(String id, String start, String end) => {
        'id': id,
        'source': 'HealthConnect',
        'provider_id': 'night',
        'started_at': start,
        'ended_at': end,
        'device_json': {'is_watch': true, 'manufacturer': 'Garmin'},
        'source_modified_at': wall,
      };
      await repository.replaceSleepRecords(
        source: 'HealthConnect',
        providerId: 'night',
        records: [
          stage('a', '2026-10-14T21:00:00Z', '2026-10-14T23:00:00Z'),
          stage('b', '2026-10-15T00:00:00Z', '2026-10-15T03:00:00Z'),
        ],
      );
      expect(await repository.listSleepRecords(), hasLength(2));
      await expectLater(
        repository.replaceSleepRecords(
          source: 'HealthConnect',
          providerId: 'night',
          records: [
            stage('c', '2026-10-14T21:00:00Z', '2026-10-15T03:00:00Z'),
            {
              ...stage('invalid', wall, '2026-10-15T11:00:00Z'),
              'source': 'other',
            },
          ],
        ),
        throwsArgumentError,
      );
      expect((await repository.listSleepRecords()).map((r) => r['id']), [
        'a',
        'b',
      ]);
      await repository.replaceSleepRecords(
        source: 'HealthConnect',
        providerId: 'night',
        records: [stage('new', '2026-10-14T21:00:00Z', '2026-10-15T03:00:00Z')],
      );
      expect((await repository.listSleepRecords()).single['id'], 'new');
    },
  );

  test(
    'complete sleep window reconciliation preserves outside history and other sources',
    () async {
      Row record(String id, String source, String start, String end) => {
        'id': id,
        'source': source,
        'provider_id': id,
        'started_at': start,
        'ended_at': end,
      };
      await repository.upsertSleepRecord(
        record('old', 'watch', '2026-10-14T22:00:00Z', wall),
      );
      await repository.upsertSleepRecord(
        record(
          'history',
          'watch',
          '2026-10-01T22:00:00Z',
          '2026-10-02T06:00:00Z',
        ),
      );
      await repository.upsertSleepRecord(
        record('other', 'manual', '2026-10-14T22:00:00Z', wall),
      );
      await expectLater(
        repository.reconcileSleepWindow(
          source: 'watch',
          startedAt: '2026-10-14T00:00:00Z',
          endedAt: wall,
          records: [],
          completeSnapshot: false,
        ),
        throwsArgumentError,
      );
      expect(await repository.listSleepRecords(), hasLength(3));
      await repository.reconcileSleepWindow(
        source: 'watch',
        startedAt: '2026-10-14T00:00:00Z',
        endedAt: wall,
        records: [record('new', 'watch', '2026-10-14T23:00:00Z', wall)],
        completeSnapshot: true,
      );
      expect(
        (await repository.listSleepRecords()).map((r) => r['id']).toSet(),
        {'history', 'other', 'new'},
      );
    },
  );

  test(
    'disk reopen retains data and explicit recovery terminates abandoned session',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'nscontrol-storage-',
      );
      final path = '${directory.path}/audit.db';
      try {
        var disk = await TripRepository.open(
          factory: databaseFactoryFfi,
          path: path,
        );
        await disk.insertTrip({'id': 'persisted', 'started_at': wall});
        await disk.insertSession({
          'id': 'open',
          'trip_id': 'persisted',
          'started_at': wall,
        });
        await disk.close();
        disk = await TripRepository.open(
          factory: databaseFactoryFfi,
          path: path,
        );
        expect((await disk.listTrips()).single['id'], 'persisted');
        expect(await disk.recoverInterrupted(), 1);
        expect((await disk.listSessions()).single['status'], 'interrupted');
        await disk.close();
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'sensitive recommendations are excluded as whole rows even with false caller flags',
    () async {
      await repository.insertRecommendation({
        'id': 'self',
        'created_at': wall,
        'action': 'rest',
        'rules_version': '1',
        'reasons_json': ['self_report'],
        'inputs_json': {'selfAssessment': 'sleepy'},
        'contains_self_assessment': 0,
      });
      await repository.insertRecommendation({
        'id': 'safe-eye',
        'created_at': wall,
        'action': 'rest',
        'rules_version': '1',
        'reasons_json': ['eyes'],
        'inputs_json': {'eyeEvent': true},
      });
      final public = await repository.exportRecommendationsCsv();
      expect(public, contains('safe-eye'));
      expect(public, isNot(contains('self_report')));
      expect(public, isNot(contains('sleepy')));
      expect(
        await repository.exportRecommendationsCsv(includeSensitive: true),
        contains('sleepy'),
      );
    },
  );

  test(
    'calendar fields reject normalized invalid days and missing zones',
    () async {
      await expectLater(
        repository.insertTrip({
          'id': 'bad-day',
          'started_at': '2026-02-30T10:00:00Z',
        }),
        throwsArgumentError,
      );
      await expectLater(
        repository.insertTrip({
          'id': 'bad-zone',
          'started_at': '2026-02-28T10:00:00',
        }),
        throwsArgumentError,
      );
    },
  );

  test(
    'relationships reject foreign sessions and immutable event onset',
    () async {
      await repository.insertTrip({'id': 'other', 'started_at': wall});
      await repository.insertSession({
        'id': 'other-session',
        'trip_id': 'other',
        'started_at': wall,
      });
      await expectLater(
        repository.upsertEvent(event('bad', session: 'other-session')),
        throwsA(anything),
      );
      await repository.upsertEvent(event('event'));
      await repository.upsertEvent({
        ...event('event'),
        'alert_requested_us': 1620000,
      });
      expect(
        (await repository.listEvents()).single['alert_requested_us'],
        1620000,
      );
      await expectLater(
        repository.upsertEvent({...event('event'), 'started_us': 0}),
        throwsArgumentError,
      );
      expect((await repository.listEvents()).single['started_us'], 100000);
      await expectLater(
        repository.upsertEvent({...event('negative'), 'started_us': -1}),
        throwsArgumentError,
      );
      await expectLater(
        repository.upsertEvent({...event('backwards'), 'ended_us': 100}),
        throwsArgumentError,
      );
    },
  );

  test(
    'session heartbeat persists stable observation and diagnostic recovery evidence',
    () async {
      await repository.checkpointSession(
        'session',
        atUs: 60000000,
        diagnostics: {
          'completed_analyses': 650,
          'usable_eyes': 640,
          'usable_head': 648,
          'gap_count': 0,
          'build_mode': 'release',
        },
      );
      await repository.checkpointSession('session', atUs: 61000000);
      await repository.recoverInterrupted(recoveredAt: '2026-10-15T11:00:00Z');
      final session = (await repository.listSessions()).single;
      expect(session['ended_us'], 61000000);
      expect(
        jsonDecode(session['diagnostics_json'] as String)['completed_analyses'],
        650,
      );
      expect(
        await repository.exportGeneralCsv(),
        contains('completed_analyses'),
      );
      await expectLater(
        repository.checkpointSession('session', atUs: 62000000),
        throwsStateError,
      );
    },
  );

  test(
    'recovery interrupts at last known monotonic point without inventing crash time',
    () async {
      await repository.upsertEvent(event('event'));
      await transition('late', 'eyes', 2500000, true);
      final recovered = await repository.recoverInterrupted(
        recoveredAt: '2026-10-15T11:00:00Z',
      );
      expect(recovered, 1);
      final session = (await repository.listSessions()).single;
      expect(session['status'], 'interrupted');
      expect(session['ended_us'], 2500000);
      expect(session['ended_at'], isNull);
      expect(session['journal_incomplete'], 1);
      expect(jsonDecode(session['settings_json'] as String), {
        'eyeThreshold': 0.4,
      });
      final recoveredEvent = (await repository.listEvents()).single;
      expect(recoveredEvent['end_reason'], 'process_interrupted');
      expect(recoveredEvent['ended_us'], 2500000);
      expect(await repository.recoverInterrupted(), 0);
    },
  );

  test(
    'general CSV never leaks recommendation content or sleep snapshots',
    () async {
      await repository.insertRecommendation({
        'id': 'rec',
        'trip_id': 'trip',
        'session_id': 'session',
        'created_at': wall,
        'action': 'Секретная рекомендация',
        'rules_version': '1',
        'reasons_json': ['Секретный сон'],
        'inputs_json': {
          'sleep': {'minutes': 412},
          'selfAssessment': 'sleepy',
        },
      });
      await repository.upsertDelivery({
        'id': 'delivery',
        'message_id': 'message',
        'trip_id': 'trip',
        'session_id': 'session',
        'recommendation_id': 'rec',
        'status': 'received',
      });
      final general = await repository.exportGeneralCsv();
      for (final secret in [
        'Секрет',
        'minutes',
        'selfAssessment',
        'sleepy',
        '412',
      ]) {
        expect(general, isNot(contains(secret)));
      }
      expect(general, contains('wearable_delivery'));
      expect(general, contains('eyeThreshold'));
      expect(
        await repository.exportRecommendationsCsv(),
        isNot(contains('Секрет')),
      );
      final sensitive = await repository.exportRecommendationsCsv(
        includeSensitive: true,
      );
      expect(sensitive, contains('Секретная рекомендация'));
      expect(sensitive, contains('412'));
    },
  );

  test(
    'CSV escapes multiline text and formula cells without corrupting negative numerics',
    () async {
      await transition('quote', 'eyes', 0, false);
      await repository.insertTransition({
        'id': '=danger',
        'trip_id': 'trip',
        'session_id': 'session',
        'channel': 'head',
        'at_us': 1,
        'state': 'unavailable',
        'available': 0,
        'reason': 'a,"b"\nc',
      });
      final csv = await repository.exportGeneralCsv();
      expect(csv, contains("'=danger"));
      expect(csv, contains('"a,""b""\nc"'));
      expect(csv, contains('\r\n'));
      expect(csv, isNot(contains('null')));
    },
  );

  test(
    'delete sleep removes snapshots, dependent recommendations and their deliveries',
    () async {
      await repository.setSetting('sleep.completeness', {
        'source': 'HealthKit',
        'hours': 7,
      });
      await repository.setSetting('camera', {'fps': 10});
      await repository.insertRecommendation({
        'id': 'sleep-rec',
        'created_at': wall,
        'action': 'rest',
        'rules_version': '1',
        'inputs_json': {'sleepMinutes': 300},
        'contains_sleep': 0,
      });
      await repository.insertRecommendation({
        'id': 'eye-rec',
        'created_at': wall,
        'action': 'rest',
        'rules_version': '1',
        'reasons_json': ['eyes'],
        'inputs_json': {'eyeEvent': true},
      });
      await repository.upsertDelivery({
        'id': 'sd',
        'message_id': 'sm',
        'recommendation_id': 'sleep-rec',
        'status': 'sent',
      });
      await repository.deleteSleep();
      expect(await repository.getSetting('sleep.completeness'), isNull);
      expect(await repository.getSetting('camera'), {'fps': 10});
      expect((await repository.listRecommendations()).map((r) => r['id']), [
        'eye-rec',
      ]);
      expect(await repository.listDeliveries(), isEmpty);
    },
  );

  test(
    'trip delete cascades audit children but preserves independent sleep',
    () async {
      await repository.upsertEvent(event('event'));
      await transition('transition', 'both', 0, true);
      await repository.insertRecommendation({
        'id': 'r',
        'trip_id': 'trip',
        'session_id': 'session',
        'created_at': wall,
        'action': 'rest',
        'rules_version': '1',
      });
      await repository.upsertDelivery({
        'id': 'd',
        'message_id': 'm',
        'trip_id': 'trip',
        'session_id': 'session',
        'event_id': 'event',
        'status': 'sent',
      });
      await repository.upsertSleepRecord({
        'id': 'sleep',
        'source': 'HealthKit',
        'provider_id': 'p',
        'started_at': '2026-10-14T21:00:00Z',
        'ended_at': wall,
      });
      await repository.deleteTrip('trip');
      expect(await repository.listTrips(), isEmpty);
      expect(await repository.listSessions(), isEmpty);
      expect(await repository.listEvents(), isEmpty);
      expect(await repository.listTransitions(), isEmpty);
      expect(await repository.listDeliveries(), isEmpty);
      expect(await repository.listRecommendations(), isEmpty);
      expect(await repository.listSleepRecords(), hasLength(1));
    },
  );

  test(
    'summary intersects unavailable intervals without double counting',
    () async {
      await transition('zero', 'both', 0, true);
      await transition('eye-down', 'eyes', 2000000, false);
      await transition('head-down', 'head', 4000000, false);
      await transition('eye-still-down', 'eyes', 5000000, false);
      await transition('eye-up', 'eyes', 7000000, true);
      await transition('head-up', 'head', 8000000, true);
      await repository.upsertEvent(event('eyes'));
      await repository.upsertEvent(event('head', type: 'head'));
      await repository.insertRecommendation({
        'id': 'rec',
        'trip_id': 'trip',
        'created_at': wall,
        'action': 'rest',
        'rules_version': '1',
      });
      await repository.endSession(
        'session',
        endedAt: '2026-10-15T10:00:10Z',
        endedUs: 10000000,
      );
      final summary = await repository.tripSummary('trip');
      expect(summary['observation_us'], 10000000);
      expect(summary['event_counts'], {'eyes': 1, 'head': 1});
      expect(summary['recommendation_count'], 1);
      expect(summary['unavailable_us'], {
        'eyes': 5000000,
        'head': 4000000,
        'both': 3000000,
      });
      expect(summary['unavailable_fraction'], {
        'eyes': 0.5,
        'head': 0.4,
        'both': 0.3,
      });
      expect(summary['journal_incomplete'], false);
    },
  );

  test(
    'missing transitions are unknown and empty duration has undefined fractions',
    () async {
      var summary = await repository.tripSummary('trip');
      expect((summary['unavailable_fraction'] as Map)['both'], isNull);
      await repository.markJournalIncomplete('trip', sessionId: 'session');
      summary = await repository.tripSummary(
        'trip',
        ongoingSessionEndsUs: {'session': 100},
      );
      expect(summary['unavailable_us'], {
        'eyes': 100,
        'head': 100,
        'both': 100,
      });
      expect(summary['journal_incomplete'], true);
    },
  );

  test('summary takes the latest cumulative vigilance history', () async {
    await repository.checkpointSession(
      'session',
      atUs: 120000000,
      diagnostics: {
        'trip_fatigue_per_minute': [1, 2],
        'trip_breaks': 0,
        'trip_escalations': 1,
      },
    );
    await repository.insertSession({
      'id': 'session-2',
      'trip_id': 'trip',
      'started_at': wall,
      'settings_json': {'eyeThreshold': 0.4},
      'calibration_json': {'pitch': 1.2},
      'algorithm_version': '1',
    });
    await repository.checkpointSession(
      'session-2',
      atUs: 60000000,
      diagnostics: {
        'trip_fatigue_per_minute': [1, 2, -1, 3],
        'trip_breaks': 1,
        'trip_escalations': 1,
      },
    );
    final summary = await repository.tripSummary('trip');
    expect(summary['fatigue_per_minute'], [1, 2, -1, 3]);
    expect(summary['fatigue_peak'], 3);
    expect(summary['breaks'], 1);
    expect(summary['escalations'], 1);
  });

  test('summary without vigilance diagnostics stays empty', () async {
    final summary = await repository.tripSummary('trip');
    expect(summary['fatigue_per_minute'], isEmpty);
    expect(summary['fatigue_peak'], isNull);
    expect(summary['breaks'], 0);
  });
}
