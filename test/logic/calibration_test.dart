import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/domain.dart';

FaceMeasurement face({
  double left = .8,
  double right = .7,
  double pitch = 2,
  double yaw = 3,
  double roll = -1,
  int? id = 7,
}) => FaceMeasurement(
  trackingId: id,
  leftEye: left,
  rightEye: right,
  pitchDown: pitch,
  yaw: yaw,
  roll: roll,
);

CalibrationCollector collector({bool hiddenEyes = false}) =>
    CalibrationCollector(
      trackingId: 7,
      detector: DetectorCapabilities.mlKit,
      hiddenEyes: hiddenEyes,
      startedUs: 0,
    );

void fill(
  CalibrationCollector target, {
  int valid = 100,
  int count = 100,
  FaceMeasurement? measurement,
}) {
  for (var i = 0; i < count; i++) {
    target.add(
      capturedUs: i * 100000,
      faces: i < valid ? [measurement ?? face()] : [],
    );
  }
}

void main() {
  test('exact MAD boundaries tolerate floating-point representation', () {
    final target = collector();
    for (var i = 0; i < 100; i++) {
      target.add(
        capturedUs: i * 100000,
        faces: [
          face(
            left: i.isEven ? .6 : .9,
            right: i.isEven ? .6 : .9,
            pitch: i.isEven ? -5 : 5,
          ),
        ],
      );
    }
    expect(target.finish(nowUs: 10000000).profile, isNotNull);
  });

  test('a face change during calibration requires explicit reconfirmation', () {
    final target = collector();
    fill(target, valid: 99);
    target.add(capturedUs: 10000000, faces: [face(id: 8)]);
    expect(target.finish(nowUs: 10000000).profile, isNull);
  });

  test(
    'calibration requires all ten seconds and derives threshold from worse eye',
    () {
      final target = collector();
      fill(target);
      expect(target.finish(nowUs: 9999999).profile, isNull);
      final result = target.finish(nowUs: 10000000);
      expect(result.issues, isEmpty);
      expect(result.profile!.eyeThreshold, closeTo(.35, 1e-12));
      expect(result.profile!.neutralPitch, 2);
      expect(
        CalibrationProfile.fromJson(result.profile!.toJson()).neutralYaw,
        3,
      );
    },
  );

  test('exactly ninety measurements and ninety percent are accepted', () {
    final target = collector();
    fill(target, valid: 90);
    expect(target.finish(nowUs: 10000000).profile, isNotNull);
    final insufficient = collector();
    fill(insufficient, valid: 89);
    expect(insufficient.finish(nowUs: 10000000).profile, isNull);
    final ratio = collector();
    fill(ratio, valid: 90, count: 101);
    expect(ratio.finish(nowUs: 10100000).profile, isNull);
  });

  test(
    'open eye median boundary is inclusive and nonfinite inputs are invalid',
    () {
      final boundary = collector();
      fill(boundary, measurement: face(left: .6, right: .6));
      expect(boundary.finish(nowUs: 10000000).profile, isNotNull);
      final closed = collector();
      fill(closed, measurement: face(left: .599));
      expect(closed.finish(nowUs: 10000000).profile, isNull);
      final invalid = collector();
      fill(invalid, measurement: face(pitch: double.nan));
      expect(invalid.finish(nowUs: 10000000).profile, isNull);
    },
  );

  test(
    'head-only calibration accepts missing eyes but still requires stable angles',
    () {
      final target = collector(hiddenEyes: true);
      fill(
        target,
        measurement: const FaceMeasurement(
          trackingId: 7,
          pitchDown: 1,
          yaw: 40,
          roll: 0,
        ),
      );
      final profile = target.finish(nowUs: 10000000).profile!;
      expect(profile.eyeThreshold, isNull);
      expect(profile.hiddenEyes, isTrue);
      final unstable = collector(hiddenEyes: true);
      for (var i = 0; i < 100; i++) {
        unstable.add(
          capturedUs: i * 100000,
          faces: [face(pitch: i.isEven ? 0 : 11)],
        );
      }
      expect(unstable.finish(nowUs: 10000000).profile, isNull);
    },
  );

  test(
    'identity ambiguity and invalid/out-of-order time do not produce a profile',
    () {
      final target = collector();
      for (var i = 0; i < 100; i++) {
        target.add(capturedUs: i * 100000, faces: [face(), face(id: 8)]);
      }
      expect(target.finish(nowUs: 10000000).profile, isNull);
      final repeated = collector();
      for (var i = 0; i < 100; i++) {
        repeated.add(capturedUs: 1, faces: [face()]);
      }
      expect(repeated.finish(nowUs: 10000000).profile, isNull);
    },
  );

  test(
    'settings reject out of range, nonfinite, and unsupported step values',
    () {
      expect(AlgorithmSettings().eyesClosedUs, 1500000);
      expect(
        () => AlgorithmSettings(eyesClosedUs: 999999),
        throwsArgumentError,
      );
      expect(
        () => AlgorithmSettings(eyesClosedUs: 1150000),
        throwsArgumentError,
      );
      expect(
        () => AlgorithmSettings(pitchThreshold: double.nan),
        throwsArgumentError,
      );
      expect(() => AlgorithmSettings(headYawLimit: 45.1), throwsArgumentError);
      expect(
        AlgorithmSettings.fromJson(AlgorithmSettings().toJson()).headDownUs,
        2000000,
      );
    },
  );
}
