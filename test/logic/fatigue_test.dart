import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/domain.dart';

const frameUs = 50000; // 20 analyses per second

FatigueMonitor monitor({double? threshold = .4}) => FatigueMonitor(
  eyeThreshold: threshold,
  nodThreshold: 12,
  eyesEventUs: 1500000,
  headEventUs: 2000000,
);

/// Feeds open eyes from [fromUs] for [durationUs]; returns the next time.
int open(FatigueMonitor m, int fromUs, int durationUs) {
  var t = fromUs;
  for (; t < fromUs + durationUs; t += frameUs) {
    m.addEyes(t, .9, .9);
  }
  return t;
}

int closed(FatigueMonitor m, int fromUs, int durationUs) {
  var t = fromUs;
  for (; t < fromUs + durationUs; t += frameUs) {
    m.addEyes(t, .1, .1);
  }
  return t;
}

void main() {
  test('unknown until half a minute of usable eye data', () {
    final m = monitor();
    final t = open(m, 0, 20000000);
    expect(m.snapshot(t).level, FatigueLevel.unknown);
    final later = open(m, t, 15000000);
    final s = m.snapshot(later);
    expect(s.level, FatigueLevel.low);
    expect(s.perclos, 0);
    expect(s.eyeCoverage, closeTo(35 / 60, .01));
  });

  test('normal blinks are counted with mean duration', () {
    final m = monitor();
    var t = 0;
    for (var i = 0; i < 15; i++) {
      t = open(m, t, 3800000);
      t = closed(m, t, 200000);
    }
    t = open(m, t, 1000000);
    final s = m.snapshot(t);
    expect(s.blinksPerMinute, closeTo(15, 1));
    expect(s.meanBlinkMs, 200);
    expect(s.longBlinks, 0);
    expect(s.level, FatigueLevel.low);
  });

  test('long blinks escalate without becoming eyes_closed events', () {
    final m = monitor();
    var t = open(m, 0, 40000000);
    for (var i = 0; i < 2; i++) {
      t = closed(m, t, 700000);
      t = open(m, t, 5000000);
    }
    expect(m.snapshot(t).level, FatigueLevel.moderate);
    expect(m.snapshot(t).longBlinks, 2);
    for (var i = 0; i < 2; i++) {
      t = closed(m, t, 700000);
      t = open(m, t, 5000000);
    }
    expect(m.snapshot(t).level, FatigueLevel.high);
    // A closure at or above the event threshold is the camera event, not a blink.
    final e = monitor();
    var u = open(e, 0, 40000000);
    u = closed(e, u, 1600000);
    u = open(e, u, 1000000);
    expect(e.snapshot(u).longBlinks, 0);
  });

  test('perclos uses time with both eyes closed', () {
    final m = monitor();
    var t = 0;
    for (var i = 0; i < 6; i++) {
      t = open(m, t, 8000000);
      t = closed(m, t, 1700000); // reported as events, so not long blinks
    }
    final s = m.snapshot(t);
    expect(s.longBlinks, 0);
    expect(s.perclos, closeTo(1.7 / 9.7, .01));
    expect(s.level, FatigueLevel.high);
  });

  test('missing eye data interrupts closure and lowers coverage', () {
    final m = monitor();
    var t = open(m, 0, 40000000);
    t = closed(m, t, 300000);
    m.eyesUnavailable();
    t += 2000000;
    t = open(m, t, 1000000);
    expect(m.snapshot(t).longBlinks, 0);
    expect(m.snapshot(t).blinksPerMinute, 0);
  });

  test('short head drops count as nods, long ones belong to the event', () {
    final m = monitor(threshold: null);
    var t = 0;
    void head(double pitch, int duration) {
      for (final end = t + duration; t < end; t += frameUs) {
        m.addHead(t, pitch);
      }
    }

    head(0, 5000000);
    expect(m.snapshot(t).level, FatigueLevel.low);
    head(16, 800000);
    head(0, 1000000);
    expect(m.snapshot(t).nods, 1);
    expect(m.snapshot(t).level, FatigueLevel.moderate);
    head(16, 2500000); // reaches head_pitch_down threshold → not a nod
    head(0, 1000000);
    head(16, 200000); // too short
    head(0, 1000000);
    expect(m.snapshot(t).nods, 1);
    head(16, 600000);
    head(0, 500000);
    head(16, 600000);
    head(0, 500000);
    expect(m.snapshot(t).level, FatigueLevel.high);
    // Trend expires after five minutes.
    head(0, 300000000);
    expect(m.snapshot(t).nods, 0);
  });

  group('DriveClock', () {
    const minute = 60000000;
    test('counts continuous activity and short pauses', () {
      final c = DriveClock();
      for (var t = 0; t <= 100 * minute; t += minute) {
        c.active(t);
      }
      // A 10-minute pause is not a rest.
      for (var t = 110 * minute; t <= 121 * minute; t += minute) {
        c.active(t);
      }
      expect(c.continuousUs(121 * minute), 121 * minute);
      expect(c.breakDue(121 * minute), isTrue);
    });

    test('a 15-minute pause or explicit break restarts the count', () {
      final c = DriveClock();
      c.active(0);
      c.active(90 * minute);
      expect(c.continuousUs(105 * minute), 0);
      c.active(105 * minute);
      expect(c.continuousUs(106 * minute), minute);
      c.markBreak(110 * minute);
      expect(c.continuousUs(110 * minute), 0);
      expect(c.untilBreakUs(110 * minute), 120 * minute);
    });
  });
}
