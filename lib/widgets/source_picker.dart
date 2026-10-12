import 'package:flutter/material.dart';

import '../models.dart';
import '../services/repo.dart';

typedef SourceEntry = ({String source, String? detail, int total});

/// "Meta form" / "Meta form · NEET Sept" / "Excel import, Website" / "3 sources"
String sourcePicksText(List<SourcePick> picks) {
  String one(SourcePick p) => '${sourceLabel(p.source)}${p.detail == null ? '' : ' · ${p.detail}'}';
  if (picks.isEmpty) return 'All sources';
  if (picks.length == 1) return one(picks.first);
  if (picks.length == 2) return '${one(picks[0])}, ${one(picks[1])}';
  return '${picks.length} sources';
}

/// The picks after one is added or taken away (a source as a whole replaces its own details).
List<SourcePick> togglePick(List<SourcePick> picks, SourcePick pick) {
  final has = picks.contains(pick);
  if (has) return [...picks]..remove(pick);
  if (pick.detail == null) {
    // the whole source: its single pages / files are included, so they go away
    return [...picks.where((p) => p.source != pick.source), pick];
  }
  return [...picks, pick];
}

/// A list of all sources (and the campaign / page / file names under them) with check boxes: tick as many as needed.
/// Returns the new choice, or null when it was closed without "Done".
Future<List<SourcePick>?> showSourcePicker(BuildContext context, List<SourceEntry> entries, List<SourcePick> selected) {
  return showModalBottomSheet<List<SourcePick>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _SourcePicker(entries: entries, selected: selected),
  );
}

class _SourcePicker extends StatefulWidget {
  final List<SourceEntry> entries;
  final List<SourcePick> selected;

  const _SourcePicker({required this.entries, required this.selected});

  @override
  State<_SourcePicker> createState() => _SourcePickerState();
}

class _SourcePickerState extends State<_SourcePicker> {
  late List<SourcePick> _picks = [...widget.selected];
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Every source with its total and its named details (campaign, page, file), in the order of the list.
  List<({String source, int total, List<SourceEntry> details})> get _groups {
    final order = <String>[];
    final byName = <String, List<SourceEntry>>{};
    for (final e in widget.entries) {
      byName.putIfAbsent(e.source, () {
        order.add(e.source);
        return [];
      }).add(e);
    }
    return [
      for (final s in order)
        (
          source: s,
          total: byName[s]!.fold<int>(0, (sum, e) => sum + e.total),
          details: byName[s]!.where((e) => e.detail != null).toList(),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final q = _search.text.trim().toLowerCase();
    // a picked source that is no longer in the list stays visible, so it can be un-ticked
    final known = widget.entries.map((e) => (source: e.source, detail: e.detail)).toSet();
    final missing = _picks.where((p) => !known.contains(p) && !widget.entries.any((e) => e.source == p.source && p.detail == null)).toList();

    final tiles = <Widget>[];
    for (final p in missing) {
      tiles.add(CheckboxListTile(
        dense: true,
        value: true,
        title: Text(sourcePicksText([p])),
        onChanged: (_) => setState(() => _picks = togglePick(_picks, p)),
      ));
    }
    for (final g in _groups) {
      final label = sourceLabel(g.source);
      final wholePick = (source: g.source, detail: null);
      final whole = _picks.contains(wholePick);
      final details = g.details.where((d) => q.isEmpty || label.toLowerCase().contains(q) || d.detail!.toLowerCase().contains(q)).toList();
      final headShown = q.isEmpty || label.toLowerCase().contains(q) || details.isNotEmpty;
      if (!headShown) continue;
      tiles.add(CheckboxListTile(
        value: whole,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(g.details.isEmpty ? label : 'All $label', style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text('${g.total} leads'),
        onChanged: (_) => setState(() => _picks = togglePick(_picks, wholePick)),
      ));
      for (final d in details) {
        final pick = (source: d.source, detail: d.detail);
        tiles.add(Padding(
          padding: const EdgeInsets.only(left: 28),
          child: CheckboxListTile(
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            // ticked through "All ..." above: shown ticked and cannot be changed on its own
            value: whole || _picks.contains(pick),
            title: Text(d.detail!, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text('${d.total} leads'),
            onChanged: whole ? null : (_) => setState(() => _picks = togglePick(_picks, pick)),
          ),
        ));
      }
    }

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        maxChildSize: 0.95,
        builder: (context, scroll) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Where the leads came from', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 2),
                  Text('Tick one or more. You get the leads of any of them.', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search a source, campaign or file', isDense: true),
                  ),
                ],
              ),
            ),
            Expanded(
              child: tiles.isEmpty
                  ? const Center(child: Text('Nothing found'))
                  : ListView(controller: scroll, children: tiles),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                    TextButton(onPressed: _picks.isEmpty ? null : () => setState(() => _picks = []), child: const Text('Untick all')),
                    const Spacer(),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, _picks),
                      child: Text(_picks.isEmpty ? 'Done (all sources)' : 'Done (${_picks.length} chosen)'),
                    ),
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
