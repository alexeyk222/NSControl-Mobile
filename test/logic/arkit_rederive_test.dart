import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/arkit_geometry.dart';
import 'package:nscontrol/logic/arkit_rederive.dart';
import 'package:nscontrol/logic/signals.dart';

/// One ARKit frame as the lab records it: Apple camera space, portrait
/// (up = −x), head turned [yaw]° to the driver's left with standard axes.
String _frame(int us, double yaw) {
  final a = yaw * math.pi / 180, c = math.cos(a), s = math.sin(a);
  final face = <double>[0, c, -s, 0, -1, 0, 0, 0, 0, s, c, 0, 0, 0, -.5, 1];
  return jsonEncode({
    'type': 'frame',
    'engine': 'arkit_face_tracking',
    'capturedUs': us,
    'completedUs': us + 20000,
    'faceCount': 1,
    'signals': {
      'engine': 'arkit_face_tracking',
      'trackingId': 1,
      'tracked': true,
      'headYawLeft': yaw,
      'box': {'left': .3, 'top': .2, 'width': .4, 'height': .3},
    },
    'raw': {
      'gravityUp': [-1.0, 0.0, 0.0],
      'axes': {'mirror': false, 'swapEyes': false},
      'faces': [
        {
          'id': 1,
          'tracked': true,
          'faceInCamera': face,
          'blendshapes': {'eyeBlink_L': .1, 'eyeBlink_R': .2},
        },
      ],
    },
  });
}

void main() {
  final jsonl = [
    jsonEncode({'type': 'meta', 'schema': 1}),
    _frame(0, 30),
    _frame(33000, 30),
    jsonEncode({'type': 'frame', 'engine': 'mlkit_face_detection'}),
  ].join('\n');

  test('rederive applies the axes and keeps everything else', () {
    final out = const LineSplitter().convert(
      ArkitRawRecording(jsonl).rederive(const ArkitAxes(mirror: true)),
    );
    expect(out, hasLength(4));
    expect(out.first, contains('"meta"'));
    expect(out.last, contains('mlkit_face_detection'));
    final frame = jsonDecode(out[1]) as Map<String, dynamic>;
    final s = FaceSignals.fromJson(frame['signals'] as Map<String, dynamic>);
    expect(s.headYawLeft, closeTo(-30, 1e-6));
    expect(s.eyeOpenLeft, closeTo(.9, 1e-12));
    expect(s.box!.left, .3);
    expect(s.headRotation, isNotNull);
    expect((frame['raw'] as Map)['axes'], {'mirror': true, 'swapEyes': false});
    final standard = jsonDecode(
      const LineSplitter().convert(
        ArkitRawRecording(jsonl).rederive(ArkitAxes.standard),
      )[1],
    );
    expect(standard['signals']['headYawLeft'], closeTo(30, 1e-6));
  });

  test('diagnose shows the phone tilt and both sign hypotheses', () {
    final report = ArkitRawRecording(jsonl).diagnose();
    expect(report, contains('raw: 2.'));
    final rows = report.split('\n');
    String row(String name) => rows.firstWhere((l) => l.startsWith('| $name'));
    expect(row('Как сейчас: поворот влево'), contains('| 30.0 |'));
    expect(row('mirror: поворот влево'), contains('| -30.0 |'));
    expect(row('Ось камеры к водителю над горизонтом'), contains('| 0.00 |'));
    expect(row('Расстояние'), contains('| 0.50 |'));
  });

  test('the iPhone default is mirrored', () {
    expect(ArkitAxes.device.mirror, isTrue);
    expect(ArkitAxes.device.swapEyes, isFalse);
  });
}
