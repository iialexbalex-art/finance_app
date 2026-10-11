import 'dart:math';

import 'money.dart';

String newExpenseRequestId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

String expenseDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

DateTime parseExpenseDate(String text) {
  if (!RegExp(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}$').hasMatch(text)) {
    throw const FormatException('Дата: ГГГГ-ММ-ДД.');
  }
  final parts = text.split('-').map(int.parse).toList();
  // UTC is a neutral component container here, never an instant conversion.
  // This also validates dates skipped by historical local timezone transitions.
  final date = DateTime.utc(parts[0], parts[1], parts[2]);
  if (parts[0] < 1 || parts[0] > 9999 || expenseDate(date) != text) {
    throw const FormatException('Укажите существующую дату.');
  }
  return date;
}

const _months = [
  'января',
  'февраля',
  'марта',
  'апреля',
  'мая',
  'июня',
  'июля',
  'августа',
  'сентября',
  'октября',
  'ноября',
  'декабря',
];

String russianExpenseDate(DateTime date) =>
    '${date.day} ${_months[date.month - 1]} ${date.year}';

/// Calendar components only: never convert a stored date to/from UTC.
DateTime parseRussianExpenseDate(String text) {
  final match = RegExp(r'^(\d{1,2})\s+([а-я]+)\s+(\d{1,4})$')
      .firstMatch(text.trim().toLowerCase());
  if (match == null || !_months.contains(match[2])) {
    throw const FormatException('Введите дату, например: 30 сентября 2026.');
  }
  return parseExpenseDate(
    '${match[3]!.padLeft(4, '0')}-'
    '${(_months.indexOf(match[2]!) + 1).toString().padLeft(2, '0')}-'
    '${match[1]!.padLeft(2, '0')}',
  );
}

class Expense {
  Expense({
    required this.id,
    required this.date,
    required this.amount,
    required this.currency,
    required this.scale,
    required this.walletName,
    required this.categoryPath,
    required this.comment,
    this.walletId = '',
    this.categoryId = '',
    this.revision = '',
    this.transferId,
  });
  final String id, date, currency, walletName, categoryPath, comment;
  final int scale;
  final String walletId, categoryId, revision;
  final BigInt amount;
  final String? transferId;
  factory Expense.fromJson(Map<String, dynamic> row) => Expense(
    id: row['id'] as String,
    date: row['expense_date'] as String,
    amount: minorFromJson(row['amount_minor']),
    currency: row['currency'] as String,
    scale: row['currency_scale'] as int,
    walletName: row['wallet_name'] as String,
    categoryPath: row['category_path'] as String,
    comment: row['comment'] as String,
    walletId: row['wallet_id'] as String,
    categoryId: row['category_id'] as String,
    revision: row['revision'] as String,
    transferId: row['transfer_id'] as String?,
  );
}

class ExpensePage {
  ExpensePage(this.items, this.hasMore);
  final List<Expense> items;
  final bool hasMore;
}

class WalletExpenseBalance {
  WalletExpenseBalance({
    required this.opening,
    required this.spent,
    required this.current,
  });
  final BigInt? opening;
  final BigInt spent, current;
  factory WalletExpenseBalance.fromJson(Map<String, dynamic> row) =>
      WalletExpenseBalance(
        opening: row['opening_minor'] == null
            ? null
            : minorFromJson(row['opening_minor']),
        spent: aggregateFromJson(row['expense_minor']),
        current: aggregateFromJson(row['current_minor']),
      );
}

/// Immutable submitted payload; retries and browser reloads reuse the same ID.
class PendingExpense {
  PendingExpense({
    required this.requestId,
    required this.spaceId,
    required this.walletId,
    required this.categoryId,
    required this.amountMinor,
    required this.date,
    required this.comment,
    required this.currency,
    required this.scale,
    required this.walletName,
    required this.categoryPath,
    this.expenseId,
    this.expectedRevision,
    this.originalCategoryId,
    this.originalCategoryPath,
  });
  final String requestId,
      spaceId,
      walletId,
      categoryId,
      amountMinor,
      date,
      comment,
      currency,
      walletName,
      categoryPath;
  final int scale;
  final String? expenseId,
      expectedRevision,
      originalCategoryId,
      originalCategoryPath;
  bool get isEdit => expenseId != null;
  Map<String, dynamic> get params => {
    'p_request_id': requestId,
    'p_space_id': spaceId,
    'p_wallet_id': walletId,
    'p_category_id': categoryId,
    'p_amount_minor': amountMinor,
    'p_expense_date': date,
    'p_comment': comment,
    if (isEdit) ...{
      'p_expense_id': expenseId,
      'p_expected_revision': expectedRevision,
      'p_currency': currency,
      'p_currency_scale': scale,
    },
  };
  Map<String, dynamic> toJson() => {
    ...params,
    'currency': currency,
    'scale': scale,
    'wallet_name': walletName,
    'category_path': categoryPath,
    'original_category_id': originalCategoryId,
    'original_category_path': originalCategoryPath,
  };
  factory PendingExpense.fromJson(Map<String, dynamic> row) => PendingExpense(
    requestId: row['p_request_id'] as String,
    spaceId: row['p_space_id'] as String,
    walletId: row['p_wallet_id'] as String,
    categoryId: row['p_category_id'] as String,
    amountMinor: row['p_amount_minor'] as String,
    date: row['p_expense_date'] as String,
    comment: row['p_comment'] as String,
    currency: row['currency'] as String,
    scale: row['scale'] as int,
    walletName: row['wallet_name'] as String,
    categoryPath: row['category_path'] as String,
    expenseId: row['p_expense_id'] as String?,
    expectedRevision: row['p_expected_revision'] as String?,
    originalCategoryId: row['original_category_id'] as String?,
    originalCategoryPath: row['original_category_path'] as String?,
  );
}
