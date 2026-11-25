import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/attention_zones.dart';
import 'package:nscontrol/logic/domain.dart';
import 'package:nscontrol/logic/driver_continuity.dart';
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
  for (final style in [SyntheticStyle.arkit, SyntheticStyle.mlKit]) {
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
          expect(r.pausedAtUs, isNull);
          if (style == SyntheticStyle.mlKit) {
            // Every loss of the face gave a new id that was taken back.
            expect(r.restoredFrames, greaterThanOrEqualTo(4));
          }
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
        expect(report, contains('| intersection_scan | off_road |'));
        expect(report, contains('наблюдение не приостанавливалось'));
        expect(
          RegExp(r'eyes_closed_3s #1 .*\| 0\.0\d; глубоко').hasMatch(report),
          isTrue,
        );
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

  test('ML Kit: the ТЗ events are identical with and without the pipeline '
      '(ids restored the same way)', () {
    final recording = Recording.parse(
      SyntheticScenario(SyntheticStyle.mlKit, seed: 3).toJsonl(),
    );
    final profile = recording.calibrations.single.profile!;
    List<String> run(bool lab, {bool continuity = true}) {
      final engine = ObservationEngine(sessionId: 's', calibration: profile);
      final driver = DriverContinuity(trackingId: profile.trackingId);
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
              : (continuity ? driver.resolve(f.capturedUs, faces) : faces)
                    .map((s) => s.toMeasurement())
                    .toList(),
        );
        out.addAll(u.started.map((e) => jsonEncode(e.toJson())));
        out.addAll(u.ended.map((e) => jsonEncode(e.toJson())));
      }
      return out;
    }

    final direct = run(false);
    expect(direct, isNotEmpty);
    expect(run(true), direct);
    // Without continuity the first blind-spot check (new ML Kit id) stops
    // observation for good: no event at all.
    expect(run(false, continuity: false), isEmpty);
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

    test('head_pitch_down while looking at a phone is allowed, not FP', () {
      // ML Kit head_down_3s starts at 120.4 s; label it as distraction_4s.
      final r = ReplayRunner(
        build([
          label(120.4, 'distraction_4s', 'start', rep: 1),
          label(124.4, 'distraction_4s', 'end', rep: 1),
        ]),
      ).run(const ReplayOptions(engine: 'mlkit_face_detection'));
      final step = r.episodes.single;
      expect(step.allowed.map((e) => e.type), ['head_pitch_down']);
      expect(step.unexpected, isEmpty);
      expect(r.scores['head_pitch_down']!.fp, 0);
      expect(replayReport(build([]), [r]), contains('допустимо по ТЗ'));
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

  group('comparison mode «ARKit + ML Kit» as the iPhone writes it', () {
    const arkit = 'arkit_face_tracking', mlKit = 'mlkit_face_detection';
    final text = SyntheticScenario(SyntheticStyle.arkitMlKit).toJsonl();
    final recording = Recording.parse(text);
    final runner = ReplayRunner(recording);
    final lines = [
      for (final l in const LineSplitter().convert(text))
        jsonDecode(l) as Map<String, dynamic>,
    ];

    test('two frame lines per analysed frame, device and raw are read', () {
      expect(recording.engines, [arkit, mlKit]);
      expect(recording.skippedLines, 0);
      expect(
        lines.where((l) => l['type'] == 'device').length,
        greaterThan(100),
      );
      final arkitFrames = lines.where(
        (l) => l['type'] == 'frame' && l['engine'] == arkit,
      );
      expect(arkitFrames.every((l) => l.containsKey('raw')), isTrue);
      final arkitTimes = {
        for (final f in recording.frames)
          if (f.engine == arkit) f.capturedUs,
      };
      final mlKitFrames = recording.frames.where((f) => f.engine == mlKit);
      expect(mlKitFrames.length, closeTo(arkitTimes.length / 4, 2));
      expect(
        mlKitFrames.every((f) => arkitTimes.contains(f.capturedUs)),
        isTrue,
      );
    });

    test('each engine is replayed on its own frames and calibration', () {
      final a = runner.run(const ReplayOptions(engine: arkit));
      final m = runner.run(const ReplayOptions(engine: mlKit));
      expect(a.calibrationSource, 'строка calibration записи');
      expect(m.calibrationSource, contains('пересчитана'));
      expect(a.missed, 0);
      expect(m.missed, 0);
      Set<String> falseSteps(ReplayResult r) => {
        for (final e in r.episodes)
          if (e.unexpected.isNotEmpty) e.episode.step,
      };
      expect(falseSteps(a), {'instruments', 'squint', 'yawn'});
      expect(falseSteps(m), isEmpty);
      expect(m.restoredFrames, greaterThanOrEqualTo(4));
      for (final engine in [arkit, mlKit]) {
        final r = runner.run(
          ReplayOptions(engine: engine, attention: AttentionSettings.lab),
        );
        expect(r.falseAlarms, 0, reason: engine);
        expect(r.missed, 0, reason: engine);
        expect(r.pausedAtUs, isNull, reason: engine);
      }
    });

    test('the report has a separate section per engine and mode', () {
      final report = replayReport(recording, [
        for (final engine in [arkit, mlKit])
          for (final mode in [
            const AttentionSettings.acceptance(),
            AttentionSettings.lab,
          ])
            runner.run(ReplayOptions(engine: engine, attention: mode)),
      ]);
      for (final engine in [arkit, mlKit]) {
        expect(report, contains('## $engine, приёмка (только ТЗ)'));
        expect(report, contains('## $engine, расширения'));
      }
      expect(report, isNot(contains('пропущено строк')));
    });

    test('a recording started after calibration (line at 0) replays', () {
      final shifted = [
        for (final l in lines)
          jsonEncode(l['type'] == 'calibration' ? {...l, 'atUs': 0} : l),
      ].join('\n');
      final r = ReplayRunner(Recording.parse(shifted));
      final m = r.run(const ReplayOptions(engine: mlKit));
      expect(m.calibrationSource, contains('после строки calibration'));
      expect(m.missed, 0);
      expect(r.run(const ReplayOptions(engine: arkit)).missed, 0);
    });

    test('a later recalibration does not move the start of the scenario', () {
      final calibration = lines.firstWhere((l) => l['type'] == 'calibration');
      final again = jsonEncode({...calibration, 'atUs': 100000000});
      final r = ReplayRunner(Recording.parse('$text$again\n'));
      final a = r.run(const ReplayOptions(engine: arkit));
      expect(a.missed, 0);
      expect(a.episodes.length, Episode.fromLabels(recording.labels).length);
    });
  });

  group('several faces in a frame', () {
    const mlKit = 'mlkit_face_detection';
    final text = SyntheticScenario(SyntheticStyle.mlKit).toJsonl();

    /// A passenger next to the driver for 0.5 s at 60 s.
    String withPassenger({required bool others}) => [
      for (final l in const LineSplitter().convert(text))
        () {
          final json = jsonDecode(l) as Map<String, dynamic>;
          final at = json['capturedUs'] as int? ?? 0;
          if (json['type'] != 'frame' ||
              json['signals'] == null ||
              at < 60000000 ||
              at > 60500000) {
            return l;
          }
          return jsonEncode({
            ...json,
            'faceCount': 2,
            if (others)
              'others': [
                {
                  'engine': mlKit,
                  'trackingId': 99,
                  'tracked': true,
                  'headYawLeft': 30.0,
                  'headPitchDown': 0.0,
                  'headRollRight': 0.0,
                  'eyeOpenLeft': .9,
                  'eyeOpenRight': .9,
                  'box': {'left': .75, 'top': .2, 'width': .2, 'height': .3},
                },
              ],
          });
        }(),
    ].join('\n');

    test('recorded other faces suspend observation as in the app', () {
      final recording = Recording.parse(withPassenger(others: true));
      expect(recording.frames.where((f) => f.others.isNotEmpty), isNotEmpty);
      final r = ReplayRunner(recording).run(const ReplayOptions(engine: mlKit));
      expect(r.pausedAtUs, inInclusiveRange(60000000, 60500000));
    });

    test('without others the frame is a frame without the driver', () {
      final r = ReplayRunner(
        Recording.parse(withPassenger(others: false)),
      ).run(const ReplayOptions(engine: mlKit));
      expect(r.pausedAtUs, isNull);
    });
  });

  test('unknown lines are skipped, a newer schema is refused', () {
    final r = Recording.parse(
      [
        '{"type":"meta","schema":1,"recordingId":"x"}',
        '{"type":"derived","atUs":1,"zone":"road"}',
        '{"type":"device","atUs":1,"thermal":"nominal"}',
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
