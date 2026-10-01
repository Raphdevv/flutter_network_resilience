/// How the delay between retry attempts is randomized.
enum JitterStrategy {
  /// Use the exponential backoff value as-is.
  none,

  /// Add a random amount between zero and [RetryPolicy.jitter].
  additive,

  /// Replace the backoff with a random delay between zero and the backoff.
  full,
}

/// Retry configuration; [retryCount] counts retries after the first attempt.
class RetryPolicy {
  const RetryPolicy({
    this.retryCount = 0,
    this.baseDelay = const Duration(milliseconds: 300),
    this.maxDelay = const Duration(seconds: 5),
    this.jitter = const Duration(milliseconds: 100),
    this.jitterStrategy = JitterStrategy.additive,
    this.retryIf,
  }) : assert(retryCount >= 0);

  final int retryCount;
  final Duration baseDelay;

  /// Caps the exponential backoff before jitter is applied.
  final Duration maxDelay;
  final Duration jitter;
  final JitterStrategy jitterStrategy;

  /// Return true to retry [error]; null retries any [Exception].
  final bool Function(Object error)? retryIf;

  static const RetryPolicy noRetry = RetryPolicy();
}
