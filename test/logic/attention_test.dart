import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/domain.dart';

void main() {
  test('without attention logic the zone is unknown', () {
    const provider = UnknownAttentionProvider();
    provider.reset(null);
    const signals = FaceSignals(engineId: 'mlkit_face_detection');
    expect(provider.update(signals, 0).zone, GazeZone.unknown);
    expect(provider.update(null, 1).zone, GazeZone.unknown);
    expect(provider.id, 'none');
  });

  test('state serializes the zone code and optional details', () {
    expect(AttentionState.unknown.toJson(), {'zone': 'unknown'});
    expect(
      const AttentionState(
        zone: GazeZone.mirrorLeft,
        details: {'offRoadMs': 300},
      ).toJson(),
      {
        'zone': 'mirror_left',
        'details': {'offRoadMs': 300},
      },
    );
  });
}
