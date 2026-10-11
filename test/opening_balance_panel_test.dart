import 'dart:async';

import 'package:finance_app/finance_repository.dart';
import 'package:finance_app/main.dart';
import 'package:finance_app/opening_balance_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'fake_auth.dart';
import 'fake_finance.dart';

const cashWallet = Wallet(
  id: 'cash',
  spaceId: 'personal',
  name: 'Касса',
  group: WalletGroup.cash,
  currency: 'RUB',
);

Future<void> click(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text).last);
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

void main() {
  for (final size in [const Size(320, 568), const Size(1440, 900)]) {
    testWidgets(
      'Absent, zero, negative, save lock and exact display at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final auth = FakeAuth(signedIn: true);
        addTearDown(auth.dispose);
        final repo = FakeFinance()..wallets['personal'] = [cashWallet];
        await tester.pumpWidget(FinanceApp(auth: auth, repository: repo));
        await tester.pumpAndSettle();
        await click(tester, 'Перейти к кошелькам');
        final actions = find.byTooltip('Действия с кошельком');
        await tester.ensureVisible(actions);
        await tester.tap(actions);
        await tester.pumpAndSettle();
        await click(tester, 'Начальный остаток');
        expect(find.text('Не задан'), findsOneWidget);
        await click(tester, 'Задать начальный остаток');
        await tester.enterText(find.byType(TextFormField), '1,234');
        await click(tester, 'Сохранить остаток');
        expect(repo.balanceWrites, 0);
        expect(find.textContaining('не более двух'), findsOneWidget);
        await tester.enterText(find.byType(TextFormField), '0');
        final pending = Completer<BigInt>();
        repo.onBalanceSave = (_, _, _) => pending.future;
        await click(tester, 'Сохранить остаток');
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Сохраняем…'),
              )
              .onPressed,
          isNull,
        );
        expect(repo.balanceWrites, 1);
        pending.complete(BigInt.zero);
        await tester.pumpAndSettle();
        expect(find.text('0,00 RUB'), findsOneWidget);
        expect(find.text('Не задан'), findsNothing);
        repo.onBalanceSave = null;
        await click(tester, 'Изменить начальный остаток');
        await tester.enterText(find.byType(TextFormField), '-100,50');
        await click(tester, 'Сохранить остаток');
        expect(repo.lastPrevious, BigInt.zero);
        expect(find.text('-100,50 RUB'), findsOneWidget);
        await click(tester, 'Изменить начальный остаток');
        await tester.enterText(
          find.byType(TextFormField),
          '92233720368547758.07',
        );
        await click(tester, 'Сохранить остаток');
        expect(find.text('92233720368547758,07 RUB'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Manager does not read balances or see amount/actions', (
    tester,
  ) async {
    final auth = FakeAuth(signedIn: true)..userId = 'manager';
    addTearDown(auth.dispose);
    final repo = FakeFinance()..spaces = [businessSpace];
    repo.wallets['business'] = [
      const Wallet(
        id: 'cash',
        spaceId: 'business',
        name: 'Касса',
        group: WalletGroup.cash,
        currency: 'RUB',
      ),
    ];
    repo.balances['cash'] = BigInt.from(123456);
    await tester.pumpWidget(FinanceApp(auth: auth, repository: repo));
    await tester.pumpAndSettle();
    await click(tester, 'Перейти к кошелькам');
    expect(find.text('Касса'), findsOneWidget);
    expect(find.text('Начальный остаток'), findsNothing);
    expect(find.text('1234,56 RUB'), findsNothing);
    expect(find.byType(OpeningBalancePanel), findsNothing);
    expect(repo.balanceReads, 0);
    expect(repo.balanceWrites, 0);
  });

  testWidgets(
    'Read error is not absence; retry, denied save and conflict are clear',
    (tester) async {
      final auth = FakeAuth(signedIn: true);
      addTearDown(auth.dispose);
      final repo = FakeFinance()..wallets['personal'] = [cashWallet];
      repo.onBalanceLoad = (_) async => throw Exception('offline');
      await tester.pumpWidget(FinanceApp(auth: auth, repository: repo));
      await tester.pumpAndSettle();
      await click(tester, 'Перейти к кошелькам');
      final actions = find.byTooltip('Действия с кошельком');
      await tester.ensureVisible(actions);
      await tester.tap(actions);
      await tester.pumpAndSettle();
      await click(tester, 'Начальный остаток');
      expect(find.text('Не задан'), findsNothing);
      expect(find.text('Задать начальный остаток'), findsNothing);
      repo.onBalanceLoad = null;
      await click(tester, 'Обновить остаток');
      expect(find.text('Не задан'), findsOneWidget);
      await click(tester, 'Задать начальный остаток');
      await tester.enterText(find.byType(TextFormField), '0,01');
      repo.onBalanceSave = (_, _, _) async =>
          throw const PostgrestException(message: 'denied', code: '42501');
      await click(tester, 'Сохранить остаток');
      expect(find.textContaining('Недостаточно прав'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Сохранить остаток'),
            )
            .onPressed,
        isNotNull,
      );
      repo.onBalanceSave = (_, _, _) async =>
          throw const PostgrestException(message: 'conflict', code: '23505');
      await click(tester, 'Сохранить остаток');
      expect(find.textContaining('изменён в другой сессии'), findsOneWidget);
    },
  );

  testWidgets(
    'Late read discarded after space switch; late save discarded after logout',
    (tester) async {
      final auth = FakeAuth(signedIn: true);
      addTearDown(auth.dispose);
      final repo = FakeFinance()..wallets['personal'] = [cashWallet];
      final read = Completer<BigInt?>();
      repo.onBalanceLoad = (_) => read.future;
      await tester.pumpWidget(FinanceApp(auth: auth, repository: repo));
      await tester.pumpAndSettle();
      // Do not settle the indeterminate progress indicator while read is pending.
      await tester.ensureVisible(find.text('Перейти к кошелькам'));
      await tester.tap(find.text('Перейти к кошелькам'));
      await tester.pump();
      final actions = find.byTooltip('Действия с кошельком');
      await tester.ensureVisible(actions);
      await tester.tap(actions);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('Начальный остаток'));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await tester.ensureVisible(find.text('Личные финансы'));
      await tester.tap(find.text('Личные финансы'));
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('Бизнес').last);
      await tester.pumpAndSettle();
      read.complete(BigInt.from(123456));
      await tester.pumpAndSettle();
      expect(find.text('1234,56 RUB'), findsNothing);
      repo.onBalanceLoad = null;
      await click(tester, 'Бизнес');
      await click(tester, 'Личные финансы');
      final restoredActions = find.byTooltip('Действия с кошельком');
      await tester.ensureVisible(restoredActions);
      await tester.tap(restoredActions);
      await tester.pumpAndSettle();
      await click(tester, 'Начальный остаток');
      await click(tester, 'Задать начальный остаток');
      await tester.enterText(find.byType(TextFormField), '1234,56');
      final save = Completer<BigInt>();
      repo.onBalanceSave = (_, _, _) => save.future;
      await click(tester, 'Сохранить остаток');
      await click(tester, 'Выйти');
      save.complete(BigInt.from(123456));
      await tester.pumpAndSettle();
      expect(find.text('Вход в приложение'), findsOneWidget);
      expect(find.text('1234,56 RUB'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
