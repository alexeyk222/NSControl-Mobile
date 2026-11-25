/// Maps timestamps of a native monotonic clock (iOS system uptime, µs) onto
/// the app's own monotonic clock (µs), from messages that carry the native
/// send time and are stamped locally on receipt.
///
/// Every message gives `received − sent = offset + latency` with latency ≥ 0,
/// so the smallest difference in a recent window is the best estimate of the
/// offset; its error is the fastest delivery seen (usually well under 1 ms).
/// The window lets the estimate follow slow drift between the two clocks.
class ClockMap {
  ClockMap({this.windowUs = 10000000});
  final int windowUs;

  // Monotonic deque: deltas increase from front to back, so the front is
  // always the window minimum.
  final List<({int atUs, int delta})> _deque = [];

  bool get ready => _deque.isNotEmpty;

  /// Current offset (local − native), null until the first sample.
  int? get offsetUs => _deque.isEmpty ? null : _deque.first.delta;

  /// Adds one message sent at [nativeUs] and received at [localUs].
  void sample({required int nativeUs, required int localUs}) {
    final delta = localUs - nativeUs;
    while (_deque.isNotEmpty && _deque.last.delta >= delta) {
      _deque.removeLast();
    }
    _deque.add((atUs: localUs, delta: delta));
    while (_deque.length > 1 && _deque.first.atUs < localUs - windowUs) {
      _deque.removeAt(0);
    }
  }

  /// Local time of a native instant; requires [ready].
  int toLocal(int nativeUs) {
    final offset = offsetUs;
    if (offset == null) throw StateError('ClockMap has no samples');
    return nativeUs + offset;
  }

  void reset() => _deque.clear();
}
