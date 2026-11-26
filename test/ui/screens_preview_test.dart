import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/domain.dart';
import 'package:nscontrol/services/sleep_controller.dart';
import 'package:nscontrol/services/trip_controller.dart';
import 'package:nscontrol/ui/design/ns_theme.dart';
import 'package:nscontrol/ui/design/tokens.dart';
import 'package:nscontrol/ui/presentation/trip_story.dart';
import 'package:nscontrol/ui/presentation/ui_prefs.dart';
import 'package:nscontrol/ui/presentation/voice.dart';
import 'package:nscontrol/ui/screens/alarm_overlay.dart';
import 'package:nscontrol/ui/screens/camera_setup_screen.dart';
import 'package:nscontrol/ui/screens/history_tab.dart';
import 'package:nscontrol/ui/screens/home_screen.dart';
import 'package:nscontrol/ui/screens/onboarding_screen.dart';
import 'package:nscontrol/ui/screens/settings_tab.dart';
import 'package:nscontrol/ui/screens/summary_screen.dart';
import 'package:nscontrol/ui/screens/trip_screen.dart';

import '../services/trip_controller_test.dart'
    show
        ControllerTestCamera,
        ControllerTestDetector,
        ControllerTestPlatform,
        mlKitFace,
        testProfile;
import 'app_test.dart' show ManualClock;

/// Every screen in every look, on an iPhone 11 frame (414 × 896 pt):
/// a smoke test (no exception, no overflow) and, with
/// `NSCONTROL_SCREENSHOTS=1`, PNG previews in `build/previews/<look>/` with
/// the real fonts, for review against the design.
void main() {
  final shots = Platform.environment['NSCONTROL_SCREENSHOTS'] == '1';
  final key = GlobalKey();

  Future<void> loadFonts(WidgetTester tester) => tester.runAsync(() async {
    for (final family in ['Geologica', 'Nunito', 'Onest']) {
      final loader = FontLoader(family);
      for (final w in [
        'Regular',
        'Medium',
        'SemiBold',
        'Bold',
        'ExtraBold',
        'Black',
      ]) {
        final bytes = File('assets/fonts/$family-$w.ttf').readAsBytesSync();
        loader.addFont(Future.value(ByteData.sublistView(bytes)));
      }
      await loader.load();
    }
    final icons = File(
      '/opt/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (icons.existsSync()) {
      final loader = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
      await loader.load();
    }
  });

  TripController newTrip(ManualClock clock) => TripController(
    repository: null,
    platform: ControllerTestPlatform(),
    detector: ControllerTestDetector(),
    clock: clock,
    // The trip reconnects a stopped camera on its tick: a fake one.
    cameraFactory: (d, n, f, e, c) => ControllerTestCamera(
      detector: d,
      nowUs: n,
      onFaces: f,
      onError: e,
      onChanged: c,
    ),
  );

  /// Observing with the given faces (an engine gives the snapshot).
  void observing(TripController trip, {bool hiddenEyes = false}) {
    trip.tripId = 'trip';
    trip.sessionId = 'session';
    trip.phase = TripPhase.observing;
    final cal = testProfile();
    trip.calibration = hiddenEyes
        ? CalibrationProfile(
            trackingId: 7,
            detector: cal.detector,
            hiddenEyes: true,
            neutralPitch: 0,
            neutralYaw: 0,
            neutralRoll: 0,
          )
        : cal;
    trip.engine = ObservationEngine(sessionId: 'session', calibration: cal);
  }

  for (final design in NsDesign.values) {
    testWidgets('every screen renders in ${design.code}', (tester) async {
      tester.view.physicalSize = const Size(828, 1792);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      if (shots) await loadFonts(tester);
      final dir = 'build/previews/${design.name}';
      var n = 0;

      Future<void> shot(
        String name,
        Widget page, {
        Brightness brightness = Brightness.dark,
        Future<void> Function()? then,
      }) async {
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildNsTheme(design, brightness),
              // A fresh state for every shot.
              home: KeyedSubtree(key: ValueKey(name), child: page),
            ),
          ),
        );
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 150));
        }
        if (then != null) await then();
        expect(tester.takeException(), isNull, reason: name);
        if (!shots) return;
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(dir).create(recursive: true);
          final file = '${(n++).toString().padLeft(2, '0')}_$name.png';
          await File('$dir/$file').writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      final clock = ManualClock()..us = 1000000;
      final trip = newTrip(clock);
      final platform = trip.platform as ControllerTestPlatform;
      final sleep = SleepController(trip: trip, platform: platform);
      final prefs = UiPrefs(design: design, onboarded: true);
      final voice = UiVoice(platform: platform, enabled: false);

      // Знакомство.
      final onboarding = OnboardingScreen(trip: trip, prefs: UiPrefs());
      await shot('onboarding_intro', Scaffold(body: onboarding));
      await shot(
        'onboarding_mount',
        Scaffold(body: onboarding),
        then: () async {
          await tester.tap(find.text('Настроить'));
          for (var i = 0; i < 4; i++) {
            await tester.pump(const Duration(milliseconds: 150));
          }
          await tester.tap(find.text('Справа от меня'));
          await tester.pump(const Duration(milliseconds: 400));
        },
      );
      await shot(
        'onboarding_sound',
        Scaffold(body: onboarding),
        then: () async {
          await tester.tap(find.text('Настроить'));
          await tester.pump(const Duration(milliseconds: 500));
          await tester.tap(find.text('Дальше'));
          await tester.pump(const Duration(milliseconds: 500));
        },
      );

      // Перед поездкой, light and dark; settings; history.
      Widget home() => Scaffold(
        body: HomeScreen(
          trip: trip,
          sleep: sleep,
          prefs: prefs,
          developerMode: false,
          onDeveloperMode: (_) {},
          onStart: () {},
        ),
      );
      await shot('pre_trip', home());
      await shot('pre_trip_light', home(), brightness: Brightness.light);
      await shot(
        'settings',
        AppSettingsPage(
          trip: trip,
          sleep: sleep,
          prefs: prefs,
          developerMode: false,
          onDeveloperMode: (_) {},
        ),
      );
      await shot('history_empty', HistoryPage(trip: trip));
      final start = DateTime.now().subtract(const Duration(minutes: 100));
      String at(int min) =>
          start.add(Duration(minutes: min)).toUtc().toIso8601String();
      const minute = 60000000;
      final story = TripStory.build(
        trip: {
          'id': 't',
          'started_at': at(0),
          'ended_at': at(100),
          'status': 'completed',
          'journal_incomplete': 0,
        },
        sessions: [
          {'id': 's1', 'started_at': at(0), 'ended_us': 50 * minute},
          {'id': 's2', 'started_at': at(60), 'ended_us': 40 * minute},
        ],
        transitions: [
          {
            'session_id': 's1',
            'at_us': 10 * minute,
            'channel': 'both',
            'available': 0,
          },
          {
            'session_id': 's1',
            'at_us': 17 * minute,
            'channel': 'both',
            'available': 1,
          },
        ],
        events: [
          {
            'session_id': 's1',
            'type': 'eyes_closed',
            'alert_requested_us': 20 * minute,
          },
          {
            'session_id': 's2',
            'type': 'eyes_closed',
            'alert_requested_us': 10 * minute,
          },
        ],
      );
      await shot('history_detail', TripDetailPage(trip: trip, story: story));

      // Настройка камеры.
      Widget camera({bool done = false}) => Scaffold(
        body: CameraSetupScreen(
          trip: trip,
          voice: voice,
          done: done,
          onCancel: () {},
        ),
      );
      trip.tripId = 'trip';
      trip.phase = TripPhase.findingFace;
      await shot('camera_search', camera());
      trip.faces = [mlKitFace(), mlKitFace(id: 8)];
      await shot('camera_many', camera());
      trip.faces = [mlKitFace()];
      trip.phase = TripPhase.calibrating;
      voice.show('Смотрите на дорогу, как обычно. Пять секунд');
      await shot('camera_capture', camera());
      trip.phase = TripPhase.observing;
      await shot('camera_done', camera(done: true));

      // В пути.
      Widget road({bool dev = false}) => Scaffold(
        body: TripScreen(
          trip: trip,
          voice: voice,
          developerMode: dev,
          onFinish: () {},
        ),
      );
      observing(trip);
      trip.faces = [mlKitFace()];
      voice.show('Готово. Слежу за дорогой');
      await shot('trip_watching', road());
      await shot(
        'trip_dimmed',
        road(),
        then: () async {
          await tester.pump(const Duration(seconds: 9));
          await tester.pump(const Duration(seconds: 1));
        },
      );
      observing(trip, hiddenEyes: true);
      await shot('trip_head_only', road());
      observing(trip);
      trip.faces = [];
      await shot('trip_unseen', road());
      trip.faces = [mlKitFace()];
      trip.tripEyesAlarms = 1;
      await shot('trip_advice', road());
      trip.tripEyesAlarms = 0;
      trip.userPaused = true;
      trip.phase = TripPhase.paused;
      await shot('trip_paused', road());
      trip.userPaused = false;
      observing(trip);
      clock.us = 6000000; // no frame for 5 s: the camera is silent
      await shot('trip_camera_silent', road());
      clock.us = 1000000;
      trip.movedText = 'Телефон сдвинулся. Смотрите на дорогу, перенастроюсь';
      await shot('trip_moved_dev', road(dev: true));
      trip.movedText = null;

      // Тревога.
      ObservationEvent event(EventType type) => ObservationEvent(
        id: 'e-${type.name}',
        sessionId: 'session',
        type: type,
        signStartedUs: 0,
        thresholdUs: 1500000,
        alertRequestedUs: 1500000,
      );
      await shot(
        'alarm_eyes',
        AlarmView(events: [event(EventType.eyesClosed)], onAcknowledge: () {}),
      );
      await shot(
        'alarm_head',
        AlarmView(
          events: [event(EventType.headPitchDown)],
          onAcknowledge: () {},
        ),
      );

      // Итог.
      trip.phase = TripPhase.idle;
      trip.tripId = null;
      await shot(
        'summary',
        Scaffold(
          body: SummaryScreen(
            trip: trip,
            tripId: 't',
            fallback: story,
            onDone: () {},
          ),
        ),
      );

      await tester.pumpWidget(const SizedBox());
      voice.dispose();
      sleep.dispose();
      trip.dispose();
      await tester.pump();
    });
  }
}
