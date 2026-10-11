import 'package:flutter/material.dart';

import 'expense.dart';
import 'money.dart';

/// Money stays integer throughout, including currencies with different scales.
Map<String, (int, BigInt)> deletionTotals(List<Expense> rows) {
  final result = <String, (int, BigInt)>{};
  for (final row in rows) {
    final prior = result[row.currency];
    if (prior == null) {
      result[row.currency] = (row.scale, row.amount);
      continue;
    }
    final scale = prior.$1 > row.scale ? prior.$1 : row.scale;
    result[row.currency] = (
      scale,
      prior.$2 * BigInt.from(10).pow(scale - prior.$1) +
          row.amount * BigInt.from(10).pow(scale - row.scale),
    );
  }
  return result;
}

class CashflowDeleteDialog extends StatelessWidget {
  const CashflowDeleteDialog({
    required this.rows,
    required this.income,
    super.key,
  });
  final List<Expense> rows;
  final bool income;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Удалить ${income ? 'доходы' : 'расходы'}: ${rows.length}?'),
    content: SizedBox(
      width: 640,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final entry in deletionTotals(rows).entries)
              Text(
                '${formatExactMoney(entry.value.$2, scale: entry.value.$1)} ${entry.key}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            const SizedBox(height: 12),
            const Text(
              'Операции будут удалены из истории и расчётов. Категории и кошельки сохранятся.',
            ),
            const SizedBox(height: 12),
            for (final e in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '${russianExpenseDate(parseExpenseDate(e.date))} · ${e.walletName}\n${e.categoryPath} · ${formatMoney(e.amount, scale: e.scale)} ${e.currency}${e.comment.isEmpty ? '' : '\n${e.comment}'}',
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, true),
        child: const Text('Удалить'),
      ),
    ],
  );
}
