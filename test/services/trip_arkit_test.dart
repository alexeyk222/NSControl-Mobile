import 'dart:io';
import 'dart:ui';

import 'package:flutter/widgets.dart' show Widget;
import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/data/trip_repository.dart';
import 'package:nscontrol/logic/arkit_geometry.dart' show arkitCapabilities;
import 'package:nscontrol/logic/attention_zones.dart';
import 'package:nscontrol/logic/detection_profile.dart';
import 'package:nscontrol/logic/domain.dart';
import 'package:nscontrol/logic/replay.dart';
import 'package:nscontrol/services/arkit_engine.dart';
import 'package:nscontrol/services/detector.dart';
import 'package:nscontrol/services/face_source.dart';
import 'package:nscontrol/services/lab_recorder.dart';
import 'package:nscontrol/services/trip_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'trip_controller_test.dart' as fixtures;

/// ARKit stand-in: the test pushes results through [emit].
class FakeArkit implements FaceSource {
  FakeArkit(this.options, this.onStats, this.onRaw, {this.failStart = false});
  final ArkitOptions options;
  final void Function(ArkitStats) onStats;
  final void Function(FaceResult, Map<String, Object?>) onRaw;
  final bool failStart;
  void Function(FaceResult)? _onResult;
  void Function(Object)? onError;
  bool _running = false, disposed = false;

  @override
  List<DetectorCapabilities> get engines => [arkitCapabilities];
  @override
  bool get running => _running;
  @override
  bool get previewMirrored => true;
  @override
  Future<void> start({
    required int Function() nowUs,
    required void Function(FaceResult) onResult,
    required void Function(Object) onError,
    required void Function() onChanged,
  }) async {
    if (failStart) throw StateError('ARKit: session failed');
    _onResult = onResult;
    this.onError = onError;
    _running = true;
  }

  void deliver(FaceResult result) => _onResult!(result);

  void emit(List<FaceSignals> faces, int captured, {int? completed}) =>
      _onResult!(
        FaceResult(
          engineId: arkitCapabilities.id,
          capturedUs: captured,
          completedUs: completed ?? captured + 20000,
          faces: [
            for (final s in faces)
              DetectedFace(
                s.toMeasurement(),
                const Rect.fromLTWH(0, 0, 100, 100),
                signals: s,
              ),
          ],
        ),
      );

  @override
  Future<void> stop() async => _running = false;
  @override
  Widget? preview() => null;
  @override
  Future<void> dispose() async {
    disposed = true;
    _running = false;
  }
}

/// ARKit face on a left-vent mount: the camera sees the face [view]° to the
/// side; [pitch] is a nod down, [eyeDown] the eyes looking down in the head.
FaceSignals arkitFace({
  double view = 38,
  double pitch = 0,
  double open = .9,
  double eyeDown = 0,
  int id = 11,
  FaceBox? box,
}) => FaceSignals(
  engineId: arkitCapabilities.id,
  trackingId: id,
  box: box ?? const FaceBox(left: .3, top: .3, width: .3, height: .3),
  distanceM: .5,
  headYawLeft: view,
  headPitchDown: pitch,
  headRollRight: 0,
  gazeLeft: view,
  gazeDown: pitch + eyeDown,
  eyeGazeLeft: 0,
  eyeGazeDown: eyeDown,
  eyeOpenLeft: open,
  eyeOpenRight: open,
  blendshapes: {
    Blendshape.eyeBlinkLeft: 1 - open,
    Blendshape.eyeBlinkRight: 1 - open,
    Blendshape.eyeLookDownLeft: (eyeDown / 30).clamp(0, 1),
    Blendshape.eyeLookDownRight: (eyeDown / 30).clamp(0, 1),
    Blendshape.eyeSquintLeft: 0,
    Blendshape.eyeSquintRight: 0,
  },
);

/// A trip clock the test moves by hand.
class FakeClock implements Stopwatch {
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
  bool get isRunning => false;
  @override
  void start() {}
  @override
  void stop() {}
  @override
  void reset() => us = 0;
}

void main() {
  late TripRepository repository;
  late TripController trip;
  late fixtures.ControllerTestPlatform platform;
  late fixtures.ControllerTestCamera camera;
  final sources = <FakeArkit>[];
  var supported = true, failStart = false;
  setUpAll(sqfliteFfiInit);

  Future<void> open({Stopwatch? clock}) async {
    repository = await TripRepository.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    platform = fixtures.ControllerTestPlatform();
    trip = TripController(
      repository: repository,
      platform: platform,
      detector: fixtures.ControllerTestDetector(),
      cameraFactory: (d, n, f, e, c) => camera = fixtures.ControllerTestCamera(
        detector: d,
        nowUs: n,
        onFaces: f,
        onError: e,
        onChanged: c,
      ),
      arkitFactory: (options, onStats, onRaw) {
        final s = FakeArkit(options, onStats, onRaw, failStart: failStart);
        sources.add(s);
        return s;
      },
      arkitSupported: () async => supported,
      clock: clock,
    );
  }

  setUp(() async {
    sources.clear();
    supported = true;
    failStart = false;
    await open();
  });
  tearDown(() async {
    trip.dispose();
    await trip.pendingWrites;
    await repository.close();
  });

  FakeArkit arkit() => sources.last;

  /// Calibrates on [make] frames for 10.2 s on the stopped clock.
  void calibrateOn(FaceSignals Function() make) {
    trip.clock.stop();
    final base = trip.clock.elapsedMicroseconds;
    arkit().emit([make()], base);
    trip.confirmFace(make().trackingId!);
    final start = trip.calibrationStartUs;
    for (var t = start; t <= start + 10200000; t += 33000) {
      arkit().emit([make()], t);
    }
    trip.finishCalibration(start + 10300000);
  }

  var lastUs = 0;

  /// Frames of the observing session for [seconds] (null face: no face).
  void observe(double seconds, FaceSignals? Function() make) {
    final base = trip.sessionBaseUs;
    final from = lastUs < base ? base + 33000 : lastUs + 33000;
    for (var t = from; t <= from + (seconds * 1000000).round(); t += 33000) {
      final f = make();
      arkit().emit([?f], t);
      lastUs = t;
    }
  }

  setUp(() => lastUs = 0);

  ArkitStats stats(String thermal, {int sent = 30}) => ArkitStats(
    atUs: trip.clock.elapsedMicroseconds,
    arFrames: 30,
    sent: sent,
    droppedEvents: 0,
    mlKitDone: 0,
    mlKitSkipped: 0,
    mlKitErrors: 0,
    mlKitBusyUs: 0,
    thermal: thermal,
    lowPower: false,
    batteryState: 'unplugged',
    battery: .7,
  );

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  group('heat (FR-DRV-08)', () {
    setUp(() => trip.announceHeat = true);

    test('silent by default: economy runs, nothing said or shown', () async {
      trip.announceHeat = false;
      await trip.start();
      calibrateOn(arkitFace);
      observe(1, arkitFace);
      arkit().onStats(stats('critical'));
      trip.tick();
      await settle();
      expect(platform.spoken.where((t) => t.startsWith('Телефон')), isEmpty);
      expect(platform.testAlertCalls, 0);
      expect(trip.heatText, isNull);
      expect(trip.heat.economy, isTrue);
      expect(arkit().options.emitEvery, 2);
    });

    test('serious: economy at 15 a second, no preview, said once', () async {
      await trip.start();
      calibrateOn(arkitFace);
      observe(1, arkitFace);
      expect(arkit().options.emitEvery, 1);
      arkit().onStats(stats('serious'));
      expect(
        platform.spoken.last,
        'Телефон нагрелся. Продолжаю в экономном режиме',
      );
      expect(trip.heatText, 'Телефон нагрелся, экономлю');
      expect(trip.showPreview, isFalse);
      trip.tick();
      await settle();
      expect(sources, hasLength(2));
      expect(sources.first.disposed, isTrue);
      expect(arkit().options.emitEvery, 2);
      expect(arkit().options.preview, isFalse);
      expect(arkit().options.fps, 30);
      // Observation goes on after the restart.
      expect(trip.phase, TripPhase.observing);
      observe(2, () => arkitFace(open: .05));
      expect(trip.snapshot!.eyes.activeEvent, isNotNull);
      arkit().onStats(stats('serious', sent: 15));
      expect(
        platform.spoken.where((t) => t.startsWith('Телефон нагрелся')),
        hasLength(1),
      );
    });

    test('no restart while an automaton has a sign or an event', () async {
      await trip.start();
      calibrateOn(arkitFace);
      observe(1, arkitFace);
      observe(2, () => arkitFace(open: .05));
      expect(trip.snapshot!.eyes.activeEvent, isNotNull);
      arkit().onStats(stats('serious'));
      trip.tick();
      await settle();
      expect(sources, hasLength(1));
      trip.acknowledge(trip.snapshot!.activeEvents.map((e) => e.id).toSet());
      observe(3, arkitFace);
      trip.tick();
      await settle();
      expect(sources, hasLength(2));
      expect(arkit().options.emitEvery, 2);
    });

    test('critical: tone and voice, repeated every 5 minutes', () async {
      await trip.start();
      calibrateOn(arkitFace);
      arkit().onStats(stats('critical'));
      expect(
        platform.spoken.last,
        'Телефон перегрелся. Уберите его от горячего воздуха',
      );
      expect(platform.testAlertCalls, 1);
      expect(trip.heatText, contains('Телефон перегрелся'));
      arkit().onStats(stats('critical'));
      expect(platform.testAlertCalls, 1);
    });
  });

  group('holder moved (FR-CAL-08)', () {
    /// Profile v1 with a fast road-pose drift, so the cap is reached in
    /// about a minute instead of ten.
    final fast = DetectionProfile.v1.copyWith(
      attention: const AttentionSettings(
        gazeAwareEyes: true,
        mountRelative: true,
        roadAdaptDegPerMin: 20,
      ),
    );

    /// The driver's road pose moves [deg] in camera yaw over [rampS]
    /// seconds and stays there for [holdS]; 10 frames a second.
    void drift(double deg, {double rampS = 60, double holdS = 120}) {
      final from = lastUs + 100000,
          end = from + ((rampS + holdS) * 1e6).round();
      for (var t = from; t <= end; t += 100000) {
        final k = ((t - from) / (rampS * 1e6)).clamp(0.0, 1.0);
        arkit().emit([arkitFace(view: 38 + deg * k)], t);
        lastUs = t;
      }
    }

    test(
      'drift past the cap: said once, new road pose, still observing',
      () async {
        trip.profile = fast;
        await trip.start();
        calibrateOn(arkitFace);
        final session = trip.sessionId;
        observe(1, arkitFace);
        drift(-13);
        expect(
          platform.spoken,
          contains('Телефон сдвинулся. Смотрите на дорогу, перенастроюсь'),
        );
        await Future<void>.delayed(Duration.zero);
        expect(trip.phase, TripPhase.observing);
        expect(trip.sessionId, isNot(session));
        expect(trip.calibration!.neutralYaw, closeTo(25, .5));
        expect(trip.movedText, isNull);
        expect(platform.alertCalls, 0);
        expect(
          platform.spoken.where((t) => t.startsWith('Телефон сдвинулся')),
          hasLength(1),
        );
      },
    );

    test('a slow drift within the cap is followed in silence', () async {
      trip.profile = fast;
      await trip.start();
      calibrateOn(arkitFace);
      final session = trip.sessionId;
      observe(1, arkitFace);
      drift(-6);
      expect(trip.roadAdaptation!.atLimit, isFalse);
      expect(trip.sessionId, session);
      expect(
        platform.spoken.where((t) => t.startsWith('Телефон сдвинулся')),
        isEmpty,
      );
    });
  });

  test('frame lines carry ARKit gravityUp', () async {
    final dir = await Directory.systemTemp.createTemp('trip');
    addTearDown(() => dir.delete(recursive: true));
    trip
      ..recorder = LabRecorder(dir)
      ..recordTrips = true;
    await trip.start();
    final face = arkitFace();
    final result = FaceResult(
      engineId: arkitCapabilities.id,
      capturedUs: 1000,
      completedUs: 21000,
      faces: [DetectedFace(face.toMeasurement(), Rect.zero, signals: face)],
    );
    arkit().onRaw(result, {
      'gravityUp': [0.1, 0.9, -0.2],
    });
    arkit().deliver(result);
    arkit().emit([face], 40000);
    await trip.finish();
    final text = await (await LabRecorder(dir).list()).single.readAsString();
    final frames = RecordingReader.parse(text).ofType('frame').toList();
    expect(frames.first['gravityUp'], [0.1, 0.9, -0.2]);
    expect(frames.last.containsKey('gravityUp'), isFalse);
  });

  test('heat phrases wait until the alarm is over', () async {
    trip.announceHeat = true;
    await trip.start();
    calibrateOn(arkitFace);
    observe(1, arkitFace);
    observe(2, () => arkitFace(open: .05));
    expect(trip.snapshot!.eyes.activeEvent, isNotNull);
    arkit().onStats(stats('critical'));
    expect(platform.spoken.where((t) => t.startsWith('Телефон')), isEmpty);
    expect(platform.testAlertCalls, 0);
    trip.acknowledge(trip.snapshot!.activeEvents.map((e) => e.id).toSet());
    observe(3, arkitFace);
    expect(trip.snapshot!.activeEvents, isEmpty);
    trip.tick();
    expect(
      platform.spoken.last,
      'Телефон перегрелся. Уберите его от горячего воздуха',
    );
    expect(platform.testAlertCalls, 1);
  });

  group('pause and return', () {
    test('the trip goes on with the same calibration', () async {
      await trip.start();
      calibrateOn(arkitFace);
      final calibration = trip.calibration, session = trip.sessionId;
      observe(1, arkitFace);
      await trip.foreground(false);
      expect(trip.phase, TripPhase.paused);
      await trip.foreground(true);
      expect(trip.phase, TripPhase.observing);
      expect(trip.calibration, same(calibration));
      expect(trip.sessionId, isNot(session));
      expect(trip.error, isNull);
      expect(platform.spoken.last, 'Продолжаю');
      // The new ARKit session gives the face a new id: the same place, so
      // it is the driver.
      lastUs = trip.clock.elapsedMicroseconds;
      observe(.5, () => arkitFace(id: 30));
      expect(trip.attentionState.details['driver'], 'same');
      observe(2, () => arkitFace(id: 30, open: .05));
      expect(trip.snapshot!.eyes.activeEvent, isNotNull);
    });

    test('another face after the return is not taken for the driver', () async {
      await trip.start();
      calibrateOn(arkitFace);
      observe(1, arkitFace);
      await trip.foreground(false);
      await trip.foreground(true);
      lastUs = trip.clock.elapsedMicroseconds;
      observe(
        .3,
        () => arkitFace(
          id: 31,
          box: const FaceBox(left: .02, top: .5, width: .15, height: .15),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(trip.phase, TripPhase.findingFace);
    });

    test('a resumed after a short inactive state changes nothing', () async {
      await trip.start();
      calibrateOn(arkitFace);
      final session = trip.sessionId;
      await trip.foreground(true);
      expect(trip.phase, TripPhase.observing);
      expect(trip.sessionId, session);
    });
  });

  test('the screen line stays calm through short losses', () async {
    await trip.start();
    calibrateOn(arkitFace);
    observe(1, arkitFace);
    expect(trip.watchText, 'Слежу');
    observe(2, () => null);
    expect(trip.watchText, 'Слежу');
    observe(9, () => null);
    expect(trip.watchText, 'Не вижу вас');
    observe(.5, arkitFace);
    expect(trip.watchText, 'Слежу');
  });

  test('a stopped frame stream says observation is off', () async {
    trip.dispose();
    await trip.pendingWrites;
    await repository.close();
    final clock = FakeClock()..us = 1000000;
    await open(clock: clock);
    await trip.start();
    calibrateOn(arkitFace);
    observe(1, arkitFace);
    expect(trip.cameraSilent, isFalse);
    expect(trip.watchText, 'Слежу');
    var notified = 0;
    trip.addListener(() => notified++);
    // ARKit stops delivering: faces and capture times freeze, the clock goes on.
    clock.us = lastUs + 2000000;
    trip.tick();
    expect(trip.cameraSilent, isFalse);
    expect(trip.watchText, 'Слежу');
    clock.us = lastUs + 3100000;
    trip.tick();
    expect(trip.cameraSilent, isTrue);
    expect(trip.watchText, 'Камера не отвечает, наблюдение остановлено');
    expect(notified, greaterThan(0));
    // Frames come back.
    arkit().emit([arkitFace()], clock.us);
    trip.tick();
    expect(trip.cameraSilent, isFalse);
    expect(trip.watchText, 'Слежу');
  });

  test('the driver unseen is counted on the trip clock', () async {
    trip.dispose();
    await trip.pendingWrites;
    await repository.close();
    final clock = FakeClock()..us = 1000000;
    await open(clock: clock);
    await trip.start();
    calibrateOn(arkitFace);
    observe(1, arkitFace);
    // A frame without the driver whose capture time lags far behind: the
    // capture times alone would still count only 5 s.
    clock.us = lastUs + 11000000;
    arkit().emit([], lastUs + 5000000);
    expect(trip.cameraSilent, isFalse);
    expect(trip.watchText, 'Не вижу вас');
  });

  test('the trip runs on ARKit at 30 fps by default', () async {
    await trip.start();
    expect(trip.engineInUse, TripEngine.arkit);
    expect(trip.capabilities.id, arkitCapabilities.id);
    expect(arkit().options.fps, 30);
    expect(arkit().running, isTrue);
    expect(camera.running, isFalse);
    await trip.finish();
    expect(arkit().disposed, isTrue);
  });

  test(
    'ML Kit when ARKit is not supported, and as the developer choice',
    () async {
      supported = false;
      await trip.start();
      expect(trip.engineInUse, TripEngine.mlkit);
      expect(trip.engineNote, TripController.arkitUnavailable);
      expect(camera.running, isTrue);
      expect(sources, isEmpty);
      await trip.finish();

      supported = true;
      trip.engineChoice = TripEngine.mlkit;
      await trip.start();
      expect(trip.engineInUse, TripEngine.mlkit);
      expect(trip.engineNote, isNull);
      expect(sources, isEmpty);
    },
  );

  test('ARKit that fails to start falls back to ML Kit', () async {
    failStart = true;
    await trip.start();
    expect(trip.engineInUse, TripEngine.mlkit);
    expect(trip.engineNote, contains('ML Kit'));
    expect(camera.running, isTrue);
    expect(sources.single.disposed, isTrue);
  });

  test('38° vent: the eyes are watched with profile v1', () async {
    await trip.start();
    calibrateOn(arkitFace);
    expect(trip.phase, TripPhase.observing);
    expect(trip.calibration!.detector.id, arkitCapabilities.id);
    expect(trip.calibration!.detector.eyeYawLimit, 50);
    expect(trip.calibration!.hiddenEyes, isFalse);
    expect(trip.calibration!.eyeThreshold, .25);
    expect(trip.calibrationNote, isNull);
    expect(platform.spoken, ['Смотрите на дорогу, как обычно']);
    observe(1, arkitFace);
    observe(1.4, () => arkitFace(open: .05));
    expect(trip.snapshot!.eyes.activeEvent, isNull);
    observe(0.4, () => arkitFace(open: .05));
    expect(trip.snapshot!.eyes.activeEvent?.type, EventType.eyesClosed);
  });

  test('the eye gate: lids lowered by looking at the instruments', () async {
    await trip.start();
    calibrateOn(arkitFace);
    observe(1, arkitFace);
    // Eyes down to the instruments, lids nearly shut for 3 s: no alarm.
    observe(.3, () => arkitFace(eyeDown: 25, pitch: 6));
    observe(3, () => arkitFace(eyeDown: 25, pitch: 6, open: .2));
    expect(trip.snapshot!.eyes.activeEvent, isNull);
    expect(trip.attentionState.details['eyeGate'], 'look_down');
    // A deep closure always counts.
    observe(1, arkitFace);
    observe(2, () => arkitFace(open: .05));
    expect(trip.snapshot!.eyes.activeEvent, isNotNull);
  });

  test('a new ARKit face id after a short loss is still the driver', () async {
    await trip.start();
    calibrateOn(arkitFace);
    observe(1, arkitFace);
    observe(1, () => null);
    observe(1, () => arkitFace(id: 12));
    expect(trip.phase, TripPhase.observing);
    expect(trip.error, isNull);
    expect(trip.attentionState.details['driver'], 'same');
    observe(2, () => arkitFace(id: 12, open: .05));
    expect(trip.snapshot!.eyes.activeEvent, isNotNull);
  });

  test(
    'a second face pauses observation, the driver alone resumes it',
    () async {
      await trip.start();
      calibrateOn(arkitFace);
      observe(1, arkitFace);
      for (var t = lastUs + 33000; t < lastUs + 2000000; t += 33000) {
        arkit().emit([
          arkitFace(open: .05),
          arkitFace(
            id: 20,
            box: const FaceBox(left: .7, top: .1, width: .2, height: .2),
          ),
        ], t);
      }
      // No alarm on an ambiguous driver, and the calibration stays.
      expect(platform.alertCalls, 0);
      expect(trip.multipleFaces, isTrue);
      expect(trip.phase, TripPhase.observing);
      final session = trip.sessionId;
      // The passenger leaves: observation goes on by itself.
      lastUs += 2000000;
      observe(.5, arkitFace);
      expect(trip.multipleFaces, isFalse);
      observe(2, () => arkitFace(open: .05));
      expect(trip.snapshot!.eyes.activeEvent, isNotNull);
      expect(trip.sessionId, session);
      expect(trip.error, isNull);
    },
  );

  test('«ТЗ 2.2 (эталон)»: a second face stops until confirmed', () async {
    trip.profile = DetectionProfile.tz22;
    await trip.start();
    calibrateOn(() => arkitFace(view: 2));
    expect(trip.phase, TripPhase.observing);
    observe(1, () => arkitFace(view: 2));
    for (var t = lastUs + 33000; t < lastUs + 500000; t += 33000) {
      arkit().emit([
        arkitFace(view: 2),
        arkitFace(
          id: 20,
          box: const FaceBox(left: .7, top: .1, width: .2, height: .2),
        ),
      ], t);
    }
    expect(trip.phase, TripPhase.findingFace);
  });

  test('the trip recording has the ARKit engine and device lines', () async {
    final dir = await Directory.systemTemp.createTemp('trip');
    addTearDown(() => dir.delete(recursive: true));
    trip
      ..recorder = LabRecorder(dir)
      ..recordTrips = true;
    await trip.start();
    calibrateOn(arkitFace);
    observe(1, arkitFace);
    arkit().onStats(
      ArkitStats(
        atUs: trip.clock.elapsedMicroseconds,
        arFrames: 30,
        sent: 30,
        droppedEvents: 0,
        mlKitDone: 0,
        mlKitSkipped: 0,
        mlKitErrors: 0,
        mlKitBusyUs: 0,
        thermal: 'fair',
        lowPower: false,
        batteryState: 'unplugged',
        battery: .7,
      ),
    );
    await trip.finish();
    final text = await (await LabRecorder(dir).list()).single.readAsString();
    final reader = RecordingReader.parse(text);
    expect(reader.meta['engines'], [arkitCapabilities.id]);
    expect(reader.meta['tripEngine'], 'arkit');
    expect(reader.meta['attentionSettings']['gazeAwareEyes'], isTrue);
    expect(reader.ofType('device').single['thermal'], 'fair');
    expect(reader.ofType('frame').first['engine'], arkitCapabilities.id);
    final recording = Recording.parse(text);
    expect(
      recording.calibrations.single.profile!.detector.id,
      arkitCapabilities.id,
    );
  });
}
