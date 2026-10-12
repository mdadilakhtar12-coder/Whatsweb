import 'package:flutter/material.dart';

import '../services/app_state.dart';
import '../services/repo.dart';

/// Admin: should leads from Meta / Google / website go to someone automatically?
class AutoAssignScreen extends StatefulWidget {
  const AutoAssignScreen({super.key});

  @override
  State<AutoAssignScreen> createState() => _AutoAssignScreenState();
}

class _AutoAssignScreenState extends State<AutoAssignScreen> {
  bool _loading = true;
  bool _enabled = false;
  final Set<String> _agents = {};

  @override
  void initState() {
    super.initState();
    Repo.setting('auto_assign').then((v) {
      if (!mounted) return;
      setState(() {
        _enabled = (v?['enabled'] as bool?) ?? false;
        _agents.addAll(((v?['agent_ids'] as List?) ?? const []).cast<String>());
        _loading = false;
      });
    }).catchError((Object e) {
      if (mounted) setState(() => _loading = false);
    });
  }

  Future<void> _save() async {
    if (_enabled && _agents.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Select at least one person')));
      return;
    }
    try {
      await Repo.saveSetting('auto_assign', {'enabled': _enabled, 'agent_ids': _agents.toList()});
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final team = AppState.instance.activeTeam;
    return Scaffold(
      appBar: AppBar(title: const Text('Auto-assign')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                SwitchListTile(
                  value: _enabled,
                  onChanged: (v) => setState(() => _enabled = v),
                  title: const Text('Assign new leads automatically'),
                  subtitle: Text(
                    _enabled
                        ? 'New Meta / Google / website leads go to the people below, one by one.'
                        : 'OFF: new leads wait in "Unassigned" until you assign them.',
                  ),
                ),
                const Divider(),
                for (final p in team)
                  CheckboxListTile(
                    enabled: _enabled,
                    value: _agents.contains(p.id),
                    title: Text(p.displayName),
                    subtitle: Text(p.isAdmin ? 'Admin' : 'Agent'),
                    onChanged: (v) => setState(() => v == true ? _agents.add(p.id) : _agents.remove(p.id)),
                  ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton(
                    onPressed: _save,
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    child: const Text('Save'),
                  ),
                ),
              ],
            ),
    );
  }
}
