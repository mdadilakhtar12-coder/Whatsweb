import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../config.dart';
import '../services/notifications.dart';
import '../services/claude_state.dart';
import '../services/repo.dart';
import 'claude_requests_screen.dart';

String mcpToolName(String tool) => switch (tool) {
      'propose_add_leads' => 'Asked: add leads',
      'propose_edit_lead' => 'Asked: change a lead',
      'propose_set_status' => 'Asked: change status',
      'propose_add_remark' => 'Asked: write a remark',
      'propose_set_reminder' => 'Asked: set a reminder',
      'propose_assign' => 'Asked: give leads to agents',
      'propose_wa_text' => 'Asked: send a WhatsApp message',
      'propose_wa_template' => 'Asked: send a WhatsApp template',
      'propose_wa_flow' => 'Asked: build a WhatsApp template and replies',
      'propose_wa_rule' => 'Asked: set an automatic reminder',
      'crm_wa_guide' => 'WhatsApp guide',
      'crm_wa_system' => 'WhatsApp system',
      'crm_chats' => 'WhatsApp chats',
      'crm_chat' => 'One WhatsApp chat',
      'crm_templates' => 'Templates',
      'crm_requests' => 'Its own requests',
      'crm_info' => 'Names and lists',
      'crm_overview' => 'Dashboard numbers',
      'crm_team' => 'Team work',
      'crm_leads' => 'List of leads',
      'crm_lead' => 'One lead',
      'crm_webinar' => 'Webinar numbers',
      'crm_whatsapp' => 'WhatsApp numbers',
      _ => tool,
    };

/// What Claude asked, in a few words: "last_7_days · agent Ravi".
String mcpArgsText(Object? args) {
  if (args is! Map || args.isEmpty) return '';
  return args.entries
      .where((e) => e.key != 'lead_id')
      .map((e) => e.value is bool ? (e.value == true ? '${e.key}' : '') : '${e.value}')
      .where((t) => t.isNotEmpty)
      .join(' · ');
}

/// (switch, title, what it lets Claude ask for)
const _permissions = [
  ('read_chats', 'Read WhatsApp chats', 'Claude reads your students\' conversations to understand them and suggest replies. Reading only.'),
  ('add_leads', 'Add new leads', 'From a list you give Claude. People already in the CRM are skipped.'),
  ('edit_leads', 'Change a lead\'s name, phone, e-mail', 'You see the old and the new value before you approve.'),
  ('change_status', 'Change status and Hot/Warm/Cold', 'For one or many leads.'),
  ('add_remark', 'Write remarks', 'A note on a lead\'s history, marked "via Claude".'),
  ('set_reminder', 'Set follow-up reminders', 'For the lead\'s agent or a team member you name.'),
  ('assign', 'Give leads to agents', 'To one agent, or shared one by one among several.'),
  ('wa_text', 'WhatsApp message to one student', 'Free text, only while the student wrote in the last 24 hours. Cannot be taken back.'),
  ('wa_template', 'WhatsApp template to students or numbers', 'Up to 50 at a time. It costs money and cannot be taken back.'),
  ('wa_build', 'Build WhatsApp templates and auto-replies', 'Claude designs a template (saved as a DRAFT: you send it to Meta yourself) and the replies its buttons lead to. It can also read how your WhatsApp is set up.'),
  ('wa_rules', 'Set automatic reminders', 'For example: 1 hour after a lead arrives, if he has not paid, send a template. Saved paused: you switch it on in More > WhatsApp.'),
];

/// Admin: lets the Claude app read the CRM's numbers and leads (reading only), and shows what it looked at.
class ClaudeConnectorScreen extends StatefulWidget {
  const ClaudeConnectorScreen({super.key});

  @override
  State<ClaudeConnectorScreen> createState() => _ClaudeConnectorScreenState();
}

class _ClaudeConnectorScreenState extends State<ClaudeConnectorScreen> {
  String? _token;
  bool _showContacts = false;
  Map<String, bool> _perms = {};
  int _waCap = 200;
  List<Map<String, dynamic>> _log = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _load() async {
    try {
      final results = await Future.wait<Object?>([Repo.setting('integrations'), Repo.mcpLog()]);
      if (!mounted) return;
      final settings = results[0] as Map<String, dynamic>?;
      setState(() {
        _token = settings?['mcp_token'] as String?;
        _showContacts = settings?['mcp_show_contacts'] == true;
        _perms = ((settings?['mcp_perms'] as Map?) ?? const {}).map((k, v) => MapEntry('$k', v == true));
        _waCap = (settings?['mcp_wa_cap'] as num?)?.toInt() ?? 200;
        _log = results[1] as List<Map<String, dynamic>>;
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

  String get _address => '$supabaseUrl/functions/v1/crm-mcp/$_token';

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

  Future<void> _setContacts(bool v) => _run(() async {
        if (v) {
          final ok = await showDialog<bool>(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('Show phone numbers and e-mails to Claude?'),
              content: const Text(
                'Claude will see every lead\'s real number and e-mail. They travel to your Claude chat. '
                'You rarely need this for summaries. Switch it on only when you want Claude to search by number or e-mail.',
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep hidden')),
                FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Show them')),
              ],
            ),
          );
          if (ok != true) return;
        }
        await Repo.mcpSetContacts(v);
        await _load();
      });

  Future<void> _setPerm(String key, bool on) => _run(() async {
        await Repo.mcpSetPerm(key, on);
        await _load();
      });

  Future<void> _setCap(int cap) => _run(() async {
        await Repo.mcpSetWaCap(cap);
        await _load();
      });

  Future<void> _rotate() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Make a new address?'),
        content: const Text(
          'The old address stops working within a minute. Claude will say it cannot connect until you paste the new address '
          '(remove the connector in Claude and add it again).',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Make new address')),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      await Repo.mcpRotate();
      await _load();
      if (mounted) _toast('New address made');
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 13);
    return Scaffold(
      appBar: AppBar(title: const Text('Claude connector'), actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)]),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Padding(padding: const EdgeInsets.all(24), child: Text(_error!))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                    children: [
                      Card(
                        color: scheme.secondaryContainer,
                        margin: EdgeInsets.zero,
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Text(
                            'Connect the Claude app to this CRM. Then you can ask Claude for a summary, '
                            'for example "what happened today?" or "which campaign brings admissions?". '
                            'You can also tell Claude to do things ("give these leads to Ravi", "reply to Rahul"): it only leaves a request, '
                            'and nothing happens until you tap Approve. It can never delete anything.',
                            style: TextStyle(color: scheme.onSecondaryContainer),
                          ),
                        ),
                      ),
                      ValueListenableBuilder<int>(
                        valueListenable: claudePending,
                        builder: (context, n, _) => Card(
                          margin: const EdgeInsets.only(top: 12),
                          child: ListTile(
                            leading: Badge(isLabelVisible: n > 0, label: Text('$n'), child: const Icon(Icons.how_to_reg_outlined)),
                            title: const Text('Claude\'s requests', style: TextStyle(fontWeight: FontWeight.w700)),
                            subtitle: Text(n > 0 ? '$n waiting for your OK' : 'Approve or reject what Claude asks for'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () async {
                              await Navigator.push(context, MaterialPageRoute(builder: (_) => const ClaudeRequestsScreen()));
                              _load();
                            },
                          ),
                        ),
                      ),
                      _section('1.  Add it in the Claude app', [
                        Text(
                          'Claude app → Settings → Connectors → + → Add custom connector. Name: AIFM CRM. '
                          'In "MCP server URL" paste this address, then Continue.',
                          style: muted,
                        ),
                        const SizedBox(height: 10),
                        if (_token == null || _token!.isEmpty)
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
                            'Keep this address private. Whoever has it can read your leads. Never put it in a photo or a chat.',
                            style: TextStyle(color: scheme.error, fontSize: 12.5),
                          ),
                        ],
                      ]),
                      _section('What Claude may ask for', [
                        Text(
                          'Every switch is off until you turn it on. Claude cannot change anything by itself: it leaves a request, '
                          'and you tap Approve in "Claude\'s requests". A switch that is off hides that tool from Claude. '
                          'A new chat in Claude may be needed before it notices a switch.',
                          style: muted,
                        ),
                        const SizedBox(height: 4),
                        for (final p in _permissions) _permTile(p),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<int>(
                          isExpanded: true,
                          initialValue: _waCap,
                          decoration: const InputDecoration(
                            labelText: 'WhatsApp messages Claude may ask for per day',
                            helperText: 'All its requests for today add up to this.',
                          ),
                          items: [
                            for (final n in {20, 50, 100, 200, 500, 1000, _waCap}.toList()..sort())
                              DropdownMenuItem(value: n, child: Text('$n messages')),
                          ],
                          onChanged: _busy ? null : (v) => v == null ? null : _setCap(v),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Never possible: deleting leads, team members and passwords, keys and tokens, connecting or disconnecting WhatsApp, and these switches.',
                          style: muted,
                        ),
                      ]),
                      _section('Phone numbers and e-mails', [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _showContacts,
                          onChanged: _busy ? null : _setContacts,
                          title: Text(_showContacts ? 'Claude sees real numbers' : 'Hidden from Claude'),
                          subtitle: Text(
                            _showContacts
                                ? 'Switch off unless you need it.'
                                : 'Claude sees 91••••••10 and r***@gmail.com. Names, statuses and numbers of calls are enough for summaries.',
                          ),
                        ),
                      ]),
                      _section('Ask Claude things like', [
                        for (final q in const [
                          'Give me today\'s summary: leads, calls, admissions.',
                          'Which campaign gave the most admissions this month?',
                          'Which agent made the fewest calls this week?',
                          'List the leads nobody has called yet.',
                          'How many paid for the webinar and how many came?',
                        ])
                          Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text('•  $q', style: muted)),
                      ]),
                      _section('If the address leaks', [
                        Text('Make a new one. The old one stops working at once.', style: muted),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _rotate,
                          icon: const Icon(Icons.autorenew, size: 18),
                          label: const Text('Make a new address'),
                        ),
                      ]),
                      const SizedBox(height: 16),
                      Text('What Claude looked at', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 6),
                      if (_log.isEmpty) Text('Nothing yet.', style: muted),
                      for (final e in _log) _logTile(e),
                    ],
                  ),
                ),
    );
  }

  Widget _permTile((String, String, String) p) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      value: _perms[p.$1] == true,
      onChanged: _busy ? null : (v) => _setPerm(p.$1, v),
      title: Text(p.$2),
      subtitle: Text(p.$3),
    );
  }

  Widget _logTile(Map<String, dynamic> e) {
    final at = DateTime.tryParse('${e['at']}')?.toLocal();
    final what = mcpArgsText(e['args']);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.visibility_outlined),
      title: Text(mcpToolName('${e['tool']}')),
      subtitle: Text([
        if (at != null) '${DateFormat('d MMM, h:mm a').format(at)} (${timeAgo(at)})',
        if (what.isNotEmpty) what,
      ].join(' · ')),
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Card(
      margin: const EdgeInsets.only(top: 12),
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
