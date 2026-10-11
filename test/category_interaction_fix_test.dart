import 'dart:async';

import 'package:finance_app/category.dart';
import 'package:finance_app/categories_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'bulk_actions_test.dart';
import 'fake_finance.dart';

class RevisionRepo extends BulkRepo {
  int version = 0;
  Completer<void>? reorderWait;
  final orders = <List<String>>[];
  @override
  Future<void> reorderCategories(
    String requestId,
    String spaceId,
    CategoryKind kind,
    String? parentId,
    List<String> ids,
    List<FinanceCategory> snapshot,
  ) async {
    expect(
      categorySnapshot(snapshot),
      categorySnapshot(
        categories
            .where((c) => c.spaceId == spaceId && c.kind == kind)
            .toList(),
      ),
    );
    expect(
      ids.toSet(),
      categories
          .where(
            (c) =>
                c.spaceId == spaceId &&
                c.kind == kind &&
                c.parentId == parentId,
          )
          .map((c) => c.id)
          .toSet(),
    );
    orders.add([...ids]);
    await reorderWait?.future;
    version++;
    for (var i = 0; i < ids.length; i++) {
      final index = categories.indexWhere((c) => c.id == ids[i]);
      final c = categories[index];
      categories[index] = FinanceCategory(
        id: c.id,
        spaceId: c.spaceId,
        kind: c.kind,
        name: c.name,
        parentId: c.parentId,
        isArchived: c.isArchived,
        iconId: c.iconId,
        sortOrder: i + 1,
        revision: '$version:${c.id}',
      );
    }
  }

  @override
  Future<List<Map<String, dynamic>>> categoryDeletePlan(
    String spaceId,
    CategoryKind kind,
    List<String> ids,
    List<FinanceCategory> snapshot,
  ) async => [
    for (final id in ids)
      {'id': id, 'expenses': 0, 'incomes': 0, 'transfers': 0},
  ];
  @override
  Future<void> mutateCategories(
    String requestId,
    String spaceId,
    CategoryKind kind,
    String action,
    List<String> ids,
    List<FinanceCategory> snapshot, {
    Map<String, String> replacements = const {},
  }) async {
    if (action == 'delete') {
      categories.removeWhere((c) => ids.contains(c.id));
      return;
    }
    await super.mutateCategories(
      requestId,
      spaceId,
      kind,
      action,
      ids,
      snapshot,
      replacements: replacements,
    );
  }
}

Future<void> toggle(WidgetTester t, String id) async {
  final button = find.byKey(ValueKey('expand-category:$id'));
  await t.ensureVisible(button);
  await t.tap(button);
  await t.pumpAndSettle();
}

Future<void> dragRow(WidgetTester t, String from, String to) async {
  final source = find.byKey(ValueKey('drag-category:$from'));
  final target = find.byKey(ValueKey('drag-category:$to'));
  await t.ensureVisible(source);
  await t.ensureVisible(target);
  final gesture = await t.startGesture(t.getCenter(source));
  await gesture.moveTo(t.getCenter(target) - const Offset(30, 15));
  await t.pump();
  expect(
    find.byWidgetPredicate((w) => w is Divider && w.thickness == 3),
    findsOneWidget,
  );
  await gesture.up();
  await t.pumpAndSettle();
}

void main() {
  for (final space in [personalSpace, businessSpace]) {
    for (final kind in CategoryKind.values) {
      testWidgets(
        'Filter collapse, independent controls, revision-safe drags and deletion ${space.kind} ${kind.value}',
        (t) async {
          final repo = RevisionRepo()
            ..categories.addAll([
              cat('root', space.id, kind, order: 1),
              cat('child', space.id, kind, parent: 'root', order: 1),
              cat('leaf', space.id, kind, parent: 'child'),
              cat('child2', space.id, kind, parent: 'root', order: 2),
              cat('other', space.id, kind, order: 2),
              cat('gone', space.id, kind, order: 3),
              FinanceCategory(
                id: 'archive',
                spaceId: space.id,
                kind: kind,
                name: 'archive',
                isArchived: true,
                sortOrder: 4,
              ),
            ]);
          await t.pumpWidget(
            host(
              CategoriesScreen(space: space, isOwner: true, repository: repo),
            ),
          );
          await t.pumpAndSettle();
          if (kind == CategoryKind.income) await tapText(t, 'Доходы');
          await tapText(t, 'Активные');
          expect(
            find.byKey(const ValueKey('select-category:leaf')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('expand-category:leaf')),
            findsNothing,
          );
          for (var repeat = 0; repeat < 3; repeat++) {
            await toggle(t, 'child');
            expect(
              find.byKey(const ValueKey('select-category:leaf')),
              findsNothing,
            );
            expect(
              find.byKey(const ValueKey('select-category:child2')),
              findsOneWidget,
            );
            expect(
              find.byKey(const ValueKey('drag-category:child')),
              findsOneWidget,
            );
            await toggle(t, 'child');
            expect(
              find.byKey(const ValueKey('select-category:leaf')),
              findsOneWidget,
            );
            await toggle(t, 'root');
            expect(
              find.byKey(const ValueKey('select-category:child')),
              findsNothing,
            );
            expect(
              t
                  .widget<IconButton>(
                    find.byKey(const ValueKey('expand-category:root')),
                  )
                  .icon,
              isA<Icon>().having((i) => i.icon, 'icon', Icons.add),
            );
            await toggle(t, 'root');
            expect(
              find.byKey(const ValueKey('select-category:leaf')),
              findsOneWidget,
            );
          }
          await t.tap(find.byKey(const ValueKey('select-category:child')));
          await t.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('select-category:leaf')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('drag-category:child')),
            findsOneWidget,
          );
          await dragRow(t, 'other', 'root');
          expect(repo.orders.last, ['other', 'root', 'gone', 'archive']);
          expect(
            find.byKey(const ValueKey('select-category:leaf')),
            findsOneWidget,
          );
          await dragRow(t, 'child2', 'child');
          expect(repo.orders.last, ['child2', 'child']);
          await dragRow(t, 'root', 'other');
          expect(repo.orders.last, ['root', 'other', 'gone', 'archive']);
          expect(repo.version, 3);
          await tapText(t, 'Снять выделение');
          await t.tap(find.byKey(const ValueKey('select-category:gone')));
          await t.pumpAndSettle();
          await tapText(t, 'Удалить');
          await tapText(t, 'Удалить');
          expect(
            find.byKey(const ValueKey('drag-category:gone')),
            findsNothing,
          );
          expect(find.textContaining('Выбрано:'), findsNothing);
          await dragRow(t, 'other', 'root');
          expect(repo.orders.last, ['other', 'root', 'archive']);
          await t.enterText(find.byType(TextField), 'root');
          await t.pumpAndSettle();
          await toggle(t, 'root');
          expect(
            find.byKey(const ValueKey('select-category:child')),
            findsNothing,
          );
          expect(
            find.byKey(const ValueKey('drag-category:root')),
            findsOneWidget,
          );
          await toggle(t, 'root');
          expect(
            find.byKey(const ValueKey('select-category:leaf')),
            findsOneWidget,
          );
          await t.pumpWidget(
            host(
              CategoriesScreen(
                key: const ValueKey('reload'),
                space: space,
                isOwner: true,
                repository: repo,
              ),
            ),
          );
          await t.pumpAndSettle();
          if (kind == CategoryKind.income) await tapText(t, 'Доходы');
          expect(
            t.getTopLeft(find.byKey(const ValueKey('drag-category:other'))).dy,
            lessThan(
              t.getTopLeft(find.byKey(const ValueKey('drag-category:root'))).dy,
            ),
          );
          expect(t.takeException(), isNull);
        },
      );
    }
  }
}
