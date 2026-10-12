import 'package:flutter/material.dart';

import '../models.dart';
import '../services/repo.dart';

/// Dashboard: registered, paid, money and attendance from Webinar.gg. Hidden until the first student arrives.
class WebinarStatsCard extends StatefulWidget {
  final (DateTime, DateTime) bounds;

  const WebinarStatsCard({super.key, required this.bounds});

  @override
  State<WebinarStatsCard> createState() => _WebinarStatsCardState();
}

class _WebinarStatsCardState extends State<WebinarStatsCard> {
  Map<String, dynamic>? _data;
  bool _any = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(WebinarStatsCard old) {
    super.didUpdateWidget(old);
    if (old.bounds != widget.bounds) _load();
  }

  Future<void> _load() async {
    final (from, to) = widget.bounds;
    try {
      final overview = await Repo.webinarOverview();
      final any = ((overview['registrations'] as num?) ?? 0) > 0;
      final d = any ? await Repo.webinarStats(from, to) : null;
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
    if (_error != null) return const SizedBox.shrink();
    final d = _data;
    if (!_any || d == null) return const SizedBox.shrink();
    final webinars = ((d['webinars'] as List?) ?? const []).cast<Map>();
    final registered = _n(d['registered']);
    final paid = _n(d['paid']);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Webinar', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _tile(context, 'Registered', '$registered', null)),
                const SizedBox(width: 8),
                Expanded(child: _tile(context, 'Paid', '$paid', registered > 0 ? '${(paid * 100 / registered).round()}% of registered' : null)),
                const SizedBox(width: 8),
                Expanded(child: _tile(context, 'Money', rupees(_d(d['revenue'])), 'after refunds')),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _tile(context, 'Attended', '${_n(d['attended'])}', null)),
                const SizedBox(width: 8),
                Expanded(child: _tile(context, 'Did not attend', '${_n(d['missed'])}', null)),
                const SizedBox(width: 8),
                Expanded(child: _tile(context, 'Payment failed', '${_n(d['failed'])}', _d(d['refunded']) > 0 ? '${rupees(_d(d['refunded']))} refunded' : null, warn: _n(d['failed']) > 0)),
              ],
            ),
            if (webinars.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text('Each webinar', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              for (final w in webinars)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${w['title'] ?? w['webinar_id'] ?? 'Webinar'}', style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(
                        '${_n(w['registered'])} registered · ${_n(w['paid'])} paid · ${rupees(_d(w['revenue']))}'
                        '${_n(w['attended']) > 0 ? ' · ${_n(w['attended'])} attended' : ''}',
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
