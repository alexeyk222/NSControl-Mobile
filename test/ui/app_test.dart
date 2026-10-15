import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/main.dart';
import 'package:nscontrol/logic/domain.dart';
import 'package:nscontrol/services/sleep_controller.dart';
import 'package:nscontrol/services/trip_controller.dart';
import '../services/trip_controller_test.dart'
    show
        ControllerTestDetector,
        ControllerTestPlatform,
        ControllerTestCamera,
        testProfile;

void main() {
  testWidgets('active camera alarm remains visible on the settings tab', (
    tester,
  ) async {
    final platform = ControllerTestPlatform();
    final trip = TripController(
      repository: null,
      platform: platform,
      detector: ControllerTestDetector(),
      cameraFactory: (d, n, f, e, c) => ControllerTestCamera(
        detector: d,
        nowUs: n,
        onFaces: f,
        onError: e,
        onChanged: c,
      ),
    );
    trip.tripId = 'trip';
    trip.sessionId = 'session';
    trip.phase = TripPhase.observing;
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
    final sleep = SleepController(trip: trip, platform: platform);
    await tester.pumpWidget(NSControlApp(trip: trip, sleep: sleep));
    await tester.pump();
    await tester.tap(find.text('Настройки'));
    await tester.pump();
    expect(find.byKey(const Key('global-alarm')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    sleep.dispose();
    trip.dispose();
    await tester.pump();
  });

  testWidgets(
    'Russian mobile UI explains missing data and navigates without a camera',
    (tester) async {
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final platform = ControllerTestPlatform();
      final trip = TripController(
        repository: null,
        platform: platform,
        detector: ControllerTestDetector(),
        cameraFactory: (d, n, f, e, c) => ControllerTestCamera(
          detector: d,
          nowUs: n,
          onFaces: f,
          onError: e,
          onChanged: c,
        ),
      );
      final sleep = SleepController(trip: trip, platform: platform);
      if (Platform.environment['NSCONTROL_SCREENSHOTS'] == '1') {
        await tester.runAsync(() async {
          final fonts = {
            'Roboto':
                '.tooling/flutter/engine/src/flutter/txt/third_party/fonts/Roboto-Regular.ttf',
            'MaterialIcons':
                '.tooling/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          };
          for (final entry in fonts.entries) {
            final loader = FontLoader(entry.key);
            loader.addFont(
              Future.value(
                ByteData.sublistView(await File(entry.value).readAsBytes()),
              ),
            );
            await loader.load();
          }
        });
      }
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: NSControlApp(trip: trip, sleep: sleep),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Перед поездкой'), findsOneWidget);
      expect(find.text('Без записи фото и видео'), findsOneWidget);
      expect(find.text('Недостаточно данных для оценки сна'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (Platform.environment['NSCONTROL_SCREENSHOTS'] == '1') {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('build/previews').create(recursive: true);
          await File(
            'build/previews/trip.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.text('Сон и часы'));
      await tester.pumpAndSettle();
      expect(find.text('Источник сна не подключён'), findsOneWidget);
      expect(find.text('Разрешить чтение сна'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Настройки'));
      await tester.pumpAndSettle();
      expect(find.text('Пороговые параметры'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      sleep.dispose();
      trip.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'landscape and dark theme preserve navigation and readable content',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final platform = ControllerTestPlatform();
      final trip = TripController(
        repository: null,
        platform: platform,
        detector: ControllerTestDetector(),
        cameraFactory: (d, n, f, e, c) => ControllerTestCamera(
          detector: d,
          nowUs: n,
          onFaces: f,
          onError: e,
          onChanged: c,
        ),
      );
      final sleep = SleepController(trip: trip, platform: platform);
      await tester.pumpWidget(
        NSControlApp(trip: trip, sleep: sleep, initialTheme: ThemeMode.dark),
      );
      await tester.pumpAndSettle();
      expect(find.text('Рекомендация отдыха'), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      sleep.dispose();
      trip.dispose();
      await tester.pump();
    },
  );
}
