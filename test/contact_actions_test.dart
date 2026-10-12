import 'package:flutter_test/flutter_test.dart';
import 'package:whatsweb/models.dart';
import 'package:whatsweb/services/contact_actions.dart';

Lead lead({String name = 'Rahul', String? phone = '+919876543210'}) => Lead.fromJson({
      'id': '1',
      'name': name,
      'phone': phone,
      'created_at': '2026-09-27T10:00:00Z',
    });

void main() {
  test('WhatsApp number has the country code and no +', () {
    expect(ContactActions.whatsappNumber('+91 98765-43210'), '919876543210');
    expect(ContactActions.whatsappNumber('9876543210'), '919876543210');
    expect(ContactActions.whatsappNumber('+14155550100'), '14155550100');
  });

  test('templates put the lead name in {name}', () {
    expect(ContactActions.fill('Hi {name}, thanks!', lead()), 'Hi Rahul, thanks!');
    expect(ContactActions.fill('Hi {name}', lead(name: '  ')), 'Hi there');
  });

  test('lead parsing handles missing fields', () {
    final l = lead(phone: null);
    expect(l.hasPhone, isFalse);
    expect(l.status, 'New');
    expect(l.displayName, 'Rahul');
    expect(sourceLabel('meta_form'), 'Meta form');
  });
}
