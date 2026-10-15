import 'package:uuid/uuid.dart';

typedef WatchMessage = Map<String, Object?>;

/// Sends current state over an immediate transport. It intentionally has no
/// retry queue for alert commands. Phone sound never waits on this gateway.
class WearableGateway {
  WearableGateway({required this.nowUs, required this.send, this.onDelivery});
  final int Function() nowUs;
  final Future<void> Function(WatchMessage) send;
  final void Function(WatchMessage message, String status)? onDelivery;
  final _ids = const Uuid();
  String? _connectionId;
  String? _receiverEpoch;
  String? _syncId;
  int? _syncedUs;
  int? _pingUs;
  String? _pingId;
  String? _syncMessageId;
  int? _syncRequestedUs;
  bool _connected = false;
  String? _tripId;
  String? _sessionId;
  List<String> _activeIds = [];
  String? _recommendation;
  bool get connected => _connected;
  bool get synchronized =>
      _connected &&
      _syncedUs != null &&
      nowUs() >= _syncedUs! &&
      nowUs() - _syncedUs! < 30000000;

  WatchMessage _envelope(String type) => {
    'v': 1,
    'type': type,
    'message_id': _ids.v4(),
    'connection_id': _connectionId,
    'receiver_epoch': _receiverEpoch,
    'trip_id': _tripId,
    'session_id': _sessionId,
  };

  void setState({
    String? tripId,
    String? sessionId,
    List<String> activeEventIds = const [],
    String? recommendation,
  }) {
    _tripId = tripId;
    _sessionId = sessionId;
    _activeIds = List.of(activeEventIds);
    _recommendation = recommendation;
  }

  Future<void> _transmit(WatchMessage message) async {
    onDelivery?.call(message, 'sending');
    try {
      await send(message);
      onDelivery?.call(message, 'sent');
    } catch (_) {
      onDelivery?.call(message, 'failed');
      disconnect();
    }
  }

  Future<void> connect() async {
    disconnect();
    _connected = true;
    _connectionId = _ids.v4();
    await _transmit(_envelope('hello'));
  }

  void disconnect() {
    _connected = false;
    _receiverEpoch = null;
    _syncId = null;
    _syncedUs = null;
    _pingUs = null;
    _pingId = null;
    _syncMessageId = null;
    _syncRequestedUs = null;
  }

  Future<void> snapshot() async {
    if (!_connected || _receiverEpoch == null) return;
    await _transmit({
      ..._envelope('snapshot'),
      'active_event_ids': _activeIds,
      'recommendation': _recommendation,
    });
  }

  Future<void> synchronize() async {
    if (!_connected || _receiverEpoch == null) return;
    _pingUs = nowUs();
    final ping = {..._envelope('ping'), 'phone_sent_us': _pingUs};
    _pingId = ping['message_id'] as String;
    await _transmit(ping);
  }

  Future<void> receive(WatchMessage message) async {
    if (!_connected) return;
    if (message['type'] == 'ready') {
      final connection = message['connection_id'];
      if (connection != null && connection != _connectionId) return;
      final epoch = message['receiver_epoch'];
      if (epoch is! String || epoch.isEmpty) return;
      _receiverEpoch = epoch;
      _syncedUs = null;
      _syncId = null;
      await snapshot();
      await synchronize();
      return;
    }
    if (message['connection_id'] != _connectionId ||
        message['receiver_epoch'] != _receiverEpoch) {
      return;
    }
    if (message['type'] == 'pong') {
      final sent = message['phone_sent_us'];
      final received = message['watch_received_ms'];
      final watchSent = message['watch_sent_ms'];
      final now = nowUs();
      if (sent is! int ||
          sent != _pingUs ||
          message['ack_message_id'] != _pingId ||
          received is! num ||
          watchSent is! num ||
          !received.isFinite ||
          !watchSent.isFinite ||
          watchSent < received ||
          now < sent ||
          now - sent > 2000000) {
        return;
      }
      _syncId = _pingId;
      _syncedUs = null;
      _syncRequestedUs = now;
      _pingUs = null;
      _pingId = null;
      final sync = <String, Object?>{
        ..._envelope('clock_sync'),
        'sync_id': _syncId,
        'watch_minus_phone_lower_ms': watchSent - now / 1000.0,
      };
      _syncMessageId = sync['message_id'] as String;
      await _transmit(sync);
    } else if (message['type'] == 'ack') {
      if (message['ack_message_id'] == _syncMessageId) {
        _syncedUs = message['status'] == 'synchronized'
            ? _syncRequestedUs
            : null;
        _syncMessageId = null;
        _syncRequestedUs = null;
      }
      onDelivery?.call(message, 'received_${message['status']}');
    }
  }

  Future<void> alert({
    required String id,
    required String reason,
    required int occurredUs,
    required bool event,
    String? recommendation,
  }) async {
    final age = nowUs() - occurredUs;
    if (!synchronized || age < 0 || age >= 2000000) return;
    await _transmit({
      ..._envelope('alert'),
      if (event) 'event_id': id else 'recommendation_id': id,
      'reason': reason,
      'recommendation': ?recommendation,
      'occurred_us': occurredUs,
      'ttl_ms': 2000,
      'sync_id': _syncId,
    });
  }

  Future<void> cancel(List<String> targetIds, {bool all = false}) async {
    if (!_connected || _receiverEpoch == null) return;
    await _transmit({
      ..._envelope('cancel'),
      'target_ids': targetIds,
      'all': all,
    });
  }
}
