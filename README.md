A focused retry extension for Dio in Flutter. For now, this package wraps a
caller-provided Dio instance to add opt-in retries, backoff, jitter, and
cancellation; it is not a replacement HTTP client or a connectivity detector.

## Dio client

```dart
import 'package:dio/dio.dart';
import 'package:flutter_network_resilience/flutter_network_resilience.dart';

final ResilienceClient client = ResilienceClient(
	dio: Dio(BaseOptions(baseUrl: 'https://example.com')),
);
final items = await client.get<Map<String, dynamic>>(
	'/items',
	params: {'page': 1},
	retryPolicy: RetryPolicy(
		retryCount: 2,
		retryIf: (error) =>
				error is DioException && error.response?.statusCode == 429,
	),
);
await client.post('/items', body: {'name': 'new item'});
await client.put('/items/1', body: {'name': 'replacement'});
await client.patch('/items/1', body: {'name': 'updated'});
await client.delete('/items/1');
```

You can also call `client.request(ResilienceRequest(method: ResilienceMethod.get,
path: '/items', params: {'page': 1}))`. Each call uses the configured Dio
instance, including its interceptors, headers, timeouts, and base URL. The
default `RetryPolicy.noRetry` sends only one request. With retries enabled,
the built-in classifier retries Dio connection/timeouts, HTTP 429, and 5xx;
other errors are not retried. Set `retryIf` in the per-call `RetryPolicy` to
override that classifier. `retryCount` must be greater than zero for the
predicate to trigger a retry. Only enable retry for write requests when the
server supports idempotency (for example, with an idempotency key).
Pass a caller-generated key through `headers: {'Idempotency-Key': key}` on a
write request; the same headers are reused for each retry of that request.
The client does not create or validate idempotency keys, and retries remain
opt-in for every HTTP method. Retrying a `FormData` or `Stream` body throws
`ArgumentError` before sending, because those bodies may not be replayable;
use `RetryPolicy.noRetry` for one-shot uploads.

## Cancellation and server delays

Pass Dio's `CancelToken` to `get`, `post`, `put`, `patch`, `delete`, or `request`:

```dart
final cancelToken = CancelToken();
final pending = client.get('/items',
	retryPolicy: const RetryPolicy(retryCount: 2),
	cancelToken: cancelToken);

// When the result is no longer needed:
cancelToken.cancel();
```

Cancellation stops an in-flight Dio request or a pending retry wait and
returns a Dio cancellation error without another attempt. For HTTP 429 and
503, a valid `Retry-After` header (seconds or HTTP date) sets a minimum wait.
This server-directed wait may exceed `maxDelay`, which caps only the local
exponential backoff. Invalid or expired headers fall back to backoff and jitter.

## Retry telemetry

Logging is opt-in. Pass `RetryTelemetry` to the client factory:

```dart
import 'dart:developer' as developer;

final client = ResilienceClient(
	dio: Dio(),
	telemetry: RetryTelemetry(
		onRetry: (event) => developer.log(
			'retry=${event.attempt} call=${event.callDuration.inMilliseconds}ms '
			'backoff=${event.backoff.inMilliseconds}ms '
			'delay=${event.delay.inMilliseconds}ms',
		),
		onComplete: (event) => developer.log(
			'attempts=${event.attempts} success=${event.succeeded} '
			'lastCall=${event.callDuration.inMilliseconds}ms '
			'total=${event.totalDuration.inMilliseconds}ms',
		),
	),
);
```

`onRetry` runs only when another attempt is scheduled; `delay` includes jitter,
whereas `backoff` is the capped value before jitter. `onComplete` runs once on
success or failure, including when no retry occurs. The events contain no URL,
body, headers, or error message. Callbacks run synchronously; exceptions from
them propagate, so keep logging callbacks non-throwing.

`retryCount` counts retries after the first call; zero disables retries.
Without `retryIf`, the client retries transient Dio errors only. Enable retry
only for operations that can safely run again (such as GET), or provide your
own idempotency key.
The delay doubles after each failure up to `maxDelay`; `JitterStrategy.additive`
adds up to `jitter` beyond that cap. `JitterStrategy.full` replaces the delay
with a random value between zero and the capped backoff.

## Network awareness

The package does not detect connectivity on its own. To stop retrying while
offline, provide your application's connection check by implementing
`NetworkAwareness` and passing it to the client:

```dart
import 'package:dio/dio.dart';
import 'package:flutter_network_resilience/flutter_network_resilience.dart';

class AppNetworkAwareness implements NetworkAwareness {
	AppNetworkAwareness(this.checkConnection);

	final Future<bool> Function() checkConnection;

	@override
	Future<bool> get isConnected => checkConnection();
}

ResilienceClient createClient(Future<bool> Function() checkConnection) =>
		ResilienceClient(
			dio: Dio(),
			networkAwareness: AppNetworkAwareness(checkConnection),
		);
```

Implement `checkConnection` using your app's chosen connectivity source.
The client checks it only after a failed request qualifies for retry, before
the next wait or attempt. `true` permits that retry; `false` stops and returns
the original request error. Without `networkAwareness`, requests still run and
retry according to the policy, but no connectivity check is performed.

## Structure

- `lib/src/domain/` defines `ResilienceRequest`, `RetryPolicy`, `JitterStrategy`, and the
	`NetworkAwareness` interface. It has no dependency on Dio or Flutter.
- `lib/src/application/` contains the internal retry runner used by the client.
- `lib/src/infrastructure/resilience_client.dart` defines the public abstraction
	and factory; `dio_resilience_client.dart` keeps the Dio implementation internal.
- `lib/flutter_network_resilience.dart` exposes the public API. A concrete
	connectivity adapter can be added later without changing the domain contract.
