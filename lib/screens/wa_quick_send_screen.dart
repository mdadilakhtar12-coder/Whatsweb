import 'package:flutter/material.dart';

import '../models.dart';
import '../services/app_state.dart';
import '../services/repo.dart';
import '../widgets/wa_widgets.dart';

typedef PhoneEntry = ({String phone, String name});

final _phonePattern = RegExp(r'\+?\d[\d\s\-().]{7,}\d');

/// Reads what the admin typed: one number per line (or separated by commas / semicolons), optionally with a name
/// ("9876543210 Rahul", "Rahul, 98765 43210"). Returns the numbers and how many lines could not be understood.
({List<PhoneEntry> entries, int unclear}) parsePhoneEntries(String text) {
  final entries = <PhoneEntry>[];
  final seen = <String>{};
  var unclear = 0;

  void add(String raw, String name) {
    final plus = raw.trim().startsWith('+');
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 10 || digits.length > 15) {
      unclear++;
      return;
    }
    // the same person typed twice counts once (last 10 digits are what the CRM compares)
    if (!seen.add(digits.substring(digits.length - 10))) return;
    entries.add((phone: '${plus ? '+' : ''}$digits', name: name.trim()));
  }

  for (final line in text.split(RegExp(r'[\n;]'))) {
    final l = line.trim();
    if (l.isEmpty) continue;
    final matches = _phonePattern.allMatches(l).toList();
    if (matches.isEmpty) {
      unclear++;
      continue;
    }
    if (matches.length == 1) {
      final m = matches.first;
      final name = (l.substring(0, m.start) + l.substring(m.end)).replaceAll(RegExp(r'^[\s,\-:]+|[\s,\-:]+$'), '');
      var digitsOnly = m.group(0)!.replaceAll(RegExp(r'\D'), '');
      // two numbers separated by a space only: "9876543210 9123456780"
      if (digitsOnly.length > 15) {
        for (final token in m.group(0)!.split(RegExp(r'\s+'))) {
          add(token, '');
        }
      } else {
        add(m.group(0)!, name);
      }
    } else {
      for (final m in matches) {
        add(m.group(0)!, '');
      }
    }
  }
  return (entries: entries, unclear: unclear);
}

/// Admin: type phone numbers, choose an approved template, send. Numbers not in the CRM become leads.
class WaQuickSendScreen extends StatefulWidget {
  const WaQuickSendScreen({super.key});

  @override
  State<WaQuickSendScreen> createState() => _WaQuickSendScreenState();
}

class _WaQuickSendScreenState extends State<WaQuickSendScreen> {
  final _numbers = TextEditingController();
  List<WaTemplate> _templates = [];
  String? _templateId;
  Map<String, String> _asked = {};
  int _askKey = 0;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _numbers.addListener(() => setState(() {}));
    Repo.waTemplates().then((list) {
      if (mounted) {
        setState(() {
          _templates = list.where((t) => t.approved).toList();
          _loading = false;
        });
      }
    }).catchError((Object e) {
      if (mounted) {
        setState(() => _loading = false);
        _toast(errorText(e));
      }
    });
  }

  @override
  void dispose() {
    _numbers.dispose();
    super.dispose();
  }

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  WaTemplate? get _template => _templates.where((t) => t.id == _templateId).firstOrNull;

  double get _price {
    final wa = AppState.instance.wa;
    final t = _template;
    final v = (t?.category == 'UTILITY' ? wa['price_utility'] : wa['price_marketing']) as num?;
    return v?.toDouble() ?? (t?.category == 'UTILITY' ? 0.15 : 0.9);
  }

  Future<void> _send() async {
    final t = _template;
    final parsed = parsePhoneEntries(_numbers.text);
    if (t == null) return _toast('Choose a template');
    if (parsed.entries.isEmpty) return _toast('Type at least one phone number');
    if (parsed.entries.length > 500) return _toast('Up to 500 numbers at a time');
    final missing = t.askNames.where((n) => (_asked[n] ?? '').isEmpty).toList();
    if (missing.isNotEmpty) return _toast('Fill in: ${missing.join(', ')}');
    final n = parsed.entries.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Send now?'),
        content: Text(
          'Template "${t.name}" will be sent to $n number${n == 1 ? '' : 's'}.\n\n'
          'Meta charges about ₹${(n * _price).toStringAsFixed(0)}. Numbers that are not in the CRM yet are added as leads.\n\n'
          'Send only to people who asked to hear from you.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text('Send to $n')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final res = await Repo.waSendToNumbers(
        t.id,
        [for (final e in parsed.entries) {'phone': e.phone, if (e.name.isNotEmpty) 'name': e.name}],
        params: _asked,
      );
      if (!mounted) return;
      int v(String k) => (res[k] as num?)?.toInt() ?? 0;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Sending'),
          content: Text(
            '✅ Sending to ${v('sending')}\n'
            '🆕 New leads created: ${v('new_leads')}\n'
            '🔁 Already in the CRM: ${v('existing')}\n'
            '${v('stopped') > 0 ? '⛔ Asked to stop (left out): ${v('stopped')}\n' : ''}'
            '${v('invalid') > 0 ? '⚠️ Not a valid number: ${v('invalid')}\n' : ''}'
            '\nIt takes a few seconds. Replies come to the Chats tab. Progress is in Broadcast.',
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
        ),
      );
      _numbers.clear();
    } catch (e) {
      _toast(errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5);
    final parsed = parsePhoneEntries(_numbers.text);
    final n = parsed.entries.length;

    return Scaffold(
      appBar: AppBar(title: const Text('Send to numbers')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                Text('Type the phone numbers, choose a template and send. No need to add the leads first.', style: muted),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: _templateId,
                  decoration: InputDecoration(
                    labelText: 'Template',
                    helperText: _templates.isEmpty ? 'No approved template yet: make one in WhatsApp templates' : null,
                  ),
                  items: [for (final t in _templates) DropdownMenuItem(value: t.id, child: Text('${t.name}  (${t.category == 'MARKETING' ? 'Marketing' : 'Utility'})'))],
                  onChanged: (v) => setState(() {
                    _templateId = v;
                    _asked = {};
                    _askKey++;
                  }),
                ),
                if (_template != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: scheme.surfaceContainerHighest.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(8)),
                    child: Text(
                      waFillSample(_template!.body, examples: {..._template!.examples, for (final e in _asked.entries) 'ask.${e.key}': e.value}),
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  if (_template!.askNames.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text('Fill in the details (same for everyone in this send):', style: muted),
                    AskFields(key: ValueKey('ask$_askKey'), template: _template!, onChanged: (v) => setState(() => _asked = v)),
                  ],
                ],
                const SizedBox(height: 16),
                TextField(
                  controller: _numbers,
                  minLines: 7,
                  maxLines: 14,
                  keyboardType: TextInputType.multiline,
                  decoration: const InputDecoration(
                    labelText: 'Phone numbers',
                    alignLabelWithHint: true,
                    hintText: '9876543210\n98765 43211  Rahul\nPriya, 9876543212\n+971501234567',
                    helperText: 'One per line (or separated by commas). A name after the number is optional.',
                    helperMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: scheme.primaryContainer.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(12)),
                  child: Row(
                    children: [
                      const Icon(Icons.phone_android),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          n == 0
                              ? 'No numbers yet'
                              : '$n number${n == 1 ? '' : 's'}${_template == null ? '' : '  ·  about ₹${(n * _price).toStringAsFixed(0)}'}'
                                  '${parsed.unclear > 0 ? '\n${parsed.unclear} line${parsed.unclear == 1 ? '' : 's'} not understood' : ''}',
                          style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _busy ? null : _send,
                  icon: _busy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.send),
                  label: const Text('Send'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                ),
                const SizedBox(height: 12),
                Text(
                  'Meta only lets you start a chat with an approved template. Once the student replies you can write freely for 24 hours (Chats tab).',
                  style: muted,
                ),
              ],
            ),
    );
  }
}
