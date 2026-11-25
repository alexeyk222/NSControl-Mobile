import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/domain.dart';
import 'package:nscontrol/ui/calm_alarm.dart';

void main() {
  ObservationEvent event() {
    final engine = ObservationEngine(
      sessionId: 's',
      calibration: CalibrationProfile(
        trackingId: 1,
        detector: DetectorCapabilities.mlKit,
        hiddenEyes: false,
        neutralPitch: 0,
        neutralYaw: 0,
        neutralRoll: 0,
        leftEyeMedian: .8,
        rightEyeMedian: .8,
        eyeThreshold: .4,
      ),
    );
    for (var t = 0; t <= 2000000; t += 100000) {
      engine.process(
        sessionId: 's',
        capturedUs: t,
        completedUs: t,
        faces: [
          const FaceMeasurement(
            trackingId: 1,
            leftEye: .1,
            rightEye: .1,
            pitchDown: 0,
            yaw: 0,
            roll: 0,
          ),
        ],
      );
    }
    return engine.snapshot.activeEvents.single;
  }

  Widget host(List<ObservationEvent> events) => MaterialApp(
    home: Scaffold(
      body: CalmAlarm(
        events: events,
        builder: (context, shown) => const Text('ALARM'),
      ),
    ),
  );

  testWidgets('fades in, stays 2 s although the event ended, fades out', (
    tester,
  ) async {
    final e = event();
    await tester.pumpWidget(host(const []));
    expect(find.text('ALARM'), findsNothing);
    await tester.pumpWidget(host([e]));
    await tester.pump(const Duration(milliseconds: 100));
    // Still fading in.
    final fade = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.text('ALARM'),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    expect(fade.opacity.value, lessThan(1));
    // The event ends after 0.3 s: the alarm stays.
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(host(const []));
    await tester.pump(const Duration(milliseconds: 1200));
    expect(find.text('ALARM'), findsOneWidget);
    // After 2 s it fades out (0.6 s) and is gone.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('ALARM'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('ALARM'), findsNothing);
  });

  testWidgets('a new event while fading out keeps the alarm', (tester) async {
    final e = event();
    await tester.pumpWidget(host([e]));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(host(const []));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpWidget(host([e]));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('ALARM'), findsOneWidget);
  });
}
