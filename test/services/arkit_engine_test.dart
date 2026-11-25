import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/arkit_geometry.dart';
import 'package:nscontrol/logic/clock_map.dart';
import 'package:nscontrol/logic/domain.dart';
import 'package:nscontrol/services/arkit_engine.dart';
import 'package:nscontrol/services/face_source.dart';

const _method = MethodChannel('test/arkit');
const _events = EventChannel('test/arkit/events');

/// Apple-convention face 0.5 m in front of the camera, looking at it.
List<double> _neutralFace() => [
  0, 1, 0, 0, // face +x (own left) = camera +y
  -1, 0, 0, 0, // face +y (up) = camera −x
  0, 0, 1, 0, // face +z (to camera) = camera +z
  0, 0, -.5, 1,
];

Map<String, Object?> _arkitEvent({
  required int captured,
  required int delivered,
  bool tracked = true,
  List<double>? display,
}) => {
  'type': 'arkit',
  'capturedUptimeUs': captured,
  'deliveredUptimeUs': delivered,
  'imageWidth': 1280,
  'imageHeight': 720,
  'gravityUp': [-1.0, 0.0, 0.0],
  'cameraTracking': 'normal',
  'lightIntensity': 900.0,
  'displayTransform': ?display,
  'faces': [
    {
      'id': 1,
      'tracked': tracked,
      if (tracked) 'faceInCamera': _neutralFace(),
      if (tracked) 'lookAt': [0.0, 0.0, 1.0],
      if (tracked) 'blendshapes': {'eyeBlink_L': .05, 'eyeBlink_R': .1},
      if (tracked) 'bounds': [100.0, 200.0, 300.0, 400.0],
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  group('ClockMap', () {
    test('keeps the fastest delivery in the window', () {
      final clock = ClockMap(windowUs: 1000);
      clock.sample(nativeUs: 100, localUs: 5150); // latency 50
      clock.sample(nativeUs: 200, localUs: 5210); // latency 10 → best
      clock.sample(nativeUs: 300, localUs: 5330);
      expect(clock.offsetUs, 5010);
      expect(clock.toLocal(1000), 6010);
      // The best sample ages out; the next best in the window takes over.
      clock.sample(nativeUs: 1260, localUs: 6300);
      expect(clock.offsetUs, 5030);
    });

    test('throws before the first sample', () {
      expect(() => ClockMap().toLocal(1), throwsStateError);
    });
  });

  group('ArkitFaceSource', () {
    late List<MethodCall> calls;
    late MockStreamHandlerEventSink sink;
    var now = 0;

    setUp(() {
      calls = [];
      now = 1000000;
      messenger.setMockMethodCallHandler(_method, (call) async {
        calls.add(call);
        return switch (call.method) {
          'start' => {
            'width': 1280,
            'height': 720,
            'fps': 60,
            'maxFaces': 2,
            'mlKitAvailable': true,
            'textureId': 7,
            'uptimeUs': 50000000,
          },
          _ => null,
        };
      });
      messenger.setMockStreamHandler(
        _events,
        MockStreamHandler.inline(
          onListen: (args, events) {
            sink = events;
          },
        ),
      );
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(_method, null);
      messenger.setMockStreamHandler(_events, null);
    });

    ArkitFaceSource source({bool compare = false}) => ArkitFaceSource(
      compare: compare,
      engine: ArkitEngine(method: _method, events: _events),
    );

    test('maps ARKit frames onto the lab clock and contract signals', () async {
      final results = <FaceResult>[];
      final errors = <Object>[];
      var changes = 0;
      final s = source();
      expect(s.engines, [arkitCapabilities]);
      await s.start(
        nowUs: () => now,
        onResult: results.add,
        onError: errors.add,
        onChanged: () => changes++,
      );
      expect(s.running, isTrue);
      expect(calls.single.method, 'start');
      expect(calls.single.arguments['compareMlKit'], false);
      // Native 50 s ↔ local 1 s at start.
      now = 1040000;
      sink.success(
        _arkitEvent(
          captured: 50020000,
          delivered: 50030000,
          display: [0, 1, -1, 0, 1, 0],
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(errors, isEmpty);
      final r = results.single;
      expect(r.engineId, 'arkit_face_tracking');
      // Offset from the start reply (1 s − 50 s); delivery took 10 ms more.
      expect(r.completedUs, 1030000);
      expect(r.capturedUs, 1020000);
      expect(r.imageSize, const Size(720, 1280));
      final face = r.faces.single;
      expect(face.bounds, const Rect.fromLTWH(100, 200, 300, 400));
      expect(face.signals!.headYawLeft, closeTo(0, 1e-9));
      expect(face.signals!.headPitchDown, closeTo(0, 1e-9));
      expect(face.signals!.distanceM, closeTo(.5, 1e-9));
      final FaceBox box = face.signals!.box!;
      expect(box.left, closeTo(100 / 720, 1e-12));
      expect(box.top, closeTo(200 / 1280, 1e-12));
      expect(box.width, closeTo(300 / 720, 1e-12));
      expect(box.height, closeTo(400 / 1280, 1e-12));
      expect(face.measurement.leftEye, closeTo(.95, 1e-12));
      expect(face.measurement.rightEye, closeTo(.9, 1e-12));
      expect(face.measurement.hasHeadAngles, isTrue);
      expect(s.engine.display, (quarterTurns: 1, mirrored: false));
      expect(s.previewMirrored, isFalse);
      expect(changes, greaterThanOrEqualTo(2));
      await s.stop();
      expect(calls.last.method, 'stop');
      expect(s.running, isFalse);
    });

    test('untracked faces reach the automata without numbers', () async {
      final results = <FaceResult>[];
      final s = source();
      await s.start(
        nowUs: () => now,
        onResult: results.add,
        onError: (_) {},
        onChanged: () {},
      );
      sink.success(
        _arkitEvent(captured: 50010000, delivered: 50012000, tracked: false),
      );
      await Future<void>.delayed(Duration.zero);
      final face = results.single.faces.single;
      expect(face.measurement.trackingId, 1);
      expect(face.measurement.hasEyes, isFalse);
      expect(face.measurement.hasHeadAngles, isFalse);
      expect(face.signals!.tracked, isFalse);
      await s.dispose();
    });

    test('comparison mode gives ML Kit the same capturedUs', () async {
      final results = <FaceResult>[];
      final raws = <Map<String, Object?>>[];
      final s = ArkitFaceSource(
        compare: true,
        engine: ArkitEngine(method: _method, events: _events),
        onRaw: (_, raw) => raws.add(raw),
      );
      expect(s.engines.map((e) => e.id), [
        'arkit_face_tracking',
        'mlkit_face_detection',
      ]);
      await s.start(
        nowUs: () => now,
        onResult: results.add,
        onError: (e) => fail('$e'),
        onChanged: () {},
      );
      expect(calls.single.arguments['compareMlKit'], true);
      now = 1050000;
      sink.success(_arkitEvent(captured: 50020000, delivered: 50040000));
      await Future<void>.delayed(Duration.zero);
      // A faster delivery afterwards moves the clock offset …
      now = 1060000;
      sink.success(_arkitEvent(captured: 50055000, delivered: 50062000));
      // … but the ML Kit result of the first frame keeps its capturedUs.
      now = 1070000;
      sink.success({
        'type': 'mlkit',
        'capturedUptimeUs': 50020000,
        'completedUptimeUs': 50065000,
        'imageWidth': 720,
        'imageHeight': 1280,
        'orientation': 'leftMirrored',
        'faces': [
          {
            'trackingId': 3,
            'bounds': [1.0, 2.0, 3.0, 4.0],
            'eulerX': 5.0,
            'eulerY': -12.0,
            'eulerZ': 2.0,
            'leftEyeOpen': .8,
            'rightEyeOpen': .7,
          },
        ],
      });
      await Future<void>.delayed(Duration.zero);
      expect(results.map((r) => r.engineId), [
        'arkit_face_tracking',
        'arkit_face_tracking',
        'mlkit_face_detection',
      ]);
      expect(results[2].capturedUs, results[0].capturedUs);
      final ml = results[2].faces.single;
      expect(ml.measurement.pitchDown, -5);
      expect(ml.measurement.yaw, -12);
      expect(ml.signals!.engineId, 'mlkit_face_detection');
      expect(ml.signals!.headYawLeft, -12);
      // Analysed mirrored: the contract box is flipped back.
      expect(ml.signals!.box!.left, closeTo(1 - 4 / 720, 1e-12));
      expect(ml.signals!.box!.top, closeTo(2 / 1280, 1e-12));
      expect(raws.first['faces'], isA<List<Object?>>());
      expect(raws.last, {'orientation': 'leftMirrored'});
      await s.dispose();
    });

    test('native errors and stats are reported', () async {
      final errors = <Object>[];
      final stats = <ArkitStats>[];
      final s = ArkitFaceSource(
        engine: ArkitEngine(method: _method, events: _events),
        onStats: stats.add,
      );
      await s.start(
        nowUs: () => now,
        onResult: (_) {},
        onError: errors.add,
        onChanged: () {},
      );
      now = 1600000;
      sink.success({
        'type': 'stats',
        'uptimeUs': 50500000,
        'arFrames': 60,
        'sent': 60,
        'droppedEvents': 0,
        'mlKitDone': 0,
        'mlKitSkipped': 0,
        'mlKitErrors': 0,
        'mlKitBusyUs': 0,
        'thermal': 'fair',
        'lowPower': false,
        'batteryState': 'unplugged',
        'battery': .81,
      });
      sink.success({
        'type': 'error',
        'code': 'camera_unauthorized',
        'message': 'denied',
      });
      await Future<void>.delayed(Duration.zero);
      expect(stats.single.arFrames, 60);
      expect(stats.single.toJson()['type'], 'device');
      expect(stats.single.toJson()['thermal'], 'fair');
      expect(stats.single.atUs, 1500000);
      expect(errors.single.toString(), contains('Нет доступа к камере'));
      await s.dispose();
    });

    test('lab options list both variants', () {
      final options = arkitLabEngineOptions();
      expect(options.map((o) => o.id), ['arkit', 'arkit_mlkit']);
      expect(options.last.engineIds, [
        'arkit_face_tracking',
        'mlkit_face_detection',
      ]);
      final created = options.last.create();
      expect(created.engines, hasLength(2));
    });

    testWidgets('preview shows the texture rotated upright', (tester) async {
      final s = source();
      await tester.runAsync(
        () => s.start(
          nowUs: () => now,
          onResult: (_) {},
          onError: (_) {},
          onChanged: () {},
        ),
      );
      final widget = s.preview()!;
      await tester.pumpWidget(
        Center(child: SizedBox(width: 180, child: widget)),
      );
      expect(find.byType(Texture), findsOneWidget);
      final box = tester.widget<RotatedBox>(find.byType(RotatedBox));
      expect(box.quarterTurns, 1);
      expect(tester.getSize(find.byType(AspectRatio)).height, closeTo(320, .1));
      await tester.runAsync(s.stop);
      expect(s.preview(), isNull);
    });
  });
}
