// Renders the main screens with sample data into docs/screenshots/*.png.
// Not part of the normal test run. Regenerate with:
//   flutter test tool/screenshots/screens_test.dart --update-goldens
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:whatsweb/screens/claude_connector_screen.dart';
import 'package:whatsweb/screens/claude_requests_screen.dart';
import 'package:whatsweb/screens/dashboard_screen.dart';
import 'package:whatsweb/screens/imports_screen.dart';
import 'package:whatsweb/screens/leads_screen.dart';
import 'package:whatsweb/screens/wa_broadcast_screen.dart';
import 'package:whatsweb/screens/wa_chat_screen.dart';
import 'package:whatsweb/screens/wa_chats_screen.dart';
import 'package:whatsweb/screens/wa_nodes_screen.dart';
import 'package:whatsweb/screens/wa_quick_send_screen.dart';
import 'package:whatsweb/screens/wa_setup_screen.dart';
import 'package:whatsweb/screens/wa_template_editor.dart';
import 'package:whatsweb/screens/api_deliveries_screen.dart';
import 'package:whatsweb/screens/api_screen.dart';
import 'package:whatsweb/screens/appx_screen.dart';
import 'package:whatsweb/screens/webinar_screen.dart';
import 'package:whatsweb/screens/wa_templates_screen.dart';
import 'package:whatsweb/screens/whatsapp_screen.dart';
import 'package:whatsweb/screens/home_screen.dart';
import 'package:whatsweb/screens/leaderboard_screen.dart';
import 'package:whatsweb/screens/lead_detail_screen.dart';
import 'package:whatsweb/screens/login_screen.dart';
import 'package:whatsweb/screens/pin_screen.dart';
import 'package:whatsweb/services/call_log_sync.dart';
import 'package:whatsweb/services/app_state.dart';
import 'package:whatsweb/services/repo.dart';
import 'package:whatsweb/theme.dart';
import 'package:whatsweb/widgets/assign_sheet.dart';
import 'package:whatsweb/widgets/call_outcome_sheet.dart';
import 'package:whatsweb/widgets/wide_layout.dart';
import 'package:whatsweb/widgets/template_picker.dart';
import 'package:whatsweb/models.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const adminId = '00000000-0000-0000-0000-00000000000a';
const raviId = '00000000-0000-0000-0000-00000000000b';
const sitaId = '00000000-0000-0000-0000-00000000000c';

final now = DateTime.now();
String iso(DateTime d) => d.toUtc().toIso8601String();

final profiles = [
  {'id': adminId, 'full_name': 'Admin', 'email': 'admin@mycrm.in', 'role': 'admin', 'is_active': true},
  {'id': raviId, 'full_name': 'Ravi', 'email': 'ravi@mycrm.in', 'role': 'agent', 'is_active': true},
  {'id': sitaId, 'full_name': 'Sita', 'email': 'sita@mycrm.in', 'role': 'agent', 'is_active': true},
];

final statuses = [
  for (final (i, s) in [
    ('New', '#1E88E5', false),
    ('No Answer', '#FB8C00', false),
    ('Interested', '#43A047', false),
    ('Call Back', '#8E24AA', false),
    ('Not Interested', '#E53935', true),
    ('Admission Done', '#00897B', true),
    ('Wrong Number', '#6D4C41', true),
  ].indexed)
    {
      'id': i + 1,
      'name': s.$1,
      'color': s.$2,
      'sort_order': i + 1,
      'is_closed': s.$3,
      'is_won': s.$1 == 'Admission Done',
      'ask_reason': s.$1 == 'Not Interested',
    },
];

Map<String, dynamic> lead(
  String id,
  String name,
  String phone, {
  String? email,
  String source = 'meta_form',
  String? detail,
  String status = 'New',
  String? assigned,
  Duration age = const Duration(hours: 2),
  DateTime? followUp,
  Map<String, dynamic> extra = const {},
  String? temperature,
  String wa = 'none',
  String? waText,
  int unread = 0,
  Duration waAge = const Duration(hours: 1),
  String waDirection = 'in',
  String? webinar,
  double webinarPaid = 0,
  bool? attended,
}) =>
    {
      'id': id,
      'name': name,
      'phone': phone,
      'email': email,
      'source': source,
      'source_detail': detail,
      'status': status,
      'assigned_to': assigned,
      'created_at': iso(now.subtract(age)),
      'last_contacted_at': status == 'New' ? null : iso(now.subtract(const Duration(hours: 1))),
      'next_follow_up_at': followUp == null ? null : iso(followUp),
      'extra': extra,
      'temperature': temperature,
      'wa_state': wa,
      'wa_last_text': waText,
      'wa_unread': unread,
      'wa_last_direction': wa == 'none' ? null : waDirection,
      'wa_last_message_at': wa == 'none' ? null : iso(now.subtract(waAge)),
      'wa_last_inbound_at': wa == 'replied' ? iso(now.subtract(waAge)) : null,
      'webinar_state': webinar,
      'webinar_paid': webinarPaid,
      'webinar_title': webinar == null ? null : 'NEET 2027: how to rank in 90 days',
      'webinar_attended': attended,
    };

final leads = [
  lead('l1', 'Rahul Kumar', '+919876543210',
      email: 'rahul.k@gmail.com',
      detail: 'NEET Sept Campaign',
      status: 'Interested',
      assigned: raviId,
      age: const Duration(minutes: 25),
      followUp: DateTime(now.year, now.month, now.day + 2, 11),
      extra: {'course': 'NEET 2027', 'city': 'Patna', 'platform': 'ig'},
      temperature: 'hot',
      wa: 'replied',
      waText: 'Fees chahiye',
      unread: 2,
      waAge: const Duration(minutes: 20),
      webinar: 'paid',
      webinarPaid: 149,
      attended: true),
  lead('l2', 'Neha Singh', '+919123456780',
      email: 'neha.singh@yahoo.com', source: 'google_landing', detail: 'JEE Search', assigned: sitaId,
      age: const Duration(hours: 3),
      wa: 'read',
      waText: 'Namaste Neha! JEE course details...',
      waDirection: 'out',
      waAge: const Duration(hours: 2)),
  lead('l3', 'Aman Verma', '+918877665544',
      source: 'excel', detail: 'enquiries_sept.xlsx', status: 'Call Back', assigned: raviId,
      age: const Duration(days: 1), followUp: now.subtract(const Duration(hours: 2)), temperature: 'warm',
      wa: 'failed', waText: 'Namaste Aman! ...', waDirection: 'out', waAge: const Duration(hours: 20),
      webinar: 'paid', webinarPaid: 99, attended: false),
  lead('l4', 'Priya Sharma', '+917766554433',
      email: 'priya@outlook.com', source: 'meta_landing', age: const Duration(hours: 5),
      wa: 'delivered', waText: 'Namaste Priya! ...', waDirection: 'out', waAge: const Duration(hours: 4),
      webinar: 'registered'),
  lead('l5', 'Mohit Yadav', '+919988776655',
      status: 'No Answer', assigned: sitaId, age: const Duration(days: 2),
      followUp: DateTime(now.year, now.month, now.day, 18)),
  lead('l6', 'Sana Khan', '+919812345678',
      email: 'sana.k@gmail.com', status: 'Admission Done', assigned: raviId, age: const Duration(days: 4)),
];

final activities = [
  {'id': 9, 'user_id': null, 'type': 'webinar', 'body': 'Paid ₹149 for NEET 2027: how to rank in 90 days', 'meta': {},
    'created_at': iso(now.subtract(const Duration(minutes: 3)))},
  {'id': 7, 'user_id': raviId, 'type': 'reminder', 'body': 'Will decide after talking to parents',
    'meta': {'remind_at': iso(DateTime(now.year, now.month, now.day + 2, 11))}, 'created_at': iso(now.subtract(const Duration(minutes: 5)))},
  {'id': 6, 'user_id': raviId, 'type': 'remark', 'body': 'Interested in NEET batch, asked about fees and hostel.',
    'meta': {}, 'created_at': iso(now.subtract(const Duration(minutes: 6)))},
  {'id': 5, 'user_id': raviId, 'type': 'status', 'body': null, 'meta': {'from': 'New', 'to': 'Interested'},
    'created_at': iso(now.subtract(const Duration(minutes: 6)))},
  {'id': 4, 'user_id': raviId, 'type': 'call', 'body': null, 'meta': {'direction': 'out', 'duration': 245, 'source': 'log'},
    'created_at': iso(now.subtract(const Duration(minutes: 9)))},
  {'id': 8, 'user_id': raviId, 'type': 'temperature', 'body': null, 'meta': {'from': null, 'to': 'hot'},
    'created_at': iso(now.subtract(const Duration(minutes: 5)))},
  {'id': 3, 'user_id': raviId, 'type': 'whatsapp', 'body': null, 'meta': {}, 'created_at': iso(now.subtract(const Duration(minutes: 15)))},
  {'id': 2, 'user_id': adminId, 'type': 'assigned', 'body': null, 'meta': {'to': raviId}, 'created_at': iso(now.subtract(const Duration(minutes: 20)))},
  {'id': 1, 'user_id': null, 'type': 'created', 'body': null, 'meta': {'source': 'meta_form'}, 'created_at': iso(now.subtract(const Duration(minutes: 25)))},
];

List<Map<String, dynamic>> reminders() => [
      for (final (i, l) in leads.where((l) => l['next_follow_up_at'] != null).indexed)
        {
          'id': 'r$i',
          'notify_id': i + 1,
          'lead_id': l['id'],
          'user_id': l['assigned_to'] ?? adminId,
          'remind_at': l['next_follow_up_at'],
          'note': ['Will decide after talking to parents', 'Call after 5 PM', 'Busy in exams, call back'][i % 3],
          'is_done': false,
          'created_at': iso(now),
          'leads': l,
        },
    ];

final waTemplates = [
  {
    'id': 'w1', 'name': 'welcome_neet', 'language': 'en', 'category': 'MARKETING', 'status': 'APPROVED', 'reason': null,
    'spec': {
      'header': {'type': 'image', 'media_path': 'tpl/neet.jpg', 'filename': 'neet_banner.jpg'},
      'body': 'Namaste {first_name}! Thank you for your interest in NEET 2027 at AIFM Education. Which would you like to know first?',
      'footer': 'AIFM Education',
      'buttons': [
        {'type': 'quick_reply', 'text': 'Fees chahiye', 'action': {'status': 'Interested', 'temperature': 'warm', 'next': 'n1'}},
        {'type': 'quick_reply', 'text': 'Call me', 'action': {'status': 'Call Back', 'temperature': 'hot', 'callback_hours': 1}},
        {'type': 'quick_reply', 'text': 'Not interested', 'action': {'status': 'Not Interested', 'temperature': 'cold', 'optout': true}},
        {'type': 'url', 'text': 'See course', 'url': 'https://aifm.in/neet'},
      ],
    },
  },
  {
    'id': 'w2', 'name': 'followup_day1', 'language': 'hi', 'category': 'MARKETING', 'status': 'PENDING', 'reason': null,
    'spec': {'header': {'type': 'none'}, 'body': 'Namaste {first_name}, kal aapne NEET ke baare mein poocha tha. Kya aap abhi baat kar sakte hain?', 'buttons': []},
  },
  {
    'id': 'w3', 'name': 'open_day', 'language': 'en', 'category': 'MARKETING', 'status': 'REJECTED', 'reason': 'INVALID_FORMAT',
    'spec': {'header': {'type': 'text', 'text': 'Open day on Sunday'}, 'body': 'Hi {first_name}, visit our campus this Sunday.', 'buttons': []},
  },
  {
    'id': 'w4', 'name': 'brochure_pdf', 'language': 'en', 'category': 'UTILITY', 'status': 'DRAFT', 'reason': null,
    'spec': {'header': {'type': 'document', 'media_path': 'tpl/b.pdf', 'filename': 'brochure.pdf'}, 'body': 'Hi {first_name}, here is our brochure.', 'buttons': []},
  },
];

final waNodes = [
  {
    'id': 'n1', 'name': 'Fees details', 'kind': 'buttons', 'header': null,
    'body': 'The full NEET course fee is ₹45,000 (EMI available). Would you like to book a free counselling call?',
    'footer': null, 'media_path': null, 'media_type': null, 'filename': null,
    'buttons': [
      {'title': 'Yes, call me', 'action': {'status': 'Call Back', 'temperature': 'hot', 'callback_hours': 1}},
      {'title': 'Send brochure', 'action': {'next': 'n2'}},
    ],
    'list_button': null, 'sections': [],
  },
  {
    'id': 'n2', 'name': 'Brochure PDF', 'kind': 'text', 'header': null, 'body': 'Here is our brochure, {first_name}.',
    'footer': null, 'media_path': 'reply/brochure.pdf', 'media_type': 'document', 'filename': 'brochure.pdf',
    'buttons': [], 'list_button': null, 'sections': [],
  },
  {
    'id': 'n3', 'name': 'Choose a course', 'kind': 'list', 'header': 'Our courses',
    'body': 'Which course are you interested in?', 'footer': null, 'media_path': null, 'media_type': null, 'filename': null,
    'buttons': [], 'list_button': 'Courses',
    'sections': [
      {'title': 'Medical', 'rows': [{'title': 'NEET 2027'}, {'title': 'NEET Dropper'}]},
    ],
  },
];

final waMessages = [
  {'id': 'm1', 'lead_id': 'l1', 'direction': 'out', 'kind': 'auto', 'type': 'template', 'body': '🖼 Image\nNamaste Rahul! Thank you for your interest in NEET 2027 at AIFM Education. Which would you like to know first?\nAIFM Education',
    'template_name': 'welcome_neet', 'status': 'read', 'created_at': iso(now.subtract(const Duration(minutes: 24)))},
  {'id': 'm2', 'lead_id': 'l1', 'direction': 'in', 'kind': 'inbound', 'type': 'button', 'body': 'Fees chahiye', 'status': 'received',
    'created_at': iso(now.subtract(const Duration(minutes: 22)))},
  {'id': 'm3', 'lead_id': 'l1', 'direction': 'out', 'kind': 'bot', 'type': 'interactive', 'body': 'The full NEET course fee is ₹45,000 (EMI available). Would you like to book a free counselling call?',
    'status': 'read', 'created_at': iso(now.subtract(const Duration(minutes: 22)))},
  {'id': 'm4', 'lead_id': 'l1', 'direction': 'in', 'kind': 'inbound', 'type': 'interactive', 'body': 'Yes, call me', 'status': 'received',
    'created_at': iso(now.subtract(const Duration(minutes: 21)))},
  {'id': 'm5', 'lead_id': 'l1', 'direction': 'out', 'kind': 'manual', 'type': 'text', 'body': 'Hi Rahul, Ravi here from AIFM. I will call you in 10 minutes.',
    'status': 'delivered', 'created_at': iso(now.subtract(const Duration(minutes: 20)))},
  {'id': 'm6', 'lead_id': 'l1', 'direction': 'in', 'kind': 'inbound', 'type': 'text', 'body': 'Ok sir, please call after 6', 'status': 'received',
    'created_at': iso(now.subtract(const Duration(minutes: 19)))},
  {'id': 'm7', 'lead_id': 'l1', 'direction': 'out', 'kind': 'manual', 'type': 'text', 'body': 'Sure, I will call you at 6 PM.', 'status': 'sent',
    'created_at': iso(now.subtract(const Duration(minutes: 18)))},
];


final webinarEvents = [
  for (final (i, e) in [
    ('registration.payment.completed', 'rahul.k@gmail.com', 'ok', 3),
    ('registration.created', 'rahul.k@gmail.com', 'ok', 4),
    ('registration.payment.failed', 'priya@outlook.com', 'ok', 190),
    ('registration.created', 'priya@outlook.com', 'ok', 195),
    ('webinar.started', '', 'ignored', 1500),
  ].indexed)
    {
      'id': 100 - i,
      'event': e.$1,
      'event_at': iso(now.subtract(Duration(minutes: e.$4))),
      'outcome': e.$3,
      'error': null,
      'attempts': 1,
      'created_at': iso(now.subtract(Duration(minutes: e.$4))),
      'body': {'event': e.$1, 'timestamp': iso(now.subtract(Duration(minutes: e.$4))), 'data': {if (e.$2.isNotEmpty) 'email': e.$2, 'webinarId': 'w_184'}},
    },
];

String fakeJwt() {
  String b64(Map<String, dynamic> m) => base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final exp = now.add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000;
  return '${b64({'alg': 'HS256', 'typ': 'JWT'})}.${b64({'sub': adminId, 'exp': exp, 'role': 'authenticated'})}.sig';
}

late http.Request _current;

http.Response jsonResponse(Object body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
      request: _current,
    );

Future<http.Response> handler(http.Request req) async {
  _current = req;
  final path = req.url.path;
  final q = req.url.queryParameters;
  if (path.startsWith('/auth/v1/token')) {
    return jsonResponse({
      'access_token': fakeJwt(),
      'token_type': 'bearer',
      'expires_in': 86400,
      'expires_at': now.add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000,
      'refresh_token': 'refresh',
      'user': {
        'id': adminId,
        'aud': 'authenticated',
        'role': 'authenticated',
        'email': 'admin@mycrm.in',
        'app_metadata': {},
        'user_metadata': {},
        'created_at': iso(now),
      },
    });
  }
  if (path.endsWith('/rpc/lead_counts')) {
    final counts = <String, int>{};
    for (final l in leads) {
      final k = '${l['assigned_to']}|${l['status']}';
      counts[k] = (counts[k] ?? 0) + 1;
    }
    return jsonResponse([
      for (final e in counts.entries)
        {
          'assigned_to': e.key.split('|')[0] == 'null' ? null : e.key.split('|')[0],
          'status': e.key.split('|')[1],
          'total': e.value + 7,
        },
    ]);
  }
  if (path.endsWith('/profiles')) {
    final id = q['id']?.replaceFirst('eq.', '');
    return jsonResponse(id == null ? profiles : profiles.where((p) => p['id'] == id).toList());
  }
  if (path.endsWith('/lead_statuses')) return jsonResponse(statuses);
  if (path.endsWith('/app_settings')) {
    final key = q['key']?.replaceFirst('eq.', '');
    final value = switch (key) {
      'lost_reasons' => {
          'reasons': ['Fees too high', 'Too far', 'Joined somewhere else', 'Wrong course', 'Parents not agreeing'],
        },
      'security' => {'require_pin': false},
      'integrations' => {'mcp_perms': {'read_chats': true, 'add_remark': true, 'change_status': true, 'assign': true, 'wa_template': true, 'wa_build': true}, 'mcp_wa_cap': 200, 'mcp_token': '9f8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c5b4a39281706f5e4d3c2b1a0', 'landing_key': 'demo', 'webinar_token': 'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90', 'appx_token': 'f0e1d2c3b4a5968778695a4b3c2d1e0ff0e1d2c3b4a5968778695a4b3c2d1e0f'},
      'app_release' => {'build': 1, 'file': 'whatsweb.apk'},
      'whatsapp_status' => {
          'connected': true,
          'display_phone': '+91 98765 43210',
          'verified_name': 'AIFM Education',
          'quality': 'GREEN',
          'tier': 'TIER_1K',
        },
      'whatsapp' => {
          'auto_send': true,
          'auto_template_id': 'w1',
          'auto_sources': ['meta_form', 'meta_landing', 'google_form', 'google_landing', 'website'],
          'rules': [
            {'match': 'neet', 'template_id': 'w2'},
          ],
          'button_via_api': false,
          'welcome_node_id': 'n1',
          'followups': {
            'enabled': true,
            'start_hour': 9,
            'end_hour': 21,
            'steps': [
              {'after_hours': 24, 'template_id': 'w2'},
              {'after_hours': 72, 'template_id': 'w1'},
            ],
          },
          'price_marketing': 0.9,
          'price_utility': 0.15,
          'nudges': [
            {
              'id': 'n1', 'name': 'BSc Maths Sem 1: not paid', 'match': 'landing page one', 'after_minutes': 60, 'only_if': 'not_paid',
              'template_id': 'w1', 'template_name': 'welcome_neet', 'start_hour': 9, 'end_hour': 21, 'enabled': false, 'by': 'claude',
            },
            {
              'id': 'n2', 'name': 'JEE: no reply', 'match': 'jee', 'after_minutes': 180, 'only_if': 'no_reply',
              'template_id': 'w2', 'template_name': 'welcome_jee', 'start_hour': 9, 'end_hour': 21, 'enabled': true,
              'enabled_at': '2026-10-01T10:00:00Z',
            },
          ],
        },
      _ => <String, dynamic>{},
    };
    return jsonResponse([
      {'value': value},
    ]);
  }
  if (path.endsWith('/message_templates')) {
    return jsonResponse([
      for (final (i, t) in [
        ('whatsapp', 'Course details', 'Hi {name}, here are the NEET 2027 batch details: ...'),
        ('whatsapp', 'Fees', 'Hi {name}, the fee for the full course is ₹45,000 (EMI available).'),
        ('whatsapp', 'Brochure', 'Hi {name}, download our brochure: https://example.com/brochure.pdf'),
        ('sms', 'Call back', 'Hi {name}, we tried calling you about your enquiry. Call us back anytime.'),
      ].indexed)
        {'id': 't$i', 'channel': t.$1, 'name': t.$2, 'subject': null, 'body': t.$3, 'sort_order': i},
    ]);
  }
  if (path.endsWith('/rpc/dashboard_stats')) {
    return jsonResponse({
      'totals': {'new_leads': 18, 'calls': 94, 'admissions': 3, 'not_called': 4, 'unassigned': 2},
      'agents': [
        {'user_id': raviId, 'name': 'Ravi', 'daily_call_target': 50, 'calls': 56, 'connected': 38, 'talk_seconds': 7420,
          'messages': 21, 'leads_contacted': 44, 'admissions': 2, 'open_leads': 64, 'not_called': 1, 'overdue_followups': 0},
        {'user_id': sitaId, 'name': 'Sita', 'daily_call_target': 50, 'calls': 31, 'connected': 19, 'talk_seconds': 3900,
          'messages': 12, 'leads_contacted': 27, 'admissions': 1, 'open_leads': 58, 'not_called': 3, 'overdue_followups': 4},
        {'user_id': adminId, 'name': 'Admin', 'daily_call_target': null, 'calls': 7, 'connected': 5, 'talk_seconds': 820,
          'messages': 3, 'leads_contacted': 6, 'admissions': 0, 'open_leads': 9, 'not_called': 0, 'overdue_followups': 0},
      ],
      'sources': [
        {'source': 'meta_form', 'leads': 11, 'admissions': 2},
        {'source': 'google_landing', 'leads': 5, 'admissions': 1},
        {'source': 'excel', 'leads': 2, 'admissions': 0},
      ],
      'campaigns': [
        {'campaign': 'NEET Sept Campaign', 'source': 'meta_form', 'leads': 8, 'admissions': 2},
        {'campaign': 'JEE Search', 'source': 'google_landing', 'leads': 5, 'admissions': 1},
        {'campaign': 'Foundation Reels', 'source': 'meta_form', 'leads': 3, 'admissions': 0},
      ],
      'lost_reasons': [
        {'reason': 'Fees too high', 'count': 5},
        {'reason': 'Too far', 'count': 3},
        {'reason': 'Joined somewhere else', 'count': 2},
      ],
    });
  }
  if (path.endsWith('/rpc/leaderboard')) {
    return jsonResponse([
      {'user_id': raviId, 'name': 'Ravi', 'calls': 56, 'connected': 38, 'talk_seconds': 7420, 'admissions': 2,
        'daily_call_target': 50, 'monthly_admission_target': 10},
      {'user_id': sitaId, 'name': 'Sita', 'calls': 31, 'connected': 19, 'talk_seconds': 3900, 'admissions': 1,
        'daily_call_target': 50, 'monthly_admission_target': 10},
      {'user_id': adminId, 'name': 'Admin', 'calls': 7, 'connected': 5, 'talk_seconds': 820, 'admissions': 0,
        'daily_call_target': 20, 'monthly_admission_target': null},
    ]);
  }
  if (path.endsWith('/rpc/webinar_overview')) {
    return jsonResponse({
      'token_saved': true,
      'amount_divisor': 1,
      'last_sync_at': iso(now.subtract(const Duration(minutes: 41))),
      'last_sync_note': 'All fine',
      'last_event': 'registration.payment.completed',
      'last_event_at': iso(now.subtract(const Duration(minutes: 3))),
      'last_outcome': 'ok',
      'events_24h': 58,
      'errors': 0,
      'waiting': 0,
      'registrations': 214,
      'paid': 96,
      'unverified': 0,
    });
  }
  if (path.endsWith('/rpc/webinar_stats')) {
    return jsonResponse({
      'registered': 214,
      'paid': 96,
      'revenue': 14304,
      'failed': 31,
      'refunded': 149,
      'attended': 71,
      'missed': 25,
      'webinars': [
        {'webinar_id': 'w_184', 'title': 'NEET 2027: how to rank in 90 days', 'registered': 140, 'paid': 66, 'revenue': 9834, 'attended': 52},
        {'webinar_id': 'w_171', 'title': 'JEE Main: last 60 days plan', 'registered': 74, 'paid': 30, 'revenue': 4470, 'attended': 19},
      ],
    });
  }
  if (path.endsWith('/webinar_events')) return jsonResponse(webinarEvents);
  if (path.endsWith('/rpc/api_settings')) {
    return jsonResponse({
      'webhook_url': 'https://hooks.example.com/whatsweb',
      'secret_saved': true,
      'auth_saved': true,
      'webhook_enabled': true,
      'send_cap': 200,
      'sent_24h': 37,
      'pending_webhooks': 0,
      'failed_webhooks': 1,
    });
  }
  if (path.endsWith('/api_keys')) {
    return jsonResponse([
      {'id': 'k1', 'name': 'AI assistant', 'prefix': 'lcrm_91e5', 'scopes': ['read', 'send', 'write'], 'created_at': iso(now.subtract(const Duration(days: 3))),
        'last_used_at': iso(now.subtract(const Duration(minutes: 2))), 'revoked_at': null},
      {'id': 'k2', 'name': 'Test key', 'prefix': 'lcrm_3b07', 'scopes': ['read'], 'created_at': iso(now.subtract(const Duration(days: 9))),
        'last_used_at': iso(now.subtract(const Duration(days: 8))), 'revoked_at': iso(now.subtract(const Duration(days: 7)))},
    ]);
  }
  if (path.endsWith('/api_log')) {
    return jsonResponse([
      {'id': 3, 'at': iso(now.subtract(const Duration(minutes: 4))), 'key_name': 'AI assistant', 'method': 'POST', 'path': '/whatsapp/send-template', 'status': 200, 'summary': 'template fee_reminder sent', 'lead_id': 'l1'},
      {'id': 2, 'at': iso(now.subtract(const Duration(minutes: 9))), 'key_name': 'AI assistant', 'method': 'POST', 'path': '/whatsapp/send-text', 'status': 409, 'summary': 'refused', 'lead_id': 'l2'},
      {'id': 1, 'at': iso(now.subtract(const Duration(minutes: 30))), 'key_name': 'AI assistant', 'method': 'PATCH', 'path': '/students/l1', 'status': 200, 'summary': 'status New -> Interested', 'lead_id': 'l1'},
    ]);
  }
  if (path.endsWith('/webhook_deliveries')) {
    Map<String, dynamic> d(String id, String event, String status, int tries, int? code, String? err, int ago, String who) => {
          'id': id, 'event': event, 'status': status, 'attempts': tries, 'last_code': code, 'last_error': err,
          'next_attempt_at': iso(now), 'created_at': iso(now.subtract(Duration(minutes: ago))), 'delivered_at': status == 'ok' ? iso(now.subtract(Duration(minutes: ago))) : null,
          'payload': {'id': id, 'event': event, 'student': {'id': 'l1', 'name': who, 'phone': '+919876543210'}, 'data': {'text': 'Fees kitni hai?'}},
        };
    return jsonResponse([
      d('d1', 'whatsapp.reply', 'ok', 1, 200, null, 3, 'Rahul Kumar'),
      d('d2', 'course.purchased', 'retry', 2, 503, 'The address answered 503', 6, 'Neha Singh'),
      d('d3', 'student.created', 'failed', 4, 500, 'The address answered 500', 190, 'Amit Yadav'),
      d('d4', 'whatsapp.button_click', 'ok', 1, 200, null, 240, 'Priya Sharma'),
    ]);
  }
  if (path.endsWith('/rpc/appx_overview')) {
    return jsonResponse({
      'set_status': true,
      'min_amount': 500,
      'last_event': 'purchase',
      'last_event_at': iso(now.subtract(const Duration(minutes: 6))),
      'last_outcome': 'ok',
      'events_24h': 41,
      'errors': 0,
      'waiting': 0,
      'signups': 318,
      'purchases': 27,
    });
  }
  if (path.endsWith('/appx_events')) {
    return jsonResponse([
      for (final (i, e) in [
        ('purchase', 'Rahul Kumar', 'ok', 6),
        ('signup', 'Sneha Gupta', 'ok', 22),
        ('cancelled', 'Priya Sharma', 'ok', 75),
        ('signup', 'Amit Yadav', 'ok', 140),
        ('demo', 'Neha Singh', 'ok', 300),
      ].indexed)
        {
          'id': 200 - i,
          'kind': e.$1,
          'outcome': e.$3,
          'error': null,
          'attempts': 1,
          'created_at': iso(now.subtract(Duration(minutes: e.$4))),
          'body': {'name': e.$2, 'number': '98765432${10 + i}'},
        },
    ]);
  }
  if (path.endsWith('/mcp_actions')) {
    Map<String, dynamic> a(String id, String kind, String title, String status, List<String> lines, int ago,
            {String? highlight, String? reason, String? result, int recipients = 0}) =>
        {
          'id': id, 'kind': kind, 'title': title, 'status': status, 'args': {}, 'reason': reason, 'result': result,
          'preview': {'lines': lines, 'highlight': ?highlight, if (recipients > 0) 'recipients': recipients},
          'created_at': iso(now.subtract(Duration(minutes: ago))),
          'expires_at': iso(now.subtract(Duration(minutes: ago)).add(const Duration(hours: 24))),
          'decided_at': status == 'pending' ? null : iso(now.subtract(Duration(minutes: ago - 1))),
        };
    return jsonResponse([
      a('q1', 'set_status', 'Change 3 leads to "Call Back" and hot', 'pending',
          ['Rahul Kumar:  Interested → Call Back   no tag → hot', 'Neha Singh:  New → Call Back   no tag → hot', 'Aman Verma:  New → Call Back   no tag → hot'], 4,
          reason: 'You asked me to follow up everyone who asked about fees today.'),
      a('q2', 'wa_template', 'WhatsApp template "exam_dates" to 24 people', 'pending',
          ['Rahul Kumar', 'Neha Singh', 'Priya Sharma', '… and 21 more', 'Template: exam_dates (Utility)', 'Message: Hi {first_name}, {ask.semester} exam is on {ask.date}.', 'Filled in: semester = Semester 3, date = 12 Oct'], 6,
          highlight: 'Costs about ₹4 (₹0.15 each)', recipients: 24, reason: 'Semester 3 students from the Excel list.'),
      a('q6', 'wa_flow', 'Build WhatsApp template "bsc_maths_sem1_reminder" and 2 auto-replies', 'pending',
          [
            'Template "bsc_maths_sem1_reminder" · Marketing · Hindi · saved as a DRAFT',
            'Message: Namaste {first_name}, BSc Maths Sem 1 ki seats bhar rahi hain. Webinar ka ticket abhi lo.',
            'Button "Fees batao": when tapped it sends the reply "Fees info", tags the lead Warm',
            'Button "Abhi nahi": when tapped it sets the status to Not Interested, notes the reason "Not now"',
            '2 automatic replies (sent only when a student taps a button; no Meta approval needed):',
            '"Fees info" (message with buttons): Webinar ticket sirf Rs 149.',
            '    – "Ticket lena hai": sends the reply "Pay steps", sets the status to Interested, tags the lead Hot',
            '"Pay steps" (message): Is link se pay karo.',
          ],
          12,
          highlight: 'Nothing goes to Meta or to students. The template is saved as a DRAFT: you send it to Meta yourself.',
          reason: 'You described this flow for the BSc Maths landing page.'),
      a('q3', 'add_remark', 'Write a remark on Rahul Kumar', 'pending', ['Parents want a call after 6 PM, asked about hostel fees.'], 9),
      a('q4', 'assign', 'Give 12 leads to Sita', 'done', ['12 leads will be given to: Sita'], 190, result: 'Gave 12 leads to the team.'),
      a('q5', 'wa_text', 'WhatsApp message to Neha Singh', 'rejected', ['Hello Neha, the batch starts on Monday.'], 260),
    ]);
  }
  if (path.endsWith('/mcp_log')) {
    return jsonResponse([
      {'id': 4, 'at': iso(now.subtract(const Duration(minutes: 2))), 'tool': 'crm_leads', 'args': {'range': 'last_7_days', 'never_called': true, 'agent': 'Sita'}},
      {'id': 3, 'at': iso(now.subtract(const Duration(minutes: 3))), 'tool': 'crm_team', 'args': {'range': 'last_7_days'}},
      {'id': 2, 'at': iso(now.subtract(const Duration(minutes: 3))), 'tool': 'crm_overview', 'args': {'range': 'last_7_days'}},
      {'id': 1, 'at': iso(now.subtract(const Duration(minutes: 4))), 'tool': 'crm_info', 'args': {}},
    ]);
  }
  if (path.endsWith('/webinar_registrations')) {
    return jsonResponse([
      {
        'registration_id': 'r1', 'lead_id': 'l1', 'webinar_id': 'w_184', 'webinar_title': 'NEET 2027: how to rank in 90 days',
        'status': 'approved', 'registered_at': iso(now.subtract(const Duration(minutes: 4))), 'attended': true,
      },
    ]);
  }
  if (path.endsWith('/webinar_payments')) {
    return jsonResponse([
      {
        'payment_id': 'p1', 'lead_id': 'l1', 'status': 'paid', 'ticket_amount': 149, 'processing_fee': 3, 'total_charged': 152,
        'refunded_amount': 0, 'verified': true, 'paid_at': iso(now.subtract(const Duration(minutes: 3))),
        'created_at': iso(now.subtract(const Duration(minutes: 3))),
      },
    ]);
  }
  if (path.endsWith('/wa_templates')) return jsonResponse(waTemplates);
  if (path.endsWith('/wa_nodes')) return jsonResponse(waNodes);
  if (path.endsWith('/wa_messages')) return jsonResponse(waMessages);
  if (path.endsWith('/import_batches')) {
    return jsonResponse([
      {'id': 'b1', 'name': 'enquiries_oct · 5 Oct', 'created_at': iso(now.subtract(const Duration(hours: 3))), 'added': 120, 'duplicates': 14, 'leads': [{'count': 120}]},
      {'id': 'b2', 'name': 'enquiries_sept · 28 Sep', 'created_at': iso(now.subtract(const Duration(days: 7))), 'added': 86, 'duplicates': 9, 'leads': [{'count': 71}]},
    ]);
  }
  if (path.endsWith('/rpc/lead_source_list')) {
    return jsonResponse([
      {'source': 'meta_form', 'source_detail': 'NEET Sept Campaign', 'total': 48},
      {'source': 'google_landing', 'source_detail': 'JEE Search', 'total': 31},
      {'source': 'website', 'source_detail': 'landing-page-1', 'total': 22},
      {'source': 'website', 'source_detail': 'landing-page-2', 'total': 17},
      {'source': 'excel', 'source_detail': 'enquiries_oct.xlsx', 'total': 120},
    ]);
  }
  if (path.endsWith('/rpc/wa_audience_count')) return jsonResponse(37);
  if (path.endsWith('/rpc/wa_broadcast_list')) {
    return jsonResponse([
      {'id': 'x1', 'name': 'Fees reminder · 3 Oct', 'template_name': 'fees_reminder', 'created_at': iso(now.subtract(const Duration(days: 2))), 'status': 'done',
        'total': 120, 'pending': 0, 'sent': 118, 'delivered': 109, 'read': 71, 'failed': 2, 'replied': 18},
      {'id': 'x2', 'name': 'Open day invite', 'template_name': 'open_day', 'created_at': iso(now.subtract(const Duration(minutes: 8))), 'status': 'sending',
        'total': 300, 'pending': 120, 'sent': 180, 'delivered': 150, 'read': 40, 'failed': 0, 'replied': 3},
    ]);
  }
  if (path.endsWith('/rpc/wa_stats')) {
    return jsonResponse({
      'totals': {'sent': 412, 'delivered': 388, 'read': 251, 'failed': 9, 'inbound': 96, 'replied_leads': 63, 'templates_sent': 380},
      'kinds': [
        {'kind': 'auto', 'sent': 210, 'delivered': 201, 'read': 140, 'failed': 3},
        {'kind': 'followup', 'sent': 96, 'delivered': 88, 'read': 51, 'failed': 4},
        {'kind': 'broadcast', 'sent': 74, 'delivered': 70, 'read': 41, 'failed': 2},
      ],
      'templates': [
        {'name': 'welcome_neet', 'sent': 140, 'delivered': 135, 'read': 98, 'failed': 1, 'replied': 41},
        {'name': 'welcome_jee', 'sent': 70, 'delivered': 66, 'read': 42, 'failed': 2, 'replied': 17},
      ],
      'states': {'replied': 63, 'read': 120},
    });
  }
  if (path.contains('/functions/v1/whatsapp')) {
    return jsonResponse({
      'webhook_url': 'https://demo.supabase.co/functions/v1/whatsapp-webhook',
      'verify_token': '5b1f0c9d2a7e4f38b6d1c0a9e8f7d6c5',
      'phone_number_id': '109876543210987',
      'waba_id': '208765432109876',
      'app_id': '1234567890123456',
      'token_saved': '••••x9Zq',
      'secret_saved': true,
      'status': {'connected': true, 'display_phone': '+91 98765 43210', 'verified_name': 'AIFM Education', 'quality': 'GREEN', 'tier': 'TIER_1K'},
    });
  }
  if (path.endsWith('/leads')) {
    final id = q['id']?.replaceFirst('eq.', '');
    if (q.containsKey('wa_last_message_at')) {
      return jsonResponse(leads.where((l) => l['wa_last_message_at'] != null).toList());
    }
    return jsonResponse(id == null ? leads : leads.where((l) => l['id'] == id).toList());
  }
  if (path.endsWith('/lead_activities')) return jsonResponse(activities);
  if (path.endsWith('/reminders')) {
    final leadId = q['lead_id']?.replaceFirst('eq.', '');
    final all = reminders();
    return jsonResponse(leadId == null ? all : all.where((r) => r['lead_id'] == leadId).toList());
  }
  return jsonResponse([]);
}

class _FakeNotifications extends FlutterLocalNotificationsPlatform {
  @override
  Future<NotificationAppLaunchDetails?> getNotificationAppLaunchDetails() async => null;

  @override
  Future<void> cancelAllPendingNotifications() async {}

  @override
  Future<void> cancelAll() async {}

  @override
  Future<void> cancel({required int id}) async {}
}

Future<void> loadFonts() async {
  const dir = '/opt/sdk/flutter/bin/cache/artifacts/material_fonts';
  final roboto = FontLoader('Roboto');
  for (final w in ['Regular', 'Medium', 'Bold', 'Light']) {
    final f = File('$dir/Roboto-$w.ttf');
    if (f.existsSync()) roboto.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
  }
  await roboto.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.sublistView(File('$dir/MaterialIcons-Regular.otf').readAsBytesSync())));
  await icons.load();
}

Widget app(Widget home, {bool wide = false}) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light).copyWith(
        textTheme: buildTheme(Brightness.light).textTheme.apply(fontFamily: 'Roboto'),
      ),
      home: home,
      builder: wide ? (context, child) => wideLayout(context, child!) : null,
    );

Future<void> shot(WidgetTester tester, String name) async {
  await tester.pumpAndSettle();
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('../../docs/screenshots/$name.png'));
  debugDisableShadows = true;
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'WhatsWeb',
      packageName: 'com.whatsweb.app',
      version: '0.1.0',
      buildNumber: '1',
      buildSignature: '',
    );
    FlutterLocalNotificationsPlatform.instance = _FakeNotifications();
    await loadFonts();
    await Supabase.initialize(
      url: 'https://demo.supabase.co',
      publishableKey: 'demo',
      httpClient: MockClient(handler),
      authOptions: const FlutterAuthClientOptions(detectSessionInUri: false, autoRefreshToken: false),
    );
    await Supabase.instance.client.auth.signInWithPassword(email: 'admin@mycrm.in', password: 'x');
    Repo.waCaller = (action, body) async => {
          'webhook_url': 'https://demo.supabase.co/functions/v1/whatsapp-webhook',
          'verify_token': '5b1f0c9d2a7e4f38b6d1c0a9e8f7d6c5',
          'phone_number_id': '109876543210987',
          'waba_id': '208765432109876',
          'app_id': '1234567890123456',
          'token_saved': '••••x9Zq',
          'secret_saved': true,
          'status': {'connected': true, 'display_phone': '+91 98765 43210', 'verified_name': 'AIFM Education', 'quality': 'GREEN', 'tier': 'TIER_1K'},
        };
    Repo.webinarCaller = (action, body) async => {'ok': true};
    await AppState.instance.load();
  });

  void phone(WidgetTester tester, {double height = 800, double width = 360}) {
    tester.view.physicalSize = Size(width * 2, height * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    // real shadows instead of the test framework's black outlines (reset in shot())
    debugDisableShadows = false;
  }

  testWidgets('login', (tester) async {
    phone(tester);
    await tester.pumpWidget(app(const LoginScreen()));
    await shot(tester, '1_login');
  });

  testWidgets('leads list', (tester) async {
    phone(tester, height: 1000);
    await tester.pumpWidget(app(const HomeScreen()));
    await shot(tester, '2_leads');
  });

  testWidgets('select and assign', (tester) async {
    phone(tester);
    await tester.pumpWidget(app(const HomeScreen()));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Priya Sharma'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Neha Singh'));
    await tester.pumpAndSettle();
    await shot(tester, '3_select');
    final ctx = tester.element(find.byType(HomeScreen));
    showAssignSheet(ctx, ['l2', 'l4']);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Ravi'));
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Sita'));
    await shot(tester, '4_assign');
  });

  testWidgets('lead profile', (tester) async {
    phone(tester, height: 2050);
    await tester.pumpWidget(app(LeadDetailScreen(leadId: 'l1', initial: Lead.fromJson(leads.first))));
    await shot(tester, '5_lead_profile');
  });

  testWidgets('after call', (tester) async {
    phone(tester);
    await tester.pumpWidget(app(const Scaffold()));
    final ctx = tester.element(find.byType(Scaffold));
    showCallOutcomeSheet(ctx, Lead.fromJson(leads[3]));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Interested').first);
    await tester.enterText(find.byType(TextField), 'Wants fee details on WhatsApp');
    await tester.tap(find.text('Tomorrow evening'));
    await shot(tester, '6_after_call');
  });

  testWidgets('follow-ups', (tester) async {
    phone(tester);
    await tester.pumpWidget(app(const HomeScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Follow-ups'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Team').first);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Upcoming'));
    await shot(tester, '7_followups');
  });

  testWidgets('team', (tester) async {
    phone(tester);
    await tester.pumpWidget(app(const HomeScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.groups_outlined));
    await shot(tester, '8_team');
  });

  testWidgets('more', (tester) async {
    phone(tester);
    await tester.pumpWidget(app(const HomeScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('More'));
    await shot(tester, '9_more');
  });

  testWidgets('dashboard', (tester) async {
    phone(tester, height: 1500);
    await tester.pumpWidget(app(const DashboardScreen()));
    await shot(tester, '10_dashboard');
  });

  testWidgets('leaderboard', (tester) async {
    phone(tester, height: 900);
    await tester.pumpWidget(app(const LeaderboardScreen()));
    await shot(tester, '11_leaderboard');
  });

  testWidgets('template picker', (tester) async {
    phone(tester);
    await tester.pumpWidget(app(const Scaffold()));
    await AppState.instance.reloadTemplates();
    final ctx = tester.element(find.byType(Scaffold));
    pickTemplate(ctx, 'whatsapp');
    await shot(tester, '12_templates');
  });

  testWidgets('after call not answered, not interested reason', (tester) async {
    phone(tester, height: 1000);
    await tester.pumpWidget(app(const Scaffold()));
    final ctx = tester.element(find.byType(Scaffold));
    showCallOutcomeSheet(
      ctx,
      Lead.fromJson(leads[3]),
      phoneCall: PhoneCall('+917766554433', 'out', 185, now),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not Interested'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fees too high'));
    await tester.tap(find.text('❄️ Cold'));
    await shot(tester, '13_after_call_reason');
  });

  testWidgets('lock screen', (tester) async {
    phone(tester);
    await tester.pumpWidget(app(const LockScreen()));
    await shot(tester, '14_lock');
  });
  testWidgets('claude connector', (tester) async {
    phone(tester, height: 3400);
    await tester.pumpWidget(app(const ClaudeConnectorScreen()));
    await shot(tester, '29_claude_connector');
  });
  testWidgets('claude requests', (tester) async {
    phone(tester, height: 1100);
    await tester.pumpWidget(app(const ClaudeRequestsScreen()));
    await shot(tester, '30_claude_requests');
    await tester.tap(find.textContaining('exam_dates'));
    await shot(tester, '31_claude_request');
  });
  testWidgets('claude flow request', (tester) async {
    phone(tester, height: 1500);
    await tester.pumpWidget(app(const ClaudeRequestsScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('bsc_maths_sem1_reminder'));
    await shot(tester, '32_claude_flow');
  });
  testWidgets('webinar', (tester) async {
    phone(tester, height: 2300);
    await tester.pumpWidget(app(const WebinarScreen()));
    await shot(tester, '28_webinar');
  });
  testWidgets('api and webhooks', (tester) async {
    phone(tester, height: 2500);
    await tester.pumpWidget(app(const ApiScreen()));
    await shot(tester, '34_api');
  });
  testWidgets('api delivery log', (tester) async {
    phone(tester, height: 900);
    await tester.pumpWidget(app(const ApiDeliveriesScreen()));
    await shot(tester, '35_api_deliveries');
  });
  testWidgets('aifm app', (tester) async {
    phone(tester, height: 2300);
    await tester.pumpWidget(app(const AppxScreen()));
    await shot(tester, '33_appx');
  });
  testWidgets('whatsapp hub', (tester) async {
    phone(tester, height: 2750);
    await tester.pumpWidget(app(const WhatsappScreen()));
    await shot(tester, '15_wa_hub');
  });

  testWidgets('whatsapp templates', (tester) async {
    phone(tester, height: 1250);
    await tester.pumpWidget(app(const WaTemplatesScreen()));
    await shot(tester, '16_wa_templates');
  });

  testWidgets('whatsapp template editor', (tester) async {
    phone(tester, height: 2700);
    final t = WaTemplate.fromJson(waTemplates.first);
    await tester.pumpWidget(app(WaTemplateEditor(existing: t)));
    await shot(tester, '17_wa_template_editor');
  });

  testWidgets('whatsapp chat', (tester) async {
    phone(tester, height: 800);
    await tester.pumpWidget(app(WaChatScreen(lead: Lead.fromJson(leads.first))));
    await shot(tester, '18_wa_chat');
  });

  testWidgets('whatsapp chats', (tester) async {
    phone(tester, height: 700);
    await tester.pumpWidget(app(const WaChatsScreen()));
    await shot(tester, '19_wa_chats');
  });

  testWidgets('whatsapp broadcast', (tester) async {
    phone(tester, height: 2300);
    await tester.pumpWidget(app(const WaBroadcastScreen()));
    await tester.pumpAndSettle();
    await shot(tester, '20_wa_broadcast');
  });

  testWidgets('filters', (tester) async {
    phone(tester, height: 1250);
    await tester.pumpWidget(app(const LeadsScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Filters'));
    await tester.pumpAndSettle();
    await shot(tester, '21_filters');
  });
  testWidgets('choose several sources', (tester) async {
    phone(tester, height: 1250);
    await tester.pumpWidget(app(const LeadsScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All sources'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('NEET Sept Campaign'));
    await tester.tap(find.text('All Website'));
    await tester.tap(find.text('enquiries_oct.xlsx'));
    await tester.pumpAndSettle();
    await shot(tester, '37_sources_many');
  });

  testWidgets('imported files', (tester) async {
    phone(tester, height: 600);
    await tester.pumpWidget(app(const ImportsScreen()));
    await shot(tester, '22_imports');
  });

  testWidgets('whatsapp connect', (tester) async {
    phone(tester, height: 1400);
    await tester.pumpWidget(app(const WaSetupScreen()));
    await shot(tester, '23_wa_setup');
  });

  testWidgets('whatsapp automatic replies', (tester) async {
    phone(tester, height: 800);
    await tester.pumpWidget(app(const WaNodesScreen()));
    await shot(tester, '24_wa_nodes');
  });

  testWidgets('send to numbers', (tester) async {
    phone(tester, height: 1100);
    await tester.pumpWidget(app(const WaQuickSendScreen()));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Phone numbers'), '9876543210\n98765 43211  Rahul\nPriya, 9876543212\n+971501234567');
    await shot(tester, '25_wa_quick_send');
  });

  testWidgets('computer: leads', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    debugDisableShadows = false;
    await tester.pumpWidget(app(const HomeScreen(), wide: true));
    await shot(tester, '26_web_leads');
  });

  testWidgets('computer: chats', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    debugDisableShadows = false;
    await tester.pumpWidget(app(const HomeScreen(), wide: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chats'));
    await shot(tester, '27_web_chats');
  });

  testWidgets('dashboard with whatsapp', (tester) async {
    phone(tester, height: 2700);
    await tester.pumpWidget(app(const DashboardScreen()));
    await shot(tester, '10_dashboard');
  });
}
