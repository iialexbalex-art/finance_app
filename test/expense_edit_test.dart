import 'dart:async';
import 'dart:convert';

import 'package:finance_app/expense.dart';
import 'package:finance_app/expense_draft_store.dart';
import 'package:finance_app/finance_repository.dart';
import 'package:finance_app/category.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'categories_screen_test.dart' show click;
import 'expenses_screen_test.dart' show prepared, field, openExpenses;
import 'fake_auth.dart';
import 'fake_finance.dart';

PendingExpense seed({
  String id = 'expense',
  String date = '2024-02-29',
  String category = 'groceries',
}) => PendingExpense(
  requestId: id,
  spaceId: 'personal',
  walletId: 'cash',
  categoryId: category,
  amountMinor: '25000',
  date: date,
  comment: 'Исходный расход',
  currency: 'RUB',
  scale: 2,
  walletName: 'Касса',
  categoryPath: 'Ежедневные → Еда → Продукты',
);

FakeFinance editable() => prepared()
  ..wallets['personal']!.addAll([
    const Wallet(
      id: 'second',
      spaceId: 'personal',
      name: 'Вторая касса',
      group: WalletGroup.cash,
      currency: 'RUB',
    ),
    const Wallet(
      id: 'usd',
      spaceId: 'personal',
      name: 'Доллары',
      group: WalletGroup.cash,
      currency: 'USD',
    ),
  ])
  ..balances['cash'] = BigInt.from(100000)
  ..balances['second'] = BigInt.from(200000)
  ..commitExpense(seed());

Future<void> selectWallet(WidgetTester t, String label) async {
  final dropdown = find.byWidgetPredicate(
    (w) =>
        w is DropdownButtonFormField<String> &&
        w.decoration.labelText == 'Кошелёк',
  );
  await t.ensureVisible(dropdown);
  await t.tap(dropdown);
  await t.pumpAndSettle();
  await click(t, label);
}

void main() {
  test('Russian calendar date roundtrips boundaries, leap day, past/future and timezone-independent components', () {
    for (final iso in [
      '0001-01-01',
      '1900-01-01',
      '2024-02-29',
      '2026-09-30',
      '2150-12-31',
      '9999-12-31',
    ]) {
      final date = parseExpenseDate(iso);
      expect(
        expenseDate(parseRussianExpenseDate(russianExpenseDate(date))),
        iso,
      );
      expect(expenseDate(DateTime.utc(date.year, date.month, date.day)), iso);
    }
    expect(
      russianExpenseDate(parseExpenseDate('2026-09-30')),
      '30 сентября 2026',
    );
    for (final invalid in [
      '29 февраля 2025',
      '31 апреля 2026',
      '1 января 0',
      '1 января 10000',
      '2026-09-30',
      '30 сентябрь 2026',
    ]) {
      expect(() => parseRussianExpenseDate(invalid), throwsFormatException);
    }
  });

  test(
    'Edit journal keeps separate tab requests and lossless RPC transport',
    () async {
      final p = PendingExpense(
        requestId: newExpenseRequestId(),
        spaceId: 'space',
        walletId: 'wallet',
        categoryId: 'category',
        amountMinor: '9007199254740993',
        date: '0001-01-01',
        comment: 'Правка',
        currency: 'USD',
        scale: 2,
        walletName: 'USD',
        categoryPath: 'Категория',
        expenseId: 'expense',
        expectedRevision: 'revision',
        originalCategoryId: 'old',
        originalCategoryPath: 'Архив',
      );
      final restored = PendingExpense.fromJson(
        jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>,
      );
      expect(restored.params, p.params);
      expect(restored.originalCategoryId, 'old');
      final store = MemoryExpenseDraftStore();
      await store.write('owner', p);
      final second = PendingExpense.fromJson({
        ...p.toJson(),
        'p_request_id': newExpenseRequestId(),
      });
      await store.write('owner', second);
      await store.clear('owner', 'space', requestId: p.requestId);
      expect((await store.read('owner', 'space'))!.requestId, second.requestId);
      final calls = <http.Request>[];
      final client = SupabaseClient(
        'https://example.supabase.co',
        'test',
        accessToken: () async => 'session',
        httpClient: MockClient((req) async {
          calls.add(req);
          return http.Response(
            jsonEncode('expense'),
            200,
            request: req,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(client.dispose);
      final repo = SupabaseFinanceRepository(client);
      await repo.editExpense(p);
      await repo.editExpense(restored);
      expect(calls.first.url.path, endsWith('/rpc/edit_expense'));
      expect(calls.first.body, calls.last.body);
      expect(
        jsonDecode(calls.first.body)['p_amount_minor'],
        '9007199254740993',
      );
      expect(jsonDecode(calls.first.body)['p_expected_revision'], 'revision');
      expect(jsonDecode(calls.first.body).containsKey('author_id'), false);
      expect(calls.first.headers['authorization'], 'Bearer session');
    },
  );

  for (final size in [const Size(320, 568), const Size(1440, 900)]) {
    testWidgets(
      'Whole row opens saved date; cancel preserves row; edit moves both balances $size',
      (t) async {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final auth = FakeAuth(signedIn: true);
        addTearDown(auth.dispose);
        final repo = editable();
        await openExpenses(t, auth, repo);
        await click(t, 'Исходный расход');
        expect(find.text('Редактирование расхода'), findsOneWidget);
        expect(
          t.widget<TextFormField>(field('Дата')).controller!.text,
          '29 февраля 2024',
        );
        await t.enterText(field('Сумма (RUB)'), '999');
        await click(t, 'Отмена');
        expect(repo.attemptedEdits, isEmpty);
        expect(repo.expenseRows['personal']!.single.amount, BigInt.from(25000));
        await click(t, 'Исходный расход');
        await selectWallet(t, 'Вторая касса (RUB)');
        expect(
          t.widget<TextFormField>(field('Сумма (RUB)')).controller!.text,
          '250,00',
        );
        await t.enterText(field('Сумма (RUB)'), '300');
        await t.enterText(field('Дата'), '31 декабря 2150');
        await t.enterText(field('Комментарий (необязательно)'), 'Правка');
        final completion = Completer<String>();
        repo.onExpenseEdit = (_) => completion.future;
        await click(t, 'Сохранить');
        await click(t, 'Сохраняем…');
        expect(repo.attemptedEdits, hasLength(1));
        completion.complete(repo.commitEdit(repo.attemptedEdits.single));
        await t.pumpAndSettle();
        expect(repo.expenseRows['personal']!.single.id, 'expense');
        expect(repo.expenseRows['personal']!.single.date, '2150-12-31');
        expect(
          (await repo.loadExpenseBalance('cash')).current,
          BigInt.from(100000),
        );
        expect(find.text('−300,00 RUB'), findsNWidgets(2));
        expect(find.textContaining('31 декабря 2150'), findsOneWidget);
        expect(t.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'New expense defaults local today and calendar supports full range',
    (t) async {
      final auth = FakeAuth(signedIn: true);
      addTearDown(auth.dispose);
      await openExpenses(t, auth, editable());
      await click(t, 'Добавить расход');
      expect(
        t.widget<TextFormField>(field('Дата')).controller!.text,
        russianExpenseDate(DateTime.now()),
      );
      for (final iso in ['0001-01-01', '9999-12-31']) {
        await t.enterText(
          field('Дата'),
          russianExpenseDate(parseExpenseDate(iso)),
        );
        final calendar = find.byTooltip('Выбрать дату');
        await t.ensureVisible(calendar);
        await t.tap(calendar);
        await t.pumpAndSettle();
        final picker = t.widget<DatePickerDialog>(
          find.byType(DatePickerDialog),
        );
        expect(expenseDate(picker.firstDate), '0001-01-01');
        expect(expenseDate(picker.lastDate), '9999-12-31');
        expect(expenseDate(picker.initialDate!), iso);
        await t.tap(find.widgetWithText(TextButton, 'ОК'));
        await t.pumpAndSettle();
        expect(
          t.widget<TextFormField>(field('Дата')).controller!.text,
          russianExpenseDate(parseExpenseDate(iso)),
        );
      }
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'Currency change requires new amount and archived current category remains selectable',
    (t) async {
      final auth = FakeAuth(signedIn: true);
      addTearDown(auth.dispose);
      final repo = editable();
      final index = repo.categories.indexWhere((c) => c.id == 'daily');
      repo.categories[index] = const FinanceCategory(
        id: 'daily',
        spaceId: 'personal',
        kind: CategoryKind.expense,
        name: 'Ежедневные',
        isArchived: true,
      );
      await openExpenses(t, auth, repo);
      await click(t, 'Исходный расход');
      expect(find.textContaining('архивная; можно оставить'), findsOneWidget);
      await selectWallet(t, 'Доллары (USD)');
      expect(
        t.widget<TextFormField>(field('Сумма (USD)')).controller!.text,
        isEmpty,
      );
      expect(find.textContaining('Новая валюта: USD'), findsOneWidget);
      await click(t, 'Сохранить');
      expect(repo.attemptedEdits, isEmpty);
      await t.enterText(field('Сумма (USD)'), '10,01');
      await click(t, 'Сохранить');
      expect(repo.attemptedEdits.single.currency, 'USD');
      expect(repo.attemptedEdits.single.categoryId, 'groceries');
      expect(repo.attemptedEdits.single.amountMinor, '1001');
    },
  );

  testWidgets(
    'Lost edit response survives reload and reuses same payload without duplicate',
    (t) async {
      final auth = FakeAuth(signedIn: true);
      addTearDown(auth.dispose);
      final repo = editable();
      repo.onExpenseEdit = (p) async {
        repo.commitEdit(p);
        throw Exception('lost');
      };
      await openExpenses(t, auth, repo);
      await click(t, 'Исходный расход');
      await t.enterText(field('Дата'), '1 января 1900');
      await t.enterText(
        field('Комментарий (необязательно)'),
        'Сохранённая правка',
      );
      await click(t, 'Сохранить');
      final first = repo.attemptedEdits.single;
      expect(
        t.widget<TextFormField>(field('Дата')).controller!.text,
        '1 января 1900',
      );
      expect(t.widget<TextFormField>(field('Дата')).enabled, false);
      await t.pumpWidget(const SizedBox());
      await t.pumpAndSettle();
      repo.onExpenseEdit = null;
      await openExpenses(t, auth, repo);
      expect(find.text('Редактирование расхода'), findsOneWidget);
      await click(t, 'Повторить сохранение');
      expect(repo.attemptedEdits.last.params, first.params);
      expect(repo.expenseRows['personal'], hasLength(1));
      expect(await repo.expenseDrafts.read('owner', 'personal'), isNull);
    },
  );

  testWidgets(
    'Stale form preserves input, blocks overwrite and allows cancel/reopen',
    (t) async {
      final auth = FakeAuth(signedIn: true);
      addTearDown(auth.dispose);
      final repo = editable();
      await openExpenses(t, auth, repo);
      await click(t, 'Исходный расход');
      await t.enterText(field('Комментарий (необязательно)'), 'Моя правка');
      repo.onExpenseEdit = (_) async =>
          throw const PostgrestException(message: 'conflict', code: 'P1003');
      await click(t, 'Сохранить');
      expect(find.textContaining('изменён в другой вкладке'), findsOneWidget);
      expect(
        t
            .widget<TextFormField>(field('Комментарий (необязательно)'))
            .controller!
            .text,
        'Моя правка',
      );
      expect(
        t
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Сохранить'),
            )
            .onPressed,
        isNull,
      );
      expect(await repo.expenseDrafts.read('owner', 'personal'), isNull);
      await click(t, 'Отмена');
      expect(repo.expenseRows['personal']!.single.comment, 'Исходный расход');
    },
  );

  testWidgets('Changing date reorders history and reopening reads saved date', (
    t,
  ) async {
    final auth = FakeAuth(signedIn: true);
    addTearDown(auth.dispose);
    final repo = editable()
      ..commitExpense(seed(id: 'second-expense', date: '2020-01-01'));
    await openExpenses(t, auth, repo);
    await t.ensureVisible(find.text('Исходный расход').first);
    await t.tap(find.text('Исходный расход').first);
    await t.pumpAndSettle();
    await t.enterText(field('Дата'), '1 января 1900');
    await click(t, 'Сохранить');
    final newer = find.text('1 января 2020');
    final older = find.text('1 января 1900');
    expect(t.getTopLeft(newer).dy, lessThan(t.getTopLeft(older).dy));
    await t.pumpWidget(const SizedBox());
    await t.pumpAndSettle();
    await openExpenses(t, auth, repo);
    await click(t, 'Исходный расход');
    expect(
      t.widget<TextFormField>(field('Дата')).controller!.text,
      '1 января 1900',
    );
  });

  testWidgets('Late edit completion cannot leak after space switch', (t) async {
    final auth = FakeAuth(signedIn: true);
    addTearDown(auth.dispose);
    final repo = editable();
    final pending = Completer<String>();
    repo.onExpenseEdit = (_) => pending.future;
    await openExpenses(t, auth, repo);
    await click(t, 'Исходный расход');
    await t.enterText(field('Комментарий (необязательно)'), 'Поздняя правка');
    await click(t, 'Сохранить');
    await click(t, 'Личные финансы');
    await click(t, 'Бизнес');
    pending.complete(repo.commitEdit(repo.attemptedEdits.single));
    await t.pumpAndSettle();
    expect(find.text('Расход сохранён.'), findsNothing);
    expect(find.text('Поздняя правка'), findsNothing);
    expect(repo.expenseRows['personal']!.single.comment, 'Поздняя правка');
    expect(await repo.expenseDrafts.read('owner', 'personal'), isNull);
    expect(t.takeException(), isNull);
  });

  testWidgets('Manager history has no edit affordance or clickable row', (
    t,
  ) async {
    final auth = FakeAuth(signedIn: true)..userId = 'manager';
    addTearDown(auth.dispose);
    final repo = prepared(space: 'business')..spaces = [businessSpace];
    repo.commitExpense(
      PendingExpense.fromJson({...seed().toJson(), 'p_space_id': 'business'}),
    );
    await openExpenses(t, auth, repo);
    expect(find.text('Редактировать'), findsNothing);
    await click(t, 'Исходный расход');
    expect(find.text('Редактирование расхода'), findsNothing);
    expect(repo.attemptedEdits, isEmpty);
  });
}
