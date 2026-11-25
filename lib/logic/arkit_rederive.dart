import 'dart:convert';
import 'dart:math' as math;

import 'arkit_geometry.dart';
import 'signals.dart';

/// Works on the `raw` field of ARKit frames in a recording (schema 1): the
/// bridge's matrices, gravity and blendshapes as they came from the iPhone.
///
/// - [rederive] recomputes the contract signals with other [ArkitAxes], so a
///   wrong sign is fixed without a new session.
/// - [diagnose] reports the geometry behind the angles: how the phone is
///   tilted, where the face sits relative to the optical axis, and the head
///   angles under each sign hypothesis.
class ArkitRawRecording {
  ArkitRawRecording(String jsonl)
    : lines = const LineSplitter()
          .convert(jsonl)
          .where((l) => l.trim().isNotEmpty)
          .toList();

  final List<String> lines;

  static bool _isArkitFrame(Map<String, dynamic> json) =>
      json['type'] == 'frame' &&
      json['engine'] == arkitCapabilities.id &&
      json['raw'] is Map;

  /// The face the recorded signals were taken from: same id, else the first
  /// tracked one.
  static ArkitFaceRaw? _driverFace(Map<String, dynamic> frame) {
    final raw = frame['raw'] as Map;
    final faces = [
      for (final f in (raw['faces'] as List?) ?? const [])
        ArkitFaceRaw.fromMap(Map<Object?, Object?>.from(f as Map)),
    ];
    if (faces.isEmpty) return null;
    final id = (frame['signals'] as Map?)?['trackingId'];
    for (final f in faces) {
      if (f.id == id) return f;
    }
    return faces.firstWhere((f) => f.tracked, orElse: () => faces.first);
  }

  static List<double>? _gravity(Map<String, dynamic> frame) {
    final g = (frame['raw'] as Map)['gravityUp'];
    if (g is! List || g.length != 3) return null;
    return [for (final v in g) (v as num).toDouble()];
  }

  /// The recording with every ARKit frame's signals recomputed from `raw`
  /// with [axes]; the recorded box is kept (the display size it needs is not
  /// in `raw`). The ARKit calibration line is converted to the new axes:
  /// mirroring negates every left/right quantity and swapping exchanges the
  /// eyes, both exactly. Other lines are unchanged.
  String rederive(ArkitAxes axes) {
    var recorded = ArkitAxes.standard;
    for (final line in lines) {
      if (!line.contains('"axes"')) continue;
      final json = jsonDecode(line) as Map<String, dynamic>;
      if (_isArkitFrame(json) && (json['raw'] as Map)['axes'] is Map) {
        recorded = ArkitAxes.fromJson(
          Map<String, dynamic>.from((json['raw'] as Map)['axes'] as Map),
        );
        break;
      }
    }
    final out = StringBuffer();
    for (final line in lines) {
      final json = jsonDecode(line) as Map<String, dynamic>;
      if (json['type'] == 'calibration') {
        out.writeln(jsonEncode(_calibration(json, recorded, axes)));
        continue;
      }
      if (!_isArkitFrame(json)) {
        out.writeln(line);
        continue;
      }
      final face = _driverFace(json);
      final gravity = _gravity(json);
      if (face == null || gravity == null) {
        out.writeln(line);
        continue;
      }
      final old = json['signals'] as Map<String, dynamic>?;
      final s = arkitSignals(face, gravityUp: gravity, axes: axes);
      json['signals'] = {
        ...s.toJson(),
        if (old?['box'] != null && s.tracked) 'box': old!['box'],
      };
      (json['raw'] as Map)['axes'] = axes.toJson();
      out.writeln(jsonEncode(json));
    }
    return out.toString();
  }

  static Map<String, dynamic> _calibration(
    Map<String, dynamic> json,
    ArkitAxes recorded,
    ArkitAxes axes,
  ) {
    final profile = json['profile'];
    if (profile is! Map ||
        (profile['detector'] as Map?)?['id'] != arkitCapabilities.id) {
      return json;
    }
    final mirror = recorded.mirror != axes.mirror;
    final swap = recorded.swapEyes != axes.swapEyes;
    num? neg(Object? v) => v is num ? -v : null;
    final p = Map<String, dynamic>.from(profile);
    if (mirror) {
      for (final key in ['neutralYaw', 'neutralRoll']) {
        if (p[key] is num) p[key] = neg(p[key]);
      }
    }
    if (swap) {
      final l = p['leftEyeMedian'];
      p['leftEyeMedian'] = p['rightEyeMedian'];
      p['rightEyeMedian'] = l;
    }
    final result = {...json, 'profile': p};
    final road = (json['zones'] as Map?)?['road'];
    if (mirror && road is Map) {
      result['zones'] = {
        ...(json['zones'] as Map),
        'road': {
          ...road,
          for (final key in ['headLeft', 'gazeLeft'])
            if (road[key] is num) key: neg(road[key]),
        },
      };
    }
    return result;
  }

  /// Markdown with medians over tracked ARKit frames.
  String diagnose() {
    final rows = <String, List<double>>{};
    void add(String key, double v) {
      if (v.isFinite) (rows[key] ??= []).add(v);
    }

    var frames = 0;
    const deg = 180 / math.pi;
    for (final line in lines) {
      final json = jsonDecode(line) as Map<String, dynamic>;
      if (!_isArkitFrame(json)) continue;
      final face = _driverFace(json);
      final gravity = _gravity(json);
      final pose = face?.faceInCamera;
      if (face == null || !face.tracked || gravity == null || pose == null) {
        continue;
      }
      frames++;
      final g = Vec3(gravity[0], gravity[1], gravity[2]).unit;
      final position = column(pose, 3);
      final frame = DriverFrame.from(facePosition: position, gravityUp: g);
      if (frame == null) continue;
      // Phone attitude: how far the snapped "up" axis is from gravity, and
      // whether the optical axis towards the driver points up or down.
      add(
        'Ось «вверх» камеры от гравитации, °',
        math.acos(g.dot(frame.up)) * deg,
      );
      add(
        'Ось камеры к водителю над горизонтом, °',
        math.asin(g.dot(frame.toDriver).clamp(-1.0, 1.0)) * deg,
      );
      // Where the face sits relative to the optical axis.
      final p = frame.local(position);
      add('Лицо от оси камеры: правее водителя, °', math.atan2(p.x, p.z) * deg);
      add('Лицо от оси камеры: выше, °', math.atan2(p.y, p.z) * deg);
      add('Расстояние, м', position.length);
      final standard = arkitSignals(face, gravityUp: gravity);
      final mirrored = arkitSignals(
        face,
        gravityUp: gravity,
        axes: const ArkitAxes(mirror: true),
      );
      void angles(String name, FaceSignals s) {
        if (s.headYawLeft != null) {
          add('$name: поворот влево, °', s.headYawLeft!);
        }
        if (s.headPitchDown != null) {
          add('$name: наклон вниз, °', s.headPitchDown!);
        }
        if (s.headRollRight != null) {
          add('$name: крен вправо, °', s.headRollRight!);
        }
      }

      angles('Как сейчас', standard);
      angles('mirror', mirrored);
      // Hypothesis "pitch is taken against the horizon": the face's forward
      // axis against gravity, independent of how the phone is tilted.
      final forward = column(pose, 2).unit;
      add(
        'Наклон вниз относительно горизонта, °',
        -math.asin(forward.dot(g).clamp(-1.0, 1.0)) * deg,
      );
      final l = face.blendshapes['eyeBlink_L'],
          r = face.blendshapes['eyeBlink_R'];
      if (l != null) add('eyeBlink_L', l);
      if (r != null) add('eyeBlink_R', r);
    }
    final b = StringBuffer()
      ..writeln('# ARKit raw: геометрия крепления')
      ..writeln()
      ..writeln('Кадров ARKit с отслеживаемым лицом и raw: $frames.')
      ..writeln()
      ..writeln('| Величина | Медиана | 10–90 % |')
      ..writeln('|---|---|---|');
    for (final e in rows.entries) {
      final v = e.value..sort();
      double q(double p) => v[((v.length - 1) * p).round()];
      b.writeln('| ${e.key} | ${_f(q(.5))} | ${_f(q(.1))} … ${_f(q(.9))} |');
    }
    b
      ..writeln()
      ..writeln(
        '- «Как сейчас» и «mirror» отличаются только знаком поворота и '
        'крена: если у ML Kit на тех же кадрах поворот другого знака, нужен '
        'mirror.',
      )
      ..writeln(
        '- «Наклон вниз относительно горизонта» ≈ наклон камеры + ось камеры '
        'над горизонтом. Если записанный наклон совпадает с ним, а не с '
        'наклоном к камере, в угол попал наклон телефона.',
      )
      ..writeln(
        '- Знак поворота из одной геометрии не виден: ARKit строит '
        'правильный поворот и в зеркальном пространстве. Его решает '
        'сравнение с ML Kit (знаки подтверждены на signs-v1) или шаг '
        'sign_head_left.',
      );
    return b.toString();
  }
}

String _f(double v) =>
    v.abs() >= 10 ? v.toStringAsFixed(1) : v.toStringAsFixed(2);
