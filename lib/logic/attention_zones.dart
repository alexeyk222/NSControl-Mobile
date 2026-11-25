import 'dart:math' as math;

import 'attention.dart';
import 'calibration.dart';
import 'driver_continuity.dart';
import 'face.dart';
import 'mount.dart';
import 'signals.dart';

/// Attention logic on top of the ТЗ automata: where the driver looks
/// ([GazeZone]), which lowered eyelids must not count as closed eyes, and the
/// optional distraction extension.
///
/// Nothing here changes a ТЗ threshold. The ТЗ automata in
/// `ObservationEngine` still receive only [FaceMeasurement]; this layer only
/// decides what goes into them. With [AttentionSettings.acceptance] (all
/// extensions off) the measurements are exactly `FaceSignals.toMeasurement()`,
/// so behaviour in acceptance mode is the ТЗ behaviour bit for bit.

/// Product extensions over the ТЗ. Every flag is off in acceptance mode,
/// because each of them can only suppress or add signals relative to ФТ-04/05.
class AttentionSettings {
  const AttentionSettings({
    this.gazeAwareEyes = false,
    this.headOnlyLookDown = false,
    this.distraction = false,
    this.mountRelative = false,
  });

  /// ТЗ acceptance mode: no extension is active.
  const AttentionSettings.acceptance() : this();

  /// Everything the MVP lab turns on by default. [headOnlyLookDown] stays off:
  /// without eye gaze it would also hide a real closure with the head
  /// slightly lowered, see docs/attention-method.md.
  static const lab = AttentionSettings(
    gazeAwareEyes: true,
    distraction: true,
    mountRelative: true,
  );

  /// A lowered lid caused by looking down (instruments, console) or by a
  /// squint does not accumulate `eyes_closed` time. Needs eye gaze or
  /// blendshapes from the engine (ARKit); for engines without them it does
  /// nothing unless [headOnlyLookDown] is also on.
  final bool gazeAwareEyes;

  /// For engines without eye gaze (ML Kit): treat the head-pose instruments
  /// and console zones as "looking down". Experimental, off by default.
  final bool headOnlyLookDown;

  /// Separate `distraction` event: off-road gaze for 3 s continuously or
  /// 10 s within 30 s (Euro NCAP Driver Engagement 1.1, § 1.2.1, § 1.2.2).
  final bool distraction;

  /// Side mount: head angles for the ТЗ automata, zones and distraction are
  /// taken relative to the calibrated road pose by rotation (`R_cal⁻¹·R`),
  /// the eyes are usable while the face is within the engine's eye limit to
  /// the camera, and the calibration uses `MountCalibrationCollector`. The
  /// ТЗ thresholds (20°, 2.0 s, 30°) are unchanged. Off in acceptance until
  /// the change request is approved. See `lib/logic/mount.dart`.
  final bool mountRelative;

  bool get isAcceptance =>
      !gazeAwareEyes && !headOnlyLookDown && !distraction && !mountRelative;

  Map<String, Object?> toJson() => {
    'gazeAwareEyes': gazeAwareEyes,
    'headOnlyLookDown': headOnlyLookDown,
    'distraction': distraction,
    'mountRelative': mountRelative,
  };

  factory AttentionSettings.fromJson(Map<String, dynamic> json) =>
      AttentionSettings(
        gazeAwareEyes: (json['gazeAwareEyes'] as bool?) ?? false,
        headOnlyLookDown: (json['headOnlyLookDown'] as bool?) ?? false,
        distraction: (json['distraction'] as bool?) ?? false,
        mountRelative: (json['mountRelative'] as bool?) ?? false,
      );
}

/// Direction of attention in degrees relative to the calibrated road
/// direction, in the driver conventions of [FaceSignals]: [left] > 0 to the
/// driver's left, [down] > 0 below the road direction.
class GazeDirection {
  const GazeDirection(this.left, this.down, {required this.fromGaze});
  final double left, down;

  /// True when it comes from eye gaze (head plus eyes), false when only the
  /// head pose was available.
  final bool fromGaze;

  Map<String, Object?> toJson() => {
    'left': left,
    'down': down,
    'source': fromGaze ? 'gaze' : 'head',
  };
}

/// An elliptic zone in direction space, relative to the road direction.
class ZoneRegion {
  const ZoneRegion(
    this.zone, {
    required this.left,
    required this.down,
    required this.radiusLeft,
    required this.radiusDown,
  });
  final GazeZone zone;
  final double left, down, radiusLeft, radiusDown;

  /// 0 at the centre, 1 on the border.
  double distance(GazeDirection d) => math.sqrt(
    math.pow((d.left - left) / radiusLeft, 2) +
        math.pow((d.down - down) / radiusDown, 2),
  );

  Map<String, Object?> toJson() => {
    'zone': zone.code,
    'left': left,
    'down': down,
    'radiusLeft': radiusLeft,
    'radiusDown': radiusDown,
  };

  factory ZoneRegion.fromJson(Map<String, dynamic> json) {
    final region = ZoneRegion(
      GazeZone.fromCode(json['zone'] as String),
      left: (json['left'] as num).toDouble(),
      down: (json['down'] as num).toDouble(),
      radiusLeft: (json['radiusLeft'] as num).toDouble(),
      radiusDown: (json['radiusDown'] as num).toDouble(),
    );
    if (![
          region.left,
          region.down,
          region.radiusLeft,
          region.radiusDown,
        ].every((v) => v.isFinite) ||
        region.radiusLeft <= 0 ||
        region.radiusDown <= 0) {
      throw FormatException('invalid zone region: $json');
    }
    return region;
  }
}

/// Personal zone layout: the road direction from the ТЗ calibration, plus
/// zone regions (default sectors or the optional mirror calibration).
///
/// Two sets of regions exist because the head alone turns less than head plus
/// eyes: [gazeRegions] are used when the engine reports gaze, [headRegions]
/// when only the head pose is known (ML Kit).
class ZoneMap {
  ZoneMap({
    required this.roadHeadLeft,
    required this.roadHeadDown,
    double? roadGazeLeft,
    double? roadGazeDown,
    List<ZoneRegion>? gazeRegions,
    List<ZoneRegion>? headRegions,
    this.mirrorsCalibrated = false,
    this.roadHeadRoll = 0,
    this.mountRelative = false,
    this.mountEngine,
  }) : roadGazeLeft = roadGazeLeft ?? roadHeadLeft,
       roadGazeDown = roadGazeDown ?? roadHeadDown,
       gazeRegions = List.unmodifiable(gazeRegions ?? defaultGazeRegions),
       headRegions = List.unmodifiable(headRegions ?? defaultHeadRegions),
       _frame = RoadFrame.fromAngles(
         roadHeadLeft,
         roadHeadDown,
         roadHeadRoll,
         engineId: mountEngine,
       );

  /// Road direction from the ТЗ calibration: neutral head yaw/pitch.
  factory ZoneMap.fromCalibration(
    CalibrationProfile profile, {
    double? roadGazeLeft,
    double? roadGazeDown,
    bool mountRelative = false,
  }) => ZoneMap(
    roadHeadLeft: profile.neutralYaw,
    roadHeadDown: profile.neutralPitch,
    roadHeadRoll: profile.neutralRoll,
    roadGazeLeft: roadGazeLeft,
    roadGazeDown: roadGazeDown,
    mountRelative: mountRelative,
    mountEngine: profile.detector.id,
  );

  /// The same layout with directions taken by rotation relative to the road
  /// pose (side mount, see [AttentionSettings.mountRelative]).
  ZoneMap withMount({required double roadHeadRoll, String? engineId}) =>
      ZoneMap(
        roadHeadLeft: roadHeadLeft,
        roadHeadDown: roadHeadDown,
        roadHeadRoll: roadHeadRoll,
        roadGazeLeft: roadGazeLeft,
        roadGazeDown: roadGazeDown,
        gazeRegions: gazeRegions,
        headRegions: headRegions,
        mirrorsCalibrated: mirrorsCalibrated,
        mountRelative: true,
        mountEngine: engineId ?? mountEngine,
      );

  /// Absolute head and gaze angles (camera frame) of the road direction.
  final double roadHeadLeft, roadHeadDown, roadGazeLeft, roadGazeDown;

  /// Head roll of the road pose; used only with [mountRelative].
  final double roadHeadRoll;
  final List<ZoneRegion> gazeRegions, headRegions;
  final bool mirrorsCalibrated;

  /// Directions by rotation relative to the road pose instead of angle
  /// differences: exact for a camera turned or tilted from the road.
  final bool mountRelative;

  /// Engine whose Euler order the road angles use (`mount.dart`).
  final String? mountEngine;
  final RoadFrame _frame;

  /// Starting sectors for a left-hand-drive car with the phone on the dash in
  /// front of the driver, relative to the road direction. They are a first
  /// guess to be tuned on recordings; the mirror calibration replaces them.
  static const defaultGazeRegions = [
    ZoneRegion(GazeZone.road, left: 0, down: 0, radiusLeft: 15, radiusDown: 11),
    ZoneRegion(
      GazeZone.mirrorLeft,
      left: 38,
      down: 4,
      radiusLeft: 14,
      radiusDown: 12,
    ),
    ZoneRegion(
      GazeZone.mirrorRight,
      left: -52,
      down: 6,
      radiusLeft: 16,
      radiusDown: 12,
    ),
    ZoneRegion(
      GazeZone.mirrorRear,
      left: -26,
      down: -14,
      radiusLeft: 12,
      radiusDown: 9,
    ),
    ZoneRegion(
      GazeZone.instruments,
      left: 0,
      down: 24,
      radiusLeft: 15,
      radiusDown: 11,
    ),
    ZoneRegion(
      GazeZone.console,
      left: -26,
      down: 32,
      radiusLeft: 14,
      radiusDown: 14,
    ),
  ];

  /// The same sectors for head pose only: the head covers roughly two thirds
  /// of a gaze shift, the eyes the rest.
  static const defaultHeadRegions = [
    ZoneRegion(GazeZone.road, left: 0, down: 0, radiusLeft: 12, radiusDown: 7),
    ZoneRegion(
      GazeZone.mirrorLeft,
      left: 26,
      down: 2,
      radiusLeft: 12,
      radiusDown: 10,
    ),
    ZoneRegion(
      GazeZone.mirrorRight,
      left: -38,
      down: 4,
      radiusLeft: 14,
      radiusDown: 10,
    ),
    ZoneRegion(
      GazeZone.mirrorRear,
      left: -17,
      down: -8,
      radiusLeft: 8,
      radiusDown: 6,
    ),
    ZoneRegion(
      GazeZone.instruments,
      left: 0,
      down: 13,
      radiusLeft: 12,
      radiusDown: 6,
    ),
    ZoneRegion(
      GazeZone.console,
      left: -18,
      down: 22,
      radiusLeft: 12,
      radiusDown: 10,
    ),
  ];

  /// Beyond this |left| the driver looks out of the side windows (blind spot,
  /// intersection), whatever the regions say.
  static const offCameraGaze = 60.0, offCameraHead = 45.0;

  /// Direction of [s] relative to the road, from gaze when the engine
  /// measures it and from the head pose otherwise. Null without usable angles.
  GazeDirection? directionOf(FaceSignals s) {
    if (mountRelative) return _mountDirectionOf(s);
    if (s.hasGaze) {
      return GazeDirection(
        s.gazeLeft! - roadGazeLeft,
        s.gazeDown! - roadGazeDown,
        fromGaze: true,
      );
    }
    if (FaceMeasurement.angle(s.headYawLeft) &&
        FaceMeasurement.angle(s.headPitchDown)) {
      return GazeDirection(
        s.headYawLeft! - roadHeadLeft,
        s.headPitchDown! - roadHeadDown,
        fromGaze: false,
      );
    }
    return null;
  }

  GazeDirection? _mountDirectionOf(FaceSignals s) {
    if (s.hasGaze) {
      final (gl, gd) = _frame.direction(s.gazeLeft!, s.gazeDown!);
      final (rl, rd) = _frame.direction(roadGazeLeft, roadGazeDown);
      return GazeDirection(gl - rl, gd - rd, fromGaze: true);
    }
    final head = _frame.head(s);
    if (head == null) return null;
    return GazeDirection(head.$1, head.$2, fromGaze: false);
  }

  /// Zone of a direction without memory. [current] gets [stickiness]: its
  /// region is scaled up, which gives the hysteresis at zone borders.
  GazeZone classify(
    GazeDirection d, {
    GazeZone? current,
    double stickiness = 1.25,
  }) {
    final regions = d.fromGaze ? gazeRegions : headRegions;
    final offCamera = d.fromGaze ? offCameraGaze : offCameraHead;
    if (d.left.abs() > offCamera) return GazeZone.offCamera;
    GazeZone? best;
    var bestDistance = double.infinity;
    for (final r in regions) {
      var distance = r.distance(d);
      if (r.zone == current) distance /= stickiness;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = r.zone;
      }
    }
    if (best != null && bestDistance <= 1) return best;
    // Between regions: the nearest zone other than the road, so that "off the
    // road" is never reported as the road.
    GazeZone? nearest;
    var nearestDistance = double.infinity;
    for (final r in regions) {
      if (r.zone == GazeZone.road) continue;
      final distance = r.distance(d);
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearest = r.zone;
      }
    }
    return nearest ?? GazeZone.offCamera;
  }

  Map<String, Object?> toJson() => {
    'road': {
      'headLeft': roadHeadLeft,
      'headDown': roadHeadDown,
      'gazeLeft': roadGazeLeft,
      'gazeDown': roadGazeDown,
      if (roadHeadRoll != 0) 'headRoll': roadHeadRoll,
    },
    'mirrorsCalibrated': mirrorsCalibrated,
    if (mountRelative) 'mountRelative': true,
    if (mountRelative && mountEngine != null) 'mountEngine': mountEngine,
    'gazeRegions': [for (final r in gazeRegions) r.toJson()],
    'headRegions': [for (final r in headRegions) r.toJson()],
  };

  factory ZoneMap.fromJson(Map<String, dynamic> json) {
    final road = Map<String, dynamic>.from(json['road'] as Map);
    List<ZoneRegion>? regions(String key) => (json[key] as List?)
        ?.map((r) => ZoneRegion.fromJson(Map<String, dynamic>.from(r as Map)))
        .toList();
    return ZoneMap(
      roadHeadLeft: (road['headLeft'] as num).toDouble(),
      roadHeadDown: (road['headDown'] as num).toDouble(),
      roadGazeLeft: (road['gazeLeft'] as num?)?.toDouble(),
      roadGazeDown: (road['gazeDown'] as num?)?.toDouble(),
      roadHeadRoll: (road['headRoll'] as num?)?.toDouble() ?? 0,
      gazeRegions: regions('gazeRegions'),
      headRegions: regions('headRegions'),
      mirrorsCalibrated: (json['mirrorsCalibrated'] as bool?) ?? false,
      mountRelative: (json['mountRelative'] as bool?) ?? false,
      mountEngine: json['mountEngine'] as String?,
    );
  }
}

/// Optional mirror calibration: the driver looks about 2 s into each mirror
/// on a prompt; the centre and the spread of each glance replace the default
/// sector. Feed it frames of one mirror at a time between [begin] and [end].
class ZoneCalibrationCollector {
  ZoneCalibrationCollector(this.base);
  final ZoneMap base;
  static const minimumUs = 1500000;
  static const minimumFrames = 10;

  /// Smallest region radius, degrees, so that a very still glance still
  /// leaves room for the next one.
  static const minimumRadius = 6.0;

  final Map<GazeZone, List<GazeDirection>> _samples = {};
  final Map<GazeZone, (int, int)> _spans = {};
  GazeZone? _zone;
  int? _startedUs;

  void begin(GazeZone mirror, int atUs) {
    if (!const [
      GazeZone.mirrorLeft,
      GazeZone.mirrorRight,
      GazeZone.mirrorRear,
    ].contains(mirror)) {
      throw ArgumentError('Калибруются только зеркала: $mirror');
    }
    _zone = mirror;
    _startedUs = atUs;
    _samples[mirror] = [];
  }

  void add(int atUs, FaceSignals? face) {
    final zone = _zone;
    if (zone == null || face == null || !face.tracked) return;
    final d = base.directionOf(face);
    if (d != null) _samples[zone]!.add(d);
  }

  /// Returns a problem in Russian, or null when the glance is usable.
  String? end(int atUs) {
    final zone = _zone, started = _startedUs;
    _zone = null;
    if (zone == null || started == null) return 'Шаг калибровки не начат';
    final samples = _samples[zone]!;
    if (atUs - started < minimumUs || samples.length < minimumFrames) {
      _samples.remove(zone);
      return 'Смотрите в зеркало не меньше 2 секунд и повторите.';
    }
    _spans[zone] = (started, atUs);
    return null;
  }

  bool get complete => _spans.length == 3;

  /// Zone map with calibrated mirrors; zones not calibrated keep defaults.
  ZoneMap finish() {
    List<ZoneRegion> merge(List<ZoneRegion> defaults, bool fromGaze) {
      final result = <ZoneRegion>[];
      for (final r in defaults) {
        final samples = (_spans.containsKey(r.zone) ? _samples[r.zone] : null)
            ?.where((d) => d.fromGaze == fromGaze)
            .toList();
        if (samples == null || samples.length < minimumFrames) {
          result.add(r);
          continue;
        }
        final lefts = samples.map((d) => d.left),
            downs = samples.map((d) => d.down);
        result.add(
          ZoneRegion(
            r.zone,
            left: median(lefts),
            down: median(downs),
            radiusLeft: math.max(
              minimumRadius,
              4 * medianAbsoluteDeviation(lefts),
            ),
            radiusDown: math.max(
              minimumRadius,
              4 * medianAbsoluteDeviation(downs),
            ),
          ),
        );
      }
      return result;
    }

    return ZoneMap(
      roadHeadLeft: base.roadHeadLeft,
      roadHeadDown: base.roadHeadDown,
      roadGazeLeft: base.roadGazeLeft,
      roadGazeDown: base.roadGazeDown,
      gazeRegions: merge(base.gazeRegions, true),
      headRegions: merge(base.headRegions, false),
      mirrorsCalibrated: _spans.isNotEmpty,
      roadHeadRoll: base.roadHeadRoll,
      mountRelative: base.mountRelative,
      mountEngine: base.mountEngine,
    );
  }
}

/// Per-frame zone with hysteresis and a minimum dwell, so the zone does not
/// flicker at region borders and in a single noisy frame.
class GazeZoneTracker {
  GazeZoneTracker(
    this.map, {
    this.dwellUs = 150000,
    this.stickiness = 1.25,
    this.lostGraceUs = 1000000,
    this.cameraEdgeYaw = 40,
  });
  final ZoneMap map;

  /// Side mount ([ZoneMap.mountRelative]): a face lost while turned at
  /// least this far from the camera, and away from the road, was turned away
  /// from the phone. The face is lost earlier on that side (a mirror on the
  /// far side may already be out of view), so the road-frame turn alone is
  /// not enough to tell a look away from a tracking failure.
  final double cameraEdgeYaw;

  /// Side mount: a fast turn away from the camera is lost before the face
  /// reaches [cameraEdgeYaw] (ML Kit gives a frame every 66 ms). The camera
  /// yaw is extrapolated from the last two frames for up to this long, and
  /// the head must already be at least [minTurn] from the road.
  static const extrapolateUs = 200000;
  static const minTurn = 6.0;

  /// A new zone must hold this long before it replaces the current one.
  final int dwellUs;
  final double stickiness;

  /// A short tracking loss keeps the last zone (ADDW 2023/2590, part 1,
  /// § 3.3.2.4: short tracking losses must not reset the assessment).
  final int lostGraceUs;

  GazeZone _zone = GazeZone.unknown;
  int? _sinceUs, _awaySinceUs, _lastSeenUs;
  GazeDirection? _direction, _lastDirection;
  double? _lastCameraYaw, _prevCameraYaw;
  int? _prevSeenUs;

  GazeZone _raw = GazeZone.unknown;

  /// Debounced zone: what the driver looks at.
  GazeZone get zone => _zone;

  /// Zone of the latest frame before the dwell filter.
  GazeZone get raw => _raw;
  int? get sinceUs => _sinceUs;
  GazeDirection? get direction => _direction;

  GazeZone update(int atUs, FaceSignals? face) {
    final d = face != null && face.tracked ? map.directionOf(face) : null;
    _direction = d;
    final GazeZone raw;
    if (d != null) {
      _prevSeenUs = _lastSeenUs;
      _prevCameraYaw = _lastCameraYaw;
      _lastSeenUs = atUs;
      _lastDirection = d;
      _lastCameraYaw = face!.headYawLeft;
      raw = map.classify(d, current: _zone, stickiness: stickiness);
    } else {
      final last = _lastDirection;
      final roadRadius = last == null
          ? 0.0
          : (last.fromGaze ? map.gazeRegions : map.headRegions)
                .firstWhere((r) => r.zone == GazeZone.road)
                .radiusLeft;
      final cameraYaw = _lastCameraYaw;
      final turnedAway =
          last != null &&
          (last.left.abs() > roadRadius * 2 ||
              (map.mountRelative &&
                  cameraYaw != null &&
                  ((cameraYaw.abs() >= cameraEdgeYaw &&
                          last.left.abs() > roadRadius) ||
                      (last.left.abs() >= minTurn &&
                          _extrapolatedCameraYaw(atUs).abs() >=
                              cameraEdgeYaw))));
      if (turnedAway) {
        // The face left the camera while the head was turned far: a look over
        // the shoulder or out of a side window, not a tracking failure.
        raw = GazeZone.offCamera;
      } else if (_lastSeenUs != null && atUs - _lastSeenUs! <= lostGraceUs) {
        raw = _zone;
      } else {
        raw = GazeZone.unknown;
      }
    }
    _raw = raw;
    if (raw == _zone) {
      _awaySinceUs = null;
    } else if (_zone == GazeZone.unknown || raw == GazeZone.unknown) {
      _set(raw, atUs);
    } else {
      // Any other zone held for the dwell time wins, even when the noise
      // alternates between two neighbours (mirror / off camera).
      _awaySinceUs ??= atUs;
      if (atUs - _awaySinceUs! >= dwellUs) _set(raw, _awaySinceUs!);
    }
    return _zone;
  }

  /// The camera yaw the face was turning to when it was lost: the last one
  /// moved on at the speed of the last two frames when the face was turning
  /// away from the camera, else the last one.
  double _extrapolatedCameraYaw(int atUs) {
    final last = _lastCameraYaw!, prev = _prevCameraYaw;
    final lastUs = _lastSeenUs!, prevUs = _prevSeenUs;
    if (prev == null ||
        prevUs == null ||
        lastUs - prevUs <= 0 ||
        lastUs - prevUs > extrapolateUs ||
        last.abs() <= prev.abs() ||
        last.sign != prev.sign) {
      return last;
    }
    final speed = (last - prev) / (lastUs - prevUs);
    return last + speed * math.min(atUs - lastUs, extrapolateUs);
  }

  void _set(GazeZone zone, int sinceUs) {
    _zone = zone;
    _sinceUs = sinceUs;
    _awaySinceUs = null;
  }
}

/// Why the eyes of a frame are not evaluated for `eyes_closed`.
enum EyeGateReason {
  none('none'),
  lookDown('look_down'),
  squint('squint');

  const EyeGateReason(this.code);
  final String code;
}

/// Decides when a lowered eyelid is not a closed eye (ФТ-04: invisible eyes
/// and an unusable view are not counted as closure).
///
/// - Looking down: the lid follows the eye down (instruments, console). The
///   gate opens only after the eyes were seen open while looking down in the
///   same glance, so a real closure that starts on the road is never hidden
///   even if the engine reports the closed eye as "looking down".
/// - Squint: a strong squint blendshape (sun, laughter, yawn).
/// - Both signs have hysteresis: squint turns on at [squintBlend] and off
///   below [squintOff]; looking down turns on at [lookDownGaze] or
///   [lookDownBlend] and off below [lookDownGazeOff] and [lookDownBlendOff].
///   A coefficient jumping around the "on" value (laughter: 0.42–0.5) keeps
///   the sign on instead of letting single frames through.
/// - A deep closure (both eyes open ≤ [deepOpen]) always counts.
/// - Closure latch: once both eyes have been below T with the gate letting
///   every frame through for [latchUs] in a row, or the eyes channel already
///   has an active event, the gate stays open until both eyes are back at or
///   above T. A sign without an event does not latch: the ТЗ automaton shows
///   a sign after two closed frames, too early to tell a closure from noise.
///   A squint flickering during a real closure then can neither reset the
///   1.5 s count nor cut an active event, while a few frames let through by
///   noise do not latch.
class EyeGate {
  EyeGate({
    this.lookDownGaze = 12,
    this.lookDownGazeOff = 9,
    this.lookDownBlend = .35,
    this.lookDownBlendOff = .25,
    this.squintBlend = .45,
    this.squintOff = .35,
    this.deepOpen = .15,
    this.latchUs = 100000,
  });

  /// Eye-in-head downward angle, degrees, that turns looking down on; it
  /// stays on until the angle is below [lookDownGazeOff].
  final double lookDownGaze, lookDownGazeOff;

  /// The same for the mean eyeLookDown blendshape.
  final double lookDownBlend, lookDownBlendOff;

  /// Mean eyeSquint that turns the squint sign on; off below [squintOff].
  final double squintBlend, squintOff;

  /// Both eyes at or below this openness are a closure whatever the gaze.
  final double deepOpen;

  /// How long an ungated closure must last before the latch holds it.
  final int latchUs;

  bool _armed = false, _latched = false, _squinting = false;
  bool _eyesDown = false;
  int? _ungatedSinceUs;

  /// True while a closure is latched and the gate is held open.
  bool get latched => _latched;

  EyeGateReason evaluate({
    required FaceSignals face,
    required GazeZone zone,
    required double threshold,
    required bool headOnly,
    int atUs = 0,
    bool eyesEventActive = false,
  }) {
    final left = face.eyeOpenLeft, right = face.eyeOpenRight;
    if (left == null || right == null) {
      reset();
      return EyeGateReason.none;
    }
    final open = left >= threshold && right >= threshold;
    final closed = left < threshold && right < threshold;
    final reason = _reason(face, zone, left, right, open, headOnly);
    if (!closed || reason != EyeGateReason.none) {
      _ungatedSinceUs = null;
      if (open) _latched = false;
    } else {
      _ungatedSinceUs ??= atUs;
    }
    if (closed &&
        (eyesEventActive ||
            (_ungatedSinceUs != null && atUs - _ungatedSinceUs! >= latchUs))) {
      _latched = true;
    }
    return _latched ? EyeGateReason.none : reason;
  }

  EyeGateReason _reason(
    FaceSignals face,
    GazeZone zone,
    double left,
    double right,
    bool open,
    bool headOnly,
  ) {
    final deep = left <= deepOpen && right <= deepOpen;
    final gazeEngine =
        face.eyeGazeDown != null ||
        face.blendshape(Blendshape.eyeLookDownLeft) != null;
    final bool lookingDown;
    if (gazeEngine) {
      final blend = _mean(
        face.blendshape(Blendshape.eyeLookDownLeft),
        face.blendshape(Blendshape.eyeLookDownRight),
      );
      final gaze = face.eyeGazeDown;
      final eyesDown = _eyesDown
          ? (gaze != null && gaze >= lookDownGazeOff) ||
                (blend != null && blend >= lookDownBlendOff)
          : (gaze != null && gaze >= lookDownGaze) ||
                (blend != null && blend >= lookDownBlend);
      _eyesDown = eyesDown;
      lookingDown =
          eyesDown || zone == GazeZone.instruments || zone == GazeZone.console;
    } else {
      lookingDown =
          headOnly &&
          (zone == GazeZone.instruments || zone == GazeZone.console);
    }
    if (!lookingDown) {
      _armed = false;
    } else if (open) {
      _armed = true;
    }
    final squint = _mean(
      face.blendshape(Blendshape.eyeSquintLeft),
      face.blendshape(Blendshape.eyeSquintRight),
    );
    _squinting =
        squint != null && squint >= (_squinting ? squintOff : squintBlend);
    if (deep) return EyeGateReason.none;
    if (_squinting) return EyeGateReason.squint;
    if (lookingDown && _armed) return EyeGateReason.lookDown;
    return EyeGateReason.none;
  }

  void reset() {
    _armed = false;
    _latched = false;
    _squinting = false;
    _eyesDown = false;
    _ungatedSinceUs = null;
  }

  static double? _mean(double? a, double? b) =>
      a == null || b == null ? null : (a + b) / 2;
}

enum DistractionKind {
  /// Off-road for [DistractionMonitor.longUs] without a break.
  longGlance('long_glance'),

  /// Visual time sharing: [DistractionMonitor.cumulativeUs] off-road within
  /// [DistractionMonitor.windowUs].
  cumulative('cumulative');

  const DistractionKind(this.code);
  final String code;
}

/// A product-extension event. It is never an `eyes_closed` or
/// `head_pitch_down` event and is not created in acceptance mode.
class DistractionEvent {
  const DistractionEvent({
    required this.id,
    required this.kind,
    required this.zone,
    required this.signStartedUs,
    required this.thresholdUs,
    this.endedUs,
  });
  static const code = 'distraction';
  final String id;
  final DistractionKind kind;
  final GazeZone zone;
  final int signStartedUs, thresholdUs;
  final int? endedUs;
  bool get active => endedUs == null;

  DistractionEvent ended(int atUs) => DistractionEvent(
    id: id,
    kind: kind,
    zone: zone,
    signStartedUs: signStartedUs,
    thresholdUs: thresholdUs,
    endedUs: atUs,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'type': code,
    'kind': kind.code,
    'zone': zone.code,
    'signStartedUs': signStartedUs,
    'thresholdUs': thresholdUs,
    'endedUs': endedUs,
  };
}

/// Distraction extension (Euro NCAP Driver Engagement 1.1, § 1.2.1 long
/// distraction, § 1.2.2 visual time sharing).
///
/// - Long glance: any zone other than the road, including a mirror held for
///   3 s, continuously for [longUs]. A sweep across the road (one raw road
///   frame, as in a left-right scan at an intersection) restarts the count.
/// - Cumulative: [cumulativeZones] (by default the console: phone, radio,
///   lap) for [cumulativeUs] within [windowUs]. Mirrors, instruments and side
///   turns at intersections are driving glances and are left out of it.
/// - [GazeZone.unknown] (no data after the tracker's grace) neither counts nor
///   resets the cumulative window, but ends a long glance.
class DistractionMonitor {
  DistractionMonitor({
    this.longUs = 3000000,
    this.longUsByZone = const {
      GazeZone.mirrorLeft: 3000000,
      GazeZone.mirrorRight: 3000000,
      GazeZone.mirrorRear: 3000000,
    },
    this.windowUs = 30000000,
    this.cumulativeUs = 10000000,
    this.cumulativeZones = const {GazeZone.console},
    this.idPrefix = 'distraction',
  });
  final int longUs, windowUs, cumulativeUs;

  /// Long-glance threshold per zone; zones not listed use [longUs]. Mirrors
  /// are separate so their limit can be set from session 1 recordings.
  final Map<GazeZone, int> longUsByZone;

  /// Long-glance threshold that applies while the driver looks at [zone].
  int longFor(GazeZone zone) => longUsByZone[zone] ?? longUs;
  final Set<GazeZone> cumulativeZones;
  final String idPrefix;

  int? _offSinceUs, _lastUs;
  GazeZone? _lastZone;
  final List<(int, int)> _cumulative = [];
  DistractionEvent? _event;
  int _sequence = 0;

  DistractionEvent? get active => _event;

  /// Feeds one frame. Returns the events that started or ended.
  ///
  /// [raw] is the frame's zone before the dwell filter. With [suppress] (a
  /// ТЗ sign is present) no new distraction starts: the ТЗ event has
  /// priority and one moment is not alarmed twice.
  ({DistractionEvent? started, DistractionEvent? ended}) update(
    int atUs,
    GazeZone zone, {
    GazeZone? raw,
    bool suppress = false,
  }) {
    DistractionEvent? started, ended;
    final previous = _lastUs, previousZone = _lastZone;
    _lastUs = atUs;
    _lastZone = zone;
    if (previous != null &&
        previousZone != null &&
        cumulativeZones.contains(previousZone)) {
      _cumulative.add((previous, atUs));
    }
    _cumulative.removeWhere((span) => span.$2 <= atUs - windowUs);
    final offRoad = zone != GazeZone.road && zone != GazeZone.unknown;
    if (!offRoad) {
      _offSinceUs = null;
      if (_event != null) {
        ended = _event!.ended(atUs);
        _event = null;
        if (ended.kind == DistractionKind.cumulative) _cumulative.clear();
      }
      return (started: null, ended: ended);
    }
    if (raw == GazeZone.road) {
      _offSinceUs = null;
      return (started: null, ended: null);
    }
    _offSinceUs ??= atUs;
    if (_event != null || suppress) return (started: null, ended: null);
    final limit = longFor(zone);
    if (atUs - _offSinceUs! >= limit) {
      _event = DistractionEvent(
        id: '$idPrefix:${++_sequence}',
        kind: DistractionKind.longGlance,
        zone: zone,
        signStartedUs: _offSinceUs!,
        thresholdUs: _offSinceUs! + limit,
      );
      started = _event;
    } else if (cumulativeZones.contains(zone) &&
        _sharedUs(atUs) >= cumulativeUs) {
      _event = DistractionEvent(
        id: '$idPrefix:${++_sequence}',
        kind: DistractionKind.cumulative,
        zone: zone,
        signStartedUs: _cumulative.first.$1,
        thresholdUs: atUs,
      );
      started = _event;
    }
    return (started: started, ended: null);
  }

  int _sharedUs(int atUs) {
    var total = 0;
    for (final span in _cumulative) {
      total += span.$2 - math.max(span.$1, atUs - windowUs);
    }
    return total;
  }
}

/// What the attention logic decided for the latest frame; the lab shows it
/// and the recording stores it in `derived` lines.
class AttentionDecision {
  const AttentionDecision({
    required this.zone,
    this.zoneSinceUs,
    this.direction,
    this.eyeGate = EyeGateReason.none,
    this.distraction,
    this.driver = ContinuityDecision.noFace,
  });
  static const unknown = AttentionDecision(zone: GazeZone.unknown);

  /// How the driver's face was identified in this frame (ФТ-02).
  final ContinuityDecision driver;

  final GazeZone zone;
  final int? zoneSinceUs;
  final GazeDirection? direction;

  /// Why the eyes of this frame were withheld from the `eyes_closed`
  /// automaton, [EyeGateReason.none] when they were passed on.
  final EyeGateReason eyeGate;
  final DistractionEvent? distraction;

  Map<String, Object?> toJson() => {
    'zone': zone.code,
    'zoneSinceUs': zoneSinceUs,
    if (direction != null) 'direction': direction!.toJson(),
    'eyeGate': eyeGate.code,
    if (distraction != null) 'distraction': distraction!.toJson(),
    'driver': driver.code,
  };
}

/// Result of [AttentionPipeline.process] for one analysed frame.
class AttentionFrame {
  AttentionFrame({
    required this.measurements,
    required this.state,
    this.distractionStarted,
    this.distractionEnded,
  });

  /// Input for `ObservationEngine.process`, one per face, same order.
  final List<FaceMeasurement> measurements;
  final AttentionDecision state;
  final DistractionEvent? distractionStarted, distractionEnded;
}

/// Runs the zone tracker, the eye gate and the distraction monitor over the
/// signals of each frame and prepares the input for the ТЗ automata.
class AttentionPipeline {
  AttentionPipeline({
    required this.calibration,
    ZoneMap? zones,
    this.settings = const AttentionSettings(),
    EyeGate? eyeGate,
    DistractionMonitor? distraction,
    DriverContinuity? continuity,
  }) : zones = _zonesFor(calibration, zones, settings),
       eyeGate = eyeGate ?? EyeGate(),
       distractionMonitor = distraction ?? DistractionMonitor(),
       continuity =
           continuity ?? DriverContinuity(trackingId: calibration.trackingId),
       road = settings.mountRelative
           ? RoadFrame.fromProfile(calibration)
           : null,
       engineCalibration = settings.mountRelative
           ? roadProfile(calibration)
           : calibration {
    tracker = GazeZoneTracker(this.zones);
  }

  static ZoneMap _zonesFor(
    CalibrationProfile calibration,
    ZoneMap? zones,
    AttentionSettings settings,
  ) {
    final map = zones ?? ZoneMap.fromCalibration(calibration);
    return settings.mountRelative && !map.mountRelative
        ? map.withMount(
            roadHeadRoll: calibration.neutralRoll,
            engineId: calibration.detector.id,
          )
        : map;
  }

  final CalibrationProfile calibration;

  /// The profile to create `ObservationEngine` with: [calibration] itself,
  /// or with [AttentionSettings.mountRelative] its road-frame form
  /// ([roadProfile]: neutral angles 0), because then the measurements carry
  /// angles relative to the road.
  final CalibrationProfile engineCalibration;

  /// Road pose for [AttentionSettings.mountRelative], else null.
  final RoadFrame? road;
  final ZoneMap zones;
  final AttentionSettings settings;
  final EyeGate eyeGate;
  final DistractionMonitor distractionMonitor;

  /// Keeps the calibrated driver across tracking-id changes (ФТ-02/03);
  /// active in every mode.
  final DriverContinuity continuity;
  late final GazeZoneTracker tracker;

  AttentionDecision attention = AttentionDecision.unknown;

  /// The driver's face as last seen during calibration, at [atUs]; see
  /// [DriverContinuity.anchor].
  void anchorDriver(FaceSignals face, int atUs) =>
      continuity.anchor(atUs, box: face.box, distanceM: face.distanceM);

  /// [tzSignActive]: a ТЗ automaton had a sign or an event on the previous
  /// frame (`ChannelPhase.signPresent` or later); distraction then waits.
  /// [eyesEventActive]: the eyes channel had an active event on the previous
  /// frame (`ChannelSnapshot.activeEvent != null`); it latches the eye gate
  /// open (see [EyeGate]).
  AttentionFrame process(
    int capturedUs,
    List<FaceSignals> faces, {
    bool tzSignActive = false,
    bool eyesEventActive = false,
  }) {
    final usable = continuity.resolve(
      capturedUs,
      faces.where((f) => f.tracked).toList(),
    );
    final driver =
        usable.length == 1 &&
            (usable.single.trackingId ?? calibration.trackingId) ==
                calibration.trackingId
        ? usable.single
        : null;
    final zone = tracker.update(capturedUs, driver);
    var gate = EyeGateReason.none;
    final threshold = calibration.eyeThreshold;
    if (driver != null && settings.gazeAwareEyes && threshold != null) {
      gate = eyeGate.evaluate(
        face: driver,
        zone: zone,
        threshold: threshold,
        headOnly: settings.headOnlyLookDown,
        atUs: capturedUs,
        eyesEventActive: eyesEventActive,
      );
    } else {
      eyeGate.reset();
    }
    final measurements = [
      for (final f in usable)
        _measurement(
          f,
          withEyes: !identical(f, driver) || gate == EyeGateReason.none,
        ),
    ];
    DistractionEvent? started, ended;
    if (settings.distraction) {
      final change = distractionMonitor.update(
        capturedUs,
        zone,
        raw: tracker.raw,
        suppress: tzSignActive,
      );
      started = change.started;
      ended = change.ended;
    }
    attention = AttentionDecision(
      zone: zone,
      zoneSinceUs: tracker.sinceUs,
      direction: tracker.direction,
      eyeGate: gate,
      distraction: settings.distraction ? distractionMonitor.active : null,
      driver: continuity.decision,
    );
    return AttentionFrame(
      measurements: measurements,
      state: attention,
      distractionStarted: started,
      distractionEnded: ended,
    );
  }

  FaceMeasurement _measurement(FaceSignals f, {required bool withEyes}) {
    final road = this.road;
    if (road != null) {
      return mountMeasurement(
        f,
        road: road,
        calibration: calibration,
        withEyes: withEyes,
      );
    }
    final m = f.toMeasurement();
    if (withEyes && m.trackingId != null) return m;
    return FaceMeasurement(
      // Engines without face ids (one face only) inherit the calibrated id.
      trackingId: m.trackingId ?? calibration.trackingId,
      leftEye: withEyes ? m.leftEye : null,
      rightEye: withEyes ? m.rightEye : null,
      pitchDown: m.pitchDown,
      yaw: m.yaw,
      roll: m.roll,
    );
  }
}

/// The attention logic behind the lab's [AttentionStateProvider]: zone, eye
/// gate and distraction for the primary engine's frames.
///
/// Call [updateFaces] with every face of the frame and feed
/// [lastMeasurements] (instead of `toMeasurement()` of each face) into
/// `ObservationEngine.process`: the engine then sees the eye gate, the
/// restored driver id and a second face exactly as the pipeline decided
/// (ФТ-02 pause on two faces). With [AttentionSettings.acceptance] the eyes
/// and angles are the ТЗ measurement; only the tracking id may be restored.
/// [update] is the single-face form of the interface.
class ZoneAttentionProvider implements AttentionStateProvider {
  ZoneAttentionProvider({this.settings = AttentionSettings.lab, this.zones});
  static const providerId = 'zones-1';

  final AttentionSettings settings;

  /// Zone layout to use instead of the defaults (mirror calibration).
  ZoneMap? zones;

  AttentionPipeline? _pipeline;
  AttentionFrame? _last;

  /// Set by the caller from the ТЗ automata after each frame (a sign or an
  /// event is present); distraction does not start meanwhile.
  bool tzSignActive = false;

  /// Set by the caller after each frame: the eyes channel has an active
  /// event (`snapshot.eyes.activeEvent != null`); latches the eye gate open.
  bool eyesEventActive = false;

  AttentionPipeline? get pipeline => _pipeline;

  /// The profile to create `ObservationEngine` with after [reset]: with
  /// [AttentionSettings.mountRelative] the road-frame profile (neutral 0),
  /// because [lastMeasurements] then carry road-frame angles.
  CalibrationProfile? get engineCalibration => _pipeline?.engineCalibration;

  /// Input for `ObservationEngine.process` for the latest frame, one per
  /// usable face, same order as the pipeline decided; empty before
  /// calibration or without faces.
  List<FaceMeasurement> get lastMeasurements => _last?.measurements ?? const [];

  /// The measurement when the latest frame had exactly one face.
  FaceMeasurement? get lastMeasurement {
    final m = lastMeasurements;
    return m.length == 1 ? m.single : null;
  }

  AttentionFrame? get lastFrame => _last;

  @override
  String get id => '$providerId${settings.isAcceptance ? '' : '+ext'}';

  @override
  void reset(CalibrationProfile? calibration) {
    _last = null;
    tzSignActive = false;
    eyesEventActive = false;
    _pipeline = calibration == null
        ? null
        : AttentionPipeline(
            calibration: calibration,
            zones: zones,
            settings: settings,
          );
  }

  /// Call right after [reset] with the last calibration frame of the driver
  /// (or a face with the median box and distance of the calibration) and its
  /// time, so that a face lost right after the start is still the driver.
  void anchorDriver(FaceSignals face, int atUs) =>
      _pipeline?.anchorDriver(face, atUs);

  @override
  AttentionState update(FaceSignals? signals, int atUs) =>
      updateFaces([?signals], atUs);

  /// Processes every face the engine reported in the frame.
  AttentionState updateFaces(List<FaceSignals> faces, int atUs) {
    final pipeline = _pipeline;
    if (pipeline == null) {
      _last = null;
      return AttentionState.unknown;
    }
    final frame = pipeline.process(
      atUs,
      faces,
      tzSignActive: tzSignActive,
      eyesEventActive: eyesEventActive,
    );
    _last = frame;
    final details = frame.state.toJson()..remove('zone');
    if (frame.distractionStarted != null) {
      details['distractionStarted'] = frame.distractionStarted!.toJson();
    }
    if (frame.distractionEnded != null) {
      details['distractionEnded'] = frame.distractionEnded!.toJson();
    }
    return AttentionState(zone: frame.state.zone, details: details);
  }
}
