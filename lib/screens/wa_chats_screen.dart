import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import '../services/app_state.dart';
import '../services/repo.dart';
import '../widgets/contact_buttons.dart' show whatsappGreen;
import '../widgets/wa_widgets.dart';
import 'wa_chat_screen.dart';

/// WhatsApp inbox: every conversation, newest first. Agents see their own leads, the admin sees all.
class WaChatsScreen extends StatefulWidget {
  const WaChatsScreen({super.key});

  @override
  State<WaChatsScreen> createState() => _WaChatsScreenState();
}

class _WaChatsScreenState extends State<WaChatsScreen> {
  List<Lead>? _chats;
  String? _error;
  bool _unreadOnly = false;
  final _search = TextEditingController();
  Timer? _poll;
  Timer? _debounce;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _load);
    _load();
    _poll = Timer.periodic(const Duration(seconds: 10), (_) => _load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _debounce?.cancel();
    _lifecycle.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await Repo.waChats(unreadOnly: _unreadOnly, search: _search.text);
      if (mounted) {
        setState(() {
          _chats = list;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  Future<void> _open(Lead lead) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => WaChatScreen(lead: lead)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chats = _chats;
    final connected = AppState.instance.waConnected;
    return Scaffold(
      appBar: AppBar(title: const Text('WhatsApp chats'), actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)]),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: TextField(
              controller: _search,
              onChanged: (_) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 400), _load);
              },
              decoration: const InputDecoration(
                hintText: 'Search name or number',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                ChoiceChip(label: const Text('All'), selected: !_unreadOnly, onSelected: (_) => setState(() { _unreadOnly = false; _load(); })),
                const SizedBox(width: 8),
                ChoiceChip(label: const Text('Unread'), selected: _unreadOnly, onSelected: (_) => setState(() { _unreadOnly = true; _load(); })),
              ],
            ),
          ),
          Expanded(
            child: chats == null
                ? Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!))
                : RefreshIndicator(
                    onRefresh: _load,
                    child: chats.isEmpty
                        ? ListView(children: [
                            const SizedBox(height: 120),
                            Padding(
                              padding: const EdgeInsets.all(32),
                              child: Text(
                                connected
                                    ? (_unreadOnly ? 'No unread chats.' : 'No chats yet.\nOpen a lead and send a template, or wait for a student to reply.')
                                    : 'WhatsApp is not connected yet (More > WhatsApp).',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: scheme.onSurfaceVariant),
                              ),
                            ),
                          ])
                        : ListView.separated(
                            physics: const AlwaysScrollableScrollPhysics(),
                            itemCount: chats.length,
                            separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
                            itemBuilder: (_, i) => _tile(chats[i], scheme),
                          ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _tile(Lead l, ColorScheme scheme) {
    final unread = l.waUnread > 0;
    final at = l.waLastMessageAt;
    final out = l.waLastDirection == 'out';
    final ticks = out && l.waState != 'replied' && l.waState != 'none' ? l.waState : null;
    return ListTile(
      onTap: () => _open(l),
      leading: CircleAvatar(
        backgroundColor: unread ? whatsappGreen.withValues(alpha: 0.2) : null,
        child: Text(l.displayName.substring(0, 1).toUpperCase()),
      ),
      title: Text(l.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: unread ? FontWeight.w800 : FontWeight.w600)),
      subtitle: Row(
        children: [
          if (ticks != null) ...[WaTicks(ticks == 'queued' ? 'sent' : (ticks == 'failed' || ticks == 'no_whatsapp' ? 'failed' : ticks), size: 15), const SizedBox(width: 3)],
          Expanded(
            child: Text(
              l.waLastText ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: unread ? FontWeight.w600 : null),
            ),
          ),
        ],
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (at != null) Text(friendlyShort(at), style: TextStyle(fontSize: 12, color: unread ? whatsappGreen : scheme.onSurfaceVariant)),
          if (unread)
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(color: whatsappGreen, borderRadius: BorderRadius.circular(10)),
              child: Text('${l.waUnread}', style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w700)),
            ),
        ],
      ),
    );
  }
}

/// "10:42 AM", "Yesterday", "12 Oct"
String friendlyShort(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  if (day == today) return DateFormat('h:mm a').format(d);
  if (day == today.subtract(const Duration(days: 1))) return 'Yesterday';
  return DateFormat('d MMM').format(d);
}
