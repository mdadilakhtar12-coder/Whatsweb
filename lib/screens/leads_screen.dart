import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import '../services/app_state.dart';
import '../services/repo.dart';
import '../widgets/assign_sheet.dart';
import '../widgets/lead_card.dart';
import '../widgets/lead_filter_sheet.dart';
import '../widgets/source_picker.dart';
import 'lead_detail_screen.dart';
import 'lead_form_screen.dart';

class LeadsScreen extends StatefulWidget {
  /// Opened from another screen with a filter already set (e.g. the leads of one Excel upload).
  final LeadFilter? initialFilter;
  final String? title;

  const LeadsScreen({super.key, this.initialFilter, this.title});

  @override
  State<LeadsScreen> createState() => _LeadsScreenState();
}

class _LeadsScreenState extends State<LeadsScreen> {
  final _scroll = ScrollController();
  final _searchCtrl = TextEditingController();
  late final AppLifecycleListener _lifecycle;
  Timer? _debounce;

  late LeadFilter _filter = widget.initialFilter ?? const LeadFilter();
  final List<Lead> _leads = [];
  bool _loading = false;
  bool _hasMore = true;
  String? _error;
  bool _searching = false;

  final Set<String> _selected = {};
  bool get _selecting => _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) _loadMore();
    });
    _lifecycle = AppLifecycleListener(onResume: () => _reload(quiet: true));
    _reload();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _scroll.dispose();
    _searchCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _reload({bool quiet = false}) async {
    if (!quiet) {
      setState(() {
        _leads.clear();
        _hasMore = true;
        _error = null;
      });
    }
    await _fetch(reset: true);
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    await _fetch(reset: false);
  }

  Future<void> _fetch({required bool reset}) async {
    setState(() => _loading = true);
    final filter = _filter;
    try {
      final page = await Repo.leads(filter, offset: reset ? 0 : _leads.length);
      if (!mounted || filter != _filter) return;
      setState(() {
        if (reset) _leads.clear();
        _leads.addAll(page);
        _hasMore = page.length == Repo.pageSize;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _setFilter(LeadFilter f) {
    _filter = f;
    _reload();
  }

  void _onSearch(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _setFilter(_filter.copyWith(search: text)));
  }

  Future<void> _open(Lead lead) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => LeadDetailScreen(leadId: lead.id, initial: lead)),
    );
    _reload(quiet: true);
  }

  Future<void> _add() async {
    final created = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const LeadFormScreen()));
    if (created == true) _reload();
  }

  void _toggle(Lead lead) {
    setState(() => _selected.contains(lead.id) ? _selected.remove(lead.id) : _selected.add(lead.id));
  }

  Future<void> _assignSelected() async {
    final n = await showAssignSheet(context, _selected.toList());
    if (n == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$n lead${n == 1 ? '' : 's'} updated')));
    setState(_selected.clear);
    _reload(quiet: true);
  }

  Future<void> _deleteSelected() async {
    final n = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete $n lead${n == 1 ? '' : 's'}?'),
        content: const Text('Their remarks and reminders are deleted too. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Repo.deleteLeads(_selected.toList());
      setState(_selected.clear);
      _reload(quiet: true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(e))));
    }
  }

  PreferredSizeWidget _appBar() {
    if (_selecting) {
      return AppBar(
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(_selected.clear)),
        titleSpacing: 0,
        title: Text('${_selected.length} selected', style: const TextStyle(fontSize: 18)),
        actions: [
          IconButton(
            tooltip: 'Select all',
            icon: const Icon(Icons.select_all),
            onPressed: () => setState(() => _selected.addAll(_leads.map((l) => l.id))),
          ),
          IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: _deleteSelected),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              onPressed: _assignSelected,
              icon: const Icon(Icons.person_add_alt_1, size: 18),
              label: const Text('Assign'),
            ),
          ),
        ],
      );
    }
    if (_searching) {
      return AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            _searchCtrl.clear();
            setState(() => _searching = false);
            _setFilter(_filter.copyWith(search: ''));
          },
        ),
        title: TextField(
          controller: _searchCtrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Name, phone or email', border: InputBorder.none),
          onChanged: _onSearch,
        ),
      );
    }
    return AppBar(
      title: Text(widget.title ?? 'Leads'),
      actions: [
        IconButton(icon: const Icon(Icons.search), onPressed: () => setState(() => _searching = true)),
        IconButton(icon: const Icon(Icons.refresh), onPressed: _reload),
      ],
    );
  }

  Future<void> _openFilters() async {
    final f = await showLeadFilterSheet(context, _filter);
    if (f != null) _setFilter(f);
  }

  /// "Landing page · summer" with a cross to remove it.
  Widget _activeChip(String label, VoidCallback onRemove) => InputChip(
        label: Text(label, overflow: TextOverflow.ellipsis),
        backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
        onDeleted: onRemove,
      );

  Widget _filters() {
    final app = AppState.instance;
    final chips = <Widget>[];
    final fmt = DateFormat('d MMM');
    final count = _filter.sheetCount;

    chips.add(ActionChip(
      avatar: const Icon(Icons.tune, size: 18),
      label: Text(count == 0 ? 'Filters' : 'Filters · $count'),
      backgroundColor: count == 0 ? null : Theme.of(context).colorScheme.secondaryContainer,
      onPressed: _openFilters,
    ));
    if (_filter.sources.length > 3) {
      chips.add(_activeChip(sourcePicksText(_filter.sources), () => _setFilter(_filter.copyWith(clearSource: true))));
    } else {
      // one chip for each chosen source: tap its cross to take just that one away
      for (final pick in _filter.sources) {
        chips.add(_activeChip(
          sourcePicksText([pick]),
          () {
            final rest = [..._filter.sources]..remove(pick);
            _setFilter(rest.isEmpty ? _filter.copyWith(clearSource: true) : _filter.copyWith(sources: rest));
          },
        ));
      }
    }
    if (_filter.batchId != null && widget.initialFilter?.batchId != _filter.batchId) {
      chips.add(_activeChip('Excel upload', () => _setFilter(_filter.copyWith(clearBatch: true))));
    }
    if (_filter.from != null) {
      chips.add(_activeChip(
        '${fmt.format(_filter.from!)} – ${fmt.format(_filter.to!.subtract(const Duration(days: 1)))}',
        () => _setFilter(_filter.copyWith(clearDates: true)),
      ));
    }
    if (_filter.waState != null) {
      chips.add(_activeChip('WhatsApp: ${waStateLabel(_filter.waState!)}', () => _setFilter(_filter.copyWith(clearWa: true))));
    }

    if (app.isAdmin) {
      final label = switch (_filter.assignee) {
        null => 'Everyone',
        'unassigned' => 'Unassigned',
        final id => app.memberName(id),
      };
      chips.add(
        PopupMenuButton<String>(
          onSelected: (v) => _setFilter(
            v == '*' ? _filter.copyWith(clearAssignee: true) : _filter.copyWith(assignee: v),
          ),
          itemBuilder: (_) => [
            const PopupMenuItem(value: '*', child: Text('Everyone')),
            const PopupMenuItem(value: 'unassigned', child: Text('Unassigned')),
            for (final p in app.team) PopupMenuItem(value: p.id, child: Text(p.displayName)),
          ],
          child: Chip(
            avatar: const Icon(Icons.person_outline, size: 18),
            label: Row(
              mainAxisSize: MainAxisSize.min,
              children: [Text(label), const Icon(Icons.arrow_drop_down, size: 18)],
            ),
            backgroundColor: _filter.assignee != null ? Theme.of(context).colorScheme.secondaryContainer : null,
          ),
        ),
      );
    }

    final temp = _filter.temperature;
    chips.add(
      PopupMenuButton<String>(
        onSelected: (v) => _setFilter(
          v == '*' ? _filter.copyWith(clearTemperature: true) : _filter.copyWith(temperature: v),
        ),
        itemBuilder: (_) => [
          const PopupMenuItem(value: '*', child: Text('Hot / Warm / Cold: all')),
          for (final t in temperatures) PopupMenuItem(value: t, child: Text(temperatureLabel(t))),
        ],
        child: Chip(
          label: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(temp == null ? 'Hot/Warm/Cold' : temperatureLabel(temp)),
              const Icon(Icons.arrow_drop_down, size: 18),
            ],
          ),
          backgroundColor: temp != null ? temperatureColor(temp).withValues(alpha: 0.15) : null,
        ),
      ),
    );

    chips.add(ChoiceChip(
      label: const Text('All'),
      selected: _filter.status == null,
      onSelected: (_) => _setFilter(_filter.copyWith(clearStatus: true)),
    ));
    for (final s in app.statuses) {
      chips.add(ChoiceChip(
        label: Text(s.name),
        selected: _filter.status == s.name,
        selectedColor: s.color.withValues(alpha: 0.25),
        onSelected: (_) => _setFilter(_filter.copyWith(status: s.name)),
      ));
    }

    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: chips.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) => chips[i],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final admin = AppState.instance.isAdmin;
    return PopScope(
      canPop: !_selecting && !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        setState(() {
          _selected.clear();
          _searching = false;
        });
      },
      child: Scaffold(
        appBar: _appBar(),
        floatingActionButton: _selecting
            ? null
            : FloatingActionButton.extended(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Add lead')),
        body: Column(
          children: [
            _filters(),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _reload,
                child: _buildList(admin),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(bool admin) {
    if (_leads.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 120),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                _error ?? (admin ? 'No leads yet.\nAdd one, or import an Excel file from More.' : 'No leads assigned to you yet.'),
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
        ],
      );
    }
    return ListView.builder(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 96, top: 2),
      itemCount: _leads.length + 1,
      itemBuilder: (context, i) {
        if (i == _leads.length) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: _loading
                  ? const CircularProgressIndicator()
                  : Text(
                      _error ?? (_hasMore ? '' : '${_leads.length} lead${_leads.length == 1 ? '' : 's'}'),
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
            ),
          );
        }
        final lead = _leads[i];
        return LeadCard(
          lead: lead,
          selecting: _selecting,
          selected: _selected.contains(lead.id),
          onTap: () => _selecting ? _toggle(lead) : _open(lead),
          onLongPress: admin ? () => _toggle(lead) : null,
          onUpdated: () => _reload(quiet: true),
        );
      },
    );
  }
}
