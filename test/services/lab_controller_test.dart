import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/domain.dart';
import 'package:nscontrol/services/detector.dart';
import 'package:nscontrol/services/face_source.dart';
import 'package:nscontrol/services/lab_controller.dart';
import 'package:nscontrol/services/mlkit_signals.dart';
import 'package:nscontrol/services/platform_bridge.dart';

class FakeSource implements FaceSource {
  void Function(FaceResult)? onResult;
  bool started = false;
  @override
  List<DetectorCapabilities> get engines => [DetectorCapabilities.mlKit];
  @override
  bool get running => started;
  @override
  bool get previewMirrored => true;
  @override
  Future<void> start({
    required int Function() nowUs,
    required void Function(FaceResult) onResult,
    required void Function(Object) onError,
    required void Function() onChanged,
  }) async {
    this.onResult = onResult;
    started = true;
  }

  @override
  Future<void> stop() async => started = false;
  @override
  Widget? preview() => null;
  @override
  Future<void> dispose() async => started = false;
}

class FakePlatform extends PlatformBridge {
  final calls = <String, List<Map<String, Object?>?>>{};
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    calls.putIfAbsent(method, () => []).add(arguments);
    if (method == 'device.info') return {'model': 'iPhone12,1', 'os': 'iOS 26'};
    return {'status': 'ok'};
  }
}

DetectedFace face({double eyes = .9, double pitch = 0, int id = 1}) {
  final s = MlKitSignals.from(
    trackingId: id,
    leftEyeOpen: eyes,
    rightEyeOpen: eyes,
    eulerX: -pitch,
    eulerY: 2,
    eulerZ: 1,
  );
  return DetectedFace(
    s.toMeasurement(),
    const Rect.fromLTWH(0, 0, 100, 100),
    signals: s,
  );
}

void main() {
  late Directory dir;
  late int now;
  late FakeSource source;
  late FakePlatform platform;
  late LabController lab;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('lab');
    now = 5000000;
    source = FakeSource();
    platform = FakePlatform();
    lab = LabController(
      options: [
        LabEngineOption(
          id: 'fake',
          title: 'Fake',
          engineIds: const ['mlkit_face_detection'],
          create: () => source,
        ),
      ],
      platform: platform,
      settings: AlgorithmSettings(),
      recordingsDirectory: dir,
      startServer: false,
      clockUs: () => now,
    );
    await lab.open();
  });

  tearDown(() async {
    await lab.close();
    await dir.delete(recursive: true);
  });

  /// Feeds frames every 33 ms for [seconds], ticking the controller.
  void run(double seconds, DetectedFace? Function() make) {
    final end = now + (seconds * 1000000).round();
    while (now < end) {
      now += 33000;
      final f = make();
      source.onResult!(
        FaceResult(
          engineId: 'mlkit_face_detection',
          capturedUs: now - 20000,
          completedUs: now,
          faces: [?f],
          imageSize: const Size(480, 640),
        ),
      );
      lab.tick();
    }
  }

  test('calibration, an eyes event and the recording file', () async {
    expect(lab.phase, LabPhase.uncalibrated);
    await lab.startRecording();
    lab.calibrate();
    expect(lab.phase, LabPhase.calibrating);
    run(10.5, () => face());
    expect(lab.calibration, isNotNull);
    expect(lab.phase, LabPhase.observing);
    run(1, () => face());
    expect(lab.statusLine, 'Зона не определена');
    run(2, () => face(eyes: .05));
    expect(lab.engine!.snapshot.eyes.activeEvent, isNotNull);
    expect(lab.statusLine, startsWith('Глаза закрыты'));
    run(1, () => face());
    run(.5, () => null);
    final file = await lab.stopRecording();
    final reader = RecordingReader.parse(await file!.readAsString());
    expect(reader.meta['recordingId'], isNotEmpty);
    expect(reader.meta['engines'], ['mlkit_face_detection']);
    expect(reader.meta['device'], 'iPhone12,1');
    final calibration = reader.ofType('calibration').single;
    expect(calibration['profile']['trackingId'], 1);
    final signals = reader.signals().toList();
    expect(signals.length, greaterThan(400));
    expect(signals.first.eyeOpenLeft, .9);
    expect(reader.ofType('frame').last['faceCount'], 0);
    final events = reader.ofType('event').toList();
    expect(events.first['change'], 'started');
    expect(events.first['event']['type'], 'eyes_closed');
    expect(events.any((e) => e['change'] == 'ended'), isTrue);
    final derived = reader.ofType('derived').toList();
    expect(derived.last['zone'], 'unknown');
    expect(derived.last['eyes'], isA<Map<String, dynamic>>());
    // Times start at the recording and never go backwards for frames.
    final captured = reader.ofType('frame').map((l) => l['capturedUs'] as int);
    expect(captured.first, greaterThanOrEqualTo(0));
    expect(captured.toList(), orderedEquals(captured.toList()..sort()));
  });

  test('a scenario calibrates first, labels each step and records', () async {
    await lab.startScenario(signsV1());
    expect(lab.recording, isTrue);
    expect(lab.phase, LabPhase.calibrating);
    run(10.5, () => face());
    expect(lab.scenario, isNotNull);
    run(signsV1().durationUs / 1000000 + 3, () => face());
    expect(lab.scenario, isNull);
    final file = await lab.stopRecording() ?? lab.recorder.file;
    final reader = RecordingReader.parse(await file!.readAsString());
    final labels = reader.ofType('label').toList();
    expect(labels.length, signsV1().cues.where((c) => c.isLabel).length);
    expect(labels.first['scenario'], 'signs-v1');
    expect(labels.map((l) => l['step']).toSet(), signsV1().steps.toSet());
    expect(platform.calls['speech.say'], isNotEmpty);
  });

  test('cancelling a scenario closes the open label as aborted', () async {
    lab.calibrate();
    run(10.5, () => face());
    await lab.startScenario(signsV1());
    final firstStart = signsV1().cues.firstWhere((c) => c.edge == 'start');
    run(firstStart.atUs / 1000000 + 1.2, () => face());
    expect(lab.scenario!.openSteps, isNotEmpty);
    await lab.cancelScenario();
    final file = await lab.stopRecording();
    final labels = RecordingReader.parse(
      await file!.readAsString(),
    ).ofType('label').toList();
    expect(labels.last['edge'], 'end');
    expect(labels.last['aborted'], isTrue);
  });

  test('a new tracking id keeps the calibration in the lab', () async {
    lab.calibrate();
    run(10.5, () => face());
    run(.5, () => null);
    run(.5, () => face(id: 2));
    expect(lab.calibration!.trackingId, 2);
    expect(lab.engine!.snapshot.requiresRecalibration, isFalse);
    expect(lab.notes.first.text, contains('перепривязано'));
  });
}
