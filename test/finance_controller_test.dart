import 'dart:async';

import 'package:finance_app/finance_controller.dart';
import 'package:finance_app/finance_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'fake_auth.dart';
import 'fake_finance.dart';

Future<void> flush() => Future<void>.delayed(Duration.zero);
Wallet wallet(String space, String name) => Wallet(
  id: name,
  spaceId: space,
  name: name,
  group: WalletGroup.cash,
  currency: 'RUB',
);

void main() {
  late FakeAuth auth;
  late FakeFinance repository;
  late FinanceController state;
  setUp(() {
    auth = FakeAuth(signedIn: true);
    repository = FakeFinance();
  });
  tearDown(() {
    state.dispose();
    auth.dispose();
  });

  test('Switch clears wallets and ignores delayed success and error', () async {
    final a = Completer<List<Wallet>>();
    final b = Completer<List<Wallet>>();
    repository.onWallets = (id) => id == 'personal' ? a.future : b.future;
    state = FinanceController(auth, repository);
    await flush();
    state.selectSpace('business');
    expect(state.wallets, isEmpty);
    b.complete([wallet('business', 'Business wallet')]);
    await flush();
    a.completeError(Exception('late response'));
    await flush();
    expect(state.wallets.single.name, 'Business wallet');
    expect(state.walletsError, isNull);
    expect(state.loadingWallets, isFalse);
  });

  test('A-B-A ignores the first A even when space id matches again', () async {
    final responses = <Completer<List<Wallet>>>[];
    repository.onWallets = (_) {
      final response = Completer<List<Wallet>>();
      responses.add(response);
      return response.future;
    };
    state = FinanceController(auth, repository);
    await flush();
    state.selectSpace('business');
    state.selectSpace('personal');
    responses[2].complete([wallet('personal', 'Newest')]);
    await flush();
    responses[0].complete([wallet('personal', 'Old')]);
    responses[1].complete([wallet('business', 'Foreign')]);
    await flush();
    expect(state.wallets.single.name, 'Newest');
  });

  test(
    'Logout clears data immediately and discards pending wallet response',
    () async {
      final pending = Completer<List<Wallet>>();
      repository.onWallets = (_) => pending.future;
      state = FinanceController(auth, repository);
      await flush();
      await auth.signOut();
      expect(state.spaces, isEmpty);
      expect(state.selectedSpace, isNull);
      expect(state.isOwner, isFalse);
      pending.complete([wallet('personal', 'Private')]);
      await flush();
      expect(state.wallets, isEmpty);
    },
  );

  test('Re-login does not accept spaces from previous session', () async {
    final old = Completer<List<FinanceSpace>>();
    repository.onSpaces = () => old.future;
    state = FinanceController(auth, repository);
    await auth.signOut();
    repository.onSpaces = () async => [businessSpace];
    auth.userId = 'manager';
    await auth.signIn('manager@example.com', 'password');
    await flush();
    old.complete([personalSpace]);
    await flush();
    expect(state.spaces.single.id, 'business');
    expect(state.isOwner, isFalse);
    expect(
      await state.createWallet('Blocked', WalletGroup.cash, 'RUB'),
      isFalse,
    );
    expect(repository.inserts, 0);
  });

  test(
    'Space and wallet errors can be retried, including empty spaces',
    () async {
      repository.onSpaces = () async => throw Exception('offline');
      state = FinanceController(auth, repository);
      await flush();
      expect(state.spacesError, isNotNull);
      repository.onSpaces = () async => [];
      await state.loadSpaces();
      expect(state.spacesError, isNull);
      expect(state.spaces, isEmpty);
      repository.onSpaces = () async => [personalSpace];
      repository.onWallets = (_) async => throw Exception('offline');
      await state.loadSpaces();
      expect(state.walletsError, isNotNull);
      repository.onWallets = (_) async => [wallet('personal', 'Loaded')];
      await state.loadWallets();
      expect(state.walletsError, isNull);
      expect(state.wallets.single.name, 'Loaded');
    },
  );

  test(
    'Create blocks double submit, trims name and refreshes after success',
    () async {
      final pending = Completer<void>();
      repository.onCreate = () => pending.future;
      state = FinanceController(auth, repository);
      await flush();
      final saved = state.createWallet(
        '  Office  ',
        WalletGroup.bankAccount,
        'KZT',
      );
      expect(state.saving, isTrue);
      expect(
        await state.createWallet('Duplicate', WalletGroup.cash, 'USD'),
        isFalse,
      );
      expect(repository.inserts, 1);
      pending.complete();
      expect(await saved, isTrue);
      await flush();
      expect(state.wallets.single.name, 'Office');
      expect(repository.insertedSpace, 'personal');
      expect(repository.insertedGroup, WalletGroup.bankAccount);
      expect(repository.insertedCurrency, 'KZT');
      expect(state.saving, isFalse);
    },
  );

  test('Late save cannot refresh the wrong space', () async {
    final pending = Completer<void>();
    repository.onCreate = () => pending.future;
    state = FinanceController(auth, repository);
    await flush();
    final saved = state.createWallet(
      'Personal wallet',
      WalletGroup.cash,
      'RUB',
    );
    state.selectSpace('business');
    await flush();
    pending.complete();
    expect(await saved, isFalse);
    expect(state.selectedSpace?.id, 'business');
    expect(state.wallets, isEmpty);
    expect(state.saveError, isNull);
  });

  test(
    'Save errors unlock form; failed refresh is not a failed insert',
    () async {
      repository.onCreate = () async =>
          throw const PostgrestException(message: 'denied', code: '42501');
      state = FinanceController(auth, repository);
      await flush();
      expect(
        await state.createWallet('Name', WalletGroup.cash, 'EUR'),
        isFalse,
      );
      expect(state.saveError, contains('Недостаточно прав'));
      expect(state.saving, isFalse);
      repository.onCreate = null;
      repository.onWallets = (_) async => throw Exception('refresh failed');
      expect(await state.createWallet('Name', WalletGroup.cash, 'EUR'), isTrue);
      await flush();
      expect(state.saveError, isNull);
      expect(state.walletsError, isNotNull);
    },
  );

  test(
    'New currencies, order, archive and delete stay server-backed',
    () async {
      repository.wallets['personal'] = [
        wallet('personal', 'A'),
        wallet('personal', 'B'),
        wallet('personal', 'C'),
      ];
      state = FinanceController(auth, repository);
      await flush();
      await state.loadWallets();
      expect(await state.createWallet('Баты', WalletGroup.cash, 'THB'), isTrue);
      await state.loadWallets();
      expect(repository.insertedCurrency, 'THB');
      final second = state.wallets[1];
      expect(await state.moveWallet(second, -1), isTrue);
      expect(state.wallets.first.id, second.id);
      expect(await state.setWalletArchived(state.wallets.first, true), isTrue);
      expect(state.wallets.first.isArchived, isTrue);
      expect(await state.deleteWallet(state.wallets.first), isTrue);
      expect(state.wallets.any((w) => w.id == second.id), isFalse);
      for (final currency in ['EGP', 'TRY']) {
        expect(
          await state.createWallet(currency, WalletGroup.cash, currency),
          isTrue,
        );
      }
    },
  );

  test(
    'Reorder sends every wallet when an archived wallet is hidden',
    () async {
      repository.wallets['personal'] = [
        wallet('personal', 'A'),
        const Wallet(
          id: 'archived',
          spaceId: 'personal',
          name: 'Archived',
          group: WalletGroup.cash,
          currency: 'RUB',
          sortOrder: 2,
          isArchived: true,
        ),
        wallet('personal', 'B'),
      ];
      state = FinanceController(auth, repository);
      await flush();
      await state.loadWallets();
      final b = state.wallets.last;
      expect(await state.moveWallet(b, -1), isTrue);
      expect(repository.wallets['personal']!.map((wallet) => wallet.name), [
        'B',
        'Archived',
        'A',
      ]);
    },
  );
}
