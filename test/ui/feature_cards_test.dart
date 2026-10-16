import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/domain.dart';
import 'package:nscontrol/services/trip_controller.dart';
import 'package:nscontrol/services/wearable_gateway.dart';
import 'package:nscontrol/ui/sleep_week_card.dart';
import 'package:nscontrol/ui/vigilance_card.dart';
import '../services/trip_controller_test.dart'
    show ControllerTestDetector, ControllerTestPlatform, ControllerTestCamera;

final _screenshots = Platform.environment['NSCONTROL_SCREENSHOTS'] == '1';

Future<void> _loadFonts(WidgetTester tester) async {
  if (!_screenshots) return;
  await tester.runAsync(() async {
    final fonts = {
      'Roboto':
          '.tooling/flutter/engine/src/flutter/txt/third_party/fonts/Roboto-Regular.ttf',
      'MaterialIcons':
          '.tooling/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    };
    for (final entry in fonts.entries) {
      final loader = FontLoader(entry.key)
        ..addFont(
          Future.value(
            ByteData.sublistView(await File(entry.value).readAsBytes()),
          ),
        );
      await loader.load();
    }
  });
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (!_screenshots) return;
  await tester.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject() as RenderRepaintBoundary)
            .toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory('build/previews').create(recursive: true);
    await File(
      'build/previews/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Widget _frame(GlobalKey key, Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff126D62)),
    scaffoldBackgroundColor: const Color(0xffF3F6F4),
  ),
  home: Scaffold(
    body: Center(
      child: RepaintBoundary(
        key: key,
        child: SizedBox(
          width: 375,
          child: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('vigilance card renders trends, drive time and watch vitals', (
    tester,
  ) async {
    await _loadFonts(tester);
    tester.view.physicalSize = const Size(375, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final trip = TripController(
      repository: null,
      platform: ControllerTestPlatform(),
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
    final now = trip.clock.elapsedMicroseconds;
    for (var t = now - 5040000000; t <= now; t += 60000000) {
      trip.drive.active(t);
    }
    trip.fatigue = const FatigueSnapshot(
      level: FatigueLevel.moderate,
      perclos: .09,
      blinksPerMinute: 21,
      meanBlinkMs: 240,
      longBlinks: 2,
      nods: 1,
      eyeCoverage: .92,
    );
    trip.vitals = WearableVitals(
      receivedUs: now,
      heartRate: 64,
      bodyBattery: 38,
      stress: 22,
    );
    final key = GlobalKey();
    await tester.pumpWidget(_frame(key, VigilanceCard(trip: trip)));
    await tester.pump();
    expect(find.text('Умеренные признаки усталости'), findsOneWidget);
    expect(find.text('Без перерыва: 1 ч 24 мин'), findsOneWidget);
    expect(find.textContaining('Body Battery 38'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _capture(tester, key, 'vigilance');
    await tester.pumpWidget(const SizedBox());
    trip.dispose();
  });

  testWidgets('weekly sleep card shows gaps without counting them as zero', (
    tester,
  ) async {
    await _loadFonts(tester);
    tester.view.physicalSize = const Size(375, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var n = 0;
    SleepRecord night(int daysAgo, double hours) {
      final wake = DateTime(2026, 10, 16 - daysAgo, 7);
      return SleepRecord(
        source: 'Garmin Connect',
        sourceId: 'n${n++}',
        start: wake.subtract(Duration(minutes: (hours * 60).round())),
        end: wake,
      );
    }

    final week = SleepWeek.build(
      records: [
        night(6, 7.5),
        night(5, 6.2),
        night(3, 8.1),
        night(2, 5.4),
        night(1, 7.0),
        night(0, 6.6),
      ],
      source: 'Garmin Connect',
      now: DateTime(2026, 10, 16, 12),
    );
    final key = GlobalKey();
    await tester.pumpWidget(
      _frame(key, SleepWeekCard(week: week, source: 'Garmin Connect')),
    );
    await tester.pump();
    expect(find.text('Записано ночей: 6 из 7'), findsOneWidget);
    expect(find.textContaining('Недобор до 7 ч'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _capture(tester, key, 'sleep_week');
  });
}
