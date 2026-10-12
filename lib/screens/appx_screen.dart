import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../config.dart';
import '../services/notifications.dart';
import '../services/repo.dart';

/// The six events the AIFM Education app (Appx) can send, with what to type in the Appx webhook form.
/// (key name, Appx field). The key name is only a label: the CRM reads these names, so type them exactly.
const appxEvents = <({String kind, String title, String does, List<(String, String)> keys})>[
  (
    kind: 'signup',
    title: 'User Signup',
    does: 'Makes a lead (or finds the one with the same phone)',
    keys: [('name', 'Name'), ('number', 'Number'), ('email', 'Email'), ('state', 'State'), ('district', 'District'), ('info1', 'Info 1'), ('info2', 'Info 2')],
  ),
  (
    kind: 'purchase',
    title: 'Successful Purchase',
    does: 'Marks the lead "Admission Done" and saves course, amount and expiry',
    keys: [
      ('name', 'Name'),
      ('number', 'Number'),
      ('email', 'E-mail'),
      ('item', 'Item Name'),
      ('amount', 'Payment Amount'),
      ('transaction_id', 'Transaction ID'),
      ('payment_mode', 'Payment Mode'),
      ('purchase_date', 'Purchase Date'),
      ('expiry_date', 'Expiry Date'),
      ('coupon', 'Coupon Code'),
    ],
  ),
  (
    kind: 'cancelled',
    title: 'Cancelled Payment',
    does: 'Makes a follow-up for the agent: this student wanted to buy',
    keys: [('name', 'Name'), ('number', 'Number'), ('email', 'E-mail'), ('item', 'Item Name'), ('link', 'Purchase Link')],
  ),
  (
    kind: 'demo',
    title: 'Demo Leads',
    does: 'Makes a lead with a note about which demo was asked for',
    keys: [('name', 'Name'), ('number', 'Number'), ('email', 'E-mail'), ('item', 'Item Name'), ('link', 'Purchase Link')],
  ),
  (
    kind: 'contact',
    title: 'Website Contact Submission',
    does: 'Makes a lead from the website contact form',
    keys: [('name', 'Name'), ('number', 'Number'), ('email', 'Email'), ('datetime', 'Datetime')],
  ),
  (
    kind: 'refund',
    title: 'Payment Refund',
    does: 'Shows the refund on the lead and takes it off the money',
    keys: [('transaction_id', 'Transaction ID'), ('amount', 'Amount'), ('number', 'User Phone'), ('email', 'User Email')],
  ),
];

String appxEventName(String kind) =>
    appxEvents.where((e) => e.kind == kind).map((e) => e.title).firstOrNull ?? kind;

/// Admin: connect the AIFM Education app (Appx) to the CRM: signups, purchases, cancelled payments, refunds.
class AppxScreen extends StatefulWidget {
  const AppxScreen({super.key});

  @override
  State<AppxScreen> createState() => _AppxScreenState();
}

class _AppxScreenState extends State<AppxScreen> {
  final _min = TextEditingController();
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
    _min.dispose();
    super.dispose();
  }

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _load() async {
    try {
      final results = await Future.wait<Object?>([
        Repo.setting('integrations'),
        Repo.appxOverview(),
        Repo.appxEvents(),
      ]);
      if (!mounted) return;
      setState(() {
        _secret = (results[0] as Map<String, dynamic>?)?['appx_token'] as String?;
        _o = results[1] as Map<String, dynamic>;
        _events = results[2] as List<Map<String, dynamic>>;
        _min.text = _rupeesText(_o['min_amount']);
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

  static String _rupeesText(Object? v) {
    final n = (v as num?) ?? 0;
    return n == n.roundToDouble() ? '${n.round()}' : '$n';
  }

  String _address(String kind) => '$supabaseUrl/functions/v1/appx/$_secret/$kind';

  bool get _setStatus => _o['set_status'] != false;

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

  Future<void> _saveConfig({bool? setStatus}) => _run(() async {
        final min = num.tryParse(_min.text.trim().isEmpty ? '0' : _min.text.trim());
        if (min == null || min < 0) return _toast('Type an amount in rupees, like 500');
        await Repo.appxSetConfig(setStatus: setStatus ?? _setStatus, minAmount: min);
        await _load();
        if (mounted) _toast('Saved');
      });

  Future<void> _sendTest() => _run(() async {
        final r = await Repo.appx('send_test');
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
    final r = await Repo.appxClearTests();
    await _load();
    if (mounted) _toast('Removed ${r['leads'] ?? 0} test lead(s)');
  }

  void _showEvent(Map<String, dynamic> e) {
    final body = const JsonEncoder.withIndent('  ').convert(e['body']);
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(appxEventName('${e['kind']}')),
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
      appBar: AppBar(title: const Text('AIFM Education app'), actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)]),
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
                        '1.  Addresses for the Appx webhooks',
                        [
                          Text(
                            'Appx CMS → Integrations → Webhooks → the + button. Make one webhook for each event below. '
                            'In each: choose the event, paste its address in "Webhook URL", keep "Key-Value Based", '
                            'and add the keys listed (type the key name exactly, then choose the Appx field next to it). '
                            'Save.',
                            style: muted,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Keep these addresses private. Anyone who has one can send fake students and purchases to your CRM.',
                            style: TextStyle(color: scheme.error, fontSize: 12.5),
                          ),
                          if (_secret == null || _secret!.isEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: Text('Not ready yet. Run "Build APK" once in GitHub Actions: it makes the secret address.', style: TextStyle(color: scheme.error)),
                            )
                          else
                            for (final e in appxEvents) _eventGuide(e, scheme),
                        ],
                      ),
                      _section(
                        '2.  When someone buys',
                        [
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Mark the lead "Admission Done"'),
                            subtitle: Text('A purchase in the app changes the lead\'s status by itself.', style: muted),
                            value: _setStatus,
                            onChanged: _busy ? null : (v) => _saveConfig(setStatus: v),
                          ),
                          if (_setStatus) ...[
                            const SizedBox(height: 4),
                            Text(
                              'Small purchases (a ₹99 test series, a book) can be left out: the status changes only from this amount.',
                              style: muted,
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _min,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(labelText: 'From this amount (₹)', helperText: '0 = every purchase'),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                FilledButton.tonal(onPressed: _busy ? null : () => _saveConfig(), child: const Text('Save')),
                              ],
                            ),
                          ],
                          const SizedBox(height: 8),
                          Text(
                            'Either way the purchase is saved on the lead, and a student who has bought no longer gets the automatic "not paid" reminder on WhatsApp. '
                            'In a WhatsApp broadcast you can choose "Bought in the app" or "Not bought" under Filters.',
                            style: muted,
                          ),
                        ],
                      ),
                      _section(
                        '3.  Test it',
                        [
                          Text(
                            'Makes a made-up student who signs up, buys a ₹499 course (sent twice, counted once) and cancels another payment, '
                            'the same way a real one would arrive. You can remove it again with one tap.',
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
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text('Latest events', style: Theme.of(context).textTheme.titleMedium),
                      ),
                      const SizedBox(height: 6),
                      if (_events.isEmpty) Text('Nothing received yet.', style: muted),
                      for (final e in _events) _eventTile(e, scheme),
                    ],
                  ),
                ),
    );
  }

  Widget _eventGuide(({String kind, String title, String does, List<(String, String)> keys}) e, ColorScheme scheme) {
    final address = _address(e.kind);
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 10),
        title: Text(e.title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(e.does, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5)),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: SelectableText(address, style: const TextStyle(fontSize: 12))),
              IconButton(
                tooltip: 'Copy',
                icon: const Icon(Icons.copy, size: 20),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: address));
                  _toast('Address copied');
                },
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('Add Key  →  choose field', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5, fontWeight: FontWeight.w600)),
          for (final k in e.keys)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  SizedBox(width: 130, child: SelectableText(k.$1, style: const TextStyle(fontFamily: 'monospace', fontSize: 13))),
                  const Text('→  '),
                  Expanded(child: Text(k.$2, style: const TextStyle(fontSize: 13))),
                ],
              ),
            ),
          const SizedBox(height: 4),
          Text(
            e.kind == 'refund'
                ? 'Transaction ID or the phone / e-mail is how the purchase is found.'
                : 'Number or Email must be there: that is how the student is recognised. The others are optional.',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _statusCard(ColorScheme scheme) {
    final last = _o['last_event_at'] == null ? null : DateTime.tryParse('${_o['last_event_at']}')?.toLocal();
    int n(String k) => (_o[k] as num?)?.toInt() ?? 0;
    final problems = n('errors') + n('waiting');
    final (Color bg, Color fg, IconData icon, String title) = last == null
        ? (Colors.orange.shade50, Colors.orange.shade900, Icons.hourglass_empty, 'Nothing received from the app yet')
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
            Text('${n('signups')} signed up · ${n('purchases')} bought', style: TextStyle(color: fg)),
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
    final body = e['body'] is Map ? e['body'] as Map : const {};
    String? find(List<String> names) {
      for (final entry in body.entries) {
        if (names.contains('${entry.key}'.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '')) && '${entry.value}'.isNotEmpty) return '${entry.value}';
      }
      return null;
    }

    final who = find(['name']) ?? find(['email', 'useremail']) ?? find(['number', 'phone', 'userphone']);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: color),
      title: Text(appxEventName('${e['kind']}')),
      subtitle: Text(
        [
          if (at != null) DateFormat('d MMM, h:mm a').format(at),
          ?who,
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
