import 'package:flutter/material.dart';

import '../models.dart';
import '../services/app_state.dart';
import '../services/repo.dart';

const _palette = [
  Color(0xFF1E88E5), Color(0xFF43A047), Color(0xFFFB8C00), Color(0xFF8E24AA),
  Color(0xFFE53935), Color(0xFF00897B), Color(0xFF6D4C41), Color(0xFF546E7A),
  Color(0xFFD81B60), Color(0xFF3949AB), Color(0xFFFDD835), Color(0xFF00ACC1),
];

/// Admin: add, rename, recolour and reorder lead statuses.
class StatusesScreen extends StatefulWidget {
  const StatusesScreen({super.key});

  @override
  State<StatusesScreen> createState() => _StatusesScreenState();
}

class _StatusesScreenState extends State<StatusesScreen> {
  List<LeadStatus> get _items => AppState.instance.statuses;

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      final msg = errorText(e);
      _toast(msg.contains('foreign key') ? 'Some leads still have this status — change them first' : msg);
    }
    await AppState.instance.reloadStatuses();
    if (mounted) setState(() {});
  }

  Future<void> _edit([LeadStatus? s]) async {
    final result = await showDialog<({String name, Color color, bool closed, bool won, bool askReason})>(
      context: context,
      builder: (_) => _StatusDialog(existing: s),
    );
    if (result == null) return;
    final values = {
      'name': result.name,
      'color': colorToHex(result.color),
      'is_closed': result.closed,
      'is_won': result.won,
      'ask_reason': result.askReason,
    };
    await _run(() async {
      if (s == null) {
        final maxOrder = _items.fold(0, (m, x) => x.sortOrder > m ? x.sortOrder : m);
        await db.from('lead_statuses').insert({...values, 'sort_order': maxOrder + 1});
      } else {
        await db.from('lead_statuses').update(values).eq('id', s.id);
      }
    });
  }

  Future<void> _delete(LeadStatus s) async {
    if (s.name == 'New') return _toast('"New" is used for every fresh lead and cannot be deleted');
    await _run(() => db.from('lead_statuses').delete().eq('id', s.id));
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    final list = [..._items];
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    AppState.instance.statuses = list;
    setState(() {});
    await _run(() async {
      for (var i = 0; i < list.length; i++) {
        await db.from('lead_statuses').update({'sort_order': i + 1}).eq('id', list[i].id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Lead statuses')),
      floatingActionButton: FloatingActionButton(onPressed: () => _edit(), child: const Icon(Icons.add)),
      body: ReorderableListView(
        padding: const EdgeInsets.only(bottom: 96),
        onReorderItem: _reorder,
        header: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Drag to change the order. Tap to rename or change colour.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
        children: [
          for (final s in _items)
            ListTile(
              key: ValueKey(s.id),
              leading: CircleAvatar(radius: 10, backgroundColor: s.color),
              title: Text(s.name),
              subtitle: s.isClosed || s.isWon || s.askReason
                  ? Text([
                      if (s.isWon) 'Admission',
                      if (s.isClosed) 'Closed',
                      if (s.askReason) 'Asks reason',
                    ].join(' · '))
                  : null,
              onTap: () => _edit(s),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _delete(s)),
                  const Icon(Icons.drag_handle),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _StatusDialog extends StatefulWidget {
  final LeadStatus? existing;

  const _StatusDialog({this.existing});

  @override
  State<_StatusDialog> createState() => _StatusDialogState();
}

class _StatusDialogState extends State<_StatusDialog> {
  late final _name = TextEditingController(text: widget.existing?.name);
  late Color _color = widget.existing?.color ?? _palette.first;
  late bool _closed = widget.existing?.isClosed ?? false;
  late bool _won = widget.existing?.isWon ?? false;
  late bool _askReason = widget.existing?.askReason ?? false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'New status' : 'Edit status'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in _palette)
                GestureDetector(
                  onTap: () => setState(() => _color = c),
                  child: CircleAvatar(
                    radius: 16,
                    backgroundColor: c,
                    child: c.toARGB32() == _color.toARGB32() ? const Icon(Icons.check, color: Colors.white, size: 18) : null,
                  ),
                ),
            ],
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _closed,
            onChanged: (v) => setState(() => _closed = v ?? false),
            title: const Text('Closed status'),
            subtitle: const Text('e.g. Admission Done, Not Interested'),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _won,
            onChanged: (v) => setState(() => _won = v ?? false),
            title: const Text('Counts as admission'),
            subtitle: const Text('Shown as admissions on the dashboard'),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _askReason,
            onChanged: (v) => setState(() => _askReason = v ?? false),
            title: const Text('Ask for a reason'),
            subtitle: const Text('e.g. Not Interested → "Fees too high"'),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final name = _name.text.trim();
            if (name.isEmpty) return;
            Navigator.pop(context, (name: name, color: _color, closed: _closed, won: _won, askReason: _askReason));
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
