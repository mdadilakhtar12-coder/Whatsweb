import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import '../services/app_state.dart';
import '../services/repo.dart';
import 'source_picker.dart';
import 'stats_widgets.dart';

/// Opens the full filter: where the lead came from, which Excel file, dates, WhatsApp state...
Future<LeadFilter?> showLeadFilterSheet(BuildContext context, LeadFilter current) {
  return showModalBottomSheet<LeadFilter>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _FilterSheet(initial: current),
  );
}

class _FilterSheet extends StatefulWidget {
  final LeadFilter initial;

  const _FilterSheet({required this.initial});

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late LeadFilter _f = widget.initial;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        maxChildSize: 0.95,
        builder: (context, scroll) => Column(
          children: [
            Expanded(
              child: ListView(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                children: [
                  Text('Filter leads', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  LeadFilterForm(initial: _f, onChanged: (f) => _f = f),
                ],
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(
                        context,
                        LeadFilter(search: widget.initial.search),
                      ),
                      child: const Text('Clear all'),
                    ),
                    const Spacer(),
                    FilledButton(onPressed: () => Navigator.pop(context, _f), child: const Text('Show leads')),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The filter fields. Also used to pick the audience of a WhatsApp broadcast.
class LeadFilterForm extends StatefulWidget {
  final LeadFilter initial;
  final ValueChanged<LeadFilter> onChanged;

  const LeadFilterForm({super.key, required this.initial, required this.onChanged});

  @override
  State<LeadFilterForm> createState() => _LeadFilterFormState();
}

class _LeadFilterFormState extends State<LeadFilterForm> {
  late LeadFilter _f = widget.initial;
  List<({String source, String? detail, int total})> _sources = [];
  List<ImportBatch> _batches = [];
  String? _preset;

  @override
  void initState() {
    super.initState();
    _preset = _presetOf(_f);
    Repo.sourceList().then((v) {
      if (mounted) setState(() => _sources = v);
    }).catchError((Object _) {});
    if (AppState.instance.isAdmin) {
      Repo.importBatches().then((v) {
        if (mounted) setState(() => _batches = v);
      }).catchError((Object _) {});
    }
  }

  void _set(LeadFilter f) {
    setState(() => _f = f);
    widget.onChanged(f);
  }

  static String? _presetOf(LeadFilter f) {
    if (f.from == null) return null;
    for (final r in StatsRange.values) {
      final (from, to) = r.bounds;
      if (from == f.from && to == f.to) return r.name;
    }
    return 'custom';
  }

  Future<void> _pickDates() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year + 1),
      initialDateRange: _f.from == null
          ? null
          : DateTimeRange(start: _f.from!, end: (_f.to ?? now).subtract(const Duration(days: 1))),
    );
    if (picked == null) return;
    setState(() => _preset = 'custom');
    _set(_f.copyWith(
      from: DateTime(picked.start.year, picked.start.month, picked.start.day),
      to: DateTime(picked.end.year, picked.end.month, picked.end.day).add(const Duration(days: 1)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final fmt = DateFormat('d MMM');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () async {
            final picked = await showSourcePicker(context, _sources, _f.sources);
            if (picked != null) _set(picked.isEmpty ? _f.copyWith(clearSource: true) : _f.copyWith(sources: picked));
          },
          child: InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Where the lead came from',
              helperText: 'Landing page, form, campaign or Excel file name. You can choose more than one.',
              helperMaxLines: 2,
              suffixIcon: Icon(Icons.arrow_drop_down),
            ),
            child: Text(sourcePicksText(_f.sources), maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        ),
        if (app.isAdmin && _batches.isNotEmpty) ...[
          const SizedBox(height: 14),
          DropdownButtonFormField<String?>(
            isExpanded: true,
            initialValue: _batches.any((b) => b.id == _f.batchId) ? _f.batchId : null,
            decoration: const InputDecoration(labelText: 'Excel upload'),
            items: [
              const DropdownMenuItem(value: null, child: Text('Any upload')),
              for (final b in _batches)
                DropdownMenuItem(
                  value: b.id,
                  child: Text('${b.name} · ${fmt.format(b.createdAt)} (${b.remaining})', overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => _set(v == null ? _f.copyWith(clearBatch: true) : _f.copyWith(batchId: v)),
          ),
        ],
        const SizedBox(height: 16),
        Text('Date the lead came in', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              label: const Text('Any'),
              selected: _preset == null,
              onSelected: (_) {
                setState(() => _preset = null);
                _set(_f.copyWith(clearDates: true));
              },
            ),
            for (final r in StatsRange.values)
              ChoiceChip(
                label: Text(r.label),
                selected: _preset == r.name,
                onSelected: (_) {
                  final (from, to) = r.bounds;
                  setState(() => _preset = r.name);
                  _set(_f.copyWith(from: from, to: to));
                },
              ),
            ChoiceChip(
              label: Text(_preset == 'custom' && _f.from != null
                  ? '${fmt.format(_f.from!)} – ${fmt.format(_f.to!.subtract(const Duration(days: 1)))}'
                  : 'Pick dates'),
              avatar: const Icon(Icons.date_range, size: 18),
              selected: _preset == 'custom',
              onSelected: (_) => _pickDates(),
            ),
          ],
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String?>(
          isExpanded: true,
          initialValue: _f.status,
          decoration: const InputDecoration(labelText: 'Status'),
          items: [
            const DropdownMenuItem(value: null, child: Text('Any status')),
            for (final s in app.statuses) DropdownMenuItem(value: s.name, child: Text(s.name)),
          ],
          onChanged: (v) => _set(v == null ? _f.copyWith(clearStatus: true) : _f.copyWith(status: v)),
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<String?>(
          isExpanded: true,
          initialValue: _f.temperature,
          decoration: const InputDecoration(labelText: 'Hot / Warm / Cold'),
          items: [
            const DropdownMenuItem(value: null, child: Text('Any')),
            for (final t in temperatures) DropdownMenuItem(value: t, child: Text(temperatureLabel(t))),
          ],
          onChanged: (v) => _set(v == null ? _f.copyWith(clearTemperature: true) : _f.copyWith(temperature: v)),
        ),
        if (app.isAdmin) ...[
          const SizedBox(height: 14),
          DropdownButtonFormField<String?>(
            isExpanded: true,
            initialValue: _f.assignee,
            decoration: const InputDecoration(labelText: 'Agent'),
            items: [
              const DropdownMenuItem(value: null, child: Text('Everyone')),
              const DropdownMenuItem(value: 'unassigned', child: Text('Unassigned')),
              for (final p in app.team) DropdownMenuItem(value: p.id, child: Text(p.displayName)),
            ],
            onChanged: (v) => _set(v == null ? _f.copyWith(clearAssignee: true) : _f.copyWith(assignee: v)),
          ),
        ],
        const SizedBox(height: 14),
        DropdownButtonFormField<String?>(
          isExpanded: true,
          initialValue: _f.webinar,
          decoration: const InputDecoration(labelText: 'Webinar (Webinar.gg)'),
          items: [
            const DropdownMenuItem(value: null, child: Text('Any')),
            for (final w in webinarStates) DropdownMenuItem(value: w.$1, child: Text(w.$2)),
          ],
          onChanged: (v) => _set(v == null ? _f.copyWith(clearWebinar: true) : _f.copyWith(webinar: v, attended: _f.attended)),
        ),
        if (_f.webinar != null) ...[
          const SizedBox(height: 14),
          DropdownButtonFormField<String?>(
            isExpanded: true,
            initialValue: _f.attended,
            decoration: const InputDecoration(labelText: 'Came to the webinar?'),
            items: const [
              DropdownMenuItem(value: null, child: Text('Either')),
              DropdownMenuItem(value: 'yes', child: Text('Attended')),
              DropdownMenuItem(value: 'no', child: Text('Did not attend')),
            ],
            onChanged: (v) => _set(_f.copyWith(clearWebinar: true).copyWith(webinar: _f.webinar, attended: v)),
          ),
        ],
        const SizedBox(height: 14),
        DropdownButtonFormField<String?>(
          isExpanded: true,
          initialValue: _f.appx,
          decoration: const InputDecoration(labelText: 'AIFM Education app'),
          items: [
            const DropdownMenuItem(value: null, child: Text('Any')),
            for (final a in appxStates) DropdownMenuItem(value: a.$1, child: Text(a.$2)),
            const DropdownMenuItem(value: 'not_purchased', child: Text('Not bought (everyone else)')),
          ],
          onChanged: (v) => _set(v == null ? _f.copyWith(clearAppx: true) : _f.copyWith(appx: v)),
        ),
        if (app.waConnected) ...[
          const SizedBox(height: 14),
          DropdownButtonFormField<String?>(
            isExpanded: true,
            initialValue: _f.waState,
            decoration: const InputDecoration(labelText: 'WhatsApp'),
            items: const [
              DropdownMenuItem(value: null, child: Text('Any')),
              DropdownMenuItem(value: 'sent', child: Text('Sent, not delivered yet')),
              DropdownMenuItem(value: 'delivered', child: Text('Delivered, not opened')),
              DropdownMenuItem(value: 'read', child: Text('Opened, no reply')),
              DropdownMenuItem(value: 'replied', child: Text('Replied')),
              DropdownMenuItem(value: 'failed', child: Text('Not delivered (failed)')),
              DropdownMenuItem(value: 'no_whatsapp', child: Text('Not on WhatsApp')),
              DropdownMenuItem(value: 'none', child: Text('No WhatsApp message yet')),
            ],
            onChanged: (v) => _set(v == null ? _f.copyWith(clearWa: true) : _f.copyWith(waState: v)),
          ),
        ],
      ],
    );
  }
}
