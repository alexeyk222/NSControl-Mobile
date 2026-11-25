import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/attention_zones.dart';
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

DetectedFace face({
  double eyes = .9,
  double pitch = 0,
  double yaw = 0,
  int id = 1,
}) {
  final s = MlKitSignals.from(
    trackingId: id,
    leftEyeOpen: eyes,
    rightEyeOpen: eyes,
    eulerX: -pitch,
    eulerY: 2 + yaw,
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
    lab.setMount(position: 'vent_left', angleDeg: 35, distanceCm: 55);
    await lab.startRecording();
    lab.calibrate();
    expect(lab.phase, LabPhase.calibrating);
    run(10.5, () => face());
    expect(lab.calibration, isNotNull);
    expect(lab.phase, LabPhase.observing);
    run(1, () => face());
    expect(lab.statusLine, 'Дорога');
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
    expect(calibration['zones']['mirrorsCalibrated'], isFalse);
    expect(reader.meta['attentionSettings'], isNotNull);
    expect(reader.meta['mount'], {
      'position': 'vent_left',
      'angleDeg': 35,
      'distanceCm': 55,
    });
    final signals = reader.signals().toList();
    expect(signals.length, greaterThan(400));
    expect(signals.first.eyeOpenLeft, .9);
    expect(reader.ofType('frame').last['faceCount'], 0);
    final events = reader.ofType('event').toList();
    expect(events.first['change'], 'started');
    expect(events.first['event']['type'], 'eyes_closed');
    expect(events.any((e) => e['change'] == 'ended'), isTrue);
    final derived = reader.ofType('derived').toList();
    expect(derived.map((d) => d['zone']), contains('road'));
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

  test('driver continuity restores a new tracking id after a loss', () async {
    lab.setAttentionSettings(const AttentionSettings.acceptance());
    lab.calibrate();
    run(10.5, () => face());
    await lab.startRecording();
    run(1, () => face());
    run(.5, () => null);
    expect(lab.driverDecision, 'no_face');
    run(.5, () => face(id: 2));
    // The calibration is untouched: the pipeline gives the face its id back.
    expect(lab.calibration!.trackingId, 1);
    expect(lab.engine!.snapshot.requiresRecalibration, isFalse);
    expect(lab.driverDecision, 'same');
    expect(lab.notes.map((n) => n.text), anyElement(contains('восстановлен')));
    final file = await lab.stopRecording();
    final derived = RecordingReader.parse(
      await file!.readAsString(),
    ).ofType('derived').map((d) => d['driver']).toSet();
    expect(derived, containsAll(['same', 'no_face']));
  });

  test('two faces go to the engine directly and suspend it', () async {
    lab.calibrate();
    run(10.5, () => face());
    final f2 = face(id: 7);
    final end = now + 1000000;
    while (now < end) {
      now += 33000;
      source.onResult!(
        FaceResult(
          engineId: 'mlkit_face_detection',
          capturedUs: now - 20000,
          completedUs: now,
          faces: [face(), f2],
          imageSize: const Size(480, 640),
        ),
      );
      lab.tick();
    }
    expect(lab.driverDecision, 'ambiguous');
    expect(lab.engine!.snapshot.requiresRecalibration, isTrue);
  });

  test('lab mode raises a distraction event, acceptance does not', () async {
    lab.calibrate();
    run(10.5, () => face());
    expect(lab.attentionSettings!.isAcceptance, isFalse);
    await lab.startRecording();
    run(1, () => face());
    run(4, () => face(yaw: -50));
    run(1, () => face());
    final file = await lab.stopRecording();
    final events = RecordingReader.parse(
      await file!.readAsString(),
    ).ofType('event').where((e) => e['event']['type'] == 'distraction');
    expect(events.first['change'], 'started');
    expect(events.any((e) => e['change'] == 'ended'), isTrue);

    lab.setAttentionSettings(const AttentionSettings.acceptance());
    expect(lab.attentionSettings!.isAcceptance, isTrue);
    await lab.startRecording();
    run(1, () => face());
    run(4, () => face(yaw: -50));
    run(1, () => face());
    final second = await lab.stopRecording();
    final reader = RecordingReader.parse(await second!.readAsString());
    expect(
      reader.ofType('event').where((e) => e['event']['type'] == 'distraction'),
      isEmpty,
    );
    expect(reader.meta['attentionSettings'], isNotNull);
  });

  test('mirror calibration writes calibrated zones', () async {
    lab.calibrate();
    run(10.5, () => face());
    await lab.startRecording();
    lab.calibrateMirrors();
    expect(lab.calibratingMirrors, isTrue);
    run(20, () {
      final p = lab.prompt ?? '';
      if (p.contains('левое')) return face(yaw: 38);
      if (p.contains('правое')) return face(yaw: -52);
      if (p.contains('салонное')) return face(yaw: -26, pitch: -14);
      return face();
    });
    expect(lab.calibratingMirrors, isFalse);
    expect(lab.zones!.mirrorsCalibrated, isTrue);
    final file = await lab.stopRecording();
    final calibrations = RecordingReader.parse(
      await file!.readAsString(),
    ).ofType('calibration').toList();
    expect(calibrations.last['zones']['mirrorsCalibrated'], isTrue);
    expect(lab.notes.map((n) => n.text), contains('Зеркала откалиброваны'));
  });

  test('side mount: head only by default, eyes with the 45° option', () async {
    lab.calibrate();
    run(10.5, () => face(yaw: 35));
    expect(lab.calibration, isNotNull);
    expect(lab.calibration!.hiddenEyes, isTrue);
    expect(
      lab.notes.map((n) => n.text),
      anyElement(contains('глаза не оцениваются')),
    );
    // The automata get the road-frame profile: a nod relative to the road.
    expect(lab.engine!.calibration.neutralYaw, 0);

    lab.setEyeLimit45(true);
    lab.calibrate();
    run(10.5, () => face(yaw: 35));
    expect(lab.calibration!.detector.eyeYawLimit, 45);
    expect(lab.calibration!.hiddenEyes, isFalse);
    run(2, () => face(yaw: 35, eyes: .05));
    expect(lab.engine!.snapshot.eyes.activeEvent, isNotNull);

    lab.setAttentionSettings(const AttentionSettings.acceptance());
    lab.calibrate();
    run(10.5, () => face(yaw: 35));
    expect(lab.error, isNotNull);
    expect(lab.notes.first.text, startsWith('Калибровка не удалась'));
  });
}
