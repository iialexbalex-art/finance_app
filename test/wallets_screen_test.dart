import 'dart:async';

import 'package:finance_app/main.dart';
import 'package:finance_app/finance_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_auth.dart';
import 'fake_finance.dart';

Future<void> click(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text).last);
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

void main() {
  for (final size in [const Size(320, 568), const Size(1440, 900)]) {
    testWidgets('Owner form validates and saves once at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = FakeAuth(signedIn: true);
      addTearDown(auth.dispose);
      final repository = FakeFinance();
      final pending = Completer<void>();
      repository.onCreate = () => pending.future;
      await tester.pumpWidget(FinanceApp(auth: auth, repository: repository));
      await tester.pumpAndSettle();
      await click(tester, 'Перейти к кошелькам');
      await click(tester, 'Добавить кошелёк');
      await click(tester, 'Сохранить');
      expect(find.text('Введите название кошелька.'), findsOneWidget);
      expect(repository.inserts, 0);
      await tester.enterText(find.byType(TextFormField), '  Мой кошелёк  ');
      await click(tester, 'Сохранить');
      expect(find.text('Сохраняем…'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Сохраняем…'),
            )
            .onPressed,
        isNull,
      );
      expect(repository.inserts, 1);
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.text('Новый кошелёк'), findsNothing);
      expect(find.text('Мой кошелёк'), findsOneWidget);
      expect(find.textContaining('RUB'), findsWidgets);
      expect(repository.inserts, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Manager sees returned wallets, without creation or balance', (
    tester,
  ) async {
    final auth = FakeAuth(signedIn: true)..userId = 'manager';
    addTearDown(auth.dispose);
    final repository = FakeFinance()..spaces = [businessSpace];
    await tester.pumpWidget(FinanceApp(auth: auth, repository: repository));
    await tester.pumpAndSettle();
    await click(tester, 'Перейти к кошелькам');
    expect(find.text('Добавить кошелёк'), findsNothing);
    expect(find.text('Кошельков пока нет'), findsNWidgets(3));
    expect(find.textContaining('баланс'), findsNothing);
  });

  testWidgets(
    'all 18 active personal wallets are built without hidden inner lists',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = FakeAuth(signedIn: true);
      addTearDown(auth.dispose);
      final repository = FakeFinance();
      const groups = [
        WalletGroup.cash,
        WalletGroup.cash,
        WalletGroup.cash,
        WalletGroup.card,
        WalletGroup.bankAccount,
        WalletGroup.card,
        WalletGroup.card,
        WalletGroup.card,
        WalletGroup.card,
        WalletGroup.bankAccount,
        WalletGroup.card,
        WalletGroup.bankAccount,
        WalletGroup.card,
        WalletGroup.card,
        WalletGroup.bankAccount,
        WalletGroup.cash,
        WalletGroup.cash,
        WalletGroup.cash,
      ];
      repository.wallets[personalSpace.id] = [
        for (var index = 0; index < groups.length; index++)
          Wallet(
            id: 'wallet-$index',
            spaceId: personalSpace.id,
            name: 'Личный кошелёк ${index + 1}',
            group: groups[index],
            currency: 'RUB',
            currencyScale: 2,
            sortOrder: index + 1,
          ),
      ];
      await tester.pumpWidget(FinanceApp(auth: auth, repository: repository));
      await tester.pumpAndSettle();
      await click(tester, 'Перейти к кошелькам');

      expect(find.text('Личный кошелёк 1'), findsOneWidget);
      expect(find.text('Личный кошелёк 18'), findsOneWidget);
      expect(find.byType(ListView), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Space retry and empty state', (tester) async {
    final auth = FakeAuth(signedIn: true);
    addTearDown(auth.dispose);
    final repository = FakeFinance()
      ..onSpaces = () async => throw Exception('offline');
    await tester.pumpWidget(FinanceApp(auth: auth, repository: repository));
    await tester.pumpAndSettle();
    expect(find.textContaining('Проверьте подключение'), findsOneWidget);
    repository.onSpaces = () async => [];
    await click(tester, 'Повторить попытку');
    expect(find.text('Нет доступных пространств'), findsOneWidget);
    expect(find.text('Добавить кошелёк'), findsNothing);
  });

  testWidgets('Switch destroys draft and logout removes loaded data', (
    tester,
  ) async {
    final auth = FakeAuth(signedIn: true);
    addTearDown(auth.dispose);
    final repository = FakeFinance();
    await tester.pumpWidget(FinanceApp(auth: auth, repository: repository));
    await tester.pumpAndSettle();
    await click(tester, 'Перейти к кошелькам');
    await click(tester, 'Добавить кошелёк');
    await tester.enterText(find.byType(TextFormField), 'Личный черновик');
    await click(tester, 'Личные финансы');
    await click(tester, 'Бизнес');
    expect(find.text('Личный черновик'), findsNothing);
    expect(find.text('Новый кошелёк'), findsNothing);
    await click(tester, 'Выйти');
    expect(find.text('Вход в приложение'), findsOneWidget);
    expect(find.text('Бизнес'), findsNothing);
    expect(find.text('Кошельков пока нет'), findsNothing);
  });
}
