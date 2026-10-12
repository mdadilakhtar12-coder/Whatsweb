import 'package:flutter/material.dart';

import '../services/push.dart';
import '../services/repo.dart';

/// Admin: alert when a new lead is not called quickly, and optionally give it to someone else.
class SpeedToLeadScreen extends StatefulWidget {
  const SpeedToLeadScreen({super.key});

  @override
  State<SpeedToLeadScreen> createState() => _SpeedToLeadScreenState();
}

class _SpeedToLeadScreenState extends State<SpeedToLeadScreen> {
  bool _loading = true;
  int _alert = 15;
  int _reassign = 0;
  int _start = 9;
  int _end = 21;

  static const _alertChoices = [0, 5, 10, 15, 30, 60];
  static const _reassignChoices = [0, 30, 60, 120, 240];

  @override
  void initState() {
    super.initState();
    Repo.setting('speed_to_lead').then((v) {
      if (!mounted) return;
      int read(String k, int d) => (v?[k] as num?)?.toInt() ?? d;
      setState(() {
        _alert = read('alert_minutes', 15);
        _reassign = read('reassign_minutes', 0);
        _start = read('start_hour', 9);
        _end = read('end_hour', 21);
        _loading = false;
      });
    }).catchError((Object _) {
      if (mounted) setState(() => _loading = false);
    });
  }

  Future<void> _save() async {
    try {
      await Repo.saveSetting('speed_to_lead', {
        'alert_minutes': _alert,
        'reassign_minutes': _reassign,
        'start_hour': _start,
        'end_hour': _end,
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(e))));
    }
  }

  String _hour(int h) => h == 0 || h == 24 ? '12 AM' : h < 12 ? '$h AM' : h == 12 ? '12 PM' : '${h - 12} PM';

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Call new leads fast'),
        actions: [TextButton(onPressed: _loading ? null : _save, child: const Text('Save'))],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (!Push.configured)
                  Card(
                    color: Colors.orange.shade50,
                    child: const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('Push notifications are not set up yet (Firebase). '
                          'These alerts start once they are.'),
                    ),
                  ),
                Text('Remind if a new lead is not called within', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final m in _alertChoices)
                      ChoiceChip(
                        label: Text(m == 0 ? 'Off' : '$m min'),
                        selected: _alert == m,
                        onSelected: (_) => setState(() => _alert = m),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text('The agent and admins get a notification (once per lead).', style: muted),
                const SizedBox(height: 24),
                Text('Give the lead to someone else after', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final m in _reassignChoices)
                      ChoiceChip(
                        label: Text(m == 0 ? 'Never' : m < 60 ? '$m min' : '${m ~/ 60} hr'),
                        selected: _reassign == m,
                        onSelected: (_) => setState(() => _reassign = m),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Goes to the next agent (the auto-assign list if set, otherwise all agents).',
                  style: muted,
                ),
                const SizedBox(height: 24),
                Text('Only during working hours', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _start,
                        decoration: const InputDecoration(labelText: 'From'),
                        items: [for (var h = 0; h < 24; h++) DropdownMenuItem(value: h, child: Text(_hour(h)))],
                        onChanged: (v) => setState(() => _start = v ?? _start),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _end,
                        decoration: const InputDecoration(labelText: 'Until'),
                        items: [for (var h = 1; h <= 24; h++) DropdownMenuItem(value: h, child: Text(_hour(h)))],
                        onChanged: (v) => setState(() => _end = v ?? _end),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text('Indian time. The morning summary goes out at 9 AM.', style: muted),
              ],
            ),
    );
  }
}
