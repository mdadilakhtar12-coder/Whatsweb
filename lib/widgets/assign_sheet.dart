import 'package:flutter/material.dart';

import '../services/app_state.dart';
import '../services/repo.dart';

/// Admin: pick one or more team members for the selected leads.
/// With several members the leads are shared out one by one.
/// Returns the number of leads changed, or null if cancelled.
Future<int?> showAssignSheet(BuildContext context, List<String> leadIds) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _AssignSheet(leadIds: leadIds),
  );
}

class _AssignSheet extends StatefulWidget {
  final List<String> leadIds;

  const _AssignSheet({required this.leadIds});

  @override
  State<_AssignSheet> createState() => _AssignSheetState();
}

class _AssignSheetState extends State<_AssignSheet> {
  final _chosen = <String>[];
  bool _saving = false;

  Future<void> _assign(List<String> agentIds) async {
    setState(() => _saving = true);
    try {
      final n = await Repo.assignLeads(widget.leadIds, agentIds);
      if (mounted) Navigator.pop(context, n);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final team = AppState.instance.activeTeam;
    final count = widget.leadIds.length;
    final many = _chosen.length > 1;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text('Assign $count lead${count == 1 ? '' : 's'} to', style: Theme.of(context).textTheme.titleLarge),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Select one person, or several to share the leads equally.',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final p in team)
                    CheckboxListTile(
                      value: _chosen.contains(p.id),
                      title: Text(p.displayName),
                      subtitle: Text(p.isAdmin ? 'Admin' : 'Agent'),
                      secondary: CircleAvatar(child: Text(p.displayName.substring(0, 1).toUpperCase())),
                      onChanged: (v) => setState(() => v == true ? _chosen.add(p.id) : _chosen.remove(p.id)),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: _saving ? null : () => _assign([]),
                    icon: const Icon(Icons.person_off_outlined),
                    label: const Text('Unassign'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _saving || _chosen.isEmpty ? null : () => _assign(_chosen),
                    child: Text(many ? 'Share among ${_chosen.length}' : 'Assign'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
