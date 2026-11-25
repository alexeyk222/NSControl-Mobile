import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/attention_zones.dart';
import 'package:nscontrol/logic/domain.dart';
import 'package:nscontrol/logic/replay.dart';
import 'package:nscontrol/logic/synthetic.dart';

const negativeSteps = {
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
  'nod',
};

void main() {
  for (final style in SyntheticStyle.values) {
    group('synthetic ${style.name}', () {
      final recording = Recording.parse(SyntheticScenario(style).toJsonl());
      final runner = ReplayRunner(recording);

      test('the recording is schema 1 and every frame parses', () {
        expect(recording.meta['schema'], 1);
        expect(recording.engines, [style.engineId]);
        expect(recording.calibrations.single.profile, isNotNull);
        expect(recording.skippedLines, 0);
        expect(recording.labels.every((l) => l.rep != null), isTrue);
        final steps = Episode.fromLabels(recording.labels).map((e) => e.step);
        expect(steps.toSet(), containsAll(negativeSteps));
      });

      test(
        'lab extensions: no alarm in negative steps, every positive found',
        () {
          final r = runner.run(
            ReplayOptions(
              engine: style.engineId,
              attention: AttentionSettings.lab,
            ),
          );
          for (final e in r.episodes) {
            expect(
              e.unexpected,
              isEmpty,
              reason:
                  '${e.episode.step} raised ${e.unexpected.map((x) => x.type)}',
            );
            expect(e.missed, isEmpty, reason: '${e.episode.step} missed');
            expect(
              e.duplicates,
              isEmpty,
              reason: '${e.episode.step} duplicate',
            );
            expect(e.late, isEmpty, reason: '${e.episode.step} late');
          }
          expect(r.outsideSteps, isEmpty);
          expect(r.falseAlarms, 0);
          expect(r.scores['eyes_closed']!.tp, 2);
          expect(r.scores['head_pitch_down']!.tp, 1);
          expect(r.scores[DistractionEvent.code]!.tp, 1);
          expect(r.scores[DistractionEvent.code]!.fp, 0);
        },
      );

      test('acceptance mode: every positive found by the ТЗ automata', () {
        final r = runner.run(ReplayOptions(engine: style.engineId));
        expect(r.missed, 0);
        expect(r.scores.containsKey(DistractionEvent.code), isFalse);
        final falseSteps = {
          for (final e in r.episodes)
            if (e.unexpected.isNotEmpty) e.episode.step,
        };
        if (style == SyntheticStyle.mlKit) {
          expect(falseSteps, isEmpty);
        } else {
          // Without the eye gate the lowered lid of a 2 s instruments glance,
          // a squint and a yawn fall below T: this is why the gate exists.
          expect(falseSteps, {'instruments', 'squint', 'yawn'});
        }
      });

      test('report names every step', () {
        final report = replayReport(recording, [
          runner.run(ReplayOptions(engine: style.engineId)),
          runner.run(
            ReplayOptions(
              engine: style.engineId,
              attention: AttentionSettings.lab,
            ),
          ),
        ]);
        expect(report, contains('# Прогон записи synthetic-${style.name}'));
        expect(report, contains('приёмка (только ТЗ)'));
        expect(report, contains('| mirror_left #2 |'));
        expect(report, contains('**Итог: ложных тревог ТЗ 0, пропусков 0.**'));
      });

      test('recalibration from frames gives the recorded profile', () {
        final r = runner.run(
          ReplayOptions(engine: style.engineId, recalibrate: true),
        );
        expect(r.calibrationSource, contains('пересчитана'));
        expect(
          r.profile.eyeThreshold,
          recording.calibrations.single.profile!.eyeThreshold,
        );
        expect(r.missed, 0);
      });
    });
  }

  test('ML Kit: the ТЗ events are identical with and without the pipeline', () {
    final recording = Recording.parse(
      SyntheticScenario(SyntheticStyle.mlKit, seed: 3).toJsonl(),
    );
    final profile = recording.calibrations.single.profile!;
    List<String> run(bool lab) {
      final engine = ObservationEngine(sessionId: 's', calibration: profile);
      final pipeline = AttentionPipeline(
        calibration: profile,
        settings: lab ? AttentionSettings.lab : const AttentionSettings(),
      );
      final out = <String>[];
      for (final f in recording.frames) {
        if (f.capturedUs <= recording.calibrations.single.atUs) continue;
        final faces = [if (f.signals != null) f.signals!];
        final u = engine.process(
          sessionId: 's',
          capturedUs: f.capturedUs,
          completedUs: f.completedUs,
          faces: lab
              ? pipeline.process(f.capturedUs, faces).measurements
              : faces.map((s) => s.toMeasurement()).toList(),
        );
        out.addAll(u.started.map((e) => jsonEncode(e.toJson())));
        out.addAll(u.ended.map((e) => jsonEncode(e.toJson())));
      }
      return out;
    }

    final direct = run(false);
    expect(direct, isNotEmpty);
    expect(run(true), direct);
  });

  group('matching by ПМИ 7.3', () {
    Recording build(List<Map<String, Object?>> extra) {
      // A tiny ML Kit recording: 10 s calibration, then whatever [extra] adds.
      final base = SyntheticScenario(SyntheticStyle.mlKit).toJsonl();
      final lines = const LineSplitter().convert(base).where((l) {
        final t = (jsonDecode(l) as Map)['type'];
        return t != 'label';
      }).toList();
      return Recording.parse(
        [...lines, for (final e in extra) jsonEncode(e)].join('\n'),
      );
    }

    Map<String, Object?> label(
      double s,
      String step,
      String edge, {
      int? rep,
      bool? aborted,
    }) => {
      'type': 'label',
      'atUs': (s * 1e6).round(),
      'step': step,
      'edge': edge,
      'rep': ?rep,
      'aborted': ?aborted,
      'unknownField': 'ignored',
    };

    // In the synthetic run eyes_closed_3s starts at 114.7 s (ML Kit) and the
    // automaton reaches the threshold at about 116.4 s.
    test('a label far from the closure: late, not FN and not FP', () {
      final r = ReplayRunner(
        build([
          label(113.5, 'eyes_closed_3s', 'start', rep: 1),
          label(119, 'eyes_closed_3s', 'end', rep: 1),
        ]),
      ).run(const ReplayOptions(engine: 'mlkit_face_detection'));
      final s = r.scores['eyes_closed']!;
      expect([s.tp, s.fn, s.late], [0, 0, 1]);
      expect(r.episodes.single.late, hasLength(1));
    });

    test('borderline step miss is shown apart from FN', () {
      final r = ReplayRunner(
        build([
          label(20, 'eyes_closed_2s', 'start', rep: 1),
          label(23, 'eyes_closed_2s', 'end', rep: 1),
        ]),
      ).run(const ReplayOptions(engine: 'mlkit_face_detection'));
      final s = r.scores['eyes_closed']!;
      expect([s.fn, s.borderline], [0, 1]);
      expect(replayReport(build([]), [r]), contains('пограничный пропуск'));
    });

    test('events outside any step and in aborted steps', () {
      final r = ReplayRunner(
        build([
          label(110.0, 'eyes_closed_2s', 'start', rep: 1),
          label(111.5, 'eyes_closed_2s', 'end', rep: 1, aborted: true),
        ]),
      ).run(const ReplayOptions(engine: 'mlkit_face_detection'));
      expect(r.episodes.single.episode.aborted, isTrue);
      expect(r.episodes.single.missed, isEmpty);
      // eyes_closed_2s threshold (~111.7 s) lies within 1 s after the aborted
      // step; eyes_closed_3s and head_down_3s have no step at all.
      expect(r.episodes.single.ignored.map((e) => e.type), ['eyes_closed']);
      expect(
        r.outsideSteps.map((e) => e.type),
        containsAll(['eyes_closed', 'head_pitch_down']),
      );
      expect(r.falseAlarms, r.outsideSteps.length);
    });

    test('a second event in the same positive step is an FP duplicate', () {
      // One step spanning both closures: the second one is a duplicate.
      final r = ReplayRunner(
        build([
          label(110.0, 'eyes_closed_3s', 'start', rep: 1),
          label(118.0, 'eyes_closed_3s', 'end', rep: 1),
        ]),
      ).run(const ReplayOptions(engine: 'mlkit_face_detection'));
      final s = r.scores['eyes_closed']!;
      expect(s.duplicates, 1);
      expect(s.fp, 1);
    });
  });

  test('unknown lines are skipped, a newer schema is refused', () {
    final r = Recording.parse(
      [
        '{"type":"meta","schema":1,"recordingId":"x"}',
        '{"type":"derived","atUs":1,"zone":"road"}',
        '{"type":"future","x":1}',
        'not json',
      ].join('\n'),
    );
    expect(r.skippedLines, 2);
    expect(
      () => Recording.parse('{"type":"meta","schema":2}'),
      throwsFormatException,
    );
  });

  test('provider for the lab', () {
    final recording = Recording.parse(
      SyntheticScenario(SyntheticStyle.arkit).toJsonl(),
    );
    final AttentionStateProvider provider = ZoneAttentionProvider();
    expect(provider.update(null, 0).zone, GazeZone.unknown);
    provider.reset(recording.calibrations.single.profile);
    final zones = <GazeZone>{};
    for (final f in recording.frames) {
      final state = provider.update(f.signals, f.capturedUs);
      zones.add(state.zone);
      expect(state.toJson()['zone'], state.zone.code);
    }
    expect(provider.id, 'zones-1+ext');
    expect(
      zones,
      containsAll([
        GazeZone.road,
        GazeZone.mirrorLeft,
        GazeZone.mirrorRight,
        GazeZone.mirrorRear,
        GazeZone.instruments,
        GazeZone.console,
        GazeZone.offCamera,
      ]),
    );
    final p = provider as ZoneAttentionProvider;
    expect(p.lastMeasurement, isNotNull);
    expect(
      ZoneAttentionProvider(settings: const AttentionSettings.acceptance()).id,
      'zones-1',
    );
  });
}
