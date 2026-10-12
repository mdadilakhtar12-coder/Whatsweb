import 'package:flutter_test/flutter_test.dart';
import 'package:whatsweb/screens/wa_quick_send_screen.dart';

void main() {
  test('reads numbers with or without names, one per line or comma separated', () {
    final r = parsePhoneEntries('''
9876543210
98765 43211  Rahul
Priya, 98765-43212
+971 50 123 4567
9876543210
hello
12345
9111111111, 9222222222
9333333333 9444444444
''');
    expect(r.entries.map((e) => e.phone).toList(), [
      '9876543210',
      '9876543211',
      '9876543212',
      '+971501234567',
      '9111111111',
      '9222222222',
      '9333333333',
      '9444444444',
    ]);
    expect(r.entries[1].name, 'Rahul');
    expect(r.entries[2].name, 'Priya');
    expect(r.unclear, 2); // "hello" and "12345"
  });

  test('empty text gives nothing', () {
    expect(parsePhoneEntries('  \n ').entries, isEmpty);
  });
}
