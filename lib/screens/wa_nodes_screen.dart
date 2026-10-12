import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models.dart';
import '../services/repo.dart';
import '../widgets/wa_widgets.dart';

String _kindLabel(String k) => switch (k) {
      'buttons' => 'Buttons',
      'list' => 'List',
      _ => 'Text',
    };

/// Admin: automatic replies. A button in a template (or in another reply) can send one of these.
/// They can also be sent by an agent as a "quick reply" inside a chat.
class WaNodesScreen extends StatefulWidget {
  const WaNodesScreen({super.key});

  @override
  State<WaNodesScreen> createState() => _WaNodesScreenState();
}

class _WaNodesScreenState extends State<WaNodesScreen> {
  List<WaNode>? _list;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await Repo.waNodes();
      if (mounted) setState(() => _list = list);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  Future<void> _edit([WaNode? n]) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => WaNodeEditor(existing: n, others: (_list ?? []).where((x) => x.id != n?.id).toList())),
    );
    if (changed == true) _load();
  }

  Future<void> _delete(WaNode n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete "${n.name}"?'),
        content: const Text('Buttons that send this reply will stop sending it.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Repo.deleteWaNode(n.id);
      _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final list = _list;
    return Scaffold(
      appBar: AppBar(title: const Text('Automatic replies')),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => _edit(), icon: const Icon(Icons.add), label: const Text('New reply')),
      body: list == null
          ? Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!))
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                  child: Text(
                    'When a student presses a button, they can get a reply at once: text, a PDF or picture, buttons, or a list to choose from. '
                    'Each button or list item can again move the lead to a status or Hot / Warm / Cold.',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
                if (list.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text('No replies yet.', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
                  ),
                for (final n in list)
                  Card(
                    child: ListTile(
                      onTap: () => _edit(n),
                      leading: CircleAvatar(
                        child: Icon(n.kind == 'list' ? Icons.list : (n.kind == 'buttons' ? Icons.smart_button : Icons.chat_bubble_outline)),
                      ),
                      title: Text(n.name),
                      subtitle: Text('${_kindLabel(n.kind)}${n.mediaPath != null ? ' + ${n.mediaType}' : ''}\n${waFillSample(n.body)}', maxLines: 3, overflow: TextOverflow.ellipsis),
                      isThreeLine: true,
                      trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _delete(n)),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _Row {
  final title = TextEditingController();
  final description = TextEditingController();
  Map<String, dynamic> action;

  _Row([Map<String, dynamic>? j]) : action = {...((j?['action'] as Map?)?.cast<String, dynamic>() ?? {})} {
    title.text = (j?['title'] as String?) ?? '';
    description.text = (j?['description'] as String?) ?? '';
  }

  Map<String, dynamic> toJson({bool withDescription = false}) => {
        'title': title.text.trim(),
        if (withDescription && description.text.trim().isNotEmpty) 'description': description.text.trim(),
        if (action.isNotEmpty) 'action': action,
      };

  void dispose() {
    title.dispose();
    description.dispose();
  }
}

class _Section {
  final title = TextEditingController();
  final List<_Row> rows;

  _Section(this.rows, [String t = '']) {
    title.text = t;
  }
}

class WaNodeEditor extends StatefulWidget {
  final WaNode? existing;

  /// The other replies (a button can lead to one of them).
  final List<WaNode> others;

  const WaNodeEditor({super.key, this.existing, required this.others});

  @override
  State<WaNodeEditor> createState() => _WaNodeEditorState();
}

class _WaNodeEditorState extends State<WaNodeEditor> {
  final _name = TextEditingController();
  final _header = TextEditingController();
  final _body = TextEditingController();
  final _footer = TextEditingController();
  final _listButton = TextEditingController(text: 'Choose');
  String _kind = 'text';
  String? _mediaPath;
  String? _mediaType;
  String? _mediaFile;
  final List<_Row> _buttons = [];
  final List<_Section> _sections = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final n = widget.existing;
    if (n != null) {
      _name.text = n.name;
      _kind = n.kind;
      _header.text = n.header ?? '';
      _body.text = n.body;
      _footer.text = n.footer ?? '';
      _listButton.text = n.listButton ?? 'Choose';
      _mediaPath = n.mediaPath;
      _mediaType = n.mediaType;
      _mediaFile = n.filename;
      for (final b in n.buttons) {
        _buttons.add(_Row(b));
      }
      for (final s in n.sections) {
        _sections.add(_Section([for (final r in (s['rows'] as List? ?? const [])) _Row((r as Map).cast<String, dynamic>())], (s['title'] as String?) ?? ''));
      }
    }
    if (_buttons.isEmpty) _buttons.add(_Row());
    if (_sections.isEmpty) _sections.add(_Section([_Row()], 'Options'));
  }

  @override
  void dispose() {
    for (final c in [_name, _header, _body, _footer, _listButton]) {
      c.dispose();
    }
    for (final b in _buttons) {
      b.dispose();
    }
    for (final s in _sections) {
      s.title.dispose();
      for (final r in s.rows) {
        r.dispose();
      }
    }
    super.dispose();
  }

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _pickMedia() async {
    try {
      final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['jpg', 'jpeg', 'png', 'mp4', 'pdf']);
      if (file == null) return;
      setState(() => _busy = true);
      final bytes = await file.readAsBytes();
      if (bytes.length > 15 * 1024 * 1024) {
        _toast('File is too big (up to 15 MB)');
        return;
      }
      final ext = file.name.split('.').last.toLowerCase();
      final (type, mime) = switch (ext) {
        'png' => ('image', 'image/png'),
        'jpg' || 'jpeg' => ('image', 'image/jpeg'),
        'mp4' => ('video', 'video/mp4'),
        _ => ('document', 'application/pdf'),
      };
      final path = await Repo.uploadWaMedia('reply', file.name, bytes, mime);
      setState(() {
        _mediaPath = path;
        _mediaType = type;
        _mediaFile = file.name;
      });
    } catch (e) {
      _toast(errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editAction(_Row r) async {
    final res = await showWaActionSheet(
      context,
      title: r.title.text.trim().isEmpty ? 'this item' : r.title.text.trim(),
      current: r.action,
      nodes: widget.others,
    );
    if (res != null) setState(() => r.action = res);
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) return _toast('Give this reply a name (only you see it)');
    if (_body.text.trim().isEmpty) return _toast('Write the message');
    final buttons = [for (final b in _buttons) if (b.title.text.trim().isNotEmpty) b.toJson()];
    final sections = [
      for (final s in _sections)
        {
          'title': s.title.text.trim(),
          'rows': [for (final r in s.rows) if (r.title.text.trim().isNotEmpty) r.toJson(withDescription: true)],
        },
    ].where((s) => (s['rows'] as List).isNotEmpty).toList();
    if (_kind == 'buttons' && buttons.isEmpty) return _toast('Add at least one button');
    if (_kind == 'list') {
      final total = sections.fold<int>(0, (n, s) => n + (s['rows'] as List).length);
      if (total == 0) return _toast('Add at least one list item');
      if (total > 10) return _toast('A list can have at most 10 items');
    }
    setState(() => _busy = true);
    try {
      await Repo.saveWaNode(widget.existing?.id, {
        'name': _name.text.trim(),
        'kind': _kind,
        'header': _header.text.trim().isEmpty ? null : _header.text.trim(),
        'body': _body.text.trim(),
        'footer': _footer.text.trim().isEmpty ? null : _footer.text.trim(),
        'media_path': _kind == 'list' ? null : _mediaPath,
        'media_type': _kind == 'list' ? null : _mediaType,
        'filename': _kind == 'list' ? null : _mediaFile,
        'buttons': _kind == 'buttons' ? buttons : [],
        'list_button': _kind == 'list' ? _listButton.text.trim() : null,
        'sections': _kind == 'list' ? sections : [],
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      _toast(errorText(e));
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _actionTile(_Row r) => InkWell(
        onTap: () => _editAction(r),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              const Icon(Icons.bolt, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(waActionSummary(r.action, widget.others), style: const TextStyle(fontSize: 13))),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12.5);
    return Scaffold(
      appBar: AppBar(title: Text(widget.existing == null ? 'New reply' : 'Edit reply')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name (only you see it)', hintText: 'Fees details')),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'text', label: Text('Text'), icon: Icon(Icons.chat_bubble_outline)),
              ButtonSegment(value: 'buttons', label: Text('Buttons'), icon: Icon(Icons.smart_button)),
              ButtonSegment(value: 'list', label: Text('List'), icon: Icon(Icons.list)),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() => _kind = s.first),
          ),
          const SizedBox(height: 6),
          Text(
            switch (_kind) {
              'buttons' => 'Up to 3 buttons under the message.',
              'list' => 'A "Choose" button opens a list of up to 10 items.',
              _ => 'A plain message. You can attach a PDF or picture.',
            },
            style: muted,
          ),
          if (_kind == 'buttons' || _kind == 'list') ...[
            const SizedBox(height: 12),
            TextField(controller: _header, maxLength: 60, decoration: const InputDecoration(labelText: 'Heading (optional)')),
          ],
          const SizedBox(height: 4),
          TextField(
            controller: _body,
            minLines: 4,
            maxLines: 10,
            maxLength: 1024,
            decoration: const InputDecoration(labelText: 'Message', helperText: 'You can use {first_name}, {name}, {agent_name}', alignLabelWithHint: true),
          ),
          if (_kind != 'text') ...[
            const SizedBox(height: 4),
            TextField(controller: _footer, maxLength: 60, decoration: const InputDecoration(labelText: 'Footer (optional)')),
          ],
          if (_kind != 'list') ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _pickMedia,
                    icon: const Icon(Icons.attach_file),
                    label: Text(_mediaFile ?? 'Attach picture / video / PDF', overflow: TextOverflow.ellipsis),
                  ),
                ),
                if (_mediaPath != null)
                  IconButton(
                    onPressed: () => setState(() {
                      _mediaPath = null;
                      _mediaType = null;
                      _mediaFile = null;
                    }),
                    icon: const Icon(Icons.close),
                  ),
              ],
            ),
          ],
          if (_kind == 'buttons') ...[
            const SizedBox(height: 16),
            Text('Buttons', style: Theme.of(context).textTheme.titleSmall),
            for (var i = 0; i < _buttons.length; i++)
              Card(
                margin: const EdgeInsets.only(top: 8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(child: TextField(controller: _buttons[i].title, maxLength: 20, decoration: InputDecoration(labelText: 'Button ${i + 1} text'))),
                          if (_buttons.length > 1)
                            IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _buttons.removeAt(i).dispose())),
                        ],
                      ),
                      _actionTile(_buttons[i]),
                    ],
                  ),
                ),
              ),
            if (_buttons.length < 3)
              TextButton.icon(onPressed: () => setState(() => _buttons.add(_Row())), icon: const Icon(Icons.add), label: const Text('Add button')),
          ],
          if (_kind == 'list') ...[
            const SizedBox(height: 8),
            TextField(controller: _listButton, maxLength: 20, decoration: const InputDecoration(labelText: 'Text on the list button', hintText: 'Choose')),
            for (var s = 0; s < _sections.length; s++)
              Card(
                margin: const EdgeInsets.only(top: 8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(child: TextField(controller: _sections[s].title, maxLength: 24, decoration: const InputDecoration(labelText: 'Group name'))),
                          if (_sections.length > 1)
                            IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _sections.removeAt(s))),
                        ],
                      ),
                      for (var r = 0; r < _sections[s].rows.length; r++)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Expanded(child: TextField(controller: _sections[s].rows[r].title, maxLength: 24, decoration: InputDecoration(labelText: 'Item ${r + 1}'))),
                                  IconButton(
                                    icon: const Icon(Icons.close),
                                    onPressed: () => setState(() => _sections[s].rows.removeAt(r).dispose()),
                                  ),
                                ],
                              ),
                              TextField(controller: _sections[s].rows[r].description, maxLength: 72, decoration: const InputDecoration(labelText: 'Small text under it (optional)')),
                              _actionTile(_sections[s].rows[r]),
                            ],
                          ),
                        ),
                      TextButton.icon(
                        onPressed: () => setState(() => _sections[s].rows.add(_Row())),
                        icon: const Icon(Icons.add),
                        label: const Text('Add item'),
                      ),
                    ],
                  ),
                ),
              ),
            TextButton.icon(
              onPressed: () => setState(() => _sections.add(_Section([_Row()]))),
              icon: const Icon(Icons.add),
              label: const Text('Add group'),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy ? null : _save,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
