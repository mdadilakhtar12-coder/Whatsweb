import 'dart:async';

import 'package:http/http.dart' as http;

/// Supabase's login server and database server sometimes have clocks a few seconds apart.
/// A token that was just issued is then rejected with PGRST303 "JWT issued at future".
/// Waiting a moment and sending the same request again fixes it, so do that here.
class ClockSkewRetryClient extends http.BaseClient {
  final http.Client _inner;

  static const _delays = [Duration(seconds: 1), Duration(seconds: 2), Duration(seconds: 4)];

  ClockSkewRetryClient([http.Client? inner]) : _inner = inner ?? http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // Keep the body so the request can be sent again.
    final body = request is http.Request ? request.bodyBytes : null;
    var attempt = 0;
    var current = request;

    while (true) {
      final response = await _inner.send(current);
      if (response.statusCode != 401 || body == null || attempt >= _delays.length) {
        return response;
      }

      final bytes = await response.stream.toBytes();
      final text = String.fromCharCodes(bytes);
      if (!text.contains('PGRST303')) {
        return http.StreamedResponse(
          Stream.value(bytes),
          response.statusCode,
          contentLength: bytes.length,
          request: response.request,
          headers: response.headers,
          isRedirect: response.isRedirect,
          persistentConnection: response.persistentConnection,
          reasonPhrase: response.reasonPhrase,
        );
      }

      await Future<void>.delayed(_delays[attempt]);
      attempt++;
      current = http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..bodyBytes = body
        ..followRedirects = request.followRedirects
        ..maxRedirects = request.maxRedirects
        ..persistentConnection = request.persistentConnection;
    }
  }

  @override
  void close() => _inner.close();
}
