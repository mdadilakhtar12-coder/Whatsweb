import 'package:flutter/material.dart';

import '../models.dart';
import '../services/app_state.dart';
import '../services/repo.dart';
import '../widgets/wa_stats_card.dart';
import '../widgets/wa_widgets.dart' show waStatusLabel;
import 'wa_broadcast_screen.dart';
import 'wa_nodes_screen.dart';
import 'wa_quick_send_screen.dart';
import 'wa_setup_screen.dart';
import 'wa_templates_screen.dart';

const _autoSources = [
  ('meta_form', 'Meta form'),
  ('meta_landing', 'Meta landing page'),
  ('google_form', 'Google form'),
  ('google_landing', 'Google landing page'),
  ('website', 'Website'),
  ('excel', 'Excel import'),
  ('manual', 'Added by hand'),
];

/// Admin: everything about the WhatsApp Cloud API in one place.
class WhatsappScreen extends StatefulWidget {
  const WhatsappScreen({super.key});

  @override
  State<WhatsappScreen> createState() => _WhatsappScreenState();
}

class _WhatsappScreenState extends State<WhatsappScreen> {
  late Map<String, dynamic> _cfg = _copy(AppState.instance.wa);
  List<WaTemplate> _templates = [];

  /// every template, whatever Meta said (the reminders show where their template stands)
  List<WaTemplate> _allTemplates = [];
  List<WaNode> _nodes = [];

  static Map<String, dynamic> _copy(Map<String, dynamic> m) => {
        ...m,
        'auto_sources': [...((m['auto_sources'] as List?) ?? const [])],
        'rules': [for (final r in (m['rules'] as List? ?? const [])) {...(r as Map).cast<String, dynamic>()}],
        'nudges': [for (final n in (m['nudges'] as List? ?? const [])) {...(n as Map).cast<String, dynamic>()}],
        'followups': {
          ...((m['followups'] as Map?)?.cast<String, dynamic>() ?? {}),
          'steps': [for (final s in ((m['followups'] as Map?)?['steps'] as List? ?? const [])) {...(s as Map).cast<String, dynamic>()}],
        },
      };

  Map<String, dynamic> get _follow => (_cfg['followups'] as Map).cast<String, dynamic>();
  List<Map<String, dynamic>> get _steps => (_follow['steps'] as List).cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> get _rules => (_cfg['rules'] as List).cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> get _nudges => ((_cfg['nudges'] as List?) ?? const []).cast<Map<String, dynamic>>();
  List<String> get _sources => (_cfg['auto_sources'] as List).cast<String>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _load() async {
    await AppState.instance.reloadWa();
    try {
      final results = await Future.wait<Object?>([Repo.waTemplates(), Repo.waNodes()]);
      if (!mounted) return;
      setState(() {
        _cfg = _copy(AppState.instance.wa);
        // Automatic messages cannot ask anyone to fill in details, so those templates are left out here.
        _allTemplates = results[0] as List<WaTemplate>;
        _templates = _allTemplates.where((t) => t.approved && t.askNames.isEmpty).toList();
        _nodes = results[1] as List<WaNode>;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _cfg = _copy(AppState.instance.wa));
        _toast(errorText(e));
      }
    }
  }

  /// Saves the whole settings box.
  Future<void> _save() async {
    try {
      await Repo.saveSetting('whatsapp', _cfg);
      AppState.instance.wa = _copy(_cfg);
    } catch (e) {
      _toast(errorText(e));
    }
  }

  void _change(VoidCallback fn) {
    setState(fn);
    _save();
  }

  Future<void> _push(Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    _load();
  }

  bool _hasTemplate(String? id) => id != null && _templates.any((t) => t.id == id);

  Widget _templateDropdown(String? value, ValueChanged<String?> onChanged, {String label = 'Template', String none = 'Choose a template'}) {
    return DropdownButtonFormField<String?>(
      isExpanded: true,
      initialValue: _hasTemplate(value) ? value : null,
      decoration: InputDecoration(labelText: label),
      items: [
        DropdownMenuItem(value: null, child: Text(none)),
        for (final t in _templates) DropdownMenuItem(value: t.id, child: Text(t.name)),
      ],
      onChanged: onChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5);
    final connected = app.waConnected;
    final st = app.waStatus;
    final autoOn = _cfg['auto_send'] == true;
    final followOn = _follow['enabled'] == true;

    return Scaffold(
      appBar: AppBar(title: const Text('WhatsApp'), actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)]),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 40),
        children: [
          Card(
            color: connected ? Colors.green.shade50 : Colors.orange.shade50,
            child: ListTile(
              leading: Icon(connected ? Icons.check_circle : Icons.link_off, color: connected ? Colors.green.shade700 : Colors.orange.shade800),
              title: Text(
                connected ? 'Connected: ${st['display_phone'] ?? ''}' : 'Not connected',
                style: TextStyle(color: connected ? Colors.green.shade900 : Colors.orange.shade900, fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                connected
                    ? [if (st['verified_name'] != null) '${st['verified_name']}', if (st['quality'] != null) 'Quality ${st['quality']}'].join(' · ')
                    : 'Tap to connect your WhatsApp Cloud API',
                style: TextStyle(color: connected ? Colors.green.shade800 : Colors.orange.shade800),
              ),
              trailing: Icon(Icons.chevron_right, color: connected ? Colors.green.shade900 : Colors.orange.shade900),
              onTap: () => _push(const WaSetupScreen()),
            ),
          ),
          const SizedBox(height: 4),
          _section('Messages'),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('Templates'),
            subtitle: const Text('Make messages, send them to Meta for approval'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _push(const WaTemplatesScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.smart_button),
            title: const Text('Automatic replies'),
            subtitle: const Text('What a student gets after pressing a button'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _push(const WaNodesScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.dialpad),
            title: const Text('Send to numbers'),
            subtitle: const Text('Type phone numbers, choose a template, send'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _push(const WaQuickSendScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.campaign_outlined),
            title: const Text('Broadcast'),
            subtitle: const Text('Send a template to a group of leads'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _push(const WaBroadcastScreen()),
          ),
          _section('When a new lead comes in'),
          SwitchListTile(
            secondary: const Icon(Icons.bolt),
            title: const Text('Send WhatsApp automatically'),
            subtitle: Text(autoOn ? 'ON: every new lead gets the message within a minute' : 'OFF: nothing is sent by itself'),
            value: autoOn,
            onChanged: (v) {
              if (v && !connected) return _toast('Connect WhatsApp first');
              if (v && !_hasTemplate(_cfg['auto_template_id'] as String?) && !_rules.any((r) => _hasTemplate(r['template_id'] as String?))) {
                return _toast('Choose an approved template below first');
              }
              _change(() => _cfg['auto_send'] = v);
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _templateDropdown(_cfg['auto_template_id'] as String?, (v) => _change(() => _cfg['auto_template_id'] = v), label: 'Message to send'),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _templates.isEmpty
                        ? 'No approved template yet. Make one under Templates.'
                        : 'Templates with "fill when sending" details are not listed: an automatic message cannot ask anyone to fill them in.',
                    style: muted,
                  ),
                ),
                const SizedBox(height: 14),
                Text('Send it to leads from', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 0,
                  children: [
                    for (final s in _autoSources)
                      FilterChip(
                        label: Text(s.$2),
                        selected: _sources.contains(s.$1),
                        onSelected: (on) => _change(() => on ? _sources.add(s.$1) : _sources.remove(s.$1)),
                      ),
                  ],
                ),
                if (_sources.contains('excel'))
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('Careful: an Excel file with 500 rows sends 500 messages (and costs money).', style: TextStyle(color: Colors.orange.shade900, fontSize: 12.5)),
                  ),
                const SizedBox(height: 14),
                Text('A different message for one landing page / form', style: Theme.of(context).textTheme.labelLarge),
                Text('If the lead\'s page, form or campaign name contains this word, it gets this template instead.', style: muted),
                for (var i = 0; i < _rules.length; i++) _ruleRow(i),
                TextButton.icon(
                  onPressed: () => _change(() => _rules.add({'match': '', 'template_id': null})),
                  icon: const Icon(Icons.add),
                  label: const Text('Add'),
                ),
              ],
            ),
          ),
          _section('If the student does not reply'),
          SwitchListTile(
            secondary: const Icon(Icons.update),
            title: const Text('Send follow-up messages'),
            subtitle: Text(followOn ? 'ON: stops as soon as the student replies' : 'OFF'),
            value: followOn,
            onChanged: (v) {
              if (v && !connected) return _toast('Connect WhatsApp first');
              if (v && !_steps.any((s) => _hasTemplate(s['template_id'] as String?))) return _toast('Choose a template for at least one follow-up');
              _change(() => _follow['enabled'] = v);
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Counted from the first automatic message. Only inside the sending hours below.', style: muted),
                for (var i = 0; i < _steps.length; i++) _stepRow(i),
                if (_steps.length < 5)
                  TextButton.icon(
                    onPressed: () => _change(() => _steps.add({'after_hours': 72, 'template_id': null})),
                    icon: const Icon(Icons.add),
                    label: const Text('Add a follow-up'),
                  ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        isExpanded: true,
                        initialValue: (_follow['start_hour'] as num?)?.toInt() ?? 9,
                        decoration: const InputDecoration(labelText: 'Send from'),
                        items: [for (var h = 0; h < 24; h++) DropdownMenuItem(value: h, child: Text(_hour(h)))],
                        onChanged: (v) => _change(() => _follow['start_hour'] = v ?? 9),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        isExpanded: true,
                        initialValue: (_follow['end_hour'] as num?)?.toInt() ?? 21,
                        decoration: const InputDecoration(labelText: 'Until'),
                        items: [for (var h = 1; h <= 24; h++) DropdownMenuItem(value: h, child: Text(_hour(h)))],
                        onChanged: (v) => _change(() => _follow['end_hour'] = v ?? 21),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (_nudges.isNotEmpty) ...[
            _section('Automatic reminders'),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                'Made by Claude (or you). A reminder goes to a new lead some time after he arrives, if the condition holds. '
                'It only reaches leads that arrive after you switch it on, and each lead gets it once.',
                style: muted,
              ),
            ),
            for (final n in _nudges) _nudgeCard(n),
          ],
          _section('Other'),
          SwitchListTile(
            secondary: const Icon(Icons.chat),
            title: const Text('WhatsApp button sends through the API'),
            subtitle: const Text('ON: the WhatsApp button on a lead opens the in-app chat. OFF: it opens the WhatsApp app on the phone.'),
            value: _cfg['button_via_api'] == true,
            onChanged: (v) {
              if (v && !connected) return _toast('Connect WhatsApp first');
              _change(() => _cfg['button_via_api'] = v);
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: DropdownButtonFormField<String?>(
              isExpanded: true,
              initialValue: _nodes.any((n) => n.id == _cfg['welcome_node_id']) ? _cfg['welcome_node_id'] as String : null,
              decoration: const InputDecoration(
                labelText: 'Reply to people who message you first',
                helperText: 'A new lead is also created for them',
              ),
              items: [
                const DropdownMenuItem(value: null, child: Text('No automatic reply')),
                for (final n in _nodes) DropdownMenuItem(value: n.id, child: Text(n.name)),
              ],
              onChanged: (v) => _change(() => _cfg['welcome_node_id'] = v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                Expanded(child: _priceField('Marketing ₹ / message', 'price_marketing', 0.9)),
                const SizedBox(width: 12),
                Expanded(child: _priceField('Utility ₹ / message', 'price_utility', 0.15)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('Only used to show the cost estimate before a broadcast. Check Meta\'s current rates.', style: muted),
          ),
          if (connected) ...[
            _section('Numbers'),
            const Padding(padding: EdgeInsets.symmetric(horizontal: 4), child: WaStatsCard()),
          ],
        ],
      ),
    );
  }

  String _hour(int h) {
    final h12 = h % 12 == 0 ? 12 : h % 12;
    return '$h12 ${h % 24 < 12 ? 'AM' : 'PM'}';
  }

  /// "60 minutes after a lead from "landing page one" arrives, if he has not paid yet"
  String _nudgeText(Map<String, dynamic> n) {
    final min = (n['after_minutes'] as num?)?.toInt() ?? 60;
    final after = min < 60 ? '$min minutes' : (min % 60 == 0 ? '${min ~/ 60} hour${min == 60 ? '' : 's'}' : '${min ~/ 60} h ${min % 60} min');
    final page = '${n['match'] ?? ''}'.isEmpty ? 'every new lead' : 'a lead from "${n['match']}"';
    final cond = switch ('${n['only_if'] ?? 'not_paid'}') {
      'not_paid' => ', if he has not paid yet',
      'no_reply' => ', if he has not written to you',
      'not_paid_no_reply' => ', if he has not paid and has not written',
      _ => '',
    };
    final from = (n['start_hour'] as num?)?.toInt() ?? 9;
    final to = (n['end_hour'] as num?)?.toInt() ?? 21;
    return '$after after $page arrives$cond. Sends "${n['template_name']}" between ${_hour(from)} and ${_hour(to)}.';
  }

  Widget _nudgeCard(Map<String, dynamic> n) {
    final scheme = Theme.of(context).colorScheme;
    final tpl = _allTemplates.where((t) => t.id == n['template_id']).firstOrNull;
    final on = n['enabled'] == true;
    final status = tpl == null ? 'The template was deleted' : (tpl.approved ? 'Template approved by Meta' : 'Waiting for Meta: ${waStatusLabel(tpl.status)}');
    final ready = tpl != null && tpl.approved;
    return Card(
      key: ObjectKey(n),
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${n['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(_nudgeText(n), style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 4),
                  Text(
                    on ? 'ON' : 'Paused · $status',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: on ? Colors.green.shade700 : (ready ? scheme.onSurfaceVariant : Colors.orange.shade800)),
                  ),
                ],
              ),
            ),
            Column(
              children: [
                Switch(
                  value: on,
                  onChanged: (v) {
                    if (v && !ready) return _toast(tpl == null ? 'Its template was deleted' : 'Switch it on after Meta approves the template');
                    if (v && !(AppState.instance.waConnected)) return _toast('Connect WhatsApp first');
                    _change(() {
                      n['enabled'] = v;
                      // from this moment: leads that arrived before are not messaged
                      if (v) n['enabled_at'] = DateTime.now().toUtc().toIso8601String();
                    });
                  },
                ),
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('Remove this reminder?'),
                        content: const Text('Messages already sent stay. Nothing more will be sent by it.'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep')),
                          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
                        ],
                      ),
                    );
                    if (ok == true) _change(() => _nudges.remove(n));
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 18, 8, 4),
        child: Text(title.toUpperCase(), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.primary)),
      );

  Widget _priceField(String label, String key, double fallback) {
    return TextFormField(
      initialValue: '${(_cfg[key] as num?)?.toDouble() ?? fallback}',
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label, isDense: true),
      onChanged: (v) {
        final n = double.tryParse(v);
        if (n != null) {
          _cfg[key] = n;
          _save();
        }
      },
    );
  }

  Widget _ruleRow(int i) {
    final r = _rules[i];
    return Card(
      key: ObjectKey(r),
      margin: const EdgeInsets.only(top: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    initialValue: '${r['match'] ?? ''}',
                    decoration: const InputDecoration(labelText: 'If the page / form / campaign name contains', hintText: 'neet', isDense: true),
                    onChanged: (v) {
                      r['match'] = v.trim();
                      _save();
                    },
                  ),
                ),
                IconButton(icon: const Icon(Icons.close), onPressed: () => _change(() => _rules.removeAt(i))),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8, top: 10),
              child: _templateDropdown(r['template_id'] as String?, (v) => _change(() => r['template_id'] = v), label: 'Send this template'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stepRow(int i) {
    final s = _steps[i];
    const hours = [6, 12, 24, 48, 72, 96, 120, 168];
    final value = (s['after_hours'] as num?)?.toInt() ?? 24;
    return Card(
      key: ObjectKey(s),
      margin: const EdgeInsets.only(top: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    isExpanded: true,
                    initialValue: hours.contains(value) ? value : 24,
                    decoration: InputDecoration(labelText: 'Follow-up ${i + 1}: send after', isDense: true),
                    items: [for (final h in hours) DropdownMenuItem(value: h, child: Text(h < 24 ? '$h hours' : '${h ~/ 24} day${h == 24 ? '' : 's'}'))],
                    onChanged: (v) => _change(() => s['after_hours'] = v ?? 24),
                  ),
                ),
                IconButton(icon: const Icon(Icons.close), onPressed: () => _change(() => _steps.removeAt(i))),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8, top: 10),
              child: _templateDropdown(s['template_id'] as String?, (v) => _change(() => s['template_id'] = v), label: 'Template'),
            ),
          ],
        ),
      ),
    );
  }
}
