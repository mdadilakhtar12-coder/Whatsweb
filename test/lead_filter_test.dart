import 'package:flutter_test/flutter_test.dart';
import 'package:whatsweb/models.dart';
import 'package:whatsweb/services/repo.dart';

void main() {
  test('filter counts only the sheet filters and builds the broadcast audience', () {
    final from = DateTime(2026, 10, 5);
    final to = DateTime(2026, 10, 6);
    final f = LeadFilter(status: 'New', sources: [(source: 'website', detail: 'landing-page-1')], from: from, to: to, waState: 'read');
    expect(f.sheetCount, 3); // where from, dates, whatsapp (status is a quick chip)
    final a = f.toAudience();
    expect(a['status'], 'New');
    expect(a['sources'], [
      {'source': 'website', 'source_detail': 'landing-page-1'},
    ]);
    expect(a['wa'], 'read');
    expect(a.containsKey('batch_id'), isFalse);
    expect(DateTime.parse(a['from'] as String).isAtSameMomentAs(from), isTrue);

    final cleared = f.copyWith(clearSource: true, clearDates: true, clearWa: true);
    expect(cleared.sheetCount, 0);
    expect(cleared.status, 'New');
  });

  test('a lead knows how long the WhatsApp reply window stays open', () {
    final open = Lead.fromJson({
      'id': 'a',
      'wa_state': 'replied',
      'wa_last_inbound_at': DateTime.now().subtract(const Duration(hours: 3)).toUtc().toIso8601String(),
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    expect(open.waWindowLeft, isNotNull);
    expect(open.waWindowLeft!.inHours, 20);

    final closed = Lead.fromJson({
      'id': 'b',
      'wa_last_inbound_at': DateTime.now().subtract(const Duration(hours: 30)).toUtc().toIso8601String(),
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    expect(closed.waWindowLeft, isNull);
    expect(Lead.fromJson({'id': 'c', 'created_at': DateTime.now().toUtc().toIso8601String()}).waWindowLeft, isNull);
  });

  test('a template reads its buttons from the saved spec', () {
    final t = WaTemplate.fromJson({
      'id': 't',
      'name': 'welcome',
      'status': 'APPROVED',
      'spec': {
        'body': 'Hi {first_name}',
        'buttons': [
          {'type': 'quick_reply', 'text': 'Fees', 'action': {'temperature': 'warm'}},
        ],
      },
    });
    expect(t.approved, isTrue);
    expect(t.buttons.single['text'], 'Fees');
    expect(t.header, isEmpty);
  });
}
