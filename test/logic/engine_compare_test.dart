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
    expect(report, contains('Веки надёжны до |поворот| ≈ 60°'));
    expect(report, contains('ML Kit на кадрах ARKit: проанализировано'));
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
    expect(report, contains('ML Kit на кадрах ARKit'));
    expect(report, contains('Согласие движков на одних кадрах'));
  });
}
