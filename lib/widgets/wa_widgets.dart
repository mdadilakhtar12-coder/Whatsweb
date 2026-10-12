import 'package:flutter/material.dart';

import '../models.dart';
import '../services/app_state.dart';
import 'contact_buttons.dart' show whatsappGreen;

const _blueTick = Color(0xFF34B7F1);

/// Sample values used in previews (the real ones come from each lead).
const waSamples = {
  'first_name': 'Rahul',
  'name': 'Rahul Sharma',
  'phone': '9876543210',
  'email': 'rahul@example.com',
  'agent_name': 'Priya',
};

/// "Hi {first_name}" -> "Hi Rahul". [examples] (e.g. {'ask.semester': 'Semester 3'}) win over the built-in samples.
String waFillSample(String text, {Map<String, String> examples = const {}}) => text.replaceAllMapped(
      RegExp(r'\{\{?\s*([a-z_][a-z0-9_.]*)\s*\}?\}', caseSensitive: false),
      (m) {
        final key = m.group(1)!.toLowerCase();
        final ex = examples[key];
        if (ex != null && ex.trim().isNotEmpty) return ex.trim();
        return waSamples[key] ?? (key.startsWith('ask.') ? '…' : 'Sample');
      },
    );

String _nice(String name) {
  final words = name.replaceAll('_', ' ').trim();
  return words.isEmpty ? name : words[0].toUpperCase() + words.substring(1);
}

/// One box for each detail the sender types in when sending ({ask.semester} -> a "Semester" box).
/// Calls [onChanged] with the values typed so far (lower-case names).
class AskFields extends StatefulWidget {
  final WaTemplate template;
  final ValueChanged<Map<String, String>> onChanged;
  final bool autofocus;

  const AskFields({super.key, required this.template, required this.onChanged, this.autofocus = false});

  @override
  State<AskFields> createState() => _AskFieldsState();
}

class _AskFieldsState extends State<AskFields> {
  late final List<String> _names = widget.template.askNames;
  late final Map<String, TextEditingController> _ctrl = {for (final n in _names) n: TextEditingController()};

  @override
  void dispose() {
    for (final c in _ctrl.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _changed() {
    final out = <String, String>{};
    _ctrl.forEach((k, c) {
      final v = c.text.trim();
      if (v.isNotEmpty) out[k] = v;
    });
    widget.onChanged(out);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < _names.length; i++)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: TextField(
              controller: _ctrl[_names[i]],
              autofocus: widget.autofocus && i == 0,
              maxLength: 200,
              decoration: InputDecoration(
                labelText: _nice(_names[i]),
                hintText: widget.template.examples['ask.${_names[i]}'],
                counterText: '',
              ),
              onChanged: (_) => _changed(),
            ),
          ),
      ],
    );
  }
}

/// Asks for the details of a template with fill-when-sending variables. Returns the values, or null if cancelled.
Future<Map<String, String>?> showAskValuesDialog(BuildContext context, WaTemplate t, {String action = 'Send'}) {
  var values = <String, String>{};
  final names = t.askNames;
  return showDialog<Map<String, String>>(
    context: context,
    builder: (_) => StatefulBuilder(
      builder: (context, setState) {
        final ready = names.every((n) => (values[n] ?? '').isNotEmpty);
        final shown = {for (final n in names) 'ask.$n': values[n] ?? '[$n]'};
        return AlertDialog(
          title: Text(t.name),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Fill in the details for this message:'),
                AskFields(template: t, autofocus: true, onChanged: (v) => setState(() => values = v)),
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: const Color(0xFFE6DDD4), borderRadius: BorderRadius.circular(8)),
                  child: Text(waFillSample(t.body, examples: shown), style: const TextStyle(color: Colors.black87, fontSize: 13.5, height: 1.3)),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: ready ? () => Navigator.pop(context, values) : null, child: Text(action)),
          ],
        );
      },
    ),
  );
}

Color waStatusColor(String status) => switch (status) {
      'APPROVED' => Colors.green.shade700,
      'PENDING' => Colors.orange.shade800,
      'REJECTED' || 'DISABLED' => Colors.red.shade700,
      'PAUSED' => Colors.deepOrange.shade700,
      _ => Colors.blueGrey,
    };

String waStatusLabel(String status) => switch (status) {
      'APPROVED' => 'Approved',
      'PENDING' => 'Waiting for Meta',
      'REJECTED' => 'Rejected',
      'PAUSED' => 'Paused',
      'DISABLED' => 'Disabled',
      'DRAFT' => 'Draft',
      _ => status,
    };

class WaStatusChip extends StatelessWidget {
  final String status;

  const WaStatusChip(this.status, {super.key});

  @override
  Widget build(BuildContext context) {
    final color = waStatusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Text(waStatusLabel(status), style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
    );
  }
}

/// ✓ sent, ✓✓ delivered, blue ✓✓ read, ⚠ failed — on a message.
class WaTicks extends StatelessWidget {
  final String status;
  final double size;

  const WaTicks(this.status, {super.key, this.size = 16});

  @override
  Widget build(BuildContext context) {
    return switch (status) {
      'queued' => Icon(Icons.schedule, size: size, color: Colors.grey),
      'sent' => Icon(Icons.done, size: size, color: Colors.grey),
      'delivered' => Icon(Icons.done_all, size: size, color: Colors.grey),
      'read' => Icon(Icons.done_all, size: size, color: _blueTick),
      'failed' => Icon(Icons.error_outline, size: size, color: Colors.red.shade700),
      _ => const SizedBox.shrink(),
    };
  }
}

/// A small badge on a lead card: what happened to the last WhatsApp message.
class WaBadge extends StatelessWidget {
  final Lead lead;

  const WaBadge(this.lead, {super.key});

  @override
  Widget build(BuildContext context) {
    final s = lead.waState;
    if (s == 'none') return const SizedBox.shrink();
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final (Widget icon, String text, Color color) = switch (s) {
      'replied' => (const Icon(Icons.chat_bubble, size: 13, color: whatsappGreen), 'Replied', Colors.green.shade800),
      'read' => (const WaTicks('read', size: 15), 'Read', _blueTick),
      'delivered' => (const WaTicks('delivered', size: 15), 'Delivered', muted),
      'sent' || 'queued' => (const WaTicks('sent', size: 15), 'Sent', muted),
      'no_whatsapp' => (Icon(Icons.phone_disabled, size: 13, color: muted), 'Not on WhatsApp', muted),
      _ => (WaTicks('failed', size: 14), 'Not delivered', Colors.red.shade700),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        icon,
        const SizedBox(width: 3),
        Text(text, style: TextStyle(fontSize: 12.5, color: color, fontWeight: FontWeight.w600)),
        if (lead.waUnread > 0) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(color: whatsappGreen, borderRadius: BorderRadius.circular(10)),
            child: Text('${lead.waUnread}', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// What happens when the student presses a button
// ---------------------------------------------------------------------------

String waActionSummary(Map<String, dynamic>? a, List<WaNode> nodes) {
  if (a == null || a.isEmpty) return 'Nothing happens';
  final parts = <String>[
    if (a['status'] != null) 'Status: ${a['status']}',
    if (a['temperature'] != null) temperatureLabel('${a['temperature']}'),
    if (a['lost_reason'] != null) '${a['lost_reason']}',
    if (a['callback_hours'] != null) 'Call reminder in ${a['callback_hours']}h',
    if (a['next'] != null) 'Reply: ${nodes.where((n) => n.id == a['next']).map((n) => n.name).firstOrNull ?? '(deleted)'}',
    if (a['optout'] == true) 'Stop messages',
  ];
  return parts.isEmpty ? 'Nothing happens' : parts.join(' · ');
}

/// Bottom sheet to choose what a button does. Returns the new action ({} = nothing), or null if cancelled.
Future<Map<String, dynamic>?> showWaActionSheet(
  BuildContext context, {
  required String title,
  required Map<String, dynamic>? current,
  required List<WaNode> nodes,
}) {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ActionSheet(title: title, current: current ?? const {}, nodes: nodes),
  );
}

class _ActionSheet extends StatefulWidget {
  final String title;
  final Map<String, dynamic> current;
  final List<WaNode> nodes;

  const _ActionSheet({required this.title, required this.current, required this.nodes});

  @override
  State<_ActionSheet> createState() => _ActionSheetState();
}

class _ActionSheetState extends State<_ActionSheet> {
  late final Map<String, dynamic> _a = {...widget.current};

  void _put(String key, Object? value) => setState(() => value == null || value == false ? _a.remove(key) : _a[key] = value);

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final statusNames = app.statuses.map((s) => s.name).toList();
    final status = statusNames.contains(_a['status']) ? _a['status'] as String : null;
    final reasons = app.lostReasons;
    final nodeIds = widget.nodes.map((n) => n.id).toSet();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('When they press "${widget.title}"', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('Everything below happens by itself.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            DropdownButtonFormField<String?>(
              isExpanded: true,
              initialValue: status,
              decoration: const InputDecoration(labelText: 'Move the lead to status'),
              items: [
                const DropdownMenuItem(value: null, child: Text('Do not change')),
                for (final n in statusNames) DropdownMenuItem(value: n, child: Text(n)),
              ],
              onChanged: (v) => _put('status', v),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              isExpanded: true,
              initialValue: temperatures.contains(_a['temperature']) ? _a['temperature'] as String : null,
              decoration: const InputDecoration(labelText: 'Mark as'),
              items: [
                const DropdownMenuItem(value: null, child: Text('Do not change')),
                for (final t in temperatures) DropdownMenuItem(value: t, child: Text(temperatureLabel(t))),
              ],
              onChanged: (v) => _put('temperature', v),
            ),
            if (reasons.isNotEmpty) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                isExpanded: true,
                initialValue: reasons.contains(_a['lost_reason']) ? _a['lost_reason'] as String : null,
                decoration: const InputDecoration(labelText: 'Reason for not joining'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('None')),
                  for (final r in reasons) DropdownMenuItem(value: r, child: Text(r)),
                ],
                onChanged: (v) => _put('lost_reason', v),
              ),
            ],
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              isExpanded: true,
              initialValue: nodeIds.contains(_a['next']) ? _a['next'] as String : null,
              decoration: InputDecoration(
                labelText: 'Then send this reply',
                helperText: widget.nodes.isEmpty ? 'No replies made yet: first make one in More > WhatsApp > Automatic replies' : null,
                helperMaxLines: 2,
              ),
              items: [
                const DropdownMenuItem(value: null, child: Text('No reply')),
                for (final n in widget.nodes) DropdownMenuItem(value: n.id, child: Text(n.name)),
              ],
              onChanged: (v) => _put('next', v),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int?>(
              isExpanded: true,
              initialValue: const [1, 2, 4, 24].contains(_a['callback_hours']) ? (_a['callback_hours'] as num).toInt() : null,
              decoration: const InputDecoration(labelText: 'Remind the agent to call'),
              items: const [
                DropdownMenuItem(value: null, child: Text('No reminder')),
                DropdownMenuItem(value: 1, child: Text('In 1 hour')),
                DropdownMenuItem(value: 2, child: Text('In 2 hours')),
                DropdownMenuItem(value: 4, child: Text('In 4 hours')),
                DropdownMenuItem(value: 24, child: Text('Tomorrow')),
              ],
              onChanged: (v) => _put('callback_hours', v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Stop all WhatsApp messages to this student'),
              value: _a['optout'] == true,
              onChanged: (v) => _put('optout', v),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton(onPressed: () => Navigator.pop(context, <String, dynamic>{}), child: const Text('Do nothing')),
                const Spacer(),
                FilledButton(onPressed: () => Navigator.pop(context, _a), child: const Text('Save')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
