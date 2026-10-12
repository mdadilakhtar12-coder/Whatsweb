import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_state.dart';
import '../services/repo.dart';

/// Admin: connect the WhatsApp Cloud API (token and IDs from Meta) and get the webhook address for Meta.
class WaSetupScreen extends StatefulWidget {
  const WaSetupScreen({super.key});

  @override
  State<WaSetupScreen> createState() => _WaSetupScreenState();
}

class _WaSetupScreenState extends State<WaSetupScreen> {
  final _token = TextEditingController();
  final _phoneId = TextEditingController();
  final _wabaId = TextEditingController();
  final _appId = TextEditingController();
  final _secret = TextEditingController();
  Map<String, dynamic>? _info;
  List<String> _warnings = [];
  bool _busy = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_token, _phoneId, _wabaId, _appId, _secret]) {
      c.dispose();
    }
    super.dispose();
  }

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _load() async {
    try {
      final info = await Repo.wa('status');
      if (!mounted) return;
      setState(() {
        _info = info;
        _phoneId.text = '${info['phone_number_id'] ?? ''}';
        _wabaId.text = '${info['waba_id'] ?? ''}';
        _appId.text = '${info['app_id'] ?? ''}';
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = errorText(e);
          _loading = false;
        });
      }
    }
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await Repo.wa('connect', {
        'access_token': _token.text,
        'app_secret': _secret.text,
        'app_id': _appId.text,
        'phone_number_id': _phoneId.text,
        'waba_id': _wabaId.text,
      });
      _token.clear();
      _secret.clear();
      await AppState.instance.reloadWa();
      if (!mounted) return;
      setState(() {
        _info = res;
        _warnings = ((res['warnings'] as List?) ?? const []).map((e) => '$e').toList();
      });
      _toast('Connected to WhatsApp ✓');
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
      await AppState.instance.reloadWa();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    setState(() => _busy = true);
    try {
      final res = await Repo.wa('disconnect');
      await AppState.instance.reloadWa();
      if (mounted) setState(() => _info = res);
    } catch (e) {
      _toast(errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy(String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    _toast('$what copied');
  }

  Widget _copyRow(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  SelectableText(value, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                ],
              ),
            ),
            IconButton.filledTonal(onPressed: () => _copy(value, label), icon: const Icon(Icons.copy, size: 18)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5);
    final info = _info;
    final status = (info?['status'] as Map?)?.cast<String, dynamic>() ?? const {};
    final connected = status['connected'] == true;
    final tokenSaved = info?['token_saved'] as String?;
    final secretSaved = info?['secret_saved'] == true;

    return Scaffold(
      appBar: AppBar(title: const Text('Connect WhatsApp')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
              children: [
                if (connected)
                  Card(
                    color: Colors.green.shade50,
                    child: ListTile(
                      leading: Icon(Icons.check_circle, color: Colors.green.shade700),
                      title: Text('Connected: ${status['display_phone'] ?? ''}', style: TextStyle(color: Colors.green.shade900, fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        [
                          if (status['verified_name'] != null) '${status['verified_name']}',
                          if (status['quality'] != null) 'Quality ${status['quality']}',
                          if (status['tier'] != null) '${status['tier']}',
                        ].join(' · '),
                        style: TextStyle(color: Colors.green.shade800),
                      ),
                    ),
                  ),
                if (_error != null)
                  Card(
                    color: scheme.errorContainer,
                    child: Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: TextStyle(color: scheme.onErrorContainer))),
                  ),
                for (final w in _warnings)
                  Card(
                    color: Colors.orange.shade50,
                    child: Padding(padding: const EdgeInsets.all(12), child: Text('⚠️ $w', style: TextStyle(color: Colors.orange.shade900))),
                  ),
                const SizedBox(height: 4),
                Text('Step 1: Details from Meta', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  'Paste them here once. The token and secret are kept safely on the server and are never shown again. '
                  'Leave a box empty to keep what is saved.',
                  style: muted,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _token,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'Permanent access token',
                    helperText: tokenSaved == null ? 'Not saved yet' : 'Saved: $tokenSaved',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _phoneId,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Phone number ID', helperText: 'Meta developer site > WhatsApp > API Setup'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _wabaId,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'WhatsApp Business Account ID', helperText: 'Same page as the Phone number ID'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _appId,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'App ID', helperText: 'App settings > Basic. Needed for picture / video / PDF templates'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _secret,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'App secret',
                    helperText: secretSaved ? 'Saved' : 'App settings > Basic > App secret > Show. Needed for replies and ticks',
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _busy ? null : _connect,
                  icon: _busy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.link),
                  label: Text(connected ? 'Save & check again' : 'Save & connect'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                ),
                const SizedBox(height: 28),
                Text('Step 2: Tell Meta where to send replies', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text('So that replies, Delivered / Read ticks and template approvals reach this app.', style: muted),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _copyRow('Callback URL', '${info?['webhook_url'] ?? ''}'),
                        _copyRow('Verify token', '${info?['verify_token'] ?? ''}'),
                        const Divider(),
                        const Text(
                          '1. developers.facebook.com > your app > WhatsApp > Configuration.\n'
                          '2. Under Webhook tap Edit. Paste the Callback URL and the Verify token. Tap Verify and save.\n'
                          '3. Under Webhook fields tap Manage and switch Subscribe ON for  messages  (and  message_template_status_update  if you see it).\n'
                          '4. Send a message to your WhatsApp number from another phone: it should appear in Chats.',
                          style: TextStyle(height: 1.5),
                        ),
                      ],
                    ),
                  ),
                ),
                if (connected) ...[
                  const SizedBox(height: 20),
                  Center(child: TextButton(onPressed: _busy ? null : _disconnect, child: const Text('Disconnect WhatsApp'))),
                ],
              ],
            ),
    );
  }
}
