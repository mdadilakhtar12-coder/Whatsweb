import 'package:flutter/material.dart';

import '../services/repo.dart';
import 'stats_widgets.dart';

/// WhatsApp numbers: how many messages went, were delivered, opened and answered.
class WaStatsCard extends StatefulWidget {
  /// Fixed dates (the dashboard passes its own range); without them the card has its own range chips.
  final (DateTime, DateTime)? bounds;

  const WaStatsCard({super.key, this.bounds});

  @override
  State<WaStatsCard> createState() => _WaStatsCardState();
}

class _WaStatsCardState extends State<WaStatsCard> {
  StatsRange _range = StatsRange.week;
  Map<String, dynamic>? _data;
  String? _error;

  (DateTime, DateTime) get _bounds => widget.bounds ?? _range.bounds;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(WaStatsCard old) {
    super.didUpdateWidget(old);
    if (old.bounds != widget.bounds) _load();
  }

  Future<void> _load() async {
    final (from, to) = _bounds;
    try {
      final d = await Repo.waStats(from, to);
      if (mounted) {
        setState(() {
          _data = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  static int _n(Object? v) => (v as num?)?.toInt() ?? 0;

  static String _pct(num part, num whole) => whole <= 0 ? '–' : '${(part * 100 / whole).round()}%';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final d = _data;
    final t = (d?['totals'] as Map?)?.cast<String, dynamic>() ?? const {};
    final sent = _n(t['sent']);
    final delivered = _n(t['delivered']);
    final read = _n(t['read']);
    final kinds = ((d?['kinds'] as List?) ?? const []).cast<Map>();
    final templates = ((d?['templates'] as List?) ?? const []).cast<Map>();
    const kindNames = {'auto': 'Welcome message', 'followup': 'Follow-ups', 'nudge': 'Reminders (not paid)', 'broadcast': 'Broadcasts', 'manual': 'By agents', 'bot': 'Auto replies'};

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('WhatsApp', style: Theme.of(context).textTheme.titleMedium),
            if (widget.bounds == null)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final r in StatsRange.values)
                      Padding(
                        padding: const EdgeInsets.only(right: 8, top: 6),
                        child: ChoiceChip(
                          label: Text(r.label),
                          selected: _range == r,
                          onSelected: (_) {
                            setState(() => _range = r);
                            _load();
                          },
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 10),
            if (_error != null)
              Text(_error!, style: TextStyle(color: scheme.error))
            else if (d == null)
              const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))
            else ...[
              Row(
                children: [
                  Expanded(child: _tile('Sent', '$sent', null)),
                  const SizedBox(width: 8),
                  Expanded(child: _tile('Delivered', _pct(delivered, sent), '$delivered')),
                  const SizedBox(width: 8),
                  Expanded(child: _tile('Opened', _pct(read, sent), '$read')),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: _tile('Replied', '${_n(t['replied_leads'])}', 'students')),
                  const SizedBox(width: 8),
                  Expanded(child: _tile('Not delivered', '${_n(t['failed'])}', null, warn: _n(t['failed']) > 0)),
                  const SizedBox(width: 8),
                  Expanded(child: _tile('Replies got', '${_n(t['inbound'])}', 'messages')),
                ],
              ),
              if (kinds.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text('Which messages', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 4),
                for (final k in kinds)
                  _line(kindNames['${k['kind']}'] ?? '${k['kind']}', _n(k['sent']), _n(k['delivered']), _n(k['read']), _n(k['failed'])),
              ],
              if (templates.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text('Templates', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 4),
                for (final tp in templates)
                  _line('${tp['name']}', _n(tp['sent']), _n(tp['delivered']), _n(tp['read']), _n(tp['failed']), replied: _n(tp['replied'])),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _tile(String label, String value, String? note, {bool warn = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700, color: warn ? scheme.error : null)),
          if (note != null) Text(note, style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _line(String name, int sent, int delivered, int read, int failed, {int? replied}) {
    final muted = TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(
            '$sent sent · ${_pct(delivered, sent)} delivered · ${_pct(read, sent)} opened'
            '${replied != null ? ' · ${_pct(replied, sent)} replied' : ''}'
            '${failed > 0 ? ' · $failed failed' : ''}',
            style: muted,
          ),
        ],
      ),
    );
  }
}
