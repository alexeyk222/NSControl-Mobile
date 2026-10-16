import 'dart:async';
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/data/trip_repository.dart';
import 'package:nscontrol/logic/domain.dart';
import 'package:nscontrol/services/camera_service.dart';
import 'package:nscontrol/services/detector.dart';
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
  int testAlertCalls = 0;
  bool alarmActive = false;
  Completer<void>? pendingCancel;
  Completer<void>? pendingAlert;
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?>? arguments,
  ]) async => {'status': 'ok'};
  @override
  Future<void> alert({required double volume, required bool vibrate}) async {
    alertCalls++;
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
}
