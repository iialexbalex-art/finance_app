import 'package:flutter/material.dart';

import 'category.dart';
import 'category_tree.dart';
import 'expense.dart';
import 'expense_filter.dart';
import 'finance_repository.dart';
import 'wallet_icons.dart';

class ExpenseFiltersBar extends StatelessWidget {
  const ExpenseFiltersBar({
    required this.filter,
    required this.wallets,
    required this.categories,
    required this.onChanged,
    this.enabled = true,
    this.showCategories = true,
    this.onReset,
    super.key,
  });
  final ExpenseFilter filter;
  final List<Wallet> wallets;
  final List<FinanceCategory> categories;
  final ValueChanged<ExpenseFilter> onChanged;
  final bool enabled;
  final bool showCategories;
  final VoidCallback? onReset;

  Future<void> _choose(BuildContext context, bool wallet) async {
    final tree = CategoryTree(categories);
    final choices = <String, String>{
      if (wallet)
        for (final w in wallets) w.id: '${w.name} (${w.currency})'
      else
        for (final c in categories)
          c.id: '${tree.path(c)}${tree.archived(c) ? ' (архив)' : ''}',
    };
    final selected = (wallet ? filter.walletIds : filter.categoryIds).toSet();
    var search = '';
    final result = await showDialog<List<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(wallet ? 'Кошельки' : 'Категории'),
          content: SizedBox(
            width: 480,
            height: 360,
            child: ListView(
              children: [
                TextField(
                  decoration: const InputDecoration(
                    labelText: 'Поиск',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (value) =>
                      update(() => search = value.toLowerCase()),
                ),
                if (!wallet)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'Выбор категории включает всех потомков, в том числе архивных.',
                    ),
                  ),
                for (final entry in choices.entries.where(
                  (e) => e.value.toLowerCase().contains(search),
                ))
                  CheckboxListTile(
                    secondary: wallet
                        ? WalletMark(
                            wallets
                                .where((w) => w.id == entry.key)
                                .firstOrNull
                                ?.displayIconId,
                          )
                        : CategoryMark(
                            categories
                                .where((c) => c.id == entry.key)
                                .firstOrNull
                                ?.iconId,
                          ),
                    contentPadding: EdgeInsets.zero,
                    title: Text(entry.value),
                    value: selected.contains(entry.key),
                    onChanged: (value) => update(() {
                      if (value!) {
                        selected.add(entry.key);
                      } else {
                        selected.remove(entry.key);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, selected.toList()),
              child: const Text('Применить'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !context.mounted) return;
    onChanged(
      ExpenseFilter(
        walletIds: wallet ? result : filter.walletIds,
        categoryIds: wallet ? filter.categoryIds : result,
        from: filter.from,
        to: filter.to,
      ),
    );
  }

  Future<void> _period(BuildContext context) async {
    final result = await showDialog<ExpenseFilter>(
      context: context,
      builder: (_) => _PeriodDialog(filter: filter),
    );
    if (result != null && context.mounted) onChanged(result);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                iconSize: 18,
              ),
              onPressed: enabled ? () => _choose(context, true) : null,
              icon: const Icon(Icons.account_balance_wallet_outlined),
              label: Text(
                'Кошельки${filter.walletIds.isEmpty ? '' : ' (${filter.walletIds.length})'}',
              ),
            ),
            if (showCategories)
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  iconSize: 18,
                ),
                onPressed: enabled ? () => _choose(context, false) : null,
                icon: const Icon(Icons.category_outlined),
                label: Text(
                  'Категории${filter.categoryIds.isEmpty ? '' : ' (${filter.categoryIds.length})'}',
                ),
              ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                iconSize: 18,
              ),
              onPressed: enabled ? () => _period(context) : null,
              icon: const Icon(Icons.date_range_outlined),
              label: const Text('Период'),
            ),
            TextButton.icon(
              onPressed: enabled
                  ? () {
                      onReset?.call();
                      onChanged(const ExpenseFilter());
                    }
                  : null,
              icon: const Icon(Icons.filter_alt_off_outlined),
              label: const Text('Сбросить фильтры'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(switch ((filter.from, filter.to)) {
          (null, null) => 'Всё время',
          (final from?, null) =>
            'С ${russianExpenseDate(parseExpenseDate(from))}',
          (null, final to?) => 'По ${russianExpenseDate(parseExpenseDate(to))}',
          (final from?, final to?) =>
            '${russianExpenseDate(parseExpenseDate(from))} — ${russianExpenseDate(parseExpenseDate(to))}',
        }),
      ],
    ),
  );
}

class _PeriodDialog extends StatefulWidget {
  const _PeriodDialog({required this.filter});
  final ExpenseFilter filter;
  @override
  State<_PeriodDialog> createState() => _PeriodDialogState();
}

class _PeriodDialogState extends State<_PeriodDialog> {
  final _form = GlobalKey<FormState>();
  late final _from = TextEditingController(
    text: russianExpenseDate(
      widget.filter.from == null
          ? DateTime.now()
          : parseExpenseDate(widget.filter.from!),
    ),
  );
  late final _to = TextEditingController(
    text: russianExpenseDate(
      widget.filter.to == null
          ? DateTime.now()
          : parseExpenseDate(widget.filter.to!),
    ),
  );
  String? _error;
  void _finish(DateTime? from, DateTime? to) => Navigator.pop(
    context,
    ExpenseFilter(
      walletIds: widget.filter.walletIds,
      categoryIds: widget.filter.categoryIds,
      from: from == null ? null : expenseDate(from),
      to: to == null ? null : expenseDate(to),
    ),
  );
  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return AlertDialog(
      title: const Text('Период'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: () => _finish(now, now),
                      child: const Text('Сегодня'),
                    ),
                    TextButton(
                      onPressed: () => _finish(
                        DateTime(now.year, now.month),
                        DateTime(now.year, now.month + 1, 0),
                      ),
                      child: const Text('Текущий месяц'),
                    ),
                    TextButton(
                      onPressed: () => _finish(
                        DateTime(now.year, now.month - 1),
                        DateTime(now.year, now.month, 0),
                      ),
                      child: const Text('Предыдущий месяц'),
                    ),
                    TextButton(
                      onPressed: () => _finish(null, null),
                      child: const Text('Всё время'),
                    ),
                  ],
                ),
                const Text('Произвольные даты включительно'),
                for (final entry in {_from: 'С', _to: 'По'}.entries)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: TextFormField(
                      controller: entry.key,
                      decoration: InputDecoration(
                        labelText: entry.value,
                        hintText: '30 сентября 2026',
                        suffixIcon: IconButton(
                          tooltip: 'Выбрать дату',
                          icon: const Icon(Icons.calendar_month),
                          onPressed: () async {
                            DateTime initial;
                            try {
                              initial = parseRussianExpenseDate(entry.key.text);
                            } catch (_) {
                              initial = now;
                            }
                            final date = await showDatePicker(
                              context: context,
                              initialDate: initial,
                              firstDate: DateTime(1),
                              lastDate: DateTime(9999, 12, 31),
                            );
                            if (date != null) {
                              entry.key.text = russianExpenseDate(date);
                            }
                          },
                        ),
                      ),
                      validator: (value) {
                        try {
                          parseRussianExpenseDate(value ?? '');
                          return null;
                        } on FormatException catch (e) {
                          return e.message;
                        }
                      },
                    ),
                  ),
                if (_error != null) Text(_error!),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () {
            if (!_form.currentState!.validate()) return;
            final from = parseRussianExpenseDate(_from.text),
                to = parseRussianExpenseDate(_to.text);
            if (from.isAfter(to)) {
              setState(
                () => _error = 'Начало периода должно быть не позже окончания.',
              );
              return;
            }
            _finish(from, to);
          },
          child: const Text('Применить'),
        ),
      ],
    );
  }
}
