import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import '../services/repo.dart';
import 'import_screen.dart';
import 'leads_screen.dart';

/// Admin: every Excel upload as a "folder". Open one to see only its leads.
class ImportsScreen extends StatefulWidget {
  const ImportsScreen({super.key});

  @override
  State<ImportsScreen> createState() => _ImportsScreenState();
}

class _ImportsScreenState extends State<ImportsScreen> {
  List<ImportBatch>? _batches;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await Repo.importBatches();
      if (mounted) setState(() => _batches = list);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  Future<void> _open(ImportBatch b) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => LeadsScreen(initialFilter: LeadFilter(batchId: b.id), title: b.name)),
    );
    _load();
  }

  Future<void> _delete(ImportBatch b) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Remove "${b.name}"?'),
        content: const Text(
          'Leads of this file that nobody has called, messaged or given a reminder yet are deleted. '
          'Leads that were already worked on stay.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final res = await Repo.deleteImportBatch(b.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${res['deleted']} leads removed${(res['kept'] as num) > 0 ? ', ${res['kept']} kept (already worked on)' : ''}'),
      ));
      _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fmt = DateFormat('d MMM yyyy, h:mm a');
    final list = _batches;
    return Scaffold(
      appBar: AppBar(title: const Text('Imported files')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => const ImportScreen()));
          _load();
        },
        icon: const Icon(Icons.upload_file),
        label: const Text('Import file'),
      ),
      body: list == null
          ? Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!))
          : list.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(32),
                  child: Center(
                    child: Text(
                      'No Excel uploads yet.\nEvery file you import shows up here as a folder.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.only(bottom: 96),
                    itemCount: list.length,
                    itemBuilder: (_, i) {
                      final b = list[i];
                      return ListTile(
                        leading: const CircleAvatar(child: Icon(Icons.folder_outlined)),
                        title: Text(b.name),
                        subtitle: Text('${fmt.format(b.createdAt)}\n${b.added} added · ${b.duplicates} already in CRM · ${b.remaining} left'),
                        isThreeLine: true,
                        onTap: () => _open(b),
                        trailing: PopupMenuButton<String>(
                          onSelected: (_) => _delete(b),
                          itemBuilder: (_) => const [PopupMenuItem(value: 'delete', child: Text('Remove untouched leads'))],
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
