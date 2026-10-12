import 'package:flutter/material.dart';

import '../models.dart';
import '../services/app_state.dart';
import '../services/repo.dart';
import '../widgets/stats_widgets.dart';
import '../widgets/wa_stats_card.dart';
import '../widgets/appx_stats_card.dart';
import '../widgets/webinar_stats_card.dart';

/// Admin: what the team did and which ads bring admissions.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  StatsRange _range = StatsRange.today;
  Map<String, dynamic>? _data;
  String? _error;
  bool _loading = true;
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
    final (from, to) = _range.bounds;
    try {
      final data = await Repo.dashboard(from, to);
      if (!mounted) return;
      setState(() {
        _data = data;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = errorText(e);
          _loading = false;
        });
      }
    }
  }

  /// Days covered by the range so far (daily targets add up).
  int get _days {
    final (from, to) = _range.bounds;
    final end = to.isAfter(DateTime.now()) ? DateTime.now() : to;
    return (end.difference(from).inHours / 24).ceil().clamp(1, 31);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dashboard')),
      body: Column(
        children: [
          RangePicker(
            value: _range,
            onChanged: (r) {
              setState(() {
                _range = r;
                _loading = true;
              });
              _load();
            },
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: _loading && _data == null
                  ? const Center(child: CircularProgressIndicator())
                  : _body(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    final data = _data;
    if (data == null) {
      return ListView(children: [Padding(padding: const EdgeInsets.all(24), child: Text(_error ?? ''))]);
    }
    final totals = (data['totals'] as Map).cast<String, dynamic>();
    final agents = (data['agents'] as List).cast<Map>();
    final sources = (data['sources'] as List).cast<Map>();
    final campaigns = (data['campaigns'] as List).cast<Map>();
    final reasons = (data['lost_reasons'] as List).cast<Map>();
    int n(Object? v) => (v as num?)?.toInt() ?? 0;
    final calls = n(totals['calls']);
    final notCalled = n(totals['not_called']);
    final unassigned = n(totals['unassigned']);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(
            children: [
              _tileRow(
                StatTile(label: 'New leads', value: '${n(totals['new_leads'])}', icon: Icons.person_add_alt),
                StatTile(label: 'Calls made', value: '$calls', icon: Icons.call_outlined),
              ),
              const SizedBox(height: 8),
              _tileRow(
                StatTile(label: 'Admissions', value: '${n(totals['admissions'])}', icon: Icons.school_outlined),
                StatTile(
                  label: 'Not called yet (now)',
                  value: '$notCalled',
                  icon: Icons.timer_outlined,
                  note: unassigned > 0 ? '$unassigned unassigned' : null,
                  noteColor: Colors.orange.shade800,
                ),
              ),
            ],
          ),
        ),
        if (AppState.instance.waConnected)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: WaStatsCard(bounds: _range.bounds),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: WebinarStatsCard(bounds: _range.bounds),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: AppxStatsCard(bounds: _range.bounds),
        ),
        const SizedBox(height: 6),
        SectionCard(
          title: 'Team',
          subtitle: 'Calls come from each phone\'s call log',
          child: Column(
            children: [
              for (final a in agents) ...[
                _AgentRow(agent: a.cast<String, dynamic>(), days: _days, showAdmissionTarget: _range == StatsRange.month),
                if (a != agents.last) const Divider(height: 20),
              ],
            ],
          ),
        ),
        if (sources.isNotEmpty)
          SectionCard(
            title: 'Where leads come from',
            subtitle: 'Leads that came in during ${_range.label.toLowerCase()} and how many joined',
            child: _bars(sources, (m) => sourceLabel('${m['source']}')),
          ),
        if (campaigns.isNotEmpty)
          SectionCard(
            title: 'Campaigns / forms',
            subtitle: 'Which ad or form brings admissions',
            child: _bars(campaigns, (m) => '${m['campaign']}'),
          ),
        if (reasons.isNotEmpty)
          SectionCard(
            title: 'Why leads didn\'t join',
            child: Builder(builder: (context) {
              final max = reasons.map((r) => n(r['count'])).fold(1, (a, b) => a > b ? a : b);
              return Column(
                children: [
                  for (final r in reasons)
                    BarRow(label: '${r['reason']}', valueText: '${n(r['count'])}', fraction: n(r['count']) / max),
                ],
              );
            }),
          ),
      ],
    );
  }

  /// Two tiles side by side, same height.
  Widget _tileRow(Widget a, Widget b) => IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [Expanded(child: a), const SizedBox(width: 8), Expanded(child: b)],
        ),
      );

  Widget _bars(List<Map> rows, String Function(Map) label) {
    int n(Object? v) => (v as num?)?.toInt() ?? 0;
    final max = rows.map((r) => n(r['leads'])).fold(1, (a, b) => a > b ? a : b);
    return Column(
      children: [
        for (final r in rows)
          BarRow(
            label: label(r),
            valueText: '${n(r['leads'])} leads · ${n(r['admissions'])} joined'
                '${n(r['leads']) > 0 ? ' (${(100 * n(r['admissions']) / n(r['leads'])).round()}%)' : ''}',
            fraction: n(r['leads']) / max,
          ),
      ],
    );
  }
}

class _AgentRow extends StatelessWidget {
  final Map<String, dynamic> agent;
  final int days;
  final bool showAdmissionTarget;

  const _AgentRow({required this.agent, required this.days, required this.showAdmissionTarget});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    int n(Object? v) => (v as num?)?.toInt() ?? 0;
    final dailyTarget = (agent['daily_call_target'] as num?)?.toInt();
    final notCalled = n(agent['not_called']);
    final overdue = n(agent['overdue_followups']);
    final muted = TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant);

    Widget warn(IconData icon, String text, Color color) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 3),
            Text(text, style: TextStyle(fontSize: 12.5, color: color, fontWeight: FontWeight.w600)),
          ],
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${agent['name']}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
        const SizedBox(height: 6),
        TargetBar(done: n(agent['calls']), target: dailyTarget == null ? null : dailyTarget * days, unit: 'calls'),
        const SizedBox(height: 6),
        Text(
          'Connected ${n(agent['connected'])} · Talk ${talkTime(n(agent['talk_seconds']))} · '
          'Messages ${n(agent['messages'])} · Admissions ${n(agent['admissions'])}',
          style: muted,
        ),
        Text('${n(agent['open_leads'])} leads assigned', style: muted),
        if (notCalled > 0 || overdue > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(
              spacing: 12,
              children: [
                if (notCalled > 0) warn(Icons.timer_outlined, '$notCalled not called', Colors.orange.shade800),
                if (overdue > 0) warn(Icons.alarm, '$overdue overdue follow-ups', Colors.red.shade700),
              ],
            ),
          ),
        if (showAdmissionTarget && agent['monthly_admission_target'] != null) ...[
          const SizedBox(height: 6),
          TargetBar(
            done: n(agent['admissions']),
            target: (agent['monthly_admission_target'] as num?)?.toInt(),
            unit: 'admissions this month',
          ),
        ],
      ],
    );
  }
}
