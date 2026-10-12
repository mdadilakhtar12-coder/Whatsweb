import 'package:flutter/material.dart';

import '../services/repo.dart';
import '../widgets/stats_widgets.dart';

/// Everyone: calls, talk time and admissions per person, ranked; with each person's target.
class LeaderboardScreen extends StatefulWidget {
  const LeaderboardScreen({super.key});

  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen> {
  StatsRange _range = StatsRange.today;
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String? _error;
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
      final rows = await Repo.leaderboard(from, to);
      if (!mounted) return;
      setState(() {
        _rows = rows;
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

  int get _days {
    final (from, to) = _range.bounds;
    final end = to.isAfter(DateTime.now()) ? DateTime.now() : to;
    return (end.difference(from).inHours / 24).ceil().clamp(1, 31);
  }

  @override
  Widget build(BuildContext context) {
    final me = currentUserId;
    int n(Object? v) => (v as num?)?.toInt() ?? 0;
    final scheme = Theme.of(context).colorScheme;
    final mine = _rows.where((r) => r['user_id'] == me).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Leaderboard')),
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
              child: _loading && _rows.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.only(bottom: 24),
                      children: [
                        if (_error != null) Padding(padding: const EdgeInsets.all(16), child: Text(_error!)),
                        if (mine.isNotEmpty)
                          SectionCard(
                            title: 'My progress · ${_range.label}',
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                TargetBar(
                                  done: n(mine.first['calls']),
                                  target: mine.first['daily_call_target'] == null
                                      ? null
                                      : n(mine.first['daily_call_target']) * _days,
                                  unit: 'calls',
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Connected ${n(mine.first['connected'])} · '
                                  'Talk ${talkTime(n(mine.first['talk_seconds']))} · '
                                  'Admissions ${n(mine.first['admissions'])}',
                                  style: TextStyle(color: scheme.onSurfaceVariant),
                                ),
                                if (_range == StatsRange.month && mine.first['monthly_admission_target'] != null) ...[
                                  const SizedBox(height: 8),
                                  TargetBar(
                                    done: n(mine.first['admissions']),
                                    target: n(mine.first['monthly_admission_target']),
                                    unit: 'admissions',
                                  ),
                                ],
                              ],
                            ),
                          ),
                        SectionCard(
                          title: 'Team ranking',
                          subtitle: 'By calls made',
                          child: Column(
                            children: [
                              for (final (i, r) in _rows.indexed)
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: CircleAvatar(
                                    backgroundColor: i < 3 ? const Color(0xFFFFF3C4) : scheme.surfaceContainerHighest,
                                    child: Text(i < 3 ? ['🥇', '🥈', '🥉'][i] : '${i + 1}'),
                                  ),
                                  title: Text(
                                    '${r['name']}${r['user_id'] == me ? ' (you)' : ''}',
                                    style: const TextStyle(fontWeight: FontWeight.w600),
                                  ),
                                  subtitle: Text(
                                    'Talk ${talkTime(n(r['talk_seconds']))} · Admissions ${n(r['admissions'])}',
                                  ),
                                  trailing: Text(
                                    '${n(r['calls'])} calls',
                                    style: const TextStyle(fontWeight: FontWeight.w700),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
