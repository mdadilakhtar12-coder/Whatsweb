import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models.dart';
import '../services/contact_actions.dart';
import '../services/repo.dart';
import '../widgets/contact_buttons.dart' show whatsappGreen;
import '../widgets/wa_widgets.dart';
import 'lead_detail_screen.dart';

/// One WhatsApp conversation with a lead: messages in and out, with ticks.
/// Free-form messages work for 24 hours after the student writes; after that, send a template.
class WaChatScreen extends StatefulWidget {
  final Lead lead;

  const WaChatScreen({super.key, required this.lead});

  @override
  State<WaChatScreen> createState() => _WaChatScreenState();
}

class _WaChatScreenState extends State<WaChatScreen> {
  late Lead _lead = widget.lead;
  List<WaMessage> _msgs = [];
  final _text = TextEditingController();
  Timer? _poll;
  bool _loaded = false;
  bool _sending = false;
  String? _error;
  bool _marking = false;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => _load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _text.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait<Object?>([Repo.waMessages(_lead.id), Repo.lead(_lead.id)]);
      if (!mounted) return;
      final lead = (results[1] as Lead?) ?? _lead;
      setState(() {
        _msgs = results[0] as List<WaMessage>;
        _lead = lead;
        _loaded = true;
        _error = null;
      });
      if (lead.waUnread > 0 && !_marking) {
        _marking = true;
        Repo.wa('mark_read', {'lead_id': lead.id}).catchError((Object _) => <String, dynamic>{}).whenComplete(() => _marking = false);
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  /// Sends and shows Meta's answer (the server says why when it cannot).
  Future<bool> _send(Map<String, dynamic> body) async {
    setState(() => _sending = true);
    try {
      final res = await Repo.wa('send', {'lead_id': _lead.id, ...body});
      if (res['ok'] == false) {
        _toast('${res['error'] ?? 'Not sent'}');
        await _load();
        return false;
      }
      await _load();
      return true;
    } catch (e) {
      _toast(errorText(e));
      return false;
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendText() async {
    final text = _text.text.trim();
    if (text.isEmpty || _sending) return;
    if (await _send({'mode': 'text', 'text': text})) _text.clear();
  }

  Future<void> _attach() async {
    try {
      final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['jpg', 'jpeg', 'png', 'mp4', 'pdf', 'mp3', 'ogg']);
      if (file == null) return;
      setState(() => _sending = true);
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
        'mp3' => ('audio', 'audio/mpeg'),
        'ogg' => ('audio', 'audio/ogg'),
        _ => ('document', 'application/pdf'),
      };
      final path = await Repo.uploadWaMedia('out/${_lead.id}', file.name, bytes, mime);
      final caption = _text.text.trim();
      final ok = await _send({
        'mode': 'media',
        'path': path,
        'media_type': type,
        'filename': file.name,
        'mime': mime,
        if (caption.isNotEmpty) 'caption': caption,
      });
      if (ok) _text.clear();
    } catch (e) {
      _toast(errorText(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _pickTemplate() async {
    List<WaTemplate> list;
    try {
      list = (await Repo.waTemplates()).where((t) => t.approved).toList();
    } catch (e) {
      return _toast(errorText(e));
    }
    if (!mounted) return;
    final picked = await showModalBottomSheet<WaTemplate>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (context, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Text('Send a template', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('Only templates approved by Meta are listed.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            if (list.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('No approved template yet.')),
            for (final t in list)
              Card(
                child: ListTile(
                  title: Text(t.name),
                  subtitle: Text(waFillSample(t.body, examples: t.examples), maxLines: 3, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.pop(context, t),
                ),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    Map<String, String>? values;
    if (picked.askNames.isNotEmpty) {
      values = await showAskValuesDialog(context, picked);
      if (values == null) return;
    }
    await _send({'mode': 'template', 'template_id': picked.id, 'values': ?values});
  }

  Future<void> _pickReply() async {
    List<WaNode> list;
    try {
      list = await Repo.waNodes();
    } catch (e) {
      return _toast(errorText(e));
    }
    if (!mounted) return;
    final picked = await showModalBottomSheet<WaNode>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Text('Quick replies', style: Theme.of(context).textTheme.titleLarge),
            if (list.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('No automatic replies made yet (More > WhatsApp).')),
            for (final n in list)
              ListTile(
                leading: Icon(n.kind == 'list' ? Icons.list : (n.kind == 'buttons' ? Icons.smart_button : Icons.chat_bubble_outline)),
                title: Text(n.name),
                subtitle: Text(waFillSample(n.body), maxLines: 2, overflow: TextOverflow.ellipsis),
                onTap: () => Navigator.pop(context, n),
              ),
          ],
        ),
      ),
    );
    if (picked != null) await _send({'mode': 'reply', 'node_id': picked.id});
  }

  void _plus() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('Picture, PDF or video'),
              onTap: () {
                Navigator.pop(context);
                _attach();
              },
            ),
            ListTile(
              leading: const Icon(Icons.flash_on),
              title: const Text('Quick reply'),
              subtitle: const Text('Ready-made messages with buttons or lists'),
              onTap: () {
                Navigator.pop(context);
                _pickReply();
              },
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Template'),
              onTap: () {
                Navigator.pop(context);
                _pickTemplate();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final left = _lead.waWindowLeft;
    final open = left != null;
    final rev = _msgs.reversed.toList();

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => LeadDetailScreen(leadId: _lead.id, initial: _lead))),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_lead.displayName, style: const TextStyle(fontSize: 17), overflow: TextOverflow.ellipsis),
              Text(_lead.phone ?? '', style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Call',
            icon: const Icon(Icons.call),
            onPressed: _lead.hasPhone ? () => ContactActions.call(context, _lead, onUpdated: _load) : null,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_lead.waOptOut)
            _banner(Colors.red.shade50, Colors.red.shade900, Icons.block, 'This student asked to stop WhatsApp messages. Only reply if they write again.')
          else if (open)
            _banner(Colors.green.shade50, Colors.green.shade900, Icons.timer_outlined, 'You can reply freely: ${_left(left)} left')
          else
            _banner(Colors.orange.shade50, Colors.orange.shade900, Icons.lock_clock,
                'More than 24 hours since the student wrote. Send a template to start the chat again.'),
          Expanded(
            child: !_loaded
                ? Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!))
                : _msgs.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text('No messages yet.\nSend a template to start.', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
                        ),
                      )
                    : ListView.builder(
                        reverse: true,
                        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                        itemCount: rev.length,
                        itemBuilder: (_, i) {
                          final m = rev[i];
                          final older = i + 1 < rev.length ? rev[i + 1] : null;
                          final newDay = older == null || !_sameDay(older.createdAt, m.createdAt);
                          return Column(
                            children: [
                              if (newDay) _dayChip(m.createdAt),
                              _Bubble(m),
                            ],
                          );
                        },
                      ),
          ),
          _composer(open, scheme),
        ],
      ),
    );
  }

  Widget _banner(Color bg, Color fg, IconData icon, String text) => Container(
        width: double.infinity,
        color: bg,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 18, color: fg),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: TextStyle(color: fg, fontSize: 12.5))),
          ],
        ),
      );

  Widget _composer(bool open, ColorScheme scheme) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
        decoration: BoxDecoration(color: scheme.surface, border: Border(top: BorderSide(color: scheme.outlineVariant))),
        child: open
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(onPressed: _sending ? null : _plus, icon: const Icon(Icons.add_circle_outline)),
                  Expanded(
                    child: TextField(
                      controller: _text,
                      minLines: 1,
                      maxLines: 5,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: 'Message',
                        isDense: true,
                        filled: true,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  _sending
                      ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))
                      : IconButton.filled(
                          style: IconButton.styleFrom(backgroundColor: whatsappGreen),
                          onPressed: _sendText,
                          icon: const Icon(Icons.send),
                        ),
                ],
              )
            : Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _sending || _lead.waOptOut ? null : _pickTemplate,
                      icon: _sending
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.description_outlined),
                      label: const Text('Send a template'),
                      style: FilledButton.styleFrom(backgroundColor: whatsappGreen, minimumSize: const Size.fromHeight(48)),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  static bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  static String _left(Duration d) => d.inHours >= 1 ? '${d.inHours}h ${d.inMinutes % 60}m' : '${d.inMinutes}m';

  Widget _dayChip(DateTime d) {
    final now = DateTime.now();
    final label = _sameDay(d, now)
        ? 'Today'
        : _sameDay(d, now.subtract(const Duration(days: 1)))
            ? 'Yesterday'
            : DateFormat('d MMM yyyy').format(d);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(12)),
        child: Text(label, style: const TextStyle(fontSize: 12)),
      ),
    );
  }
}

String _kindLabel(WaMessage m) => m.byAiAssistant ? 'Sent by AI assistant' : switch (m.kind) {
      'auto' => 'Automatic',
      'followup' => 'Follow-up',
      'nudge' => 'Reminder',
      'broadcast' => 'Broadcast',
      'bot' => 'Auto reply',
      _ => '',
    };

class _Bubble extends StatelessWidget {
  final WaMessage m;

  const _Bubble(this.m);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final out = m.outgoing;
    final label = out ? _kindLabel(m) : '';
    final media = m.mediaPath != null;
    return Align(
      alignment: out ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.8),
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.fromLTRB(10, 7, 10, 5),
        decoration: BoxDecoration(
          color: out ? scheme.primaryContainer : scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (m.templateName != null || label.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  [if (label.isNotEmpty) label, if (m.templateName != null) 'Template: ${m.templateName}'].join(' · '),
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600),
                ),
              ),
            if (media) _Media(m),
            if (m.body.isNotEmpty) Text(m.body),
            if (!media && m.body.isEmpty) Text(_placeholder(m), style: TextStyle(color: scheme.onSurfaceVariant, fontStyle: FontStyle.italic)),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(DateFormat('h:mm a').format(m.createdAt), style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant)),
                if (out) ...[const SizedBox(width: 4), WaTicks(m.status, size: 15)],
              ],
            ),
            if (m.status == 'failed' && m.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(m.error!, style: TextStyle(fontSize: 12, color: Colors.red.shade700)),
              ),
          ],
        ),
      ),
    );
  }

  static String _placeholder(WaMessage m) => switch (m.type) {
        'image' => '🖼 Photo',
        'video' => '🎬 Video',
        'audio' => '🎤 Voice message',
        'document' => '📄 ${m.filename ?? 'Document'}',
        'sticker' => 'Sticker',
        _ => '(empty)',
      };
}

final _urlCache = <String, ({String url, DateTime at})>{};

Future<String> _signed(String path) async {
  final hit = _urlCache[path];
  if (hit != null && DateTime.now().difference(hit.at) < const Duration(minutes: 40)) return hit.url;
  final url = await Repo.waMediaUrl(path);
  _urlCache[path] = (url: url, at: DateTime.now());
  return url;
}

/// A picture is shown in the chat; other files open in the phone's viewer when tapped.
class _Media extends StatelessWidget {
  final WaMessage m;

  const _Media(this.m);

  @override
  Widget build(BuildContext context) {
    final path = m.mediaPath!;
    if (m.type == 'image' || m.type == 'sticker') {
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: FutureBuilder<String>(
          future: _signed(path),
          builder: (context, snap) {
            if (!snap.hasData) return const SizedBox(height: 120, width: 160, child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
            return GestureDetector(
              onTap: () => launchUrl(Uri.parse(snap.data!), mode: LaunchMode.externalApplication),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(snap.data!, width: 220, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Text('🖼 Photo (could not load)')),
              ),
            );
          },
        ),
      );
    }
    final (icon, label) = switch (m.type) {
      'video' => (Icons.play_circle_outline, 'Video'),
      'audio' => (Icons.mic_none, 'Voice message'),
      _ => (Icons.insert_drive_file_outlined, m.filename ?? 'Document'),
    };
    return InkWell(
      onTap: () async {
        final url = await _signed(path);
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      },
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28),
            const SizedBox(width: 8),
            Flexible(child: Text(label, style: const TextStyle(decoration: TextDecoration.underline))),
          ],
        ),
      ),
    );
  }
}
