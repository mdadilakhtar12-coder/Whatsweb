import 'package:flutter_test/flutter_test.dart';
import 'package:whatsweb/models.dart';
import 'package:whatsweb/screens/webinar_screen.dart';
import 'package:whatsweb/services/repo.dart';

void main() {
  test('rupees: Indian grouping, no useless decimals', () {
    expect(rupees(149), '₹149');
    expect(rupees(149.5), '₹149.5');
    expect(rupees(1499), '₹1,499');
    expect(rupees(14304), '₹14,304');
    expect(rupees(1234567), '₹12,34,567');
    expect(rupees(0), '₹0');
    expect(rupees(99.05), '₹99.05');
  });

  test('a lead reads its Webinar.gg summary', () {
    final l = Lead.fromJson({
      'id': 'l1',
      'created_at': '2026-10-01T10:00:00Z',
      'webinar_state': 'paid',
      'webinar_paid': 149,
      'webinar_title': 'Free class',
      'webinar_attended': false,
    });
    expect(l.webinarState, 'paid');
    expect(l.webinarPaid, 149.0);
    expect(l.webinarAttended, false);
    final none = Lead.fromJson({'id': 'l2', 'created_at': '2026-10-01T10:00:00Z'});
    expect(none.webinarState, isNull);
    expect(none.webinarPaid, 0);
    expect(none.webinarAttended, isNull);
  });

  test('webinar filter goes to the list and to the broadcast group', () {
    const f = LeadFilter(webinar: 'paid', attended: 'no');
    expect(f.toAudience(), {'webinar': 'paid', 'attended': 'no'});
    expect(f.sheetCount, 2);
    // changing the webinar state keeps "attended"; clearing the webinar clears both
    expect(f.copyWith(webinar: 'registered').attended, 'no');
    final cleared = f.copyWith(clearWebinar: true);
    expect(cleared.webinar, isNull);
    expect(cleared.attended, isNull);
    expect(const LeadFilter().toAudience(), isEmpty);
  });

  test('names for events and states', () {
    expect(webinarEventName('registration.payment.completed'), 'Paid');
    expect(webinarEventName('webinar.started'), 'webinar.started');
    expect(webinarStateLabel('registered'), 'Registered, not paid');
    expect(sourceLabel('webinar'), 'Webinar.gg');
  });
}
