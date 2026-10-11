import 'package:finance_app/finance_repository.dart';
import 'package:finance_app/main.dart';
import 'package:finance_app/transfer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'categories_screen_test.dart' show click;
import 'fake_auth.dart';
import 'fake_finance.dart';

FakeFinance overviewData() {
  final repo = FakeFinance()..spaces = [businessSpace, personalSpace];
  repo.wallets['personal'] = [
    const Wallet(
      id: 'personal-secondary',
      spaceId: 'personal',
      name: 'Вторая личная карта',
      group: WalletGroup.card,
      currency: 'RUB',
      iconId: 'card_sber_purple_hq_v1',
      sortOrder: 1,
    ),
    const Wallet(
      id: 'personal-main',
      spaceId: 'personal',
      name: 'Основной личный кошелёк с длинным названием',
      group: WalletGroup.cash,
      currency: 'RUB',
      iconId: 'savings_sber_piggy_bank_hq_v1',
      sortOrder: 2,
    ),
    const Wallet(
      id: 'personal-kzt',
      spaceId: 'personal',
      name: 'Личные тенге',
      group: WalletGroup.bankAccount,
      currency: 'KZT',
      iconId: 'account_kaspi_checking',
      sortOrder: 3,
    ),
    for (var index = 4; index <= 10; index++)
      Wallet(
        id: 'personal-$index',
        spaceId: 'personal',
        name: 'Личный кошелёк $index',
        group: WalletGroup.card,
        currency: 'RUB',
        iconId: 'card_sber_green_hq_v1',
        sortOrder: index,
      ),
    const Wallet(
      id: 'personal-archived',
      spaceId: 'personal',
      name: 'Архивный личный кошелёк',
      group: WalletGroup.cash,
      currency: 'RUB',
      sortOrder: 11,
      isArchived: true,
    ),
  ];
  repo.wallets['business'] = const [
    Wallet(
      id: 'business-rub',
      spaceId: 'business',
      name: 'Расчётный счёт бизнеса',
      group: WalletGroup.bankAccount,
      currency: 'RUB',
      iconId: 'account_sber_business',
      sortOrder: 1,
    ),
    Wallet(
      id: 'business-usd',
      spaceId: 'business',
      name: 'Валютная карта бизнеса',
      group: WalletGroup.card,
      currency: 'USD',
      iconId: 'card_bakai_visa_gold_hq_v1',
      sortOrder: 2,
    ),
  ];
  repo.balances.addAll({
    'personal-secondary': BigInt.from(200),
    'personal-main': BigInt.from(100),
    'personal-kzt': BigInt.from(500),
    for (var index = 4; index <= 10; index++) 'personal-$index': BigInt.zero,
    'personal-archived': BigInt.from(999999),
    'business-rub': BigInt.from(300),
    'business-usd': BigInt.from(700),
  });
  return repo;
}

Future<void> openOverview(
  WidgetTester tester,
  FakeFinance repo,
  Size size,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final auth = FakeAuth(signedIn: true);
  addTearDown(auth.dispose);
  await tester.pumpWidget(FinanceApp(auth: auth, repository: repo));
  await tester.pumpAndSettle();
}

String total(WidgetTester tester, String label, String currency) =>
    tester.widget<Text>(find.byKey(ValueKey('$label:$currency'))).data!;

void main() {
  for (final size in [const Size(320, 700), const Size(1440, 900)]) {
    testWidgets('Both overview tables, exact totals and archive at $size', (
      tester,
    ) async {
      final repo = overviewData();
      await openOverview(tester, repo, size);

      expect(
        find.byKey(const ValueKey('overview-table:Личные финансы')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('overview-table:Бизнес')),
        findsOneWidget,
      );
      expect(find.text('Архивный личный кошелёк'), findsNothing);
      expect(total(tester, 'Итого личные финансы', 'RUB'), '3,00 RUB');
      expect(total(tester, 'Итого личные финансы', 'KZT'), '5,00 KZT');
      expect(total(tester, 'Итого бизнес', 'RUB'), '3,00 RUB');
      expect(total(tester, 'Итого бизнес', 'USD'), '7,00 USD');
      expect(total(tester, 'Всего средств', 'RUB'), '6,00 RUB');
      expect(total(tester, 'Всего средств', 'KZT'), '5,00 KZT');
      expect(total(tester, 'Всего средств', 'USD'), '7,00 USD');

      final personalTable = find.byKey(
        const ValueKey('overview-table:Личные финансы'),
      );
      final scrollable = find.descendant(
        of: personalTable,
        matching: find.byType(Scrollable),
      );
      final scrollState = tester.state<ScrollableState>(scrollable.first);
      expect(scrollState.position.maxScrollExtent, greaterThan(0));
      scrollState.position.jumpTo(scrollState.position.maxScrollExtent);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('overview-wallet:personal-10')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Same-currency transfer without fee keeps overview total', (
    tester,
  ) async {
    final repo = overviewData();
    await openOverview(tester, repo, const Size(1440, 900));
    expect(total(tester, 'Всего средств', 'RUB'), '6,00 RUB');

    repo.transfers['personal'] = [
      Transfer(
        id: 'transfer',
        spaceId: 'personal',
        revision: 'revision',
        sourceId: 'personal-main',
        targetId: 'personal-secondary',
        sourceMinor: BigInt.from(50),
        targetMinor: BigInt.from(50),
        sourceCurrency: 'RUB',
        targetCurrency: 'RUB',
        sourceScale: 2,
        targetScale: 2,
        sourceName: 'Основной',
        targetName: 'Вторая карта',
        date: '2026-10-02',
        comment: '',
        feeMinor: BigInt.zero,
      ),
    ];
    await click(tester, 'Обновить обзор');
    expect(total(tester, 'Итого личные финансы', 'RUB'), '3,00 RUB');
    expect(total(tester, 'Всего средств', 'RUB'), '6,00 RUB');
  });
}
