import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_network_resilience/flutter_network_resilience.dart';
import 'package:http_parser/http_parser.dart' show formatHttpDate;

class OfflineNetwork implements NetworkAwareness {
  int checks = 0;

  @override
  Future<bool> get isConnected async {
    checks++;
    return false;
  }
}

void main() {
  final quickRetry = RetryPolicy(retryCount: 1, baseDelay: Duration.zero);

  test('maps paths, params, bodies and HTTP methods to Dio', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test'));
    final seen = <RequestOptions>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          seen.add(options);
          handler.resolve(Response(requestOptions: options, data: 'ok'));
        },
      ),
    );
    final ResilienceClient client = ResilienceClient(dio: dio);

    expect(
      (await client.get<String>('/items', params: {'page': 2})).data,
      'ok',
    );
    await client.post<String>(
      '/items',
      body: {'name': 'new'},
      headers: {'Idempotency-Key': 'operation-1'},
    );
    await client.put<String>('/items/1', body: {'name': 'updated'});
    await client.patch<String>('/items/1', body: {'name': 'patched'});
    await client.delete<String>('/items/1', params: {'hard': true});
    await client.request<String>(
      const ResilienceRequest(
        method: ResilienceMethod.post,
        path: '/custom',
        body: 'raw',
      ),
    );

    expect(seen.map((options) => options.method), [
      'GET',
      'POST',
      'PUT',
      'PATCH',
      'DELETE',
      'POST',
    ]);
    expect(seen.first.path, '/items');
    expect(seen.first.queryParameters, {'page': 2});
    expect(seen[1].data, {'name': 'new'});
    expect(seen[1].headers['Idempotency-Key'], 'operation-1');
    expect(seen[2].data, {'name': 'updated'});
    expect(seen[2].headers.containsKey('Idempotency-Key'), isFalse);
    expect(seen[3].data, {'name': 'patched'});
    expect(seen[4].queryParameters, {'hard': true});
    expect(seen.last.data, 'raw');
  });

  for (final status in [429, 500, 503]) {
    test('retries HTTP $status with the default classifier', () async {
      final dio = Dio();
      var attempts = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            attempts++;
            if (attempts == 1) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  response: Response(
                    requestOptions: options,
                    statusCode: status,
                  ),
                  type: DioExceptionType.badResponse,
                ),
              );
            } else {
              handler.resolve(Response(requestOptions: options, data: 'ok'));
            }
          },
        ),
      );

      final response = await ResilienceClient(
        dio: dio,
      ).get<String>('/items', retryPolicy: quickRetry);
      expect(response.data, 'ok');
      expect(attempts, 2);
    });
  }

  for (final type in [
    DioExceptionType.connectionTimeout,
    DioExceptionType.sendTimeout,
    DioExceptionType.receiveTimeout,
    DioExceptionType.connectionError,
  ]) {
    test('retries $type with the default classifier', () async {
      final dio = Dio();
      var attempts = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            attempts++;
            if (attempts == 1) {
              handler.reject(DioException(requestOptions: options, type: type));
            } else {
              handler.resolve(Response(requestOptions: options, data: 'ok'));
            }
          },
        ),
      );

      await ResilienceClient(
        dio: dio,
      ).get<String>('/items', retryPolicy: quickRetry);
      expect(attempts, 2);
    });
  }

  test('does not retry a client error', () async {
    final dio = Dio();
    var attempts = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          attempts++;
          handler.reject(
            DioException(
              requestOptions: options,
              response: Response(requestOptions: options, statusCode: 404),
              type: DioExceptionType.badResponse,
            ),
          );
        },
      ),
    );

    await expectLater(
      ResilienceClient(
        dio: dio,
      ).get<String>('/missing', retryPolicy: quickRetry),
      throwsA(isA<DioException>()),
    );
    expect(attempts, 1);
  });

  test('does not retry by default, even for transient errors', () async {
    final dio = Dio();
    var attempts = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          attempts++;
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.connectionTimeout,
            ),
          );
        },
      ),
    );

    await expectLater(
      ResilienceClient(dio: dio).get<String>('/items'),
      throwsA(isA<DioException>()),
    );
    expect(attempts, 1);
  });

  test('caller retryIf overrides the Dio classifier', () async {
    final dio = Dio();
    var attempts = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          attempts++;
          if (attempts == 1) {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response(requestOptions: options, statusCode: 404),
                type: DioExceptionType.badResponse,
              ),
            );
          } else {
            handler.resolve(Response(requestOptions: options, data: 'ok'));
          }
        },
      ),
    );

    final response = await ResilienceClient(dio: dio).get<String>(
      '/items',
      retryPolicy: RetryPolicy(
        retryCount: 1,
        baseDelay: Duration.zero,
        retryIf: (error) => error is DioException,
      ),
    );
    expect(response.data, 'ok');
    expect(attempts, 2);
  });

  test('does not retry while network awareness reports offline', () async {
    final dio = Dio();
    final network = OfflineNetwork();
    var attempts = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          attempts++;
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
            ),
          );
        },
      ),
    );

    await expectLater(
      ResilienceClient(
        dio: dio,
        networkAwareness: network,
      ).get<String>('/items', retryPolicy: quickRetry),
      throwsA(isA<DioException>()),
    );
    expect(attempts, 1);
    expect(network.checks, 1);
  });

  test('forwards retry telemetry from the abstract client', () async {
    final dio = Dio();
    final scheduled = <RetryScheduled>[];
    final completed = <RetryCompleted>[];
    var attempts = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          attempts++;
          if (attempts == 1) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionTimeout,
              ),
            );
          } else {
            handler.resolve(Response(requestOptions: options, data: 'ok'));
          }
        },
      ),
    );

    final ResilienceClient client = ResilienceClient(
      dio: dio,
      telemetry: RetryTelemetry(
        onRetry: scheduled.add,
        onComplete: completed.add,
      ),
    );
    final response = await client.get<String>(
      '/items',
      retryPolicy: quickRetry,
    );

    expect(response.data, 'ok');
    expect(scheduled.single.attempt, 1);
    expect(completed.single.attempts, 2);
    expect(completed.single.succeeded, isTrue);
  });

  test(
    'cancels during backoff without starting another request',
    () async {
      final dio = Dio();
      final cancelToken = CancelToken();
      final scheduled = Completer<void>();
      final completed = <RetryCompleted>[];
      var attempts = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            attempts++;
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionTimeout,
              ),
            );
          },
        ),
      );
      final client = ResilienceClient(
        dio: dio,
        telemetry: RetryTelemetry(
          onRetry: (_) => scheduled.complete(),
          onComplete: completed.add,
        ),
      );

      final pending = client.get<String>(
        '/items',
        retryPolicy: const RetryPolicy(
          retryCount: 2,
          baseDelay: Duration(seconds: 5),
        ),
        cancelToken: cancelToken,
      );
      await scheduled.future;
      cancelToken.cancel();
      await expectLater(
        pending,
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      expect(attempts, 1);
      expect(completed.single.succeeded, isFalse);
    },
    timeout: const Timeout(Duration(seconds: 2)),
  );

  test('does not start a request with a cancelled token', () async {
    final dio = Dio();
    final cancelToken = CancelToken()..cancel();
    var attempts = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          attempts++;
          handler.next(options);
        },
      ),
    );

    await expectLater(
      ResilienceClient(
        dio: dio,
      ).get<String>('/items', cancelToken: cancelToken),
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    expect(attempts, 0);
  });

  for (final (status, retryAfter, minimumDelay) in [
    (429, '2', const Duration(seconds: 2)),
    (
      503,
      formatHttpDate(DateTime.now().toUtc().add(const Duration(minutes: 1))),
      const Duration(seconds: 50),
    ),
  ]) {
    test('honors Retry-After for HTTP $status', () async {
      final dio = Dio();
      final cancelToken = CancelToken();
      final scheduled = <RetryScheduled>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response(
                  requestOptions: options,
                  statusCode: status,
                  headers: Headers.fromMap({
                    'retry-after': [retryAfter],
                  }),
                ),
                type: DioExceptionType.badResponse,
              ),
            );
          },
        ),
      );

      await expectLater(
        ResilienceClient(
          dio: dio,
          telemetry: RetryTelemetry(
            onRetry: (event) {
              scheduled.add(event);
              cancelToken.cancel();
            },
          ),
        ).get<String>(
          '/items',
          retryPolicy: quickRetry,
          cancelToken: cancelToken,
        ),
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      expect(scheduled.single.backoff, Duration.zero);
      expect(scheduled.single.delay, greaterThanOrEqualTo(minimumDelay));
    });
  }

  test('invalid Retry-After falls back to backoff', () async {
    final dio = Dio();
    final scheduled = <RetryScheduled>[];
    var attempts = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          attempts++;
          if (attempts == 1) {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response(
                  requestOptions: options,
                  statusCode: 429,
                  headers: Headers.fromMap({
                    'retry-after': ['invalid'],
                  }),
                ),
                type: DioExceptionType.badResponse,
              ),
            );
          } else {
            handler.resolve(Response(requestOptions: options, data: 'ok'));
          }
        },
      ),
    );

    await ResilienceClient(
      dio: dio,
      telemetry: RetryTelemetry(onRetry: scheduled.add),
    ).get<String>(
      '/items',
      retryPolicy: const RetryPolicy(
        retryCount: 1,
        baseDelay: Duration.zero,
        jitterStrategy: JitterStrategy.none,
      ),
    );
    expect(attempts, 2);
    expect(scheduled.single.delay, Duration.zero);
  });

  test('rejects non-replayable bodies before retrying', () {
    final client = ResilienceClient(dio: Dio());
    final body = FormData.fromMap({'name': 'test'});

    expect(
      () => client.post('/items', body: body, retryPolicy: quickRetry),
      throwsArgumentError,
    );
    expect(
      () => client.post(
        '/items',
        body: Stream<List<int>>.value([1, 2, 3]),
        retryPolicy: quickRetry,
      ),
      throwsArgumentError,
    );
  });

  test('allows FormData when retries are disabled', () async {
    final dio = Dio();
    var attempts = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          attempts++;
          handler.resolve(Response(requestOptions: options, data: 'ok'));
        },
      ),
    );

    final response = await ResilienceClient(
      dio: dio,
    ).post<String>('/items', body: FormData.fromMap({'name': 'test'}));
    expect(response.data, 'ok');
    expect(attempts, 1);
  });

  test('reuses the idempotency key on each write attempt', () async {
    final dio = Dio();
    final keys = <String?>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          keys.add(options.headers['Idempotency-Key'] as String?);
          if (keys.length == 1) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionTimeout,
              ),
            );
          } else {
            handler.resolve(Response(requestOptions: options, data: 'ok'));
          }
        },
      ),
    );

    final response = await ResilienceClient(dio: dio).post<String>(
      '/items',
      body: {'name': 'test'},
      headers: {'Idempotency-Key': 'operation-1'},
      retryPolicy: quickRetry,
    );
    expect(response.data, 'ok');
    expect(keys, ['operation-1', 'operation-1']);
  });

  test('rejects an empty path before calling Dio', () {
    final ResilienceClient client = ResilienceClient(dio: Dio());
    expect(() => client.get<String>(''), throwsArgumentError);
  });
}
