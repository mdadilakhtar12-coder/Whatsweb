import 'package:flutter/material.dart';

import '../models.dart';
import '../services/app_state.dart';
import '../services/repo.dart';

/// Admin: team members, how many leads each has, add / edit / deactivate.
class TeamScreen extends StatefulWidget {
  const TeamScreen({super.key});

  @override
  State<TeamScreen> createState() => _TeamScreenState();
}

class _TeamScreenState extends State<TeamScreen> {
  Map<String?, Map<String, int>> _counts = {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([AppState.instance.reloadTeam(), Repo.leadCounts()]);
      if (!mounted) return;
      setState(() {
        _counts = results[1] as Map<String?, Map<String, int>>;
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

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _action(Map<String, dynamic> body, String done) async {
    try {
      await Repo.teamAction(body);
      _toast(done);
    } catch (e) {
      _toast(errorText(e));
    }
    await _load();
  }

  Future<void> _addMember() async {
    final result = await showDialog<Map<String, dynamic>>(context: context, builder: (_) => const _MemberDialog());
    if (result == null) return;
    await _action({'action': 'create', ...result}, 'Member added. Share the login ID and password with them.');
  }

  Future<void> _rename(Profile p) async {
    final name = await _askText('Name', p.fullName);
    if (name == null || name.isEmpty) return;
    await _action({'action': 'update', 'user_id': p.id, 'full_name': name}, 'Name updated');
  }

  Future<void> _setTargets(Profile p) async {
    final calls = TextEditingController(text: p.dailyCallTarget?.toString() ?? '');
    final admissions = TextEditingController(text: p.monthlyAdmissionTarget?.toString() ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Targets for ${p.displayName}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: calls,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Calls per day', hintText: 'e.g. 50'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: admissions,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Admissions per month', hintText: 'e.g. 10'),
            ),
            const SizedBox(height: 8),
            const Text('Leave empty for no target.', style: TextStyle(fontSize: 12.5)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Repo.updateProfile(p.id, {
        'daily_call_target': int.tryParse(calls.text.trim()),
        'monthly_admission_target': int.tryParse(admissions.text.trim()),
      });
      _toast('Targets saved');
    } catch (e) {
      _toast(errorText(e));
    }
    await _load();
  }

  Future<void> _resetPassword(Profile p) async {
    final pw = await _askText('New password for ${p.displayName}', '', password: true);
    if (pw == null || pw.isEmpty) return;
    await _action({'action': 'update', 'user_id': p.id, 'password': pw}, 'Password changed');
  }

  Future<String?> _askText(String title, String initial, {bool password = false}) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(helperText: password ? 'At least 6 characters' : null),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, ctrl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
  }

  Future<void> _setActive(Profile p, bool active) async {
    if (!active) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text('Deactivate ${p.displayName}?'),
          content: const Text(
            'They will be logged out and cannot see any lead. Their leads stay in the CRM — '
            'assign them to someone else from the Leads screen (filter by their name, select all, Assign).',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Deactivate')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _action(
      {'action': 'update', 'user_id': p.id, 'is_active': active},
      active ? '${p.displayName} can log in again' : '${p.displayName} deactivated',
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final unassigned = (_counts[null] ?? {}).values.fold(0, (a, b) => a + b);

    return Scaffold(
      appBar: AppBar(title: const Text('Team')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addMember,
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Add member'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                children: [
                  if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
                  if (unassigned > 0)
                    Card(
                      color: Colors.orange.shade50,
                      child: ListTile(
                        leading: Icon(Icons.inbox_outlined, color: Colors.orange.shade800),
                        title: Text('$unassigned unassigned lead${unassigned == 1 ? '' : 's'}'),
                        subtitle: const Text('Leads tab: filter "Unassigned", long-press to select, then Assign'),
                      ),
                    ),
                  for (final p in app.team) _memberCard(p),
                ],
              ),
            ),
    );
  }

  Widget _memberCard(Profile p) {
    final scheme = Theme.of(context).colorScheme;
    final counts = _counts[p.id] ?? {};
    final total = counts.values.fold(0, (a, b) => a + b);
    final isMe = p.id == currentUserId;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: CircleAvatar(
                backgroundColor: p.isActive ? scheme.primaryContainer : Colors.grey.shade300,
                child: Text(p.displayName.substring(0, 1).toUpperCase()),
              ),
              title: Text(
                '${p.displayName}${isMe ? ' (you)' : ''}',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  decoration: p.isActive ? null : TextDecoration.lineThrough,
                ),
              ),
              subtitle: Text('${p.isAdmin ? 'Admin' : 'Agent'} · ${p.email ?? ''}${p.isActive ? '' : ' · deactivated'}'),
              trailing: PopupMenuButton<String>(
                onSelected: (v) => switch (v) {
                  'targets' => _setTargets(p),
                  'rename' => _rename(p),
                  'password' => _resetPassword(p),
                  'role' => _action(
                      {'action': 'update', 'user_id': p.id, 'role': p.isAdmin ? 'agent' : 'admin'},
                      'Role changed',
                    ),
                  'active' => _setActive(p, !p.isActive),
                  _ => null,
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'targets', child: Text('Set targets')),
                  const PopupMenuItem(value: 'rename', child: Text('Change name')),
                  const PopupMenuItem(value: 'password', child: Text('Reset password')),
                  if (!isMe) PopupMenuItem(value: 'role', child: Text(p.isAdmin ? 'Make agent' : 'Make admin')),
                  if (!isMe) PopupMenuItem(value: 'active', child: Text(p.isActive ? 'Deactivate' : 'Activate again')),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _pill('Total', total, scheme.primary),
                  if (p.dailyCallTarget != null) _pill('Target ${p.dailyCallTarget} calls/day', 0, scheme.secondary, showCount: false),
                  for (final s in AppState.instance.statuses)
                    if ((counts[s.name] ?? 0) > 0) _pill(s.name, counts[s.name]!, s.color),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pill(String label, int n, Color color, {bool showCount = true}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
        child: Text(showCount ? '$label: $n' : label, style: TextStyle(fontSize: 12.5, color: color, fontWeight: FontWeight.w600)),
      );
}

class _MemberDialog extends StatefulWidget {
  const _MemberDialog();

  @override
  State<_MemberDialog> createState() => _MemberDialogState();
}

class _MemberDialogState extends State<_MemberDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  String _role = 'agent';

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add team member'),
      content: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Name'),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Enter a name' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Login ID',
                  helperText: 'Email style, e.g. ravi@mycrm.in\n(no email is sent)',
                  helperMaxLines: 2,
                ),
                validator: (v) =>
                    RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch((v ?? '').trim()) ? null : 'Like ravi@mycrm.in',
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _password,
                decoration: const InputDecoration(labelText: 'Password', helperText: 'At least 6 characters'),
                validator: (v) => (v ?? '').length < 6 ? 'Too short' : null,
              ),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'agent', label: Text('Agent')),
                  ButtonSegment(value: 'admin', label: Text('Admin')),
                ],
                selected: {_role},
                onSelectionChanged: (s) => setState(() => _role = s.first),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (!_form.currentState!.validate()) return;
            Navigator.pop(context, {
              'full_name': _name.text.trim(),
              'email': _email.text.trim(),
              'password': _password.text,
              'role': _role,
            });
          },
          child: const Text('Add'),
        ),
      ],
    );
  }
}
