import 'dart:convert';
import 'dart:typed_data';

import 'package:csv/csv.dart' as csvlib;
import 'package:excel/excel.dart';

/// A spreadsheet read into plain text cells. Row 0 is the header row.
class SheetData {
  final List<String> headers;
  final List<List<String>> rows;

  const SheetData(this.headers, this.rows);
}

class Importer {
  /// Reads .xlsx or .csv bytes. Uses the first sheet that has data.
  static SheetData read(Uint8List bytes, String fileName) {
    final lower = fileName.toLowerCase();
    List<List<String>> table;
    if (lower.endsWith('.csv') || lower.endsWith('.txt')) {
      final text = utf8.decode(bytes, allowMalformed: true).replaceFirst('﻿', '');
      table = csvlib.Csv().decode(text).map((r) => r.map((c) => '${c ?? ''}'.trim()).toList()).toList();
    } else if (lower.endsWith('.xlsx')) {
      final book = Excel.decodeBytes(bytes);
      table = [];
      for (final sheet in book.tables.values) {
        final rows = sheet.rows.map((r) => r.map((d) => cellText(d?.value)).toList()).toList();
        if (rows.any((r) => r.any((c) => c.isNotEmpty))) {
          table = rows;
          break;
        }
      }
    } else {
      throw const FormatException('Please choose an .xlsx or .csv file (old .xls is not supported — "Save as" .xlsx in Excel)');
    }

    table = table.where((r) => r.any((c) => c.isNotEmpty)).toList();
    if (table.isEmpty) throw const FormatException('The file is empty');

    final width = table.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    List<String> pad(List<String> r) => [...r, ...List.filled(width - r.length, '')];
    final headers = pad(table.first);
    for (var i = 0; i < headers.length; i++) {
      if (headers[i].isEmpty) headers[i] = 'Column ${i + 1}';
    }
    return SheetData(headers, table.skip(1).map(pad).toList());
  }

  /// Excel stores phone numbers as numbers: 9876543210 must not become "9876543210.0".
  static String cellText(CellValue? v) {
    return switch (v) {
      null => '',
      IntCellValue(:final value) => value.toString(),
      DoubleCellValue(:final value) =>
        value == value.roundToDouble() && value.abs() < 1e15 ? value.toInt().toString() : value.toString(),
      TextCellValue() => v.value.toString().trim(),
      DateCellValue() => '${v.year}-${_two(v.month)}-${_two(v.day)}',
      _ => v.toString().trim(),
    };
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// Guesses which column holds the name, phone and email.
  static ({int? name, int? phone, int? email}) guessColumns(SheetData data) {
    int? find(List<String> exact, RegExp contains, {RegExp? exclude}) {
      final norm = data.headers.map((h) => h.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '')).toList();
      for (final e in exact) {
        final i = norm.indexOf(e);
        if (i >= 0) return i;
      }
      for (var i = 0; i < norm.length; i++) {
        if (contains.hasMatch(norm[i]) && !(exclude?.hasMatch(norm[i]) ?? false)) return i;
      }
      return null;
    }

    var phone = find(['phone', 'mobile', 'phonenumber', 'mobilenumber', 'mobileno', 'contactnumber', 'whatsapp'],
        RegExp(r'phone|mobile|whatsapp|contact|number'));
    var email = find(['email', 'emailaddress', 'emailid', 'mail'], RegExp(r'mail'));
    var name = find(['name', 'fullname', 'studentname', 'candidatename'], RegExp(r'name'),
        exclude: RegExp(r'father|mother|parent|company|course|school|college|file|campaign|form|ad'));

    // No headers? Look at the data: a column of 10+ digit numbers is the phone, one with @ is email.
    if (phone == null && data.rows.isNotEmpty) {
      for (var i = 0; i < data.headers.length; i++) {
        final sample = data.rows.take(10).map((r) => r[i]).where((c) => c.isNotEmpty);
        if (sample.isNotEmpty && sample.every((c) => c.replaceAll(RegExp(r'\D'), '').length >= 10)) {
          phone = i;
          break;
        }
      }
    }
    if (email == null && data.rows.isNotEmpty) {
      for (var i = 0; i < data.headers.length; i++) {
        if (data.rows.take(10).any((r) => r[i].contains('@'))) {
          email = i;
          break;
        }
      }
    }
    return (name: name, phone: phone, email: email);
  }

  /// Builds the rows sent to the import_leads database function.
  static List<Map<String, dynamic>> buildRows(
    SheetData data, {
    required int? nameCol,
    required int? phoneCol,
    required int? emailCol,
    bool keepOtherColumns = true,
  }) {
    final out = <Map<String, dynamic>>[];
    for (final r in data.rows) {
      final extra = <String, String>{};
      if (keepOtherColumns) {
        for (var i = 0; i < data.headers.length; i++) {
          if (i == nameCol || i == phoneCol || i == emailCol) continue;
          if (r[i].isNotEmpty) extra[data.headers[i]] = r[i];
        }
      }
      out.add({
        'name': nameCol == null ? '' : r[nameCol],
        'phone': phoneCol == null ? '' : r[phoneCol],
        'email': emailCol == null ? '' : r[emailCol],
        'extra': extra,
      });
    }
    return out;
  }
}
