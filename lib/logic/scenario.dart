/// Lab scenarios: a fixed timeline of voice prompts and step labels. The
/// labels are the reference for evaluation (the detector never is); a replay
/// matches events to the `start`/`end` labels of each step.
class ScenarioCue {
  const ScenarioCue({
    required this.atUs,
    this.say,
    this.step,
    this.edge,
    this.rep,
  });

  /// Offset from the scenario start.
  final int atUs;

  /// Voice prompt (also shown on screen).
  final String? say;

  /// Step code from docs/recognition-contract.md and the label edge
  /// (`start` / `end`); both null for a prompt without a label.
  final String? step, edge;
  final int? rep;
  bool get isLabel => step != null;
}

class Scenario {
  Scenario({required this.id, required this.title, required this.cues})
    : durationUs = cues.isEmpty ? 0 : cues.last.atUs {
    var previous = 0;
    final open = <String>{};
    for (final cue in cues) {
      if (cue.atUs < previous) throw ArgumentError('Подсказки не по порядку');
      previous = cue.atUs;
      if (!cue.isLabel) continue;
      final key = '${cue.step}#${cue.rep}';
      if (cue.edge == 'start' && !open.add(key) ||
          cue.edge == 'end' && !open.remove(key) ||
          (cue.edge != 'start' && cue.edge != 'end')) {
        throw ArgumentError('Непарная метка ${cue.step} ${cue.edge}');
      }
    }
    if (open.isNotEmpty) throw ArgumentError('Незакрытые метки: $open');
  }

  final String id, title;
  final List<ScenarioCue> cues;
  final int durationUs;

  Iterable<String> get steps =>
      cues.where((c) => c.edge == 'start').map((c) => c.step!).toSet();

  static final all = <Scenario>[benchV1(), signsV1()];
  static Scenario byId(String id) => all.firstWhere((s) => s.id == id);
}

class _Builder {
  final cues = <ScenarioCue>[];
  int t = 0;
  final _reps = <String, int>{};

  void say(String text, double seconds) {
    cues.add(ScenarioCue(atUs: t, say: text));
    wait(seconds);
  }

  void wait(double seconds) => t += (seconds * 1000000).round();

  int _rep(String step) => _reps[step] = (_reps[step] ?? 0) + 1;

  void label(String step, String edge, int rep, [String? say]) => cues.add(
    ScenarioCue(atUs: t, say: say, step: step, edge: edge, rep: rep),
  );

  /// A glance or action started by [prompt]; [back] is said after [backAt]
  /// seconds, the label closes after [window] seconds, then [rest].
  void glance(
    String step,
    String prompt, {
    double backAt = 2.5,
    double window = 3.5,
    double rest = 4,
    String back = 'Дорога',
  }) {
    final rep = _rep(step);
    label(step, 'start', rep, prompt);
    wait(backAt);
    cues.add(ScenarioCue(atUs: t, say: back));
    wait(window - backAt);
    label(step, 'end', rep);
    wait(rest);
  }

  /// Instruction, countdown, then an exactly timed hold between two cues.
  void timed(
    String step,
    String instruction,
    double seconds, {
    required String go,
    required String stop,
    double rest = 5,
  }) {
    final rep = _rep(step);
    say(instruction, 3.5);
    for (final n in ['Три', 'Два', 'Один']) {
      say(n, 1);
    }
    label(step, 'start', rep, go);
    wait(seconds);
    label(step, 'end', rep, stop);
    wait(rest);
  }

  void hold(String step, String prompt, double seconds, {double rest = 3}) {
    final rep = _rep(step);
    label(step, 'start', rep, prompt);
    wait(seconds);
    label(step, 'end', rep, 'Достаточно');
    wait(rest);
  }
}

/// About 10.5 minutes; steps and expectations as in the contract table.
Scenario benchV1() {
  final b = _Builder();
  b.say('Сценарий бенч один. Смотрите на дорогу, как за рулём.', 5);
  b.hold('road', 'Смотрите на дорогу и моргайте как обычно', 60);
  b.say('Зеркала. Посмотрите в названное зеркало и вернитесь на дорогу', 5);
  for (var i = 0; i < 5; i++) {
    b.glance('mirror_left', 'Левое зеркало');
    b.glance('mirror_right', 'Правое зеркало');
    b.glance('mirror_rear', 'Салонное зеркало');
  }
  b.say('Слепая зона. Посмотрите через плечо', 4);
  for (var i = 0; i < 3; i++) {
    b.glance('blind_spot_left', 'Через левое плечо', backAt: 3, window: 4);
    b.glance('blind_spot_right', 'Через правое плечо', backAt: 3, window: 4);
  }
  b.say('Перекрёсток. Посмотрите влево, вправо и снова влево, не спеша', 6);
  for (var i = 0; i < 3; i++) {
    b.glance('intersection_scan', 'Перекрёсток', backAt: 8, window: 9, rest: 5);
  }
  b.say('Приборы. Коротко посмотрите на спидометр', 4);
  for (var i = 0; i < 5; i++) {
    b.glance('instruments', 'Приборы', backAt: 2, window: 3);
  }
  b.say('Говорите вслух двадцать секунд, как с пассажиром', 4);
  b.hold('talk', 'Говорите', 20);
  b.say('Посмейтесь', 2);
  b.hold('laugh', 'Смейтесь', 8);
  b.say('Прищурьтесь, как от яркого солнца', 3);
  b.hold('squint', 'Прищур', 8);
  for (var i = 0; i < 3; i++) {
    b.glance('yawn', 'Зевните', backAt: 6, window: 6.5, back: 'Хорошо');
  }
  b.hold('road', 'Смотрите на дорогу', 20);
  for (final (step, words, seconds) in [
    ('eyes_closed_1s', 'одну секунду', 1.0),
    ('eyes_closed_2s', 'две секунды', 2.0),
    ('eyes_closed_3s', 'три секунды', 3.0),
  ]) {
    for (var i = 0; i < 3; i++) {
      b.timed(
        step,
        'Голову прямо. Закройте глаза на $words',
        seconds,
        go: 'Закрыть',
        stop: 'Открыть',
      );
    }
  }
  for (var i = 0; i < 3; i++) {
    b.timed(
      'head_down_3s',
      'Опустите голову, подбородок к груди, на три секунды',
      3,
      go: 'Вниз',
      stop: 'Вверх',
    );
  }
  for (var i = 0; i < 3; i++) {
    b.glance('nod', 'Кивните', backAt: 2, window: 2.5, back: 'Хорошо');
  }
  b.hold('road', 'Смотрите на дорогу', 30);
  b.say('Сценарий завершён. Спасибо', 3);
  b.cues.add(ScenarioCue(atUs: b.t));
  return Scenario(id: 'bench-v1', title: 'bench-v1 · 10,5 мин', cues: b.cues);
}

/// One minute: proves the sign of every angle (contract: signs are checked on
/// a device before the values are used).
Scenario signsV1() {
  final b = _Builder();
  b.say('Проверка знаков. Смотрите прямо', 4);
  for (final (step, prompt) in [
    ('sign_head_left', 'Поверните голову влево'),
    ('sign_head_down', 'Опустите голову'),
    ('sign_roll_right', 'Наклоните голову к правому плечу'),
    ('sign_eyes_left', 'Голова прямо, посмотрите глазами влево'),
    ('sign_eyes_down', 'Голова прямо, посмотрите глазами вниз'),
  ]) {
    b.glance(step, prompt, backAt: 4, window: 4.5, rest: 3, back: 'Прямо');
  }
  b.say('Готово', 2);
  b.cues.add(ScenarioCue(atUs: b.t));
  return Scenario(
    id: 'signs-v1',
    title: 'Проверка знаков · 1 мин',
    cues: b.cues,
  );
}

/// Plays a scenario against a monotonic clock. The caller ticks it; [due]
/// returns the cues whose time has come, each once and in order.
class ScenarioRunner {
  ScenarioRunner(this.scenario, {required this.startUs});
  final Scenario scenario;
  final int startUs;
  int _next = 0;
  String? lastPrompt;
  final _open = <String>{};

  List<ScenarioCue> due(int nowUs) {
    final result = <ScenarioCue>[];
    while (_next < scenario.cues.length &&
        startUs + scenario.cues[_next].atUs <= nowUs) {
      final cue = scenario.cues[_next++];
      if (cue.say != null) lastPrompt = cue.say;
      if (cue.edge == 'start') _open.add(cue.step!);
      if (cue.edge == 'end') _open.remove(cue.step);
      result.add(cue);
    }
    return result;
  }

  bool get finished => _next >= scenario.cues.length;

  /// Steps whose label is open now (normally zero or one).
  Set<String> get openSteps => Set.unmodifiable(_open);

  double progress(int nowUs) => scenario.durationUs == 0
      ? 1
      : ((nowUs - startUs) / scenario.durationUs).clamp(0, 1).toDouble();
}
