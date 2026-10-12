import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:whatsweb/models.dart';
import 'package:whatsweb/screens/api_docs_screen.dart';
import 'package:whatsweb/services/api_docs.dart';

void main() {
  test('a message knows it was sent by the AI assistant', () {
    final base = {'id': 'm1', 'lead_id': 'l1', 'direction': 'out', 'created_at': '2026-10-08T10:00:00Z'};
    expect(WaMessage.fromJson({...base, 'via': 'api'}).byAiAssistant, isTrue);
    expect(WaMessage.fromJson({...base, 'via': null}).byAiAssistant, isFalse);
    expect(WaMessage.fromJson(base).byAiAssistant, isFalse);
    // incoming messages are never the AI's
    expect(WaMessage.fromJson({...base, 'direction': 'in'}).outgoing, isFalse);
  });

  test('the documentation lists every address of the API with JSON examples that are valid', () {
    final all = apiEndpoints.map((e) => '${e.method} ${e.path}').toSet();
    expect(all, {
      'GET /students',
      'GET /students/{id}',
      'GET /students/{id}/activities',
      'GET /courses',
      'GET /whatsapp/templates',
      'POST /whatsapp/send-template',
      'POST /whatsapp/send-text',
      'GET /students/{id}/messages',
      'GET /students/{id}/window',
      'POST /students/{id}/notes',
      'PATCH /students/{id}',
      'GET /statuses',
    });
    for (final e in apiEndpoints) {
      expect(() => jsonDecode(e.response), returnsNormally, reason: e.path);
      if (e.body != null) expect(() => jsonDecode(e.body!), returnsNormally, reason: e.path);
      // a request that changes something has a body, a read has none
      expect(e.body != null, e.method != 'GET', reason: '${e.method} ${e.path}');
    }
  });

  test('the example request is a curl command with the key header and the real address', () {
    final send = apiEndpoints.firstWhere((e) => e.path == '/whatsapp/send-text');
    final c = ApiDocsScreen.curl(send, 'https://p.supabase.co/functions/v1/api/v1');
    expect(c, contains('-X POST'));
    expect(c, contains('Authorization: Bearer \$API_KEY'));
    expect(c, contains('"https://p.supabase.co/functions/v1/api/v1/whatsapp/send-text"'));
    // the body is on one line so it can be pasted into a terminal
    final body = RegExp(r"-d '([^']*)'").firstMatch(c)!.group(1)!;
    expect(body.contains('\n'), isFalse);
    expect(jsonDecode(body)['student_id'], isNotEmpty);
    final read = apiEndpoints.firstWhere((e) => e.path == '/courses');
    expect(ApiDocsScreen.curl(read, 'https://x/api/v1'), 'curl -H "Authorization: Bearer \$API_KEY" "https://x/api/v1/courses"');
  });

  test('the documentation names the safety rules and the webhook events', () {
    final text = [...apiGeneralDocs, ...apiWebhookDocs].map((d) => '${d.$1}\n${d.$2}').join('\n');
    for (final must in [
      'Authorization: Bearer',
      '60 requests a minute',
      'opted_out',
      '24-hour',
      'student.created',
      'student.activity',
      'course.purchased',
      'whatsapp.reply',
      'whatsapp.button_click',
      'X-WhatsWeb-Signature',
      'HMAC-SHA256',
      '3 more times',
      'Sent by AI assistant',
    ]) {
      expect(text, contains(must));
    }
  });
}
