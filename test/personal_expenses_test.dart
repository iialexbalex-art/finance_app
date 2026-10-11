import 'dart:convert';
import 'dart:io';

import 'package:finance_app/personal_expense_catalog.dart';
import 'package:finance_app/category.dart';
import 'package:finance_app/category_tree.dart';
import 'package:finance_app/categories_screen.dart';
import 'package:finance_app/wallet_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'category_interaction_fix_test.dart' show RevisionRepo, toggle, dragRow;
import 'bulk_actions_test.dart' show host;
import 'fake_finance.dart' show personalSpace;

void main() {
  test('143 exact paths; 101 deduplicated original transparent PNGs', () {
    final source = jsonDecode(
      File('design/personal-expenses-pack/catalog.json').readAsStringSync(),
    ) as Map;
    final entries = (source['categories'] as List).cast<Map>();
    final nodes = personalExpenseFixtures('personal');
    final tree = CategoryTree(nodes.reversed.toList());
    expect(nodes, hasLength(143));
    expect(tree.ordered(nodes.where((x) => x.parentId == null)), hasLength(16));
    expect(nodes.where((x) => x.parentId != null), hasLength(127));
    final assets = <String>{};
    for (final c in entries) {
      final node = tree.byId(c['key'])!;
      expect(node.name, c['name']);
      expect(node.parentId, c['parent_key']);
      expect(node.sortOrder, c['sort_order']);
      final icon = resolveCategoryIcon(node.iconId);
      expect(icon.id, node.iconId);
      expect(
        File(icon.asset).readAsBytesSync(),
        File('design/personal-expenses-pack/${c['asset_file']}')
            .readAsBytesSync(),
      );
      assets.add(icon.asset);
    }
    expect(assets, hasLength(101));
    expect(
      photorealCategoryIconCatalog.map((x) => x.id).toSet().length,
      photorealCategoryIconCatalog.length,
    );
    expect(tree.subtree('natasha').length, 12);
    expect(
      nodes.singleWhere((x) => x.id == 'jaecoo').id,
      isNot(nodes.singleWhere((x) => x.id == 'loans-jaecoo').id),
    );
  });

  testWidgets('Personal catalog collapse, branch/child ordering and reload', (
    t,
  ) async {
    t.view.physicalSize = const Size(1200, 1600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final repo = RevisionRepo()
      ..categories.addAll(personalExpenseFixtures('personal'));
    Future<void> open() async {
      await t.pumpWidget(
        host(
          CategoriesScreen(
            key: UniqueKey(),
            space: personalSpace,
            isOwner: true,
            repository: repo,
          ),
        ),
      );
      await t.pumpAndSettle();
    }

    await open();
    expect(
      find.byKey(const ValueKey('drag-category:sasha-haircut')),
      findsNothing,
    );
    for (var i = 0; i < 3; i++) {
      await toggle(t, 'sasha');
      expect(
        find.byKey(const ValueKey('drag-category:sasha-haircut')),
        findsOneWidget,
      );
      await toggle(t, 'sasha');
      expect(
        find.byKey(const ValueKey('drag-category:sasha-haircut')),
        findsNothing,
      );
    }
    await toggle(t, 'sasha');
    await dragRow(t, 'sasha-gift', 'sasha-haircut');
    await dragRow(t, 'entertainment', 'sasha');
    expect(
      repo.categories.singleWhere((x) => x.id == 'sasha-gift').parentId,
      'sasha',
    );
    final expected = categorySnapshot(repo.categories);
    await open();
    expect(categorySnapshot(repo.categories), expected);
    expect(
      CategoryTree(repo.categories)
          .ordered(repo.categories.where((x) => x.parentId == null))
          .first
          .id,
      'entertainment',
    );
    expect(
      CategoryTree(repo.categories).children('sasha').first.id,
      'sasha-gift',
    );
    await toggle(t, 'sasha');
    expect(
      find.byKey(const ValueKey('drag-category:sasha-gift')),
      findsOneWidget,
    );
    expect(t.takeException(), isNull);
  });
}
