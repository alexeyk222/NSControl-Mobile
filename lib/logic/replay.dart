import 'dart:convert';
import 'dart:math' as math;

import 'attention_zones.dart';
import 'calibration.dart';
import 'driver_continuity.dart';
import 'face.dart';
import 'fatigue.dart';
import 'mount.dart';
import 'observation.dart';
import 'settings.dart';
import 'signals.dart';

/// Replay of a JSONL recording (schema 1, docs/recognition-contract.md)
/// through the same logic as the app, and scoring against the scenario labels
/// by the ПМИ matching rule (ПМИ 7.3: one event to one episode of the same
/// type, thresholds within ±1 s, nearest wins, ties go to the earlier episode,
/// extra events for a matched episode are FP duplicates).

class RecordedFrame {
  const RecordedFrame({
    required this.engine,
    required this.capturedUs,
    required this.completedUs,
    required this.faceCount,
    this.signals,
    this.others = const [],
  });
  final String engine;
  final int capturedUs, completedUs, faceCount;

  /// The driver candidate (the face the app chose).
  final FaceSignals? signals;

  /// The other faces of the frame (optional `others` of the `frame` line).
  final List<FaceSignals> others;
}

class RecordedLabel {
  const RecordedLabel({
    required this.atUs,
    required this.step,
    required this.edge,
    this.scenario,
    this.condition,
    this.rep,
    this.aborted = false,
  });
  final int atUs;
  final String step, edge;
  final String? scenario, condition;

  /// Repetition number of the step within the scenario, when the lab sends it.
  final int? rep;

  /// `end` label written when the scenario was stopped inside the step.
  final bool aborted;
}

class RecordedCalibration {
  const RecordedCalibration({required this.atUs, this.profile, this.zones});
  final int atUs;
  final CalibrationProfile? profile;
  final Map<String, dynamic>? zones;
}

class Recording {
  Recording({
    required this.meta,
    required this.calibrations,
    required this.frames,
    required this.labels,
    required this.recordedEvents,
    required this.skippedLines,
  });

  final Map<String, dynamic> meta;
  final List<RecordedCalibration> calibrations;
  final List<RecordedFrame> frames;
  final List<RecordedLabel> labels;

  /// `event` lines the app wrote while recording, for comparison only.
  final List<Map<String, dynamic>> recordedEvents;

  /// Lines of unknown type or that could not be read.
  /// Lines that are not frames, events or skipped: decisions of the app
  /// (`derived`) and phone load (`device`, read by the engine comparison).
  final int skippedLines;

  static const unusedTypes = {'derived', 'device'};

  String get id => (meta['recordingId'] as String?) ?? 'без идентификатора';

  List<String> get engines {
    final seen = <String>{};
    return [
      for (final f in frames)
        if (seen.add(f.engine)) f.engine,
    ];
  }

  static Recording parse(String text) {
    Map<String, dynamic> meta = const {};
    final calibrations = <RecordedCalibration>[];
    final frames = <RecordedFrame>[];
    final labels = <RecordedLabel>[];
    final events = <Map<String, dynamic>>[];
    var skipped = 0;
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final Map<String, dynamic> json;
      try {
        json = jsonDecode(line) as Map<String, dynamic>;
      } catch (_) {
        skipped++;
        continue;
      }
      if (json['type'] == 'meta' && json['schema'] != 1) {
        throw FormatException(
          'Схема записи ${json['schema']} не поддерживается',
        );
      }
      try {
        switch (json['type']) {
          case 'meta':
            meta = json;
          case 'calibration':
            final profile = json['profile'] as Map?;
            calibrations.add(
              RecordedCalibration(
                atUs: json['atUs'] as int,
                profile: profile == null
                    ? null
                    : CalibrationProfile.fromJson(
                        Map<String, dynamic>.from(profile),
                      ),
                zones: (json['zones'] as Map?)?.cast<String, dynamic>(),
              ),
            );
          case 'frame':
            final signals = json['signals'] as Map?;
            final others = json['others'] as List?;
            frames.add(
              RecordedFrame(
                engine: json['engine'] as String,
                capturedUs: json['capturedUs'] as int,
                completedUs: json['completedUs'] as int,
                faceCount: (json['faceCount'] as int?) ?? 0,
                signals: signals == null
                    ? null
                    : FaceSignals.fromJson(Map<String, dynamic>.from(signals)),
                others: [
                  for (final o in others ?? const [])
                    FaceSignals.fromJson(Map<String, dynamic>.from(o as Map)),
                ],
              ),
            );
          case 'label':
            labels.add(
              RecordedLabel(
                atUs: json['atUs'] as int,
                step: json['step'] as String,
                edge: json['edge'] as String,
                scenario: json['scenario'] as String?,
                condition: json['condition'] as String?,
                rep: json['rep'] as int?,
                aborted: (json['aborted'] as bool?) ?? false,
              ),
            );
          case 'event':
            events.add(json);
          default:
            // Known lines the replay does not use (`derived`, `device`) are
            // not counted; unknown types are.
            if (!unusedTypes.contains(json['type'])) skipped++;
        }
      } catch (_) {
        // A line of a known type that does not match the schema.
        skipped++;
      }
    }
    frames.sort((a, b) => a.capturedUs.compareTo(b.capturedUs));
    labels.sort((a, b) => a.atUs.compareTo(b.atUs));
    return Recording(
      meta: meta,
      calibrations: calibrations,
      frames: frames,
      labels: labels,
      recordedEvents: events,
      skippedLines: skipped,
    );
  }
}

/// One labelled scenario step: from its `start` to its `end` label.
class Episode {
  const Episode({
    required this.step,
    required this.startUs,
    required this.endUs,
    this.condition,
    this.rep,
    this.aborted = false,
  });
  final String step;
  final int startUs, endUs;
  final String? condition;
  final int? rep;

  /// The scenario stopped inside this step: it is shown but not scored.
  final bool aborted;

  static List<Episode> fromLabels(List<RecordedLabel> labels) {
    final open = <String, RecordedLabel>{};
    final result = <Episode>[];
    String key(RecordedLabel l) => '${l.step}#${l.rep ?? ''}';
    for (final l in labels) {
      if (l.edge == 'start') {
        open[key(l)] = l;
      } else if (l.edge == 'end') {
        final start = open.remove(key(l));
        if (start != null && l.atUs >= start.atUs) {
          result.add(
            Episode(
              step: l.step,
              startUs: start.atUs,
              endUs: l.atUs,
              condition: start.condition ?? l.condition,
              rep: start.rep ?? l.rep,
              aborted: l.aborted,
            ),
          );
        }
      }
    }
    result.sort((a, b) => a.startUs.compareTo(b.startUs));
    return result;
  }
}

/// Expected events per scenario step (contract table «Шаги сценария»).
/// Steps not listed here expect no event. `distraction` is expected only
/// when the extension is on.
abstract final class ScenarioExpectations {
  static const eyesClosed = 'eyes_closed';
  static const headPitchDown = 'head_pitch_down';
  static const distraction = DistractionEvent.code;

  static const Map<String, Set<String>> table = {
    'eyes_closed_2s': {eyesClosed},
    'eyes_closed_3s': {eyesClosed},
    'head_down_3s': {headPitchDown},
    // Extension step: looking at the console / phone for 4 s.
    'distraction_4s': {distraction},
  };

  /// Steps that only change the conditions of the main steps.
  static const conditions = {'glasses', 'dark'};

  /// The `start` label is the voice prompt and the reaction takes 0.3–1 s,
  /// so a 2 s closure may really last only 1.5–2 s. A miss there is shown
  /// as borderline, not counted as FN.
  static const borderline = {'eyes_closed_2s'};

  /// ТЗ events that are acceptable but not expected in a step: looking at a
  /// phone with the head down more than 20° is a real head_pitch_down.
  static const Map<String, Set<String>> allowed = {
    'distraction_4s': {headPitchDown},
  };

  /// Steps whose glance durations the report lists (mirror limit, ПМИ).
  static bool glanceStep(String step) =>
      step.startsWith('mirror_') ||
      step.startsWith('blind_spot_') ||
      step == 'intersection_scan';

  static Set<String> expected(String step, AttentionSettings settings) {
    final types = table[step] ?? const <String>{};
    return settings.distraction
        ? types
        : types.where((t) => t != distraction).toSet();
  }
}

/// An event produced by the replay, ТЗ or extension.
class ReplayEvent {
  const ReplayEvent({
    required this.type,
    required this.signStartedUs,
    required this.thresholdUs,
    required this.alertRequestedUs,
    this.endedUs,
    this.detail,
  });
  final String type;
  final int signStartedUs, thresholdUs, alertRequestedUs;
  final int? endedUs;
  final String? detail;
}

class ReplayOptions {
  const ReplayOptions({
    required this.engine,
    this.attention = const AttentionSettings(),
    this.recalibrate = false,
    this.eyeYawLimit = 25,
  });
  final String engine;
  final AttentionSettings attention;

  /// Recompute the ТЗ calibration from the frames even when the recording
  /// carries a profile for this engine.
  final bool recalibrate;

  /// Eye yaw limit for an engine other than ML Kit when the profile has to be
  /// recomputed. ARKit's own limit is measured by the ARKit thread.
  final double eyeYawLimit;
}

/// Per-step outcome.
class EpisodeResult {
  EpisodeResult(this.episode, this.expected);
  final Episode episode;
  final Set<String> expected;
  final List<ReplayEvent> matched = [], duplicates = [], unexpected = [];

  /// Expected events found inside the step but outside the ±1 s tolerance
  /// (labels are prompts, not the moment the sign began). Neither TP nor FP;
  /// shown separately.
  final List<ReplayEvent> late = [];

  /// Events inside an aborted step: shown, not scored.
  final List<ReplayEvent> ignored = [];

  /// ТЗ events the step allows without expecting them: shown, not FP.
  final List<ReplayEvent> allowed = [];
  int frames = 0, eyesUsable = 0, headUsable = 0;

  /// Smallest openness of the more open eye over the step: a closure counts
  /// as deep for the eye gate only when it reaches [EyeGate.deepOpen].
  double? minOpen;

  /// Frames with both eyes below T, and those of them that were deep.
  int closedFrames = 0, deepFrames = 0;

  /// Durations (µs) of glances that started in the step, by zone code and
  /// under [offRoad] for continuous time off the road in any zone.
  final Map<String, List<int>> glances = {};
  static const offRoad = 'off_road';
  final Map<GazeZone, int> zones = {};
  final Map<EyeGateReason, int> gates = {};

  Set<String> get missed => episode.aborted
      ? const {}
      : expected
            .where(
              (t) =>
                  !matched.any((e) => e.type == t) &&
                  !late.any((e) => e.type == t),
            )
            .toSet();
  bool get borderline => ScenarioExpectations.borderline.contains(episode.step);
  bool get positive => expected.isNotEmpty;
  bool get passed => missed.isEmpty && duplicates.isEmpty && unexpected.isEmpty;
}

class TypeScore {
  /// [late]: found in the step but outside ±1 s of the label; [borderline]:
  /// missed in a borderline step. Both are reported apart from TP/FN.
  int tp = 0, fn = 0, fp = 0, duplicates = 0, late = 0, borderline = 0;
  double? get recall => tp + fn == 0 ? null : tp / (tp + fn);
  double? get precision => tp + fp == 0 ? null : tp / (tp + fp);
}

class ReplayResult {
  ReplayResult({
    required this.options,
    required this.profile,
    required this.calibrationSource,
    this.calibrationNote,
    required this.episodes,
    required this.events,
    required this.outsideSteps,
    required this.scores,
    required this.frames,
    required this.ambiguousFrames,
    required this.rejectedFrames,
    required this.fatigue,
    required this.observedUs,
    this.restoredFrames = 0,
    this.pausedAtUs,
  });

  /// Frames whose face got the calibrated id back after a loss (ФТ-02/03).
  final int restoredFrames;

  /// When the engine suspended observation for a new calibration (another
  /// face, two faces or a long loss), null when it never did.
  final int? pausedAtUs;
  final ReplayOptions options;
  final CalibrationProfile profile;
  final String calibrationSource;

  /// A restriction of the calibration (side mount: eyes not evaluated).
  final String? calibrationNote;
  final List<EpisodeResult> episodes;
  final List<ReplayEvent> events;

  /// Events whose threshold falls outside every labelled step.
  final List<ReplayEvent> outsideSteps;
  final Map<String, TypeScore> scores;
  final int frames, ambiguousFrames, rejectedFrames, observedUs;
  final FatigueSnapshot fatigue;

  int get falseAlarms => scores.entries
      .where((e) => e.key != DistractionEvent.code)
      .fold(0, (sum, e) => sum + e.value.fp);
  int get missed => scores.values.fold(0, (sum, s) => sum + s.fn);
  int get borderline => scores.values.fold(0, (sum, s) => sum + s.borderline);
  int get late => scores.values.fold(0, (sum, s) => sum + s.late);
}

class ReplayRunner {
  ReplayRunner(this.recording);
  final Recording recording;
  static const matchToleranceUs = 1000000;
  static const calibrationUs = 10000000;

  ReplayResult run(ReplayOptions options) {
    final frames = recording.frames
        .where((f) => f.engine == options.engine)
        .toList();
    if (frames.isEmpty) {
      throw ArgumentError('В записи нет кадров движка ${options.engine}');
    }
    final (profile, source, calibrationEndUs, calibrationLine, note) =
        _calibration(frames, options);
    final zones = _zones(profile, calibrationLine, frames, calibrationEndUs);
    // The same entry point as the lab: reset, anchor, updateFaces with
    // every face of the frame, lastMeasurements into the automaton.
    final provider = ZoneAttentionProvider(
      settings: options.attention,
      zones: zones,
    )..reset(profile);
    final pipeline = provider.pipeline!;
    // Where the driver was at the end of calibration, as the app does it.
    for (final f in frames.reversed) {
      if (f.capturedUs > calibrationEndUs) continue;
      if (f.faceCount == 1 && f.signals != null && f.signals!.tracked) {
        provider.anchorDriver(f.signals!, f.capturedUs);
      }
      break;
    }
    final settings = AlgorithmSettings(hiddenEyes: profile.hiddenEyes);
    // Road-frame profile (neutral 0) with mountRelative, as in the lab.
    final engineProfile = pipeline.engineCalibration;
    final engine = ObservationEngine(
      sessionId: 'replay',
      calibration: engineProfile,
      settings: settings,
    );
    final fatigue = FatigueMonitor(
      eyeThreshold: profile.eyeThreshold,
      nodThreshold: settings.pitchThreshold * .6,
      eyesEventUs: settings.eyesClosedUs,
      headEventUs: settings.headDownUs,
    );
    final events = <ReplayEvent>[];
    final open = <String, int>{};
    final episodes = [
      for (final e in Episode.fromLabels(recording.labels))
        EpisodeResult(e, {
          // Eyes not evaluated (head-only calibration): no eyes_closed can
          // be expected; the report says so instead of counting misses.
          for (final t in ScenarioExpectations.expected(
            e.step,
            options.attention,
          ))
            if (!profile.hiddenEyes || t != ScenarioExpectations.eyesClosed) t,
        }),
    ];
    var ambiguous = 0, rejected = 0, observed = 0;
    var tzSign = false, eyesEvent = false, restored = 0;
    int? firstUs, lastUs, pausedAtUs;
    GazeZone? runZone;
    int? runStartUs, offStartUs;
    EpisodeResult? ownerOf(int atUs) {
      for (final r in episodes) {
        if (atUs >= r.episode.startUs && atUs <= r.episode.endUs) return r;
      }
      return null;
    }

    void glance(String key, int startUs, int endUs) {
      final r = ownerOf(startUs);
      if (r != null) (r.glances[key] ??= []).add(endUs - startUs);
    }

    for (final frame in frames) {
      if (frame.capturedUs <= calibrationEndUs) continue;
      firstUs ??= frame.capturedUs;
      lastUs = frame.capturedUs;
      observed++;
      final faces = <FaceSignals>[];
      if (frame.faceCount > 1) {
        ambiguous++;
        // With the other faces recorded, the pipeline and the automaton see
        // all of them and suspend observation as the app does (ФТ-02).
        // Older recordings carry only the driver candidate: such a frame is
        // replayed as a frame without the driver.
        if (frame.signals != null && frame.others.isNotEmpty) {
          faces.addAll([frame.signals!, ...frame.others]);
        }
      } else if (frame.faceCount == 1 && frame.signals != null) {
        faces.add(frame.signals!);
      }
      provider
        ..tzSignActive = tzSign
        ..eyesEventActive = eyesEvent
        ..updateFaces(faces, frame.capturedUs);
      final attention = provider.lastFrame!;
      if (attention.state.driver == ContinuityDecision.restored) restored++;
      final zone = attention.state.zone;
      if (zone != runZone) {
        if (runZone != null) {
          glance(runZone.code, runStartUs!, frame.capturedUs);
        }
        runZone = zone;
        runStartUs = frame.capturedUs;
      }
      // As the distraction monitor counts it: a sweep across the road (one
      // raw road frame) ends a continuous glance.
      final offRoad =
          zone != GazeZone.road &&
          zone != GazeZone.unknown &&
          pipeline.tracker.raw != GazeZone.road;
      if (offRoad) {
        offStartUs ??= frame.capturedUs;
      } else if (offStartUs != null) {
        glance(EpisodeResult.offRoad, offStartUs, frame.capturedUs);
        offStartUs = null;
      }
      final update = engine.process(
        sessionId: 'replay',
        capturedUs: frame.capturedUs,
        completedUs: frame.completedUs,
        faces: attention.measurements,
      );
      if (update.rejected) rejected++;
      for (final e in update.started) {
        open[e.id] = events.length;
        events.add(
          ReplayEvent(
            type: e.type.code,
            signStartedUs: e.signStartedUs,
            thresholdUs: e.thresholdUs,
            alertRequestedUs: e.alertRequestedUs,
          ),
        );
      }
      final d = attention.distractionStarted;
      if (d != null) {
        events.add(
          ReplayEvent(
            type: DistractionEvent.code,
            signStartedUs: d.signStartedUs,
            thresholdUs: d.thresholdUs,
            alertRequestedUs: frame.completedUs,
            detail: '${d.kind.code}, ${d.zone.code}',
          ),
        );
      }
      _feedFatigue(fatigue, attention, frame, engineProfile, settings);
      final snapshot = update.snapshot;
      tzSign = tzSignActive(snapshot);
      eyesEvent = snapshot.eyes.activeEvent != null;
      if (snapshot.requiresRecalibration) pausedAtUs ??= frame.capturedUs;
      for (final r in episodes) {
        if (frame.capturedUs < r.episode.startUs ||
            frame.capturedUs > r.episode.endUs) {
          continue;
        }
        r.frames++;
        final sig = faces.length == 1 ? faces.single : null;
        if (sig?.eyeOpenLeft != null && sig?.eyeOpenRight != null) {
          final open = sig!.eyeOpenLeft! > sig.eyeOpenRight!
              ? sig.eyeOpenLeft!
              : sig.eyeOpenRight!;
          if (r.minOpen == null || open < r.minOpen!) r.minOpen = open;
          final t = profile.eyeThreshold;
          if (t != null && open < t) {
            r.closedFrames++;
            if (open <= pipeline.eyeGate.deepOpen) r.deepFrames++;
          }
        }
        if (snapshot.eyes.available) r.eyesUsable++;
        if (snapshot.head.available) r.headUsable++;
        r.zones.update(attention.state.zone, (n) => n + 1, ifAbsent: () => 1);
        r.gates.update(
          attention.state.eyeGate,
          (n) => n + 1,
          ifAbsent: () => 1,
        );
      }
    }
    if (runZone != null && lastUs != null) {
      glance(runZone.code, runStartUs!, lastUs);
    }
    if (offStartUs != null && lastUs != null) {
      glance(EpisodeResult.offRoad, offStartUs, lastUs);
    }
    final outside = <ReplayEvent>[];
    final scores = _score(episodes, events, outside, settings, options);
    return ReplayResult(
      options: options,
      profile: profile,
      calibrationSource: source,
      calibrationNote: note,
      episodes: episodes,
      events: events,
      outsideSteps: outside,
      scores: scores,
      frames: observed,
      ambiguousFrames: ambiguous,
      rejectedFrames: rejected,
      fatigue: fatigue.snapshot(lastUs ?? 0),
      observedUs: (lastUs ?? 0) - (firstUs ?? 0),
      restoredFrames: restored,
      pausedAtUs: pausedAtUs,
    );
  }

  (CalibrationProfile, String, int, RecordedCalibration?, String?) _calibration(
    List<RecordedFrame> frames,
    ReplayOptions options,
  ) {
    final lines = recording.calibrations;
    // The calibration the scenario ran on: the last one before the first
    // label (a recalibration later in the recording does not move the start),
    // preferably of this engine.
    final scenarioUs = recording.labels.isEmpty
        ? null
        : recording.labels.first.atUs;
    RecordedCalibration? pick(bool Function(RecordedCalibration) ok) {
      RecordedCalibration? before, first;
      for (final c in lines) {
        if (!ok(c)) continue;
        first ??= c;
        if (scenarioUs == null || c.atUs <= scenarioUs) before = c;
      }
      return before ?? first;
    }

    final line =
        pick((c) => c.profile?.detector.id == options.engine) ??
        pick((c) => true);
    final profile = line?.profile;
    if (!options.recalibrate &&
        profile != null &&
        profile.detector.id == options.engine) {
      var used = profile;
      var source = 'строка calibration записи';
      // Side mount: a lab build before the mount calibration raised the ML
      // Kit eye limit to pass the calibration. The recorded neutral pose
      // stays; the eyes follow the ТЗ limit, as the mount calibration does.
      final mlKit = DetectorCapabilities.mlKit;
      if (options.attention.mountRelative &&
          profile.detector.id == mlKit.id &&
          profile.detector.eyeYawLimit != mlKit.eyeYawLimit) {
        final hidden =
            profile.hiddenEyes || profile.neutralYaw.abs() > mlKit.eyeYawLimit;
        used = CalibrationProfile(
          trackingId: profile.trackingId,
          detector: mlKit,
          hiddenEyes: hidden,
          neutralPitch: profile.neutralPitch,
          neutralYaw: profile.neutralYaw,
          neutralRoll: profile.neutralRoll,
          leftEyeMedian: hidden ? null : profile.leftEyeMedian,
          rightEyeMedian: hidden ? null : profile.rightEyeMedian,
          eyeThreshold: hidden ? null : profile.eyeThreshold,
        );
        source +=
            '; предел глаз ML Kit ${profile.detector.eyeYawLimit.round()}° '
            'заменён на ${mlKit.eyeYawLimit.round()}° по ТЗ';
      }
      String? note;
      if (options.attention.mountRelative &&
          used.hiddenEyes &&
          used.neutralYaw.abs() > used.detector.eyeYawLimit) {
        note = MountCalibrationCollector.eyesNote(
          used.neutralYaw,
          used.detector.eyeYawLimit,
        );
      }
      return (used, source, line!.atUs, line, note);
    }
    // Recompute from the frames of this engine: the 10 s before the recorded
    // calibration, or the first 10 s of the recording. When the recording
    // started already calibrated (the line at its very start), there are no
    // frames before the line: then the 10 s after it are used and the
    // observation starts after them.
    var endUs = line?.atUs ?? frames.first.capturedUs + calibrationUs;
    var source = 'пересчитана по кадрам записи';
    if (line != null &&
        frames.where((f) => f.capturedUs <= endUs).length < 10 &&
        frames.first.capturedUs >= endUs - calibrationUs ~/ 2) {
      endUs = line.atUs + calibrationUs;
      source = 'пересчитана по 10 с после строки calibration';
    }
    (CalibrationProfile?, List<String>, String?) attempt(int endUs) {
      final startUs = endUs - calibrationUs;
      final trackingId =
          frames
              .where((f) => f.capturedUs >= startUs && f.signals != null)
              .map((f) => f.signals!.trackingId)
              .firstWhere((id) => id != null, orElse: () => null) ??
          profile?.trackingId ??
          0;
      final detector = options.engine == DetectorCapabilities.mlKit.id
          ? DetectorCapabilities.mlKit
          : DetectorCapabilities(
              id: options.engine,
              version: 'replay',
              eyeYawLimit: options.eyeYawLimit,
            );
      if (options.attention.mountRelative) {
        // Side mount: the lab calibrates with MountCalibrationCollector.
        final collector = MountCalibrationCollector(
          trackingId: trackingId,
          detector: detector,
          hiddenEyes: false,
          startedUs: math.max(0, startUs),
        );
        for (final f in frames) {
          if (f.capturedUs < startUs || f.capturedUs > endUs) continue;
          final s = f.signals;
          collector.add(
            capturedUs: f.capturedUs,
            faces: [
              if (f.faceCount >= 1 && s != null)
                s.trackingId == null ? _withTrackingId(s, trackingId) : s,
              if (f.faceCount > 1) ...f.others,
            ],
          );
        }
        final result = collector.finish(nowUs: endUs);
        return (result.profile, result.issues, result.note);
      }
      final collector = CalibrationCollector(
        trackingId: trackingId,
        detector: detector,
        hiddenEyes: profile?.hiddenEyes ?? false,
        startedUs: math.max(0, startUs),
      );
      for (final f in frames) {
        if (f.capturedUs < startUs || f.capturedUs > endUs) continue;
        final faces = <FaceMeasurement>[];
        if (f.faceCount == 1 && f.signals != null && f.signals!.tracked) {
          final m = f.signals!.toMeasurement();
          faces.add(
            FaceMeasurement(
              trackingId: m.trackingId ?? trackingId,
              leftEye: m.leftEye,
              rightEye: m.rightEye,
              pitchDown: m.pitchDown,
              yaw: m.yaw,
              roll: m.roll,
            ),
          );
        } else if (f.faceCount > 1) {
          faces.addAll(const [FaceMeasurement(), FaceMeasurement()]);
        }
        collector.add(capturedUs: f.capturedUs, faces: faces);
      }
      final result = collector.finish(nowUs: endUs);
      return (result.profile, result.issues, null);
    }

    var (calibrated, issues, note) = attempt(endUs);
    if (calibrated == null && line == null) {
      // No calibration line (a trial recording): the first stable 10 s
      // window, sliding by 1 s.
      final lastUs = frames.last.capturedUs;
      for (var end = endUs + 1000000; end <= lastUs; end += 1000000) {
        final (p, _, n) = attempt(end);
        if (p != null) {
          (calibrated, note, endUs) = (p, n, end);
          source =
              'пересчитана по первым устойчивым 10 с '
              '(${((end - calibrationUs - frames.first.capturedUs) / 1e6).toStringAsFixed(0)}–'
              '${((end - frames.first.capturedUs) / 1e6).toStringAsFixed(0)} с записи)';
          break;
        }
      }
    }
    if (calibrated == null) {
      throw StateError(
        'Калибровка по кадрам ${options.engine} не удалась: ${issues.join(' ')}',
      );
    }
    return (calibrated, source, endUs, line, note);
  }

  static FaceSignals _withTrackingId(FaceSignals s, int id) =>
      FaceSignals.fromJson({...s.toJson(), 'trackingId': id});

  ZoneMap _zones(
    CalibrationProfile profile,
    RecordedCalibration? line,
    List<RecordedFrame> frames,
    int calibrationEndUs,
  ) {
    if (line?.zones != null) return ZoneMap.fromJson(line!.zones!);
    // Road gaze centre: median gaze during the ТЗ calibration window.
    final gaze = frames
        .where(
          (f) =>
              f.capturedUs <= calibrationEndUs &&
              f.capturedUs >= calibrationEndUs - calibrationUs &&
              f.signals != null &&
              f.signals!.hasGaze,
        )
        .map((f) => f.signals!)
        .toList();
    if (gaze.length < 10) return ZoneMap.fromCalibration(profile);
    return ZoneMap.fromCalibration(
      profile,
      roadGazeLeft: median(gaze.map((s) => s.gazeLeft!)),
      roadGazeDown: median(gaze.map((s) => s.gazeDown!)),
    );
  }

  void _feedFatigue(
    FatigueMonitor fatigue,
    AttentionFrame attention,
    RecordedFrame frame,
    CalibrationProfile profile,
    AlgorithmSettings settings,
  ) {
    final m = attention.measurements.length == 1
        ? attention.measurements.single
        : null;
    if (m != null &&
        m.hasEyes &&
        FaceMeasurement.angle(m.yaw) &&
        m.yaw!.abs() <= profile.detector.eyeYawLimit) {
      fatigue.addEyes(frame.capturedUs, m.leftEye!, m.rightEye!);
    } else {
      fatigue.eyesUnavailable();
    }
    if (m != null &&
        m.hasHeadAngles &&
        (m.yaw! - profile.neutralYaw).abs() <= settings.headYawLimit) {
      fatigue.addHead(frame.capturedUs, m.pitchDown! - profile.neutralPitch);
    } else {
      fatigue.headUnavailable();
    }
    final jaw = frame.signals?.blendshape(Blendshape.jawOpen);
    if (jaw != null) {
      fatigue.addMouth(frame.capturedUs, jaw);
    } else {
      fatigue.mouthUnavailable();
    }
  }

  Map<String, TypeScore> _score(
    List<EpisodeResult> episodes,
    List<ReplayEvent> events,
    List<ReplayEvent> outside,
    AlgorithmSettings settings,
    ReplayOptions options,
  ) {
    int signUs(String type) => switch (type) {
      ScenarioExpectations.eyesClosed => settings.eyesClosedUs,
      ScenarioExpectations.headPitchDown => settings.headDownUs,
      _ => DistractionMonitor().longUs,
    };
    final scores = <String, TypeScore>{
      ScenarioExpectations.eyesClosed: TypeScore(),
      ScenarioExpectations.headPitchDown: TypeScore(),
      if (options.attention.distraction) DistractionEvent.code: TypeScore(),
    };
    final sorted = [...events]
      ..sort((a, b) => a.thresholdUs.compareTo(b.thresholdUs));
    final matched = <EpisodeResult, Set<String>>{};
    for (final event in sorted) {
      // ПМИ 7.3: the episode's threshold moment is its labelled start plus
      // the duration of the sign; nearest within ±1 s, ties to the earlier.
      EpisodeResult? best;
      var bestDiff = matchToleranceUs + 1;
      for (final r in episodes) {
        if (r.episode.aborted || !r.expected.contains(event.type)) continue;
        if (matched[r]?.contains(event.type) ?? false) continue;
        final diff =
            (event.thresholdUs - (r.episode.startUs + signUs(event.type)))
                .abs();
        if (diff < bestDiff) {
          best = r;
          bestDiff = diff;
        }
      }
      if (best != null) {
        best.matched.add(event);
        (matched[best] ??= {}).add(event.type);
        continue;
      }
      final owner = _owner(episodes, event);
      if (owner == null) {
        outside.add(event);
      } else if (owner.episode.aborted) {
        owner.ignored.add(event);
      } else if (ScenarioExpectations.allowed[owner.episode.step]?.contains(
            event.type,
          ) ??
          false) {
        owner.allowed.add(event);
      } else if (owner.expected.contains(event.type)) {
        if ((matched[owner]?.contains(event.type) ?? false) ||
            owner.late.any((e) => e.type == event.type)) {
          owner.duplicates.add(event);
        } else {
          owner.late.add(event);
          (matched[owner] ??= {}).add(event.type);
        }
      } else {
        owner.unexpected.add(event);
      }
    }
    for (final r in episodes) {
      for (final e in r.matched) {
        scores[e.type]?.tp++;
      }
      for (final e in r.late) {
        scores[e.type]?.late++;
      }
      for (final t in r.missed) {
        if (r.borderline) {
          scores[t]?.borderline++;
        } else {
          scores[t]?.fn++;
        }
      }
      for (final e in [...r.duplicates, ...r.unexpected]) {
        final s = scores[e.type] ??= TypeScore();
        s.fp++;
        if (r.duplicates.contains(e)) s.duplicates++;
      }
    }
    for (final e in outside) {
      (scores[e.type] ??= TypeScore()).fp++;
    }
    return scores;
  }

  /// The step an event belongs to: its threshold inside the step, or up to
  /// 1 s after the step ended (the sign may still be held).
  EpisodeResult? _owner(List<EpisodeResult> episodes, ReplayEvent event) {
    EpisodeResult? owner;
    for (final r in episodes) {
      if (event.thresholdUs >= r.episode.startUs &&
          event.thresholdUs <= r.episode.endUs + matchToleranceUs) {
        owner = r;
      }
    }
    return owner;
  }
}

/// True while either ТЗ channel has a sign or an active event.
bool tzSignActive(ObservationSnapshot s) =>
    channelSignActive(s.eyes) || channelSignActive(s.head);

/// True while the channel has a sign or an active event.
bool channelSignActive(ChannelSnapshot c) =>
    c.phase == ChannelPhase.signPresent ||
    c.phase == ChannelPhase.warning ||
    c.phase == ChannelPhase.recovering;

/// Markdown report in Russian for one or more replay runs of one recording.
String replayReport(Recording recording, List<ReplayResult> results) {
  final b = StringBuffer();
  final meta = recording.meta;
  b.writeln('# Прогон записи ${recording.id}');
  b.writeln();
  b.writeln(
    '- Устройство: ${meta['device'] ?? '—'}, ${meta['os'] ?? '—'}; '
    'приложение ${meta['app'] ?? '—'}; участник ${meta['subject'] ?? '—'}.',
  );
  final mount = meta['mount'];
  if (mount is Map) {
    final position = switch (mount['position']) {
      'vent_left' || 'left' => 'решётка слева от водителя',
      'vent_right' || 'right' => 'решётка справа от водителя',
      'front' || 'center' => 'перед водителем',
      final other => '$other',
    };
    final angle = mount['angleDeg'];
    final distance = mount['distanceCm'];
    b.writeln(
      '- Крепление: $position'
      '${angle is num ? ', повёрнут к водителю примерно на ${angle.round()}°' : ''}'
      '${distance is num ? ', до лица ${distance.round()} см' : ''}'
      '${mount['note'] is String && (mount['note'] as String).isNotEmpty ? '; ${mount['note']}' : ''}.',
    );
  }
  b.writeln(
    '- Движки в записи: ${recording.engines.join(', ')}; '
    'кадров ${recording.frames.length}, меток ${recording.labels.length}, '
    'событий приложения ${recording.recordedEvents.length}'
    '${recording.skippedLines > 0 ? ', пропущено строк ${recording.skippedLines}' : ''}.',
  );
  b.writeln(
    '- Сопоставление по ПМИ 7.3: событие и эпизод одного типа, порог ± 1 с, '
    'момент порога эпизода = начало шага по метке + длительность признака '
    '(1,5 с глаза, 2,0 с голова, 3,0 с отвлечение). Лишние события того же '
    'шага — FP-дубли. Метка start ставится в момент подсказки, поэтому '
    'событие внутри шага, но позже допуска, показано отдельно, а пропуск в '
    'шаге eyes_closed_2s — как пограничный. Эталон приёмки по ПМИ — внешняя '
    'запись, метки сценария его не заменяют.',
  );
  for (final r in results) {
    b.writeln();
    final mode = r.options.attention.isAcceptance
        ? 'приёмка (только ТЗ)'
        : 'расширения: ${[if (r.options.attention.gazeAwareEyes) 'глаза с учётом взгляда', if (r.options.attention.headOnlyLookDown) 'взгляд вниз по голове', if (r.options.attention.distraction) 'отвлечение', if (r.options.attention.mountRelative) 'углы относительно дороги'].join(', ')}';
    b.writeln('## ${r.options.engine}, $mode');
    b.writeln();
    b.writeln(
      '- Калибровка: ${r.calibrationSource}; T = '
      '${r.profile.eyeThreshold?.toStringAsFixed(2) ?? 'нет (глаза скрыты)'}, '
      'нейтраль: поворот ${_deg(r.profile.neutralYaw)}, '
      'наклон ${_deg(r.profile.neutralPitch)}'
      '${r.options.attention.mountRelative ? ' (ракурс камеры на дорогу; автоматы получают углы относительно этой позы)' : ''}; '
      'предел глаз ${_deg(r.profile.detector.eyeYawLimit)}.',
    );
    if (r.calibrationNote != null) b.writeln('- ${r.calibrationNote}');
    if (r.profile.hiddenEyes) {
      b.writeln(
        '- Глаза не оцениваются: шаги eyes_closed_* не ждут события и не '
        'считаются пропусками.',
      );
    }
    b.writeln(
      '- Кадров после калибровки ${r.frames} за ${_s(r.observedUs)} с'
      '${r.observedUs > 0 ? ' (${(r.frames * 1e6 / r.observedUs).toStringAsFixed(1)} в секунду)' : ''}'
      '; отброшено автоматом ${r.rejectedFrames}'
      '${r.ambiguousFrames > 0 ? ', несколько лиц в ${r.ambiguousFrames}' : ''}.',
    );
    b.writeln(
      '- Водитель после потери лица: восстановлен по геометрии в '
      '${r.restoredFrames} кадрах; '
      '${r.pausedAtUs == null ? 'наблюдение не приостанавливалось' : '**наблюдение приостановлено до новой калибровки на ${_s(r.pausedAtUs!)} с** (другое или второе лицо, долгая потеря)'}.',
    );
    b.writeln(
      '- **Итог: ложных тревог ТЗ ${r.falseAlarms}, пропусков ${r.missed}.**'
      '${r.late > 0 ? ' Найдено позже допуска от метки: ${r.late}.' : ''}'
      '${r.borderline > 0 ? ' Пограничных пропусков (eyes_closed_2s): ${r.borderline}.' : ''}',
    );
    b.writeln();
    b.writeln(
      '| Тип | TP | FN | FP | из них дубли | позже допуска | пограничные | R | P |',
    );
    b.writeln('|---|---|---|---|---|---|---|---|---|');
    for (final e in r.scores.entries) {
      final s = e.value;
      b.writeln(
        '| ${e.key} | ${s.tp} | ${s.fn} | ${s.fp} | ${s.duplicates} | '
        '${s.late} | ${s.borderline} | '
        '${_pct(s.recall)} | ${_pct(s.precision)} |',
      );
    }
    b.writeln();
    b.writeln(
      '| Шаг | Начало, с | Ожидалось | Итог | Задержка порога, с | '
      'Пригодно глаза / голова | Зоны | Глаза не учтены | Мин. открытость; доля глубоких кадров |',
    );
    b.writeln('|---|---|---|---|---|---|---|---|---|');
    for (final e in r.episodes) {
      final ep = e.episode;
      final verdict = <String>[
        if (e.matched.isNotEmpty)
          'найдено: ${e.matched.map((x) => x.type).join(', ')}',
        if (ep.aborted) 'шаг прерван, не оценивается',
        if (e.ignored.isNotEmpty)
          'события в прерванном шаге: ${e.ignored.map((x) => x.type).join(', ')}',
        if (e.missed.isNotEmpty)
          e.borderline
              ? 'пограничный пропуск: ${e.missed.join(', ')} (реальное закрытие могло быть короче 2 с)'
              : '**пропуск: ${e.missed.join(', ')}**',
        if (e.late.isNotEmpty)
          'найдено позже ± 1 с от метки: ${e.late.map((x) => x.type).join(', ')}',
        if (e.duplicates.isNotEmpty)
          '**дубль: ${e.duplicates.map((x) => x.type).join(', ')}**',
        if (e.allowed.isNotEmpty)
          'допустимо по ТЗ: ${e.allowed.map((x) => x.type).join(', ')}',
        if (e.unexpected.isNotEmpty)
          '**ложная тревога: ${e.unexpected.map((x) => x.detail == null ? x.type : '${x.type} (${x.detail})').join(', ')}**',
      ];
      final latency = e.matched
          .map((x) => _s(x.thresholdUs - ep.startUs))
          .join(', ');
      b.writeln(
        '| ${ep.step}${ep.rep == null ? '' : ' #${ep.rep}'}'
        '${ep.condition == null ? '' : ' (${ep.condition})'} '
        '| ${_s(ep.startUs)} '
        '| ${e.expected.isEmpty ? 'нет' : e.expected.join(', ')} '
        '| ${verdict.isEmpty ? 'нет событий ✓' : verdict.join('; ')} '
        '| ${latency.isEmpty ? '—' : latency} '
        '| ${_share(e.eyesUsable, e.frames)} / ${_share(e.headUsable, e.frames)} '
        '| ${_top(e.zones.map((k, v) => MapEntry(k.code, v)), e.frames)} '
        '| ${_top({for (final g in e.gates.entries)
          if (g.key != EyeGateReason.none) g.key.code: g.value}, e.frames)} '
        '| ${e.episode.step.startsWith('eyes_closed') && e.minOpen != null ? '${e.minOpen!.toStringAsFixed(2)}; глубоко ${_share(e.deepFrames, e.closedFrames)}' : '—'} |',
      );
    }
    final glanceSteps = <String, Map<String, List<int>>>{};
    for (final e in r.episodes) {
      if (!ScenarioExpectations.glanceStep(e.episode.step)) continue;
      final byZone = glanceSteps[e.episode.step] ??= {};
      for (final g in e.glances.entries) {
        (byZone[g.key] ??= []).addAll(g.value);
      }
    }
    if (glanceSteps.isNotEmpty) {
      b.writeln();
      b.writeln(
        'Длительность взглядов на шагах зеркал, слепой зоны и перекрёстка '
        '(по зоне после фильтра; off_road — непрерывно вне дороги в любых '
        'зонах, пролёт взгляда через дорогу его прерывает, как в счёте '
        'отвлечения). Порог долгого взгляда сейчас: зеркала '
        '${_s(DistractionMonitor().longFor(GazeZone.mirrorLeft))} с, '
        'остальное ${_s(DistractionMonitor().longUs)} с.',
      );
      b.writeln();
      b.writeln('| Шаг | Зона | Взглядов | Максимум, с | p95, с |');
      b.writeln('|---|---|---|---|---|');
      for (final step in glanceSteps.entries) {
        final zones = step.value.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key));
        for (final z in zones) {
          if (z.key == GazeZone.road.code) continue;
          final d = [...z.value]..sort();
          b.writeln(
            '| ${step.key} | ${z.key} | ${d.length} | ${_s2(d.last)} '
            '| ${_s2(d[((d.length * .95).ceil() - 1).clamp(0, d.length - 1)])} |',
          );
        }
      }
    }
    if (r.outsideSteps.isNotEmpty) {
      b.writeln();
      b.writeln('События вне размеченных шагов (считаются ложными):');
      for (final e in r.outsideSteps) {
        b.writeln(
          '- ${e.type}${e.detail == null ? '' : ' (${e.detail})'}, '
          'порог на ${_s(e.thresholdUs)} с',
        );
      }
    }
    final f = r.fatigue;
    b.writeln();
    b.writeln(
      'Усталость (только информация): уровень ${f.level.name}, '
      'долгих морганий ${f.longBlinks}, кивков ${f.nods}, зевков ${f.yawns} '
      '(за последние 5 мин записи).',
    );
  }
  return b.toString();
}

String _s(int us) => (us / 1e6).toStringAsFixed(1);
String _s2(int us) => (us / 1e6).toStringAsFixed(2);
String _deg(double v) => '${v.toStringAsFixed(1)}°';
String _pct(double? v) => v == null ? '—' : '${(v * 100).round()} %';
String _share(int n, int total) =>
    total == 0 ? '—' : '${(n * 100 / total).round()} %';
String _top(Map<String, int> counts, int total) {
  if (total == 0 || counts.isEmpty) return '—';
  final sorted = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return sorted
      .take(2)
      .map((e) => '${e.key} ${(e.value * 100 / total).round()} %')
      .join(', ');
}
