import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:whatsweb/services/retry_client.dart';

void main() {
  test('retries a request rejected with PGRST303, then succeeds', () async {
    var calls = 0;
    final bodies = <String>[];
    final client = ClockSkewRetryClient(MockClient((req) async {
      calls++;
      bodies.add(req.body);
      if (calls == 1) {
        return http.Response('{"code":"PGRST303","message":"JWT issued at future"}', 401);
      }
      return http.Response('[{"id":1}]', 200);
    }));

    final res = await client.post(Uri.parse('https://x.supabase.co/rest/v1/rpc/f'), body: '{"a":1}');
    expect(res.statusCode, 200);
    expect(res.body, '[{"id":1}]');
    expect(calls, 2);
    expect(bodies, ['{"a":1}', '{"a":1}']);
  });

  test('passes other 401 errors through unchanged', () async {
    var calls = 0;
    final client = ClockSkewRetryClient(MockClient((req) async {
      calls++;
      return http.Response('{"code":"PGRST301","message":"JWT expired"}', 401);
    }));
    final res = await client.get(Uri.parse('https://x.supabase.co/rest/v1/leads'));
    expect(res.statusCode, 401);
    expect(res.body, contains('PGRST301'));
    expect(calls, 1);
  });
}
