import 'dart:io';

import 'package:finance_app/expense.dart';
import 'package:finance_app/finance_repository.dart';
import 'package:finance_app/main.dart';
import 'package:finance_app/wallet_icons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'categories_screen_test.dart' show click;
import 'expense_filters_test.dart' show capture;
import 'fake_auth.dart';
import 'fake_finance.dart';

const cash = Wallet(
  id: 'cash',
  spaceId: 'personal',
  name: 'Касса',
  group: WalletGroup.cash,
  currency: 'RUB',
  iconId: 'wallet_bifold_cognac',
  sortOrder: 1,
);
const account = Wallet(
  id: 'account',
  spaceId: 'personal',
  name: 'Накопительный счёт',
  group: WalletGroup.bankAccount,
  currency: 'RUB',
  iconId: 'account_sber_savings',
  sortOrder: 2,
);
const usdCard = Wallet(
  id: 'usd',
  spaceId: 'personal',
  name: 'Долларовая карта',
  group: WalletGroup.card,
  currency: 'USD',
  iconId: 'card_sber_green',
  sortOrder: 3,
);
const archived = Wallet(
  id: 'archived',
  spaceId: 'personal',
  name: 'Старый сейф',
  group: WalletGroup.cash,
  currency: 'RUB',
  iconId: 'safe_steel_photo',
  sortOrder: 4,
  isArchived: true,
);

Expense expenseFor(String wallet, BigInt amount) => Expense(
  id: 'expense-$wallet',
  walletId: wallet,
  categoryId: 'category',
  revision: 'revision',
  date: '2026-10-02',
  amount: amount,
  currency: 'RUB',
  scale: 2,
  walletName: wallet,
  categoryPath: 'Проверка',
  comment: '',
);

FakeFinance preparedWallets() {
  final repo = FakeFinance();
  repo.wallets['personal'] = [cash, account, usdCard, archived];
  repo.wallets['business'] = const [
    Wallet(
      id: 'business-kzt',
      spaceId: 'business',
      name: 'Бизнес KZT',
      group: WalletGroup.bankAccount,
      currency: 'KZT',
      sortOrder: 1,
    ),
  ];
  repo.balances.addAll({
    cash.id: BigInt.from(100),
    account.id: BigInt.from(100),
    usdCard.id: BigInt.from(1000),
    archived.id: BigInt.from(500),
    'business-kzt': BigInt.from(700),
  });
  repo.expenseRows['personal'] = [expenseFor(cash.id, BigInt.from(150))];
  return repo;
}

Future<void> openWallets(
  WidgetTester tester,
  FakeFinance repo, {
  FakeAuth? auth,
}) async {
  final actualAuth = auth ?? FakeAuth(signedIn: true);
  if (auth == null) addTearDown(actualAuth.dispose);
  await tester.pumpWidget(
    RepaintBoundary(
      key: const ValueKey('capture'),
      child: FinanceApp(auth: actualAuth, repository: repo),
    ),
  );
  await tester.pumpAndSettle();
  await click(tester, 'Перейти к кошелькам');
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

  for (final size in [const Size(320, 700), const Size(1440, 900)]) {
    testWidgets('Details, active totals and archive at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = preparedWallets();
      await openWallets(tester, repo);

      expect(find.text('Старый сейф'), findsNothing);
      expect(find.text('Итого наличные'), findsOneWidget);
      expect(find.text('Итого по счетам'), findsOneWidget);
      expect(find.text('Итого по картам'), findsOneWidget);
      expect(find.text('Всего в кошельках'), findsOneWidget);
      expect(
        tester
            .widgetList<WalletMark>(find.byType(WalletMark))
            .every((mark) => mark.size == 64),
        isTrue,
      );
      if (size.width >= 900) {
        final cashTop = tester.getTopLeft(find.text('Наличные').first);
        final accountTop = tester.getTopLeft(find.text('Счета').first);
        final cardTop = tester.getTopLeft(find.text('Карты').first);
        expect(cashTop.dy, closeTo(accountTop.dy, 1));
        expect(accountTop.dy, closeTo(cardTop.dy, 1));
        expect(cashTop.dx, lessThan(accountTop.dx));
        expect(accountTop.dx, lessThan(cardTop.dx));
      }
      expect(find.text('0,50 RUB'), findsOneWidget);
      expect(find.text('10,00 USD'), findsNWidgets(3));
      expect(find.text('5,00 RUB'), findsNothing);
      await capture(tester, 'wallet-totals-${size.width.toInt()}');

      await click(tester, 'Касса');
      expect(find.text('Реквизиты кошелька'), findsOneWidget);
      expect(find.text('Добавить расход'), findsNothing);
      await capture(tester, 'wallet-details-${size.width.toInt()}');
      final walletNavigation = size.width >= 900
          ? find.descendant(
              of: find.byType(NavigationRail),
              matching: find.text('Кошельки'),
            )
          : find.text('Кошельки').last;
      await tester.tap(walletNavigation);
      await tester.pumpAndSettle();
      expect(find.text('Реквизиты кошелька'), findsNothing);
      expect(find.text('Добавить кошелёк'), findsOneWidget);
      await click(tester, 'Касса');
      await click(tester, 'Назад к кошелькам');
      expect(find.text('Реквизиты кошелька'), findsNothing);

      final archiveButton = find.textContaining('Архив кошельков (1)');
      await tester.ensureVisible(archiveButton);
      await tester.tap(archiveButton);
      await tester.pumpAndSettle();
      expect(find.text('Старый сейф'), findsOneWidget);
      await tester.ensureVisible(find.text('Старый сейф'));
      await tester.pumpAndSettle();
      await capture(tester, 'wallet-archive-${size.width.toInt()}');
      final restore = find.byTooltip('Восстановить');
      await tester.ensureVisible(restore);
      await tester.tap(restore);
      await tester.pumpAndSettle();
      expect(repo.wallets['personal']!.last.isArchived, isFalse);
      expect(find.textContaining('Архив кошельков (0)'), findsOneWidget);
      expect(find.text('5,00 RUB'), findsWidgets);

      await click(tester, 'Личные финансы');
      await click(tester, 'Бизнес');
      expect(find.text('7,00 KZT'), findsNWidgets(3));
      expect(find.text('10,00 USD'), findsNothing);
    });
  }

  testWidgets('Edit persists after reload and empty wallet is really deleted', (
    tester,
  ) async {
    final repo = preparedWallets();
    const empty = Wallet(
      id: 'empty',
      spaceId: 'personal',
      name: 'Пустой кошелёк',
      group: WalletGroup.cash,
      currency: 'RUB',
      sortOrder: 5,
    );
    repo.wallets['personal']!.add(empty);
    repo.balances[empty.id] = BigInt.from(12345);
    final untouchedIcon = repo.wallets['personal']!.first.iconId;
    await openWallets(tester, repo);

    await click(tester, 'Пустой кошелёк');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Название'),
      'Переименованный кошелёк',
    );
    await click(tester, 'Значок: Наличные');
    await tester.enterText(
      find.widgetWithText(TextField, 'Поиск значка'),
      'Т-Банк чёрная копилка',
    );
    await tester.pumpAndSettle();
    final hqPiggy = find.byKey(
      const ValueKey('choose-icon:savings_t_bank_piggy_bank_hq_v1'),
    );
    await tester.ensureVisible(hqPiggy);
    await tester.tap(hqPiggy);
    await tester.pumpAndSettle();
    await click(tester, 'Сохранить реквизиты');
    await click(tester, 'Обновить кошельки');
    expect(find.text('Переименованный кошелёк'), findsOneWidget);
    expect(
      repo.wallets['personal']!.singleWhere((w) => w.id == empty.id).iconId,
      'savings_t_bank_piggy_bank_hq_v1',
    );
    expect(repo.wallets['personal']!.first.iconId, untouchedIcon);

    await click(tester, 'Переименованный кошелёк');
    expect(find.textContaining('Т-Банк — чёрная копилка'), findsOneWidget);
    await click(tester, 'Удалить кошелёк');
    expect(
      find.textContaining('Начальный остаток: 123,45 RUB'),
      findsOneWidget,
    );
    await click(tester, 'Удалить кошелёк');
    expect(repo.wallets['personal']!.any((w) => w.id == empty.id), isFalse);
    expect(repo.balances.containsKey(empty.id), isFalse);
    expect(find.textContaining('удалён.'), findsOneWidget);
    await click(tester, 'Обновить кошельки');
    expect(find.text('Переименованный кошелёк'), findsNothing);
  });

  testWidgets('History blocks delete and archive needs a separate choice', (
    tester,
  ) async {
    final repo = preparedWallets();
    await openWallets(tester, repo);
    await click(tester, 'Касса');
    await click(tester, 'Удалить кошелёк');
    await click(tester, 'Удалить кошелёк');
    expect(find.text('Удаление невозможно'), findsOneWidget);
    expect(find.textContaining('связан с расходами'), findsWidgets);
    expect(repo.wallets['personal']!.first.isArchived, isFalse);
    await click(tester, 'Переместить в архив');
    expect(repo.wallets['personal']!.first.isArchived, isTrue);
    expect(find.text('Касса'), findsNothing);
  });

  testWidgets('Pending local operation blocks deletion without success', (
    tester,
  ) async {
    final repo = preparedWallets();
    const empty = Wallet(
      id: 'pending-wallet',
      spaceId: 'personal',
      name: 'Кошелёк с запросом',
      group: WalletGroup.card,
      currency: 'RUB',
      sortOrder: 5,
    );
    repo.wallets['personal']!.add(empty);
    repo.balances[empty.id] = BigInt.zero;
    await repo.expenseDrafts.write(
      'owner',
      PendingExpense(
        requestId: 'pending',
        spaceId: 'personal',
        walletId: empty.id,
        categoryId: 'category',
        amountMinor: '100',
        date: '2026-10-02',
        comment: '',
        currency: 'RUB',
        scale: 2,
        walletName: empty.name,
        categoryPath: 'Проверка',
      ),
    );
    await openWallets(tester, repo);
    await click(tester, empty.name);
    await click(tester, 'Удалить кошелёк');
    await click(tester, 'Удалить кошелёк');
    expect(find.textContaining('незавершённой операцией'), findsWidgets);
    expect(repo.wallets['personal']!.any((w) => w.id == empty.id), isTrue);
    expect(find.textContaining('удалён.'), findsNothing);
  });

  testWidgets('Manager opens read-only details without totals', (tester) async {
    final repo = FakeFinance()
      ..spaces = [businessSpace]
      ..wallets['business'] = const [
        Wallet(
          id: 'assigned',
          spaceId: 'business',
          name: 'Назначенный счёт',
          group: WalletGroup.bankAccount,
          currency: 'KZT',
        ),
      ];
    final auth = FakeAuth(signedIn: true)..userId = 'manager';
    addTearDown(auth.dispose);
    await openWallets(tester, repo, auth: auth);
    await click(tester, 'Назначенный счёт');
    expect(find.text('Реквизиты кошелька'), findsOneWidget);
    expect(find.text('Группа: Счета'), findsOneWidget);
    expect(find.text('Валюта: KZT'), findsOneWidget);
    expect(find.text('Сохранить реквизиты'), findsNothing);
    expect(find.textContaining('Итого'), findsNothing);
    expect(repo.currentReads, 0);
  });
}
