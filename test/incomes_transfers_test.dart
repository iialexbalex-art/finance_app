import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:finance_app/category.dart';
import 'package:finance_app/expense.dart';
import 'package:finance_app/expense_filter.dart';
import 'package:finance_app/expense_filters_bar.dart';
import 'package:finance_app/finance_repository.dart';
import 'package:finance_app/main.dart';
import 'package:finance_app/transfer.dart';
import 'package:finance_app/transfer_draft_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'categories_screen_test.dart' show click;
import 'expense_edit_test.dart' show editable;
import 'expense_filters_test.dart' show capture;
import 'expenses_screen_test.dart' show field;
import 'fake_auth.dart';
import 'fake_finance.dart';

FakeFinance prepared() => editable()
  ..expenseRows.clear()
  ..categories.addAll([
    const FinanceCategory(
      id: 'salary',
      spaceId: 'personal',
      kind: CategoryKind.income,
      name: 'Работа',
    ),
    const FinanceCategory(
      id: 'bonus',
      spaceId: 'personal',
      kind: CategoryKind.income,
      name: 'Премия',
      parentId: 'salary',
    ),
    const FinanceCategory(
      id: 'oldIncome',
      spaceId: 'personal',
      kind: CategoryKind.income,
      name: 'Старые доходы',
      isArchived: true,
    ),
  ]);

PendingTransfer transfer({
  String request = 'create',
  String amount = '100000',
  String fee = '1000',
  String date = '2150-10-01',
  String comment = 'Перевод',
}) => PendingTransfer(
  requestId: request,
  data: {
    'space_id': 'personal',
    'id': null,
    'revision': null,
    'source_id': 'cash',
    'target_id': 'second',
    'source_minor': amount,
    'target_minor': amount,
    'source_currency': 'RUB',
    'target_currency': 'RUB',
    'source_scale': 2,
    'target_scale': 2,
    'date': date,
    'comment': comment,
    'fee_minor': fee,
    'fee_category_id': fee == '0' ? null : 'groceries',
  },
  display: {
    'source_name': 'Касса',
    'target_name': 'Вторая касса',
    'fee_category_path': fee == '0' ? null : 'Ежедневные → Еда → Продукты',
  },
);

Future<void> open(
  WidgetTester t,
  FakeFinance repo,
  String section, {
  FakeAuth? auth,
}) async {
  await t.pumpWidget(
    RepaintBoundary(
      key: const ValueKey('capture'),
      child: FinanceApp(
        auth: auth ?? FakeAuth(signedIn: true),
        repository: repo,
      ),
    ),
  );
  await t.pumpAndSettle();
  await click(t, section);
}

Future<void> enter(WidgetTester t, String label, String value) async {
  await t.ensureVisible(field(label));
  await t.enterText(field(label), value);
  await t.pumpAndSettle();
}

Future<void> select(WidgetTester t, String label, String item) async {
  final dropdown = find.byWidgetPredicate(
    (w) =>
        w is DropdownButtonFormField<String> && w.decoration.labelText == label,
  );
  await t.ensureVisible(dropdown);
  await t.tap(dropdown);
  await t.pumpAndSettle();
  await click(t, item);
}

Future<void> fillTransfer(WidgetTester t, {bool fee = true}) async {
  await click(t, 'Добавить перевод');
  await enter(t, 'Сумма списания (RUB)', '1000,00');
  expect(
    t.widget<TextFormField>(field('Сумма зачисления (RUB)')).controller!.text,
    '1000,00',
  );
  if (fee) {
    await enter(t, 'Комиссия (RUB), необязательно', '10');
    await select(t, 'Категория комиссии', 'Ежедневные → Еда → Продукты');
  }
  await enter(t, 'Дата', '1 октября 2150');
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

  test('Exact rate and same-currency scaling never use floating point', () {
    expect(transferRate(BigInt.from(3), 2, BigInt.one, 2), '0,33333333…');
    expect(
      transferRate(BigInt.parse('9223372036854775807'), 0, BigInt.one, 4),
      '0,00000000…',
    );
    expect(transferRate(BigInt.from(100), 2, BigInt.from(125), 2), '1,25');
    expect(
      equalCurrencyAmount(BigInt.parse('900719925474099300'), 2, 0),
      BigInt.parse('9007199254740993'),
    );
    expect(
      () => equalCurrencyAmount(BigInt.from(101), 2, 0),
      throwsFormatException,
    );
    expect(
      () => equalCurrencyAmount(BigInt.parse('9223372036854775807'), 0, 2),
      throwsFormatException,
    );
  });

  test('Journal is lossless, isolated by user/space and clears only its own request', () async {
    final store = MemoryTransferDraftStore();
    final first = transfer(amount: '9007199254740993');
    final second = transfer(request: 'second');
    final restored = PendingTransfer.fromJson(
      jsonDecode(jsonEncode(first.toJson())) as Map<String, dynamic>,
    );
    expect(restored.data, first.data);
    expect(() => restored.data['source_minor'] = '1', throwsUnsupportedError);
    await store.write('owner', first);
    await store.write('owner', second);
    expect(await store.read('manager', 'personal'), isNull);
    expect(await store.read('owner', 'business'), isNull);
    await store.clear('owner', 'personal', first.requestId);
    expect((await store.read('owner', 'personal'))!.requestId, 'second');
  });

  test('RPC transport preserves money strings, income route and transfer filters/cursor', () async {
    final calls = <http.Request>[];
    final p = transfer(amount: '9007199254740993');
    final row = {
      ...p.data,
      ...p.display,
      'id': 'id',
      'revision': 'revision',
      'transfer_date': p.data['date'],
    };
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test',
      accessToken: () async => 'session',
      httpClient: MockClient((r) async {
        calls.add(r);
        final body = r.url.path.endsWith('query_transfers')
            ? List.generate(26, (_) => row)
            : r.url.path.endsWith('query_incomes')
            ? {'items': [], 'totals': []}
            : 'saved';
        return http.Response(
          jsonEncode(body),
          200,
          request: r,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(client.dispose);
    final repo = SupabaseFinanceRepository(client);
    await repo.saveTransfer(p);
    expect(
      jsonDecode(calls.last.body)['p_data']['source_minor'],
      '9007199254740993',
    );
    final page = await repo.queryTransfers(
      'personal',
      const ExpenseFilter(
        walletIds: ['cash', 'second'],
        from: '2026-10-01',
        to: '2026-10-31',
      ),
      search: '100%_',
      before: Transfer.fromJson(row),
    );
    expect(page.hasMore, isTrue);
    expect(page.items, hasLength(25));
    expect(page.items.first.sourceMinor, BigInt.parse('9007199254740993'));
    final query = jsonDecode(calls.last.body);
    expect(query['p_before_id'], 'id');
    expect(query['p_search'], '100%_');
    expect(query['p_wallet_ids'], ['cash', 'second']);
    final income = PendingExpense(
      requestId: 'income',
      spaceId: 'personal',
      walletId: 'cash',
      categoryId: 'bonus',
      amountMinor: '9007199254740993',
      date: '2150-10-01',
      comment: '',
      currency: 'RUB',
      scale: 2,
      walletName: 'Касса',
      categoryPath: 'Работа → Премия',
    );
    await repo.saveIncome(income);
    expect(calls.last.url.path, endsWith('/rpc/save_income'));
    expect(jsonDecode(calls.last.body)['p_amount_minor'], '9007199254740993');
    expect(jsonDecode(calls.last.body)['p_income_date'], '2150-10-01');
    await repo.queryIncomes(
      'personal',
      const ExpenseFilter(categoryIds: ['salary', 'bonus']),
      includeTotals: true,
    );
    expect(calls.last.url.path, endsWith('/rpc/query_incomes'));
    expect(jsonDecode(calls.last.body)['p_include_totals'], isTrue);
  });

  for (final size in [const Size(320, 568), const Size(1440, 900)]) {
    testWidgets(
      'Income create, edit wallet/date, positive total and common balance at $size',
      (t) async {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final repo = prepared();
        await open(t, repo, 'Доходы');
        await click(t, 'Добавить доход');
        await enter(t, 'Сумма (RUB)', '250');
        await select(t, 'Категория дохода', 'Работа → Премия');
        await enter(t, 'Дата', '1 октября 2150');
        await click(t, 'Сохранить доход');
        expect(repo.incomeLedger.expenseRows['personal'], hasLength(1));
        expect(
          (await repo.loadExpenseBalance('cash')).current,
          BigInt.from(125000),
        );
        expect(find.text('+250,00 RUB'), findsWidgets);
        await click(t, 'Редактировать');
        await select(t, 'Кошелёк', 'Вторая касса (RUB)');
        await enter(t, 'Дата', '1 января 1900');
        await enter(t, 'Сумма (RUB)', '300');
        await click(t, 'Сохранить');
        expect(
          repo.incomeLedger.expenseRows['personal']!.single.walletId,
          'second',
        );
        expect(
          repo.incomeLedger.expenseRows['personal']!.single.date,
          '1900-01-01',
        );
        expect(
          (await repo.loadExpenseBalance('cash')).current,
          BigInt.from(100000),
        );
        expect(
          (await repo.loadExpenseBalance('second')).current,
          BigInt.from(230000),
        );
        await capture(t, 'income-${size.width.toInt()}');
        expect(t.takeException(), isNull);
      },
    );

    testWidgets(
      'Transfer fee creates once; expense link edits and removes fee at $size',
      (t) async {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final repo = prepared();
        await open(t, repo, 'Переводы');
        await fillTransfer(t);
        await capture(t, 'transfer-form-${size.width.toInt()}');
        await click(t, 'Сохранить перевод');
        expect(repo.transfers['personal'], hasLength(1));
        expect(repo.expenseRows['personal'], hasLength(1));
        expect(
          (await repo.loadExpenseBalance('cash')).current,
          BigInt.from(-1000),
        );
        expect(
          (await repo.loadExpenseBalance('second')).current,
          BigInt.from(300000),
        );
        await click(t, 'Расходы');
        await click(t, 'Комиссия перевода');
        expect(find.text('Редактирование перевода'), findsOneWidget);
        expect(find.textContaining('связан расход комиссии'), findsOneWidget);
        await enter(t, 'Комиссия (RUB), необязательно', '0');
        await click(t, 'Сохранить перевод');
        expect(repo.expenseRows['personal'], isEmpty);
        expect(repo.transfers['personal']!.single.feeMinor, BigInt.zero);
        expect((await repo.loadExpenseBalance('cash')).current, BigInt.zero);
        expect(find.text('Редактирование перевода'), findsNothing);
        await capture(t, 'transfer-history-${size.width.toInt()}');
        expect(t.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'FX requires both amounts and shows explicit rate; changing currency clears amount',
    (t) async {
      final repo = prepared();
      await open(t, repo, 'Переводы');
      await fillTransfer(t, fee: false);
      await select(t, 'Кошелёк зачисления', 'Доллары (USD)');
      expect(
        t
            .widget<TextFormField>(field('Сумма зачисления (USD)'))
            .controller!
            .text,
        '',
      );
      await enter(t, 'Сумма зачисления (USD)', '10');
      expect(find.textContaining('1 RUB = 0,01 USD'), findsOneWidget);
      await click(t, 'Сохранить перевод');
      expect(repo.transfers['personal']!.single.targetMinor, BigInt.from(1000));
      expect((await repo.loadExpenseBalance('usd')).current, BigInt.from(1000));
      await click(t, 'Обзор');
      expect(
        t.widget<Text>(find.byKey(const ValueKey('Всего средств:RUB'))).data,
        '2000,00 RUB',
      );
      expect(
        t.widget<Text>(find.byKey(const ValueKey('Всего средств:USD'))).data,
        '10,00 USD',
      );
    },
  );

  testWidgets(
    'Lost transfer response survives remount and replays original UUID without duplicate fee',
    (t) async {
      final repo = prepared();
      repo.onTransferSave = (p) async {
        repo.commitTransfer(p);
        throw TimeoutException('lost');
      };
      await open(t, repo, 'Переводы');
      await fillTransfer(t);
      await click(t, 'Сохранить перевод');
      final pending = (await repo.transferDrafts.read('owner', 'personal'))!;
      await t.pumpWidget(const SizedBox());
      repo.onTransferSave = null;
      await open(t, repo, 'Переводы');
      expect(find.textContaining('Поля зафиксированы'), findsOneWidget);
      await click(t, 'Повторить сохранение');
      expect(repo.attemptedTransfers.last.requestId, pending.requestId);
      expect(repo.attemptedTransfers.last.data, pending.data);
      expect(repo.transfers['personal'], hasLength(1));
      expect(repo.expenseRows['personal'], hasLength(1));
      expect(await repo.transferDrafts.read('owner', 'personal'), isNull);
    },
  );

  testWidgets(
    'Transfer conflict keeps entered values and forbids blind retry',
    (t) async {
      final repo = prepared()..commitTransfer(transfer());
      await open(t, repo, 'Переводы');
      await click(t, 'Редактировать');
      await enter(t, 'Сумма списания (RUB)', '500');
      repo.onTransferSave = (_) async =>
          throw const PostgrestException(message: 'stale', code: 'P1003');
      await click(t, 'Сохранить перевод');
      expect(find.textContaining('изменён в другой вкладке'), findsOneWidget);
      expect(
        t.widget<TextFormField>(field('Сумма списания (RUB)')).controller!.text,
        '500',
      );
      expect(
        t
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Сохранить перевод'),
            )
            .onPressed,
        isNull,
      );
      expect(await repo.transferDrafts.read('owner', 'personal'), isNull);
      expect(
        repo.transfers['personal']!.single.sourceMinor,
        BigInt.from(100000),
      );
    },
  );

  testWidgets(
    'Transfer search remains stable during pagination and resets cursor on apply',
    (t) async {
      final repo = prepared();
      for (var i = 0; i < 31; i++) {
        repo.commitTransfer(
          transfer(request: '$i', fee: '0', comment: 'match $i'),
        );
      }
      await open(t, repo, 'Переводы');
      final search = find.byWidgetPredicate(
        (w) =>
            w is TextField && w.decoration?.labelText == 'Поиск по комментарию',
      );
      await t.enterText(search, 'absent');
      await click(t, 'Загрузить ещё');
      expect(find.text('Редактировать'), findsNWidgets(31));
      await t.ensureVisible(search);
      await t.tap(find.byTooltip('Найти переводы'));
      await t.pumpAndSettle();
      expect(find.text('По выбранным фильтрам переводов нет'), findsOneWidget);
      expect(find.text('Загрузить ещё'), findsNothing);
    },
  );

  testWidgets(
    'Late transfer completion does not reveal old space and preserves receipt',
    (t) async {
      final repo = prepared();
      final waiting = Completer<String>();
      repo.onTransferSave = (_) => waiting.future;
      await open(t, repo, 'Переводы');
      await fillTransfer(t, fee: false);
      await t.ensureVisible(find.text('Сохранить перевод'));
      await t.tap(find.text('Сохранить перевод'));
      await t.pump();
      await click(t, 'Личные финансы');
      await click(t, 'Бизнес');
      waiting.complete('saved');
      await t.pumpAndSettle();
      expect(find.text('Перевод сохранён.'), findsNothing);
      expect(find.text('Касса → Вторая касса'), findsNothing);
      expect(await repo.transferDrafts.read('owner', 'personal'), isNull);
    },
  );

  testWidgets('Manager has no incomes/transfers navigation or balances', (
    t,
  ) async {
    final repo = prepared();
    final auth = FakeAuth(signedIn: true)..userId = 'manager';
    await t.pumpWidget(FinanceApp(auth: auth, repository: repo));
    await t.pumpAndSettle();
    expect(find.text('Доходы'), findsNothing);
    expect(find.text('Переводы'), findsNothing);
    expect(find.text('Текущие учётные остатки'), findsNothing);
  });

  testWidgets(
    'Income lost response restores its own journal and retries exact payload',
    (t) async {
      final repo = prepared();
      repo.onIncomeSave = (p) async {
        repo.incomeLedger.commitExpense(p);
        throw TimeoutException('lost');
      };
      await open(t, repo, 'Доходы');
      await click(t, 'Добавить доход');
      await enter(t, 'Сумма (RUB)', '90071992547409,93');
      await select(t, 'Категория дохода', 'Работа → Премия');
      await click(t, 'Сохранить доход');
      final pending = (await repo.incomeDrafts.read('owner', 'personal'))!;
      expect(await repo.expenseDrafts.read('owner', 'personal'), isNull);
      await t.pumpWidget(const SizedBox());
      repo.onIncomeSave = null;
      await open(t, repo, 'Доходы');
      await click(t, 'Повторить сохранение');
      expect(
        repo.incomeLedger.attemptedExpenses.last.requestId,
        pending.requestId,
      );
      expect(repo.incomeLedger.expenseRows['personal'], hasLength(1));
      expect(
        repo.incomeLedger.expenseRows['personal']!.single.amount,
        BigInt.parse('9007199254740993'),
      );
      expect(await repo.incomeDrafts.read('owner', 'personal'), isNull);
    },
  );

  testWidgets(
    'Income filters include archived descendants once and all-page totals, reset pagination',
    (t) async {
      final repo = prepared();
      for (var i = 0; i < 31; i++) {
        repo.incomeLedger.commitExpense(
          PendingExpense(
            requestId: 'income$i',
            spaceId: 'personal',
            walletId: 'cash',
            categoryId: 'bonus',
            amountMinor: '100',
            date: '2026-10-01',
            comment: 'Income $i',
            currency: 'RUB',
            scale: 2,
            walletName: 'Касса',
            categoryPath: 'Работа → Премия',
          ),
        );
      }
      final parent = repo.categories.indexWhere((c) => c.id == 'salary');
      repo.categories[parent] = const FinanceCategory(
        id: 'salary',
        spaceId: 'personal',
        kind: CategoryKind.income,
        name: 'Работа',
        isArchived: true,
      );
      await open(t, repo, 'Доходы');
      t
          .widget<ExpenseFiltersBar>(find.byType(ExpenseFiltersBar))
          .onChanged(const ExpenseFilter(categoryIds: ['salary', 'bonus']));
      await t.pumpAndSettle();
      expect(find.text('+31,00 RUB'), findsOneWidget);
      expect(find.text('Редактировать'), findsNWidgets(25));
      await click(t, 'Загрузить ещё');
      expect(find.text('Редактировать'), findsNWidgets(31));
      t
          .widget<ExpenseFiltersBar>(find.byType(ExpenseFiltersBar))
          .onChanged(const ExpenseFilter(from: '2027-01-01'));
      await t.pumpAndSettle();
      expect(find.text('По выбранным фильтрам доходов нет'), findsOneWidget);
      expect(find.text('Загрузить ещё'), findsNothing);
      expect(find.text('+31,00 RUB'), findsNothing);
    },
  );

  for (final size in [const Size(320, 568), const Size(1440, 900)]) {
    testWidgets(
      'Long transfer names and maximum money remain readable at $size',
      (t) async {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final repo = prepared();
        final p = transfer(amount: '9223372036854775807', fee: '0');
        await repo.editWallet(
          repo.wallets['personal']![0],
          'Очень длинное название расчётного счёта для личных накоплений и ежедневных покупок',
          WalletGroup.cash,
          iconId: 'bank_bakai',
        );
        await repo.editWallet(
          repo.wallets['personal']![1],
          'Очень длинное название банковской карты получателя для международных расчётов',
          WalletGroup.cash,
          iconId: 'piggy',
        );
        repo.commitTransfer(
          PendingTransfer(
            requestId: p.requestId,
            data: p.data,
            display: {
              ...p.display,
              'source_name': 'Очень длинное название расчётного счёта для личных накоплений и ежедневных покупок',
              'target_name': 'Очень длинное название банковской карты получателя для международных расчётов',
            },
          ),
        );
        await open(t, repo, 'Переводы');
        expect(find.text('−92233720368547758,07 RUB'), findsOneWidget);
        expect(find.text('+92233720368547758,07 RUB'), findsOneWidget);
        await t.ensureVisible(find.text('Редактировать'));
        await t.pumpAndSettle();
        await capture(t, 'transfer-long-${size.width.toInt()}');
        expect(t.takeException(), isNull);
        await click(t, 'Обзор');
        await capture(t, 'overview-${size.width.toInt()}');
        expect(t.takeException(), isNull);
      },
    );
  }
}
