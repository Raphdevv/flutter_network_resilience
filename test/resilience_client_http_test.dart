import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_network_resilience/flutter_network_resilience.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Dio sends a real HTTP request again after a transient response',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var requests = 0;
      final paths = <String>[];
      server.listen((request) async {
        requests++;
        paths.add(request.uri.toString());
        request.response.headers.contentType = ContentType.text;
        request.response.statusCode = requests == 1
            ? HttpStatus.serviceUnavailable
            : HttpStatus.ok;
        request.response.write(requests == 1 ? 'try again' : 'ready');
        await request.response.close();
      });

      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}'));
      addTearDown(() => dio.close(force: true));
      final client = ResilienceClient(dio: dio);

      final response = await client.get<String>(
        '/health',
        params: {'source': 'test'},
        retryPolicy: const RetryPolicy(
          retryCount: 1,
          baseDelay: Duration.zero,
          jitterStrategy: JitterStrategy.none,
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(response.data, 'ready');
      expect(requests, 2);
      expect(paths, ['/health?source=test', '/health?source=test']);
    },
  );

  test(
    'CancelToken aborts a real in-flight Dio request',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final received = Completer<void>();
      var requests = 0;
      server.listen((request) {
        requests++;
        received.complete();
      });

      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}'));
      addTearDown(() => dio.close(force: true));
      final cancelToken = CancelToken();
      final pending = ResilienceClient(dio: dio).get<String>(
        '/pending',
        retryPolicy: const RetryPolicy(retryCount: 1),
        cancelToken: cancelToken,
      );

      await received.future;
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
      expect(requests, 1);
    },
    timeout: const Timeout(Duration(seconds: 5)),
  );

  test(
    'Dio repeats a real POST with the same body and idempotency key',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final bodies = <Map<String, dynamic>>[];
      final keys = <String?>[];
      server.listen((request) async {
        expect(request.method, 'POST');
        expect(request.uri.path, '/items');
        keys.add(request.headers.value('idempotency-key'));
        bodies.add(
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>,
        );
        request.response.headers.contentType = ContentType.json;
        request.response.statusCode = bodies.length == 1
            ? HttpStatus.serviceUnavailable
            : HttpStatus.created;
        request.response.write('{"saved":true}');
        await request.response.close();
      });

      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}'));
      addTearDown(() => dio.close(force: true));
      final response = await ResilienceClient(dio: dio)
          .post<Map<String, dynamic>>(
            '/items',
            body: {'item': 'book'},
            headers: {'Idempotency-Key': 'operation-1'},
            retryPolicy: const RetryPolicy(
              retryCount: 1,
              baseDelay: Duration.zero,
              jitterStrategy: JitterStrategy.none,
            ),
          );

      expect(response.statusCode, HttpStatus.created);
      expect(response.data, {'saved': true});
      expect(bodies, [
        {'item': 'book'},
        {'item': 'book'},
      ]);
      expect(keys, ['operation-1', 'operation-1']);
    },
  );
}
