import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/attention_zones.dart';
import 'package:nscontrol/logic/domain.dart';
import 'package:nscontrol/logic/mount.dart';
import 'package:nscontrol/logic/replay.dart';
import 'package:nscontrol/logic/synthetic.dart';

const mlKit = 'mlkit_face_detection';
const arkit = 'arkit_face_tracking';

void expectAngles(
  (double, double, double) a,
  (double, double, double) b, {
  double tolerance = 1e-6,
}) {
  expect(a.$1, closeTo(b.$1, tolerance));
  expect(a.$2, closeTo(b.$2, tolerance));
  expect(a.$3, closeTo(b.$3, tolerance));
}

/// ML Kit face seen by a camera turned [mount] from the road pose.
FaceSignals mlKitFace(Rotation3 camera, {int id = 1}) {
  final (y, p, r) = camera.engineAngles(mlKit);
  return FaceSignals(
    engineId: mlKit,
    trackingId: id,
    headYawLeft: y,
    headPitchDown: p,
    headRollRight: r,
    eyeOpenLeft: .9,
    eyeOpenRight: .9,
  );
}

void main() {
  group('Rotation3', () {
    test('angles round trip for the contract and the ML Kit order', () {
      for (final engine in [null, arkit, mlKit]) {
        for (final a in [(0.0, 0.0, 0.0), (35.0, -12.0, 8.0), (-44, 20, -6)]) {
          final (y, p, r) = (a.$1.toDouble(), a.$2.toDouble(), a.$3.toDouble());
          final m = Rotation3.fromEngineAngles(engine, y, p, r);
          expectAngles(m.engineAngles(engine), (y, p, r));
        }
      }
    });

    test('quaternion round trip', () {
      final m = Rotation3.fromAngles(30, 15, -5);
      final q = m.quaternion;
      expect(q[0], greaterThanOrEqualTo(0));
      expect(q.fold(0.0, (s, v) => s + v * v), closeTo(1, 1e-9));
      expectAngles(Rotation3.fromQuaternion(q).angles, (30, 15, -5));
    });

    test('a direction and its angles', () {
      final v = Rotation3.direction(20, 10);
      final (l, d) = Rotation3.anglesOf(v);
      expect(l, closeTo(20, 1e-9));
      expect(d, closeTo(10, 1e-9));
    });
  });

  group('road frame', () {
    // A vent mount on the right, tilted up to the face.
    final mount = Rotation3.rotationX(10) * Rotation3.rotationY(30);

    for (final engine in [arkit, mlKit]) {
      test('$engine: a 20° nod is 20° whatever the mount', () {
        final (ry, rp, rr) = mount.engineAngles(engine);
        final road = RoadFrame.fromAngles(ry, rp, rr, engineId: engine);
        final nod = mount * Rotation3.fromAngles(0, 20, 0);
        final (y, p, r) = nod.engineAngles(engine);
        final head = road.head(
          FaceSignals(
            engineId: engine,
            headYawLeft: y,
            headPitchDown: p,
            headRollRight: r,
          ),
        )!;
        expectAngles(head, (0, 20, 0), tolerance: 1e-6);
        if (engine == mlKit) {
          // The Euler difference is short of the threshold and leaks into
          // roll: this is why the pipeline compares rotations.
          expect(p - rp, lessThan(18));
          expect((r - rr).abs(), greaterThan(5));
        }
      });
    }

    test('the head rotation quaternion wins over the Euler angles', () {
      final road = RoadFrame(mount);
      final nod = mount * Rotation3.fromAngles(10, 25, 0);
      final head = road.head(
        FaceSignals(
          engineId: arkit,
          headYawLeft: 0,
          headPitchDown: 0,
          headRollRight: 0,
          headRotation: nod.quaternion,
        ),
      )!;
      expectAngles(head, (10, 25, 0), tolerance: 1e-6);
    });

    test('gaze directions are turned into the road frame', () {
      final road = RoadFrame(mount);
      final (l, d) = Rotation3.anglesOf(
        mount.apply(Rotation3.direction(-40, 15)),
      );
      final (rl, rd) = road.direction(l, d);
      expect(rl, closeTo(-40, 1e-6));
      expect(rd, closeTo(15, 1e-6));
    });
  });

  group('mount calibration', () {
    MountCalibrationResult calibrate(
      DetectorCapabilities detector,
      Rotation3 road, {
      int aside = 0,
    }) {
      final c = MountCalibrationCollector(
        trackingId: 1,
        detector: detector,
        hiddenEyes: false,
        startedUs: 0,
      );
      for (var i = 0; i < 140; i++) {
        // A few frames looking at a mirror must not move the neutral pose.
        final pose = i < aside ? road * Rotation3.rotationY(25) : road;
        final (y, p, r) = pose.engineAngles(detector.id);
        c.add(
          capturedUs: i * 66000,
          faces: [
            FaceSignals(
              engineId: detector.id,
              trackingId: 1,
              headYawLeft: y + math.sin(i) * .3,
              headPitchDown: p,
              headRollRight: r,
              eyeOpenLeft: .9,
              eyeOpenRight: .92,
            ),
          ],
        );
      }
      return c.finish(nowUs: 10000000);
    }

    test('ML Kit at a 40° view: head only, with the reason', () {
      final r = calibrate(DetectorCapabilities.mlKit, Rotation3.rotationY(-40));
      expect(r.result.successful, isTrue);
      expect(r.result.profile!.hiddenEyes, isTrue);
      expect(r.result.profile!.eyeThreshold, isNull);
      expect(r.viewYaw, closeTo(-40, .5));
      expect(r.note, contains('ракурс 40°, предел 18°'));
    });

    test('an engine that sees the eyes at 40° keeps them', () {
      const detector = DetectorCapabilities(
        id: arkit,
        version: 'test',
        eyeYawLimit: 45,
      );
      final r = calibrate(detector, Rotation3.rotationY(40));
      expect(r.result.profile!.hiddenEyes, isFalse);
      expect(r.result.profile!.eyeThreshold, .4);
      expect(r.note, isNull);
    });

    test('beyond 45° the calibration fails', () {
      final r = calibrate(DetectorCapabilities.mlKit, Rotation3.rotationY(50));
      expect(r.result.successful, isFalse);
      expect(r.result.issues.join(), contains('под углом 50°'));
    });

    test('frames far from the median pose are left out', () {
      final r = calibrate(
        DetectorCapabilities.mlKit,
        Rotation3.rotationY(-35),
        aside: 10,
      );
      expect(r.result.successful, isTrue);
      expect(r.result.profile!.neutralYaw, closeTo(-35, .5));
      expect(r.result.usableFrames, lessThanOrEqualTo(130));
    });
  });

  test('pipeline: a 21° nod at a tilted side mount is head_pitch_down '
      'only with mountRelative', () {
    final mount = Rotation3.rotationX(10) * Rotation3.rotationY(-40);
    final (ny, np, nr) = mount.engineAngles(mlKit);
    final profile = CalibrationProfile(
      trackingId: 1,
      detector: DetectorCapabilities.mlKit,
      hiddenEyes: true,
      neutralPitch: np,
      neutralYaw: ny,
      neutralRoll: nr,
    );
    List<String> run(AttentionSettings settings) {
      final provider = ZoneAttentionProvider(settings: settings)
        ..reset(profile);
      final engine = ObservationEngine(
        sessionId: 's',
        calibration: provider.engineCalibration!,
        settings: AlgorithmSettings(hiddenEyes: true),
      );
      final events = <String>[];
      for (var t = 0; t <= 4000000; t += 66667) {
        final pose = t < 1000000
            ? mount
            : mount * Rotation3.fromAngles(0, 21, 0);
        provider.updateFaces([mlKitFace(pose)], t);
        final update = engine.process(
          sessionId: 's',
          capturedUs: t,
          completedUs: t + 30000,
          faces: provider.lastMeasurements,
        );
        events.addAll(update.started.map((e) => e.type.code));
      }
      return events;
    }

    expect(run(AttentionSettings.lab), ['head_pitch_down']);
    expect(
      run(const AttentionSettings(gazeAwareEyes: true, distraction: true)),
      isEmpty,
    );
  });

  group('synthetic side mount', () {
    for (final mountYaw in [30.0, -30.0]) {
      for (final style in [SyntheticStyle.arkit, SyntheticStyle.mlKit]) {
        final side = mountYaw > 0 ? 'right' : 'left';
        final sideRu = mountYaw > 0 ? 'справа' : 'слева';
        test('${style.name}, phone 30° on the $side: mirrors and turns do '
            'not alarm, the nod and the closures are found', () {
          final text = SyntheticScenario(
            style,
            mountYaw: mountYaw,
            mountTilt: 10,
            arkitEyeYawLimit: 45,
          ).toJsonl();
          final recording = Recording.parse(text);
          expect(recording.skippedLines, 0);
          expect((recording.meta['mount'] as Map)['position'], 'vent_$side');
          final r = ReplayRunner(recording).run(
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
          }
          expect(r.outsideSteps, isEmpty);
          expect(r.pausedAtUs, isNull);
          expect(r.scores['head_pitch_down']!.tp, 1);
          expect(r.scores[DistractionEvent.code]!.fp, 0);
          if (style == SyntheticStyle.arkit) {
            // ARKit sees both eyes at 30° (limit 45° here).
            expect(r.profile.hiddenEyes, isFalse);
            expect(r.scores['eyes_closed']!.tp, 2);
          } else {
            expect(r.profile.hiddenEyes, isTrue);
            expect(r.calibrationNote, contains('предел 18°'));
            // Every loss of the face gave a new id that was taken back.
            expect(r.restoredFrames, greaterThan(0));
          }
          // A look over the far shoulder loses the face: off camera, never
          // a plain loss; a dropout on the road is not off camera.
          final far = mountYaw > 0 ? 'blind_spot_right' : 'blind_spot_left';
          final glance = r.episodes.firstWhere((e) => e.episode.step == far);
          expect(glance.glances.keys, contains('off_camera'));
          for (final e in r.episodes.where((e) => e.episode.step == 'road')) {
            expect(e.glances.keys, isNot(contains('off_camera')));
          }
          final report = replayReport(recording, [r]);
          expect(report, contains('углы относительно дороги'));
          expect(
            report,
            contains(
              'Крепление: решётка $sideRu от водителя, повёрнут к водителю примерно на 30°',
            ),
          );
        });
      }
    }

    test('a lab profile with the raised ML Kit limit gets the ТЗ limit', () {
      final text = SyntheticScenario(
        SyntheticStyle.mlKit,
        mountYaw: -30,
      ).toJsonl();
      // As the lab wrote it with the limit raised to 45°: eyes evaluated.
      final lines = [
        for (final l in const LineSplitter().convert(text))
          if (l.contains('"type":"calibration"'))
            jsonEncode({
              'type': 'calibration',
              'atUs': (jsonDecode(l) as Map)['atUs'],
              'profile': CalibrationProfile(
                trackingId: 1,
                detector: const DetectorCapabilities(
                  id: mlKit,
                  version: 'lab',
                  eyeYawLimit: 45,
                ),
                hiddenEyes: false,
                neutralPitch: 0,
                neutralYaw: -30,
                neutralRoll: 0,
                leftEyeMedian: .9,
                rightEyeMedian: .9,
                eyeThreshold: .4,
              ).toJson(),
            })
          else
            l,
      ];
      final recording = Recording.parse('${lines.join('\n')}\n');
      expect(recording.calibrations.single.profile!.detector.eyeYawLimit, 45);
      final r = ReplayRunner(
        recording,
      ).run(ReplayOptions(engine: mlKit, attention: AttentionSettings.lab));
      expect(r.calibrationSource, contains('заменён на 18° по ТЗ'));
      expect(r.calibrationNote, contains('предел 18°'));
      expect(r.profile.hiddenEyes, isTrue);
      expect(r.profile.neutralYaw, -30);
      // Acceptance keeps the recorded profile as it is.
      final acceptance = ReplayRunner(
        recording,
      ).run(const ReplayOptions(engine: mlKit));
      expect(acceptance.calibrationSource, 'строка calibration записи');
    });
  });
}
