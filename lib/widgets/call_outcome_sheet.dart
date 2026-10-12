import 'package:flutter/material.dart';

import '../models.dart';
import '../services/app_state.dart';
import '../services/call_log_sync.dart';
import '../services/lead_ops.dart';
import '../services/repo.dart';
import 'reason_picker.dart';
import 'reminder_picker.dart';

/// Shown when the user comes back to the app after calling a lead:
/// how long the call lasted, status (+ reason), hot/warm/cold, remark and next follow-up.
/// Returns true if something was saved.
Future<bool?> showCallOutcomeSheet(BuildContext context, Lead lead, {PhoneCall? phoneCall}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _CallOutcomeSheet(lead: lead, phoneCall: phoneCall),
  );
}

class _CallOutcomeSheet extends StatefulWidget {
  final Lead lead;
  final PhoneCall? phoneCall;

  const _CallOutcomeSheet({required this.lead, this.phoneCall});

  @override
  State<_CallOutcomeSheet> createState() => _CallOutcomeSheetState();
}

class _CallOutcomeSheetState extends State<_CallOutcomeSheet> {
  late String _status = _initialStatus();
  late String? _temperature = widget.lead.temperature;
  String? _reason;
  DateTime? _remindAt;
  final _remark = TextEditingController();
  bool _saving = false;

  /// Not answered + still "New" → suggest "No Answer" (the server does the same).
  String _initialStatus() {
    final call = widget.phoneCall;
    if (call != null && !call.answered && widget.lead.status == 'New' && AppState.instance.status('No Answer') != null) {
      return 'No Answer';
    }
    return widget.lead.status;
  }

  bool get _needsReason => AppState.instance.status(_status)?.askReason ?? false;

  @override
  void dispose() {
    _remark.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_needsReason && _status != widget.lead.status && _reason == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Choose why: $_status')));
      return;
    }
    setState(() => _saving = true);
    try {
      await LeadOps.setStatus(widget.lead, _status, reason: _needsReason ? _reason : null);
      await LeadOps.setTemperature(widget.lead, _temperature);
      await LeadOps.addRemark(widget.lead, _remark.text);
      if (_remindAt != null) {
        await LeadOps.addReminder(widget.lead, _remindAt!, _remark.text.trim());
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(e))));
    }
  }

  Widget _callBanner() {
    final call = widget.phoneCall;
    if (call == null) return const SizedBox.shrink();
    final answered = call.answered;
    final color = answered ? Colors.green.shade700 : Colors.orange.shade800;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(answered ? Icons.call : Icons.phone_missed, color: color, size: 20),
          const SizedBox(width: 8),
          Text(
            answered ? 'Talked for ${formatDuration(call.durationSeconds)}' : 'Not answered',
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final statuses = AppState.instance.statuses;
    const label = TextStyle(fontWeight: FontWeight.w600);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('How did the call go?', style: Theme.of(context).textTheme.titleLarge),
          Text(widget.lead.displayName, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          _callBanner(),
          const SizedBox(height: 14),
          const Text('Status', style: label),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final s in statuses)
                ChoiceChip(
                  label: Text(s.name),
                  selected: _status == s.name,
                  selectedColor: s.color.withValues(alpha: 0.25),
                  onSelected: (_) => setState(() => _status = s.name),
                ),
            ],
          ),
          if (_needsReason && _status != widget.lead.status) ...[
            const SizedBox(height: 12),
            Text('Why $_status?', style: label),
            const SizedBox(height: 6),
            ReasonChips(value: _reason, onChanged: (v) => setState(() => _reason = v)),
          ],
          const SizedBox(height: 14),
          const Text('Lead is', style: label),
          const SizedBox(height: 6),
          TemperatureChips(value: _temperature, onChanged: (v) => setState(() => _temperature = v)),
          const SizedBox(height: 14),
          TextField(
            controller: _remark,
            decoration: const InputDecoration(
              labelText: 'Remark',
              hintText: 'What did they say?',
              border: OutlineInputBorder(),
            ),
            maxLines: 3,
            minLines: 2,
          ),
          const SizedBox(height: 14),
          const Text('Next follow-up', style: label),
          const SizedBox(height: 6),
          ReminderTimeChips(value: _remindAt, allowNone: true, onChanged: (v) => setState(() => _remindAt = v)),
          const SizedBox(height: 16),
          Row(
            children: [
              TextButton(onPressed: _saving ? null : () => Navigator.pop(context, false), child: const Text('Skip')),
              const Spacer(),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check),
                label: const Text('Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
