import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/services/wearable_gateway.dart';

void main() {
  test(
    'reconnect sends snapshot and ping, never replays alert queue',
    () async {
      var now = 1000000;
      final sent = <Map<String, Object?>>[];
      final gateway = WearableGateway(
        nowUs: () => now,
        send: (m) async {
          sent.add(m);
        },
      );
      gateway.setState(
        tripId: 't',
        sessionId: 's',
        activeEventIds: ['e'],
        recommendation: 'Отдых',
      );
      await gateway.alert(
        id: 'e',
        reason: 'Глаза',
        occurredUs: now,
        event: true,
      );
      expect(sent, isEmpty);
      await gateway.connect();
      await gateway.receive({
        'type': 'ready',
        'receiver_epoch': 'epoch',
        'connection_id': sent.last['connection_id'],
      });
      expect(sent.map((m) => m['type']), ['hello', 'snapshot', 'ping']);
      expect(sent[1]['active_event_ids'], ['e']);
      now += 3000000;
      gateway.disconnect();
      await gateway.connect();
      await gateway.receive({
        'type': 'ready',
        'receiver_epoch': 'epoch',
        'connection_id': sent.last['connection_id'],
      });
      expect(sent.where((m) => m['type'] == 'alert'), isEmpty);
      expect(sent.first['connection_id'], isNot(sent[3]['connection_id']));
    },
  );

  test(
    'clock sync uses conservative lower bound and rejects stale pongs',
    () async {
      var now = 1000000;
      final sent = <Map<String, Object?>>[];
      final gateway = WearableGateway(
        nowUs: () => now,
        send: (m) async {
          sent.add(m);
        },
      );
      await gateway.connect();
      await gateway.receive({
        'type': 'ready',
        'receiver_epoch': 'epoch',
        'connection_id': sent.last['connection_id'],
      });
      final ping = sent.last;
      now = 1200000;
      await gateway.receive({
        'type': 'pong',
        'receiver_epoch': 'epoch',
        'connection_id': ping['connection_id'],
        'ack_message_id': ping['message_id'],
        'phone_sent_us': 1000000,
        'watch_received_ms': 6000,
        'watch_sent_ms': 6010,
      });
      expect(sent.last['type'], 'clock_sync');
      expect(sent.last['watch_minus_phone_lower_ms'], 4810.0);
      expect(
        gateway.synchronized,
        isFalse,
        reason: 'Transport send is not a clock acceptance ACK',
      );
      final sync = sent.last;
      await gateway.receive({
        'type': 'ack',
        'connection_id': sync['connection_id'],
        'receiver_epoch': 'epoch',
        'ack_message_id': sync['message_id'],
        'status': 'synchronized',
      });
      expect(gateway.synchronized, isTrue);
      await gateway.alert(
        id: 'e',
        reason: 'Глаза',
        occurredUs: 1100000,
        event: true,
      );
      expect(sent.last['type'], 'alert');
      expect(sent.last['occurred_us'], 1100000);
      now = 4000000;
      final count = sent.length;
      await gateway.alert(
        id: 'old',
        reason: 'Глаза',
        occurredUs: 1000000,
        event: true,
      );
      expect(sent.length, count);
      gateway.disconnect();
      await gateway.receive({
        'type': 'pong',
        'receiver_epoch': 'epoch',
        'connection_id': ping['connection_id'],
        'ack_message_id': ping['message_id'],
        'phone_sent_us': 1000000,
        'watch_received_ms': 6000,
        'watch_sent_ms': 6010,
      });
      expect(gateway.synchronized, isFalse);
    },
  );

  test('cancel targets specific IDs and sync lifetime is bounded', () async {
    var now = 0;
    final sent = <Map<String, Object?>>[];
    final gateway = WearableGateway(
      nowUs: () => now,
      send: (m) async {
        sent.add(m);
      },
    );
    await gateway.connect();
    await gateway.receive({
      'type': 'ready',
      'receiver_epoch': 'epoch',
      'connection_id': sent.last['connection_id'],
    });
    final id = sent.last['connection_id'];
    final pingId = sent.last['message_id'];
    now = 10000;
    await gateway.receive({
      'type': 'pong',
      'receiver_epoch': 'epoch',
      'connection_id': id,
      'ack_message_id': pingId,
      'phone_sent_us': 0,
      'watch_received_ms': 400,
      'watch_sent_ms': 400,
    });
    await gateway.cancel(['e1']);
    expect(sent.last['target_ids'], ['e1']);
    now = 31000000;
    expect(gateway.synchronized, isFalse);
  });
}
