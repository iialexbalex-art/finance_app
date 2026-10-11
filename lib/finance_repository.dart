import 'package:supabase_flutter/supabase_flutter.dart';

import 'money.dart';
import 'category.dart';
import 'expense.dart';
import 'expense_draft_store.dart';
import 'expense_filter.dart';
import 'transfer.dart';
import 'transfer_draft_store.dart';
import 'backup_service.dart';
import 'config.dart';

class FinanceSpace {
  const FinanceSpace({
    required this.id,
    required this.ownerUserId,
    required this.name,
    required this.kind,
  });
  final String id;
  final String ownerUserId;
  final String name;
  final String kind;

  factory FinanceSpace.fromJson(Map<String, dynamic> row) => FinanceSpace(
    id: row['id'] as String,
    ownerUserId: row['owner_user_id'] as String,
    name: row['name'] as String,
    kind: row['kind'] as String,
  );
}

enum WalletGroup {
  cash('cash', 'Наличные'),
  bankAccount('bank_account', 'Счета'),
  card('card', 'Карты');

  const WalletGroup(this.value, this.label);
  final String value;
  final String label;
}

const walletCurrencies = ['RUB', 'KZT', 'USD', 'EUR', 'THB', 'EGP', 'TRY'];

class SpaceBalances {
  const SpaceBalances(this.wallets, this.balances);
  final List<Wallet> wallets;
  final Map<String, WalletExpenseBalance> balances;
}

class Wallet {
  const Wallet({
    required this.id,
    required this.spaceId,
    required this.name,
    required this.group,
    required this.currency,
    this.currencyScale = 2,
    this.iconId,
    this.sortOrder = 0,
    this.isArchived = false,
    this.revision,
  });
  final String id;
  final String spaceId;
  final String name;
  final WalletGroup group;
  final String currency;
  final int currencyScale;
  final String? iconId;
  final int sortOrder;
  final bool isArchived;
  final String? revision;
  String get displayIconId =>
      iconId ??
      switch (group) {
        WalletGroup.cash => 'cash',
        WalletGroup.bankAccount => 'bank',
        WalletGroup.card => 'card',
      };

  factory Wallet.fromJson(Map<String, dynamic> row) => Wallet(
    id: row['id'] as String,
    spaceId: row['space_id'] as String,
    name: row['name'] as String,
    currency: row['currency'] as String,
    currencyScale: row['currency_scale'] as int,
    iconId: row['icon_id'] as String?,
    sortOrder: row['sort_order'] as int? ?? 0,
    isArchived: row['is_archived'] as bool? ?? false,
    revision: row['revision'] as String?,
    group: WalletGroup.values.firstWhere(
      (group) => group.value == row['wallet_group'],
    ),
  );
}

abstract class FinanceRepository {
  Future<List<Map<String, dynamic>>> categoryDeletePlan(
    String spaceId,
    CategoryKind kind,
    List<String> ids,
    List<FinanceCategory> snapshot,
  ) => throw UnimplementedError();
  Future<void> mutateCategories(
    String requestId,
    String spaceId,
    CategoryKind kind,
    String action,
    List<String> ids,
    List<FinanceCategory> snapshot, {
    Map<String, String> replacements = const {},
  }) => throw UnimplementedError();
  Future<void> reorderCategories(
    String requestId,
    String spaceId,
    CategoryKind kind,
    String? parentId,
    List<String> ids,
    List<FinanceCategory> snapshot,
  ) => throw UnimplementedError();
  Future<void> deleteCashflow(
    String requestId,
    String spaceId,
    CategoryKind kind,
    List<Expense> rows,
  ) => throw UnimplementedError();
  Future<SpaceBalances> loadSpaceBalances(String spaceId);
  ExpenseDraftStore get incomeDrafts;
  TransferDraftStore get transferDrafts;
  Future<String> saveIncome(PendingExpense draft);
  Future<ExpenseQueryResult> queryIncomes(
    String spaceId,
    ExpenseFilter filter, {
    Expense? before,
    required bool includeTotals,
  });
  Future<String> saveTransfer(PendingTransfer draft);
  Future<TransferPage> queryTransfers(
    String spaceId,
    ExpenseFilter filter, {
    Transfer? before,
    String search = '',
    String? id,
  });
  Future<ExpenseQueryResult> queryExpenses(
    String spaceId,
    ExpenseFilter filter, {
    Expense? before,
    required bool includeTotals,
  });
  Future<void> editWallet(
    Wallet previous,
    String name,
    WalletGroup group, {
    String? iconId,
  });
  Future<void> setWalletArchived(Wallet previous, bool archived) =>
      throw UnimplementedError();
  Future<void> reorderWallets(String spaceId, List<String> walletIds) =>
      throw UnimplementedError();
  Future<void> deleteWallet(Wallet wallet) => throw UnimplementedError();
  Future<bool> hasPendingWalletUse(
    String userId,
    String spaceId,
    String walletId,
  ) async =>
      await expenseDrafts.referencesWallet(userId, spaceId, walletId) ||
      await incomeDrafts.referencesWallet(userId, spaceId, walletId) ||
      await transferDrafts.referencesWallet(userId, spaceId, walletId);
  ExpenseDraftStore get expenseDrafts;
  Future<String> createExpense(PendingExpense draft);
  Future<String> editExpense(PendingExpense draft);
  Future<ExpensePage> loadExpenses(String spaceId, {Expense? before});
  Future<WalletExpenseBalance> loadExpenseBalance(String walletId);
  Future<List<FinanceCategory>> loadCategories(
    String spaceId,
    CategoryKind kind,
  );
  Future<FinanceCategory> createCategory(
    String spaceId,
    CategoryKind kind,
    String name,
    String? parentId, {
    String iconId = 'category',
  });
  Future<FinanceCategory> editCategory(
    FinanceCategory previous, {
    String? name,
    String? iconId,
    bool? archived,
    bool changeParent = false,
    String? parentId,
  });
  Future<BigInt?> loadOpeningBalance(String walletId);
  Future<BigInt> saveOpeningBalance(
    String walletId,
    BigInt amount, {
    required BigInt? previous,
  });
  Future<List<FinanceSpace>> loadSpaces();
  Future<List<Wallet>> loadWallets(String spaceId);
  Future<void> createWallet({
    required String spaceId,
    required String name,
    required WalletGroup group,
    required String currency,
    String? iconId,
  });
}

class SupabaseFinanceRepository implements FinanceRepository {
  SupabaseFinanceRepository(this._client);
  final SupabaseClient _client;
  SupabaseClient get client => _client;
  Future<void> _protect(String requestId, String reason) async {
    if (AppConfig.backupApiUrl.isNotEmpty) {
      await BackupService(_client).protect(requestId, reason);
    }
  }

  bool _hasCategoryRevision = false;
  bool _hasBackupSchema = AppConfig.backupApiUrl.isNotEmpty;
  bool _hasOpeningRevision = false;
  final Map<String, String> _openingRevisions = {};
  @override
  Future<List<Map<String, dynamic>>> categoryDeletePlan(
    String spaceId,
    CategoryKind kind,
    List<String> ids,
    List<FinanceCategory> snapshot,
  ) async => (await _client.rpc(
    'category_delete_plan',
    params: {
      'p_space_id': spaceId,
      'p_kind': kind.value,
      'p_ids': ids,
      'p_expected': categorySnapshot(snapshot),
    },
  ) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  @override
  Future<void> mutateCategories(
    String requestId,
    String spaceId,
    CategoryKind kind,
    String action,
    List<String> ids,
    List<FinanceCategory> snapshot, {
    Map<String, String> replacements = const {},
  }) async {
    await _protect(requestId, 'Перед $action ${ids.length} категорий');
    await _client.rpc(
      'mutate_categories',
      params: {
        'p_request_id': requestId,
        'p_space_id': spaceId,
        'p_kind': kind.value,
        'p_action': action,
        'p_ids': ids,
        'p_expected': categorySnapshot(snapshot),
        'p_replacements': replacements,
      },
    );
  }

  @override
  Future<void> reorderCategories(
    String requestId,
    String spaceId,
    CategoryKind kind,
    String? parentId,
    List<String> ids,
    List<FinanceCategory> snapshot,
  ) async {
    await _protect(
      requestId,
      'Перед изменением порядка ${ids.length} категорий',
    );
    await _client.rpc(
      'reorder_categories',
      params: {
        'p_request_id': requestId,
        'p_space_id': spaceId,
        'p_kind': kind.value,
        'p_parent_id': parentId,
        'p_ids': ids,
        'p_expected': categorySnapshot(snapshot),
      },
    );
  }

  @override
  Future<void> deleteCashflow(
    String requestId,
    String spaceId,
    CategoryKind kind,
    List<Expense> rows,
  ) async {
    await _protect(requestId, 'Перед удалением ${rows.length} операций');
    await _client.rpc(
      'delete_cashflow',
      params: {
        'p_request_id': requestId,
        'p_space_id': spaceId,
        'p_kind': kind.value,
        'p_rows': [
          for (final e in rows) {'id': e.id, 'revision': e.revision},
        ],
      },
    );
  }

  @override
  Future<bool> hasPendingWalletUse(
    String userId,
    String spaceId,
    String walletId,
  ) async =>
      await expenseDrafts.referencesWallet(userId, spaceId, walletId) ||
      await incomeDrafts.referencesWallet(userId, spaceId, walletId) ||
      await transferDrafts.referencesWallet(userId, spaceId, walletId);
  @override
  Future<SpaceBalances> loadSpaceBalances(String spaceId) async {
    final rows = await _client.rpc(
      'space_balances',
      params: {'p_space_id': spaceId},
    ) as List;
    return SpaceBalances(
      [
        for (final row in rows)
          Wallet.fromJson(Map<String, dynamic>.from(row as Map)),
      ],
      {
        for (final row in rows)
          row['id'] as String: WalletExpenseBalance.fromJson(
            Map<String, dynamic>.from(row['balance'] as Map),
          ),
      },
    );
  }

  @override
  final ExpenseDraftStore incomeDrafts = LocalExpenseDraftStore(
    namespace: 'income_pending_v1',
  );
  @override
  final TransferDraftStore transferDrafts = LocalTransferDraftStore();
  @override
  Future<String> saveIncome(PendingExpense draft) async => await _client.rpc(
    'save_income',
    params: {
      'p_request_id': draft.requestId,
      'p_space_id': draft.spaceId,
      'p_income_id': draft.expenseId,
      'p_expected_revision': draft.expectedRevision,
      'p_wallet_id': draft.walletId,
      'p_category_id': draft.categoryId,
      'p_amount_minor': draft.amountMinor,
      'p_income_date': draft.date,
      'p_comment': draft.comment,
      'p_currency': draft.currency,
      'p_currency_scale': draft.scale,
    },
  ) as String;
  @override
  Future<ExpenseQueryResult> queryIncomes(
    String spaceId,
    ExpenseFilter filter, {
    Expense? before,
    required bool includeTotals,
  }) => _queryCashFlow(
    'query_incomes',
    spaceId,
    filter,
    before: before,
    includeTotals: includeTotals,
  );
  @override
  Future<String> saveTransfer(PendingTransfer draft) async => await _client.rpc(
    'save_transfer',
    params: {'p_request_id': draft.requestId, 'p_data': draft.data},
  ) as String;
  @override
  Future<TransferPage> queryTransfers(
    String spaceId,
    ExpenseFilter filter, {
    Transfer? before,
    String search = '',
    String? id,
  }) async {
    final result = await _client.rpc(
      'query_transfers',
      params: {
        'p_space_id': spaceId,
        'p_wallet_ids': filter.walletIds,
        'p_from': filter.from,
        'p_to': filter.to,
        'p_before_date': before?.date,
        'p_before_id': before?.id,
        'p_search': search,
        'p_id': id,
      },
    ) as List;
    return TransferPage(
      result
          .take(25)
          .map((e) => Transfer.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      result.length > 25,
    );
  }

  @override
  Future<void> editWallet(
    Wallet previous,
    String name,
    WalletGroup group, {
    String? iconId,
  }) async {
    if (_hasBackupSchema || previous.revision != null) {
      await _backupWrite('wallets', 'update', previous.id, previous.revision, {
        'name': name,
        'wallet_group': group.value,
        'icon_id': ?iconId,
      });
      return;
    }
    var query = _client
        .from('wallets')
        .update({'name': name, 'wallet_group': group.value, 'icon_id': ?iconId})
        .eq('id', previous.id)
        .eq('space_id', previous.spaceId)
        .eq('name', previous.name)
        .eq('wallet_group', previous.group.value)
        .eq('icon_id', previous.displayIconId);
    await query.select('id').single();
  }

  @override
  Future<void> setWalletArchived(Wallet previous, bool archived) async {
    if (_hasBackupSchema || previous.revision != null) {
      await _backupWrite('wallets', 'update', previous.id, previous.revision, {
        'is_archived': archived,
      });
      return;
    }
    var query = _client
        .from('wallets')
        .update({'is_archived': archived})
        .eq('id', previous.id)
        .eq('space_id', previous.spaceId)
        .eq('is_archived', previous.isArchived);
    await query.select('id').single();
  }

  @override
  Future<void> reorderWallets(String spaceId, List<String> walletIds) async {
    final requestId = newExpenseRequestId();
    await _protect(
      requestId,
      'Перед изменением порядка ${walletIds.length} кошельков',
    );
    await _client.rpc(
      'reorder_wallets',
      params: {
        'p_space_id': spaceId,
        'p_wallet_ids': walletIds,
        if (AppConfig.backupApiUrl.isNotEmpty) 'p_request_id': requestId,
      },
    );
  }

  @override
  Future<void> deleteWallet(Wallet wallet) async {
    if (_hasBackupSchema || wallet.revision != null) {
      await _backupWrite('wallets', 'delete', wallet.id, wallet.revision, {});
      return;
    }
    var query = _client
        .from('wallets')
        .delete()
        .eq('id', wallet.id)
        .eq('space_id', wallet.spaceId);
    await query.select('id').single();
  }

  @override
  Future<ExpenseQueryResult> queryExpenses(
    String spaceId,
    ExpenseFilter filter, {
    Expense? before,
    required bool includeTotals,
  }) => _queryCashFlow(
    'query_expenses',
    spaceId,
    filter,
    before: before,
    includeTotals: includeTotals,
  );

  Future<ExpenseQueryResult> _queryCashFlow(
    String rpc,
    String spaceId,
    ExpenseFilter filter, {
    Expense? before,
    required bool includeTotals,
  }) async {
    final result = Map<String, dynamic>.from(
      await _client.rpc(
        rpc,
        params: {
          'p_space_id': spaceId,
          ...filter.params,
          'p_before_date': before?.date,
          'p_before_id': before?.id,
          'p_include_totals': includeTotals,
        },
      ) as Map,
    );
    final rows = (result['items'] as List)
        .map((e) => Expense.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    return ExpenseQueryResult(
      ExpensePage(rows.take(25).toList(), rows.length > 25),
      (result['totals'] as List)
          .map(
            (e) => ExpenseTotal.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .toList(),
    );
  }

  @override
  final ExpenseDraftStore expenseDrafts = LocalExpenseDraftStore();

  @override
  Future<String> createExpense(PendingExpense draft) async =>
      await _client.rpc('create_expense', params: draft.params) as String;

  @override
  Future<String> editExpense(PendingExpense draft) async =>
      await _client.rpc('edit_expense', params: draft.params) as String;

  @override
  Future<WalletExpenseBalance> loadExpenseBalance(String walletId) async =>
      WalletExpenseBalance.fromJson(
        Map<String, dynamic>.from(
          await _client.rpc(
            'wallet_expense_balance',
            params: {'p_wallet_id': walletId},
          ) as Map,
        ),
      );

  @override
  Future<ExpensePage> loadExpenses(String spaceId, {Expense? before}) async {
    var query = _client
        .from('expenses')
        .select(
          'id,wallet_id,category_id,revision,expense_date,amount_minor::text,currency,currency_scale,wallet_name,category_path,comment,transfer_id',
        )
        .eq('space_id', spaceId);
    if (before != null) {
      parseExpenseDate(before.date);
      if (!RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(before.id)) {
        throw const FormatException('Неверный указатель страницы.');
      }
      query = query.or(
        'expense_date.lt.${before.date},and(expense_date.eq.${before.date},id.lt.${before.id})',
      );
    }
    final rows = await query
        .order('expense_date', ascending: false)
        .order('id', ascending: false)
        .limit(26);
    return ExpensePage(
      rows.take(25).map(Expense.fromJson).toList(),
      rows.length > 25,
    );
  }

  static const _categoryColumns =
      'id,space_id,kind,name,parent_id,is_archived,icon_id';
  @override
  Future<List<FinanceCategory>> loadCategories(
    String spaceId,
    CategoryKind kind,
  ) async {
    List<Map<String, dynamic>> rows;
    try {
      rows = await _client
          .from('categories')
          .select('$_categoryColumns,sort_order,revision')
          .eq('space_id', spaceId)
          .eq('kind', kind.value)
          .order('sort_order')
          .order('created_at')
          .order('id');
      _hasCategoryRevision = rows.isEmpty || rows.first.containsKey('revision');
    } on PostgrestException catch (error) {
      // Keep the installed catalog order while migration 016 is pending.
      if (error.code != '42703' && error.code != 'PGRST204') rethrow;
      _hasCategoryRevision = false;
      try {
        rows = await _client
            .from('categories')
            .select('$_categoryColumns,sort_order')
            .eq('space_id', spaceId)
            .eq('kind', kind.value)
            .order('sort_order')
            .order('created_at')
            .order('id');
      } on PostgrestException catch (legacyError) {
        if (legacyError.code != '42703' && legacyError.code != 'PGRST204') {
          rethrow;
        }
        rows = await _client
            .from('categories')
            .select(_categoryColumns)
            .eq('space_id', spaceId)
            .eq('kind', kind.value)
            .order('created_at')
            .order('id');
      }
    }
    return rows.map(FinanceCategory.fromJson).toList();
  }

  @override
  Future<FinanceCategory> createCategory(
    String spaceId,
    CategoryKind kind,
    String name,
    String? parentId, {
    String iconId = 'category',
  }) async {
    if (_hasBackupSchema) {
      return FinanceCategory.fromJson(
        await _backupWrite('categories', 'create', null, null, {
          'space_id': spaceId,
          'kind': kind.value,
          'name': name,
          'icon_id': iconId,
          'parent_id': parentId,
        }),
      );
    }
    final row = await _client
        .from('categories')
        .insert({
          'space_id': spaceId,
          'kind': kind.value,
          'name': name,
          'icon_id': iconId,
          'parent_id': parentId,
        })
        .select(
          _hasCategoryRevision
              ? '$_categoryColumns,sort_order,revision'
              : _categoryColumns,
        )
        .single();
    return FinanceCategory.fromJson(row);
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
    if (_hasBackupSchema) {
      return FinanceCategory.fromJson(
        await _backupWrite(
          'categories',
          'update',
          previous.id,
          previous.revision,
          {
            'name': ?name,
            'icon_id': ?iconId,
            'is_archived': ?archived,
            if (changeParent) 'parent_id': parentId,
          },
        ),
      );
    }
    var query = _client
        .from('categories')
        .update({
          'name': ?name,
          'icon_id': ?iconId,
          'is_archived': ?archived,
          if (changeParent) 'parent_id': parentId,
        })
        .eq('id', previous.id)
        .eq('space_id', previous.spaceId)
        .eq('kind', previous.kind.value)
        .eq('name', previous.name)
        .eq('is_archived', previous.isArchived)
        .eq('icon_id', previous.iconId);
    if (previous.revision != null) {
      query = query.eq('revision', previous.revision!);
    }
    query = previous.parentId == null
        ? query.isFilter('parent_id', null)
        : query.eq('parent_id', previous.parentId!);
    final row = await query
        .select(
          previous.revision == null
              ? _categoryColumns
              : '$_categoryColumns,sort_order,revision',
        )
        .single();
    return FinanceCategory.fromJson({'sort_order': previous.sortOrder, ...row});
  }

  @override
  Future<BigInt?> loadOpeningBalance(String walletId) async {
    Map<String, dynamic>? row;
    try {
      row = await _client
          .from('wallet_opening_balances')
          .select('amount_minor::text,revision')
          .eq('wallet_id', walletId)
          .maybeSingle();
      _hasOpeningRevision = true;
    } on PostgrestException catch (error) {
      if (error.code != '42703') rethrow;
      row = await _client
          .from('wallet_opening_balances')
          .select('amount_minor::text')
          .eq('wallet_id', walletId)
          .maybeSingle();
    }
    if (row?['revision'] != null) {
      _hasBackupSchema = true;
      _openingRevisions[walletId] = row!['revision'] as String;
    }
    return row == null ? null : minorFromJson(row['amount_minor']);
  }

  @override
  Future<BigInt> saveOpeningBalance(
    String walletId,
    BigInt amount, {
    required BigInt? previous,
  }) async {
    final text = checkedMinor(amount).toString();
    if (_hasBackupSchema) {
      final row = await _backupWrite(
        'wallet_opening_balances',
        previous == null ? 'create' : 'update',
        walletId,
        _openingRevisions[walletId],
        {'amount_minor': text},
      );
      _openingRevisions[walletId] = row['revision'] as String;
      return minorFromJson(row['amount_minor']);
    }
    // Separate INSERT/PATCH: UPSERT also updates wallet_id, which is deliberately
    // not included in the existing column UPDATE grant.
    late final Map<String, dynamic> row;
    if (previous == null) {
      row = await _client
          .from('wallet_opening_balances')
          .insert({'wallet_id': walletId, 'amount_minor': text})
          .select(
            _hasOpeningRevision
                ? 'amount_minor::text,revision'
                : 'amount_minor::text',
          )
          .single();
    } else {
      var query = _client
          .from('wallet_opening_balances')
          .update({'amount_minor': text})
          .eq('wallet_id', walletId)
          .eq('amount_minor', checkedMinor(previous).toString());
      if (_openingRevisions[walletId] != null) {
        query = query.eq('revision', _openingRevisions[walletId]!);
      }
      row = await query
          .select(
            _hasOpeningRevision
                ? 'amount_minor::text,revision'
                : 'amount_minor::text',
          )
          .single();
    }
    if (row['revision'] != null) {
      _openingRevisions[walletId] = row['revision'] as String;
    }
    return minorFromJson(row['amount_minor']);
  }

  @override
  Future<List<FinanceSpace>> loadSpaces() async {
    // RLS decides visibility; filtering by owner would hide a manager's spaces.
    final rows = await _client
        .from('spaces')
        .select('id,owner_user_id,name,kind')
        .order('created_at')
        .order('id');
    return rows.map(FinanceSpace.fromJson).toList();
  }

  @override
  Future<List<Wallet>> loadWallets(String spaceId) async {
    const columns =
        'id,space_id,name,wallet_group,currency,currency_scale,icon_id,sort_order,is_archived';
    List<Map<String, dynamic>> rows;
    try {
      rows = await _client
          .from('wallets')
          .select('$columns,revision')
          .eq('space_id', spaceId)
          .order('sort_order')
          .order('created_at')
          .order('id');
      if (rows.any((row) => row['revision'] != null)) _hasBackupSchema = true;
    } on PostgrestException catch (error) {
      if (error.code != '42703') rethrow;
      rows = await _client
          .from('wallets')
          .select(columns)
          .eq('space_id', spaceId)
          .order('sort_order')
          .order('created_at')
          .order('id');
    }
    return rows.map(Wallet.fromJson).toList();
  }

  @override
  Future<void> createWallet({
    required String spaceId,
    required String name,
    required WalletGroup group,
    required String currency,
    String? iconId,
  }) async {
    if (_hasBackupSchema) {
      await _backupWrite('wallets', 'create', null, null, {
        'space_id': spaceId,
        'name': name,
        'wallet_group': group.value,
        'currency': currency,
        'currency_scale': 2,
        'icon_id': ?iconId,
      });
      return;
    }
    await _client.from('wallets').insert({
      'space_id': spaceId,
      'name': name,
      'wallet_group': group.value,
      'currency': currency,
      'currency_scale': 2,
      'icon_id': ?iconId,
    });
  }

  Future<Map<String, dynamic>> _backupWrite(
    String table,
    String action,
    String? id,
    String? expected,
    Map<String, dynamic> data,
  ) async => Map<String, dynamic>.from(
    await _client.rpc(
      'backup_write',
      params: {
        'p_request': newExpenseRequestId(),
        'p_table': table,
        'p_action': action,
        'p_id': id,
        'p_expected': expected,
        'p_data': data,
      },
    ) as Map,
  );
}

String financeError(Object error) {
  if (error is PostgrestException) {
    if (error.code == 'PGRST202') {
      return 'Серверная функция недоступна. Проверьте установку миграций и обновите схему.';
    }
    if (error.code == 'P1018') {
      return 'Нужна готовая резервная копия текущих данных. Проверьте сервер резервирования, обновите список и повторите действие.';
    }
    if (error.code == 'P1003') {
      return 'Данные изменились в другом окне. Обновите список и выберите записи заново.';
    }
    if (error.code == 'P1011') {
      return 'Выберите всю удаляемую ветку. Для восстановления сначала восстановите архивных родителей.';
    }
    if (error.code == 'P1012') {
      return 'Назначьте активную замену того же типа и пространства вне удаляемой ветки.';
    }
    if (error.code == 'P1005') {
      return 'Комиссию можно изменить только через связанный перевод.';
    }
    if (error.code == '42501') {
      return 'Недостаточно прав. Обновите список пространств или обратитесь к владельцу.';
    }
    if (error.code == '23503') {
      return 'Пространство больше недоступно. Обновите список пространств.';
    }
    if (error.code == '23514') {
      return 'Проверьте название, группу и валюту кошелька.';
    }
    if (error.code == 'PGRST301' || error.code == 'PGRST303') {
      return 'Сессия истекла. Войдите в приложение снова.';
    }
  }
  return 'Не удалось выполнить запрос. Проверьте подключение и повторите попытку.';
}
