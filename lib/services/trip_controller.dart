import 'dart:async';
import 'package:camera/camera.dart' show CameraException;
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../data/trip_repository.dart';
import '../logic/domain.dart';
import 'camera_service.dart';
import 'detector.dart';
import 'platform_bridge.dart';
import 'wearable_gateway.dart';

typedef CameraFactory =
    CameraService Function(
      FaceDetectorPort detector,
      int Function() now,
      void Function(List<DetectedFace>, int, int) onFaces,
      void Function(Object) onError,
      void Function() onChanged,
    );

enum TripPhase { idle, findingFace, calibrating, observing, paused }

class TripController extends ChangeNotifier {
  TripController({
    required this.repository,
    required this.platform,
    required this.detector,
    AlgorithmSettings? settings,
    CameraFactory? cameraFactory,
  }) : settings = settings ?? AlgorithmSettings() {
    camera =
        (cameraFactory ??
        ((d, n, f, e, c) => CameraService(
          detector: d,
          nowUs: n,
          onFaces: f,
          onError: e,
          onChanged: c,
        )))(
          detector,
          () => clock.elapsedMicroseconds,
          _onFaces,
          _cameraError,
          _notify,
        );
    wearable = WearableGateway(
      nowUs: () => clock.elapsedMicroseconds,
      send: platform.send,
      onDelivery: _delivery,
    );
    _timer = Timer.periodic(const Duration(milliseconds: 50), (_) => _tick());
    _platformEvents = platform.events.listen(
      _platformEvent,
      onError: (Object error) {
        wearableStatus = 'Интеграция часов недоступна';
        _notify();
      },
    );
  }

  TripRepository? repository;
  final PlatformBridge platform;
  final FaceDetectorPort detector;
  late final CameraService camera;
  late final WearableGateway wearable;
  final clock = Stopwatch()..start();
  final _ids = const Uuid();
  AlgorithmSettings settings;
  CalibrationProfile? calibration;
  CalibrationCollector? _collector;
  ObservationEngine? engine;
  TripPhase phase = TripPhase.idle;
  String? tripId, sessionId, lastFinishedTrip;
  String? error, alertError;
  String wearableStatus = 'Часы не подключены';
  String? recommendationText;
  bool journalIncomplete = false;
  bool cameraPermissionBlocked = false;
  List<DetectedFace> faces = [];
  int sessionBaseUs = 0;
  DateTime? sessionStartedAt;
  int _calibrationStart = 0;
  int _lifecycleGeneration = 0;
  int _lastUiUs = 0, _lastReconnectUs = 0, _lastWatchSyncUs = 0;
  int _lastCheckpointUs = 0;
  final List<int> completedPerMinute = [];
  bool _foreground = true,
      _disposed = false,
      _cameraFailureBusy = false,
      _calibrationFinishing = false;
  bool _audioRequested = false;
  Future<void> _writes = Future.value();
  Timer? _timer;
  StreamSubscription<Map<String, Object?>>? _platformEvents;
  void Function(bool eyesEvent, bool headActive)? onCameraEvidence;
  VoidCallback? onTripStarted, onTripEnded;
  ObservationSnapshot? get snapshot => engine?.snapshot;
  bool get active => tripId != null;
  int get sessionNowUs =>
      (clock.elapsedMicroseconds - sessionBaseUs).clamp(0, 1 << 62);
  double get calibrationProgress =>
      ((clock.elapsedMicroseconds - _calibrationStart) / 10000000).clamp(0, 1);
  int get calibrationSamples => _collector?.usableFrames ?? 0;
  Future<void> get pendingWrites => _writes;
  void journal(Future<void> Function(TripRepository) operation) =>
      _write(operation);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _write(Future<void> Function(TripRepository) operation) {
    final trip = tripId, session = sessionId;
    _writes = _writes.then((_) async {
      final db = repository;
      if (db == null) {
        journalIncomplete = true;
        _notify();
        return;
      }
      try {
        await operation(db);
      } catch (_) {
        journalIncomplete = true;
        _notify();
        if (trip != null) {
          try {
            await db.markJournalIncomplete(trip, sessionId: session);
          } catch (_) {}
        }
      }
    });
  }

  Future<void> start() async {
    if (active) return;
    final generation = ++_lifecycleGeneration;
    cameraPermissionBlocked = false;
    tripId = _ids.v4();
    lastFinishedTrip = null;
    error = null;
    final id = tripId!;
    _write(
      (db) => db.insertTrip({
        'id': id,
        'started_at': DateTime.now().toUtc().toIso8601String(),
      }),
    );
    onTripStarted?.call();
    phase = TripPhase.findingFace;
    await _safe(() => platform.keepAwake(true));
    if (generation != _lifecycleGeneration || !active || !_foreground) return;
    _notify();
    await camera.start();
  }

  void confirmFace(int trackingId) {
    if (!active || phase != TripPhase.findingFace) return;
    if (faces.length != 1 ||
        faces.single.measurement.trackingId != trackingId) {
      error =
          'В области водителя должно оставаться одно лицо. Уберите другие лица из кадра.';
      _notify();
      return;
    }
    error = null;
    _calibrationStart = clock.elapsedMicroseconds;
    _collector = CalibrationCollector(
      trackingId: trackingId,
      detector: detector.capabilities,
      hiddenEyes: settings.hiddenEyes,
      startedUs: _calibrationStart,
    );
    phase = TripPhase.calibrating;
    _notify();
  }

  void _onFaces(List<DetectedFace> result, int captured, int completed) {
    if (!active || !_foreground) return;
    faces = result;
    final measurements = result.map((f) => f.measurement).toList();
    if (phase == TripPhase.calibrating) {
      _collector?.add(capturedUs: captured, faces: measurements);
    } else if (phase == TripPhase.observing && sessionId != null) {
      _apply(
        engine!.process(
          sessionId: sessionId!,
          capturedUs: captured - sessionBaseUs,
          completedUs: completed - sessionBaseUs,
          faces: measurements,
        ),
      );
      if (engine!.snapshot.requiresRecalibration) {
        unawaited(
          recalibrate(
            reason:
                'Лицо изменилось или выбор неоднозначен. Подтвердите лицо заново.',
          ),
        );
      }
    }
    _throttledNotify();
  }

  void _tick() {
    if (_disposed) return;
    final now = clock.elapsedMicroseconds;
    if (phase == TripPhase.calibrating &&
        now - _calibrationStart >= 10000000 &&
        !_calibrationFinishing) {
      final pending = camera.pipeline.inFlightCapturedUs;
      if (pending == null ||
          pending > _calibrationStart + 10000000 ||
          now - pending > 300000) {
        if (pending != null &&
            pending <= _calibrationStart + 10000000 &&
            now - pending > 300000) {
          _collector?.add(capturedUs: pending, faces: []);
        }
        _finishCalibration(now);
      }
    }
    if (phase == TripPhase.observing && engine != null) {
      _apply(engine!.tick(sessionNowUs));
      if (sessionNowUs - _lastCheckpointUs >= 1000000 && sessionId != null) {
        _lastCheckpointUs = sessionNowUs;
        while (sessionNowUs >= (completedPerMinute.length + 1) * 60000000) {
          final start = sessionBaseUs + completedPerMinute.length * 60000000;
          completedPerMinute.add(
            camera.pipeline.completedBetween(start, start + 60000000),
          );
        }
        final id = sessionId!, atUs = sessionNowUs;
        final diagnostics = <String, Object?>{
          'completed_per_minute': List.of(completedPerMinute),
          'build_mode': kReleaseMode
              ? 'release'
              : kProfileMode
              ? 'profile'
              : 'debug',
          'app_version': '1.0.0+1',
          'algorithm_version': ObservationEngine.algorithmVersion,
        };
        _write(
          (db) =>
              db.checkpointSession(id, atUs: atUs, diagnostics: diagnostics),
        );
      }
    }
    if (active &&
        _foreground &&
        !camera.running &&
        !cameraPermissionBlocked &&
        !_cameraFailureBusy &&
        now - _lastReconnectUs >= 2000000) {
      _lastReconnectUs = now;
      unawaited(camera.start());
    }
    if (wearable.connected && now - _lastWatchSyncUs >= 10000000) {
      _lastWatchSyncUs = now;
      unawaited(wearable.synchronize());
    }
    if (phase == TripPhase.calibrating) _throttledNotify();
  }

  void _finishCalibration(int now) {
    _calibrationFinishing = true;
    try {
      final result = _collector!.finish(nowUs: now);
      _collector = null;
      if (result.profile == null) {
        phase = TripPhase.findingFace;
        error = result.issues.join('\n');
      } else {
        calibration = result.profile;
        final saved = calibration!.toJson();
        _write((db) => db.setSetting('calibration', saved));
        _newSession();
      }
    } catch (e) {
      phase = TripPhase.findingFace;
      error = 'Калибровка не завершена: $e';
    } finally {
      _calibrationFinishing = false;
      _notify();
    }
  }

  void _newSession() {
    completedPerMinute.clear();
    _lastCheckpointUs = 0;
    sessionId = _ids.v4();
    sessionBaseUs = clock.elapsedMicroseconds;
    sessionStartedAt = DateTime.now().toUtc();
    engine = ObservationEngine(
      sessionId: sessionId!,
      calibration: calibration!,
      settings: settings,
    );
    final row = <String, Object?>{
      'id': sessionId,
      'trip_id': tripId,
      'started_at': sessionStartedAt!.toIso8601String(),
      'settings_json': settings.toJson(),
      'calibration_json': calibration!.toJson(),
      'detector_id': detector.capabilities.id,
      'detector_version': detector.capabilities.version,
      'algorithm_version': ObservationEngine.algorithmVersion,
    };
    _write((db) => db.insertSession(row));
    for (final channel in ['eyes', 'head']) {
      final initial = <String, Object?>{
        'id': _ids.v4(),
        'trip_id': tripId,
        'session_id': sessionId,
        'channel': channel,
        'at': sessionStartedAt!.toIso8601String(),
        'at_us': 0,
        'state': 'unavailable',
        'available': 0,
        'reason': channel == 'eyes' && settings.hiddenEyes
            ? 'hidden_eyes'
            : 'warming_up',
      };
      _write((db) => db.insertTransition(initial));
    }
    phase = TripPhase.observing;
    error = null;
    _pushWatchState();
  }

  String? _wallAt(int? offset) => offset == null || sessionStartedAt == null
      ? null
      : sessionStartedAt!.add(Duration(microseconds: offset)).toIso8601String();

  void _apply(ObservationUpdate update) {
    if (sessionId == null || tripId == null) return;
    // Immediate phone request is always scheduled before storage or wearable IO.
    final shouldSound = update.snapshot.hasUnacknowledgedAlert;
    if (_audioRequested != shouldSound || update.started.isNotEmpty) {
      _audioRequested = shouldSound;
      _syncAudio(shouldSound);
    }
    for (final event in [
      ...update.started,
      ...update.ended,
      ...update.acknowledged,
    ]) {
      final row = <String, Object?>{
        'id': event.id,
        'trip_id': tripId,
        'session_id': sessionId,
        'type': event.type.code,
        'channel': event.type == EventType.eyesClosed ? 'eyes' : 'head',
        'started_us': event.signStartedUs,
        'started_at': _wallAt(event.signStartedUs),
        'threshold_us': event.thresholdUs,
        'threshold_at': _wallAt(event.thresholdUs),
        'alert_requested_us': event.alertRequestedUs,
        'alert_requested_at': _wallAt(event.alertRequestedUs),
        'acknowledged_us': event.acknowledgedUs,
        'acknowledged_at': _wallAt(event.acknowledgedUs),
        'ended_us': event.endedUs,
        'ended_at': _wallAt(event.endedUs),
        'end_reason': event.endReason?.code,
      };
      _write((db) => db.upsertEvent(row));
    }
    for (final transition in update.transitions) {
      final row = <String, Object?>{
        'id': _ids.v4(),
        'trip_id': tripId,
        'session_id': sessionId,
        'channel': transition.channel.name,
        'at': _wallAt(transition.atUs),
        'at_us': transition.atUs,
        'state': transition.toPhase.name,
        'available': transition.available ? 1 : 0,
        'reason': transition.reason.code,
      };
      _write((db) => db.insertTransition(row));
    }
    if (update.started.isNotEmpty || update.ended.isNotEmpty) {
      final eyes = update.started.any((e) => e.type == EventType.eyesClosed);
      onCameraEvidence?.call(eyes, update.snapshot.head.activeEvent != null);
      _pushWatchState();
      for (final event in update.started) {
        unawaited(
          wearable.alert(
            id: event.id,
            reason: event.type == EventType.eyesClosed
                ? 'Длительное закрытие глаз'
                : 'Продолжительный наклон головы — проверьте состояние',
            occurredUs: sessionBaseUs + event.thresholdUs,
            event: true,
            recommendation: event.type == EventType.eyesClosed
                ? recommendationText
                : null,
          ),
        );
      }
    }
    if (update.started.isNotEmpty ||
        update.ended.isNotEmpty ||
        update.acknowledged.isNotEmpty ||
        update.transitions.isNotEmpty) {
      _notify();
    }
  }

  void _syncAudio(bool start) {
    unawaited(() async {
      try {
        final request = start
            ? platform.alert(
                volume: settings.volume,
                vibrate: settings.vibration,
              )
            : platform.stopAlert();
        await request.timeout(const Duration(milliseconds: 500));
      } catch (e) {
        alertError = 'Оповещение телефона ограничено: $e';
        _notify();
      }
    }());
  }

  void acknowledge(Set<String> ids) {
    if (engine == null) return;
    _apply(engine!.acknowledge(eventIds: ids, nowUs: sessionNowUs));
    unawaited(wearable.cancel(ids.toList()));
  }

  Future<void> _endSession(EventEndReason reason) async {
    final id = sessionId;
    if (engine != null && id != null) {
      final end = sessionNowUs;
      _apply(engine!.stop(nowUs: end, reason: reason));
      final wall = _wallAt(end)!;
      _write(
        (db) =>
            db.endSession(id, endedAt: wall, endedUs: end, reason: reason.code),
      );
    }
    engine = null;
    sessionId = null;
    _collector = null;
    _audioRequested = false;
    _syncAudio(false);
    unawaited(wearable.cancel([], all: true));
    _pushWatchState();
  }

  Future<void> recalibrate({String? reason}) async {
    if (!active) return;
    phase = TripPhase.findingFace;
    await _endSession(EventEndReason.observationStopped);
    calibration = null;
    error = reason;
    _notify();
  }

  Future<void> changeSettings(AlgorithmSettings next) async {
    settings = next;
    _write((db) => db.setSetting('algorithm', next.toJson()));
    if (active) {
      await recalibrate(
        reason: 'Настройки изменены. Подтвердите лицо и выполните калибровку.',
      );
    }
    _notify();
  }

  Future<void> finish() async {
    if (!active) return;
    _lifecycleGeneration++;
    final id = tripId!;
    phase = TripPhase.idle;
    await _endSession(EventEndReason.tripEnded);
    tripId = null;
    faces = [];
    await camera.stop();
    await _safe(() => platform.keepAwake(false));
    _write(
      (db) => db.updateTrip(id, {
        'ended_at': DateTime.now().toUtc().toIso8601String(),
        'status': 'completed',
        'journal_incomplete': journalIncomplete ? 1 : 0,
      }),
    );
    lastFinishedTrip = id;
    onTripEnded?.call();
    recommendationText = null;
    _pushWatchState();
    _notify();
  }

  Future<void> foreground(bool value) async {
    final generation = ++_lifecycleGeneration;
    _foreground = value;
    if (!active) return;
    if (!value) {
      faces = [];
      phase = TripPhase.paused;
      await _endSession(EventEndReason.cameraStopped);
      await camera.stop();
      if (generation != _lifecycleGeneration) return;
      await _safe(() => platform.keepAwake(false));
    } else {
      phase = TripPhase.findingFace;
      error = 'Подтвердите лицо после возврата и повторите калибровку.';
      await _safe(() => platform.keepAwake(true));
      if (generation != _lifecycleGeneration || !active || !_foreground) return;
      if (!cameraPermissionBlocked) await camera.start();
    }
    _notify();
  }

  void _cameraError(Object e) {
    faces = [];
    cameraPermissionBlocked =
        e is CameraException &&
        [
          'CameraAccessDenied',
          'CameraAccessDeniedWithoutPrompt',
          'CameraAccessRestricted',
        ].contains(e.code);
    error = cameraPermissionBlocked
        ? 'Доступ к камере не разрешён. Включите его в настройках приложения и нажмите «Повторить запуск».'
        : 'Наблюдение недоступно: $e';
    if (_cameraFailureBusy) return;
    _cameraFailureBusy = true;
    unawaited(() async {
      try {
        if (active) {
          phase = _foreground ? TripPhase.findingFace : TripPhase.paused;
          await _endSession(EventEndReason.cameraStopped);
        }
        await camera.stop();
      } finally {
        _cameraFailureBusy = false;
        _notify();
      }
    }());
  }

  Future<void> testAlert() async {
    if (active) return;
    await _safe(
      () => platform.testAlert(
        volume: settings.volume,
        vibrate: settings.vibration,
      ),
    );
  }

  Future<void> retryCamera() async {
    if (!active || !_foreground || _cameraFailureBusy) return;
    cameraPermissionBlocked = false;
    error = null;
    _lastReconnectUs = clock.elapsedMicroseconds;
    await camera.start();
  }

  Future<void> openSettings() async {
    await _safe(() async {
      final result = await platform.call('app.openSettings');
      if (result['status'] != 'opened') {
        throw StateError('Не удалось открыть настройки ОС');
      }
    });
  }

  Future<void> _safe(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (e) {
      alertError = e.toString();
      _notify();
    }
  }

  void _throttledNotify() {
    final now = clock.elapsedMicroseconds;
    if (now - _lastUiUs >= 100000) {
      _lastUiUs = now;
      _notify();
    }
  }

  void _pushWatchState() {
    wearable.setState(
      tripId: tripId,
      sessionId: sessionId,
      activeEventIds: snapshot?.activeEvents.map((e) => e.id).toList() ?? [],
      recommendation: recommendationText,
    );
    unawaited(wearable.snapshot());
  }

  void updateRecommendation(String text) {
    recommendationText = text;
    _pushWatchState();
  }

  Future<List<Map<String, Object?>>> connectWearable({String? deviceId}) async {
    try {
      final result = await platform.call('wearable.connect', {
        'deviceId': deviceId,
      });
      wearableStatus = (result['message'] ?? result['status'] ?? 'Подключение')
          .toString();
      if (result['status'] == 'connected' || result['reachable'] == true) {
        await wearable.connect();
      }
      _notify();
      return await platform.wearableDevices();
    } catch (e) {
      wearableStatus = 'Подключение недоступно: $e';
      _notify();
      return [];
    }
  }

  void _platformEvent(Map<String, Object?> event) {
    if (event['type'] == 'platform_interruption') {
      unawaited(foreground(false));
    } else if (event['type'] == 'platform_resumed') {
      unawaited(foreground(true));
    } else if (event['type'] == 'wearable_message' && event['message'] is Map) {
      unawaited(() async {
        await wearable.receive(
          Map<String, Object?>.from(event['message'] as Map),
        );
        _notify();
      }());
    } else if (event['type'] == 'wearable_status') {
      final detail = event['status'] is Map
          ? Map<String, Object?>.from(event['status'] as Map)
          : event;
      final status = detail['status'];
      wearableStatus = (detail['reason'] ?? detail['message'] ?? status)
          .toString();
      if (status == 'connected' || detail['reachable'] == true) {
        if (!wearable.connected) unawaited(wearable.connect());
      } else if (detail['connected'] == false || status != 'connected') {
        wearable.disconnect();
      }
      _notify();
    }
  }

  final Map<String, Map<String, Object?>> _deliveries = {};
  void _delivery(Map<String, Object?> message, String status) {
    if (status == 'failed') {
      wearableStatus = 'Команда часам не доставлена';
      _notify();
    }
    final ackId = message['ack_message_id']?.toString();
    if (ackId != null) {
      final row = _deliveries[ackId];
      if (row == null) return;
      final updated = {
        ...row,
        'status': status,
        'received_at': DateTime.now().toUtc().toIso8601String(),
        'received_us': sessionId == row['session_id'] ? sessionNowUs : null,
      };
      _write((db) => db.upsertDelivery(updated));
      _deliveries[ackId] = updated;
      return;
    }
    if (message['type'] != 'alert') return;
    final id = message['message_id']!.toString();
    final previous = _deliveries[id];
    if (previous != null) {
      final updated = {
        ...previous,
        'status': previous['received_at'] != null ? previous['status'] : status,
      };
      _deliveries[id] = updated;
      _write((db) => db.upsertDelivery(updated));
      return;
    }
    final row = <String, Object?>{
      'id': id,
      'message_id': id,
      'trip_id': message['trip_id'],
      'session_id': message['session_id'],
      'event_id': message['event_id'],
      'recommendation_id': message['recommendation_id'],
      'wearable': 'paired',
      'status': status,
      'sent_at': DateTime.now().toUtc().toIso8601String(),
      'sent_us': sessionId == null || sessionId != message['session_id']
          ? null
          : sessionNowUs,
    };
    _deliveries[id] = row;
    if (_deliveries.length > 100) _deliveries.remove(_deliveries.keys.first);
    _write((db) => db.upsertDelivery(row));
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    unawaited(_platformEvents?.cancel());
    camera.pipeline.end();
    unawaited(camera.stop());
    unawaited(_safe(() => platform.stopAlert()));
    unawaited(_safe(() => platform.keepAwake(false)));
    super.dispose();
  }
}
