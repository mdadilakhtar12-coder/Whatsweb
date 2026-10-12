import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:whatsweb/services/repo.dart';
import 'package:whatsweb/widgets/source_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final requests = <Uri>[];
http.Request? _current;

Future<http.Response> handler(http.Request req) async {
  _current = req;
  requests.add(req.url);
  return http.Response(jsonEncode([]), 200, request: _current, headers: {'content-type': 'application/json; charset=utf-8'});
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://demo.supabase.co',
      publishableKey: 'demo',
      httpClient: MockClient(handler),
      authOptions: const FlutterAuthClientOptions(detectSessionInUri: false, autoRefreshToken: false),
    );
  });
  setUp(requests.clear);

  test('several sources become one "any of them" filter; one source works as before', () async {
    await Repo.leads(const LeadFilter(sources: [
      (source: 'meta_form', detail: null),
      (source: 'excel', detail: 'sept.xlsx'),
    ]));
    final or = requests.single.queryParametersAll['or']!.single;
    expect(or, '(source.eq."meta_form",and(source.eq."excel",source_detail.eq."sept.xlsx"))');

    requests.clear();
    await Repo.leads(const LeadFilter(sources: [(source: 'website', detail: 'landing-1')]));
    expect(requests.single.queryParametersAll['or']!.single, '(and(source.eq."website",source_detail.eq."landing-1"))');

    // no source: no source filter at all
    requests.clear();
    await Repo.leads(const LeadFilter());
    expect(requests.single.queryParametersAll.containsKey('or'), isFalse);
  });

  test('names with commas, brackets, dots and quotes cannot break the filter, and it combines with search and the app filter', () async {
    await Repo.leads(const LeadFilter(
      search: 'rahul',
      appx: 'not_purchased',
      sources: [(source: 'excel', detail: 'NEET, batch (2) v1.2 "final".xlsx'), (source: 'meta_form', detail: null)],
    ));
    final ors = requests.single.queryParametersAll['or']!;
    expect(ors, hasLength(3)); // search, app, sources: all of them must hold
    expect(ors, contains(r'(and(source.eq."excel",source_detail.eq."NEET, batch (2) v1.2 \"final\".xlsx"),source.eq."meta_form")'));
    expect(sourceFilterText([(source: 'a\\b', detail: null)]), r'source.eq."a\\b"');
  });

  test('ticking: a whole source replaces its own pages, the others stay, ticking again removes', () {
    const all = (source: 'excel', detail: null);
    const one = (source: 'excel', detail: 'a.xlsx');
    const two = (source: 'excel', detail: 'b.xlsx');
    const other = (source: 'website', detail: 'x');
    var p = togglePick([], one);
    p = togglePick(p, two);
    p = togglePick(p, other);
    expect(p, [one, two, other]);
    p = togglePick(p, all);
    expect(p, [other, all]);
    p = togglePick(p, all);
    expect(p, [other]);
    expect(togglePick(p, other), isEmpty);
  });

  test('the text of the choice', () {
    expect(sourcePicksText([]), 'All sources');
    expect(sourcePicksText([(source: 'meta_form', detail: null)]), 'Meta form');
    expect(sourcePicksText([(source: 'excel', detail: 'sept.xlsx')]), 'Excel import · sept.xlsx');
    expect(sourcePicksText([(source: 'meta_form', detail: null), (source: 'website', detail: null)]), 'Meta form, Website');
    expect(sourcePicksText([(source: 'meta_form', detail: null), (source: 'website', detail: null), (source: 'excel', detail: null)]), '3 sources');
  });

  test('the filter counts as one, clears together, and goes to the broadcast as a list', () {
    const f = LeadFilter(sources: [(source: 'meta_form', detail: null), (source: 'excel', detail: 'a.xlsx')]);
    expect(f.sheetCount, 1);
    expect(f.toAudience()['sources'], [
      {'source': 'meta_form'},
      {'source': 'excel', 'source_detail': 'a.xlsx'},
    ]);
    expect(f.copyWith(status: 'New').sources, hasLength(2));
    expect(f.copyWith(clearSource: true).sources, isEmpty);
    expect(f.copyWith(clearSource: true).sheetCount, 0);
    expect(const LeadFilter().toAudience().containsKey('sources'), isFalse);
  });

  testWidgets('the list shows each source with its pages; tick several and press Done', (tester) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    List<SourcePick>? result;
    final entries = <SourceEntry>[
      (source: 'meta_form', detail: 'NEET Sept', total: 40),
      (source: 'meta_form', detail: 'JEE Oct', total: 25),
      (source: 'excel', detail: 'sept.xlsx', total: 300),
      (source: 'website', detail: null, total: 12),
    ];
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => result = await showSourcePicker(context, entries, const []),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('All Meta form'), findsOneWidget);
    expect(find.text('NEET Sept'), findsOneWidget);
    expect(find.text('Website'), findsOneWidget); // no pages: just the source
    expect(find.text('Done (all sources)'), findsOneWidget);

    await tester.tap(find.text('NEET Sept'));
    await tester.tap(find.text('sept.xlsx'));
    await tester.tap(find.text('Website'));
    await tester.pumpAndSettle();
    expect(find.text('Done (3 chosen)'), findsOneWidget);

    // ticking "All Meta form" takes over its pages
    await tester.tap(find.text('All Meta form'));
    await tester.pumpAndSettle();
    expect(find.text('Done (3 chosen)'), findsOneWidget); // all Meta form + excel page + website
    // search narrows the list
    await tester.enterText(find.byType(TextField), 'sept.x');
    await tester.pumpAndSettle();
    expect(find.text('JEE Oct'), findsNothing);
    expect(find.text('sept.xlsx'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('Done ('));
    await tester.pumpAndSettle();
    expect(result, [
      (source: 'excel', detail: 'sept.xlsx'),
      (source: 'website', detail: null),
      (source: 'meta_form', detail: null),
    ]);
  });
}
