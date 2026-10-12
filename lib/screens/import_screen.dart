import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/app_state.dart';
import '../services/importer.dart';
import '../services/repo.dart';

/// Admin: upload an .xlsx / .csv file, match the columns, import.
class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  String? _fileName;
  final _batchName = TextEditingController();
  SheetData? _data;
  int? _nameCol, _phoneCol, _emailCol;
  bool _keepOther = true;
  String? _assignTo;
  bool _busy = false;
  double? _progress;
  String? _error;

  @override
  void dispose() {
    _batchName.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    setState(() => _error = null);
    try {
      final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['xlsx', 'csv']);
      if (file == null) return;
      setState(() => _busy = true);
      final bytes = await file.readAsBytes();
      final data = Importer.read(bytes, file.name);
      final guess = Importer.guessColumns(data);
      setState(() {
        _fileName = file.name;
        _batchName.text = '${file.name.replaceFirst(RegExp(r'\.(xlsx|csv)$', caseSensitive: false), '')} · ${DateFormat('d MMM').format(DateTime.now())}';
        _data = data;
        _nameCol = guess.name;
        _phoneCol = guess.phone;
        _emailCol = guess.email;
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _error = e is FormatException ? e.message : errorText(e);
      });
    }
  }

  Future<void> _import() async {
    final data = _data!;
    if (_phoneCol == null && _emailCol == null) {
      setState(() => _error = 'Choose the Phone column (or Email)');
      return;
    }
    final rows = Importer.buildRows(
      data,
      nameCol: _nameCol,
      phoneCol: _phoneCol,
      emailCol: _emailCol,
      keepOtherColumns: _keepOther,
    );
    setState(() {
      _busy = true;
      _progress = 0;
      _error = null;
    });

    var added = 0, dupes = 0, invalid = 0;
    const chunk = 300;
    try {
      // Every upload is one "folder": Imported files shows it and can filter its leads.
      final batchId = await Repo.createImportBatch(_batchName.text.trim().isEmpty ? (_fileName ?? 'Excel') : _batchName.text, rows.length);
      for (var i = 0; i < rows.length; i += chunk) {
        final part = rows.sublist(i, (i + chunk).clamp(0, rows.length));
        final res = await Repo.importLeads(part, assignTo: _assignTo, sourceDetail: _fileName, batchId: batchId);
        added += (res['added'] as num).toInt();
        dupes += (res['duplicates'] as num).toInt();
        invalid += (res['invalid'] as num).toInt();
        setState(() => _progress = (i + part.length) / rows.length);
      }
    } catch (e) {
      setState(() {
        _busy = false;
        _progress = null;
        _error = 'Stopped after $added added: ${errorText(e)}';
      });
      return;
    }

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Import finished'),
        content: Text(
          '✅ Added: $added\n'
          '🔁 Already in CRM (skipped): $dupes\n'
          '⚠️ No phone or email (skipped): $invalid',
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Import leads')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Upload an Excel (.xlsx) or CSV file. The first row should be the column names '
            '(Name, Phone, Email…). Numbers already in the CRM are skipped automatically.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _busy ? null : _pick,
            icon: const Icon(Icons.attach_file),
            label: Text(_fileName ?? 'Choose file'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: scheme.error)),
          ],
          if (data != null) ...[
            const SizedBox(height: 20),
            Text('${data.rows.length} rows found', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              controller: _batchName,
              decoration: const InputDecoration(
                labelText: 'Name of this upload',
                helperText: 'You will find these leads under More > Imported files',
              ),
            ),
            const SizedBox(height: 12),
            _columnPicker('Name column', _nameCol, (v) => setState(() => _nameCol = v)),
            _columnPicker('Phone column', _phoneCol, (v) => setState(() => _phoneCol = v)),
            _columnPicker('Email column', _emailCol, (v) => setState(() => _emailCol = v)),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _keepOther,
              onChanged: (v) => setState(() => _keepOther = v),
              title: const Text('Keep other columns'),
              subtitle: const Text('Shown under "Form details" on the lead (city, course…)'),
            ),
            DropdownButtonFormField<String?>(
              initialValue: _assignTo,
              decoration: const InputDecoration(labelText: 'Assign all to'),
              items: [
                const DropdownMenuItem(value: null, child: Text('Nobody yet (Unassigned)')),
                for (final p in AppState.instance.activeTeam) DropdownMenuItem(value: p.id, child: Text(p.displayName)),
              ],
              onChanged: (v) => setState(() => _assignTo = v),
            ),
            const SizedBox(height: 16),
            Text('Preview', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            _preview(data),
            const SizedBox(height: 20),
            if (_progress != null) ...[
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 12),
            ],
            FilledButton.icon(
              onPressed: _busy ? null : _import,
              icon: const Icon(Icons.cloud_upload_outlined),
              label: Text('Import ${data.rows.length} leads'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _columnPicker(String label, int? value, ValueChanged<int?> onChanged) {
    final headers = _data!.headers;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<int?>(
        initialValue: value,
        decoration: InputDecoration(labelText: label),
        items: [
          const DropdownMenuItem(value: null, child: Text('— not in file —')),
          for (var i = 0; i < headers.length; i++) DropdownMenuItem(value: i, child: Text(headers[i])),
        ],
        onChanged: onChanged,
      ),
    );
  }

  Widget _preview(SheetData data) {
    String cell(List<String> row, int? col) => col == null ? '' : row[col];
    return Card(
      margin: EdgeInsets.zero,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowHeight: 36,
          dataRowMinHeight: 32,
          dataRowMaxHeight: 40,
          columns: const [DataColumn(label: Text('Name')), DataColumn(label: Text('Phone')), DataColumn(label: Text('Email'))],
          rows: [
            for (final r in data.rows.take(5))
              DataRow(cells: [
                DataCell(Text(cell(r, _nameCol))),
                DataCell(Text(cell(r, _phoneCol))),
                DataCell(Text(cell(r, _emailCol))),
              ]),
          ],
        ),
      ),
    );
  }
}
