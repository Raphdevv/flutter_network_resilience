import 'package:dio/dio.dart';

import '../domain/network_awareness.dart';
import '../domain/resilience_request.dart';
import '../domain/retry_policy.dart';
import '../domain/retry_telemetry.dart';
import 'dio_resilience_client.dart';

/// Dio-facing HTTP facade with an optional retry policy per request.
abstract class ResilienceClient {
  factory ResilienceClient({
    required Dio dio,
    NetworkAwareness? networkAwareness,
    RetryTelemetry? telemetry,
  }) = ResilienceClientImpl;

  /// For alternate transport implementations.
  ResilienceClient.base();

  Future<Response<T>> request<T>(
    ResilienceRequest request, {
    RetryPolicy retryPolicy = RetryPolicy.noRetry,
    CancelToken? cancelToken,
  });

  Future<Response<T>> get<T>(
    String path, {
    Map<String, dynamic>? params,
    Map<String, String>? headers,
    RetryPolicy retryPolicy = RetryPolicy.noRetry,
    CancelToken? cancelToken,
  }) => request(
    ResilienceRequest(
      method: ResilienceMethod.get,
      path: path,
      params: params,
      headers: headers,
    ),
    retryPolicy: retryPolicy,
    cancelToken: cancelToken,
  );

  Future<Response<T>> post<T>(
    String path, {
    Map<String, dynamic>? params,
    Object? body,
    Map<String, String>? headers,
    RetryPolicy retryPolicy = RetryPolicy.noRetry,
    CancelToken? cancelToken,
  }) => _send(
    ResilienceMethod.post,
    path,
    params,
    body,
    headers,
    retryPolicy,
    cancelToken,
  );

  Future<Response<T>> put<T>(
    String path, {
    Map<String, dynamic>? params,
    Object? body,
    Map<String, String>? headers,
    RetryPolicy retryPolicy = RetryPolicy.noRetry,
    CancelToken? cancelToken,
  }) => _send(
    ResilienceMethod.put,
    path,
    params,
    body,
    headers,
    retryPolicy,
    cancelToken,
  );

  Future<Response<T>> patch<T>(
    String path, {
    Map<String, dynamic>? params,
    Object? body,
    Map<String, String>? headers,
    RetryPolicy retryPolicy = RetryPolicy.noRetry,
    CancelToken? cancelToken,
  }) => _send(
    ResilienceMethod.patch,
    path,
    params,
    body,
    headers,
    retryPolicy,
    cancelToken,
  );

  Future<Response<T>> delete<T>(
    String path, {
    Map<String, dynamic>? params,
    Object? body,
    Map<String, String>? headers,
    RetryPolicy retryPolicy = RetryPolicy.noRetry,
    CancelToken? cancelToken,
  }) => _send(
    ResilienceMethod.delete,
    path,
    params,
    body,
    headers,
    retryPolicy,
    cancelToken,
  );

  Future<Response<T>> _send<T>(
    ResilienceMethod method,
    String path,
    Map<String, dynamic>? params,
    Object? body,
    Map<String, String>? headers,
    RetryPolicy retryPolicy,
    CancelToken? cancelToken,
  ) => request(
    ResilienceRequest(
      method: method,
      path: path,
      params: params,
      body: body,
      headers: headers,
    ),
    retryPolicy: retryPolicy,
    cancelToken: cancelToken,
  );
}
