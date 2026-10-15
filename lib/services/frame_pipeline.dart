/// Single-flight analysis. A session change invalidates in-flight completions,
/// but never unlocks the detector until the original invocation has returned.
class FramePipeline<F, R> {
  FramePipeline({
    required this.analyze,
    required this.onResult,
    required this.onError,
    required this.nowUs,
    this.onDiscard,
    this.maxAgeUs = 300000,
  });

  final Future<R> Function(F) analyze;
  final void Function(R, int capturedUs, int completedUs) onResult;
  final void Function(Object) onError;
  final int Function() nowUs;
  final int maxAgeUs;
  final void Function(int capturedUs, int completedUs)? onDiscard;
  bool busy = false;
  bool _active = false;
  int _generation = 0;
  int completed = 0;
  int dropped = 0;
  int stale = 0;
  int? lastCompletedUs;
  int? lastDurationUs;
  int? inFlightCapturedUs;
  final List<int> _completionTimes = [];
  int completedBetween(int startUs, int endUs) =>
      _completionTimes.where((t) => t >= startUs && t < endUs).length;

  void begin() {
    _generation++;
    _active = true;
  }

  void end() {
    _generation++;
    _active = false;
  }

  Future<void> offer(F frame, int capturedUs) async {
    if (!_active || busy) {
      dropped++;
      return;
    }
    busy = true;
    inFlightCapturedUs = capturedUs;
    final generation = _generation;
    try {
      final result = await analyze(frame);
      final end = nowUs();
      if (!_active || generation != _generation) return;
      completed++;
      _completionTimes.add(end);
      _completionTimes.removeWhere((t) => t < end - 120000000);
      lastCompletedUs = end;
      lastDurationUs = end - capturedUs;
      if (end < capturedUs || end - capturedUs > maxAgeUs) {
        stale++;
        onDiscard?.call(capturedUs, end);
        return;
      }
      onResult(result, capturedUs, end);
    } catch (error) {
      if (_active && generation == _generation) onError(error);
    } finally {
      busy = false;
      inFlightCapturedUs = null;
    }
  }
}
