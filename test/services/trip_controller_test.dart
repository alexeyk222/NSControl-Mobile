import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/data/trip_repository.dart';
import 'package:nscontrol/logic/detection_profile.dart';
import 'package:nscontrol/logic/domain.dart';
import 'package:nscontrol/logic/mount.dart';
import 'package:nscontrol/services/camera_service.dart';
import 'package:nscontrol/logic/replay.dart';
import 'package:nscontrol/services/detector.dart';
import 'package:nscontrol/services/lab_recorder.dart';
import 'package:nscontrol/services/mlkit_signals.dart';
import 'package:nscontrol/services/platform_bridge.dart';
import 'package:nscontrol/services/trip_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class ControllerTestDetector implements FaceDetectorPort {
  @override
  DetectorCapabilities get capabilities => DetectorCapabilities.mlKit;
  @override
  Future<List<DetectedFace>> detect(VisionFrame frame) async => [];
  @override
  Future<void> close() async {}
}

class ControllerTestPlatform extends PlatformBridge {
  final messages = <Map<String, Object?>>[];
  int alertCalls = 0;
  double? lastVolume;
  bool? lastVibrate;
  int testAlertCalls = 0;
  bool alarmActive = false;
  Completer<void>? pendingCancel;
  Completer<void>? pendingAlert;
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  final calls = <(String, Map<String, Object?>?)>[];
  @override
  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    calls.add((method, arguments));
    return {'status': 'ok'};
  }

  List<String> get spoken => [
    for (final (m, a) in calls)
      if (m == 'speech.say') a!['text'] as String,
  ];
  @override
  Future<void> alert({required double volume, required bool vibrate}) async {
    alertCalls++;
    lastVolume = volume;
    lastVibrate = vibrate;
    alarmActive = true;
  }

  @override
  Future<void> stopAlert() async {
    alarmActive = false;
  }

  @override
  Future<void> testAlert({
    required double volume,
    required bool vibrate,
  }) async {
    testAlertCalls++;
    // Native test sequences stop their temporary signal after the probe.
    alarmActive = false;
  }

  @override
  Future<void> send(Map<String, Object?> message) async {
    messages.add(message);
    if (message['type'] == 'alert' && pendingAlert != null) {
      await pendingAlert!.future;
    }
    if (message['type'] == 'cancel' && pendingCancel != null) {
      await pendingCancel!.future;
    }
  }
}

class ControllerTestCamera extends CameraService {
  ControllerTestCamera({
    required super.detector,
    required super.nowUs,
    required super.onFaces,
    required super.onError,
    required super.onChanged,
  });
  bool streaming = false;
  int stops = 0;
  @override
  bool get running => streaming;
  @override
  Future<void> start() async {
    streaming = true;
    pipeline.begin();
  }

  @override
  Future<void> stop() async {
    streaming = false;
    stops++;
    pipeline.end();
  }
}

/// An ML Kit face: [yaw] is the view angle of the camera (a vent mount
/// turned to the driver), [pitch] a nod down.
DetectedFace mlKitFace({
  double yaw = 0,
  double pitch = 0,
  double eyes = .9,
  int id = 7,
}) {
  final s = MlKitSignals.from(
    trackingId: id,
    leftEyeOpen: eyes,
    rightEyeOpen: eyes,
    eulerX: -pitch,
    eulerY: yaw,
    eulerZ: 0,
  );
  return DetectedFace(
    s.toMeasurement(),
    const Rect.fromLTWH(0, 0, 100, 100),
    signals: s,
  );
}

CalibrationProfile testProfile() => CalibrationProfile(
  trackingId: 7,
  detector: DetectorCapabilities.mlKit,
  hiddenEyes: false,
  neutralPitch: 0,
  neutralYaw: 0,
  neutralRoll: 0,
  leftEyeMedian: .8,
  rightEyeMedian: .8,
  eyeThreshold: .4,
);

void main() {
  late TripRepository repository;
  late TripController trip;
  late ControllerTestPlatform platform;
  late ControllerTestCamera camera;
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    repository = await TripRepository.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    platform = ControllerTestPlatform();
    trip = TripController(
      repository: repository,
      platform: platform,
      detector: ControllerTestDetector(),
      cameraFactory: (d, n, f, e, c) => camera = ControllerTestCamera(
        detector: d,
        nowUs: n,
        onFaces: f,
        onError: e,
        onChanged: c,
      ),
    );
    await trip.start();
    await trip.pendingWrites;
  });
  tearDown(() async {
    if (platform.pendingCancel?.isCompleted == false) {
      platform.pendingCancel!.complete();
    }
    if (platform.pendingAlert?.isCompleted == false) {
      platform.pendingAlert!.complete();
    }
    trip.dispose();
    await trip.pendingWrites;
    await repository.close();
  });

  Future<void> synchronizedWatchForEvent({
    String session = 'old-session',
  }) async {
    trip.clock.stop();
    trip.sessionId = session;
    trip.sessionBaseUs = 0;
    trip.sessionStartedAt = DateTime.now().toUtc();
    await repository.insertSession({
      'id': session,
      'trip_id': trip.tripId,
      'started_at': trip.sessionStartedAt!.toIso8601String(),
    });
    await repository.upsertEvent({
      'id': 'watch-event',
      'trip_id': trip.tripId,
      'session_id': session,
      'type': 'eyes_closed',
      'channel': 'eyes',
      'started_us': 0,
      'threshold_us': 0,
    });
    trip.wearable.setState(
      tripId: trip.tripId,
      sessionId: session,
      activeEventIds: ['watch-event'],
    );
    await trip.wearable.connect();
    final connection = platform.messages.last['connection_id'];
    await trip.wearable.receive({
      'type': 'ready',
      'connection_id': connection,
      'receiver_epoch': 'watch',
    });
    final ping = platform.messages.lastWhere((m) => m['type'] == 'ping');
    await trip.wearable.receive({
      'type': 'pong',
      'connection_id': connection,
      'receiver_epoch': 'watch',
      'ack_message_id': ping['message_id'],
      'phone_sent_us': ping['phone_sent_us'],
      'watch_received_ms': 100,
      'watch_sent_ms': 100,
    });
    final sync = platform.messages.last;
    await trip.wearable.receive({
      'type': 'ack',
      'connection_id': sync['connection_id'],
      'receiver_epoch': sync['receiver_epoch'],
      'ack_message_id': sync['message_id'],
      'status': 'synchronized',
    });
    expect(trip.wearable.synchronized, isTrue);
  }

  test(
    'fast watch receipt persists before send completes and cannot regress to sent',
    () async {
      await synchronizedWatchForEvent();
      final sentOffset = trip.sessionNowUs;
      platform.pendingAlert = Completer<void>();
      final sending = trip.wearable.alert(
        id: 'watch-event',
        reason: 'eyes',
        occurredUs: trip.clock.elapsedMicroseconds,
        event: true,
      );
      await Future<void>.delayed(Duration.zero);
      final alert = platform.messages.lastWhere((m) => m['type'] == 'alert');
      await trip.wearable.receive({
        'type': 'ack',
        'status': 'accepted',
        'ack_message_id': alert['message_id'],
        'connection_id': alert['connection_id'],
        'receiver_epoch': alert['receiver_epoch'],
      });
      await trip.pendingWrites;
      final beforeSendCompleted = await repository.listDeliveries();
      final sendWasStillPending = !platform.pendingAlert!.isCompleted;
      platform.pendingAlert!.complete();
      await sending;
      await trip.pendingWrites;
      final persisted = await repository.listDeliveries();
      expect(sendWasStillPending, isTrue);
      expect(beforeSendCompleted, hasLength(1));
      expect(beforeSendCompleted.single['status'], 'received_accepted');
      expect(persisted, hasLength(1));
      expect(persisted.single['status'], 'received_accepted');
      expect(persisted.single['received_at'], isNotNull);
      expect(persisted.single['sent_us'], sentOffset);
      expect(persisted.single['received_us'], sentOffset);
    },
  );

  test(
    'late send completion preserves the original session monotonic scale',
    () async {
      await synchronizedWatchForEvent();
      final originalOffset = trip.sessionNowUs;
      expect(originalOffset, greaterThan(0));
      platform.pendingAlert = Completer<void>();
      final sending = trip.wearable.alert(
        id: 'watch-event',
        reason: 'eyes',
        occurredUs: trip.clock.elapsedMicroseconds,
        event: true,
      );
      await Future<void>.delayed(Duration.zero);
      await repository.insertSession({
        'id': 'new-session',
        'trip_id': trip.tripId,
        'started_at': DateTime.now().toUtc().toIso8601String(),
      });
      trip.sessionId = 'new-session';
      trip.sessionBaseUs = trip.clock.elapsedMicroseconds;
      trip.wearable.setState(tripId: trip.tripId, sessionId: 'new-session');
      expect(trip.sessionNowUs, 0);
      platform.pendingAlert!.complete();
      await sending;
      await trip.pendingWrites;
      final delivery = (await repository.listDeliveries()).single;
      expect(delivery['session_id'], 'old-session');
      expect(delivery['sent_us'], originalOffset);
      expect(trip.journalIncomplete, isFalse);
    },
  );

  test(
    'test alert during an active trip cannot replace the ongoing event alarm',
    () async {
      trip.sessionId = 'alarm-session';
      trip.sessionStartedAt = DateTime.now().toUtc();
      trip.engine = ObservationEngine(
        sessionId: 'alarm-session',
        calibration: testProfile(),
      );
      trip.phase = TripPhase.observing;
      await repository.insertSession({
        'id': 'alarm-session',
        'trip_id': trip.tripId,
        'started_at': trip.sessionStartedAt!.toIso8601String(),
      });
      for (var at = 0; at <= 1700000; at += 100000) {
        camera.onFaces(
          [
            const DetectedFace(
              FaceMeasurement(
                trackingId: 7,
                leftEye: .1,
                rightEye: .1,
                pitchDown: 0,
                yaw: 0,
                roll: 0,
              ),
              Rect.fromLTWH(0, 0, 100, 100),
            ),
          ],
          at,
          at,
        );
      }
      await Future<void>.delayed(Duration.zero);
      expect(platform.alarmActive, isTrue);
      expect(trip.snapshot!.hasUnacknowledgedAlert, isTrue);
      await trip.testAlert();
      expect(platform.testAlertCalls, 0);
      expect(platform.alarmActive, isTrue);
      expect(trip.snapshot!.hasUnacknowledgedAlert, isTrue);
    },
  );

  test('phone alert begins while a journal operation is blocked', () async {
    trip.sessionId = 'session';
    trip.sessionStartedAt = DateTime.now().toUtc();
    trip.engine = ObservationEngine(
      sessionId: 'session',
      calibration: testProfile(),
    );
    trip.phase = TripPhase.observing;
    await repository.insertSession({
      'id': 'session',
      'trip_id': trip.tripId,
      'started_at': trip.sessionStartedAt!.toIso8601String(),
      'settings_json': trip.settings.toJson(),
      'calibration_json': testProfile().toJson(),
      'algorithm_version': '1.0.0',
    });
    final gate = Completer<void>();
    trip.journal((_) => gate.future);
    for (var t = 0; t <= 1700000; t += 100000) {
      camera.onFaces(
        [
          const DetectedFace(
            FaceMeasurement(
              trackingId: 7,
              leftEye: .1,
              rightEye: .1,
              pitchDown: 0,
              yaw: 0,
              roll: 0,
            ),
            Rect.fromLTWH(0, 0, 100, 100),
          ),
        ],
        t,
        t,
      );
    }
    await Future<void>.delayed(Duration.zero);
    expect(platform.alertCalls, 1);
    expect(gate.isCompleted, isFalse);
    gate.complete();
    await trip.pendingWrites;
    expect(await repository.listEvents(), hasLength(1));
  });

  test(
    'background stops the camera even when wearable cancellation is blocked',
    () async {
      await trip.wearable.connect();
      final connection = platform.messages.last['connection_id'];
      await trip.wearable.receive({
        'type': 'ready',
        'connection_id': connection,
        'receiver_epoch': 'watch',
      });
      platform.pendingCancel = Completer<void>();
      final stopping = trip.foreground(false);
      await Future<void>.delayed(Duration.zero);
      final cameraStoppedBeforeTransport = !camera.running;
      platform.pendingCancel!.complete();
      platform.pendingCancel = null;
      await stopping;
      expect(
        cameraStoppedBeforeTransport,
        isTrue,
        reason:
            'Background camera shutdown must not wait on the remote transport',
      );
    },
  );

  test(
    'watch "accept" silences the phone for the current events only',
    () async {
      await trip.wearable.connect();
      final connection = platform.messages.last['connection_id'];
      await trip.wearable.receive({
        'type': 'ready',
        'connection_id': connection,
        'receiver_epoch': 'watch',
      });
      trip.sessionId = 'ack-session';
      // The session began 5 s ago so the acknowledgement follows the frames.
      trip.sessionBaseUs = trip.clock.elapsedMicroseconds - 5000000;
      trip.sessionStartedAt = DateTime.now().toUtc();
      trip.engine = ObservationEngine(
        sessionId: 'ack-session',
        calibration: testProfile(),
      );
      trip.phase = TripPhase.observing;
      await repository.insertSession({
        'id': 'ack-session',
        'trip_id': trip.tripId,
        'started_at': trip.sessionStartedAt!.toIso8601String(),
      });
      for (var at = 0; at <= 1700000; at += 100000) {
        camera.onFaces(
          [
            const DetectedFace(
              FaceMeasurement(
                trackingId: 7,
                leftEye: .1,
                rightEye: .1,
                pitchDown: 0,
                yaw: 0,
                roll: 0,
              ),
              Rect.fromLTWH(0, 0, 100, 100),
            ),
          ],
          trip.sessionBaseUs + at,
          trip.sessionBaseUs + at,
        );
      }
      await Future<void>.delayed(Duration.zero);
      expect(platform.alarmActive, isTrue);
      final snapshot = platform.messages.lastWhere(
        (m) => m['type'] == 'snapshot',
      );
      expect(snapshot['level'], 'warning');
      final eventId = trip.snapshot!.activeEvents.single.id;
      await trip.wearable.receive({
        'type': 'user_ack',
        'event_ids': ['stale-event'],
        'connection_id': connection,
        'receiver_epoch': 'watch',
      });
      expect(trip.snapshot!.hasUnacknowledgedAlert, isTrue);
      await trip.wearable.receive({
        'type': 'user_ack',
        'event_ids': [eventId],
        'connection_id': connection,
        'receiver_epoch': 'watch',
      });
      await Future<void>.delayed(Duration.zero);
      expect(trip.snapshot!.hasUnacknowledgedAlert, isFalse);
      expect(platform.alarmActive, isFalse);
      expect(trip.watchAcknowledgedAt, isNotNull);
      final cancel = platform.messages.lastWhere((m) => m['type'] == 'cancel');
      expect(cancel['target_ids'], [eventId]);
    },
  );

  test('break button restarts the continuous driving count', () async {
    final now = trip.clock.elapsedMicroseconds;
    trip.drive.reset();
    for (var t = now - 7200000000; t <= now; t += 600000000) {
      trip.drive.active(t);
    }
    expect(trip.drivingTime.inHours, 2);
    trip.markBreak();
    expect(trip.drivingTime.inMinutes, 0);
  });

  test(
    'unacknowledged alarm escalates once after 5 s; acknowledged does not',
    () async {
      trip.settings = AlgorithmSettings(volume: .3, vibration: false);
      trip.sessionId = 'esc-session';
      trip.sessionBaseUs = trip.clock.elapsedMicroseconds - 4000000;
      trip.sessionStartedAt = DateTime.now().toUtc();
      trip.engine = ObservationEngine(
        sessionId: 'esc-session',
        calibration: testProfile(),
        settings: trip.settings,
      );
      trip.phase = TripPhase.observing;
      await repository.insertSession({
        'id': 'esc-session',
        'trip_id': trip.tripId,
        'started_at': trip.sessionStartedAt!.toIso8601String(),
      });
      for (var at = 0; at <= 1700000; at += 100000) {
        camera.onFaces(
          [
            const DetectedFace(
              FaceMeasurement(
                trackingId: 7,
                leftEye: .1,
                rightEye: .1,
                pitchDown: 0,
                yaw: 0,
                roll: 0,
              ),
              Rect.fromLTWH(0, 0, 100, 100),
            ),
          ],
          trip.sessionBaseUs + at,
          trip.sessionBaseUs + at,
        );
      }
      await Future<void>.delayed(Duration.zero);
      expect(platform.lastVolume, .3);
      // Alert requested at ~1.6 s, session time ~4 s: not yet escalated.
      trip.checkEscalation();
      expect(trip.alarmEscalated, isFalse);
      trip.sessionBaseUs -= 3000000;
      trip.checkEscalation();
      await Future<void>.delayed(Duration.zero);
      expect(trip.alarmEscalated, isTrue);
      expect(platform.lastVolume, 1);
      expect(platform.lastVibrate, isTrue);
      final calls = platform.alertCalls;
      trip.checkEscalation();
      expect(platform.alertCalls, calls);
      trip.acknowledge(trip.snapshot!.activeEvents.map((e) => e.id).toSet());
      trip.checkEscalation();
      expect(trip.alarmEscalated, isFalse);
    },
  );

  test('wearable status codes are shown in Russian', () {
    expect(
      TripController.describeWearable({'status': 'unpaired'}),
      contains('Apple Watch не сопряжены'),
    );
    expect(
      TripController.describeWearable({
        'status': 'disconnected',
        'reason': 'Open NSControl on Apple Watch',
      }),
      'Часы не на связи. Откройте NSControl на часах',
    );
    expect(
      TripController.describeWearable({
        'status': 'app_not_installed',
        'transport': 'garmin',
        'reason': 'Приложение NSControl не установлено на часах',
      }),
      'Приложение NSControl не установлено на часах',
    );
  });
  group('trip calibration', () {
    /// Calibrates on [make] frames for 10.2 s and finishes the window.
    void calibrateOn(DetectedFace Function() make) {
      trip.clock.stop();
      final base = trip.clock.elapsedMicroseconds;
      camera.onFaces([make()], base, base);
      trip.confirmFace(7);
      final start = trip.calibrationStartUs;
      for (var t = start; t <= start + 10200000; t += 33000) {
        camera.onFaces([make()], t, t + 20000);
      }
      trip.finishCalibration(start + 10300000);
    }

    /// Frames of the observing session for [seconds].
    void observe(double seconds, DetectedFace Function() make) {
      final base = trip.sessionBaseUs;
      final from = (trip.snapshot?.head.lastUsableUs ?? 0) + 33000;
      for (var t = from; t <= from + (seconds * 1000000).round(); t += 33000) {
        camera.onFaces([make()], base + t, base + t + 20000);
      }
    }

    test('passes on a vent mount at 38°, head only, said once', () {
      calibrateOn(() => mlKitFace(yaw: 38));
      expect(trip.phase, TripPhase.observing);
      expect(trip.calibration!.neutralYaw, closeTo(38, 1e-6));
      expect(trip.calibration!.hiddenEyes, isTrue);
      // The automata run on road-relative angles.
      expect(trip.engineCalibration!.neutralYaw, 0);
      expect(trip.engine!.calibration.neutralYaw, 0);
      expect(trip.calibrationNote, contains('глаза не оцениваются'));
      expect(platform.spoken, [
        'Смотрите на дорогу, как обычно',
        'Глаза под таким углом не видно, слежу за головой',
      ]);
      // Closed eyes beyond the eye limit raise nothing; a nod relative to
      // the road does.
      observe(3, () => mlKitFace(yaw: 38, eyes: .05));
      expect(trip.snapshot!.eyes.activeEvent, isNull);
      expect(trip.snapshot!.eyes.available, isFalse);
      expect(trip.snapshot!.head.activeEvent, isNull);
      observe(2.5, () => mlKitFace(yaw: 38, pitch: 40));
      expect(trip.snapshot!.head.activeEvent, isNotNull);
    });

    test('in front the eyes are watched', () {
      calibrateOn(() => mlKitFace(yaw: 2));
      expect(trip.calibration!.hiddenEyes, isFalse);
      expect(trip.calibrationNote, isNull);
      expect(platform.spoken, ['Смотрите на дорогу, как обычно']);
      observe(2, () => mlKitFace(yaw: 2, eyes: .05));
      expect(trip.snapshot!.eyes.activeEvent, isNotNull);
    });

    test('records the trip to JSONL when the option is on', () async {
      final dir = await Directory.systemTemp.createTemp('trip');
      addTearDown(() => dir.delete(recursive: true));
      await trip.finish();
      trip
        ..recorder = LabRecorder(dir)
        ..recordTrips = true
        ..mountPosition = 'vent_left';
      await trip.start();
      expect(trip.recording, isTrue);
      calibrateOn(() => mlKitFace(yaw: 38));
      observe(1, () => mlKitFace(yaw: 38));
      observe(2.5, () => mlKitFace(yaw: 38, pitch: 40));
      expect(trip.snapshot!.head.activeEvent, isNotNull);
      observe(1.5, () => mlKitFace(yaw: 38));
      expect(trip.snapshot!.head.activeEvent, isNull);
      await trip.finish();
      expect(trip.recording, isFalse);

      final files = await LabRecorder(dir).list();
      expect(files.single.path, contains('nscontrol-trip-'));
      final text = await files.single.readAsString();
      final reader = RecordingReader.parse(text);
      expect(reader.meta['source'], 'trip');
      expect(reader.meta['mount'], {'position': 'vent_left'});
      expect(reader.meta['attentionSettings']['mountRelative'], isTrue);
      expect(reader.meta['attentionSettings']['roadAdaptDegPerMin'], 1);
      expect(reader.meta['detectionProfile']['id'], 'v1');
      expect(reader.meta['engines'], ['mlkit_face_detection']);
      final calibration = reader.ofType('calibration').single;
      expect(calibration['zones']['mountRelative'], isTrue);
      expect(calibration['sessionOffsetUs'], isA<int>());
      expect(reader.ofType('frame').length, greaterThan(300));
      expect(reader.ofType('derived'), isNotEmpty);
      expect(reader.ofType('label'), isEmpty);
      final events = reader.ofType('event').toList();
      expect(events.first['event']['type'], 'head_pitch_down');
      expect(events.map((e) => e['change']), contains('ended'));
      // The replay reads it like a lab recording.
      final recording = Recording.parse(text);
      expect(
        recording.calibrations.single.profile!.neutralYaw,
        closeTo(38, 1e-6),
      );
    });

    test('«ТЗ 2.2 (эталон)» keeps the strict calibration', () {
      trip.profile = DetectionProfile.tz22;
      calibrateOn(() => mlKitFace(yaw: 38));
      expect(trip.phase, TripPhase.findingFace);
      expect(trip.error, isNotNull);
      expect(platform.spoken, isEmpty);

      calibrateOn(() => mlKitFace(yaw: 2));
      expect(trip.phase, TripPhase.observing);
      expect(trip.engine!.calibration.neutralYaw, closeTo(2, 1e-6));
      // The user's ТЗ thresholds, the ТЗ T rule.
      expect(trip.engine!.settings.pitchThreshold, 20);
      expect(trip.engine!.settings.headDownUs, 2000000);
      expect(trip.engine!.settings.eyesClosedUs, 1500000);
      expect(trip.calibration!.eyeThreshold, .4);
      observe(1.3, () => mlKitFace(yaw: 2, eyes: .05));
      expect(trip.snapshot!.eyes.activeEvent, isNull);
      observe(0.7, () => mlKitFace(yaw: 2, eyes: .05));
      expect(trip.snapshot!.eyes.activeEvent, isNotNull);
    });

    /// Camera pitch (ML Kit) at [yaw] that gives [road] degrees down
    /// relative to the trip's road pose.
    double cameraPitchFor(double road, {double yaw = 38}) {
      final frame = RoadFrame.fromProfile(trip.calibration!);
      var best = 0.0, error = double.infinity;
      for (var p = 0.0; p <= 60; p += .05) {
        final head = frame.head(mlKitFace(yaw: yaw, pitch: p).signals!);
        final e = (head!.$2 - road).abs();
        if (e < error) (best, error) = (p, e);
      }
      return best;
    }

    test('profile v1 on a 38° vent: eyes off, head over 19° for 1.5 s', () {
      expect(trip.profile.id, 'v1');
      calibrateOn(() => mlKitFace(yaw: 38));
      expect(trip.phase, TripPhase.observing);
      // ML Kit sees the eyes only within 10° of the camera in v1.
      expect(trip.calibration!.detector.eyeYawLimit, 10);
      expect(trip.calibration!.hiddenEyes, isTrue);
      expect(trip.engine!.settings.hiddenEyes, isTrue);
      expect(trip.engine!.settings.pitchThreshold, 19);
      expect(trip.engine!.settings.headDownUs, 1500000);
      observe(3, () => mlKitFace(yaw: 38, eyes: .05));
      expect(trip.snapshot!.eyes.available, isFalse);
      expect(trip.snapshot!.eyes.activeEvent, isNull);

      final low = cameraPitchFor(17), high = cameraPitchFor(21);
      observe(3, () => mlKitFace(yaw: 38, pitch: low));
      expect(trip.snapshot!.head.activeEvent, isNull);
      observe(1, () => mlKitFace(yaw: 38));
      observe(1.2, () => mlKitFace(yaw: 38, pitch: high));
      expect(trip.snapshot!.head.activeEvent, isNull);
      observe(0.6, () => mlKitFace(yaw: 38, pitch: high));
      expect(trip.snapshot!.head.activeEvent?.type.code, 'head_pitch_down');
    });

    test('the profile goes to the session journal', () async {
      calibrateOn(() => mlKitFace(yaw: 38));
      await trip.pendingWrites;
      final session = (await repository.listSessions()).singleWhere(
        (r) => r['id'] == trip.sessionId,
      );
      final row = jsonDecode(session['settings_json'] as String) as Map;
      expect(row['detectionProfile']['id'], 'v1');
      expect(row['mountRelative'], isTrue);
    });
  });
}
