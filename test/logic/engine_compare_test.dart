import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/engine_compare.dart';
import 'package:nscontrol/logic/synthetic.dart';

/// The synthetic ARKit scenario plus an "ML Kit" engine on the same frames
/// (angles and eye openness only) and a `device` line per second.
String _comparison({
  double mlYawSign = 1,
  bool devices = true,
  bool scaled = false,
}) {
  final out = <String>[];
  var lastUs = 0;
  for (final line in const LineSplitter().convert(
    SyntheticScenario(SyntheticStyle.arkit).toJsonl(),
  )) {
    final json = jsonDecode(line) as Map<String, dynamic>;
    out.add(line);
    if (json['type'] == 'meta') {
      json['engines'] = ['arkit_face_tracking', 'mlkit_face_detection'];
      out[out.length - 1] = jsonEncode(json);
    }
    if (json['type'] != 'frame') continue;
    final s = json['signals'] as Map<String, dynamic>?;
    lastUs = json['capturedUs'] as int;
    out.add(
      jsonEncode({
        ...json,
        'engine': 'mlkit_face_detection',
        'completedUs': (json['completedUs'] as int) + 20000,
        if (s != null)
          'signals': {
            'engine': 'mlkit_face_detection',
            'tracked': true,
            'trackingId': s['trackingId'],
            for (final k in ['headPitchDown', 'headRollRight'])
              if (s[k] != null) k: s[k],
            if (s['headYawLeft'] != null)
              'headYawLeft': mlYawSign * (s['headYawLeft'] as num),
            for (final k in ['eyeOpenLeft', 'eyeOpenRight'])
              if (s[k] != null) k: s[k],
          },
      }),
    );
  }
  if (devices) {
    for (var t = 0; t <= lastUs; t += 1000000) {
      out.add(
        jsonEncode({
          'type': 'device',
          'atUs': t,
          'thermal': t < lastUs / 2 ? 'nominal' : 'fair',
          'battery': .9 - .1 * t / lastUs,
          'batteryState': 'unplugged',
          'lowPower': false,
          'light': 800.0,
          'arkitFps': 30,
          'mlKitDone': 15,
          'mlKitSkipped': 15,
          'mlKitBusyUs': 15 * 25000,
          'imageWidth': 1280,
          'imageHeight': 720,
          if (scaled) 'mlKitWidth': 640,
          if (scaled) 'mlKitHeight': 360,
        }),
      );
    }
  }
  return '${out.join('\n')}\n';
}

void main() {
  test('reports all four criteria for both engines', () {
    final report = EngineComparison(_comparison()).report();
    expect(report, contains('## 1. Положительные эпизоды'));
    expect(report, contains('## 2. Ложное «глаза закрыты»'));
    expect(report, contains('## 3. Рабочий диапазон поворота'));
    expect(report, contains('## 4. Производительность'));
    expect(report, contains('**arkit_face_tracking**'));
    expect(report, contains('**mlkit_face_detection**'));
    // The synthetic ARKit signals find every positive episode.
    final arkitRow = report
        .split('\n')
        .firstWhere((l) => l.startsWith('| arkit_face_tracking | приёмка |'));
    expect(arkitRow, contains('| 2 из 2 | 1 из 1 |'));
    // Signs: mirrors turn the head the expected way for both engines.
    final mirror = report
        .split('## Знаки')
        .last
        .split('\n')
        .firstWhere((l) => l.startsWith('| mirror_left |'));
    expect('✓'.allMatches(mirror).length, 2);
    // Same frames, same numbers.
    final yaw = report
        .split('\n')
        .firstWhere((l) => l.startsWith('| headYawLeft |'));
    expect(yaw, startsWith('| headYawLeft | 1,00 |'));
    expect(report, contains('Тепловое состояние iOS: nominal'));
    expect(report, contains('Заряд: 90 % → 80 %'));
    expect(report, contains('ML Kit в режиме сравнения анализирует 1280×720'));
    expect(report, contains('Поле зрения разное'));
    expect(report, contains('Разрешения заметно разные (в 3,0 раза'));
    // Both replay modes for criteria 1 and 2.
    expect(report, contains('| arkit_face_tracking | приёмка |'));
    expect(report, contains('| arkit_face_tracking | затвор глаз |'));
    final instruments = report
        .split('## 2.')
        .last
        .split('\n')
        .firstWhere((l) => l.startsWith('| instruments |'));
    expect(RegExp(r'· \d+ / \d+').allMatches(instruments).length, 2);
    expect(report, contains('Оба глаза (ФТ-04 требует оба) надёжны до'));
    expect(report, contains('## Крепление'));
    expect(report, contains('mount в meta: не записан'));
    expect(report, contains('ML Kit на кадрах ARKit: проанализировано'));
    expect(report, contains('Мин. за окно 60 с'));
  });

  test('counts completed analyses per consecutive minute', () {
    expect(EngineComparison.perMinute([]), isEmpty);
    expect(EngineComparison.perMinute([0, 59000000]), isEmpty);
    final every100ms = [for (var t = 0; t <= 150000000; t += 100000) t];
    expect(EngineComparison.perMinute(every100ms), [600, 600]);
    final gap = every100ms.where((t) => t < 30000000 || t >= 31000000);
    expect(EngineComparison.perMinute(gap.toList()), [590, 600]);
  });

  test('side mount: yaw to the camera and the far eye', () {
    // The phone on the right air vent: every pose is 30° more to the left
    // of the camera, and beyond 40° the far (left) eye reads as closed.
    final lines = <String>[];
    for (final line in const LineSplitter().convert(
      SyntheticScenario(SyntheticStyle.arkit).toJsonl(),
    )) {
      final json = jsonDecode(line) as Map<String, dynamic>;
      if (json['type'] == 'meta') json['mount'] = 'vent_right';
      final s = json['signals'] as Map<String, dynamic>?;
      if (json['type'] == 'frame' && s != null && s['headYawLeft'] != null) {
        final yaw = (s['headYawLeft'] as num) + 30;
        s['headYawLeft'] = yaw;
        if (yaw > 40 && s['eyeOpenLeft'] != null) s['eyeOpenLeft'] = .1;
      }
      if (json['type'] == 'calibration') {
        final profile = json['profile'] as Map<String, dynamic>?;
        if (profile != null && profile['neutralYaw'] is num) {
          profile['neutralYaw'] = (profile['neutralYaw'] as num) + 30;
          // The lab records with a 45° eye limit (lab mode).
          (profile['detector'] as Map<String, dynamic>)['eyeYawLimit'] = 45;
        }
      }
      lines.add(jsonEncode(json));
    }
    final report = EngineComparison('${lines.join('\n')}\n').report();
    expect(report, contains('mount в meta: vent_right'));
    final road = report
        .split('\n')
        .firstWhere(
          (l) => l.startsWith('| arkit_face_tracking | ') && l.contains('°'),
        );
    expect(road, contains('| 34,0° |'));
    expect(report, contains('дальний — до ≈ 40° (граница'));
    // The near eye never fails: its limit is where the data ends.
    expect(
      RegExp(
        r'Ближний глаз надёжен до ≈ \d+° и дальше не проверен',
      ).hasMatch(report),
      isTrue,
    );
    expect(report, isNot(contains('Ближний глаз надёжен до ≈ 40°')));
    expect(report, contains('надёжны до |поворот к камере| ≈ 40°'));
  });

  test('swapping one engine\'s eyes', () {
    final report = EngineComparison(
      _comparison(),
      swapEyes: const {'mlkit_face_detection'},
    ).report();
    expect(
      report,
      contains('переставлены перед сравнением у: mlkit_face_detection'),
    );
    final line = EngineComparison.swapEyesOf(
      '{"type":"frame","engine":"e","signals":{"eyeOpenLeft":0.1,'
      '"eyeOpenRight":0.9,"blendshapes":{"eyeBlinkLeft":0.9}}}\n'
      '{"type":"frame","engine":"other","signals":{"eyeOpenLeft":0.1}}',
      const {'e'},
    ).split('\n');
    final s = (jsonDecode(line[0]) as Map)['signals'] as Map;
    expect(s['eyeOpenLeft'], .9);
    expect(s['eyeOpenRight'], .1);
    expect(s['blendshapes'], {'eyeBlinkRight': .9});
    expect(line[1], contains('"eyeOpenLeft":0.1'));
  });

  test('a scaled ML Kit frame is compared by its own size', () {
    final report = EngineComparison(_comparison(scaled: true)).report();
    expect(report, contains('Кадр ARKit: 1280×720; ML Kit'));
    expect(report, contains('анализирует 640×360'));
    expect(report, isNot(contains('Разрешения заметно разные')));
    expect(report, contains('Поле зрения разное'));
  });

  test('flags an engine whose yaw sign is inverted', () {
    final report = EngineComparison(_comparison(mlYawSign: -1)).report();
    final mirror = report
        .split('## Знаки')
        .last
        .split('\n')
        .firstWhere((l) => l.startsWith('| mirror_left |'));
    expect(mirror, contains('✗ знак обратный'));
    expect(report, contains('(знаки противоположны)'));
  });

  test('a single-engine recording without device lines still reports', () {
    final report = EngineComparison(
      SyntheticScenario(SyntheticStyle.mlKit).toJsonl(),
    ).report();
    expect(report, contains('Строк device нет'));
    expect(report, isNot(contains('Согласие движков')));
  });

  test('reads the comparison mode as the iPhone writes it', () {
    final report = EngineComparison(
      SyntheticScenario(SyntheticStyle.arkitMlKit).toJsonl(),
    ).report();
    expect(report, isNot(contains('ошибка:')));
    // Table layout may change; the calibration source per engine may not.
    expect(
      RegExp(
        r'\| arkit_face_tracking \|[^\n]*строка calibration записи',
      ).hasMatch(report),
      isTrue,
    );
    expect(
      RegExp(r'\| mlkit_face_detection \|[^\n]*пересчитана').hasMatch(report),
      isTrue,
    );
    // ARKit at 60 fps, ML Kit on every fourth frame: both above КЧ-05.
    expect(report, contains('ниже 600: 0)'));
    expect(report, contains('ML Kit на кадрах ARKit'));
    expect(report, contains('Согласие движков на одних кадрах'));
  });
}
