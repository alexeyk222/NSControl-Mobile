import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/domain.dart';

void main() {
  test('schema 1 lines round-trip through the reader', () {
    final profile = CalibrationProfile(
      trackingId: 7,
      detector: DetectorCapabilities.mlKit,
      hiddenEyes: false,
      neutralPitch: 1,
      neutralYaw: 2,
      neutralRoll: 0,
      leftEyeMedian: .8,
      rightEyeMedian: .8,
      eyeThreshold: .4,
    );
    const signals = FaceSignals(
      engineId: 'mlkit_face_detection',
      trackingId: 7,
      headYawLeft: 3,
      eyeOpenLeft: .9,
      eyeOpenRight: .8,
    );
    final text = [
      RecordingSchema.meta(
        recordingId: 'r1',
        app: '1.0.0+2',
        engines: ['mlkit_face_detection'],
        startedAt: DateTime(2026, 11, 27, 10),
      ),
      RecordingSchema.calibration(atUs: 0, profile: profile),
      RecordingSchema.frame(
        engine: 'mlkit_face_detection',
        capturedUs: 10,
        completedUs: 30,
        faceCount: 1,
        signals: signals,
      ),
      RecordingSchema.frame(
        engine: 'mlkit_face_detection',
        capturedUs: 40,
        completedUs: 60,
        faceCount: 0,
      ),
      RecordingSchema.derived(atUs: 60, zone: GazeZone.road),
      RecordingSchema.label(
        atUs: 70,
        scenario: 'bench-v1',
        step: 'road',
        edge: 'start',
        rep: 1,
      ),
      {'type': 'future_kind', 'x': 1},
    ].map(RecordingSchema.encode).join('\n');
    final reader = RecordingReader.parse(text);
    expect(reader.meta['schema'], 1);
    expect(reader.meta['startedAt'], startsWith('2026-11-27T10:00:00'));
    expect(reader.meta['startedAt'], matches(RegExp(r'[+-]\d\d:\d\d$')));
    expect(
      CalibrationProfile.fromJson(
        reader.ofType('calibration').single['profile'],
      ).toJson(),
      profile.toJson(),
    );
    expect(reader.signals().single.toJson(), signals.toJson());
    expect(reader.ofType('frame').last.containsKey('signals'), isFalse);
    expect(reader.ofType('derived').single['zone'], 'road');
    expect(reader.ofType('label').single['rep'], 1);
    expect(reader.ofType('future_kind'), hasLength(1));
  });

  test('a recording must start with a known meta line', () {
    expect(
      () => RecordingReader.parse('{"type":"frame"}'),
      throwsFormatException,
    );
    expect(
      () => RecordingReader.parse('{"type":"meta","schema":2}'),
      throwsFormatException,
    );
  });
}
