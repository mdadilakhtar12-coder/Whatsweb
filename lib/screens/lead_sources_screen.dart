import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config.dart';
import '../services/repo.dart';

/// Admin: the addresses to paste into landing pages and Google Ads so leads come in by themselves.
class LeadSourcesScreen extends StatefulWidget {
  const LeadSourcesScreen({super.key});

  @override
  State<LeadSourcesScreen> createState() => _LeadSourcesScreenState();
}

class _LeadSourcesScreenState extends State<LeadSourcesScreen> {
  String? _key;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    Repo.setting('integrations').then((v) {
      if (mounted) {
        setState(() {
          _key = v?['landing_key'] as String?;
          _loading = false;
        });
      }
    }).catchError((Object _) {
      if (mounted) setState(() => _loading = false);
    });
  }

  String get _webhook => '$supabaseUrl/functions/v1/lead-webhook';

  @override
  Widget build(BuildContext context) {
    final key = _key;
    return Scaffold(
      appBar: AppBar(title: const Text('Lead sources')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : key == null
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('The landing key is not set up yet. It is created by the GitHub "Build APK" run: open Actions and run it once.'),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _Section(
                      title: 'Landing page / website form',
                      help: 'Send the form (POST) to this address with fields name, phone, email. '
                          'Add ?utm_source=facebook or ?utm_source=google to the ad link so the CRM '
                          'knows where the lead came from.',
                      values: [('Form address', '$_webhook?key=$key')],
                    ),
                    _Section(
                      title: 'Google Ads lead form',
                      help: 'Lead form → Lead delivery → Webhook integration. Paste these two, '
                          'then press "Send test data".',
                      values: [('Webhook URL', _webhook), ('Key', key)],
                    ),
                    const _Section(
                      title: 'Meta Instant Forms',
                      help: 'Needs a one-time setup in Meta for Developers. Do it together with Claude.',
                      values: [],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'This key is inside your landing pages, so anyone can see it. Leads per visitor, per phone and per day are limited. If someone misuses it, ask Claude to change it.',
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ],
                ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final String help;
  final List<(String, String)> values;

  const _Section({required this.title, required this.help, required this.values});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 4),
            Text(help, style: TextStyle(color: scheme.onSurfaceVariant)),
            for (final (label, value) in values) ...[
              const SizedBox(height: 10),
              Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
              Row(
                children: [
                  Expanded(child: SelectableText(value, style: const TextStyle(fontSize: 13))),
                  IconButton(
                    tooltip: 'Copy',
                    icon: const Icon(Icons.copy, size: 20),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: value));
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label copied')));
                    },
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
