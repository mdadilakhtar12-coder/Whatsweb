import 'package:flutter/material.dart';

import '../models.dart';
import '../services/repo.dart';

/// Dashboard: signups, purchases and money from the AIFM Education app. Hidden until the app sends its first event.
class AppxStatsCard extends StatefulWidget {
  final (DateTime, DateTime) bounds;

  const AppxStatsCard({super.key, required this.bounds});

  @override
  State<AppxStatsCard> createState() => _AppxStatsCardState();
}

class _AppxStatsCardState extends State<AppxStatsCard> {
  Map<String, dynamic>? _data;
  bool _any = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(AppxStatsCard old) {
    super.didUpdateWidget(old);
    if (old.bounds != widget.bounds) _load();
  }

  Future<void> _load() async {
    final (from, to) = widget.bounds;
    try {
      final overview = await Repo.appxOverview();
      final any = _n(overview['signups']) + _n(overview['purchases']) + _n(overview['events_24h']) > 0;
      final d = any ? await Repo.appxStats(from, to) : null;
      if (mounted) {
        setState(() {
          _any = any;
          _data = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  static int _n(Object? v) => (v as num?)?.toInt() ?? 0;
  static double _d(Object? v) => (v as num?)?.toDouble() ?? 0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final d = _data;
    if (_error != null || !_any || d == null) return const SizedBox.shrink();
    final items = ((d['items'] as List?) ?? const []).cast<Map>();
    final signups = _n(d['signups']);
    final bought = _n(d['purchases']);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('AIFM Education app', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _tile(context, 'Signups', '$signups', null)),
                const SizedBox(width: 8),
                Expanded(child: _tile(context, 'Bought', '$bought', null)),
                const SizedBox(width: 8),
                Expanded(child: _tile(context, 'Money', rupees(_d(d['revenue'])), 'after refunds')),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _tile(context, 'Payment cancelled', '${_n(d['cancelled'])}', null, warn: _n(d['cancelled']) > 0)),
                const SizedBox(width: 8),
                Expanded(child: _tile(context, 'Demo requests', '${_n(d['demos'])}', null)),
                const SizedBox(width: 8),
                Expanded(child: _tile(context, 'Refunded', rupees(_d(d['refunded'])), null)),
              ],
            ),
            if (items.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text('Each course', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              for (final c in items)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${c['item']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(
                        '${_n(c['purchases'])} bought · ${rupees(_d(c['revenue']))}',
                        style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, String label, String value, String? note, {bool warn = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700, color: warn ? scheme.error : null)),
          ),
          if (note != null) Text(note, style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
