import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:whatsweb/models.dart';
import 'package:whatsweb/services/mcp_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Every request the app sent: "METHOD path?query" and the body.
final sent = <(String, Object?)>[];
var failWhatsApp = false;

// the client reads which request an answer belongs to
http.Request? _current;

http.Response json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, request: _current, headers: {'content-type': 'application/json; charset=utf-8'});

Future<http.Response> handler(http.Request req) async {
  _current = req;
  final path = req.url.path;
  final body = req.body.isEmpty ? null : jsonDecode(req.body);
  sent.add(('${req.method} ${path.replaceFirst('/rest/v1', '').replaceFirst('/functions/v1', 'fn')}${req.url.hasQuery ? '?${req.url.query}' : ''}', body));
  if (path.endsWith('/rpc/create_import_batch')) return json('batch-1');
  if (path.endsWith('/rpc/import_leads')) return json({'added': 2, 'duplicates': 1, 'invalid': 0});
  if (path.endsWith('/rpc/assign_leads')) return json(3);
  if (path.endsWith('/rpc/wa_send_to_numbers')) return json({'sending': 3, 'new_leads': 1, 'existing': 2, 'stopped': 0, 'invalid': 0});
  if (path.contains('/functions/v1/whatsapp')) {
    return failWhatsApp ? json({'ok': false, 'error': 'The 24-hour reply window is closed.'}) : json({'ok': true});
  }
  if (path.endsWith('/app_settings') && req.method == 'GET') {
    return json([
      {'value': {'auto_send': true, 'nudges': [{'id': 'old', 'name': 'Old rule', 'enabled': true}]}},
    ]);
  }
  if (path.endsWith('/wa_templates') && req.method == 'POST') return json({'id': 't-new'}, 201);
  if (path.endsWith('/reminders')) {
    return json({
      'id': 'r1', 'notify_id': 1, 'lead_id': 'l1', 'user_id': 'u-ravi', 'remind_at': '2026-10-07T11:30:00Z', 'note': 'Call about fees', 'is_done': false,
      'leads': {'id': 'l1', 'created_at': '2026-10-01T10:00:00Z'},
    }, 201);
  }
  if (req.method == 'PATCH' || req.method == 'POST') return http.Response('', 204, request: req);
  return json([]);
}

McpAction action(String kind, Map<String, dynamic> args) => McpAction(
      id: 'a1',
      kind: kind,
      title: 't',
      args: args,
      preview: const {},
      reason: null,
      status: 'running',
      result: null,
      createdAt: DateTime.now(),
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
      decidedAt: DateTime.now(),
    );

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://demo.supabase.co',
      publishableKey: 'demo',
      httpClient: MockClient(handler),
      authOptions: const FlutterAuthClientOptions(detectSessionInUri: false, autoRefreshToken: false),
    );
  });
  setUp(() {
    sent.clear();
    failWhatsApp = false;
  });

  test('add leads: a folder is made, the leads go into it with the campaign label', () async {
    final text = await runMcpAction(action('add_leads', {
      'rows': [
        {'name': 'Priya', 'phone': '+91 99999 11111', 'email': null},
        {'name': 'Mail', 'phone': null, 'email': 'm@x.com'},
      ],
      'assign_to': 'u-sita',
      'campaign': 'Class 12 list',
    }));
    expect(text, contains('Added 2'));
    expect(text, contains('1 already existed'));
    final batch = sent.firstWhere((s) => s.$1.contains('create_import_batch')).$2 as Map;
    expect(batch['p_name'], startsWith('Claude · '));
    expect(batch['p_total'], 2);
    final import = sent.firstWhere((s) => s.$1.contains('import_leads')).$2 as Map;
    expect(import['p_batch_id'], 'batch-1');
    expect(import['p_assign_to'], 'u-sita');
    expect(import['p_source_detail'], 'Class 12 list');
    expect((import['p_rows'] as List).length, 2);
  });

  test('edit a lead: only the named fields are sent', () async {
    await runMcpAction(action('edit_lead', {'lead_id': 'l1', 'values': {'name': 'Aman V.', 'email': 'aman@x.com'}}));
    final patch = sent.single;
    expect(patch.$1, 'PATCH /leads?id=eq.l1');
    expect(patch.$2, {'name': 'Aman V.', 'email': 'aman@x.com'});
  });

  test('change status: one update for all the leads, with the reason and the tag', () async {
    final text = await runMcpAction(action('set_status', {
      'lead_ids': ['l1', 'l2'],
      'values': {'status': 'Not Interested', 'lost_reason': 'Fees too high', 'temperature': null},
    }));
    expect(text, 'Changed 2 leads.');
    final patch = sent.single;
    expect(patch.$1, startsWith('PATCH /leads?id=in.'));
    expect(patch.$1, contains('l1'));
    expect(patch.$1, contains('l2'));
    expect(patch.$2, {'status': 'Not Interested', 'lost_reason': 'Fees too high', 'temperature': null});
  });

  test('a remark is marked as written through Claude', () async {
    await runMcpAction(action('add_remark', {'lead_id': 'l1', 'text': 'Parents want a call after 6'}));
    final post = sent.single;
    expect(post.$1, 'POST /lead_activities');
    final row = post.$2 as Map;
    expect(row['lead_id'], 'l1');
    expect(row['type'], 'remark');
    expect(row['body'], 'Parents want a call after 6');
    expect(row['meta'], {'via': 'claude'});
  });

  test('a reminder goes to the agent named in the request', () async {
    final text = await runMcpAction(action('set_reminder', {'lead_id': 'l1', 'at': '2026-10-07T11:30:00+00:00', 'note': 'Call about fees', 'user_id': 'u-ravi'}));
    expect(text, 'Reminder set.');
    final row = sent.single.$2 as Map;
    expect(row['lead_id'], 'l1');
    expect(row['user_id'], 'u-ravi');
    expect(row['note'], 'Call about fees');
    expect(row['remind_at'], '2026-10-07T11:30:00.000Z');
  });

  test('assign: the agents keep their order', () async {
    final text = await runMcpAction(action('assign', {'lead_ids': ['l1', 'l2', 'l3'], 'agent_ids': ['u-ravi', 'u-sita']}));
    expect(text, 'Gave 3 leads to the team.');
    final rpc = sent.single.$2 as Map;
    expect(rpc['p_lead_ids'], ['l1', 'l2', 'l3']);
    expect(rpc['p_agent_ids'], ['u-ravi', 'u-sita']);
  });

  test('a WhatsApp message goes through the same send function as the chat screen', () async {
    final text = await runMcpAction(action('wa_text', {'lead_id': 'l1', 'text': 'Hi Rahul'}));
    expect(text, 'WhatsApp message sent.');
    final body = sent.single.$2 as Map;
    expect(body['action'], 'send');
    expect(body['mode'], 'text');
    expect(body['lead_id'], 'l1');
    expect(body['text'], 'Hi Rahul');
  });

  test('when WhatsApp says no, the request fails with Meta\'s words', () async {
    failWhatsApp = true;
    await expectLater(
      runMcpAction(action('wa_text', {'lead_id': 'l1', 'text': 'Hi'})),
      throwsA(predicate((e) => '$e'.contains('24-hour reply window is closed'))),
    );
  });

  test('a template is sent to the people in the request, with the details filled in', () async {
    final text = await runMcpAction(action('wa_template', {
      'template_id': 't1',
      'template_name': 'exam',
      'entries': [
        {'phone': '+919876543210', 'name': 'Rahul'},
        {'phone': '+919000000001', 'name': 'Zed'},
      ],
      'values': {'semester': 'Semester 3', 'date': '12 Oct'},
    }));
    expect(text, contains('Sending to 3'));
    expect(text, contains('1 new leads made'));
    final rpc = sent.single.$2 as Map;
    expect(rpc['p_template'], 't1');
    expect((rpc['p_entries'] as List).length, 2);
    expect(rpc['p_params'], {'semester': 'Semester 3', 'date': '12 Oct'});
    expect(rpc['p_name'], 'Claude · exam');
  });

  test('a flow: the replies are saved with their ids first, then the template as a draft', () async {
    final text = await runMcpAction(action('wa_flow', {
      'template': {
        'name': 'bsc_maths_sem1_reminder',
        'language': 'hi',
        'category': 'MARKETING',
        'spec': {
          'header': {'type': 'none'},
          'body': 'Namaste {first_name}, seats are filling.',
          'footer': '',
          'buttons': [
            {'type': 'quick_reply', 'text': 'Fees batao', 'action': {'next': 'n-fees', 'temperature': 'warm'}},
          ],
        },
      },
      'replies': [
        {
          'id': 'n-fees', 'name': 'Fees info', 'kind': 'buttons', 'header': null, 'body': 'Fee is Rs 149.', 'footer': null,
          'buttons': [
            {'title': 'Ticket lena hai', 'action': {'next': 'n-pay', 'status': 'Interested'}},
          ],
          'list_button': null, 'sections': [],
        },
        {'id': 'n-pay', 'name': 'Pay steps', 'kind': 'text', 'header': null, 'body': 'Pay here.', 'footer': null, 'buttons': [], 'list_button': null, 'sections': []},
      ],
    }));
    expect(text, contains('saved as a draft'));
    expect(text, contains('2 automatic replies saved'));
    expect(sent.map((s) => s.$1).toList(), ['POST /wa_nodes', 'POST /wa_nodes', 'POST /wa_templates?select=id']);
    final first = sent[0].$2 as Map;
    expect(first['id'], 'n-fees');
    expect(first['kind'], 'buttons');
    expect((first['buttons'] as List).single['action'], {'next': 'n-pay', 'status': 'Interested'});
    final tpl = sent[2].$2 as Map;
    expect(tpl['name'], 'bsc_maths_sem1_reminder');
    expect(tpl['language'], 'hi');
    expect(tpl['category'], 'MARKETING');
    expect(tpl.containsKey('status'), isFalse, reason: 'the database makes it a DRAFT');
    expect(((tpl['spec'] as Map)['buttons'] as List).single['action'], {'next': 'n-fees', 'temperature': 'warm'});
  });

  test('a rule is added to the existing ones and saved paused', () async {
    final text = await runMcpAction(action('wa_rule', {
      'id': 'r1', 'name': 'Maths not paid', 'match': 'landing page one', 'source': null, 'after_minutes': 60, 'only_if': 'not_paid',
      'template_id': 't1', 'template_name': 'bsc_maths_sem1_reminder', 'start_hour': 9, 'end_hour': 21, 'enabled': true, 'by': 'claude',
    }));
    expect(text, contains('paused'));
    final save = sent.firstWhere((s) => s.$1.startsWith('POST /app_settings')).$2;
    final row = (save is List ? save.single : save) as Map;
    expect(row['key'], 'whatsapp');
    final value = (row['value'] as Map).cast<String, dynamic>();
    expect(value['auto_send'], true, reason: 'the other settings stay');
    final nudges = (value['nudges'] as List).cast<Map>();
    expect(nudges.length, 2);
    expect(nudges[0]['id'], 'old');
    expect(nudges[1]['id'], 'r1');
    expect(nudges[1]['enabled'], false, reason: 'always paused, whatever the request said');
    expect(nudges[1].containsKey('enabled_at'), isFalse);
  });

  test('a kind this version does not know does nothing', () async {
    await expectLater(runMcpAction(action('delete_everything', {})), throwsA(predicate((e) => '$e'.contains('not known'))));
    expect(sent, isEmpty);
  });

  test('a request shows its real state: expired, interrupted', () {
    McpAction at(String status, {Duration expiresIn = const Duration(hours: 1), Duration? decidedAgo}) => McpAction(
          id: 'a',
          kind: 'assign',
          title: 't',
          args: const {},
          preview: const {'lines': ['one', 'two'], 'highlight': 'Costs about ₹3'},
          reason: null,
          status: status,
          result: null,
          createdAt: DateTime.now(),
          expiresAt: DateTime.now().add(expiresIn),
          decidedAt: decidedAgo == null ? null : DateTime.now().subtract(decidedAgo),
        );
    expect(at('pending').state, 'pending');
    expect(at('pending').waiting, isTrue);
    expect(at('pending', expiresIn: const Duration(minutes: -1)).state, 'expired');
    expect(at('pending', expiresIn: const Duration(minutes: -1)).waiting, isFalse);
    expect(at('running', decidedAgo: const Duration(minutes: 2)).state, 'running');
    expect(at('running', decidedAgo: const Duration(minutes: 30)).state, 'interrupted');
    expect(at('done').state, 'done');
    expect(at('pending').lines, ['one', 'two']);
    expect(at('pending').highlight, 'Costs about ₹3');
  });
}
