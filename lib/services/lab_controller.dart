import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../logic/attention_zones.dart';
import '../logic/detection_profile.dart';
import '../logic/domain.dart';
import '../logic/driver_continuity.dart';
import '../logic/mount.dart';
import '../logic/replay.dart' show tzSignActive;
import '../version.dart';
import 'detector.dart';
import 'face_source.dart';
import 'lab_recorder.dart';
import 'lab_server.dart';
import 'platform_bridge.dart';

/// One line of the lab feed shown on the phone.
class LabNote {
  const LabNote(this.atUs, this.text, {this.important = false});
  final int atUs;
  final String text;
  final bool important;
}

enum LabPhase { stopped, uncalibrated, calibrating, observing }

/// Hidden developer lab: runs a face source outside of the trip, applies the
/// same calibration and ТЗ automata, streams and records numbers (schema 1).
/// The trip is not touched: the lab owns its own engine instance and session
/// and refuses to start while a trip is active (one camera).
class LabController extends ChangeNotifier {
  LabController({
    required this.options,
    required this.platform,
    required this.settings,
    required Directory recordingsDirectory,
    AttentionStateProvider? attention,
    LabServer? server,
    this.startServer = true,
    int Function()? clockUs,
  }) : clockUs = clockUs ?? (Stopwatch()..start()).elapsedMicrosecondsOf,
       attention =
           attention ??
           ZoneAttentionProvider(settings: DetectionProfile.current.attention),
       recorder = LabRecorder(recordingsDirectory) {
    this.server =
        server ?? LabServer(recordings: recorder.list, onConnected: _greeting);
    if (options.isEmpty) throw ArgumentError('Нет движков для Лаборатории');
    option = options.first;
  }

  final List<LabEngineOption> options;
  final PlatformBridge platform;
  final LabRecorder recorder;

  /// Zones and decisions over the ТЗ automata. With [ZoneAttentionProvider]
  /// its eye gate also decides what goes into the automata (lab mode only).
  AttentionStateProvider attention;
  final bool startServer;
  late final LabServer server;

  /// The trip settings at the time the lab opened (same thresholds as ТЗ).
  AlgorithmSettings settings;
  late LabEngineOption option;
  FaceSource? source;

  /// Monotonic microseconds (a Stopwatch; injectable for tests).
  final int Function() clockUs;

  /// Start of the current time base (lab open or recording start), in
  /// [clock] microseconds. Every recorded/streamed time is relative to it.
  int baseUs = 0;
  int get nowUs => clockUs() - baseUs;

  CalibrationProfile? calibration;
  _LabCollector? _collector;

  /// Compare mode: the other engines calibrate over the same window as the
  /// primary one, each from its own frames, and get their own `calibration`
  /// line (field `engine`). The live automata run on the primary engine; the
  /// replay of another engine takes its own line. Null until that engine
  /// sees exactly one face in the window.
  final Map<String, _LabCollector?> _otherCollectors = {};
  final Map<String, List<FaceSignals>> _otherGaze = {};

  /// The other engines' calibrations of the current window, with zones.
  final Map<String, (CalibrationProfile, ZoneMap)> otherCalibrations = {};
  int? _calibrationStartUs;
  bool _calibrationRequested = false;
  ObservationEngine? engine;
  FatigueMonitor? _fatigue;
  FatigueSnapshot fatigue = FatigueSnapshot.empty;
  AttentionState attentionState = AttentionState.unknown;
  String? _sessionId;
  int _sessions = 0;

  /// Road gaze collected during the ТЗ calibration (engines with gaze).
  final List<FaceSignals> _calibrationGaze = [];

  /// How the attention pipeline identified the driver on the last frame
  /// (`same`, `restored`, `no_face`, `ambiguous`, `different`).
  String? driverDecision;

  /// Driver reference for [ZoneAttentionProvider.anchorDriver]: the last
  /// calibration frame, and when the driver was last seen (absolute clock).
  FaceSignals? _anchorFace;
  int? _driverSeenAbsUs;

  /// Engine numbers of the result being delivered (ARKit `raw`).
  (FaceResult, Map<String, Object?>)? _pendingRaw;

  /// Latest `device` line (ARKit source), for the screen.
  Map<String, Object?>? lastDevice;

  /// Zone layout of the current calibration (road + optional mirrors).
  ZoneMap? zones;
  ZoneCalibrationCollector? _mirrors;
  final List<(int, void Function())> _mirrorPlan = [];
  bool get calibratingMirrors => _mirrorPlan.isNotEmpty;

  /// Last results per engine id (primary first in [engineIds]).
  final Map<String, FaceResult> lastResults = {};
  final Map<String, FaceSignals?> lastSignals = {};
  final List<int> _primaryCompletions = [];
  int? lastLatencyUs;
  String? error;
  final List<LabNote> notes = [];

  String? recordingId;
  DateTime? recordingStartedAt;
  String subject = 'S1';

  /// Where the phone is mounted, for the `meta.mount` field: `front`,
  /// `vent_left` or `vent_right`, with the rough angle towards the driver
  /// (degrees) and distance to the face (cm) when known.
  String mountPosition = 'front';
  int? mountAngleDeg, mountDistanceCm;

  static const mountNames = {
    'front': 'Прямо',
    'vent_left': 'Решётка слева',
    'vent_right': 'Решётка справа',
  };

  void setMount({String? position, int? angleDeg, int? distanceCm}) {
    if (recording) return;
    if (position != null) mountPosition = position;
    mountAngleDeg = angleDeg ?? mountAngleDeg;
    mountDistanceCm = distanceCm ?? mountDistanceCm;
    _notify(force: true);
  }

  Map<String, Object?> get mount => {
    'position': mountPosition,
    'angleDeg': ?mountAngleDeg,
    'distanceCm': ?mountDistanceCm,
  };
  ScenarioRunner? scenario;
  Scenario? _pendingScenario;
  String? prompt;
  bool _open = false, _disposed = false;
  Timer? _timer;
  int _lastNotifyUs = 0, _lastDerivedUs = 0;
  Map<String, String>? _device;

  bool get recording => recorder.active;

  ZoneAttentionProvider? get zoneProvider {
    final a = attention;
    return a is ZoneAttentionProvider ? a : null;
  }

  /// Acceptance (ТЗ only) or lab extensions; null for another provider.
  AttentionSettings? get attentionSettings => zoneProvider?.settings;

  /// Detection profile (attention-method.md § 10): thresholds, T rule, eye
  /// view limits and attention flags. «ТЗ 2.2 (эталон)» or the tuned one;
  /// written to `meta.detectionProfile`.
  DetectionProfile profile = DetectionProfile.current;

  /// Switches the profile. The automata restart with the same calibration;
  /// the T rule and the eye view limit apply from the next calibration.
  void setProfile(DetectionProfile next) {
    if (recording || next.id == profile.id) return;
    profile = next;
    attention = ZoneAttentionProvider(settings: next.attention, zones: zones);
    _newSession();
    _note(
      next.isReference
          ? 'ТЗ 2.2 (эталон): числа и калибровка ТЗ — после новой калибровки'
          : 'Профиль ${next.id}: ${next.summary} — после новой калибровки',
    );
    _notify(force: true);
  }

  /// Switches the attention flags alone (experiments; the profile's
  /// thresholds stay). The automata restart with the same calibration,
  /// because the eye gate changes their input.
  void setAttentionSettings(AttentionSettings next) {
    if (recording || attentionSettings == null) return;
    attention = ZoneAttentionProvider(settings: next, zones: zones);
    _newSession();
    _note(
      next.isAcceptance
          ? 'Режим приёмки: только ТЗ (ракурс глаз до 18° — после новой калибровки)'
          : 'Режим Лаборатории: расширения включены, ракурс глаз до 45° '
                'для бокового крепления — после новой калибровки',
    );
  }

  bool get isOpen => _open;
  List<String> get engineIds =>
      source?.engines.map((e) => e.id).toList() ?? option.engineIds;
  String get primaryEngine => source?.engines.first.id ?? '';

  LabPhase get phase {
    if (source == null || !(source!.running)) return LabPhase.stopped;
    if (_collector != null || _calibrationRequested) {
      return LabPhase.calibrating;
    }
    return engine == null ? LabPhase.uncalibrated : LabPhase.observing;
  }

  double get calibrationProgress {
    final start = _calibrationStartUs;
    if (start == null) return 0;
    return ((nowUs - start) / 10000000).clamp(0, 1).toDouble();
  }

  /// Analyses per second of the primary engine over the last second.
  double get analysesPerSecond {
    final now = clockUs();
    return _primaryCompletions
        .where((t) => t > now - 1000000)
        .length
        .toDouble();
  }

  void _notify({bool force = false}) {
    if (_disposed) return;
    final now = clockUs();
    if (force || now - _lastNotifyUs >= 100000) {
      _lastNotifyUs = now;
      notifyListeners();
    }
  }

  void _note(String text, {bool important = false}) {
    notes.insert(0, LabNote(nowUs, text, important: important));
    if (notes.length > 100) notes.removeLast();
    server.broadcast({'type': 'lab', 'note': text});
    _notify(force: true);
  }

  /// Writes to the recording (when on) and to every connected page.
  void _emit(Map<String, Object?> line) {
    recorder.write(line);
    // The page does not use the raw engine numbers; keep the stream light.
    server.broadcast(
      line.containsKey('raw') ? ({...line}..remove('raw')) : line,
    );
  }

  List<Map<String, Object?>> _greeting() => [
    _metaLine(live: !recording),
    if (calibration != null)
      RecordingSchema.calibration(
        atUs: 0,
        profile: calibration!,
        zones: zones?.toJson(),
      ),
    {'type': 'lab', 'prompt': prompt ?? ''},
  ];

  Map<String, Object?> _metaLine({bool live = false}) => RecordingSchema.meta(
    recordingId: recordingId ?? '',
    app: appVersion,
    engines: engineIds,
    startedAt: recordingStartedAt ?? DateTime.now(),
    device: _device?['model'],
    os: _device?['os'],
    subject: subject,
    extra: {
      if (live) 'live': true,
      'attention': attention.id,
      if (attentionSettings != null)
        'attentionSettings': attentionSettings!.toJson(),
      'detectionProfile': profile.toJson(),
      'mount': mount,
      'algorithm': ObservationEngine.algorithmVersion,
      'settings': settings.toJson(),
    },
  );

  Future<void> open() async {
    if (_open) return;
    _open = true;
    error = null;
    baseUs = clockUs();
    _timer = Timer.periodic(const Duration(milliseconds: 50), (_) => _tick());
    unawaited(_loadDevice());
    if (startServer) {
      try {
        await server.start();
      } catch (e) {
        _note('Сервер для Mac не запустился: $e', important: true);
      }
    }
    await _safe(() => platform.keepAwake(true));
    await _startSource();
    _notify(force: true);
  }

  Future<void> _loadDevice() async {
    try {
      final info = await platform.call('device.info');
      _device = {
        if (info['model'] != null) 'model': '${info['model']}',
        if (info['os'] != null) 'os': '${info['os']}',
      };
    } catch (_) {
      _device = {'os': Platform.operatingSystemVersion};
    }
  }

  Future<void> _startSource() async {
    final created = option.create();
    source = created;
    lastResults.clear();
    lastSignals.clear();
    try {
      await created.start(
        nowUs: () => clockUs(),
        onResult: _onResult,
        onError: (Object e) {
          error = 'Источник кадров: $e';
          _notify(force: true);
        },
        onChanged: () => _notify(force: true),
      );
    } catch (e) {
      error = 'Камера недоступна: $e';
    }
    _notify(force: true);
  }

  Future<void> _stopSource() async {
    final old = source;
    source = null;
    if (old != null) await old.dispose();
  }

  /// Pauses the camera when the app leaves the foreground.
  Future<void> pause() async {
    if (!_open) return;
    _cancelCalibration();
    _cancelMirrors();
    await _stopSource();
    _notify(force: true);
  }

  Future<void> resume() async {
    if (!_open || source != null) return;
    await _startSource();
  }

  Future<void> selectEngine(LabEngineOption next) async {
    if (recording || next.id == option.id) return;
    option = next;
    calibration = null;
    otherCalibrations.clear();
    zones = null;
    zoneProvider?.zones = null;
    _cancelCalibration();
    _cancelMirrors();
    engine = null;
    attention.reset(null);
    await _stopSource();
    if (_open) await _startSource();
    _note('Движок: ${next.title}. Нужна новая калибровка.');
  }

  Future<void> close() async {
    if (!_open) return;
    _open = false;
    _timer?.cancel();
    await cancelScenario();
    await stopRecording();
    await _stopSource();
    await server.stop();
    await _safe(() => platform.keepAwake(false));
    await _safe(() => platform.call('speech.stop'));
  }

  // ---- frames ---------------------------------------------------------------

  DetectedFace? _driver(List<DetectedFace> faces) {
    if (faces.isEmpty) return null;
    final id = calibration?.trackingId ?? _collector?.trackingId;
    if (id != null) {
      for (final f in faces) {
        if (f.measurement.trackingId == id) return f;
      }
    }
    return faces.reduce(
      (a, b) =>
          a.bounds.width * a.bounds.height >= b.bounds.width * b.bounds.height
          ? a
          : b,
    );
  }

  FaceSignals? _signalsOf(DetectedFace? face, String engineId) {
    if (face == null) return null;
    final m = face.measurement;
    return face.signals ??
        FaceSignals(
          engineId: engineId,
          trackingId: m.trackingId,
          headYawLeft: m.yaw,
          headPitchDown: m.pitchDown,
          headRollRight: m.roll,
          eyeOpenLeft: m.leftEye,
          eyeOpenRight: m.rightEye,
        );
  }

  void _onResult(FaceResult result) {
    if (!_open || source == null) return;
    final captured = result.capturedUs - baseUs;
    final completed = result.completedUs - baseUs;
    if (captured < 0) return; // started before the time base moved
    final driver = _driver(result.faces);
    final signals = _signalsOf(driver, result.engineId);
    lastResults[result.engineId] = result;
    lastSignals[result.engineId] = signals;
    final pending = _pendingRaw;
    _pendingRaw = null;
    // Every face in the order the engine reported it (and the pipeline gets
    // it); the frame line keeps the chosen face in `signals`, the rest in
    // `others`, so a replay sees the same ambiguity (ФТ-02).
    final all = [
      for (final f in result.faces)
        identical(f, driver) ? signals! : _signalsOf(f, result.engineId)!,
    ];
    _emit({
      ...RecordingSchema.frame(
        engine: result.engineId,
        capturedUs: captured,
        completedUs: completed,
        faceCount: result.faces.length,
        signals: signals,
      ),
      if (result.faces.length > 1)
        'others': [
          for (var i = 0; i < all.length; i++)
            if (!identical(result.faces[i], driver)) all[i].toJson(),
        ],
      if (pending != null && identical(pending.$1, result)) 'raw': pending.$2,
    });
    if (result.engineId != primaryEngine) {
      if (_otherCollectors.containsKey(result.engineId)) {
        _collectOther(result, captured, all, signals);
      }
      _notify();
      return;
    }
    _primaryCompletions.add(result.completedUs);
    _primaryCompletions.removeWhere((t) => t < clockUs() - 2000000);
    lastLatencyUs = completed - captured;
    var measurements = result.faces.map((f) => f.measurement).toList();

    if (_calibrationRequested && _collector == null) {
      if (result.faces.length == 1 &&
          result.faces.single.measurement.trackingId != null) {
        _beginCollector(result.faces.single.measurement.trackingId!, captured);
      }
    }
    final collector = _collector;
    if (collector != null) {
      collector.add(captured, measurements, all);
      if (result.faces.length == 1 && signals != null) {
        _anchorFace = signals;
        _driverSeenAbsUs = result.capturedUs;
        if (signals.hasGaze) _calibrationGaze.add(signals);
      }
    }
    final single = result.faces.length == 1 ? signals : null;
    _mirrors?.add(captured, single);
    final previousDriver = driverDecision;
    final zoned = zoneProvider;
    attentionState = zoned != null
        ? zoned.updateFaces(all, captured)
        : attention.update(single, captured);
    driverDecision = attentionState.details['driver'] as String?;
    if (driverDecision == ContinuityDecision.same.code ||
        driverDecision == ContinuityDecision.restored.code) {
      _driverSeenAbsUs = result.capturedUs;
    }
    if (driverDecision == ContinuityDecision.restored.code &&
        previousDriver != driverDecision) {
      _note(
        'Водитель восстановлен по рамке лица (trackingId ${single?.trackingId})',
      );
    }
    if (collector == null && engine != null) {
      // In both modes the engine gets only the pipeline's measurements:
      // driver continuity restores the calibrated id after a loss, and the
      // lab-mode eye gate may withhold lowered lids from `eyes_closed`.
      if (zoned != null) measurements = zoned.lastMeasurements;
      _apply(
        engine!.process(
          sessionId: _sessionId!,
          capturedUs: captured,
          completedUs: completed,
          faces: measurements,
        ),
      );
      _feedFatigue(measurements, captured);
      zoned?.tzSignActive = tzSignActive(engine!.snapshot);
      zoned?.eyesEventActive = engine!.snapshot.eyes.activeEvent != null;
      _distraction(zoned?.lastFrame);
    }
    // 10 per second is enough for the page and keeps an hour-long file
    // small; the replay recomputes decisions from the frames anyway.
    if (completed - _lastDerivedUs >= 100000 || completed < _lastDerivedUs) {
      _lastDerivedUs = completed;
      _emitDerived(completed);
    }
    _notify();
  }

  void _feedFatigue(List<FaceMeasurement> measured, int atUs) {
    final monitor = _fatigue,
        profile = zoneProvider?.engineCalibration ?? calibration;
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

  void _apply(ObservationUpdate update) {
    for (final e in update.started) {
      _emit(RecordingSchema.event(change: 'started', event: e, atUs: nowUs));
      _note(
        e.type == EventType.eyesClosed
            ? 'Событие: глаза закрыты'
            : 'Событие: голова опущена',
        important: true,
      );
    }
    for (final e in update.ended) {
      _emit(RecordingSchema.event(change: 'ended', event: e, atUs: nowUs));
    }
    for (final e in update.acknowledged) {
      _emit(
        RecordingSchema.event(change: 'acknowledged', event: e, atUs: nowUs),
      );
    }
  }

  void _distraction(AttentionFrame? frame) {
    final started = frame?.distractionStarted, ended = frame?.distractionEnded;
    if (started != null) {
      _emit({
        'type': 'event',
        'change': 'started',
        'atUs': nowUs,
        'event': started.toJson(),
      });
      _note('Отвлечение (${started.zone.code})', important: true);
    }
    if (ended != null) {
      _emit({
        'type': 'event',
        'change': 'ended',
        'atUs': nowUs,
        'event': ended.toJson(),
      });
    }
  }

  void _emitDerived(int atUs) {
    final snapshot = engine?.snapshot;
    _emit(
      RecordingSchema.derived(
        atUs: atUs,
        zone: attentionState.zone,
        eyes: snapshot?.eyes,
        head: snapshot?.head,
        fatigue: engine == null ? null : fatigue,
        extra: {
          'status': statusLine,
          'stats': {
            'aps': analysesPerSecond,
            'latencyMs': (lastLatencyUs ?? 0) / 1000,
          },
          if (attentionState.details.isNotEmpty)
            'attention': attentionState.details,
          'driver': ?driverDecision,
          if (scenario != null && scenario!.openSteps.isNotEmpty)
            'step': scenario!.openSteps.first,
        },
      ),
    );
  }

  // ---- calibration --------------------------------------------------------

  /// Starts the ТЗ calibration (10 s) as soon as exactly one face is seen.
  void calibrate() {
    if (source == null) return;
    _cancelCalibration();
    _cancelMirrors();
    _calibrationRequested = true;
    engine = null;
    _say('Калибровка. Смотрите на дорогу десять секунд');
    _notify(force: true);
  }

  void _beginCollector(int trackingId, int atUs) {
    _calibrationStartUs = atUs;
    _calibrationGaze.clear();
    _anchorFace = null;
    _collector = _newCollector(source!.engines.first, trackingId, atUs);
    _otherCollectors.clear();
    _otherGaze.clear();
    for (final other in source!.engines.skip(1)) {
      _otherCollectors[other.id] = null;
      _otherGaze[other.id] = [];
    }
  }

  _LabCollector _newCollector(
    DetectorCapabilities engine,
    int trackingId,
    int atUs,
  ) {
    final detector = calibrationDetector(engine);
    // Side mount (lab mode): angles relative to the road pose, the eyes
    // only within the engine's range (attention-method.md § 9).
    return attentionSettings?.mountRelative ?? false
        ? _MountCollector(
            MountCalibrationCollector(
              trackingId: trackingId,
              detector: detector,
              hiddenEyes: settings.hiddenEyes,
              startedUs: atUs,
            ),
          )
        : _TzCollector(
            CalibrationCollector(
              trackingId: trackingId,
              detector: detector,
              hiddenEyes: settings.hiddenEyes,
              startedUs: atUs,
            ),
          );
  }

  /// A frame of another engine inside the calibration window: its collector
  /// starts at the primary window's start, on that engine's own tracking id.
  void _collectOther(
    FaceResult result,
    int captured,
    List<FaceSignals> all,
    FaceSignals? signals,
  ) {
    final start = _calibrationStartUs;
    if (start == null || captured < start) return;
    var collector = _otherCollectors[result.engineId];
    if (collector == null) {
      final id = result.faces.length == 1
          ? result.faces.single.measurement.trackingId
          : null;
      final caps = source!.engines
          .where((e) => e.id == result.engineId)
          .firstOrNull;
      if (id == null || caps == null) return;
      collector = _otherCollectors[result.engineId] = _newCollector(
        caps,
        id,
        start,
      );
    }
    collector.add(
      captured,
      result.faces.map((f) => f.measurement).toList(),
      all,
    );
    if (result.faces.length == 1 && signals != null && signals.hasGaze) {
      _otherGaze[result.engineId]!.add(signals);
    }
  }

  /// Zones of a calibration: the road gaze is the median gaze of the
  /// window, as the replay does.
  static ZoneMap _zonesOf(CalibrationProfile profile, List<FaceSignals> gaze) =>
      gaze.length < 10
      ? ZoneMap.fromCalibration(profile)
      : ZoneMap.fromCalibration(
          profile,
          roadGazeLeft: median(gaze.map((s) => s.gazeLeft!)),
          roadGazeDown: median(gaze.map((s) => s.gazeDown!)),
        );

  /// Measurement option «Замер: предел глаз 45°» (off by default): the eyes
  /// are evaluated up to 45° to the camera, to measure how far an engine's
  /// lids stay reliable on a side mount. Lab mode only; acceptance keeps the
  /// engine's own range (ML Kit 18°). The profile carries the range it was
  /// made with, so the observation engine and the replay use the same one.
  static const sideMountEyeYawLimit = 45.0;
  bool eyeLimit45 = false;

  void setEyeLimit45(bool value) {
    if (recording || value == eyeLimit45) return;
    eyeLimit45 = value;
    _note(
      value
          ? 'Замер: предел глаз 45° — после новой калибровки'
          : 'Предел глаз движка — после новой калибровки',
    );
    _notify(force: true);
  }

  DetectorCapabilities calibrationDetector(DetectorCapabilities base) {
    final settings = attentionSettings;
    final engine = profile.detector(base);
    if (!eyeLimit45 ||
        settings == null ||
        settings.isAcceptance ||
        engine.eyeYawLimit >= sideMountEyeYawLimit) {
      return engine;
    }
    return DetectorCapabilities(
      id: engine.id,
      version: engine.version,
      eyeYawLimit: sideMountEyeYawLimit,
    );
  }

  void _cancelCalibration() {
    _collector = null;
    _otherCollectors.clear();
    _otherGaze.clear();
    _calibrationRequested = false;
    _calibrationStartUs = null;
  }

  void _finishCalibration() {
    final collector = _collector!;
    final finishedUs = nowUs;
    final result = collector.finish(finishedUs);
    final gaze = List.of(_calibrationGaze);
    final others = Map.of(_otherCollectors);
    final otherGaze = Map.of(_otherGaze);
    _cancelCalibration();
    otherCalibrations.clear();
    final found = result.profile;
    if (found == null) {
      error = result.issues.join('\n');
      _say('Калибровка не удалась');
      _note('Калибровка не удалась: ${result.issues.join(' ')}');
      if (_pendingScenario != null) {
        _pendingScenario = null;
        _note('Сценарий отменён: нет калибровки', important: true);
      }
      return;
    }
    error = null;
    final profile = this.profile.calibrate(found);
    calibration = profile;
    final restriction = result.note;
    if (restriction != null) {
      _say('При этом креплении глаза не оцениваются');
      _note(restriction, important: true);
    }
    final map = _zonesOf(profile, gaze);
    zones = map;
    zoneProvider?.zones = map;
    _emit(
      RecordingSchema.calibration(
        atUs: nowUs,
        profile: profile,
        zones: map.toJson(),
        engine: others.isEmpty ? null : profile.detector.id,
      ),
    );
    for (final MapEntry(key: id, value: other) in others.entries) {
      final r = other?.finish(finishedUs);
      final found = r?.profile;
      final p = found == null ? null : this.profile.calibrate(found);
      if (p == null) {
        _note(
          'Калибровка $id не удалась: '
          '${r?.issues.join(' ') ?? 'нет одного лица в окне'}',
        );
        continue;
      }
      final m = _zonesOf(p, otherGaze[id] ?? const []);
      otherCalibrations[id] = (p, m);
      _emit(
        RecordingSchema.calibration(
          atUs: nowUs,
          profile: p,
          zones: m.toJson(),
          engine: id,
        ),
      );
    }
    _newSession();
    _say('Калибровка завершена');
    _note(
      'Калибровка: наклон ${profile.neutralPitch.toStringAsFixed(1)}°, '
      'поворот ${profile.neutralYaw.toStringAsFixed(1)}°, '
      'T ${profile.eyeThreshold?.toStringAsFixed(2) ?? '—'}',
    );
    final pending = _pendingScenario;
    if (pending != null) {
      _pendingScenario = null;
      _beginScenario(pending, delayUs: 2500000);
    }
  }

  /// Optional mirror step: about 2.5 s of gaze into each mirror on a voice
  /// prompt. The calibrated centres replace the default sectors.
  void calibrateMirrors() {
    final base = zones;
    if (calibration == null || base == null || calibratingMirrors) return;
    if (scenario != null || phase != LabPhase.observing) return;
    final collector = ZoneCalibrationCollector(base);
    _mirrors = collector;
    var t = nowUs + 500000;
    for (final (zone, name) in [
      (GazeZone.mirrorLeft, 'левое'),
      (GazeZone.mirrorRight, 'правое'),
      (GazeZone.mirrorRear, 'салонное'),
    ]) {
      _mirrorPlan
        ..add((
          t,
          () {
            _say('Смотрите в $name зеркало');
            _setPrompt('Смотрите в $name зеркало');
          },
        ))
        ..add((t + 1500000, () => collector.begin(zone, nowUs)))
        ..add((
          t + 4000000,
          () {
            final issue = collector.end(nowUs);
            if (issue != null) _note('Зеркало $name: $issue');
            _say('Дорога');
            _setPrompt('Дорога');
          },
        ));
      t += 6000000;
    }
    _mirrorPlan.add((t, () => _finishMirrors(collector)));
    _note('Калибровка зеркал');
    _notify(force: true);
  }

  void _finishMirrors(ZoneCalibrationCollector collector) {
    _mirrors = null;
    _setPrompt(null);
    final map = collector.finish();
    if (!map.mirrorsCalibrated || calibration == null) {
      _say('Зеркала не откалиброваны');
      _note('Зеркала не откалиброваны, остались стартовые секторы');
      return;
    }
    zones = map;
    zoneProvider?.zones = map;
    _emit(
      RecordingSchema.calibration(
        atUs: nowUs,
        profile: calibration!,
        zones: map.toJson(),
        engine: otherCalibrations.isEmpty ? null : calibration!.detector.id,
      ),
    );
    _newSession();
    _say('Зеркала откалиброваны');
    _note('Зеркала откалиброваны');
  }

  void _cancelMirrors() {
    if (_mirrorPlan.isEmpty && _mirrors == null) return;
    _mirrorPlan.clear();
    _mirrors = null;
    _setPrompt(null);
  }

  /// New ObservationEngine session on the current time base.
  void _newSession() {
    final profile = calibration;
    if (profile == null) return;
    _sessionId = 'lab-${++_sessions}';
    attention.reset(profile);
    // Side mount: the measurements carry road-frame angles, so the automata
    // get the road-frame profile (neutral 0) the pipeline made.
    final automata = zoneProvider?.engineCalibration ?? profile;
    final session = this.profile.session(
      settings,
      hiddenEyes: automata.hiddenEyes,
    );
    engine = ObservationEngine(
      sessionId: _sessionId!,
      calibration: automata,
      settings: session,
    );
    _fatigue = FatigueMonitor(
      eyeThreshold: profile.hiddenEyes ? null : profile.eyeThreshold,
      nodThreshold: session.pitchThreshold * .6,
      eyesEventUs: session.eyesClosedUs,
      headEventUs: session.headDownUs,
    );
    fatigue = FatigueSnapshot.empty;
    // Where the driver was last seen, so a loss right after the start of the
    // session is judged by geometry (ПЗ: the selected face keeps its profile).
    final anchor = _anchorFace, seen = _driverSeenAbsUs;
    if (anchor != null && seen != null) {
      zoneProvider?.anchorDriver(anchor, seen - baseUs);
    }
  }

  /// ARKit hands the engine numbers of a result just before the result
  /// itself; they go into its `frame` line as `raw`.
  void attachRaw(FaceResult result, Map<String, Object?> raw) =>
      _pendingRaw = (result, raw);

  /// A `device` line (ArkitStats.toJson) on the lab time base.
  void deviceLine(Map<String, Object?> line) {
    if (!_open) return;
    final at = line['atUs'];
    final rebased = {...line, if (at is int) 'atUs': at - baseUs};
    if (rebased['atUs'] is int && (rebased['atUs'] as int) < 0) return;
    lastDevice = rebased;
    _emit(rebased);
  }

  // ---- recording ----------------------------------------------------------

  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  Future<void> startRecording() async {
    if (recording || !_open) return;
    final started = DateTime.now();
    recordingId = _stamp(started);
    recordingStartedAt = started;
    // New time base: the recording starts at 0. A running calibration
    // restarts; the automata start a new session with the same profile.
    final wasCalibrating = _collector != null || _calibrationRequested;
    _cancelCalibration();
    _cancelMirrors();
    baseUs = clockUs();
    _primaryCompletions.clear();
    try {
      await recorder.start(recordingId!);
    } catch (e) {
      recordingId = null;
      _note('Запись не началась: $e', important: true);
      return;
    }
    _emit(_metaLine());
    if (calibration != null) {
      _emit(
        RecordingSchema.calibration(
          atUs: 0,
          profile: calibration!,
          zones: zones?.toJson(),
          engine: otherCalibrations.isEmpty ? null : calibration!.detector.id,
        ),
      );
      for (final MapEntry(key: id, value: (p, m))
          in otherCalibrations.entries) {
        _emit(
          RecordingSchema.calibration(
            atUs: 0,
            profile: p,
            zones: m.toJson(),
            engine: id,
          ),
        );
      }
      _newSession();
    }
    if (wasCalibrating) calibrate();
    _note('Запись ${LabRecorder.fileName(recordingId!)}');
  }

  Future<File?> stopRecording() async {
    if (!recording) return null;
    final lines = recorder.lines;
    final file = await recorder.stop();
    final id = recordingId;
    recordingId = null;
    recordingStartedAt = null;
    server.broadcast(_metaLine(live: true));
    if (id != null) _note('Запись сохранена: $lines строк');
    _notify(force: true);
    return file;
  }

  // ---- scenarios ----------------------------------------------------------

  Future<void> startScenario(Scenario next) async {
    if (!_open || source == null || scenario != null || calibratingMirrors) {
      return;
    }
    if (!recording) await startRecording();
    if (calibration == null) {
      _pendingScenario = next;
      calibrate();
      _note('Сценарий ${next.id} начнётся после калибровки');
      return;
    }
    _beginScenario(next, delayUs: 1000000);
  }

  void _beginScenario(Scenario next, {required int delayUs}) {
    scenario = ScenarioRunner(next, startUs: nowUs + delayUs);
    _note(
      'Сценарий ${next.id}: ${next.cues.where((c) => c.edge == 'start').length} шагов',
    );
    _notify(force: true);
  }

  Future<void> cancelScenario() async {
    _pendingScenario = null;
    final runner = scenario;
    if (runner == null) return;
    scenario = null;
    for (final step in runner.openSteps) {
      _emit({
        ...RecordingSchema.label(
          atUs: nowUs,
          scenario: runner.scenario.id,
          step: step,
          edge: 'end',
        ),
        'aborted': true,
      });
    }
    _setPrompt(null);
    await _safe(() => platform.call('speech.stop'));
    _note('Сценарий прерван', important: true);
  }

  void _setPrompt(String? text) {
    prompt = text;
    server.broadcast({'type': 'lab', 'prompt': text ?? ''});
  }

  void _say(String text) {
    unawaited(_safe(() => platform.call('speech.say', {'text': text})));
  }

  // ---- clock --------------------------------------------------------------

  @visibleForTesting
  void tick() => _tick();

  void _tick() {
    if (!_open || _disposed) return;
    final now = nowUs;
    if (_collector != null &&
        _calibrationStartUs != null &&
        now - _calibrationStartUs! >= 10000000) {
      _finishCalibration();
    }
    while (_mirrorPlan.isNotEmpty && _mirrorPlan.first.$1 <= now) {
      _mirrorPlan.removeAt(0).$2();
    }
    final current = engine;
    if (current != null) {
      _apply(current.tick(now));
      if (_fatigue != null) fatigue = _fatigue!.snapshot(now);
    }
    final runner = scenario;
    if (runner != null) {
      for (final cue in runner.due(now)) {
        if (cue.say != null) {
          _say(cue.say!);
          _setPrompt(cue.say);
        }
        if (cue.isLabel) {
          _emit(
            RecordingSchema.label(
              atUs: now,
              scenario: runner.scenario.id,
              step: cue.step!,
              edge: cue.edge!,
              rep: cue.rep,
            ),
          );
        }
      }
      if (runner.finished) {
        scenario = null;
        _setPrompt(null);
        _note('Сценарий ${runner.scenario.id} завершён', important: true);
        unawaited(
          Future<void>.delayed(
            const Duration(seconds: 1),
            () async => stopRecording(),
          ),
        );
      }
    }
    if (phase == LabPhase.calibrating) _notify();
  }

  // ---- presentation -------------------------------------------------------

  static const driverNames = {
    'same': 'тот же',
    'restored': 'восстановлен',
    'no_face': 'нет лица',
    'ambiguous': 'несколько лиц',
    'different': 'другое лицо',
  };

  static const zoneNames = {
    GazeZone.road: 'Дорога',
    GazeZone.mirrorLeft: 'Левое зеркало',
    GazeZone.mirrorRight: 'Правое зеркало',
    GazeZone.mirrorRear: 'Салонное зеркало',
    GazeZone.instruments: 'Приборы',
    GazeZone.console: 'Консоль',
    GazeZone.offCamera: 'Вне камеры',
    GazeZone.unknown: 'Зона не определена',
  };

  static String _seconds(int us) =>
      '${(us / 1000000).toStringAsFixed(1).replaceAll('.', ',')} с';

  /// The big status line: «Дорога», «Глаза закрыты 1,2 с» …
  String get statusLine {
    switch (phase) {
      case LabPhase.stopped:
        return 'Камера выключена';
      case LabPhase.calibrating:
        return _collector == null
            ? 'Калибровка: нужно одно лицо в кадре'
            : 'Калибровка: смотрите на дорогу · '
                  '${(10 - calibrationProgress * 10).ceil()} с';
      case LabPhase.uncalibrated:
      case LabPhase.observing:
        break;
    }
    final primary = lastResults[primaryEngine];
    if (primary == null) return 'Ожидание кадров';
    if (primary.faces.isEmpty) return 'Лицо не найдено';
    if (primary.faces.length > 1) return 'В кадре несколько лиц';
    final snap = engine?.snapshot;
    if (snap == null) return 'Нужна калибровка';
    for (final (channel, name) in [
      (snap.eyes, 'Глаза закрыты'),
      (snap.head, 'Голова опущена'),
    ]) {
      final started = channel.signStartedUs;
      if ((channel.phase == ChannelPhase.signPresent ||
              channel.phase == ChannelPhase.warning) &&
          started != null) {
        return '$name ${_seconds(nowUs - started)}';
      }
    }
    return zoneNames[attentionState.zone]!;
  }

  Future<void> _safe(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    unawaited(close());
    super.dispose();
  }
}

extension on Stopwatch {
  int elapsedMicrosecondsOf() => elapsedMicroseconds;
}

/// The lab's calibration window: the ТЗ collector or, on a side mount, the
/// mount collector (angles relative to the road pose).
sealed class _LabCollector {
  int get trackingId;
  void add(int capturedUs, List<FaceMeasurement> faces, List<FaceSignals> s);
  ({CalibrationProfile? profile, List<String> issues, String? note}) finish(
    int nowUs,
  );
}

class _TzCollector implements _LabCollector {
  _TzCollector(this.c);
  final CalibrationCollector c;
  @override
  int get trackingId => c.trackingId;
  @override
  void add(int capturedUs, List<FaceMeasurement> faces, List<FaceSignals> s) =>
      c.add(capturedUs: capturedUs, faces: faces);
  @override
  ({CalibrationProfile? profile, List<String> issues, String? note}) finish(
    int nowUs,
  ) {
    final r = c.finish(nowUs: nowUs);
    return (profile: r.profile, issues: r.issues, note: null);
  }
}

class _MountCollector implements _LabCollector {
  _MountCollector(this.c);
  final MountCalibrationCollector c;
  @override
  int get trackingId => c.trackingId;
  @override
  void add(int capturedUs, List<FaceMeasurement> faces, List<FaceSignals> s) =>
      c.add(capturedUs: capturedUs, faces: s);
  @override
  ({CalibrationProfile? profile, List<String> issues, String? note}) finish(
    int nowUs,
  ) {
    final r = c.finish(nowUs: nowUs);
    return (profile: r.profile, issues: r.issues, note: r.note);
  }
}
