import 'package:flutter/material.dart';

DateTime? _date(dynamic v) => v == null ? null : DateTime.parse(v as String).toLocal();

class Profile {
  final String id;
  final String fullName;
  final String? email;
  final String role;
  final bool isActive;
  final int? dailyCallTarget;
  final int? monthlyAdmissionTarget;

  const Profile({
    required this.id,
    required this.fullName,
    required this.email,
    required this.role,
    required this.isActive,
    this.dailyCallTarget,
    this.monthlyAdmissionTarget,
  });

  bool get isAdmin => role == 'admin';

  String get displayName => fullName.isNotEmpty ? fullName : (email ?? 'Unknown');

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
        id: j['id'] as String,
        fullName: (j['full_name'] as String?) ?? '',
        email: j['email'] as String?,
        role: (j['role'] as String?) ?? 'agent',
        isActive: (j['is_active'] as bool?) ?? true,
        dailyCallTarget: (j['daily_call_target'] as num?)?.toInt(),
        monthlyAdmissionTarget: (j['monthly_admission_target'] as num?)?.toInt(),
      );
}

class LeadStatus {
  final int id;
  final String name;
  final Color color;
  final int sortOrder;
  final bool isClosed;

  /// Counts as an admission in reports.
  final bool isWon;

  /// Asks for a reason (e.g. Not Interested → "Fees too high").
  final bool askReason;

  const LeadStatus({
    required this.id,
    required this.name,
    required this.color,
    required this.sortOrder,
    required this.isClosed,
    this.isWon = false,
    this.askReason = false,
  });

  factory LeadStatus.fromJson(Map<String, dynamic> j) => LeadStatus(
        id: j['id'] as int,
        name: j['name'] as String,
        color: parseHexColor(j['color'] as String?),
        sortOrder: (j['sort_order'] as int?) ?? 0,
        isClosed: (j['is_closed'] as bool?) ?? false,
        isWon: (j['is_won'] as bool?) ?? false,
        askReason: (j['ask_reason'] as bool?) ?? false,
      );
}

Color parseHexColor(String? hex) {
  final h = (hex ?? '').replaceFirst('#', '');
  final v = int.tryParse(h.length == 6 ? 'FF$h' : h, radix: 16);
  return v == null ? Colors.blueGrey : Color(v);
}

String colorToHex(Color c) {
  final argb = c.toARGB32();
  return '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

class Lead {
  final String id;
  final String name;
  final String? phone;
  final String? email;
  final String source;
  final String? sourceDetail;
  final String status;
  final String? assignedTo;
  final DateTime? assignedAt;
  final DateTime? lastContactedAt;
  final DateTime? nextFollowUpAt;
  final Map<String, dynamic> extra;
  final DateTime createdAt;

  /// hot, warm, cold or null
  final String? temperature;
  final String? lostReason;

  /// WhatsApp: none, queued, sent, delivered, read, replied, failed, no_whatsapp
  final String waState;
  final bool waOptOut;
  final DateTime? waLastInboundAt;
  final DateTime? waLastMessageAt;
  final String? waLastText;
  final String? waLastDirection;
  final int waUnread;
  final String? importBatchId;

  /// Webinar.gg: registered, paid, failed, refunded, cancelled, waitlisted (null = never registered)
  final String? webinarState;
  final double webinarPaid;
  final String? webinarTitle;

  /// null = not known yet
  final bool? webinarAttended;

  /// AIFM Education app (Appx): signed_up, purchased, cancelled, refunded (null = never seen in the app)
  final String? appxState;
  final double appxPaid;
  final String? appxItem;

  const Lead({
    required this.id,
    required this.name,
    required this.phone,
    required this.email,
    required this.source,
    required this.sourceDetail,
    required this.status,
    required this.assignedTo,
    required this.assignedAt,
    required this.lastContactedAt,
    required this.nextFollowUpAt,
    required this.extra,
    required this.createdAt,
    this.temperature,
    this.lostReason,
    this.waState = 'none',
    this.waOptOut = false,
    this.waLastInboundAt,
    this.waLastMessageAt,
    this.waLastText,
    this.waLastDirection,
    this.waUnread = 0,
    this.importBatchId,
    this.webinarState,
    this.webinarPaid = 0,
    this.webinarTitle,
    this.webinarAttended,
    this.appxState,
    this.appxPaid = 0,
    this.appxItem,
  });

  /// Free-form WhatsApp messages are allowed for 24 hours after the student last wrote.
  Duration? get waWindowLeft {
    final at = waLastInboundAt;
    if (at == null) return null;
    final left = const Duration(hours: 24) - DateTime.now().difference(at);
    return left.isNegative ? null : left;
  }

  /// A lead that was given to someone but nobody has called or messaged yet.
  bool get notContactedYet => status == 'New' && lastContactedAt == null && assignedTo != null;

  String get displayName => name.isNotEmpty ? name : (phone ?? email ?? 'No name');

  bool get hasPhone => (phone ?? '').isNotEmpty;
  bool get hasEmail => (email ?? '').isNotEmpty;

  factory Lead.fromJson(Map<String, dynamic> j) => Lead(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '',
        phone: j['phone'] as String?,
        email: j['email'] as String?,
        source: (j['source'] as String?) ?? 'manual',
        sourceDetail: j['source_detail'] as String?,
        status: (j['status'] as String?) ?? 'New',
        assignedTo: j['assigned_to'] as String?,
        assignedAt: _date(j['assigned_at']),
        lastContactedAt: _date(j['last_contacted_at']),
        nextFollowUpAt: _date(j['next_follow_up_at']),
        extra: (j['extra'] as Map?)?.cast<String, dynamic>() ?? const {},
        createdAt: _date(j['created_at']) ?? DateTime.now(),
        temperature: j['temperature'] as String?,
        lostReason: j['lost_reason'] as String?,
        waState: (j['wa_state'] as String?) ?? 'none',
        waOptOut: (j['wa_opt_out'] as bool?) ?? false,
        waLastInboundAt: _date(j['wa_last_inbound_at']),
        waLastMessageAt: _date(j['wa_last_message_at']),
        waLastText: j['wa_last_text'] as String?,
        waLastDirection: j['wa_last_direction'] as String?,
        waUnread: (j['wa_unread'] as num?)?.toInt() ?? 0,
        importBatchId: j['import_batch_id'] as String?,
        webinarState: j['webinar_state'] as String?,
        webinarPaid: (j['webinar_paid'] as num?)?.toDouble() ?? 0,
        webinarTitle: j['webinar_title'] as String?,
        webinarAttended: j['webinar_attended'] as bool?,
        appxState: j['appx_state'] as String?,
        appxPaid: (j['appx_paid'] as num?)?.toDouble() ?? 0,
        appxItem: j['appx_item'] as String?,
      );
}

/// "₹149", "₹149.5"
String rupees(num amount) {
  final whole = amount == amount.roundToDouble();
  final text = whole ? amount.round().toString() : amount.toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '');
  final digits = text.split('.');
  final grouped = digits[0].replaceAllMapped(RegExp(r'(\d)(?=(\d\d)+\d$)'), (m) => '${m[1]},');
  return '₹$grouped${digits.length > 1 ? '.${digits[1]}' : ''}';
}

const webinarStates = [
  ('paid', 'Paid'),
  ('registered', 'Registered, not paid'),
  ('failed', 'Payment failed'),
  ('refunded', 'Refunded'),
  ('cancelled', 'Cancelled'),
  ('waitlisted', 'Waitlisted'),
];

String webinarStateLabel(String state) =>
    webinarStates.where((s) => s.$1 == state).map((s) => s.$2).firstOrNull ?? state;

const appxStates = [
  ('purchased', 'Bought in the app'),
  ('signed_up', 'Signed up, not bought'),
  ('cancelled', 'Cancelled a payment'),
  ('refunded', 'Refunded'),
];

String appxStateLabel(String state) =>
    appxStates.where((s) => s.$1 == state).map((s) => s.$2).firstOrNull ?? state;

const temperatures = ['hot', 'warm', 'cold'];

String temperatureLabel(String t) => switch (t) {
      'hot' => '🔥 Hot',
      'warm' => '☀️ Warm',
      'cold' => '❄️ Cold',
      _ => t,
    };

Color temperatureColor(String t) => switch (t) {
      'hot' => const Color(0xFFD84315),
      'warm' => const Color(0xFFF9A825),
      'cold' => const Color(0xFF1E88E5),
      _ => Colors.blueGrey,
    };

const sourceLabels = {
  'webinar': 'Webinar.gg',
  'appx': 'AIFM Education app',
  'meta_form': 'Meta form',
  'meta_landing': 'Meta landing page',
  'google_form': 'Google form',
  'google_landing': 'Google landing page',
  'website': 'Website',
  'excel': 'Excel import',
  'whatsapp': 'WhatsApp',
  'manual': 'Added manually',
};

String waStateLabel(String s) => switch (s) {
      'queued' => 'Sending',
      'sent' => 'Sent',
      'delivered' => 'Delivered',
      'read' => 'Read',
      'replied' => 'Replied',
      'failed' => 'Failed',
      'no_whatsapp' => 'Not on WhatsApp',
      _ => s,
    };

String sourceLabel(String source) => sourceLabels[source] ?? source;

class Activity {
  final int id;
  final String? userId;
  final String type;
  final String? body;
  final Map<String, dynamic> meta;
  final DateTime createdAt;

  const Activity({
    required this.id,
    required this.userId,
    required this.type,
    required this.body,
    required this.meta,
    required this.createdAt,
  });

  factory Activity.fromJson(Map<String, dynamic> j) => Activity(
        id: j['id'] as int,
        userId: j['user_id'] as String?,
        type: j['type'] as String,
        body: j['body'] as String?,
        meta: (j['meta'] as Map?)?.cast<String, dynamic>() ?? const {},
        createdAt: _date(j['created_at']) ?? DateTime.now(),
      );
}

class Reminder {
  final String id;
  final int notifyId;
  final String leadId;
  final String userId;
  final DateTime remindAt;
  final String? note;
  final bool isDone;

  /// Filled when the query embeds the lead.
  final Lead? lead;

  const Reminder({
    required this.id,
    required this.notifyId,
    required this.leadId,
    required this.userId,
    required this.remindAt,
    required this.note,
    required this.isDone,
    this.lead,
  });

  factory Reminder.fromJson(Map<String, dynamic> j) => Reminder(
        id: j['id'] as String,
        notifyId: j['notify_id'] as int,
        leadId: j['lead_id'] as String,
        userId: j['user_id'] as String,
        remindAt: _date(j['remind_at'])!,
        note: j['note'] as String?,
        isDone: (j['is_done'] as bool?) ?? false,
        lead: j['leads'] is Map
            ? Lead.fromJson((j['leads'] as Map).cast<String, dynamic>())
            : null,
      );
}

class MessageTemplate {
  final String id;

  /// whatsapp, sms or email
  final String channel;
  final String name;
  final String? subject;
  final String body;
  final int sortOrder;

  const MessageTemplate({
    required this.id,
    required this.channel,
    required this.name,
    required this.subject,
    required this.body,
    required this.sortOrder,
  });

  factory MessageTemplate.fromJson(Map<String, dynamic> j) => MessageTemplate(
        id: j['id'] as String,
        channel: j['channel'] as String,
        name: (j['name'] as String?) ?? '',
        subject: j['subject'] as String?,
        body: (j['body'] as String?) ?? '',
        sortOrder: (j['sort_order'] as num?)?.toInt() ?? 0,
      );
}


/// One Excel / CSV upload ("folder" of leads).
class ImportBatch {
  final String id;
  final String name;
  final DateTime createdAt;
  final int added;
  final int duplicates;

  /// Leads of this file still in the CRM.
  final int remaining;

  const ImportBatch({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.added,
    required this.duplicates,
    required this.remaining,
  });

  factory ImportBatch.fromJson(Map<String, dynamic> j) {
    final embedded = j['leads'];
    final count = embedded is List && embedded.isNotEmpty ? (embedded.first as Map)['count'] : 0;
    return ImportBatch(
      id: j['id'] as String,
      name: (j['name'] as String?) ?? '',
      createdAt: _date(j['created_at']) ?? DateTime.now(),
      added: (j['added'] as num?)?.toInt() ?? 0,
      duplicates: (j['duplicates'] as num?)?.toInt() ?? 0,
      remaining: (count as num?)?.toInt() ?? 0,
    );
  }
}

/// A WhatsApp message template (made in the app, approved by Meta).
class WaTemplate {
  final String id;
  final String name;
  final String language;
  final String category;
  final Map<String, dynamic> spec;

  /// DRAFT, PENDING, APPROVED, REJECTED, PAUSED, DISABLED
  final String status;
  final String? reason;

  const WaTemplate({
    required this.id,
    required this.name,
    required this.language,
    required this.category,
    required this.spec,
    required this.status,
    required this.reason,
  });

  bool get approved => status == 'APPROVED';
  String get body => (spec['body'] as String?) ?? '';
  Map<String, dynamic> get header => (spec['header'] as Map?)?.cast<String, dynamic>() ?? const {};
  String get footer => (spec['footer'] as String?) ?? '';
  List<Map<String, dynamic>> get buttons =>
      ((spec['buttons'] as List?) ?? const []).map((b) => (b as Map).cast<String, dynamic>()).toList();

  /// Example text for custom variables ("ask.semester": "Semester 3"); Meta reads these, the preview shows them.
  Map<String, String> get examples =>
      ((spec['examples'] as Map?) ?? const {}).map((k, v) => MapEntry(k.toString(), v.toString()));

  /// Variables typed in when the message is sent: {ask.semester} -> semester.
  List<String> get askNames => waAskNames([
        if (header['type'] == 'text') (header['text'] as String?) ?? '',
        body,
        for (final b in buttons)
          if (b['type'] == 'url') (b['url'] as String?) ?? '',
      ]);

  factory WaTemplate.fromJson(Map<String, dynamic> j) => WaTemplate(
        id: j['id'] as String,
        name: j['name'] as String,
        language: (j['language'] as String?) ?? 'en',
        category: (j['category'] as String?) ?? 'MARKETING',
        spec: (j['spec'] as Map?)?.cast<String, dynamic>() ?? {},
        status: (j['status'] as String?) ?? 'DRAFT',
        reason: j['reason'] as String?,
      );
}

final _askVar = RegExp(r'\{\s*ask\.([A-Za-z][A-Za-z0-9_]*)\s*\}');

/// Names of the {ask.x} variables in some texts, lower-case, in order, without repeats.
List<String> waAskNames(Iterable<String> texts) {
  final out = <String>[];
  for (final t in texts) {
    for (final m in _askVar.allMatches(t)) {
      final n = m.group(1)!.toLowerCase();
      if (!out.contains(n)) out.add(n);
    }
  }
  return out;
}

/// An automatic reply: plain text, buttons, or a list to pick from.
class WaNode {
  final String id;
  final String name;

  /// text, buttons, list
  final String kind;
  final String? header;
  final String body;
  final String? footer;
  final String? mediaPath;
  final String? mediaType;
  final String? filename;
  final List<Map<String, dynamic>> buttons;
  final String? listButton;
  final List<Map<String, dynamic>> sections;

  const WaNode({
    required this.id,
    required this.name,
    required this.kind,
    required this.header,
    required this.body,
    required this.footer,
    required this.mediaPath,
    required this.mediaType,
    required this.filename,
    required this.buttons,
    required this.listButton,
    required this.sections,
  });

  factory WaNode.fromJson(Map<String, dynamic> j) => WaNode(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '',
        kind: (j['kind'] as String?) ?? 'text',
        header: j['header'] as String?,
        body: (j['body'] as String?) ?? '',
        footer: j['footer'] as String?,
        mediaPath: j['media_path'] as String?,
        mediaType: j['media_type'] as String?,
        filename: j['filename'] as String?,
        buttons: ((j['buttons'] as List?) ?? const []).map((b) => (b as Map).cast<String, dynamic>()).toList(),
        listButton: j['list_button'] as String?,
        sections: ((j['sections'] as List?) ?? const []).map((b) => (b as Map).cast<String, dynamic>()).toList(),
      );
}

class WaMessage {
  final String id;
  final String leadId;
  final bool outgoing;

  /// auto, followup, broadcast, manual, bot, inbound
  final String kind;

  /// text, template, image, video, document, audio, interactive, button, location, sticker, reaction, unknown
  final String type;
  final String body;
  final String? templateName;
  final String? mediaPath;
  final String? filename;

  /// queued, sent, delivered, read, failed, received
  final String status;
  final String? error;
  final DateTime createdAt;

  /// 'api' = sent through the REST API by the AI assistant
  final String? via;

  const WaMessage({
    required this.id,
    required this.leadId,
    required this.outgoing,
    required this.kind,
    required this.type,
    required this.body,
    required this.templateName,
    required this.mediaPath,
    required this.filename,
    required this.status,
    required this.error,
    required this.createdAt,
    this.via,
  });

  bool get byAiAssistant => via == 'api';

  factory WaMessage.fromJson(Map<String, dynamic> j) => WaMessage(
        id: j['id'] as String,
        leadId: j['lead_id'] as String,
        outgoing: j['direction'] == 'out',
        kind: (j['kind'] as String?) ?? 'manual',
        type: (j['type'] as String?) ?? 'text',
        body: (j['body'] as String?) ?? '',
        templateName: j['template_name'] as String?,
        mediaPath: j['media_path'] as String?,
        filename: j['filename'] as String?,
        status: (j['status'] as String?) ?? 'sent',
        error: j['error'] as String?,
        createdAt: _date(j['created_at']) ?? DateTime.now(),
        via: j['via'] as String?,
      );
}

/// What Claude asked for. The owner reads it and taps Approve or Reject.
class McpAction {
  final String id;

  /// add_leads, edit_lead, set_status, add_remark, set_reminder, assign, wa_text, wa_template
  final String kind;
  final String title;

  /// exactly what the app will do when it is approved
  final Map<String, dynamic> args;

  /// {lines: [...], highlight: "...", recipients: n}
  final Map<String, dynamic> preview;

  /// Claude's own words about why (never trusted)
  final String? reason;
  final String status;
  final String? result;
  final DateTime createdAt;
  final DateTime expiresAt;
  final DateTime? decidedAt;

  const McpAction({
    required this.id,
    required this.kind,
    required this.title,
    required this.args,
    required this.preview,
    required this.reason,
    required this.status,
    required this.result,
    required this.createdAt,
    required this.expiresAt,
    required this.decidedAt,
  });

  /// pending, running, done, failed, rejected, expired or interrupted (approved, but the phone stopped before it finished)
  String get state {
    final now = DateTime.now();
    if (status == 'pending' && expiresAt.isBefore(now)) return 'expired';
    if (status == 'running' && decidedAt != null && now.difference(decidedAt!).inMinutes >= 10) return 'interrupted';
    return status;
  }

  bool get waiting => state == 'pending';
  List<String> get lines => ((preview['lines'] as List?) ?? const []).map((e) => '$e').toList();
  String? get highlight => preview['highlight'] as String?;

  factory McpAction.fromJson(Map<String, dynamic> j) => McpAction(
        id: j['id'] as String,
        kind: (j['kind'] as String?) ?? '',
        title: (j['title'] as String?) ?? '',
        args: (j['args'] as Map?)?.cast<String, dynamic>() ?? const {},
        preview: (j['preview'] as Map?)?.cast<String, dynamic>() ?? const {},
        reason: j['reason'] as String?,
        status: (j['status'] as String?) ?? 'pending',
        result: j['result'] as String?,
        createdAt: _date(j['created_at']) ?? DateTime.now(),
        expiresAt: _date(j['expires_at']) ?? DateTime.now().add(const Duration(hours: 24)),
        decidedAt: _date(j['decided_at']),
      );
}
