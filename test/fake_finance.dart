import 'package:finance_app/finance_repository.dart';
import 'package:finance_app/category.dart';
import 'package:finance_app/expense.dart';
import 'package:finance_app/expense_filter.dart';
import 'package:finance_app/transfer.dart';
import 'package:finance_app/transfer_draft_store.dart';

import 'dart:convert';

import 'package:finance_app/expense_draft_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const personalSpace = FinanceSpace(
  id: 'personal',
  ownerUserId: 'owner',
  name: 'Личные финансы',
  kind: 'personal',
);
const businessSpace = FinanceSpace(
  id: 'business',
  ownerUserId: 'owner',
  name: 'Бизнес',
  kind: 'business',
);

class FakeFinance extends FinanceRepository {
  @override
  final ExpenseDraftStore incomeDrafts = MemoryExpenseDraftStore();
  @override
  final TransferDraftStore transferDrafts = MemoryTransferDraftStore();
  late final FakeFinance incomeLedger = FakeFinance();
  Future<String> Function(PendingExpense)? onIncomeSave;
  @override
  Future<String> saveIncome(PendingExpense draft) async {
    if (onIncomeSave != null) return onIncomeSave!(draft);
    return draft.isEdit
        ? incomeLedger.editExpense(draft)
        : incomeLedger.createExpense(draft);
  }

  @override
  Future<ExpenseQueryResult> queryIncomes(
    String spaceId,
    ExpenseFilter filter, {
    Expense? before,
    required bool includeTotals,
  }) {
    incomeLedger.categories
      ..clear()
      ..addAll(categories);
    return incomeLedger.queryExpenses(
      spaceId,
      filter,
      before: before,
      includeTotals: includeTotals,
    );
  }

  @override
  Future<SpaceBalances> loadSpaceBalances(String spaceId) async {
    final rows = onWallets != null
        ? await onWallets!(spaceId)
        : List<Wallet>.from(wallets[spaceId] ?? []);
    return SpaceBalances(rows, {
      for (final w in rows) w.id: await loadExpenseBalance(w.id),
    });
  }

  final transfers = <String, List<Transfer>>{};
  final transferReceipts = <String, PendingTransfer>{};
  final transferIds = <String, String>{};
  final attemptedTransfers = <PendingTransfer>[];
  Future<String> Function(PendingTransfer)? onTransferSave;
  Future<TransferPage> Function(String, ExpenseFilter, Transfer?)? onTransfers;
  @override
  Future<String> saveTransfer(PendingTransfer draft) async {
    attemptedTransfers.add(draft);
    return onTransferSave != null
        ? onTransferSave!(draft)
        : commitTransfer(draft);
  }

  String commitTransfer(PendingTransfer draft) {
    final d = draft.data;
    if (transferReceipts.containsKey(draft.requestId)) {
      if (jsonEncode(transferReceipts[draft.requestId]!.data) !=
          jsonEncode(d)) {
        throw const PostgrestException(message: 'reused', code: 'P1002');
      }
      return transferIds[draft.requestId]!;
    }
    final rows = transfers.putIfAbsent(draft.spaceId, () => []);
    final old = rows.where((t) => t.id == d['id']).firstOrNull;
    if (d['id'] != null && old?.revision != d['revision']) {
      throw const PostgrestException(message: 'conflict', code: 'P1003');
    }
    if (d['source_id'] == d['target_id']) {
      throw const PostgrestException(message: 'same wallet', code: '22023');
    }
    if (d['source_currency'] == d['target_currency'] &&
        equalCurrencyAmount(
              BigInt.parse(d['source_minor'] as String),
              d['source_scale'] as int,
              d['target_scale'] as int,
            ) !=
            BigInt.parse(d['target_minor'] as String)) {
      throw const PostgrestException(message: 'amounts', code: '22023');
    }
    final id = d['id'] as String? ?? newExpenseRequestId();
    final row = Transfer.fromJson({
      ...d,
      ...draft.display,
      'id': id,
      'revision': newExpenseRequestId(),
      'transfer_date': d['date'],
    });
    rows.removeWhere((t) => t.id == id);
    rows.add(row);
    final expenses = expenseRows.putIfAbsent(draft.spaceId, () => []);
    expenses.removeWhere((e) => e.transferId == id);
    if (row.feeMinor > BigInt.zero) {
      expenses.add(
        Expense(
          id: 'fee:$id',
          date: row.date,
          amount: row.feeMinor,
          currency: row.sourceCurrency,
          scale: row.sourceScale,
          walletName: row.sourceName,
          categoryPath: row.feeCategoryPath!,
          comment: 'Комиссия перевода',
          walletId: row.sourceId,
          categoryId: row.feeCategoryId!,
          revision: row.revision,
          transferId: id,
        ),
      );
    }
    transferReceipts[draft.requestId] = draft;
    transferIds[draft.requestId] = id;
    return id;
  }

  @override
  Future<TransferPage> queryTransfers(
    String spaceId,
    ExpenseFilter filter, {
    Transfer? before,
    String search = '',
    String? id,
  }) async {
    if (onTransfers != null) return onTransfers!(spaceId, filter, before);
    final rows =
        (transfers[spaceId] ?? [])
            .where(
              (t) =>
                  (id == null || t.id == id) &&
                  (filter.walletIds.isEmpty ||
                      filter.walletIds.contains(t.sourceId) ||
                      filter.walletIds.contains(t.targetId)) &&
                  (filter.from == null ||
                      t.date.compareTo(filter.from!) >= 0) &&
                  (filter.to == null || t.date.compareTo(filter.to!) <= 0) &&
                  t.comment.toLowerCase().contains(search.toLowerCase()) &&
                  (before == null ||
                      t.date.compareTo(before.date) < 0 ||
                      (t.date == before.date && t.id.compareTo(before.id) < 0)),
            )
            .toList()
          ..sort(
            (a, b) => a.date == b.date
                ? b.id.compareTo(a.id)
                : b.date.compareTo(a.date),
          );
    return TransferPage(rows.take(25).toList(), rows.length > 25);
  }

  final List<ExpenseFilter> filters = [];
  final List<bool> totalsRequests = [];
  @override
  Future<void> editWallet(
    Wallet previous,
    String name,
    WalletGroup group, {
    String? iconId,
  }) async {
    final rows = wallets[previous.spaceId]!;
    final index = rows.indexWhere(
      (w) =>
          w.id == previous.id &&
          w.name == previous.name &&
          w.group == previous.group &&
          w.displayIconId == previous.displayIconId,
    );
    if (index < 0) throw StateError('conflict');
    rows[index] = Wallet(
      id: previous.id,
      spaceId: previous.spaceId,
      name: name,
      group: group,
      currency: previous.currency,
      currencyScale: previous.currencyScale,
      iconId: iconId ?? previous.iconId,
      sortOrder: previous.sortOrder,
      isArchived: previous.isArchived,
    );
  }

  @override
  Future<void> setWalletArchived(Wallet previous, bool archived) async {
    final rows = wallets[previous.spaceId]!;
    final index = rows.indexWhere((w) => w.id == previous.id);
    if (index < 0 || rows[index].isArchived != previous.isArchived) {
      throw StateError('conflict');
    }
    final w = rows[index];
    rows[index] = Wallet(
      id: w.id,
      spaceId: w.spaceId,
      name: w.name,
      group: w.group,
      currency: w.currency,
      currencyScale: w.currencyScale,
      iconId: w.iconId,
      sortOrder: w.sortOrder,
      isArchived: archived,
    );
  }

  @override
  Future<void> reorderWallets(String spaceId, List<String> walletIds) async {
    final rows = wallets[spaceId]!;
    if (walletIds.toSet().length != rows.length ||
        !walletIds.toSet().containsAll(rows.map((w) => w.id))) {
      throw StateError('invalid order');
    }
    final byId = {for (final wallet in rows) wallet.id: wallet};
    wallets[spaceId] = [for (final id in walletIds) byId[id]!];
  }

  @override
  Future<void> deleteWallet(Wallet wallet) async {
    final linked =
        expenseRows.values
            .expand((rows) => rows)
            .any((row) => row.walletId == wallet.id) ||
        incomeLedger.expenseRows.values
            .expand((rows) => rows)
            .any((row) => row.walletId == wallet.id) ||
        transfers.values
            .expand((rows) => rows)
            .any(
              (row) => row.sourceId == wallet.id || row.targetId == wallet.id,
            );
    if (linked) {
      throw const PostgrestException(
        message: 'wallet is referenced',
        code: '23503',
      );
    }
    wallets[wallet.spaceId]?.removeWhere((w) => w.id == wallet.id);
    balances.remove(wallet.id);
  }

  @override
  Future<ExpenseQueryResult> queryExpenses(
    String spaceId,
    ExpenseFilter filter, {
    Expense? before,
    required bool includeTotals,
  }) async {
    filters.add(filter);
    totalsRequests.add(includeTotals);
    if (onExpenses != null) {
      return ExpenseQueryResult(await onExpenses!(spaceId, before), []);
    }
    final ids = filter.categoryIds.toSet();
    var changed = true;
    while (changed) {
      final size = ids.length;
      ids.addAll(
        categories
            .where((c) => c.spaceId == spaceId && ids.contains(c.parentId))
            .map((c) => c.id),
      );
      changed = size != ids.length;
    }
    final all =
        (expenseRows[spaceId] ?? [])
            .where(
              (e) =>
                  (filter.walletIds.isEmpty ||
                      filter.walletIds.contains(e.walletId)) &&
                  (ids.isEmpty || ids.contains(e.categoryId)) &&
                  (filter.from == null ||
                      e.date.compareTo(filter.from!) >= 0) &&
                  (filter.to == null || e.date.compareTo(filter.to!) <= 0),
            )
            .toList()
          ..sort(
            (a, b) => a.date == b.date
                ? b.id.compareTo(a.id)
                : b.date.compareTo(a.date),
          );
    final sums = <String, ExpenseTotal>{};
    if (includeTotals) {
      for (final e in all) {
        final key = e.currency;
        final previous = sums[key];
        final scale = (previous?.scale ?? 0) > e.scale
            ? previous!.scale
            : e.scale;
        sums[key] = ExpenseTotal(
          e.currency,
          scale,
          (previous?.amount ?? BigInt.zero) *
                  BigInt.from(10).pow(scale - (previous?.scale ?? scale)) +
              e.amount * BigInt.from(10).pow(scale - e.scale),
        );
      }
    }
    final rows = all
        .where(
          (e) =>
              before == null ||
              e.date.compareTo(before.date) < 0 ||
              (e.date == before.date && e.id.compareTo(before.id) < 0),
        )
        .toList();
    return ExpenseQueryResult(
      ExpensePage(rows.take(25).toList(), rows.length > 25),
      sums.values.toList(),
    );
  }

  @override
  final ExpenseDraftStore expenseDrafts = MemoryExpenseDraftStore();
  final Map<String, List<Expense>> expenseRows = {};
  final Map<String, PendingExpense> expensePayloads = {};
  Future<String> Function(PendingExpense)? onExpenseSave;
  Future<ExpensePage> Function(String, Expense?)? onExpenses;
  int expenseWrites = 0, currentReads = 0;
  final List<PendingExpense> attemptedExpenses = [];
  final List<PendingExpense> attemptedEdits = [];
  final Map<String, String> editReceipts = {};
  Future<String> Function(PendingExpense)? onExpenseEdit;
  @override
  Future<String> editExpense(PendingExpense draft) async {
    attemptedEdits.add(draft);
    if (onExpenseEdit != null) return onExpenseEdit!(draft);
    return commitEdit(draft);
  }

  String commitEdit(PendingExpense draft) {
    if (editReceipts.containsKey(draft.requestId)) return draft.expenseId!;
    final rows = expenseRows[draft.spaceId]!;
    final index = rows.indexWhere((e) => e.id == draft.expenseId);
    if (rows[index].revision != draft.expectedRevision) {
      throw const PostgrestException(message: 'conflict', code: 'P1003');
    }
    rows[index] = Expense(
      id: draft.expenseId!,
      date: draft.date,
      amount: BigInt.parse(draft.amountMinor),
      currency: draft.currency,
      scale: draft.scale,
      walletName: draft.walletName,
      categoryPath: draft.categoryPath,
      comment: draft.comment,
      walletId: draft.walletId,
      categoryId: draft.categoryId,
      revision: newExpenseRequestId(),
    );
    expensePayloads[draft.expenseId!] = draft;
    editReceipts[draft.requestId] = draft.expenseId!;
    return draft.expenseId!;
  }

  @override
  Future<String> createExpense(PendingExpense draft) async {
    expenseWrites++;
    attemptedExpenses.add(draft);
    if (onExpenseSave != null) return onExpenseSave!(draft);
    return commitExpense(draft);
  }

  String commitExpense(PendingExpense draft) {
    if (!expensePayloads.containsKey(draft.requestId)) {
      expensePayloads[draft.requestId] = draft;
      expenseRows
          .putIfAbsent(draft.spaceId, () => [])
          .add(
            Expense(
              id: draft.requestId,
              walletId: draft.walletId,
              categoryId: draft.categoryId,
              revision: newExpenseRequestId(),
              date: draft.date,
              amount: BigInt.parse(draft.amountMinor),
              currency: draft.currency,
              scale: draft.scale,
              walletName: draft.walletName,
              categoryPath: draft.categoryPath,
              comment: draft.comment,
            ),
          );
    }
    return draft.requestId;
  }

  @override
  Future<ExpensePage> loadExpenses(String spaceId, {Expense? before}) async {
    if (onExpenses != null) return onExpenses!(spaceId, before);
    final all = [...expenseRows[spaceId] ?? <Expense>[]]
      ..sort((a, b) {
        final d = b.date.compareTo(a.date);
        return d == 0 ? b.id.compareTo(a.id) : d;
      });
    final rows = all
        .where(
          (e) =>
              before == null ||
              e.date.compareTo(before.date) < 0 ||
              (e.date == before.date && e.id.compareTo(before.id) < 0),
        )
        .toList();
    return ExpensePage(rows.take(25).toList(), rows.length > 25);
  }

  @override
  Future<WalletExpenseBalance> loadExpenseBalance(String walletId) async {
    currentReads++;
    final spent = expenseRows.values
        .expand((rows) => rows)
        .where((e) => e.walletId == walletId)
        .fold(BigInt.zero, (sum, e) => sum + e.amount);
    final income = incomeLedger.expenseRows.values
        .expand((rows) => rows)
        .where((e) => e.walletId == walletId)
        .fold(BigInt.zero, (sum, e) => sum + e.amount);
    final incoming = transfers.values
        .expand((rows) => rows)
        .where((e) => e.targetId == walletId)
        .fold(BigInt.zero, (sum, e) => sum + e.targetMinor);
    final outgoing = transfers.values
        .expand((rows) => rows)
        .where((e) => e.sourceId == walletId)
        .fold(BigInt.zero, (sum, e) => sum + e.sourceMinor);
    return WalletExpenseBalance(
      opening: balances[walletId],
      spent: spent,
      current:
          (balances[walletId] ?? BigInt.zero) +
          income -
          spent +
          incoming -
          outgoing,
    );
  }

  final List<FinanceCategory> categories = [];
  Future<List<FinanceCategory>> Function(String, CategoryKind)? onCategories;
  Future<void> Function()? onCategorySave;
  int categoryWrites = 0;
  @override
  Future<List<FinanceCategory>> loadCategories(
    String spaceId,
    CategoryKind kind,
  ) async => onCategories != null
      ? onCategories!(spaceId, kind)
      : categories
            .where((c) => c.spaceId == spaceId && c.kind == kind)
            .toList();
  @override
  Future<FinanceCategory> createCategory(
    String spaceId,
    CategoryKind kind,
    String name,
    String? parentId, {
    String iconId = 'category',
  }) async {
    categoryWrites++;
    if (onCategorySave != null) await onCategorySave!();
    final category = FinanceCategory(
      id: 'category-$categoryWrites',
      iconId: iconId,
      spaceId: spaceId,
      kind: kind,
      name: name,
      parentId: parentId,
    );
    categories.add(category);
    return category;
  }

  @override
  Future<FinanceCategory> editCategory(
    FinanceCategory previous, {
    String? name,
    String? iconId,
    bool? archived,
    bool changeParent = false,
    String? parentId,
  }) async {
    categoryWrites++;
    if (onCategorySave != null) await onCategorySave!();
    final category = FinanceCategory(
      id: previous.id,
      spaceId: previous.spaceId,
      kind: previous.kind,
      name: name ?? previous.name,
      iconId: iconId ?? previous.iconId,
      parentId: changeParent ? parentId : previous.parentId,
      isArchived: archived ?? previous.isArchived,
    );
    categories[categories.indexWhere((c) => c.id == previous.id)] = category;
    return category;
  }

  final Map<String, BigInt> balances = {};
  Future<BigInt?> Function(String)? onBalanceLoad;
  Future<BigInt> Function(String, BigInt, BigInt?)? onBalanceSave;
  int balanceReads = 0;
  int balanceWrites = 0;
  BigInt? lastPrevious;
  @override
  Future<BigInt?> loadOpeningBalance(String walletId) async {
    balanceReads++;
    return onBalanceLoad != null
        ? onBalanceLoad!(walletId)
        : balances[walletId];
  }

  @override
  Future<BigInt> saveOpeningBalance(
    String walletId,
    BigInt amount, {
    required BigInt? previous,
  }) async {
    balanceWrites++;
    lastPrevious = previous;
    if (onBalanceSave != null) {
      return onBalanceSave!(walletId, amount, previous);
    }
    balances[walletId] = amount;
    return amount;
  }

  List<FinanceSpace> spaces = [personalSpace, businessSpace];
  final Map<String, List<Wallet>> wallets = {};
  Future<List<FinanceSpace>> Function()? onSpaces;
  Future<List<Wallet>> Function(String)? onWallets;
  Future<void> Function()? onCreate;
  int inserts = 0;
  String? insertedSpace;
  String? insertedName;
  WalletGroup? insertedGroup;
  String? insertedCurrency;
  @override
  Future<List<FinanceSpace>> loadSpaces() async =>
      onSpaces != null ? onSpaces!() : spaces;
  @override
  Future<List<Wallet>> loadWallets(String spaceId) async =>
      onWallets != null ? onWallets!(spaceId) : List.of(wallets[spaceId] ?? []);
  @override
  Future<void> createWallet({
    required String spaceId,
    required String name,
    required WalletGroup group,
    required String currency,
    String? iconId,
  }) async {
    inserts++;
    insertedSpace = spaceId;
    insertedName = name;
    insertedGroup = group;
    insertedCurrency = currency;
    if (onCreate != null) await onCreate!();
    wallets
        .putIfAbsent(spaceId, () => [])
        .add(
          Wallet(
            id: '$inserts',
            spaceId: spaceId,
            name: name,
            group: group,
            currency: currency,
            iconId: iconId,
            sortOrder: (wallets[spaceId]?.length ?? 0) + 1,
          ),
        );
  }
}
