import 'calibration.dart';
import 'signals.dart';

/// What the attention logic decided for one moment: where the driver looks
/// and any extra details it wants to show (for the lab and the recording).
class AttentionState {
  const AttentionState({required this.zone, this.details = const {}});
  static const unknown = AttentionState(zone: GazeZone.unknown);

  final GazeZone zone;

  /// Free-form numbers/codes of the provider (timers, scores). Consumers show
  /// them as is; nothing in the ТЗ automata reads them.
  final Map<String, Object?> details;

  Map<String, Object?> toJson() => {
    'zone': zone.code,
    if (details.isNotEmpty) 'details': details,
  };
}

/// Connection point for the attention logic (gaze zones, distraction). The lab
/// and later the trip feed it every analysed frame of the primary engine and
/// only display its output: it never raises the ТЗ alarms itself.
abstract interface class AttentionStateProvider {
  /// Stable id, written into the recording so a replay can tell versions apart.
  String get id;

  /// A new calibration (or none) starts a new attention session.
  void reset(CalibrationProfile? calibration);

  /// [signals] is null when the frame had no usable face of the driver.
  AttentionState update(FaceSignals? signals, int atUs);
}

/// Placeholder until the attention logic is connected: always `unknown`.
class UnknownAttentionProvider implements AttentionStateProvider {
  const UnknownAttentionProvider();
  @override
  String get id => 'none';
  @override
  void reset(CalibrationProfile? calibration) {}
  @override
  AttentionState update(FaceSignals? signals, int atUs) =>
      AttentionState.unknown;
}
