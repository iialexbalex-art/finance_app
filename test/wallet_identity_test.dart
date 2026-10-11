import 'dart:convert';
import 'dart:io';

import 'package:finance_app/category.dart';
import 'package:finance_app/expense.dart';
import 'package:finance_app/expense_filters_bar.dart';
import 'package:finance_app/finance_repository.dart';
import 'package:finance_app/wallet_icons.dart';
import 'package:finance_app/wallets_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'categories_screen_test.dart' show click;
import 'expense_filters_test.dart' show capture;
import 'incomes_transfers_test.dart' show prepared, open, enter, transfer;
import 'fake_auth.dart';

PendingExpense cashFlow(String request, String category) => PendingExpense(
  requestId: request,
  spaceId: 'personal',
  walletId: 'cash',
  categoryId: category,
  amountMinor: '100',
  date: '2026-10-01',
  comment: request,
  currency: 'RUB',
  scale: 2,
  walletName: 'Снимок старого имени',
  categoryPath: 'Исторический путь',
);

Future<void> tab(WidgetTester t, String name) async {
  final target = find.descendant(
    of: find.byType(TabBar),
    matching: find.text(name),
  );
  await t.ensureVisible(target);
  await t.tap(target);
  await t.pumpAndSettle();
}

Future<void> navigate(WidgetTester t, String name) async {
  final rail = find.descendant(
    of: find.byType(NavigationRail),
    matching: find.text(name),
  );
  if (rail.evaluate().isEmpty) {
    await click(t, name);
  } else {
    await t.ensureVisible(rail);
    await t.tap(rail);
    await t.pumpAndSettle();
  }
}

void main() {
  setUpAll(() async {
    if (!kIsWeb && const bool.fromEnvironment('CAPTURE_QA')) {
      await (FontLoader('Roboto')..addFont(
            File('C:/Windows/Fonts/arial.ttf')
                .readAsBytes()
                .then(ByteData.sublistView),
          ))
          .load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });
  test('Catalog preserves wallet IDs with local color resources', () {
    expect(
      walletIconCatalog.map((c) => c.id).toSet().length,
      walletIconCatalog.length,
    );
    expect(bankIconCatalog.length, 9);
    expect(
      bankIconCatalog.every((c) => c.asset.startsWith('assets/icons/banks/')),
      isTrue,
    );
    expect(resolveWalletIcon('unknown').id, 'wallet');
    for (final group in WalletGroup.values) {
      final w = Wallet(
        id: 'id',
        spaceId: 's',
        name: 'Сбербанк',
        group: group,
        currency: 'USD',
      );
      expect(
        w.displayIconId,
        {
          WalletGroup.cash: 'cash',
          WalletGroup.card: 'card',
          WalletGroup.bankAccount: 'bank',
        }[group],
      );
    }
  });

  test('Wallet transport only changes metadata and compares previous icon for conflicts', () async {
    final calls = <http.Request>[];
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test',
      accessToken: () async => 'session',
      httpClient: MockClient((r) async {
        calls.add(r);
        return http.Response(
          r.method == 'PATCH' ? jsonEncode({'id': 'w'}) : '',
          r.method == 'PATCH' ? 200 : 201,
          request: r,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(client.dispose);
    final repo = SupabaseFinanceRepository(client);
    const w = Wallet(
      id: 'w',
      spaceId: 's',
      name: 'Old',
      group: WalletGroup.cash,
      currency: 'USD',
      iconId: 'bank_alfa',
    );
    await repo.editWallet(w, 'New', WalletGroup.cash, iconId: 'bank_sber');
    expect(jsonDecode(calls.single.body), {
      'name': 'New',
      'wallet_group': 'cash',
      'icon_id': 'bank_sber',
    });
    expect(calls.single.url.queryParameters['icon_id'], 'eq.bank_alfa');
    expect(calls.single.url.queryParameters['space_id'], 'eq.s');
    await repo.createWallet(
      spaceId: 's',
      name: 'New',
      group: WalletGroup.card,
      currency: 'KZT',
      iconId: 'piggy',
    );
    expect(jsonDecode(calls.last.body)['icon_id'], 'piggy');
    expect(jsonDecode(calls.last.body)['wallet_group'], 'card');
    expect(jsonDecode(calls.last.body)['currency'], 'KZT');
  });

  for (final size in [const Size(320, 568), const Size(1440, 900)]) {
    testWidgets('Icon picker search/group and creation preview at $size', (
      t,
    ) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final repo = prepared();
      await open(t, repo, 'Кошельки');
      await click(t, 'Добавить кошелёк');
      await enter(t, 'Название', 'Новый кошелёк');
      await click(t, 'Значок: Наличные');
      await capture(t, 'icon-picker-${size.width.toInt()}');
      expect(find.byType(GridView), findsOneWidget);
      await click(t, 'Банки');
      expect(find.byKey(const ValueKey('choose-icon:cash')), findsNothing);
      await t.enterText(
        find.widgetWithText(TextField, 'Поиск значка'),
        'Тинькофф',
      );
      await t.pumpAndSettle();
      final bankT = find.byKey(const ValueKey('choose-icon:bank_t'));
      await t.ensureVisible(bankT);
      await t.tap(bankT);
      await t.pumpAndSettle();
      expect(find.text('Значок: Т-Банк / Тинькофф'), findsOneWidget);
      final form = find.byType(WalletForm);
      expect(
        find.descendant(
          of: form,
          matching: find.byWidgetPredicate(
            (w) => w is WalletMark && w.id == 'bank_t',
          ),
        ),
        findsOneWidget,
      );
      await click(t, 'Сохранить');
      expect(repo.wallets['personal']!.last.iconId, 'bank_t');
      expect(repo.wallets['personal']!.last.currency, 'RUB');
      expect(repo.wallets['personal']!.last.group, WalletGroup.cash);
      expect(t.takeException(), isNull);
    });

    testWidgets(
      'Rename and icon update appear in all history without altering snapshots at $size',
      (t) async {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final repo = prepared();
        final e = cashFlow('Expense', 'groceries'),
            income = cashFlow('Income', 'bonus');
        repo.commitExpense(e);
        repo.incomeLedger.commitExpense(income);
        repo.commitTransfer(transfer());
        final expenseBefore = repo.expenseRows['personal']!.first;
        final incomeBefore = repo.incomeLedger.expenseRows['personal']!.single;
        final transferBefore = repo.transfers['personal']!.single;
        final balanceBefore = (await repo.loadExpenseBalance('cash')).current;
        await open(t, repo, 'Расходы');
        expect(find.text('Снимок старого имени'), findsNothing);
        await navigate(t, 'Кошельки');
        final menu = find.byTooltip('Действия с кошельком').first;
        await t.ensureVisible(menu);
        await t.tap(menu);
        await t.pumpAndSettle();
        await click(t, 'Редактировать реквизиты');
        await enter(t, 'Название', 'Новое актуальное имя');
        await click(t, 'Значок: Наличные');
        await t.enterText(
          find.widgetWithText(TextField, 'Поиск значка'),
          'Kaspi',
        );
        await t.pumpAndSettle();
        final kaspi = find.byKey(const ValueKey('choose-icon:bank_kaspi'));
        await t.ensureVisible(kaspi);
        await t.tap(kaspi);
        await t.pumpAndSettle();
        await click(t, 'Сохранить реквизиты');
        expect(repo.wallets['personal']!.first.name, 'Новое актуальное имя');
        await repo.editWallet(
          repo.wallets['personal']![1],
          'Актуальный получатель',
          WalletGroup.cash,
          iconId: 'piggy',
        );
        await repo.editCategory(
          repo.categories.firstWhere((c) => c.id == 'groceries'),
          name: 'Актуальные продукты',
          iconId: 'coffee',
        );
        await repo.editCategory(
          repo.categories.firstWhere((c) => c.id == 'bonus'),
          name: 'Актуальная премия',
          iconId: 'salary',
        );
        for (final section in ['Расходы', 'Доходы', 'Переводы', 'Обзор']) {
          await navigate(t, section);
          expect(find.text('Новое актуальное имя'), findsWidgets);
          expect(find.text('Снимок старого имени'), findsNothing);
          if (section == 'Расходы' || section == 'Доходы') {
            expect(
              find.text(
                section == 'Расходы'
                    ? 'Ежедневные → Еда → Актуальные продукты'
                    : 'Работа → Актуальная премия',
              ),
              findsWidgets,
            );
            expect(find.text('Исторический путь'), findsNothing);
            expect(
              find.byWidgetPredicate(
                (w) =>
                    w is CategoryMark &&
                    w.id == (section == 'Расходы' ? 'coffee' : 'salary'),
              ),
              section == 'Расходы' ? findsNWidgets(2) : findsOneWidget,
            );
            await t.ensureVisible(
              find.text(section == 'Расходы' ? 'Expense' : 'Income').first,
            );
            await t.pumpAndSettle();
            await capture(
              t,
              'color-history-${section == 'Расходы' ? 'expense' : 'income'}-${size.width.toInt()}',
            );
          }
          expect(
            find.byWidgetPredicate(
              (w) => w is WalletMark && w.id == 'bank_kaspi',
            ),
            findsWidgets,
          );
        }
        await navigate(t, 'Расходы');
        expect(
          t
              .widget<ExpenseFiltersBar>(find.byType(ExpenseFiltersBar))
              .wallets
              .first
              .name,
          'Новое актуальное имя',
        );
        await click(t, 'Expense');
        expect(find.text('Новое актуальное имя (RUB)'), findsWidgets);
        await click(t, 'Отмена');
        await click(t, 'Комиссия перевода');
        expect(find.text('Новое актуальное имя (RUB)'), findsWidgets);
        expect(find.text('Актуальный получатель (RUB)'), findsWidgets);
        await click(t, 'Отмена');
        expect(find.text('Актуальный получатель'), findsOneWidget);
        await capture(t, 'wallet-history-${size.width.toInt()}');
        await navigate(t, 'Доходы');
        await click(t, 'Income');
        expect(find.text('Новое актуальное имя (RUB)'), findsWidgets);
        await click(t, 'Отмена');
        expect(repo.expenseRows['personal']!.first, same(expenseBefore));
        expect(
          repo.incomeLedger.expenseRows['personal']!.single,
          same(incomeBefore),
        );
        expect(repo.transfers['personal']!.single, same(transferBefore));
        expect((await repo.loadExpenseBalance('cash')).current, balanceBefore);
        expect(repo.commitExpense(e), expenseBefore.id);
        expect(t.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Category tabs keep independent same-name trees, creation kind and filters',
    (t) async {
      final repo = prepared();
      await open(t, repo, 'Категории');
      for (final name in ['Расходы', 'Доходы']) {
        await tab(t, name);
        await click(t, 'Добавить категорию');
        await t.enterText(find.byType(TextFormField), 'Одинаковое имя');
        await click(t, 'Сохранить');
        expect(find.text('Одинаковое имя'), findsOneWidget);
      }
      final identical = repo.categories
          .where((c) => c.name == 'Одинаковое имя')
          .toList();
      expect(identical.map((c) => c.kind).toSet(), CategoryKind.values.toSet());
      expect(identical.map((c) => c.id).toSet().length, 2);
      repo.onCategories = (_, _) async => repo.categories;
      await navigate(t, 'Доходы');
      final incomeBar = t.widget<ExpenseFiltersBar>(
        find.byType(ExpenseFiltersBar),
      );
      expect(
        incomeBar.categories.every((c) => c.kind == CategoryKind.income),
        isTrue,
      );
      await navigate(t, 'Расходы');
      expect(
        t
            .widget<ExpenseFiltersBar>(find.byType(ExpenseFiltersBar))
            .categories
            .every((c) => c.kind == CategoryKind.expense),
        isTrue,
      );
    },
  );

  testWidgets(
    'Pending request shows current wallet but keeps original retry JSON',
    (t) async {
      final repo = prepared();
      final pending = cashFlow('Pending', 'groceries');
      await repo.expenseDrafts.write('owner', pending);
      await repo.editWallet(
        repo.wallets['personal']!.first,
        'Актуальное имя',
        WalletGroup.cash,
        iconId: 'safe',
      );
      await open(t, repo, 'Расходы');
      expect(
        find.textContaining('Запрос ожидает подтверждения: Актуальное имя,'),
        findsOneWidget,
      );
      await click(t, 'Повторить сохранение');
      expect(repo.attemptedExpenses.last.toJson(), pending.toJson());
    },
  );

  testWidgets(
    'Manager sees current assigned wallet metadata but no icon editing',
    (t) async {
      final repo = prepared();
      await open(
        t,
        repo,
        'Кошельки',
        auth: FakeAuth(signedIn: true)..userId = 'manager',
      );
      expect(find.byTooltip('Действия с кошельком'), findsNothing);
      expect(find.byType(WalletIconField), findsNothing);
      expect(find.text('Текущий остаток'), findsNothing);
    },
  );
}
