import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/data/trip_repository.dart';
import 'package:nscontrol/logic/domain.dart';
import 'package:nscontrol/services/sleep_controller.dart';
import 'package:nscontrol/services/trip_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'trip_controller_test.dart' as fixtures;

class SleepTestPlatform extends fixtures.ControllerTestPlatform {
  Map<String, Object?> response = {};
  Completer<Map<String, Object?>>? pendingRead;
  @override
  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    if (method == 'sleep.read') return pendingRead?.future ?? response;
    return {'status': 'ok'};
  }
}

void main() {
  late TripRepository repository;
  late TripController trip;
  late SleepController sleep;
  late SleepTestPlatform platform;
  late DateTime now;
  var repositoryClosed = false;
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    repositoryClosed = false;
    repository = await TripRepository.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    platform = SleepTestPlatform();
    trip = TripController(
      repository: repository,
      platform: platform,
      detector: fixtures.ControllerTestDetector(),
      cameraFactory: (d, n, f, e, c) => fixtures.ControllerTestCamera(
        detector: d,
        nowUs: n,
        onFaces: f,
        onError: e,
        onChanged: c,
      ),
    );
    sleep = SleepController(trip: trip, platform: platform)..enabled = true;
    now = DateTime.now().toUtc();
    await trip.pendingWrites;
  });
  tearDown(() async {
    sleep.dispose();
    trip.dispose();
    await trip.pendingWrites;
    if (!repositoryClosed) await repository.close();
  });

  Map<String, Object?> stage(
    String id,
    int from,
    int to, {
    String kind = 'asleep',
  }) => {
    'id': id,
    'provider_id': 'night',
    'source': 'watch',
    'start': now.add(Duration(hours: from)).toIso8601String(),
    'end': now.add(Duration(hours: to)).toIso8601String(),
    'stage': kind,
    'device': {'is_watch': true, 'model': 'Watch'},
  };
  Map<String, Object?> response(
    List<Map<String, Object?>> rows, {
    bool complete = true,
  }) => {
    'status': 'available',
    'snapshot_complete': complete,
    'sources': ['watch'],
    'records': rows,
    'read_at': now.toIso8601String(),
  };

  test(
    'sleep segments sharing a provider ID stay distinct and replacement removes old stages',
    () async {
      platform.response = response([
        stage('sleep1', -9, -6),
        stage('sleep2', -5, -2),
        stage('wake', -4, -3, kind: 'awake'),
      ]);
      await sleep.refresh();
      expect(sleep.summary.duration, const Duration(hours: 5));
      expect(sleep.records, hasLength(3));
      platform.response = response([stage('corrected', -4, -2)]);
      await sleep.refresh();
      expect(sleep.summary.duration, const Duration(hours: 2));
      expect(await repository.listSleepRecords(), hasLength(1));
    },
  );

  test('complete source snapshot removes a deleted provider group', () async {
    platform.response = response([stage('sleep', -8, -2)]);
    await sleep.refresh();
    expect(sleep.summary.duration, const Duration(hours: 6));
    platform.response = response([]);
    await sleep.refresh();
    expect(await repository.listSleepRecords(), isEmpty);
    expect(sleep.summary.duration, Duration.zero);
    sleep.confirmCoverage(unrecordedSleep: false);
    expect(sleep.summary.complete, isFalse);
  });

  test(
    'ambiguous empty read retains cached volume without allowing complete confirmation',
    () async {
      platform.response = response([stage('sleep', -8, -2)]);
      await sleep.refresh();
      platform.response = response([], complete: false);
      await sleep.refresh();
      expect(sleep.summary.duration, const Duration(hours: 6));
      sleep.confirmCoverage(unrecordedSleep: false);
      expect(sleep.summary.complete, isFalse);
      expect(
        sleep.recommendation!.reasons,
        isNot(contains(RecommendationReason.insufficientSleep)),
      );
    },
  );

  test(
    'disconnect while native read is pending prevents applying its result',
    () async {
      platform.pendingRead = Completer<Map<String, Object?>>();
      final refresh = sleep.refresh();
      sleep.disconnect();
      platform.pendingRead!.complete(response([stage('sleep', -8, -2)]));
      await refresh;
      expect(sleep.records, isEmpty);
      expect(sleep.readStatus, SleepReadStatus.unavailable);
      expect(sleep.enabled, isFalse);
    },
  );

  test(
    'a complete snapshot also reconciles a previously known source absent from the response',
    () async {
      platform.response = {
        ...response([stage('sleep', -8, -2)]),
        'provider': 'healthkit',
      };
      await sleep.refresh();
      expect(sleep.source, 'watch');
      platform.response = {
        ...response([
          {...stage('other', -9, -1), 'source': 'otherWatch'},
        ]),
        'provider': 'healthkit',
        'sources': ['otherWatch'],
      };
      await sleep.refresh();
      expect(
        (await repository.listSleepRecords()).where(
          (r) => r['source'] == 'watch',
        ),
        isEmpty,
      );
      sleep.confirmCoverage(unrecordedSleep: false);
      expect(sleep.summary.complete, isFalse);
    },
  );

  test(
    'a failed journal write cannot replace a fresh provider response with stale sleep',
    () async {
      platform.response = response([stage('cached', -8, -2)]);
      await sleep.refresh();
      await trip.pendingWrites;
      expect(sleep.summary.duration, const Duration(hours: 6));
      await repository.close();
      repositoryClosed = true;
      now = DateTime.now().toUtc();
      platform.response = response([stage('fresh', -9, -1)]);
      await sleep.refresh();
      await trip.pendingWrites;
      expect(trip.journalIncomplete, isTrue);
      expect(sleep.summary.duration, const Duration(hours: 8));
      expect(sleep.records, hasLength(1));
      expect(
        sleep.records.single.start,
        now.subtract(const Duration(hours: 9)),
      );
      expect(sleep.readStatus, SleepReadStatus.success);
      expect(sleep.lastRead, now);
      expect(
        sleep.recommendation!.reasons,
        isNot(contains(RecommendationReason.insufficientSleep)),
      );
    },
  );

  test(
    'memory fallback never endorses deleted cached sleep after a complete refresh',
    () async {
      platform.response = response([stage('sleep', -8, -2)]);
      await sleep.refresh();
      trip.repository = null;
      platform.response = response([]);
      await sleep.refresh();
      sleep.confirmCoverage(unrecordedSleep: false);
      expect(sleep.summary.complete, isFalse);
      expect(
        sleep.recommendation!.reasons,
        isNot(contains(RecommendationReason.insufficientSleep)),
      );
    },
  );
}
