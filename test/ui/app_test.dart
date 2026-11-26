import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/domain.dart';
import 'package:nscontrol/main.dart';
import 'package:nscontrol/services/detector.dart';
import 'package:nscontrol/services/sleep_controller.dart';
import 'package:nscontrol/services/trip_controller.dart';
import 'package:nscontrol/ui/copy.dart';
import 'package:nscontrol/ui/design/ns_theme.dart';
import 'package:nscontrol/ui/design/tokens.dart';
import 'package:nscontrol/ui/presentation/ui_prefs.dart';
import 'package:nscontrol/ui/screens/app_shell.dart';

import '../services/trip_controller_test.dart'
    show
        ControllerTestDetector,
        ControllerTestPlatform,
        ControllerTestCamera,
        mlKitFace,
        testProfile;

/// The whole scenario of the design on the real trip controller with a
/// fake camera (no device): Знакомство → Перед поездкой → «Поехали» →
/// Настройка камеры (no taps) → В пути → Тревога → Пауза → Итог.
void main() {
  late ControllerTestPlatform platform;
  late TripController trip;
  late SleepController sleep;
  ControllerTestCamera? camera;
  late ManualClock clock;

  /// A camera frame at [us] on the trip clock, which moves with it.
  void frame(DetectedFace face, int us) {
    clock.us = us + 20000;
    camera!.onFaces([face], us, us + 20000);
  }

  Future<void> setUpApp(
    WidgetTester tester, {
    UiPrefs? prefs,
    void Function()? before,
  }) async {
    tester.view.physicalSize = const Size(414, 896);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    platform = ControllerTestPlatform();
    trip = TripController(
      repository: null,
      platform: platform,
      detector: ControllerTestDetector(),
      clock: clock = ManualClock(),
      cameraFactory: (d, n, f, e, c) => camera = ControllerTestCamera(
        detector: d,
        nowUs: n,
        onFaces: f,
        onError: e,
        onChanged: c,
      ),
    );
    sleep = SleepController(trip: trip, platform: platform);
    before?.call();
    await tester.pumpWidget(
      NSControlApp(trip: trip, sleep: sleep, prefs: prefs),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tearDownApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    sleep.dispose();
    trip.dispose();
    await tester.pump();
  }

  /// The camera ring and the breathing indicator never settle: wait for
  /// the page transitions instead.
  Future<void> calm(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  /// Frames of the observing session for [seconds] after the last one.
  void observe(double seconds, DetectedFace Function() make) {
    final base = trip.sessionBaseUs;
    final from = (trip.snapshot?.head.lastUsableUs ?? 0) + 33000;
    for (var t = from; t <= from + (seconds * 1000000).round(); t += 33000) {
      frame(make(), base + t);
    }
  }

  testWidgets('first run to the end of a trip without a camera', (
    tester,
  ) async {
    final prefs = UiPrefs();
    await setUpApp(tester, prefs: prefs);

    // Знакомство.
    expect(find.text(Copy.introTitle), findsOneWidget);
    await tester.tap(find.text(Copy.introCta));
    await tester.pumpAndSettle();
    expect(find.text(Copy.mountTitle), findsOneWidget);
    await tester.tap(find.text(Copy.mountRight));
    await tester.pumpAndSettle();
    expect(trip.mountPosition, 'vent_right');
    await tester.tap(find.text(Copy.next));
    await tester.pumpAndSettle();
    expect(find.text(Copy.soundTitle), findsOneWidget);
    await tester.tap(find.bySemanticsLabel(Copy.soundPlay));
    await tester.pump();
    expect(platform.testAlertCalls, 1);
    await tester.tap(find.text(Copy.soundYes));
    await tester.pumpAndSettle();
    expect(prefs.onboarded, isTrue);

    // Перед поездкой.
    expect(find.text(Copy.verdictUnknown), findsOneWidget);
    expect(find.text(Copy.readyCameraNone), findsOneWidget);
    await tester.tap(find.byKey(const Key('start-trip')));
    await tester.pump();
    await calm(tester);
    expect(trip.active, isTrue);
    expect(find.text(Copy.calTitle), findsOneWidget);
    expect(trip.phase, TripPhase.findingFace);

    // The face is seen for a second: confirmed without a tap.
    frame(mlKitFace(yaw: 2), clock.us + 200000);
    await tester.pump();
    expect(find.text(Copy.calFaceSeen), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1100));
    expect(trip.phase, TripPhase.calibrating);
    await tester.pump();
    expect(find.text(Copy.calGo), findsOneWidget);
    final start = trip.calibrationStartUs;
    for (var t = start; t <= start + 10200000; t += 33000) {
      frame(mlKitFace(yaw: 2), t);
    }
    trip.finishCalibration(start + 10300000);
    await tester.pump();
    expect(trip.phase, TripPhase.observing);
    // «Готово» first, then the trip screen.
    expect(find.text(Copy.calDone), findsOneWidget);
    expect(platform.spoken, contains(Voice.calDone));
    expect(prefs.cameraReady, isTrue);
    await tester.pump(AppShell.doneFor);
    await calm(tester);
    observe(.5, () => mlKitFace(yaw: 2));
    await tester.pump();
    expect(find.text(Copy.watching), findsOneWidget);

    // Тревога: eyes closed for two seconds.
    observe(2.2, () => mlKitFace(yaw: 2, eyes: .05));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('global-alarm')), findsOneWidget);
    expect(find.text(Copy.alarmEyes), findsOneWidget);
    expect(trip.snapshot!.hasUnacknowledgedAlert, isTrue);
    await tester.tap(find.byKey(const Key('global-alarm')));
    await tester.pump();
    expect(trip.snapshot!.hasUnacknowledgedAlert, isFalse);
    // Eyes open again: the alarm fades after at least 2 s on screen.
    observe(3, () => mlKitFace(yaw: 2));
    expect(trip.snapshot!.activeEvents, isEmpty);
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await calm(tester);
    expect(find.byKey(const Key('global-alarm')), findsNothing);
    expect(find.text(Copy.adviceStop), findsOneWidget);

    // Пауза and back.
    await tester.tap(find.byKey(const Key('trip-pause')));
    await calm(tester);
    expect(trip.userPaused, isTrue);
    expect(find.text(Copy.paused), findsOneWidget);
    expect(find.byKey(const Key('trip-resume')), findsOneWidget);
    await tester.tap(find.byKey(const Key('trip-resume')));
    await calm(tester);
    expect(trip.userPaused, isFalse);

    // A short touch of «Завершить» does nothing; holding 1.2 s finishes.
    await tester.tap(find.byKey(const Key('trip-finish')));
    await calm(tester);
    expect(trip.active, isTrue);
    final hold = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('trip-finish'))),
    );
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await hold.up();
    await calm(tester);
    expect(trip.active, isFalse);

    // Итог.
    expect(find.text(Copy.sumTitle), findsOneWidget);
    expect(find.textContaining('Будил 1 раз'), findsOneWidget);
    await tester.tap(find.byKey(const Key('summary-done')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('verdict')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tearDownApp(tester);
  });

  testWidgets('the alarm lies over every page and a tap silences it', (
    tester,
  ) async {
    await setUpApp(
      tester,
      before: () {
        trip.tripId = 'trip';
        trip.sessionId = 'session';
        trip.phase = TripPhase.observing;
        // The frames below end 2 s into the session; «now» is 5 s.
        trip.sessionBaseUs = trip.clock.elapsedMicroseconds - 5000000;
        trip.engine = ObservationEngine(
          sessionId: 'session',
          calibration: testProfile(),
        );
        for (var t = 0; t <= 2000000; t += 100000) {
          trip.engine!.process(
            sessionId: 'session',
            capturedUs: t,
            completedUs: t,
            faces: [
              const FaceMeasurement(
                trackingId: 7,
                leftEye: .1,
                rightEye: .1,
                pitchDown: 0,
                yaw: 0,
                roll: 0,
              ),
            ],
          );
        }
      },
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('global-alarm')), findsOneWidget);
    expect(find.text(Copy.alarmHint), findsOneWidget);
    await tester.tap(find.byKey(const Key('global-alarm')));
    await tester.pump();
    expect(trip.snapshot!.hasUnacknowledgedAlert, isFalse);
    await tearDownApp(tester);
  });

  testWidgets('a look chosen in settings applies at once', (tester) async {
    final prefs = UiPrefs(onboarded: true);
    await setUpApp(tester, prefs: prefs);
    await tester.tap(find.byKey(const Key('open-settings')));
    await tester.pumpAndSettle();
    expect(find.text(Copy.setDesign), findsOneWidget);
    for (final design in [NsDesign.companion, NsDesign.roadsign]) {
      await tester.tap(find.byKey(Key('design-${design.name}')));
      await tester.pumpAndSettle();
      expect(prefs.design, design);
      final context = tester.element(find.text(Copy.setDesign));
      expect(NsTheme.of(context).design, design);
    }
    // The voice switch silences the controller's optional phrases too.
    expect(trip.voiceEnabled, isTrue);
    prefs.setVoice(false);
    await tester.pump();
    expect(trip.voiceEnabled, isFalse);
    // The break interval goes to the trip rules outside a trip.
    prefs.setBreakMinutes(150);
    await tester.pump();
    expect(trip.breakInterval, const Duration(minutes: 150));
    expect(trip.drive.breakAfterUs, 150 * 60 * 1000000);
    // The theme outside a trip.
    await tester.tap(find.text(Copy.themeLight));
    await tester.pumpAndSettle();
    expect(prefs.themeMode, ThemeMode.light);
    expect(tester.takeException(), isNull);
    await tearDownApp(tester);
  });
}

/// The trip clock of the test: it stands still and moves only with the
/// frames, so the controller's throttled updates follow the frames.
class ManualClock implements Stopwatch {
  int us = 0;
  @override
  int get elapsedMicroseconds => us;
  @override
  int get elapsedMilliseconds => us ~/ 1000;
  @override
  int get elapsedTicks => us;
  @override
  Duration get elapsed => Duration(microseconds: us);
  @override
  int get frequency => 1000000;
  @override
  bool get isRunning => true;
  @override
  void start() {}
  @override
  void stop() {}
  @override
  void reset() => us = 0;
}
