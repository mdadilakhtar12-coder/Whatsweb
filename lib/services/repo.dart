import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models.dart';

SupabaseClient get db => Supabase.instance.client;

String? get currentUserId => db.auth.currentUser?.id;

/// One chosen source: the source itself (website, excel, ...) and optionally the page / form / file name.
/// Without a detail it means every lead of that source.
typedef SourcePick = ({String source, String? detail});

/// "source.eq.x" or "and(source.eq.x,source_detail.eq.y)" for each pick, joined with commas (= any of them).
/// Values are quoted, so commas, brackets and dots in a campaign or file name cannot break the filter.
@visibleForTesting
String sourceFilterText(List<SourcePick> picks) {
  String q(String v) => '"${v.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  return picks
      .map((p) => p.detail == null ? 'source.eq.${q(p.source)}' : 'and(source.eq.${q(p.source)},source_detail.eq.${q(p.detail!)})')
      .join(',');
}

/// Filter for the leads list (and the audience of a WhatsApp broadcast).
class LeadFilter {
  final String search;
  final String? status;

  /// null = everyone, 'unassigned', or a profile id
  final String? assignee;

  /// hot, warm, cold or null
  final String? temperature;

  /// Where the lead came from: one or more sources (website, excel, ...), each optionally narrowed to a page /
  /// form / file name. A lead matches when it matches ANY of them. Empty = every source.
  final List<SourcePick> sources;

  /// One Excel upload.
  final String? batchId;

  /// Created between [from] (included) and [to] (not included).
  final DateTime? from;
  final DateTime? to;

  /// Latest WhatsApp state: sent, delivered, read, replied, failed, no_whatsapp
  final String? waState;

  /// Webinar.gg: paid, registered, failed, refunded, cancelled, waitlisted
  final String? webinar;

  /// Webinar.gg attendance: 'yes' or 'no'
  final String? attended;

  /// AIFM Education app: purchased, signed_up, cancelled, refunded, or not_purchased (everyone else)
  final String? appx;

  const LeadFilter({
    this.search = '',
    this.status,
    this.assignee,
    this.temperature,
    this.sources = const [],
    this.batchId,
    this.from,
    this.to,
    this.waState,
    this.webinar,
    this.attended,
    this.appx,
  });

  LeadFilter copyWith({
    String? search,
    String? status,
    String? assignee,
    String? temperature,
    List<SourcePick>? sources,
    String? batchId,
    DateTime? from,
    DateTime? to,
    String? waState,
    String? webinar,
    String? attended,
    String? appx,
    bool clearAppx = false,
    bool clearWebinar = false,
    bool clearStatus = false,
    bool clearAssignee = false,
    bool clearTemperature = false,
    bool clearSource = false,
    bool clearBatch = false,
    bool clearDates = false,
    bool clearWa = false,
  }) =>
      LeadFilter(
        search: search ?? this.search,
        status: clearStatus ? null : (status ?? this.status),
        assignee: clearAssignee ? null : (assignee ?? this.assignee),
        temperature: clearTemperature ? null : (temperature ?? this.temperature),
        sources: clearSource ? const [] : (sources ?? this.sources),
        batchId: clearBatch ? null : (batchId ?? this.batchId),
        from: clearDates ? null : (from ?? this.from),
        to: clearDates ? null : (to ?? this.to),
        waState: clearWa ? null : (waState ?? this.waState),
        webinar: clearWebinar ? null : (webinar ?? this.webinar),
        attended: clearWebinar ? null : (attended ?? this.attended),
        appx: clearAppx ? null : (appx ?? this.appx),
      );

  /// Filters from the "Filters" sheet (the quick chips are counted separately).
  int get sheetCount =>
      (sources.isNotEmpty ? 1 : 0) +
      (batchId != null ? 1 : 0) +
      (from != null ? 1 : 0) +
      (waState != null ? 1 : 0) +
      (webinar != null ? 1 : 0) +
      (attended != null ? 1 : 0) +
      (appx != null ? 1 : 0);

  /// For the broadcast audience (the database function reads these keys).
  Map<String, dynamic> toAudience() => {
        'status': ?status,
        'temperature': ?temperature,
        'assignee': ?assignee,
        if (sources.isNotEmpty)
          'sources': [
            for (final s in sources) {'source': s.source, if (s.detail != null) 'source_detail': s.detail},
          ],
        'batch_id': ?batchId,
        'from': ?from?.toUtc().toIso8601String(),
        'to': ?to?.toUtc().toIso8601String(),
        'wa': ?waState,
        'webinar': ?webinar,
        'attended': ?attended,
        'appx': ?appx,
      };
}

/// All database calls in one place.
class Repo {
  static const pageSize = 40;

  // ---- profiles / settings ------------------------------------------------

  static Future<Profile?> myProfile() async {
    final uid = currentUserId;
    if (uid == null) return null;
    final row = await db.from('profiles').select().eq('id', uid).maybeSingle();
    return row == null ? null : Profile.fromJson(row);
  }

  static Future<List<Profile>> profiles() async {
    final rows = await db.from('profiles').select().order('full_name');
    return rows.map(Profile.fromJson).toList();
  }

  static Future<List<LeadStatus>> statuses() async {
    final rows = await db.from('lead_statuses').select().order('sort_order').order('id');
    return rows.map(LeadStatus.fromJson).toList();
  }

  static Future<Map<String, dynamic>?> setting(String key) async {
    final row = await db.from('app_settings').select('value').eq('key', key).maybeSingle();
    return (row?['value'] as Map?)?.cast<String, dynamic>();
  }

  static Future<void> saveSetting(String key, Map<String, dynamic> value) async {
    await db.from('app_settings').upsert({
      'key': key,
      'value': value,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  // ---- message templates ----------------------------------------------------

  static Future<List<MessageTemplate>> templates() async {
    final rows = await db.from('message_templates').select().order('sort_order').order('created_at');
    return rows.map(MessageTemplate.fromJson).toList();
  }

  static Future<void> saveTemplate({
    String? id,
    required String channel,
    required String name,
    String? subject,
    required String body,
    int sortOrder = 0,
  }) async {
    final values = {
      'channel': channel,
      'name': name,
      'subject': subject,
      'body': body,
      'sort_order': sortOrder,
    };
    if (id == null) {
      await db.from('message_templates').insert(values);
    } else {
      await db.from('message_templates').update(values).eq('id', id);
    }
  }

  static Future<void> deleteTemplate(String id) async {
    await db.from('message_templates').delete().eq('id', id);
  }

  static Future<void> updateProfile(String id, Map<String, dynamic> values) async {
    await db.from('profiles').update(values).eq('id', id);
  }

  // ---- leads ----------------------------------------------------------------

  static Future<List<Lead>> leads(LeadFilter f, {int offset = 0, int limit = pageSize}) async {
    var q = db.from('leads').select();
    if (f.status != null) q = q.eq('status', f.status!);
    if (f.temperature != null) q = q.eq('temperature', f.temperature!);
    if (f.sources.isNotEmpty) q = q.or(sourceFilterText(f.sources));
    if (f.batchId != null) q = q.eq('import_batch_id', f.batchId!);
    if (f.from != null) q = q.gte('created_at', f.from!.toUtc().toIso8601String());
    if (f.to != null) q = q.lt('created_at', f.to!.toUtc().toIso8601String());
    if (f.waState != null) q = q.eq('wa_state', f.waState!);
    if (f.webinar != null) q = q.eq('webinar_state', f.webinar!);
    if (f.attended != null) q = q.eq('webinar_attended', f.attended == 'yes');
    if (f.appx == 'not_purchased') {
      q = q.or('appx_state.is.null,appx_state.neq.purchased');
    } else if (f.appx != null) {
      q = q.eq('appx_state', f.appx!);
    }
    if (f.assignee == 'unassigned') {
      q = q.isFilter('assigned_to', null);
    } else if (f.assignee != null) {
      q = q.eq('assigned_to', f.assignee!);
    }
    final s = f.search.replaceAll(RegExp(r'[,()*%\\]'), ' ').trim();
    if (s.isNotEmpty) {
      final digits = s.replaceAll(RegExp(r'\D'), '');
      final parts = <String>['name.ilike.*$s*', 'email.ilike.*$s*'];
      if (digits.length >= 3) parts.add('phone.ilike.*$digits*');
      q = q.or(parts.join(','));
    }
    final rows = await q.order('created_at', ascending: false).range(offset, offset + limit - 1);
    return rows.map(Lead.fromJson).toList();
  }

  static Future<Lead?> lead(String id) async {
    final row = await db.from('leads').select().eq('id', id).maybeSingle();
    return row == null ? null : Lead.fromJson(row);
  }

  /// Returns {status: created|duplicate|duplicate_other, id?}
  static Future<Map<String, dynamic>> createLead({
    required String name,
    required String phone,
    String? email,
    String? assignTo,
  }) async {
    final res = await db.rpc('create_lead', params: {
      'p_name': name,
      'p_phone': phone,
      'p_email': email,
      'p_assign_to': assignTo,
    });
    return (res as Map).cast<String, dynamic>();
  }

  static Future<void> updateLead(String id, Map<String, dynamic> values) async {
    await db.from('leads').update(values).eq('id', id);
  }

  static Future<void> deleteLeads(List<String> ids) async {
    await db.from('leads').delete().inFilter('id', ids);
  }

  static Future<int> assignLeads(List<String> leadIds, List<String> agentIds) async {
    final res = await db.rpc('assign_leads', params: {
      'p_lead_ids': leadIds,
      'p_agent_ids': agentIds,
    });
    return (res as num).toInt();
  }

  static Future<Map<String, dynamic>> importLeads(
    List<Map<String, dynamic>> rows, {
    String? assignTo,
    String? sourceDetail,
    String? batchId,
  }) async {
    final res = await db.rpc('import_leads', params: {
      'p_rows': rows,
      'p_assign_to': assignTo,
      'p_source_detail': sourceDetail,
      'p_batch_id': batchId,
    });
    return (res as Map).cast<String, dynamic>();
  }

  // ---- where leads came from -------------------------------------------------

  /// (source, page / form / file name, how many leads) for the filter.
  static Future<List<({String source, String? detail, int total})>> sourceList() async {
    final rows = await db.rpc('lead_source_list') as List;
    return rows
        .cast<Map>()
        .map((r) => (source: r['source'] as String, detail: r['source_detail'] as String?, total: (r['total'] as num).toInt()))
        .toList();
  }

  static Future<List<ImportBatch>> importBatches() async {
    final rows = await db.from('import_batches').select('*, leads(count)').order('created_at', ascending: false).limit(100);
    return rows.map(ImportBatch.fromJson).toList();
  }

  static Future<String> createImportBatch(String name, int total) async {
    final res = await db.rpc('create_import_batch', params: {'p_name': name, 'p_total': total});
    return res as String;
  }

  /// Removes the leads of a file that nobody has worked on. Returns {deleted, kept}.
  static Future<Map<String, dynamic>> deleteImportBatch(String id) async {
    final res = await db.rpc('delete_import_batch', params: {'p_id': id});
    return (res as Map).cast<String, dynamic>();
  }

  /// assigned_to (null = unassigned) -> status -> count
  static Future<Map<String?, Map<String, int>>> leadCounts() async {
    final rows = await db.rpc('lead_counts') as List;
    final out = <String?, Map<String, int>>{};
    for (final r in rows.cast<Map>()) {
      final who = r['assigned_to'] as String?;
      out.putIfAbsent(who, () => {})[r['status'] as String] = (r['total'] as num).toInt();
    }
    return out;
  }

  // ---- activities -------------------------------------------------------------

  static Future<List<Activity>> activities(String leadId) async {
    final rows = await db
        .from('lead_activities')
        .select()
        .eq('lead_id', leadId)
        .order('created_at', ascending: false)
        .limit(200);
    return rows.map(Activity.fromJson).toList();
  }

  static Future<void> addActivity(String leadId, String type, {String? body, Map<String, dynamic>? meta}) async {
    await db.from('lead_activities').insert({
      'lead_id': leadId,
      'type': type,
      'body': ?body,
      'meta': ?meta,
    });
  }

  /// Logs a call / WhatsApp / SMS / email tap and stamps last_contacted_at.
  static Future<void> logContact(String leadId, String type) async {
    await Future.wait([
      addActivity(leadId, type),
      updateLead(leadId, {'last_contacted_at': DateTime.now().toUtc().toIso8601String()}),
    ]);
  }

  /// Calls from the phone's call log; the server keeps only calls with leads.
  static Future<int> logCalls(List<Map<String, dynamic>> calls) async {
    final res = await db.rpc('log_calls', params: {'p_calls': calls});
    return (res as num?)?.toInt() ?? 0;
  }

  // ---- push notifications ------------------------------------------------------

  static Future<void> registerDevice(String token) async {
    await db.rpc('register_device', params: {'p_token': token});
  }

  static Future<void> unregisterDevice(String token) async {
    await db.rpc('unregister_device', params: {'p_token': token});
  }

  // ---- reports ----------------------------------------------------------------

  static Future<Map<String, dynamic>> dashboard(DateTime from, DateTime to) async {
    final res = await db.rpc('dashboard_stats', params: {
      'p_from': from.toUtc().toIso8601String(),
      'p_to': to.toUtc().toIso8601String(),
    });
    return (res as Map).cast<String, dynamic>();
  }

  static Future<List<Map<String, dynamic>>> leaderboard(DateTime from, DateTime to) async {
    final res = await db.rpc('leaderboard', params: {
      'p_from': from.toUtc().toIso8601String(),
      'p_to': to.toUtc().toIso8601String(),
    });
    return (res as List).cast<Map>().map((m) => m.cast<String, dynamic>()).toList();
  }

  // ---- reminders --------------------------------------------------------------

  static Future<List<Reminder>> leadReminders(String leadId) async {
    final rows = await db
        .from('reminders')
        .select()
        .eq('lead_id', leadId)
        .eq('is_done', false)
        .order('remind_at');
    return rows.map(Reminder.fromJson).toList();
  }

  /// Open reminders with their lead. [userId] null = everyone (admin).
  static Future<List<Reminder>> openReminders({String? userId, DateTime? until}) async {
    var q = db.from('reminders').select('*, leads(*)').eq('is_done', false);
    if (userId != null) q = q.eq('user_id', userId);
    if (until != null) q = q.lte('remind_at', until.toUtc().toIso8601String());
    final rows = await q.order('remind_at').limit(500);
    return rows.map(Reminder.fromJson).where((r) => r.lead != null).toList();
  }

  static Future<Reminder> addReminder({
    required String leadId,
    required DateTime at,
    String? note,
    String? userId,
  }) async {
    final row = await db
        .from('reminders')
        .insert({
          'lead_id': leadId,
          'remind_at': at.toUtc().toIso8601String(),
          if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
          'user_id': ?userId,
        })
        .select('*, leads(*)')
        .single();
    return Reminder.fromJson(row);
  }

  static Future<void> completeReminder(String id) async {
    await db.from('reminders').update({'is_done': true}).eq('id', id);
  }

  static Future<void> deleteReminder(String id) async {
    await db.from('reminders').delete().eq('id', id);
  }

  // ---- WhatsApp ----------------------------------------------------------------

  /// Lets the screenshot tool answer the server function without a network.
  @visibleForTesting
  static Future<Map<String, dynamic>> Function(String action, Map<String, dynamic> body)? waCaller;

  /// Calls the "whatsapp" server function (connect, send, templates...).
  static Future<Map<String, dynamic>> wa(String action, [Map<String, dynamic> body = const {}]) async {
    if (waCaller != null) return waCaller!(action, body);
    final res = await db.functions.invoke('whatsapp', body: {'action': action, ...body});
    final data = res.data;
    if (data is Map && data['error'] != null) throw Exception(data['error']);
    return (data as Map?)?.cast<String, dynamic>() ?? {};
  }

  static Future<List<WaTemplate>> waTemplates() async {
    final rows = await db.from('wa_templates').select().order('created_at', ascending: false);
    return rows.map(WaTemplate.fromJson).toList();
  }

  /// Saves a template (new when [id] is null) and returns its id.
  static Future<String> saveWaTemplate({
    String? id,
    required String name,
    required String language,
    required String category,
    required Map<String, dynamic> spec,
  }) async {
    final values = {
      'name': name,
      'language': language,
      'category': category,
      'spec': spec,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    if (id == null) {
      final row = await db.from('wa_templates').insert(values).select('id').single();
      return row['id'] as String;
    }
    await db.from('wa_templates').update(values).eq('id', id);
    return id;
  }

  static Future<List<WaNode>> waNodes() async {
    final rows = await db.from('wa_nodes').select().order('created_at');
    return rows.map(WaNode.fromJson).toList();
  }

  static Future<void> saveWaNode(String? id, Map<String, dynamic> values) async {
    if (id == null) {
      await db.from('wa_nodes').insert(values);
    } else {
      await db.from('wa_nodes').update(values).eq('id', id);
    }
  }

  static Future<void> deleteWaNode(String id) async {
    await db.from('wa_nodes').delete().eq('id', id);
  }

  static Future<List<WaMessage>> waMessages(String leadId) async {
    final rows = await db
        .from('wa_messages')
        .select()
        .eq('lead_id', leadId)
        .order('created_at', ascending: false)
        .limit(300);
    return rows.map(WaMessage.fromJson).toList().reversed.toList();
  }

  /// Conversations: leads with WhatsApp messages, latest first.
  static Future<List<Lead>> waChats({bool unreadOnly = false, String search = '', int limit = 100}) async {
    var q = db.from('leads').select().not('wa_last_message_at', 'is', null);
    if (unreadOnly) q = q.gt('wa_unread', 0);
    final s = search.replaceAll(RegExp(r'[,()*%\\]'), ' ').trim();
    if (s.isNotEmpty) {
      final digits = s.replaceAll(RegExp(r'\D'), '');
      q = q.or([
        'name.ilike.*$s*',
        if (digits.length >= 3) 'phone.ilike.*$digits*',
      ].join(','));
    }
    final rows = await q.order('wa_last_message_at', ascending: false).limit(limit);
    return rows.map(Lead.fromJson).toList();
  }

  static Future<int> waUnreadCount() async {
    final res = await db.from('leads').select('id').gt('wa_unread', 0).count(CountOption.exact);
    return res.count;
  }

  /// Uploads a picture / PDF / video and returns its path in the WhatsApp file store.
  static Future<String> uploadWaMedia(String folder, String fileName, List<int> bytes, String mime) async {
    final safe = fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final path = '$folder/${DateTime.now().millisecondsSinceEpoch}_$safe';
    await db.storage.from('wa-media').uploadBinary(
          path,
          Uint8List.fromList(bytes),
          fileOptions: FileOptions(contentType: mime, upsert: true),
        );
    return path;
  }

  static Future<String> waMediaUrl(String path) => db.storage.from('wa-media').createSignedUrl(path, 3600);

  static Future<int> waAudienceCount(Map<String, dynamic> filter) async {
    final res = await db.rpc('wa_audience_count', params: {'p_filter': filter});
    return (res as num).toInt();
  }

  static Future<Map<String, dynamic>> waCreateBroadcast(String templateId, String name, Map<String, dynamic> filter,
      {Map<String, String> params = const {}}) async {
    final res = await db.rpc('wa_create_broadcast', params: {'p_template': templateId, 'p_name': name, 'p_filter': filter, 'p_params': params});
    return (res as Map).cast<String, dynamic>();
  }

  /// Sends a template to typed phone numbers (new numbers become leads). Returns the counts.
  static Future<Map<String, dynamic>> waSendToNumbers(String templateId, List<Map<String, dynamic>> entries,
      {String? name, Map<String, String> params = const {}}) async {
    final res = await db.rpc('wa_send_to_numbers', params: {'p_template': templateId, 'p_entries': entries, 'p_name': name, 'p_params': params});
    return (res as Map).cast<String, dynamic>();
  }

  static Future<void> waCancelBroadcast(String id) async {
    await db.rpc('wa_cancel_broadcast', params: {'p_id': id});
  }

  static Future<List<Map<String, dynamic>>> waBroadcasts() async {
    final res = await db.rpc('wa_broadcast_list') as List;
    return res.cast<Map>().map((m) => m.cast<String, dynamic>()).toList();
  }

  static Future<Map<String, dynamic>> waStats(DateTime from, DateTime to) async {
    final res = await db.rpc('wa_stats', params: {
      'p_from': from.toUtc().toIso8601String(),
      'p_to': to.toUtc().toIso8601String(),
    });
    return (res as Map).cast<String, dynamic>();
  }

  // ---- Webinar.gg -------------------------------------------------------------

  /// Test hook (see [waCaller]).
  @visibleForTesting
  static Future<Map<String, dynamic>> Function(String action, Map<String, dynamic> body)? webinarCaller;

  /// Calls the "webinar-gg" server function (save_token, sync_now, send_test...). Admin only.
  static Future<Map<String, dynamic>> webinar(String action, [Map<String, dynamic> body = const {}]) async {
    if (webinarCaller != null) return webinarCaller!(action, body);
    final res = await db.functions.invoke('webinar-gg', body: {'action': action, ...body});
    final data = res.data;
    if (data is Map && data['error'] != null) throw Exception(data['error']);
    return (data as Map?)?.cast<String, dynamic>() ?? {};
  }

  static Future<Map<String, dynamic>> webinarOverview() async {
    final res = await db.rpc('webinar_overview');
    return (res as Map).cast<String, dynamic>();
  }

  static Future<Map<String, dynamic>> webinarStats(DateTime from, DateTime to) async {
    final res = await db.rpc('webinar_stats', params: {
      'p_from': from.toUtc().toIso8601String(),
      'p_to': to.toUtc().toIso8601String(),
    });
    return (res as Map).cast<String, dynamic>();
  }

  static Future<void> webinarSetDivisor(num divisor) async {
    await db.rpc('webinar_set_divisor', params: {'p_divisor': divisor});
  }

  static Future<Map<String, dynamic>> webinarClearTests() async {
    final res = await db.rpc('webinar_clear_tests');
    return (res as Map).cast<String, dynamic>();
  }

  /// The latest events Webinar.gg sent (admin).
  static Future<List<Map<String, dynamic>>> webinarEvents({int limit = 15}) async {
    final rows = await db
        .from('webinar_events')
        .select('id, event, event_at, outcome, error, attempts, created_at, body')
        .order('id', ascending: false)
        .limit(limit);
    return rows.map((r) => r.cast<String, dynamic>()).toList();
  }

  /// One lead's webinar registrations and payments (newest first).
  static Future<({List<Map<String, dynamic>> registrations, List<Map<String, dynamic>> payments})> webinarFor(String leadId) async {
    final results = await Future.wait([
      db.from('webinar_registrations').select().eq('lead_id', leadId).order('registered_at', ascending: false, nullsFirst: false),
      db.from('webinar_payments').select().eq('lead_id', leadId).order('created_at', ascending: false),
    ]);
    List<Map<String, dynamic>> rows(Object v) => (v as List).map((r) => (r as Map).cast<String, dynamic>()).toList();
    return (registrations: rows(results[0]), payments: rows(results[1]));
  }

  // ---- AIFM Education app (Appx) -------------------------------------------------

  /// Test hook (see [waCaller]).
  @visibleForTesting
  static Future<Map<String, dynamic>> Function(String action, Map<String, dynamic> body)? appxCaller;

  /// Calls the "appx" server function (send_test). Admin only.
  static Future<Map<String, dynamic>> appx(String action, [Map<String, dynamic> body = const {}]) async {
    if (appxCaller != null) return appxCaller!(action, body);
    final res = await db.functions.invoke('appx', body: {'action': action, ...body});
    final data = res.data;
    if (data is Map && data['error'] != null) throw Exception(data['error']);
    return (data as Map?)?.cast<String, dynamic>() ?? {};
  }

  static Future<Map<String, dynamic>> appxOverview() async {
    final res = await db.rpc('appx_overview');
    return (res as Map).cast<String, dynamic>();
  }

  static Future<Map<String, dynamic>> appxStats(DateTime from, DateTime to) async {
    final res = await db.rpc('appx_stats', params: {
      'p_from': from.toUtc().toIso8601String(),
      'p_to': to.toUtc().toIso8601String(),
    });
    return (res as Map).cast<String, dynamic>();
  }

  static Future<void> appxSetConfig({required bool setStatus, required num minAmount}) async {
    await db.rpc('appx_set_config', params: {'p_set_status': setStatus, 'p_min_amount': minAmount});
  }

  static Future<Map<String, dynamic>> appxClearTests() async {
    final res = await db.rpc('appx_clear_tests');
    return (res as Map).cast<String, dynamic>();
  }

  /// The latest events the app sent (admin).
  static Future<List<Map<String, dynamic>>> appxEvents({int limit = 15}) async {
    final rows = await db
        .from('appx_events')
        .select('id, kind, outcome, error, attempts, created_at, body')
        .eq('is_test', false)
        .order('id', ascending: false)
        .limit(limit);
    return rows.map((r) => r.cast<String, dynamic>()).toList();
  }

  /// One lead's purchases in the app (newest first).
  static Future<List<Map<String, dynamic>>> appxFor(String leadId) async {
    final rows = await db.from('appx_purchases').select().eq('lead_id', leadId).order('purchased_at', ascending: false, nullsFirst: false);
    return rows.map((r) => r.cast<String, dynamic>()).toList();
  }

  // ---- Claude connector (admin) ---------------------------------------------------

  /// Makes a new secret address for the connector; the old one stops working.
  static Future<void> mcpRotate() async {
    await db.rpc('mcp_rotate_token');
  }

  static Future<void> mcpSetContacts(bool show) async {
    await db.rpc('mcp_set_contacts', params: {'p_show': show});
  }

  /// The switch of one thing Claude may do (read_chats, add_leads, ...). Off by default.
  static Future<void> mcpSetPerm(String key, bool on) async {
    await db.rpc('mcp_set_perm', params: {'p_key': key, 'p_on': on});
  }

  /// The most WhatsApp messages Claude's requests may add up to in a day.
  static Future<void> mcpSetWaCap(int cap) async {
    await db.rpc('mcp_set_wa_cap', params: {'p_cap': cap});
  }

  /// Claude's requests, newest first.
  static Future<List<McpAction>> mcpActions({int limit = 50}) async {
    final rows = await db.from('mcp_actions').select().order('created_at', ascending: false).limit(limit);
    return rows.map(McpAction.fromJson).toList();
  }

  /// Requests waiting for the owner.
  static Future<int> mcpPendingCount() async {
    final res = await db
        .from('mcp_actions')
        .select('id')
        .eq('status', 'pending')
        .gt('expires_at', DateTime.now().toUtc().toIso8601String())
        .count(CountOption.exact);
    return res.count;
  }

  /// Takes a request to do it (only once). Returns {kind, args, ...}.
  static Future<Map<String, dynamic>> mcpClaim(String id) async {
    final res = await db.rpc('mcp_claim_action', params: {'p_id': id});
    return (res as Map).cast<String, dynamic>();
  }

  static Future<void> mcpFinish(String id, bool ok, String result) async {
    await db.rpc('mcp_finish_action', params: {'p_id': id, 'p_ok': ok, 'p_result': result});
  }

  static Future<void> mcpReject(String id) async {
    await db.rpc('mcp_reject_action', params: {'p_id': id});
  }

  /// Changes the same fields on several leads at once.
  static Future<void> updateLeads(List<String> ids, Map<String, dynamic> values) async {
    await db.from('leads').update(values).inFilter('id', ids);
  }

  /// What Claude asked for lately (newest first).
  static Future<List<Map<String, dynamic>>> mcpLog({int limit = 25}) async {
    final rows = await db.from('mcp_log').select('id, at, tool, args').order('id', ascending: false).limit(limit);
    return rows.map((r) => r.cast<String, dynamic>()).toList();
  }

  // ---- REST API for the AI assistant (admin) ------------------------------------------

  static Future<Map<String, dynamic>> apiSettings() async {
    final res = await db.rpc('api_settings');
    return (res as Map).cast<String, dynamic>();
  }

  /// The keys (never the key itself: only its first letters), newest first.
  static Future<List<Map<String, dynamic>>> apiKeys() async {
    final rows = await db
        .from('api_keys')
        .select('id, name, prefix, scopes, created_at, last_used_at, revoked_at')
        .order('created_at', ascending: false);
    return rows.map((r) => r.cast<String, dynamic>()).toList();
  }

  /// Makes a key. The returned 'key' is shown once and cannot be read again.
  static Future<Map<String, dynamic>> apiKeyCreate(String name, List<String> scopes) async {
    final res = await db.rpc('api_key_create', params: {'p_name': name, 'p_scopes': scopes});
    return (res as Map).cast<String, dynamic>();
  }

  static Future<void> apiKeyRevoke(String id) async {
    await db.rpc('api_key_revoke', params: {'p_id': id});
  }

  /// [secret] and [auth]: null = keep the saved one, '' = remove it.
  /// [auth] is sent exactly as typed as the "Authorization" header of every delivery.
  static Future<void> apiWebhookSet({required String url, String? secret, String? auth, required bool enabled}) async {
    await db.rpc('api_webhook_set', params: {'p_url': url, 'p_secret': secret, 'p_auth': auth, 'p_enabled': enabled});
  }

  /// Every try of one delivery: the answer code and the start of what the address said.
  static Future<List<Map<String, dynamic>>> apiAttempts(String deliveryId) async {
    final rows = await db.from('webhook_attempts').select('attempt, at, code, body, error').eq('delivery_id', deliveryId).order('attempt');
    return rows.map((r) => r.cast<String, dynamic>()).toList();
  }

  static Future<void> apiSetCap(int cap) async {
    await db.rpc('api_set_cap', params: {'p_cap': cap});
  }

  static Future<void> apiWebhookTest() async {
    await db.rpc('api_webhook_test');
  }

  static Future<void> apiDeliveryRetry(String id) async {
    await db.rpc('api_delivery_retry', params: {'p_id': id});
  }

  static Future<List<Map<String, dynamic>>> apiDeliveries({int limit = 60}) async {
    final rows = await db
        .from('webhook_deliveries')
        .select('id, event, status, attempts, last_code, last_error, next_attempt_at, created_at, delivered_at, payload')
        .order('seq', ascending: false)
        .limit(limit);
    return rows.map((r) => r.cast<String, dynamic>()).toList();
  }

  /// What the AI assistant changed or sent through the API (newest first).
  static Future<List<Map<String, dynamic>>> apiLog({int limit = 15}) async {
    final rows = await db
        .from('api_log')
        .select('id, at, key_name, method, path, status, summary, lead_id')
        .order('id', ascending: false)
        .limit(limit);
    return rows.map((r) => r.cast<String, dynamic>()).toList();
  }

  // ---- team (admin, through the admin-users edge function) ----------------

  static Future<void> teamAction(Map<String, dynamic> body) async {
    final res = await db.functions.invoke('admin-users', body: body);
    final data = res.data;
    if (data is Map && data['error'] != null) {
      throw Exception(data['error']);
    }
  }
}

/// Human readable message for any error thrown by Supabase.
String errorText(Object e) {
  if (e is PostgrestException) return e.message;
  if (e is AuthException) return e.message;
  if (e is FunctionException) {
    final d = e.details;
    if (d is Map && d['error'] != null) return d['error'].toString();
    return 'Server error (${e.status})';
  }
  final s = e.toString();
  if (s.contains('SocketException') || s.contains('ClientException')) {
    return 'No internet connection';
  }
  return s.replaceFirst('Exception: ', '');
}
