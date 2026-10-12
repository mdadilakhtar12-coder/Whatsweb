import 'package:flutter/material.dart';

import '../services/app_state.dart';
import '../services/repo.dart';

/// Admin: the reasons offered when a lead is marked e.g. "Not Interested".
class LostReasonsScreen extends StatefulWidget {
  const LostReasonsScreen({super.key});

  @override
  State<LostReasonsScreen> createState() => _LostReasonsScreenState();
}

class _LostReasonsScreenState extends State<LostReasonsScreen> {
  late final List<String> _reasons = [...AppState.instance.lostReasons];
  final _new = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _new.dispose();
    super.dispose();
  }

  void _add() {
    final r = _new.text.trim();
    if (r.isEmpty || _reasons.contains(r)) return;
    setState(() => _reasons.add(r));
    _new.clear();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await Repo.saveSetting('lost_reasons', {'reasons': _reasons});
      AppState.instance.lostReasons = [..._reasons];
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reasons for not joining'),
        actions: [TextButton(onPressed: _saving ? null : _save, child: const Text('Save'))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Asked when a lead gets a status with "Ask for a reason" (like Not Interested). '
            'The dashboard shows which reasons come up most.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          for (final r in _reasons)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.label_outline),
              title: Text(r),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => _reasons.remove(r)),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _new,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(labelText: 'Add a reason'),
                  onSubmitted: (_) => _add(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(onPressed: _add, icon: const Icon(Icons.add)),
            ],
          ),
        ],
      ),
    );
  }
}
