import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../config.dart';
import '../services/notifications.dart';
import '../services/repo.dart';

String webinarEventName(String event) => switch (event) {
      'registration.created' => 'Registered',
      'registration.payment.completed' => 'Paid',
      'registration.payment.failed' => 'Payment failed',
      'registration.refunded' => 'Refunded',
      'registration.status.changed' => 'Status changed',
      _ => event,
    };

/// Admin: connect Webinar.gg (registrations, payments and who came) to the CRM.
class WebinarScreen extends StatefulWidget {
  const WebinarScreen({super.key});

  @override
  State<WebinarScreen> createState() => _WebinarScreenState();
}

class _WebinarScreenState extends State<WebinarScreen> {
  final _token = TextEditingController();
  String? _secret;
  Map<String, dynamic> _o = const {};
  List<Map<String, dynamic>> _events = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _load() async {
    try {
      final results = await Future.wait<Object?>([
        Repo.setting('integrations'),
        Repo.webinarOverview(),
        Repo.webinarEvents(),
      ]);
      if (!mounted) return;
      setState(() {
        _secret = (results[0] as Map<String, dynamic>?)?['webinar_token'] as String?;
        _o = results[1] as Map<String, dynamic>;
        _events = results[2] as List<Map<String, dynamic>>;
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

  String get _address => '$supabaseUrl/functions/v1/webinar-gg/$_secret';

  bool get _tokenSaved => _o['token_saved'] == true;

  Future<void> _run(Future<void> Function() job) async {
    setState(() => _busy = true);
    try {
      await job();
    } catch (e) {
      if (mounted) _toast(errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveToken() => _run(() async {
        final t = _token.text.trim();
        if (t.isEmpty) return _toast('Paste the token first');
        await Repo.webinar('save_token', {'token': t});
        _token.clear();
        _toast('Token saved');
        await _load();
      });

  Future<void> _removeToken() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove the saved token?'),
        content: const Text('Attendance will not be copied from Webinar.gg until you save a token again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      await Repo.webinar('clear_token');
      await _load();
    });
  }

  Future<void> _syncNow() => _run(() async {
        final r = await Repo.webinar('sync_now');
        await _load();
        if (!mounted) return;
        _toast('${r['note'] ?? 'Done'}');
      });

  Future<void> _sendTest() => _run(() async {
        final r = await Repo.webinar('send_test');
        await _load();
        if (!mounted) return;
        final lines = ((r['lines'] as List?) ?? const []).map((e) => '$e').toList();
        final ok = r['ok'] == true;
        final clear = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(ok ? 'The test worked' : 'The test did not work'),
            content: SingleChildScrollView(child: Text(lines.join('\n\n'))),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep it')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove test data')),
            ],
          ),
        );
        if (clear == true) await _clearTests();
      });

  Future<void> _clearTests() async {
    final r = await Repo.webinarClearTests();
    await _load();
    if (mounted) _toast('Removed ${r['leads'] ?? 0} test lead(s)');
  }

  Future<void> _setUnit(num divisor) => _run(() async {
        await Repo.webinarSetDivisor(divisor);
        await _load();
        if (mounted) _toast('Amounts updated');
      });

  void _showEvent(Map<String, dynamic> e) {
    final body = const JsonEncoder.withIndent('  ').convert(e['body']);
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(webinarEventName('${e['event']}')),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if ((e['error'] ?? '').toString().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text('${e['error']}', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              SelectableText(body, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: body));
              Navigator.pop(context);
              _toast('Copied');
            },
            child: const Text('Copy'),
          ),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 13);
    return Scaffold(
      appBar: AppBar(title: const Text('Webinar.gg'), actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)]),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Padding(padding: const EdgeInsets.all(24), child: Text(_error!))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                    children: [
                      _statusCard(scheme),
                      const SizedBox(height: 8),
                      _section(
                        '1.  Address for Webinar.gg',
                        [
                          Text(
                            'Webinar.gg → Settings → Developer Settings → "Webhook callback URL": paste this address and tap Save. '
                            'There is nothing to tick: Webinar.gg sends all its events here and the CRM keeps only the ones it needs '
                            '(registered, paid, payment failed, refunded, status changed).',
                            style: muted,
                          ),
                          const SizedBox(height: 10),
                          if (_secret == null || _secret!.isEmpty)
                            Text('Not ready yet. Run "Build APK" once in GitHub Actions: it makes the secret address.', style: TextStyle(color: scheme.error))
                          else ...[
                            Row(
                              children: [
                                Expanded(child: SelectableText(_address, style: const TextStyle(fontSize: 12.5))),
                                IconButton(
                                  tooltip: 'Copy',
                                  icon: const Icon(Icons.copy, size: 20),
                                  onPressed: () {
                                    Clipboard.setData(ClipboardData(text: _address));
                                    _toast('Address copied');
                                  },
                                ),
                              ],
                            ),
                            Text(
                              'Keep this address private. Anyone who has it can send fake payments to your CRM.',
                              style: TextStyle(color: scheme.error, fontSize: 12.5),
                            ),
                          ],
                        ],
                      ),
                      _section(
                        '2.  Who came to the webinar',
                        [
                          Text(
                            'The webhook does not say who attended. For that, create an API token in Webinar.gg '
                            '(Settings → Developer Settings → API Tokens) and paste it here. It is kept on the server and is never shown again.',
                            style: muted,
                          ),
                          const SizedBox(height: 10),
                          if (_tokenSaved)
                            Row(
                              children: [
                                Icon(Icons.check_circle, color: Colors.green.shade700, size: 20),
                                const SizedBox(width: 8),
                                const Expanded(child: Text('Token saved')),
                                TextButton(onPressed: _busy ? null : _removeToken, child: const Text('Remove')),
                              ],
                            ),
                          TextField(
                            controller: _token,
                            obscureText: true,
                            autocorrect: false,
                            enableSuggestions: false,
                            decoration: InputDecoration(labelText: _tokenSaved ? 'Replace the token' : 'API token'),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 10,
                            runSpacing: 8,
                            children: [
                              FilledButton.tonal(onPressed: _busy ? null : _saveToken, child: const Text('Save token')),
                              OutlinedButton.icon(
                                onPressed: _busy || !_tokenSaved ? null : _syncNow,
                                icon: const Icon(Icons.sync, size: 18),
                                label: const Text('Copy attendance now'),
                              ),
                            ],
                          ),
                          if (_o['last_sync_at'] != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              'Last copied ${timeAgo(DateTime.parse('${_o['last_sync_at']}').toLocal())}: ${_o['last_sync_note'] ?? ''}',
                              style: muted,
                            ),
                          ],
                          Text('This also runs by itself every hour.', style: muted),
                        ],
                      ),
                      _section(
                        '3.  Test it',
                        [
                          Text(
                            'Makes a made-up student who registers and pays ₹149, the same way a real one would arrive. '
                            'You can remove it again with one tap.',
                            style: muted,
                          ),
                          const SizedBox(height: 10),
                          FilledButton.icon(
                            onPressed: _busy ? null : _sendTest,
                            icon: _busy
                                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                : const Icon(Icons.science_outlined),
                            label: const Text('Send a test'),
                          ),
                        ],
                      ),
                      _section(
                        'Amounts',
                        [
                          Text(
                            'Does Webinar.gg send ₹149 as 149 or as 14900 (paise)? After the first real payment look at the lead: '
                            'if it shows ₹14,900, choose Paise. Every saved amount is corrected.',
                            style: muted,
                          ),
                          const SizedBox(height: 10),
                          DropdownButtonFormField<num>(
                            isExpanded: true,
                            initialValue: ((_o['amount_divisor'] as num?) ?? 1) >= 100 ? 100 : 1,
                            decoration: const InputDecoration(labelText: 'Webinar.gg sends amounts in'),
                            items: const [
                              DropdownMenuItem(value: 1, child: Text('Rupees  (149 = ₹149)')),
                              DropdownMenuItem(value: 100, child: Text('Paise  (14900 = ₹149)')),
                            ],
                            onChanged: _busy ? null : (v) => v == null ? null : _setUnit(v),
                          ),
                        ],
                      ),
                      Text('Latest events', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 6),
                      if (_events.isEmpty) Text('Nothing received yet.', style: muted),
                      for (final e in _events) _eventTile(e, scheme),
                    ],
                  ),
                ),
    );
  }

  Widget _statusCard(ColorScheme scheme) {
    final last = _o['last_event_at'] == null ? null : DateTime.tryParse('${_o['last_event_at']}')?.toLocal();
    int n(String k) => (_o[k] as num?)?.toInt() ?? 0;
    final problems = n('errors') + n('waiting');
    final (Color bg, Color fg, IconData icon, String title) = last == null
        ? (Colors.orange.shade50, Colors.orange.shade900, Icons.hourglass_empty, 'Nothing received from Webinar.gg yet')
        : problems > 0
            ? (Colors.red.shade50, Colors.red.shade900, Icons.warning_amber_rounded, '$problems event(s) could not be put into the CRM')
            : (Colors.green.shade50, Colors.green.shade900, Icons.check_circle_outline, 'Working · last event ${timeAgo(last)}');
    return Card(
      color: bg,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: fg),
                const SizedBox(width: 10),
                Expanded(child: Text(title, style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 15))),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${n('registrations')} registered · ${n('paid')} paid'
              '${n('unverified') > 0 ? ' · ${n('unverified')} payment(s) not found in Webinar.gg' : ''}',
              style: TextStyle(color: fg),
            ),
            if (problems > 0)
              Text('The hourly check tries them again. Tap an event below to see what went wrong.', style: TextStyle(color: fg, fontSize: 12.5)),
          ],
        ),
      ),
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Card(
      margin: const EdgeInsets.only(top: 12, bottom: 4),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 6),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _eventTile(Map<String, dynamic> e, ColorScheme scheme) {
    final outcome = '${e['outcome']}';
    final at = DateTime.tryParse('${e['created_at']}')?.toLocal();
    final (IconData icon, Color color) = switch (outcome) {
      'ok' => (Icons.check_circle, Colors.green.shade700),
      'error' => (Icons.error, scheme.error),
      'received' => (Icons.schedule, Colors.orange.shade800),
      _ => (Icons.remove_circle_outline, scheme.outline),
    };
    final email = (e['body'] is Map ? ((e['body'] as Map)['data'] is Map ? ((e['body'] as Map)['data'] as Map)['email'] : null) : null);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: color),
      title: Text(webinarEventName('${e['event']}')),
      subtitle: Text(
        [
          if (at != null) DateFormat('d MMM, h:mm a').format(at),
          if (email != null) '$email',
          if (outcome == 'ignored') 'not needed',
          if (outcome == 'error') '${e['error'] ?? 'error'}',
          if (outcome == 'received') 'waiting',
        ].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => _showEvent(e),
    );
  }
}
