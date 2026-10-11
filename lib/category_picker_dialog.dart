import 'package:flutter/material.dart';

import 'category.dart';
import 'category_tree.dart';
import 'wallet_icons.dart';

/// Search uses full paths, so equal leaf names in different branches stay distinct.
class CategoryPickerDialog extends StatefulWidget {
  const CategoryPickerDialog({
    required this.categories,
    this.selected,
    super.key,
  });
  final List<FinanceCategory> categories;
  final String? selected;
  @override
  State<CategoryPickerDialog> createState() => _CategoryPickerDialogState();
}

class _CategoryPickerDialogState extends State<CategoryPickerDialog> {
  String _query = '';
  final _expanded = <String>{};
  String _normalize(String text) => text.toLowerCase().replaceAll('ё', 'е');
  @override
  Widget build(BuildContext context) {
    final tree = CategoryTree(widget.categories);
    final searching = _query.trim().isNotEmpty;
    final matches = widget.categories
        .where(
          (c) => _normalize(tree.path(c)).contains(_normalize(_query.trim())),
        )
        .toList();
    final included = <String>{};
    for (final c in matches) {
      included.addAll(tree.ancestry(c)?.map((a) => a.id) ?? [c.id]);
    }
    final rows = <FinanceCategory>[];
    final visited = <String>{};
    void visit(FinanceCategory c) {
      if (!visited.add(c.id) || (searching && !included.contains(c.id))) return;
      rows.add(c);
      if (searching || _expanded.contains(c.id)) {
        for (final child in tree.children(c.id)) {
          visit(child);
        }
      }
    }

    for (final c in tree.ordered(
      widget.categories.where(
        (c) => c.parentId == null || tree.byId(c.parentId) == null,
      ),
    )) {
      visit(c);
    }
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800, maxHeight: 680),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Выбор категории',
                      style: TextStyle(fontSize: 22),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    tooltip: 'Закрыть',
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              TextField(
                decoration: const InputDecoration(
                  labelText: 'Поиск категории',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: LayoutBuilder(
                  builder: (context, constraints) => ListView(
                    shrinkWrap: true,
                    children: [
                      if (rows.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('Категории не найдены'),
                        ),
                      for (final c in rows)
                        Padding(
                          padding: EdgeInsets.only(
                            left:
                                (tree.depth(c) - 1) *
                                (constraints.maxWidth >= 720 ? 128 : 24.0),
                          ),
                          child: ListTile(
                            key: ValueKey('pick-category:${c.id}'),
                            leading: CategoryMark(c.iconId, size: 48),
                            title: Text(c.name),
                            selected: c.id == widget.selected,
                            onTap: () => Navigator.pop(context, c.id),
                            trailing: tree.children(c.id).isEmpty
                                ? null
                                : IconButton(
                                    tooltip: _expanded.contains(c.id)
                                        ? 'Свернуть ${c.name}'
                                        : 'Раскрыть ${c.name}',
                                    icon: Icon(
                                      _expanded.contains(c.id)
                                          ? Icons.remove
                                          : Icons.add,
                                    ),
                                    onPressed: () => setState(() {
                                      if (!_expanded.remove(c.id)) {
                                        _expanded.add(c.id);
                                      }
                                    }),
                                  ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
