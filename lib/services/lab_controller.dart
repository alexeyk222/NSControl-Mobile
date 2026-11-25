import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../logic/attention_zones.dart';
import '../logic/domain.dart';
import '../logic/driver_continuity.dart';
import '../logic/replay.dart' show channelSignActive, tzSignActive;
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
           attention ?? ZoneAttentionProvider(settings: AttentionSettings.lab),
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
  CalibrationCollector? _collector;
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

  /// Switches the attention mode. The automata restart with the same
  /// calibration, because the eye gate changes their input.
  void setAttentionSettings(AttentionSettings next) {
    if (recording || attentionSettings == null) return;
    attention = ZoneAttentionProvider(settings: next, zones: zones);
    _newSession();
    _note(
      next.isAcceptance
          ? 'Режим приёмки: только ТЗ'
          : 'Режим Лаборатории: расширения включены',
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
    server.broadcast(line);
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
    _emit(
      RecordingSchema.frame(
        engine: result.engineId,
        capturedUs: captured,
        completedUs: completed,
        faceCount: result.faces.length,
        signals: signals,
      ),
    );
    if (result.engineId != primaryEngine) {
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
      collector.add(capturedUs: captured, faces: measurements);
      if (result.faces.length == 1 && signals != null && signals.hasGaze) {
        _calibrationGaze.add(signals);
      }
    }
    // The provider takes one face for now: with several faces it sees none
    // and the engine gets them all directly (it suspends observation, ФТ-02).
    final single = result.faces.length == 1 ? signals : null;
    _mirrors?.add(captured, single);
    final previousDriver = driverDecision;
    attentionState = attention.update(single, captured);
    final zoned = zoneProvider;
    if (zoned != null && result.faces.length > 1) {
      driverDecision = ContinuityDecision.ambiguous.code;
    } else {
      driverDecision = attentionState.details['driver'] as String?;
    }
    if (driverDecision == ContinuityDecision.restored.code &&
        previousDriver != driverDecision) {
      _note(
        'Водитель восстановлен по рамке лица (trackingId ${single?.trackingId})',
      );
    }
    if (collector == null && engine != null) {
      // In both modes the engine gets the pipeline's measurements: driver
      // continuity restores the calibrated id after a loss, and the lab-mode
      // eye gate may withhold lowered lids from `eyes_closed`.
      if (zoned != null && result.faces.length <= 1) {
        final m = zoned.lastMeasurement;
        measurements = [?m];
      }
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
      zoned?.eyesSignActive = channelSignActive(engine!.snapshot.eyes);
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
    final monitor = _fatigue, profile = calibration;
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
    _collector = CalibrationCollector(
      trackingId: trackingId,
      detector: source!.engines.first,
      hiddenEyes: settings.hiddenEyes,
      startedUs: atUs,
    );
  }

  void _cancelCalibration() {
    _collector = null;
    _calibrationRequested = false;
    _calibrationStartUs = null;
  }

  void _finishCalibration() {
    final collector = _collector!;
    final result = collector.finish(nowUs: nowUs);
    final gaze = List.of(_calibrationGaze);
    _cancelCalibration();
    final profile = result.profile;
    if (profile == null) {
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
    calibration = profile;
    // Road gaze: median gaze of the calibration window, as the replay does.
    final map = gaze.length < 10
        ? ZoneMap.fromCalibration(profile)
        : ZoneMap.fromCalibration(
            profile,
            roadGazeLeft: median(gaze.map((s) => s.gazeLeft!)),
            roadGazeDown: median(gaze.map((s) => s.gazeDown!)),
          );
    zones = map;
    zoneProvider?.zones = map;
    _emit(
      RecordingSchema.calibration(
        atUs: nowUs,
        profile: profile,
        zones: map.toJson(),
      ),
    );
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
    engine = ObservationEngine(
      sessionId: _sessionId!,
      calibration: profile,
      settings: AlgorithmSettings.fromJson({
        ...settings.toJson(),
        'hiddenEyes': profile.hiddenEyes,
      }),
    );
    _fatigue = FatigueMonitor(
      eyeThreshold: profile.hiddenEyes ? null : profile.eyeThreshold,
      nodThreshold: settings.pitchThreshold * .6,
      eyesEventUs: settings.eyesClosedUs,
      headEventUs: settings.headDownUs,
    );
    fatigue = FatigueSnapshot.empty;
    attention.reset(profile);
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
        ),
      );
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
