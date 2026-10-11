import 'dart:async';

import 'package:finance_app/category.dart';
import 'package:finance_app/expense.dart';
import 'package:finance_app/finance_repository.dart';
import 'package:finance_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'fake_auth.dart';
import 'fake_finance.dart';
import 'categories_screen_test.dart' show click;

FakeFinance prepared({String space = 'personal'}) => FakeFinance()
  ..wallets[space] = [
    Wallet(
      id: 'cash',
      spaceId: space,
      name: 'Касса',
      group: WalletGroup.cash,
      currency: 'RUB',
    ),
  ]
  ..categories.addAll([
    FinanceCategory(
      id: 'daily',
      spaceId: space,
      kind: CategoryKind.expense,
      name: 'Ежедневные',
    ),
    FinanceCategory(
      id: 'food',
      spaceId: space,
      kind: CategoryKind.expense,
      name: 'Еда',
      parentId: 'daily',
    ),
    FinanceCategory(
      id: 'groceries',
      spaceId: space,
      kind: CategoryKind.expense,
      name: 'Продукты',
      parentId: 'food',
    ),
    FinanceCategory(
      id: 'archive',
      spaceId: space,
      kind: CategoryKind.expense,
      name: 'Архив',
      isArchived: true,
    ),
    FinanceCategory(
      id: 'hidden',
      spaceId: space,
      kind: CategoryKind.expense,
      name: 'Скрытая',
      parentId: 'archive',
    ),
  ]);

Finder field(String label) => find.ancestor(
  of: find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label,
  ),
  matching: find.byType(TextFormField),
);
Future<void> openExpenses(
  WidgetTester t,
  FakeAuth auth,
  FakeFinance repo,
) async {
  await t.pumpWidget(FinanceApp(auth: auth, repository: repo));
  await t.pumpAndSettle();
  await click(t, 'Расходы');
}

Future<void> fill(WidgetTester t, {String amount = '250,00'}) async {
  await click(t, 'Добавить расход');
  await t.enterText(field('Сумма (RUB)'), amount);
  final category = find.byWidgetPredicate(
    (w) =>
        w is DropdownButtonFormField<String> &&
        w.decoration.labelText == 'Категория расхода',
  );
  await t.ensureVisible(category);
  await t.tap(category);
  await t.pumpAndSettle();
  expect(find.text('Архив'), findsNothing);
  expect(find.text('Архив → Скрытая'), findsNothing);
  await click(t, 'Ежедневные → Еда → Продукты');
  await t.enterText(field('Комментарий (необязательно)'), 'Покупка');
}

void main() {
  for (final size in [const Size(320, 568), const Size(1440, 900)]) {
    testWidgets(
      'Owner expense validates, saves once, refreshes history/balance at $size',
      (t) async {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final auth = FakeAuth(signedIn: true);
        addTearDown(auth.dispose);
        final repo = prepared()..balances['cash'] = BigInt.from(100000);
        await openExpenses(t, auth, repo);
        await fill(t, amount: '1,234');
        await click(t, 'Сохранить расход');
        expect(repo.expenseWrites, 0);
        expect(find.textContaining('без округления'), findsOneWidget);
        await t.enterText(field('Сумма (RUB)'), '250,00');
        final pending = Completer<String>();
        repo.onExpenseSave = (p) => pending.future;
        await click(t, 'Сохранить расход');
        await click(t, 'Сохраняем…');
        expect(repo.expenseWrites, 1);
        expect(find.text('Расход сохранён.'), findsNothing);
        final p = repo.attemptedExpenses.single;
        expect(
          (await repo.expenseDrafts.read('owner', 'personal'))!.requestId,
          p.requestId,
        );
        pending.complete(repo.commitExpense(p));
        await t.pumpAndSettle();
        expect(find.text('Расход сохранён.'), findsOneWidget);
        expect(find.text('−250,00 RUB'), findsNWidgets(2));
        expect(find.text('Покупка'), findsOneWidget);
        expect(await repo.expenseDrafts.read('owner', 'personal'), isNull);
        expect(t.takeException(), isNull);
      },
    );
  }
  testWidgets('Lost response, reload, retry stable ID produces one expense', (
    t,
  ) async {
    final auth = FakeAuth(signedIn: true);
    addTearDown(auth.dispose);
    final repo = prepared();
    repo.onExpenseSave = (p) async {
      repo.commitExpense(p);
      throw Exception('response lost');
    };
    await openExpenses(t, auth, repo);
    await fill(t);
    await click(t, 'Сохранить расход');
    expect(find.text('Расход сохранён.'), findsNothing);
    expect(find.text('Покупка'), findsOneWidget);
    final id = repo.attemptedExpenses.single.requestId;
    await t.pumpWidget(const SizedBox());
    await t.pumpAndSettle();
    repo.onExpenseSave = null;
    await openExpenses(t, auth, repo);
    expect(find.text('Повторить сохранение'), findsOneWidget);
    await click(t, 'Повторить сохранение');
    expect(repo.attemptedExpenses.last.requestId, id);
    expect(repo.expenseRows['personal']!.length, 1);
    expect(find.text('Расход сохранён.'), findsOneWidget);
  });
  testWidgets('Manager sees own returned history, never requests balances', (
    t,
  ) async {
    final auth = FakeAuth(signedIn: true)..userId = 'manager';
    addTearDown(auth.dispose);
    final repo = prepared(space: 'business')..spaces = [businessSpace];
    await openExpenses(t, auth, repo);
    await fill(t);
    await click(t, 'Сохранить расход');
    expect(repo.currentReads, 0);
    expect(repo.balanceReads, 0);
    expect(find.textContaining('Текущий остаток'), findsNothing);
    expect(find.text('Покупка'), findsOneWidget);
  });
  testWidgets(
    'Pagination beyond first page and opening edits preserve expenses',
    (t) async {
      final auth = FakeAuth(signedIn: true);
      addTearDown(auth.dispose);
      final repo = prepared();
      for (var i = 0; i < 30; i++) {
        repo.commitExpense(
          PendingExpense(
            requestId: newExpenseRequestId(),
            spaceId: 'personal',
            walletId: 'cash',
            categoryId: 'daily',
            amountMinor: '100',
            date: '2026-09-30',
            comment: 'row-$i',
            currency: 'RUB',
            scale: 2,
            walletName: 'Касса',
            categoryPath: 'Ежедневные',
          ),
        );
      }
      await openExpenses(t, auth, repo);
      expect(find.textContaining('row-'), findsNWidgets(25));
      expect(find.text('−30,00 RUB'), findsOneWidget);
      await click(t, 'Загрузить ещё');
      expect(find.textContaining('row-'), findsNWidgets(30));
      repo.balances['cash'] = BigInt.from(5000);
      await click(t, 'Обновить расходы');
      expect(find.text('−30,00 RUB'), findsOneWidget);
      expect(repo.expenseRows['personal']!.length, 30);
    },
  );
  testWidgets('Rejected category retains fields and allows correction', (
    t,
  ) async {
    final auth = FakeAuth(signedIn: true);
    addTearDown(auth.dispose);
    final repo = prepared();
    repo.onExpenseSave = (p) async =>
        throw const PostgrestException(message: 'archived', code: 'P1001');
    await openExpenses(t, auth, repo);
    await fill(t);
    await click(t, 'Сохранить расход');
    expect(find.text('Покупка'), findsOneWidget);
    expect(find.textContaining('Категория или её предок'), findsOneWidget);
    expect(t.widget<TextFormField>(field('Сумма (RUB)')).enabled, isTrue);
    expect(await repo.expenseDrafts.read('owner', 'personal'), isNull);
  });
  testWidgets(
    'Space switch during request cannot put result in another context',
    (t) async {
      final auth = FakeAuth(signedIn: true);
      addTearDown(auth.dispose);
      final repo = prepared();
      final pending = Completer<String>();
      repo.onExpenseSave = (_) => pending.future;
      await openExpenses(t, auth, repo);
      await fill(t);
      await click(t, 'Сохранить расход');
      await click(t, 'Личные финансы');
      await click(t, 'Бизнес');
      pending.complete(repo.commitExpense(repo.attemptedExpenses.single));
      await t.pumpAndSettle();
      expect(repo.expenseRows['personal']!.length, 1);
      expect(repo.expenseRows['business'], isNull);
      expect(find.text('Расход сохранён.'), findsNothing);
      expect(find.text('Покупка'), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('Empty inputs and loading failure have clear retry', (t) async {
    final auth = FakeAuth(signedIn: true);
    addTearDown(auth.dispose);
    final repo = FakeFinance();
    repo.onExpenses = (_, _) async => throw Exception('offline');
    await openExpenses(t, auth, repo);
    expect(find.textContaining('Проверьте подключение'), findsOneWidget);
    repo.onExpenses = null;
    await click(t, 'Обновить расходы');
    expect(find.textContaining('Нет доступных кошельков'), findsOneWidget);
    expect(
      find.textContaining('Нет доступных неархивных категорий'),
      findsOneWidget,
    );
  });
}
