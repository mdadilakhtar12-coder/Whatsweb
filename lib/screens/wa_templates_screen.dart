import 'package:flutter/material.dart';

import '../models.dart';
import '../services/repo.dart';
import '../widgets/wa_widgets.dart';
import 'wa_template_editor.dart';

/// Admin: WhatsApp message templates. Meta must approve each one before it can be sent.
class WaTemplatesScreen extends StatefulWidget {
  const WaTemplatesScreen({super.key});

  @override
  State<WaTemplatesScreen> createState() => _WaTemplatesScreenState();
}

class _WaTemplatesScreenState extends State<WaTemplatesScreen> {
  List<WaTemplate>? _list;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _load() async {
    try {
      final list = await Repo.waTemplates();
      if (mounted) setState(() => _list = list);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  /// Asks Meta for the latest approval status of every template.
  Future<void> _sync() async {
    setState(() => _busy = true);
    try {
      final r = await Repo.wa('sync_templates');
      await _load();
      _toast('${r['count']} templates checked with Meta');
    } catch (e) {
      _toast(errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit([WaTemplate? t]) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => WaTemplateEditor(existing: t)),
    );
    if (changed == true) _load();
  }

  Future<void> _submit(WaTemplate t) async {
    setState(() => _busy = true);
    try {
      await Repo.wa('submit_template', {'template_id': t.id});
      _toast('Sent to Meta. You will get a notification when it is approved.');
      await _load();
    } catch (e) {
      _toast(errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(WaTemplate t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete "${t.name}"?'),
        content: Text(t.status == 'DRAFT' ? 'This draft will be deleted.' : 'It is also deleted at Meta. Messages already sent stay in the chats.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final r = await Repo.wa('delete_template', {'template_id': t.id});
      if (r['warning'] != null) _toast('${r['warning']}');
      await _load();
    } catch (e) {
      _toast(errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final list = _list;
    return Scaffold(
      appBar: AppBar(
        title: const Text('WhatsApp templates'),
        actions: [
          IconButton(
            tooltip: 'Check approval status',
            icon: _busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
            onPressed: _busy ? null : _sync,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('New template'),
      ),
      body: list == null
          ? Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!))
          : RefreshIndicator(
              onRefresh: _sync,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                    child: Text(
                      'The first message to a student must be an approved template. '
                      'Meta usually approves within a few minutes to a few hours.',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                  if (list.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text('No templates yet. Tap "New template".', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
                    ),
                  for (final t in list) _card(t, scheme),
                ],
              ),
            ),
    );
  }

  Widget _card(WaTemplate t, ColorScheme scheme) {
    final buttons = t.buttons.map((b) => (b['text'] ?? (b['type'] == 'copy_code' ? 'Copy code' : '')).toString()).where((s) => s.isNotEmpty);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _edit(t),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(t.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5))),
                  WaStatusChip(t.status),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                '${t.language} · ${t.category == 'MARKETING' ? 'Marketing' : 'Utility'}'
                '${t.header['type'] != null && t.header['type'] != 'none' ? ' · ${t.header['type']} heading' : ''}',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
              ),
              const SizedBox(height: 8),
              Text(waFillSample(t.body), maxLines: 3, overflow: TextOverflow.ellipsis),
              if (buttons.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 4, children: [for (final b in buttons) Chip(label: Text(b), visualDensity: VisualDensity.compact)]),
              ],
              if (t.reason != null && (t.status == 'REJECTED' || t.status == 'PAUSED' || t.status == 'DISABLED')) ...[
                const SizedBox(height: 6),
                Text('Meta says: ${t.reason}', style: TextStyle(color: Colors.red.shade700, fontSize: 12.5)),
              ],
              const SizedBox(height: 4),
              Row(
                children: [
                  if (t.status == 'DRAFT' || t.status == 'REJECTED')
                    TextButton.icon(
                      onPressed: _busy ? null : () => _submit(t),
                      icon: const Icon(Icons.send, size: 18),
                      label: Text(t.status == 'DRAFT' ? 'Send to Meta' : 'Send again'),
                    ),
                  const Spacer(),
                  IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: _busy ? null : () => _delete(t)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
