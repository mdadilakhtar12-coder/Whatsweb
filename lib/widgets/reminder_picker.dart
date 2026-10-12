import 'package:flutter/material.dart';

import '../services/notifications.dart';

typedef ReminderChoice = ({DateTime at, String note});

/// Quick choices for a follow-up time. Returns null if cancelled.
Future<ReminderChoice?> pickReminder(BuildContext context, {String? title}) {
  return showModalBottomSheet<ReminderChoice>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ReminderSheet(title: title),
  );
}

List<(String, DateTime)> quickTimes() {
  final now = DateTime.now();
  DateTime at(int addDays, int hour) => DateTime(now.year, now.month, now.day + addDays, hour);
  return [
    ('In 1 hour', now.add(const Duration(hours: 1))),
    if (now.hour < 17) ('This evening', at(0, 18)),
    ('Tomorrow morning', at(1, 10)),
    ('Tomorrow evening', at(1, 17)),
    ('In 2 days', at(2, 11)),
    ('Next week', at(7, 11)),
  ];
}

Future<DateTime?> pickDateTime(BuildContext context, {DateTime? initial}) async {
  final now = DateTime.now();
  final start = initial ?? now.add(const Duration(days: 1));
  final date = await showDatePicker(
    context: context,
    initialDate: start,
    firstDate: DateTime(now.year, now.month, now.day),
    lastDate: now.add(const Duration(days: 730)),
  );
  if (date == null || !context.mounted) return null;
  final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(start));
  if (time == null) return null;
  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

class _ReminderSheet extends StatefulWidget {
  final String? title;

  const _ReminderSheet({this.title});

  @override
  State<_ReminderSheet> createState() => _ReminderSheetState();
}

class _ReminderSheetState extends State<_ReminderSheet> {
  DateTime? _at;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.title ?? 'Set follow-up reminder', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          ReminderTimeChips(value: _at, onChanged: (v) => setState(() => _at = v)),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            decoration: const InputDecoration(
              labelText: 'Note (optional)',
              hintText: 'e.g. Wants to buy the course after 2 days',
              border: OutlineInputBorder(),
            ),
            maxLines: 2,
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: const Icon(Icons.alarm_add),
              label: Text(_at == null ? 'Choose a time' : 'Set for ${friendlyTime(_at!)}'),
              onPressed: _at == null ? null : () => Navigator.pop(context, (at: _at!, note: _note.text.trim())),
            ),
          ),
        ],
      ),
    );
  }
}

/// Row of quick time chips + "Pick date & time".
class ReminderTimeChips extends StatefulWidget {
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final bool allowNone;

  const ReminderTimeChips({super.key, required this.value, required this.onChanged, this.allowNone = false});

  @override
  State<ReminderTimeChips> createState() => _ReminderTimeChipsState();
}

class _ReminderTimeChipsState extends State<ReminderTimeChips> {
  // Worked out once, so "In 1 hour" keeps the same value while the sheet is open.
  final _quick = quickTimes();

  @override
  Widget build(BuildContext context) {
    final value = widget.value;
    final isQuick = _quick.any((q) => q.$2 == value);
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        if (widget.allowNone)
          ChoiceChip(
            label: const Text('No reminder'),
            selected: value == null,
            onSelected: (_) => widget.onChanged(null),
          ),
        for (final q in _quick)
          ChoiceChip(label: Text(q.$1), selected: value == q.$2, onSelected: (_) => widget.onChanged(q.$2)),
        ChoiceChip(
          avatar: const Icon(Icons.calendar_month, size: 18),
          label: Text(value != null && !isQuick ? friendlyTime(value) : 'Pick date & time'),
          selected: value != null && !isQuick,
          onSelected: (_) async {
            final picked = await pickDateTime(context, initial: value);
            if (picked != null) widget.onChanged(picked);
          },
        ),
      ],
    );
  }
}
