import 'package:flutter/material.dart';

import '../models.dart';
import '../services/app_state.dart';
import '../services/lead_ops.dart';
import '../services/notifications.dart';
import '../services/repo.dart';
import '../widgets/contact_buttons.dart';
import '../widgets/status_chip.dart';
import 'lead_detail_screen.dart';

class FollowUpsScreen extends StatefulWidget {
  const FollowUpsScreen({super.key});

  @override
  State<FollowUpsScreen> createState() => _FollowUpsScreenState();
}

class _FollowUpsScreenState extends State<FollowUpsScreen> {
  List<Reminder> _items = [];
  bool _loading = true;
  String? _error;
  bool _everyone = false;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _load);
    _load();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final items = await Repo.openReminders(userId: _everyone ? null : currentUserId);
      if (!mounted) return;
      setState(() {
        _items = items;
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

  Future<void> _done(Reminder r) async {
    try {
      await LeadOps.completeReminder(r);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(e))));
    }
    await _load();
  }

  Future<void> _open(Reminder r) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => LeadDetailScreen(leadId: r.leadId, initial: r.lead)),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final endOfToday = DateTime(now.year, now.month, now.day + 1);
    final overdue = _items.where((r) => r.remindAt.isBefore(now)).toList();
    final today = _items.where((r) => !r.remindAt.isBefore(now) && r.remindAt.isBefore(endOfToday)).toList();
    final later = _items.where((r) => !r.remindAt.isBefore(endOfToday)).toList();
    final admin = AppState.instance.isAdmin;

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Follow-ups'),
          actions: [
            if (admin)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: SegmentedButton<bool>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  segments: const [
                    ButtonSegment(value: false, label: Text('Mine')),
                    ButtonSegment(value: true, label: Text('Team')),
                  ],
                  selected: {_everyone},
                  onSelectionChanged: (s) {
                    setState(() {
                      _everyone = s.first;
                      _loading = true;
                    });
                    _load();
                  },
                ),
              ),
          ],
          bottom: TabBar(
            tabs: [
              Tab(text: 'Overdue (${overdue.length})'),
              Tab(text: 'Today (${today.length})'),
              Tab(text: 'Upcoming (${later.length})'),
            ],
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [
                  _list(overdue, 'Nothing overdue 🎉'),
                  _list(today, 'No follow-ups left for today'),
                  _list(later, 'No upcoming follow-ups'),
                ],
              ),
      ),
    );
  }

  Widget _list(List<Reminder> items, String empty) {
    return RefreshIndicator(
      onRefresh: _load,
      child: items.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SizedBox(height: 120),
                Center(
                  child: Text(
                    _error ?? empty,
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            )
          : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(vertical: 6),
              itemCount: items.length,
              itemBuilder: (_, i) => _tile(items[i]),
            ),
    );
  }

  Widget _tile(Reminder r) {
    final lead = r.lead!;
    final scheme = Theme.of(context).colorScheme;
    final color = followUpColor(context, r.remindAt);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _open(r),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.alarm, size: 18, color: color),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(friendlyTime(r.remindAt), style: TextStyle(color: color, fontWeight: FontWeight.w700)),
                  ),
                  IconButton(
                    tooltip: 'Mark done',
                    icon: const Icon(Icons.check_circle_outline),
                    onPressed: () => _done(r),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(lead.displayName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    ),
                    StatusChip(lead.status, dense: true),
                  ],
                ),
              ),
              if ((r.note ?? '').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4, right: 8),
                  child: Text(r.note!, style: TextStyle(color: scheme.onSurfaceVariant)),
                ),
              if (_everyone)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'For ${AppState.instance.memberName(r.userId)}',
                    style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                  ),
                ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ContactButtons(lead: lead, onUpdated: _load),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
