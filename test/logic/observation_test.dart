import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/domain.dart';

CalibrationProfile profile({double yaw = 0}) {
  final c = CalibrationCollector(
    trackingId: 7,
    detector: DetectorCapabilities.mlKit,
    hiddenEyes: false,
    startedUs: 0,
  );
  for (var i = 0; i < 100; i++) {
    c.add(
      capturedUs: i * 100000,
      faces: [f(yaw: yaw)],
    );
  }
  return c.finish(nowUs: 10000000).profile!;
}

FaceMeasurement f({
  double? eye = .8,
  double? pitch = 0,
  double? yaw = 0,
  double? roll = 0,
  int? id = 7,
}) => FaceMeasurement(
  trackingId: id,
  leftEye: eye,
  rightEye: eye,
  pitchDown: pitch,
  yaw: yaw,
  roll: roll,
);

ObservationEngine engine({double yaw = 0}) => ObservationEngine(
  sessionId: 's1',
  calibration: profile(yaw: yaw),
);

ObservationUpdate frame(
  ObservationEngine e,
  int time,
  FaceMeasurement value, {
  int? completed,
  String session = 's1',
}) => e.process(
  sessionId: session,
  capturedUs: time,
  completedUs: completed ?? time,
  faces: [value],
);

List<ObservationEvent> feed(
  ObservationEngine e,
  int start,
  int end,
  FaceMeasurement value,
) {
  final events = <ObservationEvent>[];
  for (var t = start; t <= end; t += 100000) {
    events.addAll(frame(e, t, value).started);
  }
  return events;
}

void main() {
  test(
    'both eyes must reopen for sustained recovery of an active eye event',
    () {
      final e = engine();
      feed(e, 0, 1700000, f(eye: .1));
      const oneOpen = FaceMeasurement(
        trackingId: 7,
        leftEye: .8,
        rightEye: .1,
        pitchDown: 0,
        yaw: 0,
        roll: 0,
      );
      feed(e, 1800000, 2500000, oneOpen);
      expect(e.snapshot.eyes.activeEvent, isNotNull);
      feed(e, 2600000, 2900000, f());
      expect(e.snapshot.eyes.activeEvent, isNotNull);
      expect(frame(e, 3000000, f()).ended.single.endedUs, 2700000);
    },
  );

  test(
    'head recovery needs five hundred milliseconds and returns its first normal time',
    () {
      final e = engine();
      feed(e, 0, 2200000, f(pitch: 25));
      feed(e, 2300000, 2800000, f());
      expect(e.snapshot.head.activeEvent, isNotNull);
      final update = frame(e, 2900000, f());
      expect(update.ended.single.endedUs, 2400000);
      expect(update.ended.single.endReason, EventEndReason.recovered);
    },
  );

  test(
    'a single noisy eye sample is removed by the median without resetting onset',
    () {
      final e = engine();
      feed(e, 0, 1000000, f(eye: .1));
      frame(e, 1100000, f());
      final events = feed(e, 1200000, 1700000, f(eye: .1));
      expect(events.single.signStartedUs, 200000);
    },
  );

  test(
    'median requires three frames and eyes threshold is strict and duration inclusive',
    () {
      final e = engine();
      expect(feed(e, 0, 2000000, f(eye: .4)), isEmpty);
      expect(feed(e, 2100000, 3600000, f(eye: .1)), isEmpty);
      final update = frame(e, 3700000, f(eye: .1));
      expect(update.started.single.type, EventType.eyesClosed);
      expect(update.started.single.signStartedUs, 2200000);
      expect(update.started.single.thresholdUs, 3700000);
    },
  );

  test('head threshold is strict and yaw exactly thirty is allowed', () {
    final e = engine();
    expect(feed(e, 0, 2300000, f(pitch: 20, yaw: 30)), isEmpty);
    final events = feed(e, 2400000, 4500000, f(pitch: 21, yaw: 30));
    expect(events.single.type, EventType.headPitchDown);
    expect(e.snapshot.eyes.available, isFalse);
    expect(e.snapshot.cameraStatus, CameraStatus.warning);
  });

  test('raw side turn resets only head before median can hide it', () {
    final e = engine(yaw: -18);
    feed(e, 0, 1000000, f(eye: .1, pitch: 25, yaw: 0));
    final turn = frame(e, 1100000, f(eye: .1, pitch: 25, yaw: 13));
    expect(turn.snapshot.head.reason, ChannelReason.sideTurn);
    expect(turn.snapshot.eyes.available, isTrue);
    final events = feed(e, 1200000, 1700000, f(eye: .1, pitch: 25, yaw: 0));
    expect(events.single.type, EventType.eyesClosed);
    expect(e.snapshot.head.activeEvent, isNull);
  });

  test(
    'eye yaw is absolute while head yaw is relative and channels are independent',
    () {
      final e = engine(yaw: 10);
      final events = feed(e, 0, 2300000, f(eye: .1, pitch: 25, yaw: 19));
      expect(events.single.type, EventType.headPitchDown);
      expect(e.snapshot.eyes.reason, ChannelReason.eyePose);
      final independent = engine();
      final eyes = feed(independent, 0, 1800000, f(eye: .1, pitch: null));
      expect(eyes.single.type, EventType.eyesClosed);
    },
  );

  test(
    'gap at exactly three hundred milliseconds is valid but greater resets filter',
    () {
      final e = engine();
      feed(e, 0, 1000000, f(eye: .1));
      expect(frame(e, 1300000, f(eye: .1)).snapshot.eyes.signStartedUs, 200000);
      e.tick(1600001);
      expect(e.snapshot.eyes.signStartedUs, isNull);
      expect(e.snapshot.eyes.reason, ChannelReason.observationGap);
      frame(e, 1700000, f(eye: .1));
      expect(e.snapshot.eyes.phase, ChannelPhase.warmingUp);
      expect(e.snapshot.eyes.signStartedUs, isNull);
      e.tick(2700000);
      expect(e.snapshot.eyes.reason, ChannelReason.noRecentData);
    },
  );

  test(
    'late, stale, out of order and previous-session frames never advance onset',
    () {
      final e = engine();
      feed(e, 0, 1000000, f(eye: .1));
      expect(frame(e, 1100000, f(eye: .1), session: 'old').rejected, isTrue);
      expect(frame(e, 900000, f(eye: .1)).rejected, isTrue);
      expect(
        frame(e, 1100000, f(eye: .1), completed: 1400001).rejected,
        isTrue,
      );
      expect(e.snapshot.eyes.signStartedUs, isNull);
      expect(frame(e, -1, f(eye: .1)).rejected, isTrue);
      expect(
        frame(e, 1500000, f(eye: .1), completed: 1499999).rejected,
        isTrue,
      );
    },
  );

  test(
    'recovery is sustained and event end is first filtered normal frame',
    () {
      final e = engine();
      final event = feed(e, 0, 1700000, f(eye: .1)).single;
      feed(e, 1800000, 1900000, f());
      feed(e, 2000000, 2100000, f(eye: .1));
      expect(e.snapshot.activeEvents.single.id, event.id);
      expect(feed(e, 2200000, 2500000, f()), isEmpty);
      final recovered = frame(e, 2600000, f());
      expect(recovered.ended.single.endedUs, 2300000);
      expect(recovered.ended.single.endReason, EventEndReason.recovered);
    },
  );

  test('acknowledgement is scoped to IDs and new events still alert', () {
    final e = engine();
    final first = feed(e, 0, 1700000, f(eye: .1)).single;
    final ack = e.acknowledge(eventIds: {first.id}, nowUs: 1750000);
    expect(ack.snapshot.cameraStatus, CameraStatus.warning);
    expect(ack.snapshot.hasUnacknowledgedAlert, isFalse);
    feed(e, 1800000, 2400000, f());
    final second = feed(e, 2500000, 4200000, f(eye: .1)).single;
    expect(second.id, isNot(first.id));
    e.acknowledge(eventIds: {first.id}, nowUs: 4250000);
    expect(e.snapshot.hasUnacknowledgedAlert, isTrue);
  });

  test(
    'data loss and camera stop close active events without claiming recovery',
    () {
      final e = engine();
      feed(e, 0, 2200000, f(eye: .1, pitch: 25));
      expect(e.snapshot.activeEvents, hasLength(2));
      final loss = frame(e, 2300000, f(eye: null, pitch: 25));
      expect(loss.ended.single.type, EventType.eyesClosed);
      expect(loss.ended.single.endReason, EventEndReason.dataLost);
      expect(loss.snapshot.head.activeEvent, isNotNull);
      final stopped = e.stop(
        nowUs: 2350000,
        reason: EventEndReason.cameraStopped,
      );
      expect(stopped.ended.single.endReason, EventEndReason.cameraStopped);
      expect(frame(e, 2400000, f()).rejected, isTrue);
    },
  );

  test(
    'ambiguous or changed face locks observation until a new calibration',
    () {
      final e = engine();
      feed(e, 0, 1000000, f(eye: .1));
      frame(e, 1100000, f(id: 8));
      expect(e.snapshot.requiresRecalibration, isTrue);
      expect(feed(e, 1200000, 4000000, f(eye: .1)), isEmpty);
      expect(e.snapshot.cameraStatus, CameraStatus.unavailable);
    },
  );
}
