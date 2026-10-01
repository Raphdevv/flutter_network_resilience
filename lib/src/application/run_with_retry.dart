import 'dart:math';

import '../domain/network_awareness.dart';
import '../domain/retry_policy.dart';
import '../domain/retry_telemetry.dart';

/// Runs [action], retrying exceptions with capped exponential backoff and jitter.
/// Stops retrying if [networkAwareness] reports no connection after a failure.
Future<T> runWithRetry<T>(
  RetryPolicy policy,
  Future<T> Function() action, {
  NetworkAwareness? networkAwareness,
  RetryTelemetry? telemetry,
  void Function()? checkCancelled,
  Future<void> Function(Duration delay)? waitForRetry,
  Duration? Function(Object error)? retryAfter,
}) async {
  if (policy.baseDelay.isNegative ||
      policy.maxDelay.isNegative ||
      policy.jitter.isNegative) {
    throw ArgumentError('Retry delays must not be negative.');
  }
  var attempts = 0;
  var succeeded = false;
  var lastCallDuration = Duration.zero;
  final totalWatch = telemetry == null ? null : (Stopwatch()..start());
  var backoff = _capDuration(policy.baseDelay, policy.maxDelay);
  try {
    while (true) {
      checkCancelled?.call();
      final callWatch = telemetry == null ? null : (Stopwatch()..start());
      attempts++;
      try {
        final value = await action();
        callWatch?.stop();
        lastCallDuration = callWatch?.elapsed ?? Duration.zero;
        succeeded = true;
        return value;
      } on Exception catch (error) {
        callWatch?.stop();
        lastCallDuration = callWatch?.elapsed ?? Duration.zero;
        if (attempts > policy.retryCount ||
            !(policy.retryIf?.call(error) ?? true)) {
          rethrow;
        }
        if (networkAwareness != null && !await networkAwareness.isConnected) {
          rethrow;
        }
        checkCancelled?.call();
        final jitteredDelay = _applyJitter(backoff, policy);
        final serverDelay = retryAfter?.call(error);
        final delay = serverDelay != null && serverDelay > jitteredDelay
            ? serverDelay
            : jitteredDelay;
        _notifyRetry(telemetry, attempts, lastCallDuration, backoff, delay);
        await (waitForRetry?.call(delay) ?? Future<void>.delayed(delay));
        backoff = _capDuration(backoff * 2, policy.maxDelay);
      }
    }
  } finally {
    _notifyCompletion(
      telemetry,
      totalWatch,
      attempts,
      lastCallDuration,
      succeeded,
    );
  }
}

void _notifyRetry(
  RetryTelemetry? telemetry,
  int attempt,
  Duration callDuration,
  Duration backoff,
  Duration delay,
) {
  telemetry?.onRetry?.call(
    RetryScheduled(
      attempt: attempt,
      callDuration: callDuration,
      backoff: backoff,
      delay: delay,
    ),
  );
}

void _notifyCompletion(
  RetryTelemetry? telemetry,
  Stopwatch? totalWatch,
  int attempts,
  Duration callDuration,
  bool succeeded,
) {
  totalWatch?.stop();
  if (telemetry?.onComplete != null) {
    telemetry!.onComplete!(
      RetryCompleted(
        attempts: attempts,
        callDuration: callDuration,
        totalDuration: totalWatch!.elapsed,
        succeeded: succeeded,
      ),
    );
  }
}

Duration _capDuration(Duration value, Duration max) =>
    value > max ? max : value;

Duration _applyJitter(Duration backoff, RetryPolicy policy) {
  switch (policy.jitterStrategy) {
    case JitterStrategy.none:
      return backoff;
    case JitterStrategy.additive:
      return backoff + Duration(milliseconds: _randomMillis(policy.jitter));
    case JitterStrategy.full:
      return Duration(milliseconds: _randomMillis(backoff));
  }
}

int _randomMillis(Duration upperBound) {
  final millis = upperBound.inMilliseconds;
  return millis <= 0 ? 0 : Random().nextInt(millis + 1);
}
