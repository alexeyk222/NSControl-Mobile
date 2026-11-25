import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/domain.dart';

void main() {
  test('bench-v1 lasts 10–12 minutes and covers the contract steps', () {
    final s = benchV1();
    expect(s.id, 'bench-v1');
    expect(s.durationUs, inInclusiveRange(600000000, 720000000));
    expect(
      s.steps,
      containsAll([
        'road',
        'mirror_left',
        'mirror_right',
        'mirror_rear',
        'blind_spot_left',
        'blind_spot_right',
        'intersection_scan',
        'instruments',
        'talk',
        'laugh',
        'squint',
        'yawn',
        'eyes_closed_1s',
        'eyes_closed_2s',
        'eyes_closed_3s',
        'head_down_3s',
        'nod',
      ]),
    );
  });

  test('every label opens and closes once per repetition', () {
    for (final s in Scenario.all) {
      final starts = s.cues.where((c) => c.edge == 'start').toList();
      final ends = s.cues.where((c) => c.edge == 'end').toList();
      expect(starts.length, ends.length, reason: s.id);
      for (final start in starts) {
        final end = ends.singleWhere(
          (e) => e.step == start.step && e.rep == start.rep,
        );
        expect(end.atUs, greaterThan(start.atUs));
      }
    }
  });

  test('timed steps hold exactly the named duration', () {
    final s = benchV1();
    for (final (step, us) in [
      ('eyes_closed_1s', 1000000),
      ('eyes_closed_2s', 2000000),
      ('eyes_closed_3s', 3000000),
      ('head_down_3s', 3000000),
    ]) {
      final starts = s.cues.where((c) => c.step == step && c.edge == 'start');
      expect(starts, hasLength(3));
      for (final start in starts) {
        final end = s.cues.singleWhere(
          (c) => c.step == step && c.rep == start.rep && c.edge == 'end',
        );
        expect(end.atUs - start.atUs, us);
      }
    }
  });

  test('signs-v1 checks every angle sign', () {
    expect(
      signsV1().steps,
      containsAll([
        'sign_head_left',
        'sign_head_down',
        'sign_roll_right',
        'sign_eyes_left',
        'sign_eyes_down',
      ]),
    );
    expect(Scenario.byId('signs-v1').id, 'signs-v1');
  });

  test('runner emits each cue once, in order, by the clock', () {
    final s = signsV1();
    final runner = ScenarioRunner(s, startUs: 1000);
    expect(runner.due(999), isEmpty);
    final seen = <ScenarioCue>[];
    for (var t = 0; t <= s.durationUs + 2000; t += 50000) {
      seen.addAll(runner.due(1000 + t));
      for (final cue in seen) {
        expect(cue.atUs + 1000, lessThanOrEqualTo(1000 + t));
      }
    }
    expect(seen, s.cues);
    expect(runner.finished, isTrue);
    expect(runner.openSteps, isEmpty);
    expect(runner.progress(1000 + s.durationUs), 1);
  });

  test('runner tracks the open step and the last prompt', () {
    final s = signsV1();
    final runner = ScenarioRunner(s, startUs: 0);
    final start = s.cues.firstWhere((c) => c.edge == 'start');
    runner.due(start.atUs);
    expect(runner.openSteps, {start.step});
    expect(runner.lastPrompt, start.say);
  });

  test('unpaired labels are rejected', () {
    expect(
      () => Scenario(
        id: 'x',
        title: 'x',
        cues: const [ScenarioCue(atUs: 0, step: 'road', edge: 'start')],
      ),
      throwsArgumentError,
    );
    expect(
      () => Scenario(
        id: 'x',
        title: 'x',
        cues: const [ScenarioCue(atUs: 0, step: 'road', edge: 'end')],
      ),
      throwsArgumentError,
    );
  });

  test('pmi-negative-60 is six labelled 10-minute blocks', () {
    final s = pmiNegative60();
    final starts = s.cues.where((c) => c.edge == 'start').toList();
    expect(starts.map((c) => c.step), [
      'neg_natural',
      'neg_mirrors',
      'neg_blind_spot',
      'neg_intersection',
      'neg_instruments',
      'neg_mixed',
    ]);
    for (final start in starts) {
      final end = s.cues.singleWhere(
        (c) => c.step == start.step && c.edge == 'end',
      );
      expect(end.atUs - start.atUs, 600000000);
    }
    expect(s.durationUs, inInclusiveRange(3600000000, 3660000000));
    final prompts = s.cues.where((c) => c.say != null && !c.isLabel).length;
    expect(prompts, inInclusiveRange(60, 200), reason: 'rare prompts');
  });
}
