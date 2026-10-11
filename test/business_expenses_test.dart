import 'dart:convert';
import 'dart:io';

import 'package:finance_app/business_expense_catalog.dart';
import 'package:finance_app/category_picker_dialog.dart';
import 'package:finance_app/category_tree.dart';
import 'package:finance_app/wallet_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('62 exact catalog entries, sibling order and original PNG bytes', () {
    final source = jsonDecode(
      File('design/business-expenses-pack/catalog.json').readAsStringSync(),
    ) as Map;
    final entries = (source['categories'] as List).cast<Map>();
    final nodes = businessExpenseFixtures('business');
    final tree = CategoryTree(nodes.reversed.toList());
    expect(nodes, hasLength(62));
    expect(nodes.where((n) => n.parentId == null), hasLength(11));
    expect(nodes.where((n) => n.parentId != null), hasLength(51));
    expect(businessExpenseIconCatalog.map((c) => c.id).toSet(), hasLength(62));
    for (final entry in entries) {
      final node = tree.byId(entry['key'])!;
      expect(node.name, entry['name']);
      expect(node.parentId, entry['parent_key']);
      expect(node.sortOrder, entry['sort_order']);
      expect(node.iconId, entry['icon_id']);
      final icon = resolveCategoryIcon(node.iconId);
      expect(icon.id, node.iconId);
      expect(
        File(icon.asset).readAsBytesSync(),
        File('design/business-expenses-pack/${entry['asset_file']}')
            .readAsBytesSync(),
      );
      expect(tree.archived(node), isFalse);
    }
    expect(
      tree.children('advertising').map((c) => c.sortOrder),
      orderedEquals([1, 2, 3, 4, 5]),
    );
    expect(tree.children('client-refunds'), isEmpty);
  });

  for (final width in [390.0, 1200.0]) {
    testWidgets(
      'business tree picker searches and chooses exact leaf at width $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        String? selected;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async => selected = await showDialog<String>(
                    context: context,
                    builder: (_) => CategoryPickerDialog(
                      categories: businessExpenseFixtures('business'),
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.text('Реклама на площадке OLX'), findsNothing);
        await tester.tap(find.byTooltip('Раскрыть Реклама'));
        await tester.pumpAndSettle();
        expect(find.text('Реклама на площадке OLX'), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'Набиуллина');
        await tester.pumpAndSettle();
        expect(find.text('Юрист — Набиуллина Эльвира'), findsOneWidget);
        expect(find.text('Юрист — Смирнова Марина'), findsNothing);
        await tester.tap(find.text('Юрист — Набиуллина Эльвира'));
        await tester.pumpAndSettle();
        final source = jsonDecode(
          File('design/business-expenses-pack/catalog.json').readAsStringSync(),
        ) as Map;
        final leaf = (source['categories'] as List).cast<Map>().singleWhere(
          (c) => c['name'] == 'Юрист — Набиуллина Эльвира',
        );
        expect(selected, leaf['key']);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
