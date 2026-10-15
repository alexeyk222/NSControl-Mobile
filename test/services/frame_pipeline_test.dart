import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/services/frame_pipeline.dart';

void main() {
  test(
    'performance buckets use half-open monotonic minutes including late analyses',
    () async {
      var now = 59999999;
      final pipe = FramePipeline<int, int>(
        analyze: (v) async => v,
        onResult: (_, _, _) {},
        onError: (_) {},
        nowUs: () => now,
      );
      pipe.begin();
      await pipe.offer(1, now);
      now = 60000000;
      await pipe.offer(2, now);
      now = 60300001;
      await pipe.offer(3, 60000000);
      expect(pipe.completedBetween(0, 60000000), 1);
      expect(pipe.completedBetween(60000000, 120000000), 2);
    },
  );
  test('busy detector drops frames without queueing them', () async {
    final pending = Completer<int>();
    var calls = 0;
    final results = <int>[];
    final pipe = FramePipeline<int, int>(
      analyze: (frame) {
        calls++;
        return pending.future;
      },
      onResult: (result, captured, completed) => results.add(result),
      onError: (_) {},
      nowUs: () => 100,
    );
    pipe.begin();
    final first = pipe.offer(1, 0);
    await pipe.offer(2, 1);
    expect(calls, 1);
    expect(pipe.dropped, 1);
    pending.complete(7);
    await first;
    expect(results, [7]);
  });

  test('old session completion cannot enter a replacement session', () async {
    final pending = Completer<int>();
    final results = <int>[];
    final pipe = FramePipeline<int, int>(
      analyze: (_) => pending.future,
      onResult: (r, _, _) => results.add(r),
      onError: (_) {},
      nowUs: () => 50,
    );
    pipe.begin();
    final old = pipe.offer(1, 0);
    pipe.end();
    pipe.begin();
    pending.complete(1);
    await old;
    expect(results, isEmpty);
    expect(pipe.busy, isFalse);
  });

  test('late analysis and detector failure release backpressure', () async {
    var now = 300001;
    var fail = false;
    var errors = 0;
    final results = <int>[];
    final pipe = FramePipeline<int, int>(
      analyze: (f) async {
        if (fail) throw StateError('camera');
        return f;
      },
      onResult: (r, _, _) => results.add(r),
      onError: (_) => errors++,
      nowUs: () => now,
    );
    pipe.begin();
    await pipe.offer(1, 0);
    expect(results, isEmpty);
    expect(pipe.completed, 1);
    expect(pipe.stale, 1);
    fail = true;
    await pipe.offer(2, now);
    expect(errors, 1);
    expect(pipe.busy, isFalse);
    fail = false;
    now = 400000;
    await pipe.offer(3, 399999);
    expect(results, [3]);
  });
}
