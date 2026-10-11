import 'package:flutter/material.dart';

import 'category.dart';
import 'category_tree.dart';
import 'wallet_icons.dart';

class CategoryBulkDialog extends StatefulWidget {
  const CategoryBulkDialog({
    required this.action,
    required this.selected,
    required this.tree,
    this.usage = const [],
    super.key,
  });
  final String action;
  final List<FinanceCategory> selected;
  final CategoryTree tree;
  final List<Map<String, dynamic>> usage;
  @override
  State<CategoryBulkDialog> createState() => _CategoryBulkDialogState();
}

class _CategoryBulkDialogState extends State<CategoryBulkDialog> {
  final _replacements = <String, String>{};
  @override
  Widget build(BuildContext context) {
    final ids = widget.selected.map((c) => c.id).toSet();
    final used = widget.usage
        .where(
          (u) =>
              (u['expenses'] as num) +
                  (u['incomes'] as num) +
                  (u['transfers'] as num) >
              0,
        )
        .toList();
    final choices = widget.tree.items
        .where((c) => !ids.contains(c.id) && !widget.tree.archived(c))
        .toList();
    return AlertDialog(
      title: Text(
        '${switch (widget.action) {
          'delete' => 'Удалить',
          'archive' => 'Архивировать',
          _ => 'Восстановить',
        }} категории: ${widget.selected.length}?',
      ),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Включены все выбранные категории и вложенные пункты. Финансовые операции, суммы, валюты и кошельки сохранятся.',
              ),
              const SizedBox(height: 12),
              for (final c in widget.selected) Text('• ${widget.tree.path(c)}'),
              for (final u in used) ...[
                const SizedBox(height: 16),
                Text(
                  'Замена: ${widget.tree.path(widget.tree.byId(u['id'] as String)!)} · расходы ${u['expenses']}, доходы ${u['incomes']}, комиссии переводов ${u['transfers']}',
                ),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  itemHeight: null,
                  decoration: const InputDecoration(
                    labelText: 'Категория для переноса связей',
                  ),
                  items: [
                    for (final c in choices)
                      DropdownMenuItem(
                        value: c.id,
                        child: CategoryLabel(c.iconId, widget.tree.path(c)),
                      ),
                  ],
                  onChanged: (id) =>
                      setState(() => _replacements[u['id'] as String] = id!),
                ),
                if (choices.isEmpty)
                  const Text(
                    'Нет активной замены вне удаляемой ветки. Создайте её перед удалением.',
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: used.every((u) => _replacements.containsKey(u['id']))
              ? () => Navigator.pop(context, _replacements)
              : null,
          child: Text(
            widget.action == 'delete'
                ? 'Удалить'
                : widget.action == 'archive'
                ? 'Архивировать'
                : 'Восстановить',
          ),
        ),
      ],
    );
  }
}
