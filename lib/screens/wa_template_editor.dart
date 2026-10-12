import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models.dart';
import '../services/repo.dart';
import '../widgets/wa_widgets.dart';

const _languages = [
  ('en', 'English'),
  ('en_US', 'English (US)'),
  ('en_GB', 'English (UK)'),
  ('hi', 'Hindi'),
  ('mr', 'Marathi'),
  ('gu', 'Gujarati'),
  ('bn', 'Bengali'),
  ('ta', 'Tamil'),
  ('te', 'Telugu'),
  ('kn', 'Kannada'),
  ('ml', 'Malayalam'),
  ('pa', 'Punjabi'),
  ('ur', 'Urdu'),
];

const _details = [
  ('first_name', 'First name'),
  ('name', 'Full name'),
  ('phone', 'Phone'),
  ('email', 'Email'),
  ('agent_name', 'Agent name'),
];

class _Btn {
  String type; // quick_reply, url, phone, copy_code
  final text = TextEditingController();
  final url = TextEditingController();
  final phone = TextEditingController();
  final example = TextEditingController();
  Map<String, dynamic> action;

  _Btn(this.type, [Map<String, dynamic>? json]) : action = {...((json?['action'] as Map?)?.cast<String, dynamic>() ?? {})} {
    text.text = (json?['text'] as String?) ?? '';
    url.text = (json?['url'] as String?) ?? '';
    phone.text = (json?['phone'] as String?) ?? '';
    example.text = (json?['example'] as String?) ?? '';
  }

  Map<String, dynamic> toJson() => {
        'type': type,
        if (type != 'copy_code') 'text': text.text.trim(),
        if (type == 'url') 'url': url.text.trim(),
        if (type == 'phone') 'phone': phone.text.trim(),
        if (type == 'copy_code') 'example': example.text.trim(),
        if (type == 'quick_reply' && action.isNotEmpty) 'action': action,
      };

  void dispose() {
    text.dispose();
    url.dispose();
    phone.dispose();
    example.dispose();
  }
}

/// Create or change a WhatsApp template: heading (text / picture / video / PDF / location), text,
/// footer and buttons (quick reply, link, call, copy code), with a live preview.
class WaTemplateEditor extends StatefulWidget {
  final WaTemplate? existing;

  const WaTemplateEditor({super.key, this.existing});

  @override
  State<WaTemplateEditor> createState() => _WaTemplateEditorState();
}

class _WaTemplateEditorState extends State<WaTemplateEditor> {
  final _name = TextEditingController();
  final _body = TextEditingController();
  final _footer = TextEditingController();
  final _headerText = TextEditingController();
  final _lat = TextEditingController();
  final _lng = TextEditingController();
  final _placeName = TextEditingController();
  final _address = TextEditingController();
  String _language = 'en';
  String _category = 'MARKETING';
  String _headerType = 'none';
  String? _headerPath;
  String? _headerFile;
  final List<_Btn> _buttons = [];
  final Map<String, String> _examples = {};
  List<WaNode> _nodes = [];
  bool _busy = false;

  WaTemplate? get _t => widget.existing;

  /// Meta only lets name, language and category be chosen when the template is created.
  bool get _fresh => _t == null || _t!.status == 'DRAFT';

  @override
  void initState() {
    super.initState();
    for (final c in [_name, _body, _footer, _headerText, _lat, _lng, _placeName, _address]) {
      c.addListener(() => setState(() {}));
    }
    final t = _t;
    if (t != null) {
      _name.text = t.name;
      _language = t.language;
      _category = t.category;
      _body.text = t.body;
      _footer.text = t.footer;
      final h = t.header;
      _headerType = (h['type'] as String?) ?? 'none';
      _headerText.text = (h['text'] as String?) ?? '';
      _headerPath = h['media_path'] as String?;
      _headerFile = h['filename'] as String?;
      _lat.text = h['latitude']?.toString() ?? '';
      _lng.text = h['longitude']?.toString() ?? '';
      _placeName.text = (h['name'] as String?) ?? '';
      _address.text = (h['address'] as String?) ?? '';
      for (final b in t.buttons) {
        _buttons.add(_Btn((b['type'] as String?) ?? 'quick_reply', b));
      }
      _examples.addAll(t.examples);
    }
    Repo.waNodes().then((n) {
      if (mounted) setState(() => _nodes = n);
    }).catchError((Object _) {});
  }

  @override
  void dispose() {
    for (final c in [_name, _body, _footer, _headerText, _lat, _lng, _placeName, _address]) {
      c.dispose();
    }
    for (final b in _buttons) {
      b.dispose();
    }
    super.dispose();
  }

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  void _insert(String variable) {
    final c = _body;
    final sel = c.selection;
    final at = sel.isValid ? sel.start : c.text.length;
    final end = sel.isValid ? sel.end : c.text.length;
    final text = c.text.replaceRange(at, end, '{$variable}');
    c.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: at + variable.length + 2));
  }

  /// Asks for a name and an example (Meta wants an example of what the detail looks like).
  Future<(String, String)?> _askDetail({
    required String title,
    required String nameLabel,
    required String nameHelp,
    required String exampleHelp,
    required bool exampleRequired,
  }) async {
    final name = TextEditingController();
    final example = TextEditingController();
    final res = await showDialog<(String, String)>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  autofocus: true,
                  onChanged: (_) => setLocal(() {}),
                  decoration: InputDecoration(labelText: nameLabel, helperText: nameHelp, helperMaxLines: 3),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: example,
                  onChanged: (_) => setLocal(() {}),
                  decoration: InputDecoration(labelText: exampleRequired ? 'Example' : 'Example (optional)', helperText: exampleHelp, helperMaxLines: 3),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
              onPressed: name.text.trim().isEmpty || (exampleRequired && example.text.trim().isEmpty)
                  ? null
                  : () => Navigator.pop(context, (name.text.trim(), example.text.trim())),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    example.dispose();
    return res;
  }

  Future<void> _insertCustom() async {
    final res = await _askDetail(
      title: 'Detail from the lead form',
      nameLabel: 'Field name',
      nameHelp: 'Same as the column / form field, e.g. City or Course',
      exampleHelp: 'What it looks like, e.g. Delhi. Meta reads this when it reviews the template.',
      exampleRequired: false,
    );
    if (res == null) return;
    final key = res.$1.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
    _insert('extra.$key');
    if (res.$2.isNotEmpty) _examples['extra.${key.toLowerCase()}'] = res.$2;
  }

  /// A detail the sender types in each time the message is sent, e.g. {ask.semester}.
  Future<void> _insertAsk() async {
    final res = await _askDetail(
      title: 'Fill when sending',
      nameLabel: 'What is it called?',
      nameHelp: 'Small words, e.g. semester, paper, date. A box with this name appears every time you send this template.',
      exampleHelp: 'What it looks like, e.g. Semester 3. Meta reads this when it reviews the template.',
      exampleRequired: true,
    );
    if (res == null) return;
    var name = res.$1.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    if (name.length > 24) name = name.substring(0, 24);
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(name)) return _toast('The name must start with a letter (letters, numbers and _ only)');
    final existing = waAskNames([_headerText.text, _body.text, for (final b in _buttons) b.url.text]);
    if (!existing.contains(name) && existing.length >= 5) return _toast('At most 5 details can be filled when sending');
    _insert('ask.$name');
    _examples['ask.$name'] = res.$2;
  }

  Future<void> _pickHeaderFile() async {
    final exts = switch (_headerType) {
      'image' => ['jpg', 'jpeg', 'png'],
      'video' => ['mp4'],
      _ => ['pdf'],
    };
    try {
      final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: exts);
      if (file == null) return;
      setState(() => _busy = true);
      final bytes = await file.readAsBytes();
      final limit = _headerType == 'image' ? 5 : (_headerType == 'video' ? 16 : 100);
      if (bytes.length > limit * 1024 * 1024) {
        _toast('File is too big: ${_headerType == 'image' ? 'pictures' : _headerType == 'video' ? 'videos' : 'PDFs'} can be at most $limit MB');
        return;
      }
      final ext = file.name.split('.').last.toLowerCase();
      final mime = switch (ext) {
        'png' => 'image/png',
        'mp4' => 'video/mp4',
        'pdf' => 'application/pdf',
        _ => 'image/jpeg',
      };
      final path = await Repo.uploadWaMedia('tpl', file.name, bytes, mime);
      setState(() {
        _headerPath = path;
        _headerFile = file.name;
      });
    } catch (e) {
      _toast(errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Map<String, dynamic> _spec() {
    final header = <String, dynamic>{'type': _headerType};
    if (_headerType == 'text') header['text'] = _headerText.text.trim();
    if (_headerType == 'image' || _headerType == 'video' || _headerType == 'document') {
      header['media_path'] = _headerPath;
      header['filename'] = _headerFile;
    }
    if (_headerType == 'location') {
      header['latitude'] = double.tryParse(_lat.text.trim());
      header['longitude'] = double.tryParse(_lng.text.trim());
      header['name'] = _placeName.text.trim();
      header['address'] = _address.text.trim();
    }
    final buttons = [for (final b in _buttons) b.toJson()];
    // keep an example only while its detail is still used in the text
    final used = <String>{};
    final all = [if (_headerType == 'text') _headerText.text, _body.text, for (final b in buttons) if (b['type'] == 'url') '${b['url']}'];
    for (final t in all) {
      for (final m in RegExp(r'\{\s*([a-z_][a-z0-9_.]*)\s*\}', caseSensitive: false).allMatches(t)) {
        used.add(m.group(1)!.toLowerCase());
      }
    }
    return {
      'header': header,
      'body': _body.text.trim(),
      'footer': _footer.text.trim(),
      'buttons': buttons,
      'examples': {for (final e in _examples.entries) if (used.contains(e.key)) e.key: e.value},
    };
  }

  Future<void> _save({required bool submit}) async {
    final name = _name.text.trim();
    if (!RegExp(r'^[a-z0-9_]+$').hasMatch(name)) {
      return _toast('Template name: only small letters, numbers and _ (like course_details)');
    }
    if (_body.text.trim().isEmpty) return _toast('Write the message text');
    setState(() => _busy = true);
    try {
      final id = await Repo.saveWaTemplate(id: _t?.id, name: name, language: _language, category: _category, spec: _spec());
      if (submit) {
        await Repo.wa('submit_template', {'template_id': id});
        _toast('Sent to Meta. You will get a notification when it is approved.');
      } else {
        _toast('Saved');
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      final msg = errorText(e);
      _toast(msg.contains('duplicate key') ? 'You already have a template with this name and language' : msg);
      if (submit && mounted) {
        // It is saved even if Meta said no: say so and let them fix it.
        setState(() => _busy = false);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editAction(_Btn b) async {
    // Replies made after this screen opened should show up too.
    try {
      final fresh = await Repo.waNodes();
      if (mounted) setState(() => _nodes = fresh);
    } catch (_) {
      // keep the list we have
    }
    if (!mounted) return;
    final res = await showWaActionSheet(context, title: b.text.text.trim().isEmpty ? 'this button' : b.text.text.trim(), current: b.action, nodes: _nodes);
    if (res != null) setState(() => b.action = res);
  }

  void _addButton(String type) {
    final quick = _buttons.where((b) => b.type == 'quick_reply').length;
    if (_buttons.length >= 10) return _toast('At most 10 buttons');
    if (type == 'quick_reply' && quick >= 10) return;
    if (type == 'url' && _buttons.where((b) => b.type == 'url').length >= 2) return _toast('At most 2 link buttons');
    if (type == 'phone' && _buttons.any((b) => b.type == 'phone')) return _toast('Only 1 call button');
    if (type == 'copy_code' && _buttons.any((b) => b.type == 'copy_code')) return _toast('Only 1 copy-code button');
    setState(() => _buttons.add(_Btn(type)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5);
    final t = _t;

    return Scaffold(
      appBar: AppBar(title: Text(t == null ? 'New template' : 'Edit template')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (t != null && t.status != 'DRAFT')
            Card(
              color: scheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  t.status == 'APPROVED'
                      ? 'This template is approved. Changing the words sends it to Meta for review again (Meta allows only a few changes a month). '
                          'Changing what a button does needs no review: just tap Save.'
                      : 'Status: ${waStatusLabel(t.status)}. Change it and send it again.',
                ),
              ),
            ),
          const SizedBox(height: 8),
          TextField(
            controller: _name,
            enabled: _fresh,
            decoration: const InputDecoration(
              labelText: 'Template name',
              helperText: 'Small letters, numbers and _ only. Example: course_details',
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: _language,
                  decoration: const InputDecoration(labelText: 'Language'),
                  items: [for (final l in _languages) DropdownMenuItem(value: l.$1, child: Text(l.$2))],
                  onChanged: _fresh ? (v) => setState(() => _language = v ?? 'en') : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: _category,
                  decoration: const InputDecoration(labelText: 'Type'),
                  items: const [
                    DropdownMenuItem(value: 'MARKETING', child: Text('Marketing')),
                    DropdownMenuItem(value: 'UTILITY', child: Text('Utility')),
                  ],
                  onChanged: _fresh ? (v) => setState(() => _category = v ?? 'MARKETING') : null,
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Marketing: offers, course promotion. Utility: replying to an enquiry or confirming something. '
              'Meta may change the type if it does not match.',
              style: muted,
            ),
          ),
          const SizedBox(height: 20),
          Text('Heading (optional)', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: _headerType,
            decoration: const InputDecoration(labelText: 'Heading type'),
            items: const [
              DropdownMenuItem(value: 'none', child: Text('No heading')),
              DropdownMenuItem(value: 'text', child: Text('Text')),
              DropdownMenuItem(value: 'image', child: Text('Picture')),
              DropdownMenuItem(value: 'video', child: Text('Video')),
              DropdownMenuItem(value: 'document', child: Text('PDF file')),
              DropdownMenuItem(value: 'location', child: Text('Location')),
            ],
            onChanged: (v) => setState(() {
              _headerType = v ?? 'none';
              _headerPath = null;
              _headerFile = null;
            }),
          ),
          if (_headerType == 'text') ...[
            const SizedBox(height: 12),
            TextField(
              controller: _headerText,
              maxLength: 60,
              decoration: const InputDecoration(labelText: 'Heading text', helperText: 'Can have one {first_name}'),
            ),
          ],
          if (_headerType == 'image' || _headerType == 'video' || _headerType == 'document') ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _busy ? null : _pickHeaderFile,
              icon: const Icon(Icons.attach_file),
              label: Text(_headerFile ?? 'Choose ${_headerType == 'image' ? 'picture (JPG / PNG, up to 5 MB)' : _headerType == 'video' ? 'video (MP4, up to 16 MB)' : 'PDF'}'),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            ),
          ],
          if (_headerType == 'location') ...[
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: TextField(controller: _lat, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: const InputDecoration(labelText: 'Latitude'))),
              const SizedBox(width: 12),
              Expanded(child: TextField(controller: _lng, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: const InputDecoration(labelText: 'Longitude'))),
            ]),
            const SizedBox(height: 12),
            TextField(controller: _placeName, decoration: const InputDecoration(labelText: 'Place name')),
            const SizedBox(height: 12),
            TextField(controller: _address, decoration: const InputDecoration(labelText: 'Address')),
          ],
          const SizedBox(height: 20),
          Text('Message', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _body,
            minLines: 5,
            maxLines: 12,
            maxLength: 1024,
            decoration: const InputDecoration(
              hintText: 'Namaste {first_name}! Thank you for your interest in ...',
              alignLabelWithHint: true,
            ),
          ),
          Wrap(
            spacing: 6,
            children: [
              for (final d in _details) ActionChip(label: Text('+ ${d.$2}'), onPressed: () => _insert(d.$1)),
              ActionChip(label: const Text('+ Form detail'), onPressed: _insertCustom),
              ActionChip(
                avatar: const Icon(Icons.edit_note, size: 18),
                label: const Text('+ Fill when sending'),
                onPressed: _insertAsk,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '"Fill when sending" makes a box appear each time you send this template (for example the semester or paper). '
              'Such a template cannot be used for the automatic message.',
              style: muted,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _footer,
            maxLength: 60,
            decoration: const InputDecoration(labelText: 'Footer (optional)', helperText: 'Small grey text under the message'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: Text('Buttons (optional)', style: Theme.of(context).textTheme.titleSmall)),
              PopupMenuButton<String>(
                onSelected: _addButton,
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'quick_reply', child: Text('Quick reply (student taps, reply comes back)')),
                  PopupMenuItem(value: 'url', child: Text('Link (opens a website)')),
                  PopupMenuItem(value: 'phone', child: Text('Call button')),
                  PopupMenuItem(value: 'copy_code', child: Text('Copy code (offer code)')),
                ],
                child: const Chip(avatar: Icon(Icons.add, size: 18), label: Text('Add button')),
              ),
            ],
          ),
          for (var i = 0; i < _buttons.length; i++) _buttonCard(i, scheme),
          const SizedBox(height: 20),
          Text('Preview', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          _preview(scheme),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : () => _save(submit: false),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                  child: const Text('Save'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  onPressed: _busy ? null : () => _save(submit: true),
                  icon: _busy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.send),
                  label: const Text('Save & send to Meta'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buttonCard(int i, ColorScheme scheme) {
    final b = _buttons[i];
    final title = switch (b.type) {
      'quick_reply' => 'Quick reply',
      'url' => 'Link button',
      'phone' => 'Call button',
      _ => 'Copy code button',
    };
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700))),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _buttons.removeAt(i).dispose()),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Column(
                children: [
                  if (b.type != 'copy_code')
                    TextField(controller: b.text, maxLength: 25, decoration: const InputDecoration(labelText: 'Button text')),
                  if (b.type == 'url')
                    TextField(
                      controller: b.url,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: 'Website address',
                        helperText: 'Starts with https://  (you may end it with {first_name} or {phone})',
                      ),
                    ),
                  if (b.type == 'phone')
                    TextField(controller: b.phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone number', hintText: '+919876543210')),
                  if (b.type == 'copy_code')
                    TextField(controller: b.example, maxLength: 15, decoration: const InputDecoration(labelText: 'Code the student can copy', hintText: 'SAVE20')),
                  if (b.type == 'quick_reply') ...[
                    const SizedBox(height: 4),
                    InkWell(
                      onTap: () => _editAction(b),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          border: Border.all(color: scheme.outlineVariant),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.bolt, size: 18),
                            const SizedBox(width: 8),
                            Expanded(child: Text(waActionSummary(b.action, _nodes), style: const TextStyle(fontSize: 13))),
                            const Icon(Icons.chevron_right),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _preview(ColorScheme scheme) {
    final h = _headerType;
    final buttons = _buttons.where((b) => b.type == 'copy_code' || b.text.text.trim().isNotEmpty).toList();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: const Color(0xFFE6DDD4), borderRadius: BorderRadius.circular(12)),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (h == 'text' && _headerText.text.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(waFillSample(_headerText.text, examples: _examples), style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.black87)),
                      ),
                    if (h == 'image' || h == 'video' || h == 'document' || h == 'location')
                      Container(
                        height: 90,
                        margin: const EdgeInsets.only(bottom: 8),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(6)),
                        child: Text(
                          switch (h) {
                            'image' => '🖼  ${_headerFile ?? 'Picture'}',
                            'video' => '🎬  ${_headerFile ?? 'Video'}',
                            'document' => '📄  ${_headerFile ?? 'PDF'}',
                            _ => '📍  ${_placeName.text.isEmpty ? 'Location' : _placeName.text}',
                          },
                          style: const TextStyle(color: Colors.black87),
                        ),
                      ),
                    Text(
                      waFillSample(_body.text.isEmpty ? 'Your message appears here' : _body.text, examples: _examples),
                      style: const TextStyle(color: Colors.black87, height: 1.3),
                    ),
                    if (_footer.text.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(_footer.text, style: const TextStyle(color: Colors.black54, fontSize: 12)),
                      ),
                  ],
                ),
              ),
              for (final b in buttons)
                Container(
                  margin: const EdgeInsets.only(top: 3),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
                  child: Text(
                    switch (b.type) {
                      'url' => '🔗  ${b.text.text}',
                      'phone' => '📞  ${b.text.text}',
                      'copy_code' => '⧉  Copy code',
                      _ => b.text.text,
                    },
                    style: const TextStyle(color: Color(0xFF00A5F4), fontWeight: FontWeight.w600),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
