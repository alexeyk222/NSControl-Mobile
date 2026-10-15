import 'dart:async';
import 'package:flutter/services.dart';

/// Only the platform boundary knows Flutter channels. Missing capabilities are
/// surfaced as unavailable; a transport ACK is never labelled vibration proof.
class PlatformBridge {
  const PlatformBridge();
  static const _methods = MethodChannel('nscontrol/platform');
  static const _events = EventChannel('nscontrol/events');
  Stream<Map<String, Object?>> get events => _events
      .receiveBroadcastStream()
      .map((event) => Map<String, Object?>.from(event as Map));

  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    final value = await _methods.invokeMethod<Object?>(method, arguments);
    return value is Map ? Map<String, Object?>.from(value) : {'status': 'ok'};
  }

  Future<void> alert({required double volume, required bool vibrate}) async {
    _requireOutput(
      await call('alert.start', {'volume': volume, 'vibrate': vibrate}),
    );
  }

  Future<void> stopAlert() async {
    await call('alert.stop');
  }

  Future<void> testAlert({
    required double volume,
    required bool vibrate,
  }) async {
    _requireOutput(
      await call('alert.test', {'volume': volume, 'vibrate': vibrate}),
    );
  }

  Future<void> keepAwake(bool enabled) async {
    await call('screen.keepAwake', {'enabled': enabled});
  }

  Future<List<Map<String, Object?>>> wearableDevices() async {
    final value = await _methods.invokeMethod<Object?>('wearable.devices');
    if (value is List) {
      return value
          .whereType<Map>()
          .map((m) => Map<String, Object?>.from(m))
          .toList();
    }
    if (value is Map && value['devices'] is List) {
      return (value['devices'] as List)
          .whereType<Map>()
          .map((m) => Map<String, Object?>.from(m))
          .toList();
    }
    return [];
  }

  Future<void> send(Map<String, Object?> message) async {
    final result = await call('wearable.send', {'message': message});
    if (result['accepted'] != true) {
      throw StateError(
        (result['reason'] ??
                result['message'] ??
                result['status'] ??
                'Часы недоступны')
            .toString(),
      );
    }
  }

  void _requireOutput(Map<String, Object?> result) {
    if (result['status'] == 'error' || result['status'] == 'unavailable') {
      throw StateError(
        (result['reason'] ?? result['message'] ?? 'Оповещение недоступно')
            .toString(),
      );
    }
  }
}
