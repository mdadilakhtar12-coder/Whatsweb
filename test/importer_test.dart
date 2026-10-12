import 'dart:convert';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whatsweb/services/importer.dart';

void main() {
  test('reads CSV with header row and guesses columns', () {
    const text = '﻿Student Name,Mobile No,Email ID,City\n'
        'Rahul,98765 43210,rahul@x.com,Patna\n'
        'Neha,+91 9123456780,,Delhi\n';
    final data = Importer.read(Uint8List.fromList(utf8.encode(text)), 'leads.csv');
    expect(data.headers, ['Student Name', 'Mobile No', 'Email ID', 'City']);
    expect(data.rows.length, 2);

    final g = Importer.guessColumns(data);
    expect(g.name, 0);
    expect(g.phone, 1);
    expect(g.email, 2);

    final rows = Importer.buildRows(data, nameCol: g.name, phoneCol: g.phone, emailCol: g.email);
    expect(rows.first['name'], 'Rahul');
    expect(rows.first['phone'], '98765 43210');
    expect(rows.first['extra'], {'City': 'Patna'});
    expect(rows[1]['email'], '');
  });

  test('reads xlsx and keeps numeric phone numbers intact', () {
    final book = Excel.createExcel();
    final sheet = book[book.getDefaultSheet()!];
    sheet.appendRow([TextCellValue('Name'), TextCellValue('Phone'), TextCellValue('Course')]);
    sheet.appendRow([TextCellValue('Aman'), IntCellValue(9876543210), TextCellValue('NEET')]);
    sheet.appendRow([TextCellValue('Sita'), DoubleCellValue(9123456780), TextCellValue('JEE')]);
    final bytes = Uint8List.fromList(book.encode()!);

    final data = Importer.read(bytes, 'Leads.XLSX');
    expect(data.rows.length, 2);
    expect(data.rows[0][1], '9876543210');
    expect(data.rows[1][1], '9123456780');
    final g = Importer.guessColumns(data);
    expect((g.name, g.phone, g.email), (0, 1, null));
  });

  test('finds phone and email columns without headers', () {
    const text = 'a,b,c\nRavi,9876543210,ravi@x.com\nMohan,9123456789,m@x.com\n';
    final data = Importer.read(Uint8List.fromList(utf8.encode(text)), 'x.csv');
    final g = Importer.guessColumns(data);
    expect(g.phone, 1);
    expect(g.email, 2);
  });

  test('rejects old .xls files with a clear message', () {
    expect(
      () => Importer.read(Uint8List(4), 'old.xls'),
      throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('.xlsx'))),
    );
  });
}
