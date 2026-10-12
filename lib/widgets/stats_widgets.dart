import 'package:flutter/material.dart';

/// Date ranges used by the dashboard and the leaderboard.
enum StatsRange { today, yesterday, week, month }

extension StatsRangeX on StatsRange {
  String get label => switch (this) {
        StatsRange.today => 'Today',
        StatsRange.yesterday => 'Yesterday',
        StatsRange.week => '7 days',
        StatsRange.month => 'This month',
      };

  (DateTime, DateTime) get bounds {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return switch (this) {
      StatsRange.today => (today, today.add(const Duration(days: 1))),
      StatsRange.yesterday => (today.subtract(const Duration(days: 1)), today),
      StatsRange.week => (today.subtract(const Duration(days: 6)), today.add(const Duration(days: 1))),
      StatsRange.month => (DateTime(now.year, now.month), today.add(const Duration(days: 1))),
    };
  }
}

class RangePicker extends StatelessWidget {
  final StatsRange value;
  final ValueChanged<StatsRange> onChanged;

  const RangePicker({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          for (final r in StatsRange.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(label: Text(r.label), selected: value == r, onSelected: (_) => onChanged(r)),
            ),
        ],
      ),
    );
  }
}

/// A headline number with its label.
class StatTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final String? note;
  final Color? noteColor;

  const StatTile({super.key, required this.label, required this.value, required this.icon, this.note, this.noteColor});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(label, style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(value, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700, height: 1.1)),
            if (note != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  note!,
                  style: TextStyle(fontSize: 12, color: noteColor ?? scheme.onSurfaceVariant, fontWeight: FontWeight.w600),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Horizontal bar with a label on the left and the value text on the right.
/// All bars in a list share one hue; length carries the magnitude.
class BarRow extends StatelessWidget {
  final String label;
  final String valueText;
  final double fraction;

  const BarRow({super.key, required this.label, required this.valueText, required this.fraction});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 8),
              Text(valueText, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5)),
            ],
          ),
          const SizedBox(height: 4),
          LayoutBuilder(
            builder: (context, c) => Stack(
              children: [
                Container(
                  height: 8,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                Container(
                  height: 8,
                  width: c.maxWidth * fraction.clamp(0.0, 1.0),
                  decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(4)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Progress towards a target, e.g. 32 / 50 calls. Green once reached.
class TargetBar extends StatelessWidget {
  final int done;
  final int? target;
  final String unit;

  const TargetBar({super.key, required this.done, required this.target, required this.unit});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = target;
    if (t == null || t == 0) {
      return Text('$done $unit · no target set', style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant));
    }
    final reached = done >= t;
    final color = reached ? Colors.green.shade700 : scheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('$done / $t $unit', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            if (reached) ...[
              const SizedBox(width: 6),
              Icon(Icons.check_circle, size: 16, color: color),
              Text(' Target done', style: TextStyle(fontSize: 12.5, color: color, fontWeight: FontWeight.w600)),
            ],
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: (done / t).clamp(0.0, 1.0),
            minHeight: 8,
            color: color,
            backgroundColor: scheme.surfaceContainerHighest,
          ),
        ),
      ],
    );
  }
}

String talkTime(int seconds) {
  if (seconds < 60) return '${seconds}s';
  final m = seconds ~/ 60;
  if (m < 60) return '${m}m';
  return '${m ~/ 60}h ${m % 60}m';
}

class SectionCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;

  const SectionCard({super.key, required this.title, this.subtitle, required this.child});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(subtitle!, style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}
