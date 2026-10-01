import 'dart:async';

import 'package:dio/dio.dart';
import 'package:http_parser/http_parser.dart' show parseHttpDate;

import '../application/run_with_retry.dart';
import '../domain/network_awareness.dart';
import '../domain/resilience_request.dart';
import '../domain/retry_policy.dart';
import '../domain/retry_telemetry.dart';
import 'resilience_client.dart';

const _tooManyRequestsStatus = 429;
const _serverErrorStart = 500;
const _serverErrorEnd = 600;
const _serviceUnavailableStatus = 503;
const _retryAfterHeader = 'retry-after';

/// Executes [ResilienceRequest] through the supplied [Dio] instance.
class ResilienceClientImpl extends ResilienceClient {
  ResilienceClientImpl({
    required this.dio,
    NetworkAwareness? networkAwareness,
    RetryTelemetry? telemetry,
  }) : _networkAwareness = networkAwareness,
       _telemetry = telemetry,
       super.base();

  final Dio dio;
  final NetworkAwareness? _networkAwareness;
  final RetryTelemetry? _telemetry;

  @override
  Future<Response<T>> request<T>(
    ResilienceRequest request, {
    RetryPolicy retryPolicy = RetryPolicy.noRetry,
    CancelToken? cancelToken,
  }) {
    if (request.path.isEmpty) {
      throw ArgumentError.value(request.path, 'path', 'Must not be empty');
    }
    if (retryPolicy.retryCount > 0 &&
        (request.body is FormData || request.body is Stream)) {
      throw ArgumentError(
        'Retrying FormData or Stream bodies is unsupported; use noRetry or a replayable body.',
      );
    }
    final effectivePolicy = retryPolicy.retryIf == null
        ? RetryPolicy(
            retryCount: retryPolicy.retryCount,
            baseDelay: retryPolicy.baseDelay,
            maxDelay: retryPolicy.maxDelay,
            jitter: retryPolicy.jitter,
            jitterStrategy: retryPolicy.jitterStrategy,
            retryIf: _isRetryableHttpError,
          )
        : retryPolicy;
    return runWithRetry(
      effectivePolicy,
      () => dio.request<T>(
        request.path,
        data: request.body,
        queryParameters: request.params,
        options: Options(
          method: request.method.name.toUpperCase(),
          headers: request.headers,
        ),
        cancelToken: cancelToken,
      ),
      networkAwareness: _networkAwareness,
      telemetry: _telemetry,
      checkCancelled: cancelToken == null
          ? null
          : () => _throwIfCancelled(cancelToken),
      waitForRetry: cancelToken == null
          ? null
          : (delay) => _waitForRetry(cancelToken, delay),
      retryAfter: _retryAfter,
    );
  }

  static Duration? _retryAfter(Object error) {
    if (error is! DioException ||
        (error.response?.statusCode != _tooManyRequestsStatus &&
            error.response?.statusCode != _serviceUnavailableStatus)) {
      return null;
    }
    final value = error.response?.headers[_retryAfterHeader]?.first.trim();
    if (value == null) return null;
    final seconds = int.tryParse(value);
    if (seconds != null) {
      return seconds >= 0 ? Duration(seconds: seconds) : null;
    }
    try {
      final duration = parseHttpDate(value).difference(DateTime.now().toUtc());
      return duration > Duration.zero ? duration : null;
    } on FormatException {
      return null;
    }
  }

  static void _throwIfCancelled(CancelToken token) {
    if (token.isCancelled) throw token.cancelError!;
  }

  static Future<void> _waitForRetry(CancelToken token, Duration delay) =>
      Future.any<void>([
        Future<void>.delayed(delay),
        token.whenCancel.then<void>((error) => throw error),
      ]);

  static bool _isRetryableHttpError(Object error) {
    if (error is! DioException) return false;
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return true;
      case DioExceptionType.badResponse:
        final status = error.response?.statusCode;
        return status == _tooManyRequestsStatus ||
            (status != null &&
                status >= _serverErrorStart &&
                status < _serverErrorEnd);
      default:
        return false;
    }
  }
}
