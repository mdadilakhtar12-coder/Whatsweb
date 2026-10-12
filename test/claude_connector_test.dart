import 'package:flutter_test/flutter_test.dart';
import 'package:whatsweb/screens/claude_connector_screen.dart';

void main() {
  test('what Claude asked is shown in a few words', () {
    expect(mcpArgsText({'range': 'last_7_days', 'never_called': true, 'agent': 'Sita'}), 'last_7_days · never_called · Sita');
    expect(mcpArgsText({'never_called': false}), '');
    expect(mcpArgsText({}), '');
    expect(mcpArgsText(null), '');
    // an id is not worth showing
    expect(mcpArgsText({'lead_id': '7150910f-7d52-43f0-909e-cb587de32e5b'}), '');
  });

  test('tools have readable names', () {
    expect(mcpToolName('crm_overview'), 'Dashboard numbers');
    expect(mcpToolName('something_new'), 'something_new');
  });
}
