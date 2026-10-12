import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../config.dart';
import '../services/notifications.dart';
import '../services/repo.dart';
import 'api_deliveries_screen.dart';
import 'api_docs_screen.dart';

/// The address every API request is added to.
String get apiBaseUrl => '$supabaseUrl/functions/v1/api/v1';

const apiScopes = [
  ('read', 'Read', 'students, activities, messages, courses, templates'),
  ('write', 'Write', 'notes and the status of a student'),
  ('send', 'Send', 'WhatsApp messages (templates and text)'),
];

/// Admin: keys and the outgoing webhook for an outside AI assistant.
class ApiScreen extends StatefulWidget {
  const ApiScreen({super.key});

  @override
  State<ApiScreen> createState() => _ApiScreenState();
}

class _ApiScreenState extends State<ApiScreen> {
  final _url = TextEditingController();
  final _secret = TextEditingController();
  final _auth = TextEditingController();
  bool _showAuth = false;
  final _cap = TextEditingController();
  Map<String, dynamic> _s = const {};
  List<Map<String, dynamic>> _keys = [];
  List<Map<String, dynamic>> _log = [];
  bool _enabled = false;
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
    _url.dispose();
    _secret.dispose();
    _auth.dispose();
    _cap.dispose();
    super.dispose();
  }

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _load() async {
    try {
      final results = await Future.wait<Object?>([Repo.apiSettings(), Repo.apiKeys(), Repo.apiLog()]);
      if (!mounted) return;
      setState(() {
        _s = results[0] as Map<String, dynamic>;
        _keys = results[1] as List<Map<String, dynamic>>;
        _log = results[2] as List<Map<String, dynamic>>;
        _url.text = (_s['webhook_url'] as String?) ?? '';
        _cap.text = '${_s['send_cap'] ?? 200}';
        _enabled = _s['webhook_enabled'] == true;
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

  // ---- keys -----------------------------------------------------------------------------

  Future<void> _newKey() async {
    final name = TextEditingController();
    final scopes = <String>{'read', 'write', 'send'};
    final go = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Generate an API key'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(controller: name, decoration: const InputDecoration(labelText: 'Name (who will use it)', hintText: 'AI assistant')),
                const SizedBox(height: 12),
                const Text('What may this key do?', style: TextStyle(fontWeight: FontWeight.w600)),
                for (final s in apiScopes)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: scopes.contains(s.$1),
                    title: Text(s.$2),
                    subtitle: Text(s.$3, style: const TextStyle(fontSize: 12)),
                    onChanged: (v) => setLocal(() => v == true ? scopes.add(s.$1) : scopes.remove(s.$1)),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: scopes.isEmpty ? null : () => Navigator.pop(context, true), child: const Text('Generate')),
          ],
        ),
      ),
    );
    final label = name.text.trim().isEmpty ? 'AI assistant' : name.text.trim();
    name.dispose();
    if (go != true) return;
    await _run(() async {
      final r = await Repo.apiKeyCreate(label, scopes.toList());
      await _load();
      if (!mounted) return;
      await _showKey('${r['key']}');
    });
  }

  Future<void> _showKey(String key) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Your API key'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Copy it now. It is shown only this once: the CRM keeps just a fingerprint and cannot show it again.'),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
                child: SelectableText(key, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
              ),
              const SizedBox(height: 10),
              Text('Give it only to your AI assistant. Anyone with this key can read your students and send WhatsApp messages from your number.',
                  style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12.5)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: key));
              _toast('Key copied');
            },
            child: const Text('Copy'),
          ),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('I have saved it')),
        ],
      ),
    );
  }

  Future<void> _revoke(Map<String, dynamic> k) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Revoke "${k['name']}"?'),
        content: const Text('The key stops working at once. Anything that uses it will get an error. This cannot be undone (make a new key if needed).'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Revoke')),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      await Repo.apiKeyRevoke('${k['id']}');
      await _load();
    });
  }

  // ---- webhook and limit ------------------------------------------------------------------

  /// [secret] / [auth]: '' removes the saved one; left out, a new text typed in the box replaces it, an empty box keeps it.
  Future<void> _saveWebhook({String? secret, String? auth}) => _run(() async {
        await Repo.apiWebhookSet(
          url: _url.text.trim(),
          secret: secret ?? (_secret.text.isEmpty ? null : _secret.text.trim()),
          auth: auth ?? (_auth.text.trim().isEmpty ? null : _auth.text.trim()),
          enabled: _enabled,
        );
        _secret.clear();
        _auth.clear();
        await _load();
        if (mounted) _toast('Saved');
      });

  void _generateSecret() {
    final rnd = Random.secure();
    setState(() => _secret.text = List.generate(32, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join());
  }

  Future<void> _test() => _run(() async {
        await Repo.apiWebhookTest();
        await _load();
        if (mounted) _toast('Test event queued: see the Delivery log');
      });

  Future<void> _saveCap() => _run(() async {
        final n = int.tryParse(_cap.text.trim());
        if (n == null || n < 0 || n > 5000) return _toast('Type a number from 0 to 5000');
        await Repo.apiSetCap(n);
        await _load();
        if (mounted) _toast('Saved');
      });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 13);
    return Scaffold(
      appBar: AppBar(title: const Text('API & webhooks'), actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)]),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Padding(padding: const EdgeInsets.all(24), child: Text(_error!))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                    children: [
                      _section('1.  API address', [
                        Text('Your AI assistant sends every request to this address (HTTPS only), with its key:', style: muted),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(child: SelectableText(apiBaseUrl, style: const TextStyle(fontSize: 12.5))),
                            IconButton(
                              tooltip: 'Copy',
                              icon: const Icon(Icons.copy, size: 20),
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: apiBaseUrl));
                                _toast('Address copied');
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text('Header:  Authorization: Bearer <API key>.   60 requests a minute per key.', style: muted),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ApiDocsScreen())),
                          icon: const Icon(Icons.menu_book_outlined, size: 18),
                          label: const Text('API documentation'),
                        ),
                      ]),
                      _section('2.  API keys', [
                        Text('A key is shown once, when you make it. Revoke a key and it stops working at once.', style: muted),
                        const SizedBox(height: 6),
                        if (_keys.isEmpty) Text('No keys yet.', style: muted),
                        for (final k in _keys) _keyTile(k, scheme),
                        const SizedBox(height: 8),
                        FilledButton.icon(onPressed: _busy ? null : _newKey, icon: const Icon(Icons.key), label: const Text('Generate key')),
                      ]),
                      _section('3.  Messages through the API', [
                        Text(
                          'Every message the AI sends shows "Sent by AI assistant" in the chat. Students who replied STOP are never messaged. '
                          'Free text only inside the 24-hour window.',
                          style: muted,
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _cap,
                                keyboardType: TextInputType.number,
                                decoration: InputDecoration(
                                  labelText: 'Most messages in 24 hours',
                                  helperText: '${_s['sent_24h'] ?? 0} sent in the last 24 hours (all keys)',
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            FilledButton.tonal(onPressed: _busy ? null : _saveCap, child: const Text('Save')),
                          ],
                        ),
                        if (_log.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          Text('What the AI did lately', style: Theme.of(context).textTheme.labelLarge),
                          for (final l in _log) _logTile(l, scheme),
                        ],
                      ]),
                      _section('4.  Outgoing webhook', [
                        Text(
                          'The CRM sends a message to your address when a student is created, does something in the app, buys a course, '
                          'replies on WhatsApp or presses a button. https:// only.',
                          style: muted,
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _url,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          decoration: const InputDecoration(labelText: 'Webhook address', hintText: 'https://example.com/whatsweb-hook'),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _secret,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: InputDecoration(
                            labelText: _s['secret_saved'] == true ? 'Secret (saved: type to replace)' : 'Secret (optional)',
                            helperText: 'Used to sign every message (X-WhatsWeb-Signature, HMAC-SHA256).',
                            suffixIcon: IconButton(tooltip: 'Make a secret', icon: const Icon(Icons.auto_fix_high), onPressed: _generateSecret),
                          ),
                        ),
                        if (_s['secret_saved'] == true)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(onPressed: _busy ? null : () => _saveWebhook(secret: ''), child: const Text('Remove the saved secret')),
                          ),
                        const SizedBox(height: 6),
                        TextField(
                          controller: _auth,
                          autocorrect: false,
                          enableSuggestions: false,
                          obscureText: !_showAuth,
                          decoration: InputDecoration(
                            labelText: 'Authorization header value',
                            hintText: _s['auth_saved'] == true ? '•••• saved' : 'optional',
                            helperText: _s['auth_saved'] == true
                                ? 'Saved. Type a new value to replace it. Sent exactly as typed, with no prefix added.'
                                : 'Sent exactly as typed, e.g. Bearer abc123, as the Authorization header of every delivery.',
                            helperMaxLines: 2,
                            suffixIcon: IconButton(
                              tooltip: _showAuth ? 'Hide' : 'Show what I typed',
                              icon: Icon(_showAuth ? Icons.visibility_off : Icons.visibility),
                              onPressed: () => setState(() => _showAuth = !_showAuth),
                            ),
                          ),
                        ),
                        if (_s['auth_saved'] == true)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(onPressed: _busy ? null : () => _saveWebhook(auth: ''), child: const Text('Remove the saved Authorization value')),
                          ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Send events to this address'),
                          value: _enabled,
                          onChanged: _busy ? null : (v) => setState(() => _enabled = v),
                        ),
                        Wrap(
                          spacing: 10,
                          runSpacing: 8,
                          children: [
                            FilledButton(onPressed: _busy ? null : () => _saveWebhook(), child: const Text('Save')),
                            OutlinedButton.icon(
                              onPressed: _busy || _s['webhook_enabled'] != true ? null : _test,
                              icon: const Icon(Icons.science_outlined, size: 18),
                              label: const Text('Send a test event'),
                            ),
                            OutlinedButton.icon(
                              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ApiDeliveriesScreen())).then((_) => _load()),
                              icon: const Icon(Icons.list_alt, size: 18),
                              label: Text('Delivery log${(_s['failed_webhooks'] as num? ?? 0) > 0 ? ' (${_s['failed_webhooks']} failed)' : ''}'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text('A failed delivery is tried again up to 3 times (after 1, 5 and 15 minutes).', style: muted),
                      ]),
                    ],
                  ),
                ),
    );
  }

  Widget _keyTile(Map<String, dynamic> k, ColorScheme scheme) {
    final revoked = k['revoked_at'] != null;
    final used = k['last_used_at'] == null ? null : DateTime.tryParse('${k['last_used_at']}')?.toLocal();
    final scopes = ((k['scopes'] as List?) ?? const []).map((e) => '$e').toList();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(revoked ? Icons.block : Icons.vpn_key_outlined, color: revoked ? scheme.outline : scheme.primary),
      title: Text('${k['name']}', style: TextStyle(decoration: revoked ? TextDecoration.lineThrough : null)),
      subtitle: Text(
        [
          '${k['prefix']}…',
          scopes.join(' + '),
          if (revoked) 'revoked' else if (used != null) 'used ${timeAgo(used)}' else 'never used',
        ].join(' · '),
      ),
      trailing: revoked ? null : TextButton(onPressed: _busy ? null : () => _revoke(k), child: const Text('Revoke')),
    );
  }

  Widget _logTile(Map<String, dynamic> l, ColorScheme scheme) {
    final at = DateTime.tryParse('${l['at']}')?.toLocal();
    final status = (l['status'] as num?)?.toInt() ?? 0;
    final good = status >= 200 && status < 300;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(good ? Icons.check_circle : Icons.block, size: 20, color: good ? Colors.green.shade700 : scheme.error),
      title: Text('${l['method']} ${l['path']}', style: const TextStyle(fontSize: 13)),
      subtitle: Text(
        [if (at != null) DateFormat('d MMM, h:mm a').format(at), '${l['key_name'] ?? ''}', '$status', if ((l['summary'] ?? '').toString().isNotEmpty) '${l['summary']}'].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
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
}
