import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../services/repo.dart';

/// Admin: every outgoing webhook delivery and what the receiving address answered.
class ApiDeliveriesScreen extends StatefulWidget {
  const ApiDeliveriesScreen({super.key});

  @override
  State<ApiDeliveriesScreen> createState() => _ApiDeliveriesScreenState();
}

class _ApiDeliveriesScreenState extends State<ApiDeliveriesScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await Repo.apiDeliveries();
      if (mounted) {
        setState(() {
          _rows = rows;
          _loading = false;
          _error = null;
        });
      }
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

  Future<void> _open(Map<String, dynamic> d) async {
    final payload = const JsonEncoder.withIndent('  ').convert(d['payload']);
    final status = '${d['status']}';
    List<Map<String, dynamic>> attempts = const [];
    try {
      attempts = await Repo.apiAttempts('${d['id']}');
    } catch (_) {
      // the summary is still shown
    }
    if (!mounted) return;
    final retry = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(eventLabel('${d['event']}')),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_statusLine(d)),
              if ((d['last_error'] ?? '').toString().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('${d['last_error']}', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              if (attempts.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('Every try', style: TextStyle(fontWeight: FontWeight.w700)),
                for (final a in attempts) _attemptTile(a),
              ],
              const SizedBox(height: 10),
              const Text('What was sent', style: TextStyle(fontWeight: FontWeight.w700)),
              SelectableText(payload, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: payload));
              _toast('Copied');
            },
            child: const Text('Copy'),
          ),
          if (status == 'failed' || status == 'ok') TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Send again')),
          FilledButton(onPressed: () => Navigator.pop(context, false), child: const Text('Close')),
        ],
      ),
    );
    if (retry == true) {
      try {
        await Repo.apiDeliveryRetry('${d['id']}');
        _toast('Queued again');
        await _load();
      } catch (e) {
        if (mounted) _toast(errorText(e));
      }
    }
  }

  Widget _attemptTile(Map<String, dynamic> a) {
    final code = (a['code'] as num?)?.toInt() ?? 0;
    final good = code >= 200 && code < 300;
    final at = DateTime.tryParse('${a['at']}')?.toLocal();
    final body = (a['body'] ?? '').toString();
    final error = (a['error'] ?? '').toString();
    final color = good ? Colors.green.shade700 : Theme.of(context).colorScheme.error;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '#${a['attempt']}  ·  ${code == 0 ? 'no answer' : 'HTTP $code'}${at == null ? '' : '  ·  ${DateFormat('d MMM, h:mm:ss a').format(at)}'}',
            style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 13),
          ),
          if (error.isNotEmpty && !good) Text(error, style: const TextStyle(fontSize: 12.5)),
          if (body.isNotEmpty) SelectableText('Answer: $body', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ],
      ),
    );
  }

  static String eventLabel(String e) => switch (e) {
        'student.created' => 'New student',
        'student.activity' => 'Student activity',
        'course.purchased' => 'Course purchased',
        'whatsapp.reply' => 'WhatsApp reply',
        'whatsapp.button_click' => 'WhatsApp button click',
        'webhook.test' => 'Test event',
        _ => e,
      };

  String _statusLine(Map<String, dynamic> d) {
    final tries = (d['attempts'] as num?)?.toInt() ?? 0;
    final code = d['last_code'];
    return switch ('${d['status']}') {
      'ok' => 'Delivered (answer $code) after $tries ${tries == 1 ? 'try' : 'tries'}',
      'failed' => 'Failed after $tries tries${code != null && code != 0 ? ' (last answer $code)' : ''}',
      'retry' => 'Will try again soon ($tries ${tries == 1 ? 'try' : 'tries'} so far${code != null && code != 0 ? ', last answer $code' : ''})',
      'sending' => 'Sending now',
      _ => 'Waiting to be sent',
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Delivery log'), actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)]),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Padding(padding: const EdgeInsets.all(24), child: Text(_error!))
              : _rows.isEmpty
                  ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Nothing sent yet. Switch the webhook on and tap "Send a test event".')))
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        itemCount: _rows.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final d = _rows[i];
                          final at = DateTime.tryParse('${d['created_at']}')?.toLocal();
                          final (IconData icon, Color color) = switch ('${d['status']}') {
                            'ok' => (Icons.check_circle, Colors.green.shade700),
                            'failed' => (Icons.error, scheme.error),
                            'retry' => (Icons.restart_alt, Colors.orange.shade800),
                            _ => (Icons.schedule, Colors.orange.shade800),
                          };
                          final student = d['payload'] is Map ? (d['payload'] as Map)['student'] : null;
                          final who = student is Map ? student['name'] as String? : null;
                          return ListTile(
                            leading: Icon(icon, color: color),
                            title: Text(eventLabel('${d['event']}')),
                            subtitle: Text(
                              [if (at != null) DateFormat('d MMM, h:mm a').format(at), if ((who ?? '').isNotEmpty) who!, _statusLine(d)].join(' · '),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => _open(d),
                          );
                        },
                      ),
                    ),
    );
  }
}
