import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:finance_app/expense.dart';
import 'package:finance_app/expense_filter.dart';
import 'package:finance_app/expense_filters_bar.dart';
import 'package:finance_app/finance_repository.dart';
import 'package:finance_app/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'categories_screen_test.dart' show click;
import 'expenses_screen_test.dart' show prepared, openExpenses;
import 'fake_auth.dart';
import 'fake_finance.dart';

Expense row(
  int id, {
  String wallet = 'cash',
  String category = 'groceries',
  String date = '2026-09-30',
  String currency = 'RUB',
  String? name,
  BigInt? amount,
}) => Expense(
  id: '$id'.padLeft(4, '0'),
  date: date,
  amount: amount ?? BigInt.from(100),
  currency: currency,
  scale: 2,
  walletId: wallet,
  categoryId: category,
  revision: 'v1',
  walletName: name ?? 'Касса',
  categoryPath: 'Ежедневные → Еда → Продукты',
  comment: 'Запись $id',
);

Future<void> capture(WidgetTester t, String name) async {
  if (kIsWeb || !const bool.fromEnvironment('CAPTURE_QA')) return;
  // Raster asset decoding uses real IO; fake-clock pumpAndSettle alone can
  // capture an image before its codec has completed.
  await t.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await t.pumpAndSettle();
  final boundary = t.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('capture')),
  );
  await t.runAsync(() async {
    final picture = await boundary.toImage(pixelRatio: 1);
    final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
    await Directory('build/qa').create(recursive: true);
    await File('build/qa/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    picture.dispose();
  });
}

void main() {
  setUpAll(() async {
    if (!kIsWeb && const bool.fromEnvironment('CAPTURE_QA')) {
      final font = FontLoader('Roboto')
        ..addFont(
          File('C:/Windows/Fonts/arial.ttf')
              .readAsBytes()
              .then(ByteData.sublistView),
        );
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    }
  });
  test('RPC sends complete filters, cursor and totals flag with exact string amounts', () async {
    final calls = <Map<String, dynamic>>[];
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test',
      accessToken: () async => 'session',
      httpClient: MockClient((request) async {
        expect(request.url.path, '/rest/v1/rpc/query_expenses');
        expect(request.headers['Authorization'], 'Bearer session');
        calls.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode({
            'items': List.generate(
              26,
              (i) => {
                'id': '$i',
                'wallet_id': 'w1',
                'category_id': 'leaf',
                'revision': 'v1',
                'expense_date': '2026-09-30',
                'amount_minor': '9007199254740993',
                'currency': 'RUB',
                'currency_scale': 2,
                'wallet_name': 'Касса',
                'category_path': 'Путь',
                'comment': '',
              },
            ),
            'totals': [
              {
                'currency': 'RUB',
                'currency_scale': 2,
                'amount_minor': '270215977642229790',
              },
            ],
          }),
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(client.dispose);
    final repo = SupabaseFinanceRepository(client);
    const filter = ExpenseFilter(
      walletIds: ['w1', 'w2'],
      categoryIds: ['parent', 'leaf'],
      from: '2026-09-01',
      to: '2026-09-30',
    );
    final result = await repo.queryExpenses(
      'space',
      filter,
      includeTotals: true,
    );
    expect(result.page.items.length, 25);
    expect(result.page.hasMore, isTrue);
    expect(result.totals.single.amount.toString(), '270215977642229790');
    expect(result.page.items.first.amount.toString(), '9007199254740993');
    await repo.queryExpenses(
      'space',
      filter,
      before: result.page.items.last,
      includeTotals: false,
    );
    expect(calls.first, {
      'p_space_id': 'space',
      ...filter.params,
      'p_before_date': null,
      'p_before_id': null,
      'p_include_totals': true,
    });
    expect(calls.last['p_before_id'], '24');
    expect(calls.last['p_include_totals'], false);
    expect(calls.last['p_category_ids'], ['parent', 'leaf']);
  });

  for (final size in [const Size(320, 568), const Size(1440, 900)]) {
    testWidgets(
      'Wallet navigation, large amounts, long names and filters at $size',
      (t) async {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final auth = FakeAuth(signedIn: true);
        addTearDown(auth.dispose);
        final repo = prepared();
        final longName =
            'Основной кошелёк для ежедневных покупок и хозяйственных расходов семьи';
        repo.wallets['personal'] = [
          Wallet(
            id: 'cash',
            spaceId: 'personal',
            name: longName,
            group: WalletGroup.cash,
            currency: 'RUB',
          ),
          const Wallet(
            id: 'usd',
            spaceId: 'personal',
            name: 'Валютная карта',
            group: WalletGroup.card,
            currency: 'USD',
          ),
        ];
        repo.balances['cash'] = BigInt.parse('9223372036854775807');
        repo.expenseRows['personal'] = [
          for (var i = 0; i < 30; i++)
            row(i, name: longName, amount: BigInt.parse('9007199254740993')),
          row(40, wallet: 'usd', currency: 'USD'),
        ];
        await t.pumpWidget(
          RepaintBoundary(
            key: const ValueKey('capture'),
            child: FinanceApp(auth: auth, repository: repo),
          ),
        );
        await t.pumpAndSettle();
        await click(t, 'Перейти к кошелькам');
        await capture(t, 'wallets-${size.width.toInt()}');
        await t.ensureVisible(
          find.textContaining('89531560592125460,17 RUB').first,
        );
        await t.pumpAndSettle();
        await capture(t, 'wallet-row-${size.width.toInt()}');
        expect(t.takeException(), isNull);
        await click(t, longName);
        expect(find.text('Реквизиты кошелька'), findsOneWidget);
        await click(t, 'Назад к кошелькам');
        await click(t, 'Расходы');
        final filterBar = find.byType(ExpenseFiltersBar);
        await t.ensureVisible(filterBar);
        await t.tap(
          find.descendant(
            of: filterBar,
            matching: find.widgetWithText(OutlinedButton, 'Кошельки'),
          ),
        );
        await t.pumpAndSettle();
        await t.tap(find.text('$longName (RUB)'));
        await click(t, 'Применить');
        expect(repo.filters.last.walletIds, ['cash']);
        expect(find.textContaining('Запись '), findsNWidgets(25));
        expect(find.text('−2702159776422297,90 RUB'), findsOneWidget);
        expect(find.text('30 сентября 2026'), findsOneWidget);
        await capture(t, 'expenses-${size.width.toInt()}');
        await t.ensureVisible(find.text('Запись 29'));
        await t.pumpAndSettle();
        await capture(t, 'expense-row-${size.width.toInt()}');
        await click(t, 'Загрузить ещё');
        expect(find.textContaining('Запись '), findsNWidgets(30));
        await click(t, 'Сбросить фильтры');
        expect(repo.filters.last.walletIds, isEmpty);
        expect(find.textContaining('Запись '), findsNWidgets(25));
        expect(find.text('−1,00 USD'), findsWidgets);
        await t.ensureVisible(filterBar);
        await t.tap(
          find.descendant(
            of: filterBar,
            matching: find.widgetWithText(OutlinedButton, 'Категории'),
          ),
        );
        await t.pumpAndSettle();
        await t.enterText(find.byType(TextField), 'Архив');
        await t.pumpAndSettle();
        expect(find.text('Архив (архив)'), findsOneWidget);
        await t.tap(find.text('Архив (архив)'));
        await click(t, 'Применить');
        expect(find.text('По выбранным фильтрам расходов нет'), findsOneWidget);
        expect(find.text('Нет расходов'), findsOneWidget);
        expect(t.takeException(), isNull);
        await click(t, 'Личные финансы');
        await click(t, 'Бизнес');
        expect(repo.filters.last.categoryIds, isEmpty);
        expect(find.text(longName), findsNothing);
        expect(t.takeException(), isNull);
      },
    );
  }

  testWidgets('Filter change ignores pending pagination and resets cursor', (
    t,
  ) async {
    final auth = FakeAuth(signedIn: true);
    addTearDown(auth.dispose);
    final repo = prepared()
      ..expenseRows['personal'] = [for (var i = 0; i < 30; i++) row(i)];
    await openExpenses(t, auth, repo);
    final delayed = Completer<ExpensePage>();
    repo.onExpenses = (_, before) {
      expect(before, isNotNull);
      return delayed.future;
    };
    await click(t, 'Загрузить ещё');
    repo.onExpenses = (_, before) async {
      expect(before, isNull);
      return ExpensePage([row(99)], false);
    };
    await click(t, 'Сбросить фильтры');
    delayed.complete(ExpensePage([row(88)], false));
    await t.pumpAndSettle();
    expect(find.text('Запись 99'), findsOneWidget);
    expect(find.text('Запись 88'), findsNothing);
  });

  testWidgets(
    'Period presets and inclusive custom dates are passed to server',
    (t) async {
      t.view.physicalSize = const Size(320, 568);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final auth = FakeAuth(signedIn: true);
      addTearDown(auth.dispose);
      final repo = prepared();
      await openExpenses(t, auth, repo);
      final now = DateTime.now();
      for (final preset in [
        'Сегодня',
        'Текущий месяц',
        'Предыдущий месяц',
        'Всё время',
      ]) {
        await click(t, 'Период');
        await click(t, preset);
        if (preset == 'Сегодня') {
          expect(repo.filters.last.from, expenseDate(now));
        }
        if (preset == 'Текущий месяц') {
          expect(
            repo.filters.last.to,
            expenseDate(DateTime(now.year, now.month + 1, 0)),
          );
        }
        if (preset == 'Предыдущий месяц') {
          expect(
            repo.filters.last.from,
            expenseDate(DateTime(now.year, now.month - 1)),
          );
        }
        if (preset == 'Всё время') expect(repo.filters.last.from, isNull);
      }
      await click(t, 'Период');
      await t.enterText(find.byType(TextFormField).first, '30 сентября 2026');
      await t.enterText(find.byType(TextFormField).last, '1 сентября 2026');
      await click(t, 'Применить');
      expect(find.textContaining('не позже окончания'), findsOneWidget);
      await t.enterText(find.byType(TextFormField).last, '30 сентября 2026');
      await click(t, 'Применить');
      expect(repo.filters.last.from, '2026-09-30');
      expect(repo.filters.last.to, '2026-09-30');
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('Manager never requests totals or balances', (t) async {
    final auth = FakeAuth(signedIn: true)..userId = 'manager';
    addTearDown(auth.dispose);
    final repo = prepared(space: 'business')..spaces = [businessSpace];
    await openExpenses(t, auth, repo);
    expect(find.text('Итог расходов по выбранным фильтрам'), findsNothing);
    expect(repo.currentReads, 0);
    expect(repo.balanceReads, 0);
    expect(repo.totalsRequests, everyElement(isFalse));
  });

  testWidgets('Wallet actions edit metadata and keep navigation separate', (
    t,
  ) async {
    final auth = FakeAuth(signedIn: true);
    addTearDown(auth.dispose);
    final repo = prepared();
    await t.pumpWidget(FinanceApp(auth: auth, repository: repo));
    await t.pumpAndSettle();
    await click(t, 'Перейти к кошелькам');
    await t.tap(find.byTooltip('Действия с кошельком'));
    await t.pumpAndSettle();
    await click(t, 'Редактировать реквизиты');
    await t.enterText(find.byType(TextFormField), 'Новая касса');
    await click(t, 'Сохранить реквизиты');
    expect(repo.wallets['personal']!.single.name, 'Новая касса');
    expect(repo.filters, isEmpty);
    expect(find.text('Новая касса'), findsOneWidget);
  });
}
