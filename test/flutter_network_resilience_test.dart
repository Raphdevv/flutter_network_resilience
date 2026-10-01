import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_network_resilience/flutter_network_resilience.dart';
import 'package:flutter_network_resilience/src/application/run_with_retry.dart';

class TestNetworkAwareness implements NetworkAwareness {
  TestNetworkAwareness(this.connected);

  final bool connected;
  int checks = 0;

  @override
  Future<bool> get isConnected async {
    checks++;
    return connected;
  }
}

void main() {
  test('noRetry runs the action once and preserves its error', () async {
    final failure = Exception('failure');
    var attempts = 0;

    await expectLater(
      runWithRetry(RetryPolicy.noRetry, () async {
        attempts++;
        throw failure;
      }),
      throwsA(same(failure)),
    );
    expect(attempts, 1);
  });

  test('returns the first successful result after retries', () async {
    var attempts = 0;
    final value = await runWithRetry(
      const RetryPolicy(retryCount: 2, baseDelay: Duration.zero),
      () async {
        attempts++;
        if (attempts < 3) throw Exception('temporary');
        return 42;
      },
    );

    expect(value, 42);
    expect(attempts, 3);
  });

  test('waits with exponential backoff up to the cap', () async {
    final stopwatch = Stopwatch()..start();
    final scheduled = <RetryScheduled>[];
    final completed = <RetryCompleted>[];
    var attempts = 0;

    await runWithRetry(
      const RetryPolicy(
        retryCount: 2,
        baseDelay: Duration(milliseconds: 20),
        maxDelay: Duration(milliseconds: 30),
        jitterStrategy: JitterStrategy.none,
      ),
      () async {
        attempts++;
        if (attempts < 3) throw Exception('temporary');
      },
      telemetry: RetryTelemetry(
        onRetry: scheduled.add,
        onComplete: completed.add,
      ),
    );

    expect(attempts, 3);
    expect(scheduled.map((event) => event.attempt), [1, 2]);
    expect(scheduled.map((event) => event.backoff), [
      const Duration(milliseconds: 20),
      const Duration(milliseconds: 30),
    ]);
    expect(scheduled.map((event) => event.delay), [
      const Duration(milliseconds: 20),
      const Duration(milliseconds: 30),
    ]);
    expect(scheduled.every((event) => !event.callDuration.isNegative), isTrue);
    expect(completed, hasLength(1));
    expect(completed.single.attempts, 3);
    expect(completed.single.succeeded, isTrue);
    expect(
      completed.single.totalDuration,
      greaterThanOrEqualTo(completed.single.callDuration),
    );
    expect(
      stopwatch.elapsed,
      greaterThanOrEqualTo(const Duration(milliseconds: 45)),
    );
  });

  test('doubles backoff until the configured cap', () async {
    final scheduled = <RetryScheduled>[];
    var attempts = 0;

    await runWithRetry(
      const RetryPolicy(
        retryCount: 3,
        baseDelay: Duration(milliseconds: 2),
        maxDelay: Duration(milliseconds: 5),
        jitterStrategy: JitterStrategy.none,
      ),
      () async {
        attempts++;
        if (attempts < 4) throw Exception('temporary');
      },
      telemetry: RetryTelemetry(onRetry: scheduled.add),
    );

    expect(attempts, 4);
    expect(scheduled.map((event) => event.backoff), [
      const Duration(milliseconds: 2),
      const Duration(milliseconds: 4),
      const Duration(milliseconds: 5),
    ]);
    expect(
      scheduled.map((event) => event.delay),
      scheduled.map((event) => event.backoff),
    );
  });

  for (final strategy in [JitterStrategy.additive, JitterStrategy.full]) {
    test('$strategy stays within its randomized delay bounds', () async {
      final scheduled = <RetryScheduled>[];
      var attempts = 0;

      await runWithRetry(
        RetryPolicy(
          retryCount: 1,
          baseDelay: const Duration(milliseconds: 10),
          jitter: const Duration(milliseconds: 4),
          jitterStrategy: strategy,
        ),
        () async {
          attempts++;
          if (attempts == 1) throw Exception('temporary');
        },
        telemetry: RetryTelemetry(onRetry: scheduled.add),
      );

      final delay = scheduled.single.delay;
      final backoff = scheduled.single.backoff;
      if (strategy == JitterStrategy.additive) {
        expect(delay, greaterThanOrEqualTo(backoff));
        expect(
          delay,
          lessThanOrEqualTo(backoff + const Duration(milliseconds: 4)),
        );
      } else {
        expect(delay, greaterThanOrEqualTo(Duration.zero));
        expect(delay, lessThanOrEqualTo(backoff));
      }
      expect(attempts, 2);
    });
  }

  test('stops at the retry limit and preserves the last error', () async {
    final failure = Exception('persistent');
    var attempts = 0;

    await expectLater(
      runWithRetry(
        const RetryPolicy(retryCount: 2, baseDelay: Duration.zero),
        () async {
          attempts++;
          throw failure;
        },
      ),
      throwsA(same(failure)),
    );
    expect(attempts, 3);
  });

  test('emits completion without retry when the call fails', () async {
    final scheduled = <RetryScheduled>[];
    final completed = <RetryCompleted>[];

    await expectLater(
      runWithRetry(
        RetryPolicy.noRetry,
        () async => throw Exception('failed'),
        telemetry: RetryTelemetry(
          onRetry: scheduled.add,
          onComplete: completed.add,
        ),
      ),
      throwsException,
    );
    expect(scheduled, isEmpty);
    expect(completed, hasLength(1));
    expect(completed.single.attempts, 1);
    expect(completed.single.succeeded, isFalse);
  });

  test('retryIf can stop retries', () async {
    final failure = Exception('not retryable');
    var attempts = 0;

    await expectLater(
      runWithRetry(
        RetryPolicy(
          retryCount: 3,
          retryIf: (error) => !identical(error, failure),
        ),
        () async {
          attempts++;
          throw failure;
        },
      ),
      throwsA(same(failure)),
    );
    expect(attempts, 1);
  });

  test('stops retrying when the network is offline', () async {
    final awareness = TestNetworkAwareness(false);
    final failure = Exception('offline');
    final scheduled = <RetryScheduled>[];
    final completed = <RetryCompleted>[];
    var attempts = 0;

    await expectLater(
      runWithRetry(
        const RetryPolicy(retryCount: 3),
        () async {
          attempts++;
          throw failure;
        },
        networkAwareness: awareness,
        telemetry: RetryTelemetry(
          onRetry: scheduled.add,
          onComplete: completed.add,
        ),
      ),
      throwsA(same(failure)),
    );
    expect(attempts, 1);
    expect(awareness.checks, 1);
    expect(scheduled, isEmpty);
    expect(completed.single.succeeded, isFalse);
  });

  test('skips the network check when the action succeeds', () async {
    final awareness = TestNetworkAwareness(false);

    expect(
      await runWithRetry(
        const RetryPolicy(retryCount: 1),
        () async => 42,
        networkAwareness: awareness,
      ),
      42,
    );
    expect(awareness.checks, 0);
  });

  for (final strategy in JitterStrategy.values) {
    test('retries with $strategy jitter', () async {
      var attempts = 0;
      final value = await runWithRetry(
        RetryPolicy(
          retryCount: 1,
          baseDelay: Duration.zero,
          jitter: Duration.zero,
          jitterStrategy: strategy,
        ),
        () async {
          attempts++;
          if (attempts == 1) throw Exception('temporary');
          return 42;
        },
      );

      expect(value, 42);
      expect(attempts, 2);
    });
  }

  test('rejects negative delays before running the action', () async {
    var attempts = 0;

    await expectLater(
      runWithRetry(
        const RetryPolicy(baseDelay: Duration(milliseconds: -1)),
        () async {
          attempts++;
          return 42;
        },
      ),
      throwsArgumentError,
    );
    expect(attempts, 0);
  });
}
