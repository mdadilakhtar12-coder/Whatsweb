import 'package:flutter_test/flutter_test.dart';
import 'package:whatsweb/models.dart';
import 'package:whatsweb/screens/appx_screen.dart';
import 'package:whatsweb/services/repo.dart';

void main() {
  test('a lead reads its AIFM Education app summary', () {
    final l = Lead.fromJson({
      'id': 'l1',
      'created_at': '2026-10-01T10:00:00Z',
      'appx_state': 'purchased',
      'appx_paid': 4999,
      'appx_item': 'NEET 2027 Batch',
    });
    expect(l.appxState, 'purchased');
    expect(l.appxPaid, 4999.0);
    expect(l.appxItem, 'NEET 2027 Batch');
    final none = Lead.fromJson({'id': 'l2', 'created_at': '2026-10-01T10:00:00Z'});
    expect(none.appxState, isNull);
    expect(none.appxPaid, 0);
    expect(none.appxItem, isNull);
  });

  test('app filter goes to the list and to the broadcast group', () {
    const f = LeadFilter(appx: 'not_purchased', webinar: 'paid');
    expect(f.toAudience(), {'webinar': 'paid', 'appx': 'not_purchased'});
    expect(f.sheetCount, 2);
    // the webinar filters and the app filter do not clear each other
    expect(f.copyWith(clearWebinar: true).appx, 'not_purchased');
    expect(f.copyWith(clearAppx: true).webinar, 'paid');
    expect(f.copyWith(clearAppx: true).appx, isNull);
    expect(f.copyWith(appx: 'purchased').appx, 'purchased');
    expect(const LeadFilter().toAudience(), isEmpty);
  });

  test('names for states, events and the source', () {
    expect(appxStateLabel('purchased'), 'Bought in the app');
    expect(appxStateLabel('signed_up'), 'Signed up, not bought');
    expect(appxStateLabel('other'), 'other');
    expect(sourceLabel('appx'), 'AIFM Education app');
    expect(appxEventName('purchase'), 'Successful Purchase');
    expect(appxEventName('cancelled'), 'Cancelled Payment');
    expect(appxEventName('video'), 'video');
  });

  test('every event has keys the server understands and the guide covers all six', () {
    expect(appxEvents.map((e) => e.kind), ['signup', 'purchase', 'cancelled', 'demo', 'contact', 'refund']);
    for (final e in appxEvents) {
      // the student is found by phone or e-mail, so each event must ask for at least one
      expect(e.keys.map((k) => k.$1), anyOf(contains('number'), contains('email')), reason: e.kind);
      expect(e.keys.map((k) => k.$1).toSet().length, e.keys.length, reason: 'duplicate key in ${e.kind}');
    }
    expect(appxEvents.firstWhere((e) => e.kind == 'purchase').keys.map((k) => k.$1), containsAll(['item', 'amount', 'transaction_id']));
  });
}
