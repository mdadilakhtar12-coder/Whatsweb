import 'package:flutter/material.dart';

import '../models.dart';
import '../services/app_state.dart';

/// Reason chips (from the admin's list) plus "Other" with free text.
class ReasonChips extends StatefulWidget {
  final String? value;
  final ValueChanged<String?> onChanged;

  const ReasonChips({super.key, required this.value, required this.onChanged});

  @override
  State<ReasonChips> createState() => _ReasonChipsState();
}

class _ReasonChipsState extends State<ReasonChips> {
  late final List<String> _reasons = AppState.instance.lostReasons;
  late bool _other = widget.value != null && !_reasons.contains(widget.value);
  late final _text = TextEditingController(text: _other ? widget.value : '');

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final r in _reasons)
              ChoiceChip(
                label: Text(r),
                selected: !_other && widget.value == r,
                onSelected: (_) {
                  setState(() => _other = false);
                  widget.onChanged(r);
                },
              ),
            ChoiceChip(
              label: const Text('Other'),
              selected: _other,
              onSelected: (_) {
                setState(() => _other = true);
                widget.onChanged(_text.text.trim().isEmpty ? null : _text.text.trim());
              },
            ),
          ],
        ),
        if (_other)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextField(
              controller: _text,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Reason', isDense: true),
              onChanged: (v) => widget.onChanged(v.trim().isEmpty ? null : v.trim()),
            ),
          ),
      ],
    );
  }
}

/// Asks why (for statuses like "Not Interested"). Returns null if cancelled.
Future<String?> pickLostReason(BuildContext context, String status) {
  String? reason;
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$status — why?', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            ReasonChips(value: reason, onChanged: (v) => setState(() => reason = v)),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: reason == null ? null : () => Navigator.pop(context, reason),
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Hot / Warm / Cold chips; tapping the selected one clears it.
class TemperatureChips extends StatelessWidget {
  final String? value;
  final ValueChanged<String?> onChanged;

  const TemperatureChips({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      children: [
        for (final t in temperatures)
          ChoiceChip(
            label: Text(temperatureLabel(t)),
            selectedColor: temperatureColor(t).withValues(alpha: 0.2),
            selected: value == t,
            onSelected: (_) => onChanged(value == t ? null : t),
          ),
      ],
    );
  }
}
