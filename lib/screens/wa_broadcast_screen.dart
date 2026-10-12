import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import '../services/app_state.dart';
import '../services/repo.dart';
import '../widgets/lead_filter_sheet.dart';
import '../widgets/wa_widgets.dart';

/// Admin: send one approved template to a chosen group of leads (for example everyone "Opened, no reply").
class WaBroadcastScreen extends StatefulWidget {
  const WaBroadcastScreen({super.key});

  @override
  State<WaBroadcastScreen> createState() => _WaBroadcastScreenState();
}

class _WaBroadcastScreenState extends State<WaBroadcastScreen> {
  List<WaTemplate> _templates = [];
  List<Map<String, dynamic>>? _past;
  String? _error;
  final _name = TextEditingController();
  String? _templateId;
  Map<String, String> _asked = {};
  int _askKey = 0;
  LeadFilter _filter = const LeadFilter();
  int? _count;
  bool _busy = false;
  int _filterKey = 0;

  @override
  void initState() {
    super.initState();
    _load();
    _recount();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _load() async {
    try {
      final results = await Future.wait<Object?>([Repo.waTemplates(), Repo.waBroadcasts()]);
      if (!mounted) return;
      setState(() {
        _templates = (results[0] as List<WaTemplate>).where((t) => t.approved).toList();
        _past = results[1] as List<Map<String, dynamic>>;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  Future<void> _recount() async {
    setState(() => _count = null);
    final f = _filter;
    try {
      final n = await Repo.waAudienceCount(f.toAudience());
      if (mounted && identical(f, _filter)) setState(() => _count = n);
    } catch (e) {
      if (mounted) _toast(errorText(e));
    }
  }

  WaTemplate? get _template => _templates.where((t) => t.id == _templateId).firstOrNull;

  double get _price {
    final wa = AppState.instance.wa;
    final t = _template;
    final v = (t?.category == 'UTILITY' ? wa['price_utility'] : wa['price_marketing']) as num?;
    return v?.toDouble() ?? (t?.category == 'UTILITY' ? 0.15 : 0.9);
  }

  Future<void> _send() async {
    final t = _template;
    final n = _count;
    if (t == null) return _toast('Choose a template');
    if (n == null || n == 0) return _toast('No leads match this group');
    final missing = t.askNames.where((a) => (_asked[a] ?? '').isEmpty).toList();
    if (missing.isNotEmpty) return _toast('Fill in: ${missing.join(', ')}');
    final cost = n * _price;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Send now?'),
        content: Text(
          'Template "${t.name}" will be sent to $n leads.\n\n'
          'Meta charges about ₹${cost.toStringAsFixed(0)} (₹${_price.toStringAsFixed(2)} per message). '
          'Students who asked to stop are left out.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text('Send to $n')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final res = await Repo.waCreateBroadcast(t.id, _name.text.trim().isEmpty ? '${t.name} · ${DateFormat('d MMM').format(DateTime.now())}' : _name.text.trim(), _filter.toAudience(), params: _asked);
      _toast('Sending to ${res['total']} leads…');
      _name.clear();
      await _load();
    } catch (e) {
      _toast(errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel(Map<String, dynamic> b) async {
    try {
      await Repo.waCancelBroadcast(b['id'] as String);
      await _load();
    } catch (e) {
      _toast(errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5);
    final past = _past;
    return Scaffold(
      appBar: AppBar(title: const Text('WhatsApp broadcast'), actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)]),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text('New broadcast', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name (optional)', hintText: 'October fees reminder')),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: _templateId,
            decoration: InputDecoration(
              labelText: 'Template',
              helperText: _templates.isEmpty ? 'No approved template yet: make one in WhatsApp templates' : null,
            ),
            items: [for (final t in _templates) DropdownMenuItem(value: t.id, child: Text('${t.name}  (${t.category == 'MARKETING' ? 'Marketing' : 'Utility'})'))],
            onChanged: (v) => setState(() {
              _templateId = v;
              _asked = {};
              _askKey++;
            }),
          ),
          if (_template != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: scheme.surfaceContainerHighest.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(8)),
              child: Text(
                waFillSample(_template!.body, examples: {..._template!.examples, for (final e in _asked.entries) 'ask.${e.key}': e.value}),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            if (_template!.askNames.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('Fill in the details (same for everyone in this broadcast):', style: muted),
              AskFields(key: ValueKey('ask$_askKey'), template: _template!, onChanged: (v) => setState(() => _asked = v)),
            ],
          ],
          const SizedBox(height: 16),
          Text('Who gets it', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Text('Pick the group. Leads without a phone number or who asked to stop are left out automatically.', style: muted),
          const SizedBox(height: 12),
          LeadFilterForm(
            key: ValueKey(_filterKey),
            initial: _filter,
            onChanged: (f) {
              _filter = f;
              _recount();
            },
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () {
                setState(() {
                  _filter = const LeadFilter();
                  _filterKey++;
                });
                _recount();
              },
              child: const Text('Reset group'),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: scheme.primaryContainer.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(12)),
            child: Row(
              children: [
                const Icon(Icons.groups_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child: _count == null
                      ? const Text('Counting…')
                      : Text(
                          '$_count leads${_template == null ? '' : '  ·  about ₹${(_count! * _price).toStringAsFixed(0)}'}',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _send,
            icon: const Icon(Icons.send),
            label: const Text('Send broadcast'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
          ),
          const SizedBox(height: 28),
          Text('Earlier broadcasts', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (past == null)
            Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!))
          else if (past.isEmpty)
            Text('None yet.', style: muted)
          else
            for (final b in past) _pastCard(b, scheme),
        ],
      ),
    );
  }

  Widget _pastCard(Map<String, dynamic> b, ColorScheme scheme) {
    int n(String k) => (b[k] as num?)?.toInt() ?? 0;
    final sent = n('sent');
    String pct(int part) => sent <= 0 ? '–' : '${(part * 100 / sent).round()}%';
    final at = DateTime.tryParse('${b['created_at']}')?.toLocal();
    final sending = b['status'] == 'sending';
    final progress = n('total') <= 0 ? 1.0 : (n('total') - n('pending')) / n('total');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('${b['name']}', style: const TextStyle(fontWeight: FontWeight.w700))),
                Text(
                  sending ? 'Sending…' : (b['status'] == 'cancelled' ? 'Cancelled' : 'Done'),
                  style: TextStyle(color: sending ? Colors.orange.shade800 : scheme.onSurfaceVariant, fontWeight: FontWeight.w600, fontSize: 12.5),
                ),
              ],
            ),
            Text(
              '${at == null ? '' : DateFormat('d MMM, h:mm a').format(at)} · template ${b['template_name'] ?? '(deleted)'} · ${n('total')} leads',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
            ),
            if (sending) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: progress.clamp(0, 1).toDouble()),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                _stat('Sent', '$sent'),
                _stat('Delivered', pct(n('delivered'))),
                _stat('Opened', pct(n('read'))),
                _stat('Replied', '${n('replied')}'),
                _stat('Failed', '${n('failed')}', warn: n('failed') > 0),
                if (n('pending') > 0) _stat('Waiting', '${n('pending')}'),
              ],
            ),
            if (sending) Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => _cancel(b), child: const Text('Stop sending the rest'))),
          ],
        ),
      ),
    );
  }

  Widget _stat(String label, String value, {bool warn = false}) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 11.5, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          Text(value, style: TextStyle(fontWeight: FontWeight.w700, color: warn ? Theme.of(context).colorScheme.error : null)),
        ],
      );
}
