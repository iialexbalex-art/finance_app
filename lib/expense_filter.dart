import 'expense.dart';
import 'money.dart';

class ExpenseFilter {
  const ExpenseFilter({
    this.walletIds = const [],
    this.categoryIds = const [],
    this.from,
    this.to,
  });
  final List<String> walletIds, categoryIds;
  final String? from, to;
  Map<String, dynamic> get params => {
    'p_wallet_ids': walletIds,
    'p_category_ids': categoryIds,
    'p_from': from,
    'p_to': to,
  };
}

class ExpenseTotal {
  const ExpenseTotal(this.currency, this.scale, this.amount);
  final String currency;
  final int scale;
  final BigInt amount;
  factory ExpenseTotal.fromJson(Map<String, dynamic> row) => ExpenseTotal(
    row['currency'] as String,
    row['currency_scale'] as int,
    aggregateFromJson(row['amount_minor']),
  );
}

class ExpenseQueryResult {
  const ExpenseQueryResult(this.page, this.totals);
  final ExpensePage page;
  final List<ExpenseTotal> totals;
}
