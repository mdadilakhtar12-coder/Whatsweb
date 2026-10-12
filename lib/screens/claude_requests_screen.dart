import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import '../services/claude_state.dart';
import '../services/mcp_actions.dart';
import '../services/repo.dart';

IconData mcpKindIcon(String kind) => switch (kind) {
      'add_leads' => Icons.person_add_alt_1_outlined,
      'edit_lead' => Icons.edit_outlined,
      'set_status' => Icons.flag_outlined,
      'add_remark' => Icons.notes,
      'set_reminder' => Icons.alarm_add,
      'assign' => Icons.swap_horiz,
      'wa_text' => Icons.chat_bubble_outline,
      'wa_template' => Icons.campaign_outlined,
      'wa_flow' => Icons.account_tree_outlined,
      'wa_rule' => Icons.schedule_send_outlined,
      _ => Icons.help_outline,
    };

/// Can this not be taken back? (WhatsApp messages cannot.)
bool mcpIrreversible(String kind) => kind == 'wa_text' || kind == 'wa_template';

String mcpStateLabel(String state) => switch (state) {
      'pending' => 'Waiting for you',
      'running' => 'Running',
      'done' => 'Done',
      'failed' => 'Did not work',
      'rejected' => 'Rejected',
      'expired' => 'Expired',
      'interrupted' => 'Stopped half way',
      _ => state,
    };

Color mcpStateColor(String state, ColorScheme scheme) => switch (state) {
      'done' => Colors.green.shade700,
      'failed' || 'interrupted' => scheme.error,
      'pending' || 'running' => Colors.orange.shade800,
      _ => scheme.outline,
    };

/// Admin: what Claude asked for. Tap one to read exactly what it will do, then Approve or Reject.
class ClaudeRequestsScreen extends StatefulWidget {
  const ClaudeRequestsScreen({super.key});

  @override
  State<ClaudeRequestsScreen> createState() => _ClaudeRequestsScreenState();
}

class _ClaudeRequestsScreenState extends State<ClaudeRequestsScreen> {
  List<McpAction> _items = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _load() async {
    try {
      final items = await Repo.mcpActions();
      if (!mounted) return;
      claudePending.value = items.where((a) => a.waiting).length;
      setState(() {
        _items = items;
        _loading = false;
        _error = null;
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

  Future<void> _open(McpAction a) async {
    final scheme = Theme.of(context).colorScheme;
    final choice = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Row(children: [Icon(mcpKindIcon(a.kind)), const SizedBox(width: 10), const Expanded(child: Text('Claude asks'))]),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(a.title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              if (a.lines.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: scheme.surfaceContainerHighest.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(8)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [for (final l in a.lines) Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text(l, style: const TextStyle(fontSize: 13.5)))],
                  ),
                ),
              if (a.highlight != null) ...[
                const SizedBox(height: 10),
                Text(a.highlight!, style: TextStyle(fontWeight: FontWeight.w700, color: Colors.orange.shade900)),
              ],
              if (mcpIrreversible(a.kind)) ...[
                const SizedBox(height: 8),
                Text('A WhatsApp message cannot be taken back.', style: TextStyle(color: scheme.error, fontSize: 12.5)),
              ],
              if ((a.reason ?? '').isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('Claude says (not checked):', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                Text('"${a.reason}"', style: const TextStyle(fontStyle: FontStyle.italic, fontSize: 13)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Later')),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            child: const Text('Reject'),
          ),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(mcpIrreversible(a.kind) ? 'Approve & send' : 'Approve')),
        ],
      ),
    );
    if (choice == null) return;
    if (choice) {
      await _approve(a);
    } else {
      await _reject(a);
    }
  }

  Future<void> _reject(McpAction a) async {
    setState(() => _busy = true);
    try {
      await Repo.mcpReject(a.id);
      _toast('Rejected');
    } catch (e) {
      _toast(errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  Future<void> _approve(McpAction a) async {
    setState(() => _busy = true);
    McpAction taken;
    try {
      // takes it for good (a second tap or another phone cannot do it twice)
      final claimed = await Repo.mcpClaim(a.id);
      taken = McpAction(
        id: a.id,
        kind: claimed['kind'] as String,
        title: a.title,
        args: (claimed['args'] as Map).cast<String, dynamic>(),
        preview: a.preview,
        reason: a.reason,
        status: 'running',
        result: null,
        createdAt: a.createdAt,
        expiresAt: a.expiresAt,
        decidedAt: DateTime.now(),
      );
    } catch (e) {
      _toast(errorText(e));
      if (mounted) setState(() => _busy = false);
      await _load();
      return;
    }
    try {
      final done = await runMcpAction(taken);
      await Repo.mcpFinish(a.id, true, done);
      _toast(done);
    } catch (e) {
      final msg = errorText(e);
      try {
        await Repo.mcpFinish(a.id, false, msg);
      } catch (_) {
        // the list shows it as stopped half way
      }
      _toast('Did not work: $msg');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final waiting = _items.where((a) => a.waiting).toList();
    final earlier = _items.where((a) => !a.waiting).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Claude\'s requests'), actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)]),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Padding(padding: const EdgeInsets.all(24), child: Text(_error!))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
                    children: [
                      if (_busy) const LinearProgressIndicator(),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
                        child: Text('Waiting for you', style: Theme.of(context).textTheme.titleMedium),
                      ),
                      if (waiting.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text('Nothing is waiting. When you ask Claude to change something, it shows up here.', style: TextStyle(color: scheme.onSurfaceVariant)),
                        ),
                      for (final a in waiting) _card(a, scheme),
                      if (earlier.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
                          child: Text('Earlier', style: Theme.of(context).textTheme.titleMedium),
                        ),
                        for (final a in earlier) _card(a, scheme),
                      ],
                    ],
                  ),
                ),
    );
  }

  Widget _card(McpAction a, ColorScheme scheme) {
    final state = a.state;
    final color = mcpStateColor(state, scheme);
    final left = a.expiresAt.difference(DateTime.now());
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: CircleAvatar(backgroundColor: color.withValues(alpha: 0.12), child: Icon(mcpKindIcon(a.kind), color: color, size: 20)),
        title: Text(a.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          [
            mcpStateLabel(state),
            DateFormat('d MMM, h:mm a').format(a.createdAt.toLocal()),
            if (a.waiting) 'expires in ${left.inHours >= 1 ? '${left.inHours}h' : '${left.inMinutes.clamp(0, 59)}m'}',
            if ((a.result ?? '').isNotEmpty && state != 'pending') a.result!,
          ].join(' · '),
          style: TextStyle(color: a.waiting ? null : scheme.onSurfaceVariant),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: a.waiting ? const Icon(Icons.chevron_right) : null,
        onTap: a.waiting && !_busy ? () => _open(a) : null,
      ),
    );
  }
}
