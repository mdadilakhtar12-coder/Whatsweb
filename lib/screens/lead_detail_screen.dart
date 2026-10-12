import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import '../services/app_state.dart';
import '../services/call_log_sync.dart';
import '../services/lead_ops.dart';
import '../services/notifications.dart';
import '../services/repo.dart';
import '../widgets/assign_sheet.dart';
import '../widgets/contact_buttons.dart';
import '../widgets/reminder_picker.dart';
import '../widgets/reason_picker.dart';
import '../widgets/status_chip.dart';
import 'lead_form_screen.dart';
import '../widgets/wa_widgets.dart';
import '../widgets/appx_widgets.dart';
import '../widgets/webinar_widgets.dart';
import 'wa_chat_screen.dart';

class LeadDetailScreen extends StatefulWidget {
  final String leadId;
  final Lead? initial;

  const LeadDetailScreen({super.key, required this.leadId, this.initial});

  @override
  State<LeadDetailScreen> createState() => _LeadDetailScreenState();
}

class _LeadDetailScreenState extends State<LeadDetailScreen> {
  Lead? _lead;
  List<Activity> _activities = [];
  List<Reminder> _reminders = [];
  ({List<Map<String, dynamic>> registrations, List<Map<String, dynamic>> payments})? _webinar;
  List<Map<String, dynamic>>? _appx;
  bool _loading = true;
  String? _error;
  final _remark = TextEditingController();
  bool _savingRemark = false;

  @override
  void initState() {
    super.initState();
    _lead = widget.initial;
    _load();
  }

  @override
  void dispose() {
    _remark.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        Repo.lead(widget.leadId),
        Repo.activities(widget.leadId),
        Repo.leadReminders(widget.leadId),
      ]);
      if (!mounted) return;
      final lead = results[0] as Lead?;
      // the webinar details only exist for students who registered through Webinar.gg
      var webinar = _webinar;
      if (lead?.webinarState != null) {
        try {
          webinar = await Repo.webinarFor(widget.leadId);
        } catch (_) {
          // the summary on top of the page is still right
        }
      } else {
        webinar = null;
      }
      // the purchases only exist for students who came through the AIFM Education app
      var appx = _appx;
      if (lead?.appxState != null) {
        try {
          appx = await Repo.appxFor(widget.leadId);
        } catch (_) {
          // the summary on top of the page is still right
        }
      } else {
        appx = null;
      }
      if (!mounted) return;
      setState(() {
        _lead = lead;
        _appx = appx;
        _activities = results[1] as List<Activity>;
        _reminders = results[2] as List<Reminder>;
        _webinar = webinar;
        _loading = false;
        _error = _lead == null ? 'This lead was deleted or is no longer assigned to you.' : null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = errorText(e);
        });
      }
    }
  }

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _run(Future<void> Function() action, {String? done}) async {
    try {
      await action();
      if (done != null) _toast(done);
    } catch (e) {
      _toast(errorText(e));
    }
    await _load();
  }

  Future<void> _setStatus(String status) async {
    final lead = _lead!;
    String? reason;
    if (status != lead.status && (AppState.instance.status(status)?.askReason ?? false)) {
      reason = await pickLostReason(context, status);
      if (reason == null) return;
    }
    await _run(() => LeadOps.setStatus(lead, status, reason: reason), done: 'Status: $status');
  }

  Future<void> _setTemperature(String? t) =>
      _run(() => LeadOps.setTemperature(_lead!, t), done: t == null ? 'Tag removed' : temperatureLabel(t));

  Future<void> _saveRemark() async {
    if (_remark.text.trim().isEmpty) return;
    setState(() => _savingRemark = true);
    await _run(() => LeadOps.addRemark(_lead!, _remark.text), done: 'Remark saved');
    _remark.clear();
    if (mounted) {
      setState(() => _savingRemark = false);
      FocusScope.of(context).unfocus();
    }
  }

  Future<void> _addReminder() async {
    final choice = await pickReminder(context);
    if (choice == null) return;
    await _run(() => LeadOps.addReminder(_lead!, choice.at, choice.note), done: 'Reminder set for ${friendlyTime(choice.at)}');
  }

  Future<void> _assign() async {
    final n = await showAssignSheet(context, [_lead!.id]);
    if (n != null) await _load();
  }

  Future<void> _edit() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => LeadFormScreen(existing: _lead)),
    );
    if (changed == true) await _load();
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete this lead?'),
        content: const Text('Remarks and reminders are deleted too.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      for (final r in _reminders) {
        await Notifications.cancel(r);
      }
      await Repo.deleteLeads([_lead!.id]);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _toast(errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final lead = _lead;
    final admin = AppState.instance.isAdmin;

    return Scaffold(
      appBar: AppBar(
        title: Text(lead?.displayName ?? 'Lead'),
        actions: [
          if (lead != null) IconButton(tooltip: 'Edit', icon: const Icon(Icons.edit_outlined), onPressed: _edit),
          if (lead != null && admin)
            IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: _delete),
        ],
      ),
      body: lead == null
          ? Center(
              child: _loading
                  ? const CircularProgressIndicator()
                  : Padding(padding: const EdgeInsets.all(24), child: Text(_error ?? 'Not found')),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
                children: [
                  _header(lead, admin),
                  const SizedBox(height: 10),
                  _card(
                    child: ContactButtons(lead: lead, large: true, onUpdated: _load),
                  ),
                  if (AppState.instance.waConnected && lead.hasPhone) ...[
                    const SizedBox(height: 10),
                    _waCard(lead),
                  ],
                  if (lead.webinarState != null) ...[
                    const SizedBox(height: 10),
                    _webinarCard(lead),
                  ],
                  if (lead.appxState != null) ...[
                    const SizedBox(height: 10),
                    _appxCard(lead),
                  ],
                  const SizedBox(height: 10),
                  _statusCard(lead),
                  const SizedBox(height: 10),
                  _followUpCard(),
                  const SizedBox(height: 10),
                  _remarkCard(),
                  if (lead.extra.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    _extraCard(lead),
                  ],
                  const SizedBox(height: 10),
                  _historyCard(),
                ],
              ),
            ),
    );
  }

  /// Webinar.gg: registrations, payments and whether the student came.
  Widget _webinarCard(Lead lead) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5);
    final w = _webinar;
    String when(Object? v) {
      final d = v == null ? null : DateTime.tryParse('$v')?.toLocal();
      return d == null ? '' : DateFormat('d MMM, h:mm a').format(d);
    }

    return _card(
      title: 'Webinar',
      trailing: WebinarBadge(lead),
      child: w == null
          ? Text('Loading…', style: muted)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final r in w.registrations)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${r['webinar_title'] ?? 'Webinar'}', style: const TextStyle(fontWeight: FontWeight.w600)),
                        Text(
                          [
                            if (when(r['registered_at']).isNotEmpty) 'Registered ${when(r['registered_at'])}',
                            if ((r['status'] ?? '').toString().isNotEmpty) '${r['status']}',
                            if (r['attended'] == true) 'Attended' else if (r['attended'] == false) 'Did not attend',
                          ].join(' · '),
                          style: muted,
                        ),
                      ],
                    ),
                  ),
                if (w.payments.isNotEmpty) const Divider(height: 18),
                for (final p in w.payments) _paymentLine(p, muted, when),
              ],
            ),
    );
  }

  /// AIFM Education app: what this student bought.
  Widget _appxCard(Lead lead) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5);
    final buys = _appx;
    String when(Object? v) {
      final d = v == null ? null : DateTime.tryParse('$v')?.toLocal();
      return d == null ? '' : DateFormat('d MMM yyyy').format(d);
    }

    return _card(
      title: 'AIFM Education app',
      trailing: AppxBadge(lead),
      child: buys == null
          ? Text('Loading…', style: muted)
          : buys.isEmpty
              ? Text(lead.appxState == 'signed_up' ? 'Signed up in the app, has not bought yet.' : appxStateLabel(lead.appxState ?? ''), style: muted)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final p in buys)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${p['item'] ?? 'Purchase'}', style: const TextStyle(fontWeight: FontWeight.w600)),
                            Text(
                              [
                                if (p['amount'] != null) rupees(p['amount'] as num),
                                if ((p['refunded_amount'] as num? ?? 0) > 0) '${rupees(p['refunded_amount'] as num)} refunded',
                                if (when(p['purchased_at']).isNotEmpty) when(p['purchased_at']),
                                if ((p['payment_mode'] ?? '').toString().isNotEmpty) '${p['payment_mode']}',
                                if ((p['coupon'] ?? '').toString().isNotEmpty) 'coupon ${p['coupon']}',
                                if (when(p['expires_at']).isNotEmpty) 'valid till ${when(p['expires_at'])}',
                              ].join(' · '),
                              style: muted,
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
    );
  }

  Widget _paymentLine(Map<String, dynamic> p, TextStyle muted, String Function(Object?) when) {
    final status = '${p['status']}';
    final amount = (p['ticket_amount'] ?? p['total_charged']) as num?;
    final refunded = (p['refunded_amount'] as num?) ?? 0;
    final unconfirmed = p['verified'] == false;
    final color = unconfirmed ? Colors.orange.shade800 : webinarStateColor(status == 'paid' ? 'paid' : status);
    final label = switch (status) {
      'paid' => refunded > 0 ? 'Paid, ${rupees(refunded)} refunded' : 'Paid',
      'refunded' => 'Refunded',
      _ => 'Payment did not go through',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(webinarStateIcon(status == 'paid' ? 'paid' : status), size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${amount == null || status == 'failed' ? '' : '${rupees(amount)} · '}$label',
                  style: TextStyle(color: color, fontWeight: FontWeight.w600),
                ),
                Text(
                  [
                    when(p['paid_at'] ?? p['status_at'] ?? p['created_at']),
                    if (status != 'failed' && p['total_charged'] != null && p['total_charged'] != p['ticket_amount'])
                      '${rupees(p['total_charged'] as num)} charged with fees',
                    if (unconfirmed) 'Not found in Webinar.gg: check it',
                  ].where((e) => e.isNotEmpty).join(' · '),
                  style: muted,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// WhatsApp through the API: last message, ticks and a button to open the in-app chat.
  Widget _waCard(Lead lead) {
    final scheme = Theme.of(context).colorScheme;
    return _card(
      child: InkWell(
        onTap: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => WaChatScreen(lead: lead)));
          _load();
        },
        child: Row(
          children: [
            const CircleAvatar(backgroundColor: whatsappGreen, child: Icon(Icons.chat_bubble, color: Colors.white, size: 20)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('WhatsApp chat', style: TextStyle(fontWeight: FontWeight.w700)),
                  if (lead.waState != 'none') WaBadge(lead) else Text('No message sent yet', style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
                  if ((lead.waLastText ?? '').isNotEmpty)
                    Text(lead.waLastText!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }

  Widget _card({required Widget child, String? title, Widget? trailing}) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
                    ?trailing,
                  ],
                ),
              ),
            child,
          ],
        ),
      ),
    );
  }

  Widget _header(Lead lead, bool admin) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant);

    Widget line(IconData icon, String text, {VoidCallback? onTap}) => InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Icon(icon, size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(child: Text(text)),
              ],
            ),
          ),
        );

    void copy(String v) {
      Clipboard.setData(ClipboardData(text: v));
      _toast('Copied');
    }

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: scheme.primaryContainer,
                child: Text(
                  lead.displayName.substring(0, 1).toUpperCase(),
                  style: TextStyle(fontSize: 22, color: scheme.onPrimaryContainer),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(lead.displayName, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    StatusChip(lead.status),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (lead.hasPhone) line(Icons.phone_outlined, lead.phone!, onTap: () => copy(lead.phone!)),
          if (lead.hasEmail) line(Icons.email_outlined, lead.email!, onTap: () => copy(lead.email!)),
          line(
            Icons.campaign_outlined,
            [sourceLabel(lead.source), if ((lead.sourceDetail ?? '').isNotEmpty) lead.sourceDetail!].join(' · '),
          ),
          line(Icons.schedule, 'Came in ${DateFormat('d MMM yyyy, h:mm a').format(lead.createdAt)}'),
          if (lead.lastContactedAt != null)
            line(Icons.history, 'Last contacted ${timeAgo(lead.lastContactedAt!)}'),
          const Divider(height: 20),
          Row(
            children: [
              Icon(Icons.person_outline, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Text('Handled by ', style: muted),
              Expanded(
                child: Text(
                  AppState.instance.memberName(lead.assignedTo),
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: lead.assignedTo == null ? Colors.orange.shade800 : null,
                  ),
                ),
              ),
              if (admin) TextButton(onPressed: _assign, child: const Text('Change')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statusCard(Lead lead) {
    final scheme = Theme.of(context).colorScheme;
    final askReason = AppState.instance.status(lead.status)?.askReason ?? false;
    return _card(
      title: 'Status',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final s in AppState.instance.statuses)
                ChoiceChip(
                  label: Text(s.name),
                  selected: lead.status == s.name,
                  selectedColor: s.color.withValues(alpha: 0.25),
                  side: BorderSide(color: s.color.withValues(alpha: 0.5)),
                  onSelected: (_) => _setStatus(s.name),
                ),
            ],
          ),
          if (askReason && (lead.lostReason ?? '').isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Reason: ${lead.lostReason}', style: TextStyle(color: scheme.onSurfaceVariant)),
          ],
          const Divider(height: 24),
          TemperatureChips(value: lead.temperature, onChanged: _setTemperature),
        ],
      ),
    );
  }

  Widget _followUpCard() {
    return _card(
      title: 'Follow-up reminders',
      trailing: TextButton.icon(onPressed: _addReminder, icon: const Icon(Icons.alarm_add, size: 18), label: const Text('Add')),
      child: _reminders.isEmpty
          ? Text('No reminder set', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))
          : Column(
              children: [
                for (final r in _reminders)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.alarm, color: followUpColor(context, r.remindAt)),
                    title: Text(
                      friendlyTime(r.remindAt),
                      style: TextStyle(color: followUpColor(context, r.remindAt), fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text([
                      if ((r.note ?? '').isNotEmpty) r.note!,
                      if (AppState.instance.isAdmin) 'For ${AppState.instance.memberName(r.userId)}',
                    ].join('\n')),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Done',
                          icon: const Icon(Icons.check_circle_outline),
                          onPressed: () => _run(() => LeadOps.completeReminder(r), done: 'Marked done'),
                        ),
                        IconButton(
                          tooltip: 'Delete',
                          icon: const Icon(Icons.close),
                          onPressed: () => _run(() => LeadOps.deleteReminder(r)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _remarkCard() {
    return _card(
      title: 'Add remark',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          TextField(
            controller: _remark,
            minLines: 2,
            maxLines: 5,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'e.g. Will buy the course after 2 days'),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: _savingRemark ? null : _saveRemark,
            icon: const Icon(Icons.save_outlined, size: 18),
            label: const Text('Save remark'),
          ),
        ],
      ),
    );
  }

  Widget _extraCard(Lead lead) {
    final scheme = Theme.of(context).colorScheme;
    return _card(
      title: 'Form details',
      child: Column(
        children: [
          for (final e in lead.extra.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 120,
                    child: Text(e.key.replaceAll('_', ' '), style: TextStyle(color: scheme.onSurfaceVariant)),
                  ),
                  Expanded(child: SelectableText('${e.value}')),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _historyCard() {
    return _card(
      title: 'History',
      child: _activities.isEmpty
          ? const Text('Nothing yet')
          : Column(children: [for (final a in _activities) _ActivityTile(a)]),
    );
  }
}

class _ActivityTile extends StatelessWidget {
  final Activity a;

  const _ActivityTile(this.a);

  (IconData, Color, String) _callLine(Activity a) {
    final direction = a.meta['direction'] as String?;
    final seconds = (a.meta['duration'] as num?)?.toInt() ?? 0;
    return switch (direction) {
      'in' => (Icons.call_received, Colors.green.shade700,
          seconds > 0 ? 'Incoming call · ${formatDuration(seconds)}' : 'Incoming call'),
      'missed' || 'rejected' => (Icons.phone_missed, Colors.red.shade700, 'Missed call from lead'),
      'out' => seconds > 0
          ? (Icons.call_made, Colors.green.shade700, 'Called · ${formatDuration(seconds)}')
          : (Icons.phone_disabled_outlined, Colors.orange.shade800, 'Called · not answered'),
      _ => (Icons.call, Colors.green.shade700, 'Called'),
    };
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final scheme = Theme.of(context).colorScheme;
    final who = a.userId == null ? 'System' : app.memberName(a.userId);

    final (IconData icon, Color color, String text) = switch (a.type) {
      'created' => (Icons.fiber_new_outlined, scheme.primary, 'Lead added from ${sourceLabel('${a.meta['source'] ?? ''}')}'),
      'remark' => (Icons.notes, scheme.primary, '${a.body ?? ''}${a.meta['via'] == 'claude' ? '  (via Claude)' : a.meta['via'] == 'api' ? '  (AI assistant)' : ''}'),
      'status' => (Icons.flag_outlined, app.statusColor('${a.meta['to']}'), 'Status changed to ${a.meta['to']} (was ${a.meta['from']})'),
      'call' => _callLine(a),
      'temperature' => (
          Icons.local_fire_department_outlined,
          a.meta['to'] == null ? scheme.outline : temperatureColor('${a.meta['to']}'),
          a.meta['to'] == null ? 'Hot/Warm/Cold tag removed' : 'Marked ${temperatureLabel('${a.meta['to']}')}',
        ),
      'lost_reason' => (Icons.help_outline, Colors.red.shade700, 'Reason: ${a.body ?? ''}'),
      'whatsapp' => (Icons.chat, whatsappGreen, 'Opened WhatsApp'),
      'wa' => (Icons.chat_bubble, whatsappGreen, a.body ?? 'WhatsApp'),
      'webinar' => (Icons.cast_for_education_outlined, Colors.indigo.shade600, a.body ?? 'Webinar'),
      'appx' => (Icons.phone_android, Colors.teal.shade700, a.body ?? 'AIFM Education app'),
      'sms' => (Icons.sms_outlined, Colors.blue.shade700, 'Opened SMS'),
      'email' => (Icons.email_outlined, Colors.deepOrange, 'Opened email'),
      'assigned' => (
          Icons.person_add_alt,
          scheme.secondary,
          a.meta['to'] == null ? 'Unassigned' : 'Assigned to ${app.memberName(a.meta['to'] as String?)}',
        ),
      'reminder' => (
          Icons.alarm_add,
          Colors.orange.shade800,
          'Reminder for ${a.meta['remind_at'] == null ? '' : friendlyTime(DateTime.parse('${a.meta['remind_at']}').toLocal())}'
              '${(a.body ?? '').isEmpty ? '' : ' — ${a.body}'}',
        ),
      'duplicate' => (
          Icons.repeat,
          Colors.purple,
          'Enquired again via ${sourceLabel('${a.meta['source'] ?? ''}')}',
        ),
      _ => (Icons.circle_outlined, scheme.outline, a.body ?? a.type),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(radius: 14, backgroundColor: color.withValues(alpha: 0.12), child: Icon(icon, size: 16, color: color)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text),
                const SizedBox(height: 2),
                Text(
                  '$who · ${DateFormat('d MMM, h:mm a').format(a.createdAt)}',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
