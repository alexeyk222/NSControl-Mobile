import 'dart:convert';
import 'dart:math' as math;

import 'attention_zones.dart';
import 'calibration.dart';
import 'replay.dart';
import 'signals.dart';

/// Engine comparison on one recording, by the four criteria of the plan
/// («Инструменты: как выбираем»):
/// 1. share of positive episodes found (ТЗ automata, via [ReplayRunner]);
/// 2. false "eyes closed" when looking at instruments, mirrors, squinting
///    (events and closed frames per step);
/// 3. head yaw range in which eyelids stay reliable;
/// 4. analyses per second, latency, heat and battery (`device` lines).
/// Plus the sign checks of `signs-v1` and, for comparison recordings, the
/// agreement of both engines on the same frames.
class EngineComparison {
  EngineComparison(this.text) : recording = Recording.parse(text) {
    for (final line in const LineSplitter().convert(text)) {
      if (!line.contains('"device"')) continue;
      try {
        final json = jsonDecode(line);
        if (json is Map<String, dynamic> &&
            json['type'] == 'device' &&
            json['atUs'] is num) {
          devices.add(json);
        }
      } on FormatException {
        continue;
      }
    }
  }

  final String text;
  final Recording recording;
  final List<Map<String, dynamic>> devices = [];

  /// Steps where closed or narrowed eyes are expected, left out of the
  /// "false closure" statistics.
  static const closingSteps = {
    'eyes_closed_1s',
    'eyes_closed_2s',
    'eyes_closed_3s',
    'squint',
    'laugh',
    'yawn',
    'sign_wink_left',
  };

  /// Steps for criterion 2: eyes open, but the lid may look lowered.
  static const lidSteps = {
    'instruments',
    'mirror_left',
    'mirror_right',
    'mirror_rear',
    'squint',
    'talk',
    'laugh',
    'yawn',
    'intersection_scan',
    'blind_spot_left',
    'blind_spot_right',
    'nod',
    'road',
  };

  /// Steps for criterion 3: the head turns, the eyes stay open and are not
  /// looking down.
  static const yawSteps = {
    'road',
    'mirror_left',
    'mirror_right',
    'mirror_rear',
    'blind_spot_left',
    'blind_spot_right',
    'intersection_scan',
    'talk',
    'sign_head_left',
  };

  /// Closures shorter than this are blinks (plan: blinks < 0.4 s) and are
  /// not counted as false "eyes closed".
  static const blinkUs = 400000;

  /// A bin is reliable when false closures stay at or below this share.
  static const reliableFalseClosed = .02;
  static const minBinFrames = 30;

  /// Criterion 3 bins: 5° of yaw to the camera, the last one open-ended.
  static const yawBin = 5, yawBins = 13;

  late final List<Episode> episodes = Episode.fromLabels(recording.labels);

  Episode? _episodeAt(int atUs) {
    for (final e in episodes) {
      if (atUs >= e.startUs && atUs <= e.endUs) return e;
    }
    return null;
  }

  /// Replay modes for criteria 1 and 2: the ТЗ acceptance mode, and the
  /// gaze-aware eye gate without distraction — the candidate for the change
  /// request (decision of 28.11).
  static const gatedEyes = AttentionSettings(gazeAwareEyes: true);

  Map<String, ReplayResult?> _replays = const {};
  Map<String, ReplayResult?> _gated = const {};
  Map<String, String> _replayErrors = const {};

  void _runReplays() {
    final results = <String, ReplayResult?>{};
    final gated = <String, ReplayResult?>{};
    final errors = <String, String>{};
    for (final engine in recording.engines) {
      try {
        results[engine] = ReplayRunner(
          recording,
        ).run(ReplayOptions(engine: engine));
        gated[engine] = ReplayRunner(
          recording,
        ).run(ReplayOptions(engine: engine, attention: gatedEyes));
      } catch (error) {
        results[engine] = null;
        gated[engine] = null;
        errors[engine] = '$error';
      }
    }
    _replays = results;
    _gated = gated;
    _replayErrors = errors;
  }

  String report() {
    _runReplays();
    final b = StringBuffer();
    final meta = recording.meta;
    b.writeln('# Сравнение движков: запись ${recording.id}');
    b.writeln();
    b.writeln(
      '- Устройство ${meta['device'] ?? '—'}, ${meta['os'] ?? '—'}; '
      'движки: ${recording.engines.join(', ')}; кадров '
      '${recording.frames.length}, шагов ${episodes.length}, строк device '
      '${devices.length}.',
    );
    b.writeln(
      '- Эталон — метки сценария (момент подсказки), а не детектор. '
      'Порог T и нейтральные углы — из калибровки каждого движка '
      '(из записи или пересчитанные по первым 10 с).',
    );
    _mount(b);
    _criterion1(b);
    _criterion2(b);
    _criterion3(b);
    _criterion4(b);
    _signs(b);
    _agreement(b);
    return b.toString();
  }

  /// Where the phone stands: the `mount` field of meta and the median head
  /// pose to the camera while the driver looks at the road.
  void _mount(StringBuffer b) {
    b.writeln();
    b.writeln('## Крепление');
    b.writeln();
    final mount = recording.meta['mount'];
    b.writeln(
      '- mount в meta: '
      '${mount == null ? 'не записан' : (mount is String ? mount : jsonEncode(mount))}.',
    );
    b.writeln(
      '- Медианы на шаге road относительно камеры. Поворот > 0 — голова '
      'повёрнута влево от оси камеры, то есть телефон справа от водителя; '
      '< 0 — слева.',
    );
    b.writeln();
    b.writeln(
      '| Движок | Кадров | Поворот к камере | Наклон вниз | Крен вправо | '
      'Расстояние, м | Калибровка: поворот / наклон |',
    );
    b.writeln('|---|---|---|---|---|---|---|');
    for (final engine in recording.engines) {
      final road = [
        for (final f in recording.frames)
          if (f.engine == engine &&
              f.signals != null &&
              f.signals!.tracked &&
              _episodeAt(f.capturedUs)?.step == 'road')
            f.signals!,
      ];
      double? median(double? Function(FaceSignals s) v) {
        final values = [for (final s in road) ?v(s)]..sort();
        return _quantile(values, .5);
      }

      final p = _replays[engine]?.profile;
      b.writeln(
        '| $engine | ${road.length} | ${_f(median((s) => s.headYawLeft), 1)}° | '
        '${_f(median((s) => s.headPitchDown), 1)}° | '
        '${_f(median((s) => s.headRollRight), 1)}° | '
        '${_f(median((s) => s.distanceM), 2)} | '
        '${p == null ? '—' : '${_f(p.neutralYaw, 1)}° / ${_f(p.neutralPitch, 1)}°'} |',
      );
    }
  }

  // 1 and 2: events from the ТЗ automata, in both modes.
  void _criterion1(StringBuffer b) {
    b.writeln();
    b.writeln('## 1. Положительные эпизоды (автоматы ТЗ)');
    b.writeln();
    b.writeln(
      'Два режима: «приёмка» — как в ТЗ; «затвор глаз» — '
      'AttentionSettings(gazeAwareEyes: true), без отвлечения: веко, опущенное '
      'взглядом вниз или прищуром, не копит отсчёт eyes_closed. Пороги ТЗ '
      'одинаковые.',
    );
    b.writeln();
    b.writeln(
      '| Движок | Режим | Калибровка | eyes_closed найдено | '
      'head_pitch_down найдено | Пограничные | Позже допуска | Ложные тревоги |',
    );
    b.writeln('|---|---|---|---|---|---|---|---|');
    for (final engine in recording.engines) {
      for (final (mode, r) in [
        ('приёмка', _replays[engine]),
        ('затвор глаз', _gated[engine]),
      ]) {
        if (r == null) {
          b.writeln(
            '| $engine | $mode | ошибка: ${_replayErrors[engine]} | | | | | |',
          );
          continue;
        }
        String score(String type) {
          final s = r.scores[type];
          if (s == null || s.tp + s.fn == 0) return '—';
          return '${s.tp} из ${s.tp + s.fn}';
        }

        b.writeln(
          '| $engine | $mode | ${r.calibrationSource}, T = '
          '${_f(r.profile.eyeThreshold, 2)} | '
          '${score(ScenarioExpectations.eyesClosed)} | '
          '${score(ScenarioExpectations.headPitchDown)} | ${r.borderline} | '
          '${r.late} | ${r.falseAlarms} |',
        );
      }
    }
  }

  static int _eyeAlarms(ReplayResult r, String step) {
    var alarms = 0;
    for (final e in r.episodes.where((e) => e.episode.step == step)) {
      alarms += [
        ...e.unexpected,
        ...e.allowed,
        ...e.duplicates,
      ].where((x) => x.type == ScenarioExpectations.eyesClosed).length;
    }
    return alarms;
  }

  void _criterion2(StringBuffer b) {
    b.writeln();
    b.writeln('## 2. Ложное «глаза закрыты»: приборы, зеркала, прищур');
    b.writeln();
    b.writeln(
      'В ячейке: доля кадров шага, где оба глаза ниже T, затем тревоги '
      'eyes_closed внутри шага в режиме приёмки / с затвором глаз. Прищур, '
      'смех и зевок не ошибка детектора, но тревоги на них быть не должно.',
    );
    b.writeln();
    final engines = recording.engines;
    b.writeln(
      '| Шаг | ${engines.map((e) => '$e: кадры < T · тревоги').join(' | ')} |',
    );
    b.writeln('|---|${engines.map((_) => '---').join('|')}|');
    final steps = <String>{
      for (final e in episodes)
        if (lidSteps.contains(e.step)) e.step,
    }.toList()..sort();
    for (final step in steps) {
      final cells = <String>[];
      for (final engine in engines) {
        final r = _replays[engine], g = _gated[engine];
        if (r == null) {
          cells.add('—');
          continue;
        }
        var frames = 0, closed = 0;
        for (final e in r.episodes.where((e) => e.episode.step == step)) {
          frames += e.frames;
          closed += e.closedFrames;
        }
        final gated = g == null ? '—' : '${_eyeAlarms(g, step)}';
        cells.add('${_pct(closed, frames)} · ${_eyeAlarms(r, step)} / $gated');
      }
      b.writeln('| $step | ${cells.join(' | ')} |');
    }
  }

  // 3: yaw to the camera, per eye.
  void _criterion3(StringBuffer b) {
    b.writeln();
    b.writeln('## 3. Рабочий диапазон поворота головы для век');
    b.writeln();
    b.writeln(
      'Кадры шагов, где глаза открыты и не смотрят вниз (дорога, зеркала, '
      'слепые зоны, перекрёсток, разговор), по модулю поворота головы '
      '**к камере** (headYawLeft как есть, без вычета калибровки): так '
      'проверяет предел глаз ObservationEngine. Ближний глаз — тот, что '
      'повёрнут к камере, дальний — тот, что уходит за нос (поворот влево → '
      'дальний левый). «Оценён» — доля кадров с лицом, где у глаза есть '
      'значение; «ложно < T» — глаз ниже T дольше моргания '
      '(${blinkUs ~/ 1000} мс). Надёжная полоса: оценён не меньше 90 %, ложных '
      'закрытий не больше ${_pctValue(reliableFalseClosed)}, кадров не меньше '
      '$minBinFrames; полосы, где кадров меньше, пропускаются.',
    );
    for (final engine in recording.engines) {
      final r = _replays[engine];
      if (r == null) continue;
      final t = r.profile.eyeThreshold;
      final frames = recording.frames.where((f) => f.engine == engine).toList();
      final longLeft = _longRuns(frames, t, (s) => s.eyeOpenLeft);
      final longRight = _longRuns(frames, t, (s) => s.eyeOpenRight);
      final bins = <int, _EyeBin>{};
      var lost = 0;
      for (final f in frames) {
        final episode = _episodeAt(f.capturedUs);
        if (episode == null || !yawSteps.contains(episode.step)) continue;
        final s = f.signals;
        final yaw = s?.headYawLeft;
        if (f.faceCount == 0 || s == null || yaw == null || !s.tracked) {
          lost++;
          continue;
        }
        final bin = bins[(yaw.abs() ~/ yawBin).clamp(0, yawBins - 1)] ??=
            _EyeBin();
        bin.faces++;
        if (yaw >= 0) bin.towardLeft++;
        // Turned left: the left eye goes behind the nose.
        final farLeft = yaw >= 0;
        final far = farLeft ? s.eyeOpenLeft : s.eyeOpenRight;
        final near = farLeft ? s.eyeOpenRight : s.eyeOpenLeft;
        final farLong = (farLeft ? longLeft : longRight).contains(f.capturedUs);
        final nearLong = (farLeft ? longRight : longLeft).contains(
          f.capturedUs,
        );
        if (near != null) {
          bin.near.eyes++;
          if (nearLong) bin.near.falseClosed++;
        }
        if (far != null) {
          bin.far.eyes++;
          if (farLong) bin.far.falseClosed++;
        }
      }
      b.writeln();
      b.writeln('**$engine** (T = ${_f(t, 2)}):');
      b.writeln();
      b.writeln(
        '| Поворот к камере | Кадров с лицом | Влево | '
        'Ближний: оценён · ложно < T | Дальний: оценён · ложно < T |',
      );
      b.writeln('|---|---|---|---|---|');
      double? nearLimit, farLimit;
      var nearBroken = false, farBroken = false;
      for (var i = 0; i < yawBins; i++) {
        final bin = bins[i];
        if (bin == null) continue;
        final label = i == yawBins - 1
            ? '≥ ${i * yawBin}°'
            : '${i * yawBin}–${(i + 1) * yawBin}°';
        String eye(_Eye e) =>
            '${_pct(e.eyes, bin.faces)} · ${_pct(e.falseClosed, e.eyes)}';
        b.writeln(
          '| $label | ${bin.faces} | ${_pct(bin.towardLeft, bin.faces)} | '
          '${eye(bin.near)} | ${eye(bin.far)} |',
        );
        bool ok(_Eye e) =>
            e.eyes >= minBinFrames &&
            e.eyes >= .9 * bin.faces &&
            e.falseClosed <= reliableFalseClosed * e.eyes;
        if (bin.faces >= minBinFrames) {
          if (!nearBroken && ok(bin.near)) {
            nearLimit = (i + 1) * yawBin.toDouble();
          } else {
            nearBroken = true;
          }
          if (!farBroken && ok(bin.far)) {
            farLimit = (i + 1) * yawBin.toDouble();
          } else {
            farBroken = true;
          }
        }
      }
      if (lost > 0) b.writeln('| без лица | $lost | — | — | — |');
      b.writeln();
      String limit(double? v) => v == null ? 'не набралось' : '≈ ${_f(v, 0)}°';
      b.writeln(
        '- Ближний глаз надёжен до ${limit(nearLimit)}, дальний — до '
        '${limit(farLimit)} (граница полосы $yawBin°).',
      );
      final both = nearLimit == null || farLimit == null
          ? null
          : math.min(nearLimit, farLimit);
      b.writeln(
        both == null
            ? '- Оба глаза (ФТ-04 требует оба): полосы не набралось — мало '
                  'кадров или много ложных закрытий.'
            : '- Оба глаза (ФТ-04 требует оба) надёжны до |поворот к камере| '
                  '≈ ${_f(both, 0)}°. Для eyeYawLimit взять с запасом и '
                  'проверить на второй записи.',
      );
    }
  }

  /// capturedUs of frames inside runs where [value] stays below [t] for at
  /// least [blinkUs].
  static Set<int> _longRuns(
    List<RecordedFrame> frames,
    double? t,
    double? Function(FaceSignals s) value,
  ) {
    final result = <int>{};
    if (t == null) return result;
    final run = <int>[];
    void flush() {
      if (run.length > 1 && run.last - run.first >= blinkUs) result.addAll(run);
      run.clear();
    }

    for (final f in frames) {
      final s = f.signals;
      final v = s == null || !s.tracked ? null : value(s);
      if (v != null && v < t) {
        run.add(f.capturedUs);
      } else {
        flush();
      }
    }
    flush();
    return result;
  }

  /// Completed analyses in each consecutive 60 s window from the first
  /// completion (КЧ-05 counts completions, a frame without a face included);
  /// a trailing partial window is left out.
  static List<int> perMinute(List<int> completedUs) {
    if (completedUs.isEmpty) return const [];
    final sorted = [...completedUs]..sort();
    final start = sorted.first;
    final full = (sorted.last - start) ~/ 60000000;
    final counts = List.filled(full, 0);
    for (final t in sorted) {
      final i = (t - start) ~/ 60000000;
      if (i < full) counts[i]++;
    }
    return counts;
  }

  // 4: throughput and device.
  void _criterion4(StringBuffer b) {
    b.writeln();
    b.writeln('## 4. Производительность, нагрев, заряд');
    b.writeln();
    b.writeln(
      '| Движок | Анализов в секунду | Мин. за окно 60 с (КЧ-05: ≥ 600) | '
      'Задержка p50 / p95, мс | Кадров без лица |',
    );
    b.writeln('|---|---|---|---|---|');
    for (final engine in recording.engines) {
      final frames = recording.frames.where((f) => f.engine == engine).toList();
      if (frames.length < 2) continue;
      final span = frames.last.capturedUs - frames.first.capturedUs;
      final rate = span > 0 ? (frames.length - 1) * 1e6 / span : null;
      final latency = [
        for (final f in frames) (f.completedUs - f.capturedUs) / 1000,
      ]..sort();
      final noFace = frames.where((f) => f.faceCount == 0).length;
      final windows = perMinute([for (final f in frames) f.completedUs]);
      final minute = windows.isEmpty
          ? 'запись < 60 с'
          : '${windows.reduce(math.min)} (окон ${windows.length}, '
                'ниже 600: ${windows.where((n) => n < 600).length})';
      b.writeln(
        '| $engine | ${_f(rate, 1)} | $minute | '
        '${_f(_quantile(latency, .5), 0)} / '
        '${_f(_quantile(latency, .95), 0)} | ${_pct(noFace, frames.length)} |',
      );
    }
    b.writeln();
    b.writeln(
      '- Минимум за окно 60 с — предварительная оценка: на приёмке КЧ-05 '
      'меряется на часовом прогоне release без отладчика.',
    );
    if (devices.isEmpty) {
      b.writeln();
      b.writeln('- Строк device нет: нагрев и заряд не записаны.');
      return;
    }
    final first = devices.first, last = devices.last;
    final spanUs =
        (last['atUs'] as num).toInt() - (first['atUs'] as num).toInt();
    final thermal = <String, int>{};
    for (var i = 0; i < devices.length; i++) {
      final state = devices[i]['thermal'] as String? ?? 'unknown';
      final next = i + 1 < devices.length
          ? (devices[i + 1]['atUs'] as num).toInt()
          : (devices[i]['atUs'] as num).toInt();
      thermal[state] =
          (thermal[state] ?? 0) + next - (devices[i]['atUs'] as num).toInt();
    }
    final b0 = (first['battery'] as num?)?.toDouble();
    final b1 = (last['battery'] as num?)?.toDouble();
    final fps = [
      for (final d in devices)
        if (d['arkitFps'] is num) (d['arkitFps'] as num).toDouble(),
    ]..sort();
    final light = [
      for (final d in devices)
        if (d['light'] is num) (d['light'] as num).toDouble(),
    ]..sort();
    final busy = devices.fold<int>(
      0,
      (s, d) => s + ((d['mlKitBusyUs'] as num?)?.toInt() ?? 0),
    );
    final done = devices.fold<int>(
      0,
      (s, d) => s + ((d['mlKitDone'] as num?)?.toInt() ?? 0),
    );
    final skipped = devices.fold<int>(
      0,
      (s, d) => s + ((d['mlKitSkipped'] as num?)?.toInt() ?? 0),
    );
    b.writeln();
    b.writeln('- Длительность по строкам device: ${_minutes(spanUs)} мин.');
    b.writeln(
      '- Тепловое состояние iOS: ${thermal.entries.map((e) => '${e.key} ${_minutes(e.value)} мин').join(', ')}.',
    );
    if (b0 != null && b1 != null && spanUs > 0) {
      final drop = (b0 - b1) * 100;
      b.writeln(
        '- Заряд: ${_f(b0 * 100, 0)} % → ${_f(b1 * 100, 0)} %, '
        '${_f(drop, 1)} п. п.${spanUs >= 600e6 ? '; в пересчёте на 20 минут ${_f(drop * 1200e6 / spanUs, 1)} п. п.' : ''} '
        '(iOS отдаёт заряд шагами по 1–5 %, поэтому мерить на записи не '
        'короче 20 минут и без зарядки).',
      );
    }
    final charging = devices.any(
      (d) => d['batteryState'] == 'charging' || d['batteryState'] == 'full',
    );
    if (charging) b.writeln('- Внимание: часть записи телефон заряжался.');
    if (fps.isNotEmpty) {
      b.writeln(
        '- Кадров ARKit в секунду: медиана ${_f(_quantile(fps, .5), 0)}, '
        'минимум ${_f(fps.first, 0)}.',
      );
    }
    if (done + skipped > 0) {
      b.writeln(
        '- ML Kit на кадрах ARKit: проанализировано $done, пропущено $skipped '
        '(занят), среднее время анализа ${_f(done == 0 ? null : busy / done / 1000, 0)} мс.',
      );
    }
    _resolution(b);
    if (light.isNotEmpty) {
      b.writeln(
        '- Освещённость ARKit (ambientIntensity, 1000 ≈ норма): медиана '
        '${_f(_quantile(light, .5), 0)}, минимум ${_f(light.first, 0)}.',
      );
    }
  }

  /// The camera plugin path of ML Kit (`CameraService`,
  /// `ResolutionPreset.medium`) delivers 640×480 frames on iOS.
  static const cameraPluginPixels = 640 * 480;

  void _resolution(StringBuffer b) {
    (int, int)? size(String w, String h) {
      for (final d in devices) {
        if (d[w] is num && d[h] is num) {
          return ((d[w] as num).toInt(), (d[h] as num).toInt());
        }
      }
      return null;
    }

    final arkit = size('imageWidth', 'imageHeight');
    final mlKit = size('mlKitWidth', 'mlKitHeight') ?? arkit;
    if (mlKit == null) {
      b.writeln(
        '- Размер кадра ARKit и ML Kit в записи не указан (нет imageWidth и '
        'mlKitWidth в строках device).',
      );
      return;
    }
    final (w, h) = mlKit;
    final ratio = w * h / cameraPluginPixels;
    b.writeln(
      '- Кадр ARKit: ${arkit == null ? '—' : '${arkit.$1}×${arkit.$2}'}; ML Kit '
      'в режиме сравнения анализирует $w×$h. Обычный путь ML Kit через '
      'плагин camera (ResolutionPreset.medium) получает 640×480.',
    );
    if (ratio > 1.5 || ratio < 1 / 1.5) {
      b.writeln(
        '- **Разрешения заметно разные (в ${_f(ratio >= 1 ? ratio : 1 / ratio, 1)} '
        'раза по числу пикселей): сравнение ML Kit с ARKit на кадрах ARKit не '
        'полностью повторяет обычный путь ML Kit. Для честного вывода нужен '
        'короткий прогон ML Kit через плагин camera.**',
      );
    }
    if ((w / h - 4 / 3).abs() > .05) {
      b.writeln(
        '- Поле зрения разное: кадр ARKit ${_f(w / h, 2)}:1 (16:9), у плагина '
        'camera 4:3. Лицо занимает другую долю кадра, поэтому ML Kit через '
        'обычный путь проверяется отдельно (signs-v1).',
      );
    }
  }

  // Sign checks: step, expectation, value, expected direction.
  static const _signChecks =
      <
        (
          String,
          String,
          double? Function(FaceSignals, CalibrationProfile),
          bool,
        )
      >[
        ('sign_head_left', 'headYawLeft > 0', _yaw, true),
        ('mirror_left', 'headYawLeft > 0', _yaw, true),
        ('mirror_right', 'headYawLeft < 0', _yaw, false),
        ('sign_head_down', 'headPitchDown > 0', _pitch, true),
        ('sign_roll_right', 'headRollRight > 0', _roll, true),
        ('sign_eyes_left', 'eyeGazeLeft > 0', _eyeLeft, true),
        ('sign_eyes_down', 'eyeGazeDown > 0', _eyeDown, true),
        ('sign_wink_left', 'eyeOpenLeft < eyeOpenRight', _wink, false),
      ];
  static double? _minus(double? a, double? b) =>
      a == null || b == null ? null : a - b;
  static double? _yaw(FaceSignals s, CalibrationProfile p) =>
      _minus(s.headYawLeft, p.neutralYaw);
  static double? _pitch(FaceSignals s, CalibrationProfile p) =>
      _minus(s.headPitchDown, p.neutralPitch);
  static double? _roll(FaceSignals s, CalibrationProfile p) =>
      _minus(s.headRollRight, p.neutralRoll);
  static double? _eyeLeft(FaceSignals s, CalibrationProfile p) => s.eyeGazeLeft;
  static double? _eyeDown(FaceSignals s, CalibrationProfile p) => s.eyeGazeDown;
  static double? _wink(FaceSignals s, CalibrationProfile p) =>
      _minus(s.eyeOpenLeft, s.eyeOpenRight);

  void _signs(StringBuffer b) {
    final present = {for (final e in episodes) e.step};
    final checks = _signChecks.where((c) => present.contains(c.$1)).toList();
    if (checks.isEmpty) return;
    b.writeln();
    b.writeln('## Знаки');
    b.writeln();
    b.writeln(
      'Медиана величины во второй половине шага (первая половина — реакция '
      'на подсказку), относительно калибровки для углов головы. '
      'Порог уверенности: 5° для углов, 0,2 для век.',
    );
    b.writeln();
    final engines = recording.engines;
    b.writeln('| Шаг | Ожидание | ${engines.join(' | ')} |');
    b.writeln('|---|---|${engines.map((_) => '---').join('|')}|');
    for (final (step, expectation, value, positive) in checks) {
      final cells = <String>[];
      for (final engine in engines) {
        final r = _replays[engine];
        if (r == null) {
          cells.add('—');
          continue;
        }
        final values = <double>[];
        for (final e in episodes.where((e) => e.step == step && !e.aborted)) {
          final mid = (e.startUs + e.endUs) ~/ 2;
          for (final f in recording.frames) {
            if (f.engine != engine ||
                f.capturedUs < mid ||
                f.capturedUs > e.endUs) {
              continue;
            }
            final s = f.signals;
            if (s == null || !s.tracked) continue;
            final v = value(s, r.profile);
            if (v != null && v.isFinite) values.add(v);
          }
        }
        if (values.isEmpty) {
          cells.add('нет данных');
          continue;
        }
        final m = median(values);
        final margin = step == 'sign_wink_left' ? .2 : 5.0;
        final ok = positive ? m > margin : m < -margin;
        final wrong = positive ? m < -margin : m > margin;
        final verdict = ok
            ? '✓'
            : (wrong ? '✗ знак обратный' : '? слабый сигнал');
        cells.add('${_f(m, step == 'sign_wink_left' ? 2 : 1)} $verdict');
      }
      b.writeln('| $step | $expectation | ${cells.join(' | ')} |');
    }
  }

  // Agreement on the same frames.
  void _agreement(StringBuffer b) {
    final engines = recording.engines;
    if (engines.length < 2) return;
    final a = engines[0], c = engines[1];
    final byTime = <int, Map<String, RecordedFrame>>{};
    for (final f in recording.frames) {
      if (f.engine == a || f.engine == c) {
        (byTime[f.capturedUs] ??= {})[f.engine] = f;
      }
    }
    final pairs = byTime.values
        .where((m) => m.length == 2)
        .map((m) => (m[a]!, m[c]!))
        .toList();
    b.writeln();
    b.writeln('## Согласие движков на одних кадрах ($a и $c)');
    b.writeln();
    if (pairs.isEmpty) {
      b.writeln('- Пар кадров с одинаковым capturedUs нет.');
      return;
    }
    final aFace = pairs.where((p) => _has(p.$1)).length;
    final both = pairs.where((p) => _has(p.$1) && _has(p.$2)).length;
    b.writeln(
      '- Пар кадров ${pairs.length}; лицо у $a в $aFace, у обоих в $both '
      '(${_pct(both, aFace)} кадров $a).',
    );
    b.writeln();
    b.writeln('| Величина | Корреляция | Медиана |разницы| | Пар |');
    b.writeln('|---|---|---|---|');
    for (final (name, get) in <(String, double? Function(FaceSignals))>[
      ('headYawLeft', (s) => s.headYawLeft),
      ('headPitchDown', (s) => s.headPitchDown),
      ('headRollRight', (s) => s.headRollRight),
      ('eyeOpenLeft', (s) => s.eyeOpenLeft),
      ('eyeOpenRight', (s) => s.eyeOpenRight),
    ]) {
      final xs = <double>[], ys = <double>[];
      for (final (p, q) in pairs) {
        final x = p.signals == null ? null : get(p.signals!);
        final y = q.signals == null ? null : get(q.signals!);
        if (x == null || y == null || !p.signals!.tracked) continue;
        xs.add(x);
        ys.add(y);
      }
      if (xs.length < 3) {
        b.writeln('| $name | — | — | ${xs.length} |');
        continue;
      }
      final r = _pearson(xs, ys);
      final diffs = [for (var i = 0; i < xs.length; i++) (xs[i] - ys[i]).abs()];
      final note = r != null && r < -.5 ? ' (знаки противоположны)' : '';
      b.writeln(
        '| $name | ${_f(r, 2)}$note | ${_f(median(diffs), 2)} | ${xs.length} |',
      );
    }
  }

  static bool _has(RecordedFrame f) =>
      f.faceCount > 0 && f.signals != null && f.signals!.tracked;
}

class _Eye {
  int eyes = 0, falseClosed = 0;
}

class _EyeBin {
  int faces = 0, towardLeft = 0;
  final near = _Eye(), far = _Eye();
}

double? _pearson(List<double> x, List<double> y) {
  final n = x.length;
  final mx = x.reduce((a, b) => a + b) / n, my = y.reduce((a, b) => a + b) / n;
  var sxy = 0.0, sxx = 0.0, syy = 0.0;
  for (var i = 0; i < n; i++) {
    sxy += (x[i] - mx) * (y[i] - my);
    sxx += (x[i] - mx) * (x[i] - mx);
    syy += (y[i] - my) * (y[i] - my);
  }
  if (sxx <= 0 || syy <= 0) return null;
  return sxy / math.sqrt(sxx * syy);
}

double? _quantile(List<double> sorted, double q) {
  if (sorted.isEmpty) return null;
  final i = ((sorted.length - 1) * q).round();
  return sorted[i];
}

String _f(num? v, int digits) => v == null || !v.isFinite
    ? '—'
    : v.toStringAsFixed(digits).replaceAll('.', ',');
String _pct(int part, int whole) => whole == 0 ? '—' : _pctValue(part / whole);
String _pctValue(double v) => '${_f(v * 100, 1)} %';
String _minutes(int us) => _f(us / 60e6, 1);
