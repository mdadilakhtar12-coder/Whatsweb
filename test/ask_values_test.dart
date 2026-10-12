import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whatsweb/models.dart';
import 'package:whatsweb/widgets/wa_widgets.dart';

WaTemplate _t(Map<String, dynamic> spec) => WaTemplate(
      id: 't1',
      name: 'exam_dates',
      language: 'en',
      category: 'UTILITY',
      spec: spec,
      status: 'APPROVED',
      reason: null,
    );

void main() {
  test('finds the details typed in when sending, once each, lower-case', () {
    final t = _t({
      'header': {'type': 'text', 'text': 'Hello {first_name}'},
      'body': 'Your {ask.Paper} exam for {ask.semester} is on {ask.date}. {ask.semester} again. Hi {first_name}',
      'buttons': [
        {'type': 'url', 'text': 'Open', 'url': 'https://x.in/r/{ask.code}'},
        {'type': 'phone', 'text': 'Call', 'phone': '+911234567890'},
      ],
    });
    expect(t.askNames, ['paper', 'semester', 'date', 'code']);
  });

  test('a template without such details has none', () {
    expect(_t({'body': 'Hi {first_name}, your course {extra.course}'}).askNames, isEmpty);
  });

  test('examples fill the preview', () {
    final t = _t({
      'body': 'Semester {ask.semester} for {first_name}',
      'examples': {'ask.semester': 'Semester 3'},
    });
    expect(t.examples['ask.semester'], 'Semester 3');
    expect(waFillSample(t.body, examples: t.examples), 'Semester Semester 3 for Rahul');
    expect(waFillSample('Unit {ask.unit}'), 'Unit …');
  });

  testWidgets('one box per detail; values come back trimmed and without empty ones', (tester) async {
    final t = _t({
      'body': 'A {ask.paper} B {ask.unit} C',
      'examples': {'ask.paper': 'Maths'},
    });
    var got = <String, String>{};
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: AskFields(template: t, onChanged: (v) => got = v))));
    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.text('Paper'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '  Maths  ');
    expect(got, {'paper': 'Maths'});
    await tester.enterText(find.byType(TextField).last, '2');
    expect(got, {'paper': 'Maths', 'unit': '2'});
  });
}
