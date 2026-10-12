import 'package:flutter/material.dart';

import '../models.dart';
import '../services/app_state.dart';
import '../services/repo.dart';

const _channels = [('whatsapp', 'WhatsApp'), ('sms', 'SMS'), ('email', 'Email')];

/// Admin: ready-made messages (Course details, Fees, Brochure…) for WhatsApp, SMS and email.
/// When someone taps WhatsApp on a lead and there is more than one, they choose which to send.
class TemplatesScreen extends StatefulWidget {
  const TemplatesScreen({super.key});

  @override
  State<TemplatesScreen> createState() => _TemplatesScreenState();
}

class _TemplatesScreenState extends State<TemplatesScreen> {
  Future<void> _edit(String channel, [MessageTemplate? t]) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => _TemplateEditor(channel: channel, existing: t)),
    );
    if (saved == true) {
      await AppState.instance.reloadTemplates();
      if (mounted) setState(() {});
    }
  }

  Future<void> _delete(MessageTemplate t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete "${t.name}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Repo.deleteTemplate(t.id);
      await AppState.instance.reloadTemplates();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: _channels.length,
      child: Builder(
        builder: (context) => Scaffold(
          appBar: AppBar(
            title: const Text('Message templates'),
            bottom: TabBar(tabs: [for (final c in _channels) Tab(text: c.$2)]),
          ),
          floatingActionButton: FloatingActionButton.extended(
            icon: const Icon(Icons.add),
            label: const Text('New template'),
            onPressed: () => _edit(_channels[DefaultTabController.of(context).index].$1),
          ),
          body: TabBarView(
            children: [for (final c in _channels) _list(c.$1)],
          ),
        ),
      ),
    );
  }

  Widget _list(String channel) {
    final items = AppState.instance.templatesFor(channel);
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
      children: [
        Text(
          'Write {name} where the lead\'s name should go. With more than one template, the app '
          'asks which one to send. The message can still be changed before sending.',
          style: muted,
        ),
        const SizedBox(height: 12),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text('No templates yet — the chat opens empty.', textAlign: TextAlign.center, style: muted),
          ),
        for (final t in items)
          Card(
            child: ListTile(
              title: Text(t.name, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(
                (t.subject ?? '').isNotEmpty ? '${t.subject}\n${t.body}' : t.body,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => _edit(channel, t),
              trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _delete(t)),
            ),
          ),
      ],
    );
  }
}

class _TemplateEditor extends StatefulWidget {
  final String channel;
  final MessageTemplate? existing;

  const _TemplateEditor({required this.channel, this.existing});

  @override
  State<_TemplateEditor> createState() => _TemplateEditorState();
}

class _TemplateEditorState extends State<_TemplateEditor> {
  late final _name = TextEditingController(text: widget.existing?.name);
  late final _subject = TextEditingController(text: widget.existing?.subject);
  late final _body = TextEditingController(text: widget.existing?.body);
  bool _saving = false;

  bool get _isEmail => widget.channel == 'email';

  @override
  void dispose() {
    _name.dispose();
    _subject.dispose();
    _body.dispose();
    super.dispose();
  }

  void _insertName() {
    final sel = _body.selection;
    final text = _body.text;
    final at = sel.isValid ? sel.start : text.length;
    _body.value = TextEditingValue(
      text: text.replaceRange(at, sel.isValid ? sel.end : at, '{name}'),
      selection: TextSelection.collapsed(offset: at + '{name}'.length),
    );
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty || _body.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a name and the message')));
      return;
    }
    setState(() => _saving = true);
    try {
      final count = AppState.instance.templatesFor(widget.channel).length;
      await Repo.saveTemplate(
        id: widget.existing?.id,
        channel: widget.channel,
        name: _name.text.trim(),
        subject: _isEmail ? _subject.text.trim() : null,
        body: _body.text.trim(),
        sortOrder: widget.existing?.sortOrder ?? count + 1,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final channelName = _channels.firstWhere((c) => c.$1 == widget.channel).$2;
    return Scaffold(
      appBar: AppBar(title: Text(widget.existing == null ? 'New $channelName template' : 'Edit template')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Template name', hintText: 'e.g. Course details, Fees, Brochure'),
          ),
          if (_isEmail) ...[
            const SizedBox(height: 14),
            TextField(controller: _subject, decoration: const InputDecoration(labelText: 'Email subject')),
          ],
          const SizedBox(height: 14),
          TextField(
            controller: _body,
            minLines: 6,
            maxLines: 14,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Message', alignLabelWithHint: true),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _insertName,
              icon: const Icon(Icons.person_add_alt, size: 18),
              label: const Text('Insert lead name'),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _saving ? null : _save,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
