import 'dart:async';
import 'package:camera/camera.dart' show CameraException, CameraPreview;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Widget;
import 'package:uuid/uuid.dart';
import '../data/trip_repository.dart';
import '../logic/arkit_geometry.dart' show arkitCapabilities;
import '../logic/domain.dart';
import '../logic/attention_zones.dart';
import '../logic/detection_profile.dart';
import '../logic/mount.dart';
import '../logic/replay.dart' show tzSignActive;
import '../version.dart';
import 'arkit_engine.dart' show ArkitOptions, ArkitStats;
import 'camera_service.dart';
import 'detector.dart';
import 'face_source.dart';
import 'lab_recorder.dart';
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

/// ARKit for the trip: a source started with [options]; [onStats] gets the
/// once-a-second `device` numbers (thermal state, battery, frame rate).
typedef ArkitSourceFactory =
    FaceSource Function(
      ArkitOptions options,
      void Function(ArkitStats stats) onStats,
    );

enum TripPhase { idle, findingFace, calibrating, observing, paused }

/// Face engine of a trip. ARKit is the main one on iPhone (engine decision
/// 25.11.2026): its eyelids stay reliable to ≥ 55° to the camera, so the
/// eyes are watched on a vent mount. ML Kit is the developer choice and the
/// fallback when ARKit is unavailable; on a vent it watches the head only.
enum TripEngine {
  arkit('ARKit'),
  mlkit('ML Kit');

  const TripEngine(this.title);
  final String title;
}

class TripController extends ChangeNotifier {
  TripController({
    required this.repository,
    required this.platform,
    required this.detector,
    AlgorithmSettings? settings,
    CameraFactory? cameraFactory,
    this.arkitFactory,
    this.arkitSupported,
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
      onVitals: _onVitals,
      onUserAck: (ids) => acknowledge(ids.toSet(), fromWatch: true),
      onWatchState: (_) => _notify(),
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

  /// ARKit for the trip (iOS); null where there is none.
  final ArkitSourceFactory? arkitFactory;

  /// Whether this phone has ARKit Face Tracking (TrueDepth); null: assume
  /// it has when [arkitFactory] is given.
  final Future<bool> Function()? arkitSupported;

  /// Engine the next trip asks for (developer choice, ARKit by default).
  TripEngine engineChoice = TripEngine.arkit;

  /// Engine of the current trip: [engineChoice], or ML Kit when ARKit is
  /// unavailable or failed to start.
  TripEngine engineInUse = TripEngine.mlkit;

  /// Why the trip runs on ML Kit although ARKit was asked for.
  String? engineNote;

  /// ARKit frame rate in the trip: 30, the rate the phone falls back to once
  /// warm anyway (bench-v1); about 29 analyses a second.
  static const arkitFps = 30;
  FaceSource? _arkit;
  ArkitOptions? arkitOptions;
  final List<int> _arkitCompletions = [];

  /// Latest `device` line of ARKit (thermal state, battery, frame rate).
  Map<String, Object?>? lastDevice;

  /// Capabilities of the engine in use.
  DetectorCapabilities get capabilities => engineInUse == TripEngine.arkit
      ? arkitCapabilities
      : detector.capabilities;
  final clock = Stopwatch()..start();
  final _ids = const Uuid();
  AlgorithmSettings settings;
  CalibrationProfile? calibration;
  CalibrationCollector? _collector;
  ObservationEngine? engine;

  /// Detection profile of the trip (attention-method.md § 10), from the
  /// next calibration. By default the current tuned profile: it calibrates
  /// on any mount the way the lab does for a side mount (§ 9) — the road
  /// pose is whatever the driver looks at while driving, head angles are
  /// taken relative to it (`R_cal⁻¹ · R`) with a slow drift of that pose,
  /// the eyes only within the profile's view limit of the engine, the
  /// thresholds of the profile. The developer option «ТЗ 2.2 (эталон)»
  /// ([DetectionProfile.tz22]) is the strict ТЗ calibration (head turned to
  /// the camera within the engine's eye limit), camera-frame angles and the
  /// user's ТЗ thresholds.
  DetectionProfile profile = DetectionProfile.current;
  bool get tzReference => profile.isReference;
  MountCalibrationCollector? _mountCollector;

  /// The attention pipeline of the session, the same as in the lab and the
  /// replay the profile was tuned on: driver continuity (a new tracking id
  /// after a short loss is still the driver, ФТ-02/03), the eye gate of the
  /// profile (lids lowered by looking down, a squint), road-relative angles
  /// and the slow drift of the road pose. The automata get its
  /// measurements.
  ZoneAttentionProvider? attention;
  AttentionState attentionState = AttentionState.unknown;

  /// The driver's face on the last calibration frame, to anchor driver
  /// continuity at the session start (clock microseconds).
  FaceSignals? _anchorFace;
  int? _anchorUs;

  /// Slow drift of the road pose, when the profile has it.
  RoadAdaptation? get roadAdaptation => attention?.pipeline?.roadAdaptation;

  /// The profile and settings the automata and the fatigue monitor run on:
  /// the road-frame profile in mount mode, [calibration] itself otherwise.
  CalibrationProfile? engineCalibration;
  AlgorithmSettings? _engineSettings;

  /// Shown under the trip status after a calibration with a restriction
  /// (FR-CAL-06: eyes out of the engine's view, head only).
  String? calibrationNote;

  /// Developer option «Записывать поездку»: the trip goes to a JSONL file
  /// (schema 1, the lab's lines without prompts and labels) in the same
  /// folder as the lab recordings, for offline analysis. Numbers only.
  LabRecorder? recorder;
  bool recordTrips = false;

  /// Where the phone is mounted, for `meta.mount` (as in the lab).
  String mountPosition = 'front';
  String? recordingId;
  int _recordBaseUs = 0, _lastDerivedUs = 0;
  bool get recording => recorder?.active ?? false;
  TripPhase phase = TripPhase.idle;
  String? tripId, sessionId, lastFinishedTrip;
  String? error, alertError;
  String wearableStatus = 'Часы не подключены';
  List<Map<String, Object?>> wearableDevices = [];
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
  FatigueMonitor? _fatigueMonitor;
  FatigueSnapshot fatigue = FatigueSnapshot.empty;
  final drive = DriveClock();
  WearableVitals? vitals;
  int _lastFatigueUs = 0;
  String? watchAcknowledgedAt;
  bool alarmEscalated = false;
  // Trip-level vigilance history; written into every session checkpoint.
  final List<int> fatiguePerMinute = [];
  int tripBreaks = 0, tripEscalations = 0, _fatigueMinutePeak = 0;
  int _lastFatigueMinuteUs = 0;
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

  /// Fatigue level reached "high", a break was taken, or watch vitals changed.
  VoidCallback? onFatigueHigh, onBreakTaken, onVitalsChanged;
  ObservationSnapshot? get snapshot => engine?.snapshot;
  bool get active => tripId != null;
  int get sessionNowUs =>
      (clock.elapsedMicroseconds - sessionBaseUs).clamp(0, 1 << 62);
  double get calibrationProgress =>
      ((clock.elapsedMicroseconds - _calibrationStart) / 10000000).clamp(0, 1);
  int get calibrationSamples =>
      _collector?.usableFrames ?? _mountCollector?.processedFrames ?? 0;

  /// Mount mode: the calibration and the automata use road-relative angles.
  bool get mountRelative => profile.attention.mountRelative;
  Future<void> get pendingWrites => _writes;
  Duration get drivingTime =>
      Duration(microseconds: drive.continuousUs(clock.elapsedMicroseconds));
  Duration get untilBreak =>
      Duration(microseconds: drive.untilBreakUs(clock.elapsedMicroseconds));

  /// Watch telemetry is used for 30 minutes after it was received.
  WearableVitals? get freshVitals {
    final v = vitals;
    if (v == null) return null;
    return clock.elapsedMicroseconds - v.receivedUs <= 30 * 60 * 1000000
        ? v
        : null;
  }

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
    fatiguePerMinute.clear();
    tripBreaks = 0;
    tripEscalations = 0;
    _fatigueMinutePeak = 0;
    _lastFatigueMinuteUs = clock.elapsedMicroseconds;
    drive.reset();
    drive.active(clock.elapsedMicroseconds);
    fatigue = FatigueSnapshot.empty;
    final id = tripId!;
    _write(
      (db) => db.insertTrip({
        'id': id,
        'started_at': DateTime.now().toUtc().toIso8601String(),
      }),
    );
    onTripStarted?.call();
    engineInUse = await _chooseEngine();
    if (generation != _lifecycleGeneration || !active) return;
    await _startRecording();
    phase = TripPhase.findingFace;
    // The watch must learn about the trip before any alert: it starts its
    // background session on a non-idle snapshot or on the launch below.
    _pushWatchState();
    unawaited(() async {
      try {
        await platform.call('wearable.prepare');
      } catch (_) {
        // Android/Garmin have no launch step; the watch status says the rest.
      }
    }());
    await _safe(() => platform.keepAwake(true));
    if (generation != _lifecycleGeneration || !active || !_foreground) return;
    _notify();
    await _startCamera();
  }

  static const arkitUnavailable =
      'ARKit на этом телефоне недоступен. Работаю на ML Kit: на решётке '
      'слежу только за головой.';

  Future<TripEngine> _chooseEngine() async {
    engineNote = null;
    if (engineChoice != TripEngine.arkit || arkitFactory == null) {
      return TripEngine.mlkit;
    }
    var supported = false;
    try {
      supported = await (arkitSupported?.call() ?? Future.value(true)).timeout(
        const Duration(seconds: 2),
      );
    } catch (_) {}
    if (!supported) engineNote = arkitUnavailable;
    return supported ? TripEngine.arkit : TripEngine.mlkit;
  }

  /// ARKit options of the trip: 30 fps, the native preview only when the
  /// screen shows it.
  ArkitOptions _arkitOptionsNow() =>
      ArkitOptions(fps: arkitFps, preview: settings.showPreview);

  bool get _cameraRunning => engineInUse == TripEngine.arkit
      ? _arkit?.running ?? false
      : camera.running;

  /// Starts the engine of the trip. When ARKit fails to start, the trip goes
  /// on with ML Kit (a new calibration, because the engines' numbers differ).
  Future<void> _startCamera() async {
    if (engineInUse != TripEngine.arkit) return camera.start();
    if (_arkit != null) return;
    final options = _arkitOptionsNow();
    final source = arkitFactory!(options, _onArkitStats);
    _arkit = source;
    arkitOptions = options;
    try {
      await source.start(
        nowUs: () => clock.elapsedMicroseconds,
        onResult: _onArkitResult,
        onError: _cameraError,
        onChanged: _notify,
      );
    } catch (e) {
      if (!identical(_arkit, source)) return;
      _arkit = null;
      arkitOptions = null;
      unawaited(_safe(source.dispose));
      engineInUse = TripEngine.mlkit;
      engineNote =
          'ARKit не запустился. Работаю на ML Kit: на решётке '
          'слежу только за головой.';
      if (phase == TripPhase.calibrating || calibration != null) {
        await recalibrate(reason: engineNote);
      }
      if (active && _foreground) await camera.start();
    }
    _notify();
  }

  Future<void> _stopCamera() async {
    final arkit = _arkit;
    _arkit = null;
    arkitOptions = null;
    if (arkit != null) await arkit.dispose();
    if (engineInUse != TripEngine.arkit || camera.running) await camera.stop();
  }

  void _onArkitResult(FaceResult result) {
    if (result.engineId != arkitCapabilities.id) return;
    _arkitCompletions.add(result.completedUs);
    final old = clock.elapsedMicroseconds - 120000000;
    while (_arkitCompletions.isNotEmpty && _arkitCompletions.first < old) {
      _arkitCompletions.removeAt(0);
    }
    _onFaces(result.faces, result.capturedUs, result.completedUs);
  }

  /// A `device` line of ARKit: kept for the screen and the recording.
  void _onArkitStats(ArkitStats stats) {
    final line = stats.toJson();
    lastDevice = line;
    if (recording) _record({...line, 'atUs': _recUs(stats.atUs)});
  }

  /// Completed analyses of the engine in use with completion time in
  /// [fromUs, toUs) on [clock] (КЧ-05: at least 600 in every 60 s).
  int completedBetween(int fromUs, int toUs) => engineInUse == TripEngine.arkit
      ? _arkitCompletions.where((t) => t >= fromUs && t < toUs).length
      : camera.pipeline.completedBetween(fromUs, toUs);

  /// Live preview of the engine in use, never recorded; null when there is
  /// none yet.
  Widget? preview() {
    if (engineInUse == TripEngine.arkit) return _arkit?.preview();
    final controller = camera.controller;
    if (controller == null || !controller.value.isInitialized) return null;
    return CameraPreview(controller);
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
    calibrationNote = null;
    _anchorFace = null;
    _anchorUs = null;
    _calibrationStart = clock.elapsedMicroseconds;
    if (!mountRelative) {
      _collector = CalibrationCollector(
        trackingId: trackingId,
        detector: profile.detector(capabilities),
        hiddenEyes: settings.hiddenEyes,
        startedUs: _calibrationStart,
      );
    } else {
      _mountCollector = MountCalibrationCollector(
        trackingId: trackingId,
        detector: profile.detector(capabilities),
        hiddenEyes: settings.hiddenEyes,
        startedUs: _calibrationStart,
      );
      _say('Смотрите на дорогу, как обычно'); // FR-CAL-04
    }
    phase = TripPhase.calibrating;
    _notify();
  }

  @visibleForTesting
  int get calibrationStartUs => _calibrationStart;

  /// Voice prompt of the calibration; best effort, never an alert error.
  void _say(String text) => unawaited(() async {
    try {
      await platform.call('speech.say', {'text': text});
    } catch (_) {}
  }());

  /// The face's engine numbers; the ML Kit adapter always sets them.
  static FaceSignals _signalsOf(DetectedFace f) =>
      f.signals ??
      FaceSignals(
        engineId: '',
        trackingId: f.measurement.trackingId,
        headYawLeft: f.measurement.yaw,
        headPitchDown: f.measurement.pitchDown,
        headRollRight: f.measurement.roll,
        eyeOpenLeft: f.measurement.leftEye,
        eyeOpenRight: f.measurement.rightEye,
      );

  void _onFaces(List<DetectedFace> result, int captured, int completed) {
    if (!active || !_foreground) return;
    faces = result;
    _recordFrame(result, captured, completed);
    if (phase == TripPhase.calibrating) {
      _collector?.add(
        capturedUs: captured,
        faces: result.map((f) => f.measurement).toList(),
      );
      final signals = result.map(_signalsOf).toList();
      _mountCollector?.add(capturedUs: captured, faces: signals);
      if (signals.length == 1) {
        _anchorFace = signals.single;
        _anchorUs = captured;
      }
    } else if (phase == TripPhase.observing &&
        sessionId != null &&
        engine != null) {
      final pipeline = attention;
      final at = captured - sessionBaseUs;
      // Every face, in the engine's order: the pipeline keeps the driver
      // across tracking-id changes, gates lowered lids and pauses on a
      // second face (ФТ-02) exactly as the lab and the replay do.
      if (pipeline != null) {
        attentionState = pipeline.updateFaces(
          result.map(_signalsOf).toList(),
          at,
        );
      }
      final measurements =
          pipeline?.lastMeasurements ??
          result.map((f) => f.measurement).toList();
      final engine = this.engine!;
      _apply(
        engine.process(
          sessionId: sessionId!,
          capturedUs: at,
          completedUs: completed - sessionBaseUs,
          faces: measurements,
        ),
      );
      _feedFatigue(measurements, at);
      pipeline
        ?..tzSignActive = tzSignActive(engine.snapshot)
        ..eyesEventActive = engine.snapshot.eyes.activeEvent != null;
      _recordDerived(completed);
      if (engine.snapshot.requiresRecalibration) {
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

  void _feedFatigue(List<FaceMeasurement> measured, int atUs) {
    final monitor = _fatigueMonitor, profile = engineCalibration ?? calibration;
    final settings = _engineSettings ?? this.settings;
    if (monitor == null || profile == null) return;
    final face =
        measured.length == 1 && measured.single.trackingId == profile.trackingId
        ? measured.single
        : null;
    if (face != null &&
        !settings.hiddenEyes &&
        face.hasEyes &&
        FaceMeasurement.angle(face.yaw) &&
        face.yaw!.abs() <= profile.detector.eyeYawLimit) {
      monitor.addEyes(atUs, face.leftEye!, face.rightEye!);
    } else {
      monitor.eyesUnavailable();
    }
    if (face != null &&
        face.hasHeadAngles &&
        (face.yaw! - profile.neutralYaw).abs() <= settings.headYawLimit) {
      monitor.addHead(atUs, face.pitchDown! - profile.neutralPitch);
    } else {
      monitor.headUnavailable();
    }
  }

  void _updateFatigue() {
    final monitor = _fatigueMonitor;
    if (monitor == null || phase != TripPhase.observing) return;
    final previous = fatigue.level;
    fatigue = monitor.snapshot(sessionNowUs);
    if (fatigue.level.index > _fatigueMinutePeak) {
      _fatigueMinutePeak = fatigue.level.index;
    }
    if (fatigue.level == previous) return;
    if (fatigue.level == FatigueLevel.high) {
      // A short chime, never louder than the configured alarm and never on
      // top of an active camera alarm.
      if (!_audioRequested) {
        unawaited(
          _safe(
            () => platform.testAlert(
              volume: settings.volume * .6,
              vibrate: settings.vibration,
            ),
          ),
        );
      }
      onFatigueHigh?.call();
    }
    _pushWatchState();
    _notify();
  }

  /// The user confirms a rest stop: restart the continuous-driving count and
  /// clear fatigue trends (eye evidence stays until the trip ends).
  void markBreak() {
    if (!active) return;
    drive.markBreak(clock.elapsedMicroseconds);
    tripBreaks++;
    _fatigueMonitor = calibration == null ? null : _newFatigueMonitor();
    fatigue = FatigueSnapshot.empty;
    onBreakTaken?.call();
    _pushWatchState();
    _notify();
  }

  FatigueMonitor _newFatigueMonitor() => FatigueMonitor(
    eyeThreshold: (_engineSettings ?? settings).hiddenEyes
        ? null
        : calibration!.eyeThreshold,
    nodThreshold: (_engineSettings ?? settings).pitchThreshold * .6,
    eyesEventUs: (_engineSettings ?? settings).eyesClosedUs,
    headEventUs: (_engineSettings ?? settings).headDownUs,
  );

  /// Escalates an alarm that stayed unacknowledged for 5 s. Runs on the
  /// controller tick; exposed for tests.
  @visibleForTesting
  void checkEscalation() {
    final current = snapshot;
    final pending = current?.activeEvents
        .where((e) => e.acknowledgedUs == null)
        .map((e) => e.alertRequestedUs)
        .fold<int?>(null, (a, b) => a == null || b < a ? b : a);
    if (pending == null) {
      if (alarmEscalated) {
        alarmEscalated = false;
        _notify();
      }
      return;
    }
    if (alarmEscalated ||
        !settings.escalate ||
        phase != TripPhase.observing ||
        sessionNowUs - pending < AlgorithmSettings.escalationDelayUs) {
      return;
    }
    alarmEscalated = true;
    tripEscalations++;
    unawaited(() async {
      try {
        await platform
            .alert(volume: 1, vibrate: true)
            .timeout(const Duration(milliseconds: 500));
      } catch (e) {
        alertError = 'Усиление сигнала недоступно: $e';
      }
      _notify();
    }());
  }

  void _onVitals(WearableVitals value) {
    final changed = vitals?.bodyBattery != value.bodyBattery;
    vitals = value;
    if (changed) onVitalsChanged?.call();
    _notify();
  }

  void _tick() {
    if (_disposed) return;
    final now = clock.elapsedMicroseconds;
    if (active && phase != TripPhase.paused) {
      if (drive.active(now)) tripBreaks++;
    }
    // One entry per trip minute: peak fatigue level index, or -1 when the
    // camera did not observe during that minute.
    if (active && now - _lastFatigueMinuteUs >= 60000000) {
      _lastFatigueMinuteUs = now;
      fatiguePerMinute.add(
        phase == TripPhase.observing ? _fatigueMinutePeak : -1,
      );
      _fatigueMinutePeak = fatigue.level.index;
    }
    checkEscalation();
    if (now - _lastFatigueUs >= 1000000) {
      _lastFatigueUs = now;
      _updateFatigue();
    }
    if (phase == TripPhase.calibrating &&
        now - _calibrationStart >= 10000000 &&
        !_calibrationFinishing) {
      final pending = engineInUse == TripEngine.mlkit
          ? camera.pipeline.inFlightCapturedUs
          : null;
      if (pending == null ||
          pending > _calibrationStart + 10000000 ||
          now - pending > 300000) {
        if (pending != null &&
            pending <= _calibrationStart + 10000000 &&
            now - pending > 300000) {
          _collector?.add(capturedUs: pending, faces: []);
          _mountCollector?.add(capturedUs: pending, faces: []);
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
          completedPerMinute.add(completedBetween(start, start + 60000000));
        }
        final id = sessionId!, atUs = sessionNowUs;
        final diagnostics = <String, Object?>{
          'completed_per_minute': List.of(completedPerMinute),
          'engine': capabilities.id,
          'build_mode': kReleaseMode
              ? 'release'
              : kProfileMode
              ? 'profile'
              : 'debug',
          'app_version': appVersion,
          'algorithm_version': ObservationEngine.algorithmVersion,
          'fatigue': fatigue.toJson(),
          'continuous_drive_s': drive.continuousUs(now) ~/ 1000000,
          'trip_fatigue_per_minute': List.of(fatiguePerMinute),
          'trip_breaks': tripBreaks,
          'trip_escalations': tripEscalations,
        };
        _write(
          (db) =>
              db.checkpointSession(id, atUs: atUs, diagnostics: diagnostics),
        );
      }
    }
    if (active &&
        _foreground &&
        !_cameraRunning &&
        !cameraPermissionBlocked &&
        !_cameraFailureBusy &&
        now - _lastReconnectUs >= 2000000) {
      _lastReconnectUs = now;
      unawaited(_startCamera());
    }
    if (wearable.connected && now - _lastWatchSyncUs >= 10000000) {
      _lastWatchSyncUs = now;
      unawaited(wearable.synchronize());
    }
    if (phase == TripPhase.calibrating) _throttledNotify();
  }

  /// Finishes the calibration window at [now]; the controller tick calls it
  /// 10 s after the start. Exposed for tests.
  @visibleForTesting
  void finishCalibration(int now) => _finishCalibration(now);

  void _finishCalibration(int now) {
    _calibrationFinishing = true;
    try {
      final CalibrationResult result;
      final mount = _mountCollector;
      String? note;
      if (mount != null) {
        final r = mount.finish(nowUs: now);
        result = r.result;
        note = r.note;
      } else {
        result = _collector!.finish(nowUs: now);
      }
      _collector = null;
      _mountCollector = null;
      if (result.profile == null) {
        phase = TripPhase.findingFace;
        error = result.issues.join('\n');
      } else {
        calibration = profile.calibrate(result.profile!);
        final saved = calibration!.toJson();
        _write((db) => db.setSetting('calibration', saved));
        if (note != null) {
          // FR-CAL-06: a false eye alarm is worse than no eye tracking.
          calibrationNote = note;
          _say('Глаза под таким углом не видно, слежу за головой');
        }
        _newSession();
        _recordCalibration(now);
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
    final profile = calibration!;
    // The pipeline of the profile. Mount mode: the measurements carry
    // road-frame angles, so the automata get the road-frame profile
    // (neutral 0); eyes hidden by the mount turn the eye channel off like
    // the ТЗ "hidden eyes" setting.
    final pipeline = ZoneAttentionProvider(settings: this.profile.attention)
      ..reset(profile);
    attention = pipeline;
    attentionState = AttentionState.unknown;
    final anchor = _anchorFace, seen = _anchorUs;
    if (anchor != null && seen != null) {
      // Where the driver was last seen, so a loss right after the start of
      // the session is judged by geometry (ПЗ: the selected face keeps its
      // profile).
      pipeline.anchorDriver(anchor, seen - sessionBaseUs);
    }
    engineCalibration = pipeline.engineCalibration;
    _engineSettings = this.profile.session(
      settings,
      hiddenEyes: engineCalibration!.hiddenEyes,
    );
    engine = ObservationEngine(
      sessionId: sessionId!,
      calibration: engineCalibration!,
      settings: _engineSettings!,
    );
    _fatigueMonitor = _newFatigueMonitor();
    fatigue = FatigueSnapshot.empty;
    final row = <String, Object?>{
      'id': sessionId,
      'trip_id': tripId,
      'started_at': sessionStartedAt!.toIso8601String(),
      'settings_json': {
        ..._engineSettings!.toJson(),
        if (mountRelative) 'mountRelative': true,
        'detectionProfile': this.profile.toJson(),
      },
      'calibration_json': calibration!.toJson(),
      'detector_id': capabilities.id,
      'detector_version': capabilities.version,
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
        'reason': channel == 'eyes' && _engineSettings!.hiddenEyes
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
    if (recording) {
      for (final (change, events) in [
        ('started', update.started),
        ('ended', update.ended),
        ('acknowledged', update.acknowledged),
      ]) {
        for (final e in events) {
          _record({
            ...RecordingSchema.event(
              change: change,
              event: e,
              atUs: _recUs(clock.elapsedMicroseconds),
            ),
            'sessionOffsetUs': _recUs(sessionBaseUs),
          });
        }
      }
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
            kind: event.type == EventType.eyesClosed ? 'eyes' : 'head',
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
        // A new event during an escalated alarm keeps the escalated level.
        final request = start
            ? platform.alert(
                volume: alarmEscalated ? 1 : settings.volume,
                vibrate: alarmEscalated || settings.vibration,
              )
            : platform.stopAlert();
        await request.timeout(const Duration(milliseconds: 500));
      } catch (e) {
        alertError = 'Оповещение телефона ограничено: $e';
        _notify();
      }
    }());
  }

  void acknowledge(Set<String> ids, {bool fromWatch = false}) {
    if (engine == null) return;
    final update = engine!.acknowledge(eventIds: ids, nowUs: sessionNowUs);
    if (fromWatch && update.acknowledged.isNotEmpty) {
      watchAcknowledgedAt = DateTime.now().toUtc().toIso8601String();
    }
    _apply(update);
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
    _mountCollector = null;
    attention = null;
    attentionState = AttentionState.unknown;
    _fatigueMonitor = null;
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
    await _stopRecording();
    tripId = null;
    faces = [];
    await _stopCamera();
    await _safe(() => platform.keepAwake(false));
    _write(
      (db) => db.updateTrip(id, {
        'ended_at': DateTime.now().toUtc().toIso8601String(),
        'status': 'completed',
        'journal_incomplete': journalIncomplete ? 1 : 0,
      }),
    );
    lastFinishedTrip = id;
    drive.reset();
    fatigue = FatigueSnapshot.empty;
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
      await _stopCamera();
      if (generation != _lifecycleGeneration) return;
      await _safe(() => platform.keepAwake(false));
    } else {
      phase = TripPhase.findingFace;
      error = 'Подтвердите лицо после возврата и повторите калибровку.';
      await _safe(() => platform.keepAwake(true));
      if (generation != _lifecycleGeneration || !active || !_foreground) return;
      if (!cameraPermissionBlocked) await _startCamera();
    }
    _notify();
  }

  void _cameraError(Object e) {
    faces = [];
    cameraPermissionBlocked =
        (e is CameraException &&
            [
              'CameraAccessDenied',
              'CameraAccessDeniedWithoutPrompt',
              'CameraAccessRestricted',
            ].contains(e.code)) ||
        // ArkitEngine reports `camera_unauthorized` with this text.
        (engineInUse == TripEngine.arkit &&
            e.toString().contains('Нет доступа к камере'));
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
        await _stopCamera();
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
    await _startCamera();
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
    final camera = snapshot?.cameraStatus;
    wearable.setState(
      tripId: tripId,
      sessionId: sessionId,
      activeEventIds: snapshot?.activeEvents.map((e) => e.id).toList() ?? [],
      recommendation: recommendationText,
      extra: {
        'level': !active
            ? 'idle'
            : switch (camera) {
                CameraStatus.warning => 'warning',
                CameraStatus.observing => 'observing',
                CameraStatus.limited => 'limited',
                _ => 'unavailable',
              },
        'fatigue': fatigue.level.name,
        if (active) 'drive_min': drivingTime.inMinutes,
      },
    );
    unawaited(wearable.snapshot());
  }

  /// Sends a short test burst to the watch through the live protocol, so the
  /// first pulse goes through the same TTL check as a real alert.
  Future<bool> testWatch() async {
    if (!wearable.synchronized) return false;
    await wearable.alert(
      id: 'test-${_ids.v4()}',
      reason: 'Проверка вибрации',
      occurredUs: clock.elapsedMicroseconds,
      event: false,
      kind: 'test',
    );
    return true;
  }

  /// Plain-language state of screen-off alerts on Apple Watch.
  String? get watchBackgroundText => switch (wearable.watchBackground) {
    'active' => 'Часы предупредят и при погасшем экране',
    'starting' => 'Часы включают фоновый режим…',
    'denied' =>
      'Откройте NSControl на часах и разрешите тренировку, иначе при погасшем экране часы промолчат',
    'failed' || 'unavailable' =>
      'Фоновый режим часов не запустился. Держите приложение на часах открытым',
    'off' => active ? 'Фоновый режим часов выключен' : null,
    _ => null,
  };

  void updateRecommendation(String text) {
    recommendationText = text;
    _pushWatchState();
  }

  Future<List<Map<String, Object?>>> connectWearable({String? deviceId}) async {
    try {
      final result = await platform.call('wearable.connect', {
        'deviceId': deviceId,
      });
      wearableStatus = describeWearable(result);
      if (result['status'] == 'connected' || result['reachable'] == true) {
        await wearable.connect();
      }
      _notify();
      wearableDevices = await platform.wearableDevices();
      _notify();
      return wearableDevices;
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
    } else if (event['type'] == 'wearable_devices' &&
        event['devices'] is List) {
      wearableDevices = (event['devices'] as List)
          .whereType<Map>()
          .map((m) => Map<String, Object?>.from(m))
          .toList();
      _notify();
    } else if (event['type'] == 'wearable_status') {
      final detail = event['status'] is Map
          ? Map<String, Object?>.from(event['status'] as Map)
          : event;
      final status = detail['status'];
      wearableStatus = describeWearable(detail);
      if (status == 'connected' || detail['reachable'] == true) {
        if (!wearable.connected) unawaited(wearable.connect());
      } else if (detail['connected'] == false || status != 'connected') {
        wearable.disconnect();
      }
      _notify();
    }
  }

  /// User-facing wearable state. Native layers report status codes; Garmin
  /// bridges also supply Russian reasons, other free-form text is not shown.
  static String describeWearable(Map<String, Object?> detail) {
    final reason = detail['reason']?.toString();
    if (detail['transport'] == 'garmin' &&
        reason != null &&
        reason.isNotEmpty) {
      return reason;
    }
    return switch (detail['status']) {
      'connected' => 'Часы на связи',
      'disconnected' => 'Часы не на связи. Откройте NSControl на часах',
      'unpaired' => 'Apple Watch не сопряжены с этим iPhone',
      'app_not_installed' => 'Приложение NSControl не установлено на часах',
      'connecting' => 'Подключение…',
      'unavailable' => 'Обмен с часами недоступен на этом устройстве',
      'selection_required' => 'Выберите часы в списке',
      'selection_requested' => 'Выберите часы в Garmin Connect и вернитесь',
      'timeout' => 'Часы не ответили вовремя',
      'error' => 'Ошибка связи с часами',
      _ => 'Часы не подключены',
    };
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

  // ---- recording (developer option) ----------------------------------------

  int _recUs(int absUs) => absUs - _recordBaseUs;
  void _record(Map<String, Object?> line) => recorder?.write(line);

  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  Future<void> _startRecording() async {
    final target = recorder;
    if (!recordTrips || target == null) return;
    final started = DateTime.now();
    final id = 'trip-${_stamp(started)}';
    try {
      await target.start(id);
    } catch (e) {
      alertError = 'Запись поездки не началась: $e';
      return;
    }
    recordingId = id;
    _recordBaseUs = clock.elapsedMicroseconds;
    _lastDerivedUs = 0;
    Map<String, Object?> device = const {};
    try {
      device = await platform
          .call('device.info')
          .timeout(const Duration(milliseconds: 500));
    } catch (_) {}
    _record(
      RecordingSchema.meta(
        recordingId: id,
        app: appVersion,
        engines: [capabilities.id],
        startedAt: started,
        device: device['model'] as String?,
        os: device['os'] as String?,
        extra: {
          'source': 'trip',
          'tripId': tripId,
          // The trip runs the profile's attention pipeline as the lab does.
          'attention': ZoneAttentionProvider(settings: profile.attention).id,
          'attentionSettings': profile.attention.toJson(),
          'tripEngine': engineInUse.name,
          if (engineNote != null) 'engineNote': engineNote,
          'tzReference': tzReference,
          'detectionProfile': profile.toJson(),
          'mount': {'position': mountPosition},
          'algorithm': ObservationEngine.algorithmVersion,
          'settings': settings.toJson(),
        },
      ),
    );
  }

  Future<void> _stopRecording() async {
    final target = recorder;
    if (target == null || !target.active) return;
    await target.stop();
    recordingId = null;
  }

  /// The trip's calibration with the zones the replay needs: road-relative
  /// with `mountRelative`. `sessionOffsetUs` converts the automata times of
  /// the session (events) to the recording clock.
  void _recordCalibration(int now) {
    final profile = calibration;
    if (!recording || profile == null) return;
    final zones =
        attention?.pipeline?.zones ?? ZoneMap.fromCalibration(profile);
    _record({
      ...RecordingSchema.calibration(
        atUs: _recUs(now),
        profile: profile,
        zones: zones.toJson(),
      ),
      'sessionOffsetUs': _recUs(sessionBaseUs),
    });
  }

  void _recordFrame(List<DetectedFace> result, int captured, int completed) {
    if (!recording) return;
    final id = calibration?.trackingId;
    final driver = result.isEmpty
        ? null
        : result
                  .where((f) => id != null && f.measurement.trackingId == id)
                  .firstOrNull ??
              result.first;
    _record({
      ...RecordingSchema.frame(
        engine: capabilities.id,
        capturedUs: _recUs(captured),
        completedUs: _recUs(completed),
        faceCount: result.length,
        signals: driver == null ? null : _signalsOf(driver),
      ),
      if (result.length > 1)
        'others': [
          for (final f in result)
            if (!identical(f, driver)) _signalsOf(f).toJson(),
        ],
    });
  }

  /// 10 per second, as in the lab.
  void _recordDerived(int completed) {
    final current = engine?.snapshot;
    if (!recording || current == null) return;
    if (completed - _lastDerivedUs < 100000 && completed >= _lastDerivedUs) {
      return;
    }
    _lastDerivedUs = completed;
    _record(
      RecordingSchema.derived(
        atUs: _recUs(completed),
        zone: attentionState.zone,
        eyes: current.eyes,
        head: current.head,
        fatigue: fatigue,
        extra: {
          'sessionOffsetUs': _recUs(sessionBaseUs),
          if (attentionState.details.isNotEmpty)
            'attention': attentionState.details,
        },
      ),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(recorder?.stop());
    _timer?.cancel();
    unawaited(_platformEvents?.cancel());
    camera.pipeline.end();
    unawaited(camera.stop());
    final arkit = _arkit;
    _arkit = null;
    if (arkit != null) unawaited(_safe(arkit.dispose));
    unawaited(_safe(() => platform.stopAlert()));
    unawaited(_safe(() => platform.keepAwake(false)));
    super.dispose();
  }
}
