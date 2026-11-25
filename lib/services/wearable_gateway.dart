import 'package:uuid/uuid.dart';

typedef WatchMessage = Map<String, Object?>;

/// Sends current state over an immediate transport. It intentionally has no
/// retry queue for alert commands. Phone sound never waits on this gateway.
class WearableGateway {
  WearableGateway({
    required this.nowUs,
    required this.send,
    this.onDelivery,
    this.onVitals,
    this.onUserAck,
    this.onWatchState,
  });
  final int Function() nowUs;
  final Future<void> Function(WatchMessage) send;
  final void Function(WatchMessage message, String status)? onDelivery;

  /// Validated wearable telemetry (heart rate, Body Battery, stress).
  final void Function(WearableVitals vitals)? onVitals;

  /// The user pressed "accept" on the watch for the listed event ids.
  final void Function(List<String> eventIds)? onUserAck;

  /// Apple Watch background mode changed (`active`, `off`, `denied`, ...).
  final void Function(String background)? onWatchState;

  /// Whether the watch app keeps running with its screen off
  /// (`active` = workout session running). Null until the watch reports it.
  String? get watchBackground => _watchBackground;
  String? _watchBackground;
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
  Map<String, Object?> _extra = const {};
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
    Map<String, Object?> extra = const {},
  }) {
    _tripId = tripId;
    _sessionId = sessionId;
    _activeIds = List.of(activeEventIds);
    _recommendation = recommendation;
    _extra = Map.unmodifiable(extra);
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
      ..._extra,
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
      _setBackground(message['background']);
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
    } else if (message['type'] == 'vitals') {
      final vitals = WearableVitals.fromMessage(message, nowUs());
      if (vitals != null) onVitals?.call(vitals);
    } else if (message['type'] == 'watch_state') {
      _setBackground(message['background']);
    } else if (message['type'] == 'user_ack') {
      final ids = message['event_ids'];
      // Only events the phone currently reports as active can be acknowledged.
      final targets = ids is List
          ? ids.whereType<String>().where(_activeIds.contains).toList()
          : List.of(_activeIds);
      if (targets.isNotEmpty) onUserAck?.call(targets);
    }
  }

  void _setBackground(Object? value) {
    if (value is! String || value.isEmpty || value == _watchBackground) return;
    _watchBackground = value;
    onWatchState?.call(value);
  }

  Future<void> alert({
    required String id,
    required String reason,
    required int occurredUs,
    required bool event,
    String? recommendation,
    String? kind,
  }) async {
    final age = nowUs() - occurredUs;
    if (!synchronized || age < 0 || age >= 2000000) return;
    await _transmit({
      ..._envelope('alert'),
      if (event) 'event_id': id else 'recommendation_id': id,
      'reason': reason,
      'alarm': ?kind,
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

/// Telemetry sent by the Garmin app. Values outside physiological ranges are
/// dropped individually; a message without any valid value is ignored.
class WearableVitals {
  const WearableVitals({
    required this.receivedUs,
    this.heartRate,
    this.bodyBattery,
    this.stress,
  });
  final int receivedUs;
  final int? heartRate, bodyBattery, stress;

  static int? _ranged(Object? value, int min, int max) {
    if (value is! num || !value.isFinite) return null;
    final v = value.round();
    return v < min || v > max ? null : v;
  }

  static WearableVitals? fromMessage(WatchMessage m, int nowUs) {
    final hr = _ranged(m['hr'], 25, 240);
    final battery = _ranged(m['body_battery'], 0, 100);
    final stress = _ranged(m['stress'], 0, 100);
    if (hr == null && battery == null && stress == null) return null;
    return WearableVitals(
      receivedUs: nowUs,
      heartRate: hr,
      bodyBattery: battery,
      stress: stress,
    );
  }

  Map<String, Object?> toJson() => {
    'hr': heartRate,
    'body_battery': bodyBattery,
    'stress': stress,
  };
}
