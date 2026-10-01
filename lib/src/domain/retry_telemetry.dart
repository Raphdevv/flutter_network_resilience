/// Timing and delay metadata for a retry scheduled after a failed attempt.
class RetryScheduled {
  const RetryScheduled({
    required this.attempt,
    required this.callDuration,
    required this.backoff,
    required this.delay,
  });

  /// One-based number of the attempt that failed.
  final int attempt;
  final Duration callDuration;
  final Duration backoff;

  /// Actual scheduled wait, after applying jitter.
  final Duration delay;
}

/// Final timing metadata, including all attempts and waits.
class RetryCompleted {
  const RetryCompleted({
    required this.attempts,
    required this.callDuration,
    required this.totalDuration,
    required this.succeeded,
  });

  final int attempts;

  /// Duration of the final call, excluding waits and earlier attempts.
  final Duration callDuration;
  final Duration totalDuration;
  final bool succeeded;
}

/// Optional observation hooks; no request data or error messages are included.
class RetryTelemetry {
  const RetryTelemetry({this.onRetry, this.onComplete});

  final void Function(RetryScheduled event)? onRetry;
  final void Function(RetryCompleted event)? onComplete;
}
