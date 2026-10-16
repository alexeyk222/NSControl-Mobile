import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/domain.dart';

void main() {
  var n = 0;
  SleepRecord r(
    DateTime start,
    DateTime end, {
    String source = 'garmin',
    SleepStage stage = SleepStage.asleep,
  }) => SleepRecord(
    source: source,
    sourceId: 'r${n++}',
    start: start,
    end: end,
    stage: stage,
  );
  final now = DateTime(2026, 10, 16, 12);

  test('nights belong to the wake-up day and missing nights stay unknown', () {
    final week = SleepWeek.build(
      now: now,
      source: 'garmin',
      records: [
        // Night 15→16: 23:00–06:30 with an awake gap, plus overlap.
        r(DateTime(2026, 10, 15, 23), DateTime(2026, 10, 16, 3)),
        r(DateTime(2026, 10, 16, 2), DateTime(2026, 10, 16, 4)),
        r(
          DateTime(2026, 10, 16, 4),
          DateTime(2026, 10, 16, 4, 30),
          stage: SleepStage.awake,
        ),
        r(DateTime(2026, 10, 16, 4, 30), DateTime(2026, 10, 16, 6, 30)),
        // Night 14→15: 5 h.
        r(DateTime(2026, 10, 15, 1), DateTime(2026, 10, 15, 6)),
        // Another source is ignored.
        r(
          DateTime(2026, 10, 13, 22),
          DateTime(2026, 10, 14, 7),
          source: 'phone',
        ),
      ],
    );
    expect(week.nights, hasLength(7));
    expect(week.nights.last.day, DateTime(2026, 10, 16));
    expect(week.nights.last.duration, const Duration(hours: 7));
    expect(week.nights[5].duration, const Duration(hours: 5));
    expect(week.nights[4].hasData, isFalse);
    expect(week.recorded, hasLength(2));
    expect(week.average, const Duration(hours: 6));
    // Only the recorded 5 h night contributes 2 h; unknown nights add nothing.
    expect(week.debt, const Duration(hours: 2));
    expect(week.onsetSpreadMinutes, isNull);
  });

  test('time in bed without sleep stages is not counted as zero sleep', () {
    final week = SleepWeek.build(
      now: now,
      source: 'garmin',
      records: [
        r(
          DateTime(2026, 10, 15, 23),
          DateTime(2026, 10, 16, 7),
          stage: SleepStage.inBed,
        ),
      ],
    );
    expect(week.nights.last.hasData, isFalse);
    expect(week.nights.last.inBedOnly, isTrue);
    expect(week.debt, Duration.zero);
    expect(week.average, isNull);
  });

  test('onset spread wraps around midnight', () {
    final week = SleepWeek.build(
      now: now,
      source: 'garmin',
      records: [
        r(DateTime(2026, 10, 13, 23, 30), DateTime(2026, 10, 14, 7)),
        r(DateTime(2026, 10, 15, 0, 30), DateTime(2026, 10, 15, 7)),
        r(DateTime(2026, 10, 16, 0), DateTime(2026, 10, 16, 7)),
      ],
    );
    expect(week.onsetSpreadMinutes, 24);
  });
}
