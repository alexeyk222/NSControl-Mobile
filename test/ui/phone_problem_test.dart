import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/domain.dart';
import 'package:nscontrol/services/sleep_controller.dart';
import 'package:nscontrol/services/trip_controller.dart';
import 'package:nscontrol/ui/copy.dart';
import 'package:nscontrol/ui/design/ns_theme.dart';
import 'package:nscontrol/ui/design/tokens.dart';
import 'package:nscontrol/ui/presentation/phone_problem.dart';
import 'package:nscontrol/ui/presentation/ui_prefs.dart';
import 'package:nscontrol/ui/presentation/voice.dart';
import 'package:nscontrol/ui/screens/home_screen.dart';
import 'package:nscontrol/ui/screens/trip_screen.dart';

import '../services/trip_controller_test.dart'
    show
        ControllerTestCamera,
        ControllerTestDetector,
        ControllerTestPlatform,
        mlKitFace,
        testProfile;
import 'app_test.dart' show ManualClock;

/// A failure of the phone (TripController.alertError) is never silent on
/// screen: the alarm sound that did not start is the worst of them.
void main() {
  group('PhoneProblem.of', () {
    test('nothing to show', () {
      expect(PhoneProblem.of(null), isNull);
      expect(PhoneProblem.of('  '), isNull);
    });

    test('the alarm sound and its escalation', () {
      for (final text in [
        'Оповещение телефона ограничено: PlatformException(audio)',
        'Усиление сигнала недоступно: TimeoutException',
      ]) {
        final p = PhoneProblem.of(text)!;
        expect(p.title, Copy.problemAlarm);
        expect(p.alarm, isTrue);
        expect(p.hint, Copy.problemAlarmHint);
        expect(p.detail, text);
      }
    });

    test('recording, live debug and any other platform call', () {
      expect(
        PhoneProblem.of('Запись поездки не началась: disk')!.title,
        Copy.problemRecording,
      );
      expect(
        PhoneProblem.of('Живой дебаг не запустился: port')!.title,
        Copy.problemDebug,
      );
      final other = PhoneProblem.of('PlatformException(keepAwake)')!;
      expect(other.title, Copy.problemOther);
      expect(other.alarm, isFalse);
    });
  });

  group('on screen', () {
    late TripController trip;
    late SleepController sleep;
    late UiVoice voice;

    Future<void> pump(WidgetTester tester, Widget page) async {
      tester.view.physicalSize = const Size(828, 1792);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNsTheme(NsDesign.cockpit, Brightness.dark),
          home: Scaffold(body: page),
        ),
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
    }

    setUp(() {
      final platform = ControllerTestPlatform();
      trip = TripController(
        repository: null,
        platform: platform,
        detector: ControllerTestDetector(),
        clock: ManualClock()..us = 1000000,
        cameraFactory: (d, n, f, e, c) => ControllerTestCamera(
          detector: d,
          nowUs: n,
          onFaces: f,
          onError: e,
          onChanged: c,
        ),
      );
      sleep = SleepController(trip: trip, platform: platform);
      voice = UiVoice(platform: platform, enabled: false);
    });

    Future<void> tearDownScreen(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      voice.dispose();
      sleep.dispose();
      trip.dispose();
      await tester.pump();
    }

    testWidgets('the trip screen shows a failed alarm sound and keeps it', (
      tester,
    ) async {
      trip
        ..tripId = 'trip'
        ..sessionId = 'session'
        ..phase = TripPhase.observing
        ..calibration = testProfile()
        ..engine = ObservationEngine(
          sessionId: 'session',
          calibration: testProfile(),
        )
        ..faces = [mlKitFace()];
      final page = TripScreen(
        trip: trip,
        voice: voice,
        developerMode: false,
        onFinish: () {},
      );
      await pump(tester, page);
      expect(find.byKey(const Key('trip-problem')), findsNothing);

      trip.alertError = 'Оповещение телефона ограничено: PlatformException';
      await pump(tester, page);
      expect(find.byKey(const Key('trip-problem')), findsOneWidget);
      expect(find.text(Copy.problemAlarm), findsOneWidget);
      expect(find.textContaining('PlatformException'), findsOneWidget);
      // No «Скрыть» on the road.
      expect(find.text(Copy.problemHide), findsNothing);
      expect(tester.takeException(), isNull);
      await tearDownScreen(tester);
    });

    testWidgets('before a trip it shows and the driver may hide it', (
      tester,
    ) async {
      trip.alertError = 'Запись поездки не началась: no space';
      final page = HomeScreen(
        trip: trip,
        sleep: sleep,
        prefs: UiPrefs(onboarded: true),
        developerMode: false,
        onDeveloperMode: (_) {},
        onStart: () {},
      );
      await pump(tester, page);
      expect(find.byKey(const Key('pre-trip-problem')), findsOneWidget);
      expect(find.text(Copy.problemRecording), findsOneWidget);
      await tester.tap(find.text(Copy.problemHide));
      await tester.pump();
      expect(find.byKey(const Key('pre-trip-problem')), findsNothing);
      // A new problem shows again.
      trip.alertError = 'Усиление сигнала недоступно: timeout';
      await pump(tester, page);
      expect(find.text(Copy.problemAlarm), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tearDownScreen(tester);
    });
  });
}
