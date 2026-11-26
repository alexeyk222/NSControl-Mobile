import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/domain.dart';

final now = DateTime.utc(2026, 10, 15, 12);
SleepRecord record(
  String id,
  int from,
  int until, {
  String source = 'watch',
  SleepStage stage = SleepStage.asleep,
}) => SleepRecord(
  source: source,
  sourceId: id,
  start: now.add(Duration(hours: from)),
  end: now.add(Duration(hours: until)),
  stage: stage,
);

SleepSummary summary(
  List<SleepRecord> records, {
  bool complete = true,
  DateTime? at,
  SleepReadStatus status = SleepReadStatus.success,
}) {
  final time = at ?? now;
  final initial = SleepNormalizer.summarize(
    records: records,
    now: time,
    selectedSource: 'watch',
    readStatus: status,
    lastSuccessfulRead: time,
  );
  return SleepNormalizer.summarize(
    records: records,
    now: time,
    selectedSource: 'watch',
    readStatus: status,
    lastSuccessfulRead: time,
    coverage: complete
        ? SleepCoverage(
            source: 'watch',
            start: time.subtract(const Duration(hours: 24)),
            end: time,
            confirmedAt: time,
            hasUnrecordedSleep: false,
            inputFingerprint: initial.inputFingerprint,
          )
        : null,
  );
}

void main() {
  test(
    'sleep clips a 24-hour window, merges one source, subtracts awake and ignores in-bed',
    () {
      final s = summary([
        record('one', -26, -20),
        record('two', -22, -18),
        record('awake', -21, -20, stage: SleepStage.awake),
        record('bed', -18, -16, stage: SleepStage.inBed),
        record('other', -16, -10, source: 'other'),
        record('ongoing', -1, 1),
      ]);
      expect(s.duration, const Duration(hours: 5));
      expect(s.complete, isTrue);
      expect(s.intervals, hasLength(2));
    },
  );

  test(
    'source IDs update records without duplicates and invalid intervals are rejected',
    () {
      final s = summary([record('same', -9, -1), record('same', -8, -2)]);
      expect(s.duration, const Duration(hours: 6));
      expect(() => record('invalid', 1, -1), throwsArgumentError);
      expect(
        SleepRecord.fromJson(record('saved', -8, -1).toJson()).sourceId,
        'saved',
      );
    },
  );

  test(
    'read success alone and unrecorded sleep do not establish completeness',
    () {
      final records = [record('one', -8, -2)];
      final s = summary(records, complete: false);
      expect(s.complete, isFalse);
      final coverage = SleepCoverage(
        source: 'watch',
        start: now.subtract(const Duration(hours: 24)),
        end: now,
        confirmedAt: now,
        hasUnrecordedSleep: true,
        inputFingerprint: s.inputFingerprint,
      );
      expect(
        SleepNormalizer.summarize(
          records: records,
          now: now,
          selectedSource: 'watch',
          readStatus: SleepReadStatus.success,
          lastSuccessfulRead: now,
          coverage: coverage,
        ).complete,
        isFalse,
      );
    },
  );

  test(
    'moving window, changed input and failed refresh invalidate confirmation but preserve volume',
    () {
      final records = [record('one', -8, -2)];
      final s = summary(records);
      final coverage = SleepCoverage(
        source: 'watch',
        start: s.windowStart,
        end: s.windowEnd,
        confirmedAt: now,
        hasUnrecordedSleep: false,
        inputFingerprint: s.inputFingerprint,
      );
      SleepSummary calculate(
        List<SleepRecord> input,
        DateTime time,
        SleepReadStatus status,
      ) => SleepNormalizer.summarize(
        records: input,
        now: time,
        selectedSource: 'watch',
        readStatus: status,
        lastSuccessfulRead: now,
        coverage: coverage,
      );
      expect(
        calculate(
          records,
          now.add(const Duration(minutes: 1)),
          SleepReadStatus.success,
        ).complete,
        isFalse,
      );
      expect(
        calculate(
          [record('one', -9, -2)],
          now,
          SleepReadStatus.success,
        ).complete,
        isFalse,
      );
      final failed = calculate(records, now, SleepReadStatus.failed);
      expect(failed.complete, isFalse);
      expect(failed.duration, const Duration(hours: 6));
    },
  );

  test(
    'seven hours exact does not trigger insufficient sleep and unknown assessment stays unknown',
    () {
      final e = RecommendationEngine(tripId: 'trip');
      final seven = e.evaluate(
        localNow: now,
        sleep: summary([record('one', -8, -1)]),
      );
      expect(seven.recommendation.action, RecommendationAction.noGrounds);
      expect(seven.recommendation.assessment, SelfAssessment.unknown);
      expect(seven.shouldNotify, isFalse);
      final less = e.evaluate(
        localNow: now,
        sleep: summary([record('one', -7, -1)]),
      );
      expect(less.recommendation.action, RecommendationAction.delayAndRest);
      expect(
        less.recommendation.reasons,
        contains(RecommendationReason.insufficientSleep),
      );
      expect(less.shouldNotify, isTrue);
    },
  );

  test(
    'missing sleep does not assert zero sleep or suppress independent sleepy report',
    () {
      final e = RecommendationEngine(tripId: 'trip');
      final update = e.evaluate(
        localNow: now,
        sleep: summary([], complete: false),
        assessment: SelfAssessment.sleepy,
        tripStarted: true,
      );
      expect(update.recommendation.action, RecommendationAction.stopAndRest);
      expect(
        update.recommendation.reasons,
        contains(RecommendationReason.selfReportedSleepiness),
      );
      expect(
        update.recommendation.reasons,
        isNot(contains(RecommendationReason.insufficientSleep)),
      );
      expect(update.recommendation.dataStatus, SleepDataStatus.insufficient);
    },
  );

  test(
    'eye reason remains through recovery and acknowledgement until trip end',
    () {
      final e = RecommendationEngine(tripId: 'trip');
      final enough = summary([record('one', -9, -1)]);
      final first = e.evaluate(
        localNow: now,
        sleep: enough,
        tripStarted: true,
        eyesEventOccurred: true,
      );
      expect(first.recommendation.action, RecommendationAction.stopAndRest);
      expect(first.shouldNotify, isTrue);
      final next = e.evaluate(
        localNow: now.add(const Duration(minutes: 1)),
        sleep: enough,
        tripStarted: true,
      );
      expect(
        next.recommendation.reasons,
        contains(RecommendationReason.eyesClosed),
      );
      expect(next.shouldNotify, isFalse);
      expect(next.changed, isFalse);
      e.endTrip();
      expect(
        e.evaluate(localNow: now, sleep: enough).recommendation.reasons,
        isNot(contains(RecommendationReason.eyesClosed)),
      );
    },
  );

  test(
    'night is inclusive at midnight and exclusive at six; head is not confirmed sleep',
    () {
      final e = RecommendationEngine(tripId: 'trip');
      final enough = summary([record('one', -9, -1)]);
      final midnight = e.evaluate(
        localNow: DateTime(2026, 10, 15),
        sleep: enough,
      );
      expect(
        midnight.recommendation.action,
        RecommendationAction.reconsiderTripTime,
      );
      final six = e.evaluate(
        localNow: DateTime(2026, 10, 15, 6),
        sleep: enough,
        headEventActive: true,
      );
      expect(six.recommendation.action, RecommendationAction.checkCondition);
      expect(six.recommendation.reasons, [RecommendationReason.headPitchDown]);
      expect(six.recommendation.message, contains('проверьте состояние'));
    },
  );

  test(
    'priority increase notifies while identical minute recalculation does not',
    () {
      final e = RecommendationEngine(tripId: 'trip');
      final enough = summary([record('one', -9, -1)]);
      e.evaluate(localNow: DateTime(2026, 10, 15, 1), sleep: enough);
      final escalation = e.evaluate(
        localNow: DateTime(2026, 10, 15, 1, 1),
        sleep: enough,
        assessment: SelfAssessment.sleepy,
        tripStarted: true,
      );
      expect(escalation.shouldNotify, isTrue);
      final repeat = e.evaluate(
        localNow: DateTime(2026, 10, 15, 1, 2),
        sleep: enough,
        assessment: SelfAssessment.sleepy,
        tripStarted: true,
      );
      expect(repeat.shouldNotify, isFalse);
      expect(repeat.changed, isFalse);
      expect(repeat.recommendation.id, escalation.recommendation.id);
    },
  );

  group('rules 1.1 product extensions', () {
    test('long continuous drive asks for a break only during a trip', () {
      final e = RecommendationEngine(tripId: 'trip');
      final enough = summary([record('one', -9, -1)]);
      final before = e.evaluate(
        localNow: now,
        sleep: enough,
        drivingTime: const Duration(hours: 3),
      );
      expect(before.recommendation.action, RecommendationAction.noGrounds);
      final short = e.evaluate(
        localNow: now,
        sleep: enough,
        tripStarted: true,
        drivingTime: const Duration(minutes: 119),
      );
      expect(short.recommendation.action, RecommendationAction.noGrounds);
      final due = e.evaluate(
        localNow: now,
        sleep: enough,
        tripStarted: true,
        drivingTime: const Duration(hours: 2, minutes: 5),
      );
      expect(due.recommendation.action, RecommendationAction.takeBreak);
      expect(due.shouldNotify, isTrue);
      expect(due.recommendation.reasonTexts.single, contains('2 ч 5 мин'));
    });

    test('the break interval of the settings', () {
      final e = RecommendationEngine(
        tripId: 'trip',
        breakAfter: const Duration(minutes: 90),
      );
      final enough = summary([record('one', -9, -1)]);
      final due = e.evaluate(
        localNow: now,
        sleep: enough,
        tripStarted: true,
        drivingTime: const Duration(minutes: 95),
      );
      expect(due.recommendation.action, RecommendationAction.takeBreak);
    });

    test('fatigue trend latches until a break and ranks below head event', () {
      final e = RecommendationEngine(tripId: 'trip');
      final enough = summary([record('one', -9, -1)]);
      final tired = e.evaluate(
        localNow: now,
        sleep: enough,
        tripStarted: true,
        fatigueHigh: true,
      );
      expect(tired.recommendation.action, RecommendationAction.takeBreak);
      final later = e.evaluate(
        localNow: now,
        sleep: enough,
        tripStarted: true,
        headEventActive: true,
      );
      expect(later.recommendation.action, RecommendationAction.checkCondition);
      expect(
        later.recommendation.reasons,
        contains(RecommendationReason.fatigueSigns),
      );
      e.restTaken();
      final rested = e.evaluate(
        localNow: now,
        sleep: enough,
        tripStarted: true,
      );
      expect(rested.recommendation.action, RecommendationAction.noGrounds);
    });

    test('low Body Battery is a low-priority reason, eyes still dominate', () {
      final e = RecommendationEngine(tripId: 'trip');
      final enough = summary([record('one', -9, -1)]);
      final low = e.evaluate(localNow: now, sleep: enough, bodyBattery: 15);
      expect(
        low.recommendation.action,
        RecommendationAction.reconsiderTripTime,
      );
      expect(
        low.recommendation.reasonTexts.single,
        contains('Body Battery 15'),
      );
      final ok = e.evaluate(localNow: now, sleep: enough, bodyBattery: 21);
      expect(ok.recommendation.reasons, isEmpty);
      final eyes = e.evaluate(
        localNow: now,
        sleep: enough,
        tripStarted: true,
        eyesEventOccurred: true,
        bodyBattery: 15,
      );
      expect(eyes.recommendation.action, RecommendationAction.stopAndRest);
    });
  });
}
