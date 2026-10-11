import 'dart:async';

import 'package:finance_app/category.dart';
import 'package:finance_app/categories_screen.dart';
import 'package:finance_app/cashflow_delete_dialog.dart';
import 'package:finance_app/category_bulk_dialog.dart';
import 'package:finance_app/category_tree.dart';
import 'package:finance_app/expense.dart';
import 'package:finance_app/expenses_screen.dart';
import 'package:finance_app/finance_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_auth.dart';
import 'fake_finance.dart';

class BulkRepo extends FakeFinance {
  List<String> affected = [];
  String? action;
  Completer<void>? waitForDelete;
  int deleteCalls = 0;
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
    this.action = action;
    affected = ids;
    for (final id in ids) {
      final index = categories.indexWhere((c) => c.id == id);
      final c = categories[index];
      categories[index] = FinanceCategory(
        id: c.id,
        spaceId: c.spaceId,
        kind: c.kind,
        name: c.name,
        parentId: c.parentId,
        isArchived: action == 'archive',
        sortOrder: c.sortOrder,
      );
    }
  }

  @override
  Future<void> reorderCategories(
    String requestId,
    String spaceId,
    CategoryKind kind,
    String? parentId,
    List<String> ids,
    List<FinanceCategory> snapshot,
  ) async {
    affected = ids;
    action = 'reorder';
    for (var order = 0; order < ids.length; order++) {
      final index = categories.indexWhere((c) => c.id == ids[order]);
      final c = categories[index];
      categories[index] = FinanceCategory(
        id: c.id,
        spaceId: c.spaceId,
        kind: c.kind,
        name: c.name,
        parentId: c.parentId,
        sortOrder: order + 1,
      );
    }
  }

  @override
  Future<void> deleteCashflow(
    String requestId,
    String spaceId,
    CategoryKind kind,
    List<Expense> rows,
  ) async {
    deleteCalls++;
    affected = rows.map((e) => e.id).toList();
    await waitForDelete?.future;
    final ledger = kind == CategoryKind.income ? incomeLedger : this;
    ledger.expenseRows[spaceId]?.removeWhere((e) => affected.contains(e.id));
  }
}

Future<void> tapText(WidgetTester t, String text) async {
  await t.ensureVisible(find.text(text).last);
  await t.tap(find.text(text).last);
  await t.pumpAndSettle();
}

FinanceCategory cat(
  String id,
  String space,
  CategoryKind kind, {
  String? parent,
  int order = 0,
}) => FinanceCategory(
  id: id,
  spaceId: space,
  kind: kind,
  name: id,
  parentId: parent,
  sortOrder: order,
);
Expense operation(
  String id,
  String currency,
  BigInt amount, {
  String? transfer,
}) => Expense(
  id: id,
  date: '2026-10-06',
  amount: amount,
  currency: currency,
  scale: 2,
  walletName: 'Касса',
  categoryPath: 'Категория',
  comment: id,
  walletId: 'cash',
  categoryId: 'root',
  revision: 'revision-$id',
  transferId: transfer,
);
Widget host(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  testWidgets(
    'Used category needs an active replacement outside deleted branch',
    (t) async {
      final root = cat('root', 'business', CategoryKind.expense);
      final child = cat(
        'child',
        'business',
        CategoryKind.expense,
        parent: 'root',
      );
      final replacement = cat('replacement', 'business', CategoryKind.expense);
      final archived = FinanceCategory(
        id: 'archived',
        spaceId: 'business',
        kind: CategoryKind.expense,
        name: 'archived',
        isArchived: true,
      );
      await t.pumpWidget(
        host(
          CategoryBulkDialog(
            action: 'delete',
            selected: [root, child],
            tree: CategoryTree([root, child, replacement, archived]),
            usage: [
              {'id': 'child', 'expenses': 1, 'incomes': 0, 'transfers': 1},
            ],
          ),
        ),
      );
      expect(find.text('Удалить категории: 2?'), findsOneWidget);
      expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Удалить'))
            .onPressed,
        isNull,
      );
      await t.tap(find.byType(DropdownButtonFormField<String>));
      await t.pumpAndSettle();
      expect(find.text('archived'), findsNothing);
      await tapText(t, 'replacement');
      expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Удалить'))
            .onPressed,
        isNotNull,
      );
    },
  );
  testWidgets(
    'Individual operation delete menu allows cancellation and refresh',
    (t) async {
      final auth = FakeAuth(signedIn: true);
      addTearDown(auth.dispose);
      final repo = BulkRepo();
      var refreshed = 0;
      repo.wallets['personal'] = [
        const Wallet(
          id: 'cash',
          spaceId: 'personal',
          name: 'Касса',
          group: WalletGroup.cash,
          currency: 'RUB',
        ),
      ];
      repo.expenseRows['personal'] = [
        operation('single', 'RUB', BigInt.from(20000)),
      ];
      await t.pumpWidget(
        host(
          ExpensesScreen(
            space: personalSpace,
            isOwner: true,
            userId: 'owner',
            auth: auth,
            repository: repo,
            onChanged: () => refreshed++,
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.ensureVisible(
        find.byKey(const ValueKey('operation-menu:single')),
      );
      await t.tap(find.byKey(const ValueKey('operation-menu:single')));
      await t.pumpAndSettle();
      await tapText(t, 'Удалить операцию');
      await tapText(t, 'Отмена');
      expect(repo.deleteCalls, 0);
      await t.tap(find.byKey(const ValueKey('operation-menu:single')));
      await t.pumpAndSettle();
      await tapText(t, 'Удалить операцию');
      await tapText(t, 'Удалить');
      expect(repo.deleteCalls, 1);
      expect(refreshed, 1);
      expect(repo.expenseRows['personal'], isEmpty);
    },
  );
  for (final space in [personalSpace, businessSpace]) {
    for (final kind in CategoryKind.values) {
      testWidgets(
        'Collapsed branch, partial check, bulk archive/restore and context reset ${space.kind} ${kind.value}',
        (t) async {
          final repo = BulkRepo()
            ..categories.addAll([
              cat('root', space.id, kind, order: 1),
              cat('child', space.id, kind, parent: 'root'),
              cat('sibling', space.id, kind, order: 2),
            ]);
          await t.pumpWidget(
            host(
              CategoriesScreen(space: space, isOwner: true, repository: repo),
            ),
          );
          await t.pumpAndSettle();
          if (kind == CategoryKind.income) await tapText(t, 'Доходы');
          expect(
            find.byKey(const ValueKey('select-category:child')),
            findsNothing,
          );
          await t.tap(find.byKey(const ValueKey('select-category:root')));
          await t.pumpAndSettle();
          expect(find.text('Выбрано: 2'), findsOneWidget);
          await t.tap(find.byKey(const ValueKey('expand-category:root')));
          await t.pumpAndSettle();
          await t.tap(find.byKey(const ValueKey('select-category:child')));
          await t.pumpAndSettle();
          await t.tap(find.byKey(const ValueKey('select-category:child')));
          await t.pumpAndSettle();
          expect(
            t
                .widget<Checkbox>(
                  find.byKey(const ValueKey('select-category:root')),
                )
                .value,
            isNull,
          );
          await t.tap(find.byKey(const ValueKey('select-category:root')));
          await t.pumpAndSettle();
          await tapText(t, 'Архивировать');
          await tapText(t, 'Архивировать');
          expect(repo.affected.toSet(), {'root', 'child'});
          expect(repo.action, 'archive');
          await t.tap(find.byKey(const ValueKey('select-category:root')));
          await t.pumpAndSettle();
          await tapText(t, 'Восстановить');
          await tapText(t, 'Восстановить');
          expect(repo.action, 'restore');
          await t.tap(find.byKey(const ValueKey('select-category:child')));
          await t.pumpAndSettle();
          await tapText(t, kind == CategoryKind.income ? 'Расходы' : 'Доходы');
          expect(find.textContaining('Выбрано:'), findsNothing);
        },
      );
    }
  }
  testWidgets(
    'Filtered select-all and sibling menu ordering preserve expansion',
    (t) async {
      final repo = BulkRepo()
        ..categories.addAll([
          cat('root', 'personal', CategoryKind.expense, order: 1),
          cat('child', 'personal', CategoryKind.expense, parent: 'root'),
          cat('sibling', 'personal', CategoryKind.expense, order: 2),
        ]);
      await t.pumpWidget(
        host(
          CategoriesScreen(
            space: personalSpace,
            isOwner: true,
            repository: repo,
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), 'child');
      await t.pumpAndSettle();
      await tapText(t, 'Выделить все');
      expect(find.text('Выбрано: 1'), findsOneWidget);
      await tapText(t, 'Снять выделение');
      await t.enterText(find.byType(TextField), '');
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('expand-category:root')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('category-menu:root')));
      await t.pumpAndSettle();
      await tapText(t, 'Опустить ниже');
      expect(repo.affected, ['sibling', 'root']);
      expect(
        find.byKey(const ValueKey('select-category:child')),
        findsOneWidget,
      );
      final drag = await t.startGesture(
        t.getCenter(find.byKey(const ValueKey('drag-category:root'))),
      );
      await drag.moveTo(
        t.getCenter(find.byKey(const ValueKey('drag-category:sibling'))) -
            const Offset(30, 15),
      );
      await t.pump();
      expect(
        find.byWidgetPredicate((w) => w is Divider && w.thickness == 3),
        findsOneWidget,
      );
      await drag.up();
      await t.pumpAndSettle();
      expect(repo.affected, ['root', 'sibling']);
      expect(
        find.byKey(const ValueKey('select-category:child')),
        findsOneWidget,
      );
      await t.pumpWidget(
        host(
          CategoriesScreen(
            key: const ValueKey('reload'),
            space: personalSpace,
            isOwner: true,
            repository: repo,
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(
        t.getTopLeft(find.byKey(const ValueKey('select-category:root'))).dy,
        lessThan(
          t
              .getTopLeft(find.byKey(const ValueKey('select-category:sibling')))
              .dy,
        ),
      );
    },
  );
  test('Deletion totals retain currency and exact aggregate precision', () {
    final max = BigInt.parse('9223372036854775807');
    final totals = deletionTotals([
      operation('a', 'RUB', max),
      operation('b', 'RUB', max),
      operation('c', 'USD', BigInt.from(123)),
    ]);
    expect(totals['RUB']!.$2, max * BigInt.two);
    expect(totals['USD']!.$2, BigInt.from(123));
  });
  for (final space in [personalSpace, businessSpace]) {
    for (final income in [false, true]) {
      testWidgets(
        'Bulk cashflow confirmation, currencies, blocking and fee exclusion ${space.kind} $income',
        (t) async {
          final auth = FakeAuth(signedIn: true);
          addTearDown(auth.dispose);
          final repo = BulkRepo()
            ..wallets[space.id] = [
              Wallet(
                id: 'cash',
                spaceId: space.id,
                name: 'Касса',
                group: WalletGroup.cash,
                currency: 'RUB',
              ),
            ];
          final ledger = income ? repo.incomeLedger : repo;
          ledger.expenseRows[space.id] = [
            operation('a', 'RUB', BigInt.from(20000)),
            operation('b', 'USD', BigInt.from(123)),
          ];
          if (!income) {
            ledger.expenseRows[space.id]!.add(
              operation('fee', 'RUB', BigInt.from(100), transfer: 'transfer'),
            );
          }
          await t.pumpWidget(
            host(
              ExpensesScreen(
                space: space,
                isOwner: true,
                userId: 'owner',
                auth: auth,
                repository: repo,
                isIncome: income,
              ),
            ),
          );
          await t.pumpAndSettle();
          await tapText(t, 'Выделить все операции');
          expect(find.text('Выбрано операций: 2'), findsOneWidget);
          await tapText(t, 'Удалить выбранные');
          expect(find.text('200,00 RUB'), findsOneWidget);
          expect(find.text('1,23 USD'), findsOneWidget);
          expect(find.textContaining('a'), findsWidgets);
          repo.waitForDelete = Completer<void>();
          await t.tap(find.widgetWithText(FilledButton, 'Удалить'));
          await t.pump();
          expect(repo.deleteCalls, 1);
          expect(repo.affected.toSet(), {'a', 'b'});
          expect(
            t
                .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Удалить выбранные'),
                )
                .onPressed,
            isNull,
          );
          repo.waitForDelete!.complete();
          await t.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('select-operation:a')),
            findsNothing,
          );
          if (!income) {
            expect(
              find.byKey(const ValueKey('select-operation:fee')),
              findsOneWidget,
            );
          }
          expect(t.takeException(), isNull);
        },
      );
    }
  }
}
