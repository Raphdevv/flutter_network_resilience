/// HTTP methods supported by the Dio facade.
enum ResilienceMethod { get, post, put, patch, delete }

/// Transport-independent description of an HTTP request.
class ResilienceRequest {
  const ResilienceRequest({
    required this.method,
    required this.path,
    this.params,
    this.body,
    this.headers,
  });

  final ResilienceMethod method;
  final String path;
  final Map<String, dynamic>? params;
  final Object? body;
  final Map<String, String>? headers;
}
