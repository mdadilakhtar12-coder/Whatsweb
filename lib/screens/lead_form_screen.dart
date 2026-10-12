import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models.dart';
import '../services/app_state.dart';
import '../services/repo.dart';
import 'lead_detail_screen.dart';

/// Add a lead by hand, or edit name / phone / email of an existing one.
class LeadFormScreen extends StatefulWidget {
  final Lead? existing;

  const LeadFormScreen({super.key, this.existing});

  @override
  State<LeadFormScreen> createState() => _LeadFormScreenState();
}

class _LeadFormScreenState extends State<LeadFormScreen> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?.name);
  late final _phone = TextEditingController(text: widget.existing?.phone);
  late final _email = TextEditingController(text: widget.existing?.email);
  String? _assignTo;
  bool _saving = false;

  bool get _editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    // Admin's new leads go to the admin by default; they can pick someone else.
    _assignTo = currentUserId;
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      if (_editing) {
        await Repo.updateLead(widget.existing!.id, {
          'name': _name.text.trim(),
          'phone': _phone.text.trim(),
          'email': _email.text.trim(),
        });
        await Repo.addActivity(widget.existing!.id, 'edit', body: 'Details edited');
        if (mounted) Navigator.pop(context, true);
        return;
      }

      final res = await Repo.createLead(
        name: _name.text.trim(),
        phone: _phone.text.trim(),
        email: _email.text.trim(),
        assignTo: AppState.instance.isAdmin ? _assignTo : null,
      );
      if (!mounted) return;
      switch (res['status']) {
        case 'created':
          Navigator.pop(context, true);
        case 'duplicate':
          setState(() => _saving = false);
          final open = await showDialog<bool>(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('Already in CRM'),
              content: const Text('A lead with this phone number / email already exists.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('OK')),
                FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Open it')),
              ],
            ),
          );
          if (open == true && mounted) {
            await Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (_) => LeadDetailScreen(leadId: res['id'] as String)),
            );
          }
        default:
          setState(() => _saving = false);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('This number is already in CRM with another team member. Ask your admin.'),
          ));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      final msg = e is PostgrestException && e.code == '23505'
          ? 'Another lead already has this phone number'
          : errorText(e);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    return Scaffold(
      appBar: AppBar(title: Text(_editing ? 'Edit lead' : 'Add lead')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name', prefixIcon: Icon(Icons.person_outline)),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Phone',
                hintText: '10-digit mobile number',
                prefixIcon: Icon(Icons.phone_outlined),
              ),
              validator: (v) {
                final digits = (v ?? '').replaceAll(RegExp(r'\D'), '');
                if (digits.isEmpty && _email.text.trim().isEmpty) return 'Enter a phone number or email';
                if (digits.isNotEmpty && digits.length < 10) return 'Phone number looks too short';
                return null;
              },
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.email_outlined)),
              validator: (v) {
                final t = (v ?? '').trim();
                if (t.isNotEmpty && !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(t)) return 'Email looks wrong';
                return null;
              },
            ),
            if (!_editing && app.isAdmin) ...[
              const SizedBox(height: 14),
              DropdownButtonFormField<String?>(
                initialValue: _assignTo,
                decoration: const InputDecoration(labelText: 'Assign to', prefixIcon: Icon(Icons.assignment_ind_outlined)),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Unassigned')),
                  for (final p in app.activeTeam) DropdownMenuItem(value: p.id, child: Text(p.displayName)),
                ],
                onChanged: (v) => setState(() => _assignTo = v),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              child: Text(_saving ? 'Saving…' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }
}
