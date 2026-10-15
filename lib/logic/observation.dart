import 'calibration.dart';
import 'face.dart';
import 'settings.dart';

enum ObservationChannel { eyes, head }

enum EventType {
  eyesClosed('eyes_closed'),
  headPitchDown('head_pitch_down');

  const EventType(this.code);
  final String code;
}

enum EventEndReason {
  recovered('recovered'),
  dataLost('data_lost'),
  sideTurn('side_turn'),
  faceChanged('face_changed'),
  cameraStopped('camera_stopped'),
  observationStopped('observation_stopped'),
  tripEnded('trip_ended');

  const EventEndReason(this.code);
  final String code;
}

enum ChannelReason {
  none('none'),
  warmingUp('warming_up'),
  hiddenEyes('hidden_eyes'),
  noFace('no_face'),
  missingEyes('missing_eyes'),
  missingAngles('missing_angles'),
  eyePose('eye_pose'),
  sideTurn('side_turn'),
  ambiguousFace('ambiguous_face'),
  faceChanged('face_changed'),
  observationGap('observation_gap'),
  noRecentData('no_recent_data'),
  stopped('stopped');

  const ChannelReason(this.code);
  final String code;
}

enum ChannelPhase {
  unavailable,
  warmingUp,
  normal,
  signPresent,
  warning,
  recovering,
}

enum CameraStatus { warning, limited, observing, unavailable }

class ObservationEvent {
  const ObservationEvent({
    required this.id,
    required this.sessionId,
    required this.type,
    required this.signStartedUs,
    required this.thresholdUs,
    required this.alertRequestedUs,
    this.acknowledgedUs,
    this.endedUs,
    this.endReason,
  });
  final String id, sessionId;
  final EventType type;
  final int signStartedUs, thresholdUs, alertRequestedUs;
  final int? acknowledgedUs, endedUs;
  final EventEndReason? endReason;
  bool get active => endedUs == null;
  int? get durationUs => endedUs == null ? null : endedUs! - signStartedUs;
  ObservationEvent _copy({
    int? acknowledgedUs,
    int? endedUs,
    EventEndReason? endReason,
  }) => ObservationEvent(
    id: id,
    sessionId: sessionId,
    type: type,
    signStartedUs: signStartedUs,
    thresholdUs: thresholdUs,
    alertRequestedUs: alertRequestedUs,
    acknowledgedUs: acknowledgedUs ?? this.acknowledgedUs,
    endedUs: endedUs ?? this.endedUs,
    endReason: endReason ?? this.endReason,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'sessionId': sessionId,
    'type': type.code,
    'signStartedUs': signStartedUs,
    'thresholdUs': thresholdUs,
    'alertRequestedUs': alertRequestedUs,
    'acknowledgedUs': acknowledgedUs,
    'endedUs': endedUs,
    'endReason': endReason?.code,
  };
}

class ChannelSnapshot {
  const ChannelSnapshot({
    required this.channel,
    required this.available,
    required this.phase,
    required this.reason,
    this.signStartedUs,
    this.activeEvent,
    this.lastUsableUs,
  });
  final ObservationChannel channel;
  final bool available;
  final ChannelPhase phase;
  final ChannelReason reason;
  final int? signStartedUs, lastUsableUs;
  final ObservationEvent? activeEvent;
  Map<String, Object?> toJson() => {
    'channel': channel.name,
    'available': available,
    'phase': phase.name,
    'reason': reason.code,
    'signStartedUs': signStartedUs,
    'lastUsableUs': lastUsableUs,
    'activeEvent': activeEvent?.toJson(),
  };
}

class ObservationSnapshot {
  ObservationSnapshot({
    required this.eyes,
    required this.head,
    required this.requiresRecalibration,
    required this.stopped,
  });
  final ChannelSnapshot eyes, head;
  final bool requiresRecalibration, stopped;
  List<ObservationEvent> get activeEvents => List.unmodifiable([
    if (eyes.activeEvent != null) eyes.activeEvent!,
    if (head.activeEvent != null) head.activeEvent!,
  ]);
  bool get hasUnacknowledgedAlert =>
      activeEvents.any((event) => event.acknowledgedUs == null);
  CameraStatus get cameraStatus {
    if (activeEvents.isNotEmpty) return CameraStatus.warning;
    if (eyes.available && head.available) return CameraStatus.observing;
    if (eyes.available || head.available) return CameraStatus.limited;
    return CameraStatus.unavailable;
  }
}

class ChannelTransition {
  const ChannelTransition({
    required this.channel,
    required this.atUs,
    required this.fromPhase,
    required this.toPhase,
    required this.reason,
    required this.available,
  });
  final ObservationChannel channel;
  final int atUs;
  final ChannelPhase fromPhase, toPhase;
  final ChannelReason reason;
  final bool available;
  Map<String, Object?> toJson() => {
    'channel': channel.name,
    'atUs': atUs,
    'fromPhase': fromPhase.name,
    'toPhase': toPhase.name,
    'reason': reason.code,
    'available': available,
  };
}

class ObservationUpdate {
  ObservationUpdate({
    required this.snapshot,
    Iterable<ObservationEvent> started = const [],
    Iterable<ObservationEvent> ended = const [],
    Iterable<ObservationEvent> acknowledged = const [],
    Iterable<ChannelTransition> transitions = const [],
    this.rejected = false,
  }) : started = List.unmodifiable(started),
       ended = List.unmodifiable(ended),
       acknowledged = List.unmodifiable(acknowledged),
       transitions = List.unmodifiable(transitions);
  final ObservationSnapshot snapshot;
  final List<ObservationEvent> started, ended, acknowledged;
  final List<ChannelTransition> transitions;
  final bool rejected;
}

class _Channel {
  _Channel(this.channel);
  final ObservationChannel channel;
  final List<double> first = [], second = [];
  bool available = false;
  ChannelPhase phase = ChannelPhase.unavailable;
  ChannelReason reason = ChannelReason.warmingUp;
  int? lastUsableUs, signStartedUs, recoveryStartedUs;
  ObservationEvent? event;
  ChannelSnapshot get snapshot => ChannelSnapshot(
    channel: channel,
    available: available,
    phase: phase,
    reason: reason,
    signStartedUs: signStartedUs,
    activeEvent: event,
    lastUsableUs: lastUsableUs,
  );
}

/// Independent deterministic state machines, driven only by monotonic time.
class ObservationEngine {
  ObservationEngine({
    required this.sessionId,
    required this.calibration,
    AlgorithmSettings? settings,
  }) : settings =
           settings ?? AlgorithmSettings(hiddenEyes: calibration.hiddenEyes) {
    if (sessionId.isEmpty ||
        this.settings.hiddenEyes != calibration.hiddenEyes) {
      throw ArgumentError(
        'Сеанс и режим калибровки должны соответствовать настройкам',
      );
    }
    if (calibration.hiddenEyes) _eyes.reason = ChannelReason.hiddenEyes;
  }
  static const algorithmVersion = '1.0.0';
  static const maximumGapUs = 300000;
  final String sessionId;
  final CalibrationProfile calibration;
  final AlgorithmSettings settings;
  final _eyes = _Channel(ObservationChannel.eyes),
      _head = _Channel(ObservationChannel.head);
  bool _stopped = false, _requiresRecalibration = false;
  int _now = 0, _sequence = 0;
  int? _lastCaptured;
  ObservationSnapshot get snapshot => ObservationSnapshot(
    eyes: _eyes.snapshot,
    head: _head.snapshot,
    requiresRecalibration: _requiresRecalibration,
    stopped: _stopped,
  );

  ObservationUpdate process({
    required String sessionId,
    required int capturedUs,
    required int completedUs,
    required List<FaceMeasurement> faces,
  }) {
    if (_stopped ||
        sessionId != this.sessionId ||
        capturedUs < 0 ||
        completedUs < capturedUs ||
        completedUs < _now ||
        (_lastCaptured != null && capturedUs <= _lastCaptured!)) {
      return ObservationUpdate(snapshot: snapshot, rejected: true);
    }
    final before = snapshot;
    final started = <ObservationEvent>[], ended = <ObservationEvent>[];
    _now = completedUs;
    _lastCaptured = capturedUs;
    if (completedUs - capturedUs > maximumGapUs) {
      _gaps(completedUs, ended);
      return _update(before, completedUs, ended: ended, rejected: true);
    }
    _gaps(capturedUs, ended);
    if (_requiresRecalibration) {
      return _update(before, completedUs, ended: ended);
    }
    if (faces.length > 1 ||
        (faces.length == 1 &&
            faces.single.trackingId != calibration.trackingId)) {
      _requiresRecalibration = true;
      final reason = faces.length > 1
          ? ChannelReason.ambiguousFace
          : ChannelReason.faceChanged;
      for (final c in [_eyes, _head]) {
        _invalidate(c, reason, capturedUs, ended, EventEndReason.faceChanged);
      }
    } else if (faces.isEmpty) {
      _invalidate(_head, ChannelReason.noFace, capturedUs, ended);
      if (!settings.hiddenEyes) {
        _invalidate(_eyes, ChannelReason.noFace, capturedUs, ended);
      }
    } else {
      final face = faces.single;
      if (!settings.hiddenEyes) {
        if (!face.hasEyes) {
          _invalidate(_eyes, ChannelReason.missingEyes, capturedUs, ended);
        } else if (!FaceMeasurement.angle(face.yaw)) {
          _invalidate(_eyes, ChannelReason.missingAngles, capturedUs, ended);
        } else if (face.yaw!.abs() > calibration.detector.eyeYawLimit) {
          _invalidate(_eyes, ChannelReason.eyePose, capturedUs, ended);
        } else {
          _observe(
            _eyes,
            face.leftEye!,
            face.rightEye!,
            capturedUs,
            completedUs,
            started,
            ended,
          );
        }
      }
      if (!face.hasHeadAngles) {
        _invalidate(_head, ChannelReason.missingAngles, capturedUs, ended);
      } else if ((face.yaw! - calibration.neutralYaw).abs() >
          settings.headYawLimit) {
        _invalidate(
          _head,
          ChannelReason.sideTurn,
          capturedUs,
          ended,
          EventEndReason.sideTurn,
        );
      } else {
        _observe(
          _head,
          face.pitchDown! - calibration.neutralPitch,
          0,
          capturedUs,
          completedUs,
          started,
          ended,
        );
      }
    }
    return _update(before, completedUs, started: started, ended: ended);
  }

  ObservationUpdate tick(int nowUs) {
    if (_stopped || nowUs < _now || nowUs < 0) {
      return ObservationUpdate(snapshot: snapshot, rejected: true);
    }
    final before = snapshot;
    _now = nowUs;
    final ended = <ObservationEvent>[];
    _gaps(nowUs, ended);
    return _update(before, nowUs, ended: ended);
  }

  ObservationUpdate acknowledge({
    required Set<String> eventIds,
    required int nowUs,
  }) {
    if (nowUs < _now || _stopped) {
      return ObservationUpdate(snapshot: snapshot, rejected: true);
    }
    final before = snapshot;
    _now = nowUs;
    final acknowledged = <ObservationEvent>[];
    for (final c in [_eyes, _head]) {
      if (c.event != null &&
          eventIds.contains(c.event!.id) &&
          c.event!.acknowledgedUs == null) {
        c.event = c.event!._copy(acknowledgedUs: nowUs);
        acknowledged.add(c.event!);
      }
    }
    return _update(before, nowUs, acknowledged: acknowledged);
  }

  ObservationUpdate stop({
    required int nowUs,
    EventEndReason reason = EventEndReason.observationStopped,
  }) {
    if (_stopped || nowUs < _now) {
      return ObservationUpdate(snapshot: snapshot, rejected: true);
    }
    if (reason == EventEndReason.recovered) {
      throw ArgumentError('Остановка не является восстановлением');
    }
    final before = snapshot;
    _now = nowUs;
    _stopped = true;
    final ended = <ObservationEvent>[];
    for (final c in [_eyes, _head]) {
      _invalidate(c, ChannelReason.stopped, nowUs, ended, reason);
    }
    return _update(before, nowUs, ended: ended);
  }

  void _gaps(int nowUs, List<ObservationEvent> ended) {
    if (_requiresRecalibration) return;
    for (final c in [_eyes, _head]) {
      if (c == _eyes && settings.hiddenEyes) continue;
      final gap = nowUs - (c.lastUsableUs ?? 0);
      if (gap > maximumGapUs && c.available) {
        _invalidate(c, ChannelReason.observationGap, nowUs, ended);
      }
      if (gap >= 1000000) {
        _invalidate(c, ChannelReason.noRecentData, nowUs, ended);
      }
    }
  }

  void _invalidate(
    _Channel c,
    ChannelReason reason,
    int nowUs,
    List<ObservationEvent> ended, [
    EventEndReason endReason = EventEndReason.dataLost,
  ]) {
    if (c.event != null) {
      ended.add(c.event!._copy(endedUs: nowUs, endReason: endReason));
    }
    c.event = null;
    c.available = false;
    c.phase = ChannelPhase.unavailable;
    c.reason = reason;
    c.first.clear();
    c.second.clear();
    c.signStartedUs = null;
    c.recoveryStartedUs = null;
  }

  void _observe(
    _Channel c,
    double first,
    double second,
    int capturedUs,
    int completedUs,
    List<ObservationEvent> started,
    List<ObservationEvent> ended,
  ) {
    c.available = true;
    c.lastUsableUs = capturedUs;
    c.first.add(first);
    c.second.add(second);
    if (c.first.length > 3) {
      c.first.removeAt(0);
      c.second.removeAt(0);
    }
    if (c.first.length < 3) {
      c.phase = ChannelPhase.warmingUp;
      c.reason = ChannelReason.warmingUp;
      return;
    }
    c.reason = ChannelReason.none;
    final isEyes = c.channel == ObservationChannel.eyes;
    final abnormal = isEyes
        ? median(c.first) < calibration.eyeThreshold! &&
              median(c.second) < calibration.eyeThreshold!
        : median(c.first) > settings.pitchThreshold;
    final recovered = isEyes
        ? median(c.first) >= calibration.eyeThreshold! &&
              median(c.second) >= calibration.eyeThreshold!
        : !abnormal;
    final duration = isEyes ? settings.eyesClosedUs : settings.headDownUs;
    if (abnormal) {
      c.recoveryStartedUs = null;
      c.signStartedUs ??= capturedUs;
      if (c.event == null && capturedUs - c.signStartedUs! >= duration) {
        c.event = ObservationEvent(
          id: '$sessionId:${++_sequence}',
          sessionId: sessionId,
          type: isEyes ? EventType.eyesClosed : EventType.headPitchDown,
          signStartedUs: c.signStartedUs!,
          thresholdUs: c.signStartedUs! + duration,
          alertRequestedUs: completedUs,
        );
        started.add(c.event!);
      }
      c.phase = c.event == null
          ? ChannelPhase.signPresent
          : ChannelPhase.warning;
    } else if (c.event == null) {
      c.signStartedUs = null;
      c.phase = ChannelPhase.normal;
    } else if (!recovered) {
      // One open eye interrupts closed-eye evidence but is not sustained
      // reopening of both eyes, so an already active event remains active.
      c.recoveryStartedUs = null;
      c.phase = ChannelPhase.warning;
    } else {
      c.recoveryStartedUs ??= capturedUs;
      c.phase = ChannelPhase.recovering;
      final recovery = isEyes ? 300000 : 500000;
      if (capturedUs - c.recoveryStartedUs! >= recovery) {
        ended.add(
          c.event!._copy(
            endedUs: c.recoveryStartedUs,
            endReason: EventEndReason.recovered,
          ),
        );
        c.event = null;
        c.signStartedUs = null;
        c.recoveryStartedUs = null;
        c.phase = ChannelPhase.normal;
      }
    }
  }

  ObservationUpdate _update(
    ObservationSnapshot before,
    int nowUs, {
    List<ObservationEvent> started = const [],
    List<ObservationEvent> ended = const [],
    List<ObservationEvent> acknowledged = const [],
    bool rejected = false,
  }) {
    final after = snapshot;
    final transitions = <ChannelTransition>[];
    for (final pair in [(before.eyes, after.eyes), (before.head, after.head)]) {
      if (pair.$1.phase != pair.$2.phase ||
          pair.$1.reason != pair.$2.reason ||
          pair.$1.available != pair.$2.available) {
        transitions.add(
          ChannelTransition(
            channel: pair.$2.channel,
            atUs: nowUs,
            fromPhase: pair.$1.phase,
            toPhase: pair.$2.phase,
            reason: pair.$2.reason,
            available: pair.$2.available,
          ),
        );
      }
    }
    return ObservationUpdate(
      snapshot: after,
      started: started,
      ended: ended,
      acknowledged: acknowledged,
      transitions: transitions,
      rejected: rejected,
    );
  }
}
