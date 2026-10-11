import 'package:flutter/material.dart';

import 'category.dart';
import 'category_tree.dart';
import 'categories_screen.dart' show categoryError;
import 'wallet_icons.dart';

class CategoryParentDialog extends StatefulWidget {
  const CategoryParentDialog({
    required this.moving,
    required this.tree,
    required this.save,
    super.key,
  });
  final FinanceCategory moving;
  final CategoryTree tree;
  final Future<void> Function(String?) save;
  @override
  State<CategoryParentDialog> createState() => _CategoryParentDialogState();
}

class _CategoryParentDialogState extends State<CategoryParentDialog> {
  String? _selected;
  String _query = '';
  bool _saving = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _selected = widget.moving.parentId;
  }

  Future<void> _save() async {
    if (_saving) return;
    final changed = _selected != widget.moving.parentId;
    final validation = changed
        ? widget.tree.parentError(widget.moving, _selected)
        : null;
    if (validation != null) {
      setState(() => _error = validation);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.save(_selected);
      if (mounted) {
        Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error is StateError
              ? error.message.toString()
              : categoryError(error);
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tree = widget.tree;
    final moving = widget.moving;
    final choices = tree.parents(moving.spaceId, moving.kind, moving: moving);
    final current = tree.byId(moving.parentId);
    final unavailable =
        moving.parentId != null && !choices.any((c) => c.id == moving.parentId);
    final query = _query.toLowerCase().replaceAll('ё', 'е').trim();
    return PopScope(
      canPop: !_saving,
      child: Dialog(
        insetPadding: const EdgeInsets.all(12),
        child: SizedBox(
          width: 620,
          height: (MediaQuery.sizeOf(context).height - 24).clamp(260.0, 650.0),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Добавить в родительскую категорию',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  tree.path(moving),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                TextField(
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: 'Поиск родителя',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (value) => setState(() => _query = value),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Только совместимые родители. Переносится вся ветвь; максимум три уровня.',
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView(
                    children: [
                      _option(
                        null,
                        'Без родительской категории',
                        enabled: tree.height(moving) <= 3,
                      ),
                      if (unavailable)
                        _option(
                          moving.parentId,
                          '${current == null ? 'Текущий родитель' : tree.path(current)} (в архиве или недоступен)',
                          enabled: false,
                          category: current,
                        ),
                      for (final item in choices)
                        if (tree
                            .path(item)
                            .toLowerCase()
                            .replaceAll('ё', 'е')
                            .contains(query))
                          _option(item.id, tree.path(item), category: item),
                      if (choices
                          .where(
                            (c) => tree
                                .path(c)
                                .toLowerCase()
                                .replaceAll('ё', 'е')
                                .contains(query),
                          )
                          .isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('Подходящие родители не найдены'),
                        ),
                    ],
                  ),
                ),
                if (_error != null)
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton(
                      onPressed: _saving ? null : _save,
                      child: Text(_saving ? 'Сохраняем…' : 'Сохранить'),
                    ),
                    TextButton(
                      onPressed: _saving ? null : () => Navigator.pop(context),
                      child: const Text('Отмена'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _option(
    String? id,
    String label, {
    bool enabled = true,
    FinanceCategory? category,
  }) {
    final selected = _selected == id;
    final current = widget.moving.parentId == id;
    return Semantics(
      selected: selected,
      child: ListTile(
        key: ValueKey('parent-choice:${id ?? 'root'}'),
        enabled: enabled && !_saving,
        leading: category == null
            ? null
            : CategoryMark(category.iconId, size: 40),
        title: Text(label),
        subtitle: current ? const Text('Текущий родитель') : null,
        trailing: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        ),
        onTap: enabled && !_saving
            ? () => setState(() => _selected = id)
            : null,
      ),
    );
  }
}
