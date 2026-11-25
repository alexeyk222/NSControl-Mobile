import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/calibration.dart';
import 'package:nscontrol/logic/face.dart';
import 'package:nscontrol/logic/recording.dart';
import 'package:nscontrol/logic/replay.dart';
import 'package:nscontrol/logic/signals.dart';

const _engine = 'mlkit_face_detection';

/// A trip that calibrates again after a pause: the holder was moved, the
/// road pose is 25° lower to the camera from then on, and the driver lowers
/// the head for 3 s at 70 s.
///
/// [derived] writes the app's `derived` lines while a session runs (10–40 s
/// and from 52 s); [shiftAt] is the second calibration's line.
String _trip({required bool trip, bool derived = true, int shiftAt = 52}) {
  const s = 1000000;
  final lines = <Map<String, Object?>>[
    {
      ...RecordingSchema.meta(
        recordingId: 'trip-test',
        app: 'test',
        engines: [_engine],
        startedAt: DateTime.utc(2026, 11, 26),
      ),
      if (trip) 'source': 'trip',
    },
  ];
  Map<String, Object?> calibration(int atUs, double pitch) => {
    ...RecordingSchema.calibration(
      atUs: atUs,
      engine: _engine,
      profile: CalibrationProfile(
        trackingId: 1,
        detector: DetectorCapabilities.mlKit,
        hiddenEyes: false,
        neutralPitch: pitch,
        neutralYaw: 0,
        neutralRoll: 0,
        leftEyeMedian: .9,
        rightEyeMedian: .9,
        eyeThreshold: .4,
      ),
    ),
    if (trip) 'sessionOffsetUs': atUs,
  };
  void frame(int t, double pitch) => lines.add(
    RecordingSchema.frame(
      engine: _engine,
      capturedUs: t,
      completedUs: t + 20000,
      faceCount: 1,
      signals: FaceSignals(
        engineId: _engine,
        trackingId: 1,
        headYawLeft: 0,
        headPitchDown: pitch,
        headRollRight: 0,
        eyeOpenLeft: .9,
        eyeOpenRight: .9,
      ),
    ),
  );
  for (var t = 0; t < 40 * s; t += 33000) {
    frame(t, 0);
    if (derived && t >= 10 * s && t % 99000 == 0) {
      lines.add({'type': 'derived', 'atUs': t + 20000});
    }
  }
  lines.add(calibration(10 * s, 0));
  // Paused 40–42 s, then the trip finds the face and calibrates.
  for (var t = 42 * s; t < 80 * s; t += 33000) {
    final down = t >= 70 * s && t < 73 * s;
    frame(t, down ? 55 : 25);
    if (derived && t > shiftAt * s && t % 99000 == 0) {
      lines.add({'type': 'derived', 'atUs': t + 20000});
    }
  }
  lines.add(calibration(shiftAt * s, 25));
  for (final (at, edge) in [(69500000, 'start'), (74000000, 'end')]) {
    lines.add(
      RecordingSchema.label(
        atUs: at,
        scenario: 'bench-v1',
        step: 'head_down_3s',
        edge: edge,
      ),
    );
  }
  return lines.map(jsonEncode).join('\n');
}

void main() {
  const options = ReplayOptions(engine: _engine);
  List<int> heads(ReplayResult r) => [
    for (final e in r.events)
      if (e.type == 'head_pitch_down') e.signStartedUs,
  ];

  test('a trip switches to each new calibration line', () {
    final r = ReplayRunner(Recording.parse(_trip(trip: true))).run(options);
    expect(r.recalibratedUs, [52000000]);
    // Only the real head-down: the lower road pose after the move is the
    // new calibration's road.
    expect(heads(r), hasLength(1));
    expect(heads(r).single, inInclusiveRange(69900000, 70100000));
    expect(r.missed, 0);
    expect(r.falseAlarms, 0);
    // Frames while the trip found the face and calibrated are not observed.
    final observed = r.frames;
    expect(observed, lessThan((30 + 28) * 1000000 ~/ 33000 + 2));
    expect(
      replayReport(Recording.parse(_trip(trip: true)), [r]),
      contains('Новые калибровки поездки: 52.0 с'),
    );
  });

  test('a lab recording keeps the calibration the scenario ran on', () {
    final r = ReplayRunner(Recording.parse(_trip(trip: false))).run(options);
    // The last calibration before the first label; nothing before it.
    expect(r.recalibratedUs, isEmpty);
    expect(r.frames, lessThan(28 * 1000000 ~/ 33000 + 2));
    expect(heads(r), hasLength(1));
  });

  test('without derived lines the 10 s before the line are not observed', () {
    final r = ReplayRunner(
      Recording.parse(_trip(trip: true, derived: false)),
    ).run(options);
    expect(r.recalibratedUs, [52000000]);
    expect(heads(r), hasLength(1));
  });
}
