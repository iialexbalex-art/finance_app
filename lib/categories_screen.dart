import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'category.dart';
import 'category_tree.dart';
import 'category_parent_dialog.dart';
import 'finance_repository.dart';
import 'wallet_icons.dart';
import 'expense.dart' show newExpenseRequestId;
import 'category_bulk_dialog.dart';

String categoryError(Object error) {
  if (error is PostgrestException) {
    if (error.code == '42703' || error.code == 'PGRST204') {
      return 'Обновите схему категорий: требуется миграция 011.';
    }
    if (error.code == 'PGRST205' || error.code == '42P01') {
      return 'Категории ещё не подключены к базе. Примените миграцию категорий и повторите загрузку.';
    }
    if (error.code == 'PGRST116') {
      return 'Категория изменена в другой сессии или доступ отозван. Обновите список.';
    }
    if (error.code == '23503' || error.code == '23514') {
      return 'Создание или перенос недоступны: не более трёх уровней, без циклов, в одном пространстве и типе. Родитель и его предки должны быть неархивными. Обновите список.';
    }
    if (error.code == '40001' || error.code == '40P01') {
      return 'Категории одновременно изменяются в другой сессии. Обновите список и повторите изменение.';
    }
  }
  return financeError(error);
}

class CategoriesScreen extends StatefulWidget {
  const CategoriesScreen({
    required this.space,
    required this.isOwner,
    required this.repository,
    this.expansionState,
    super.key,
  });
  final FinanceSpace space;
  final bool isOwner;
  final FinanceRepository repository;
  final Map<String, Set<String>>? expansionState;
  @override
  State<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends State<CategoriesScreen> {
  CategoryKind _kind = CategoryKind.expense;
  final Map<String, Set<String>> _localExpansion = {};
  @override
  Widget build(BuildContext context) {
    final kind = widget.isOwner ? _kind : CategoryKind.expense;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.isOwner)
          DefaultTabController(
            length: 2,
            initialIndex: CategoryKind.values.indexOf(kind),
            child: TabBar(
              onTap: (index) =>
                  setState(() => _kind = CategoryKind.values[index]),
              tabs: [
                for (final item in CategoryKind.values) Tab(text: item.label),
              ],
            ),
          )
        else
          const Text('Категории расходов. Управление доступно владельцу.'),
        const SizedBox(height: 16),
        // A different space, type or role destroys drafts and pending callbacks.
        _CategoryList(
          key: ValueKey('${widget.space.id}:${kind.value}:${widget.isOwner}'),
          space: widget.space,
          kind: kind,
          isOwner: widget.isOwner,
          repository: widget.repository,
          expanded: (widget.expansionState ?? _localExpansion).putIfAbsent(
            '${widget.space.id}:${kind.value}:${widget.isOwner}',
            () => <String>{},
          ),
        ),
      ],
    );
  }
}

enum _EditMode { create, rename, archive, activate }

enum _CategoryAction {
  edit,
  archive,
  activate,
  createChild,
  move,
  up,
  down,
  delete,
}

class _CategoryList extends StatefulWidget {
  const _CategoryList({
    required this.space,
    required this.kind,
    required this.isOwner,
    required this.repository,
    required this.expanded,
    super.key,
  });
  final FinanceSpace space;
  final CategoryKind kind;
  final bool isOwner;
  final FinanceRepository repository;
  final Set<String> expanded;
  @override
  State<_CategoryList> createState() => _CategoryListState();
}

class _CategoryListState extends State<_CategoryList> {
  List<FinanceCategory> _items = [];
  bool _loading = true;
  bool _saving = false;
  String? _loadError;
  String? _saveError;
  int _request = 0;
  _EditMode? _mode;
  FinanceCategory? _target;
  String? _editedParentId;
  String _iconId = 'category';
  final _name = TextEditingController();
  final _form = GlobalKey<FormState>();
  final Map<String, GlobalKey> _rowKeys = {};
  String? _highlightedId;
  Timer? _highlightTimer;
  String _search = '';
  final _searchController = TextEditingController();
  String _activity = 'Все';
  final _selected = <String>{};
  final _filterCollapsed = <String>{};
  bool _dropAfter = false;

  bool _isOpen(String id, bool filtering) =>
      filtering ? !_filterCollapsed.contains(id) : widget.expanded.contains(id);

  void _acceptRows(List<FinanceCategory> rows) {
    _items = rows;
    final ids = rows.map((c) => c.id).toSet();
    _selected.retainAll(ids);
    widget.expanded.retainAll(ids);
    _filterCollapsed.retainAll(ids);
    _rowKeys.removeWhere((id, _) => !ids.contains(id));
  }

  void _toggleBranch(FinanceCategory item, CategoryTree tree, bool filtering) {
    final branch = tree.subtree(item.id);
    final open = _isOpen(item.id, filtering);
    setState(() {
      if (open) {
        widget.expanded.removeAll(branch);
        if (filtering) _filterCollapsed.add(item.id);
      } else {
        widget.expanded.addAll(branch);
        _filterCollapsed.removeAll(branch);
      }
    });
  }

  void _selectBranch(FinanceCategory item, bool select) {
    final tree = CategoryTree(_items);
    final branch = tree.subtree(item.id);
    setState(() {
      if (select) {
        _selected.addAll(branch);
      } else {
        _selected.removeAll(branch);
      }
      for (final ancestor in tree.ancestry(item) ?? <FinanceCategory>[]) {
        if (!tree.subtree(ancestor.id).every(_selected.contains)) {
          _selected.remove(ancestor.id);
        }
      }
    });
  }

  bool _matchesFilter(FinanceCategory c, CategoryTree tree) =>
      (_activity == 'Все' ||
          (_activity == 'Активные' && !tree.archived(c)) ||
          (_activity == 'В архиве' && tree.archived(c))) &&
      tree
          .path(c)
          .toLowerCase()
          .replaceAll('ё', 'е')
          .contains(_search.trim().toLowerCase().replaceAll('ё', 'е'));

  Future<void> _bulk(String action, {FinanceCategory? single}) async {
    if (_saving || _mode != null || !widget.isOwner) return;
    final tree = CategoryTree(_items);
    final ids = single == null ? _selected.toSet() : tree.subtree(single.id);
    if (ids.isEmpty) return;
    // Deleting a selected parent always includes descendants, even when collapsed.
    if (action == 'delete') {
      for (final id in ids.toList()) {
        ids.addAll(tree.subtree(id));
      }
    }
    final snapshot = [..._items];
    final selected = _items.where((c) => ids.contains(c.id)).toList();
    setState(() => _saving = true);
    try {
      final usage = action == 'delete'
          ? await widget.repository.categoryDeletePlan(
              widget.space.id,
              widget.kind,
              ids.toList()..sort(),
              snapshot,
            )
          : <Map<String, dynamic>>[];
      if (!mounted) return;
      final replacements = await showDialog<Map<String, String>>(
        context: context,
        builder: (_) => CategoryBulkDialog(
          action: action,
          selected: selected,
          tree: tree,
          usage: usage,
        ),
      );
      if (replacements == null || !mounted) return;
      await widget.repository.mutateCategories(
        newExpenseRequestId(),
        widget.space.id,
        widget.kind,
        action,
        ids.toList()..sort(),
        snapshot,
        replacements: replacements,
      );
      final rows = await widget.repository.loadCategories(
        widget.space.id,
        widget.kind,
      );
      if (mounted) {
        setState(() {
          _acceptRows(rows);
          _selected.clear();
          _saveError = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _saveError = categoryError(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _reorder(
    FinanceCategory target,
    String sourceId, {
    bool after = false,
  }) async {
    if (_saving || _mode != null || !widget.isOwner) return;
    final tree = CategoryTree(_items);
    final source = tree.byId(sourceId);
    if (source == null ||
        source.parentId != target.parentId ||
        source.id == target.id) {
      return;
    }
    final siblings = tree
        .ordered(_items.where((c) => c.parentId == target.parentId))
        .map((c) => c.id)
        .toList();
    siblings.remove(sourceId);
    siblings.insert(siblings.indexOf(target.id) + (after ? 1 : 0), sourceId);
    final snapshot = [..._items];
    setState(() => _saving = true);
    try {
      await widget.repository.reorderCategories(
        newExpenseRequestId(),
        widget.space.id,
        widget.kind,
        target.parentId,
        siblings,
        snapshot,
      );
      final rows = await widget.repository.loadCategories(
        widget.space.id,
        widget.kind,
      );
      if (mounted) {
        setState(() {
          _acceptRows(rows);
          _saveError = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _saveError = categoryError(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _move(FinanceCategory item, int delta) {
    final siblings = CategoryTree(_items)
        .ordered(_items.where((c) => c.parentId == item.parentId));
    final index = siblings.indexWhere((c) => c.id == item.id) + delta;
    if (index >= 0 && index < siblings.length) {
      _reorder(siblings[index], item.id, after: delta > 0);
    }
  }

  void _reveal(FinanceCategory item) {
    final tree = CategoryTree(_items);
    widget.expanded.addAll(tree.subtree(item.id));
    widget.expanded.addAll(tree.ancestry(item)?.map((c) => c.id) ?? []);
    _highlightedId = item.id;
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _highlightedId = null);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final rowContext = _rowKeys[item.id]?.currentContext;
      if (rowContext != null) {
        Scrollable.ensureVisible(
          rowContext,
          alignment: .5,
          duration: const Duration(milliseconds: 250),
        );
      }
    });
  }

  void _acceptSaved(FinanceCategory saved, {bool reveal = false}) {
    final index = _items.indexWhere((item) => item.id == saved.id);
    if (index < 0) {
      _items = [..._items, saved];
    } else {
      _items = [..._items]..[index] = saved;
    }
    if (reveal) {
      _search = '';
      _searchController.clear();
      _activity = 'Все';
      _reveal(saved);
    }
  }

  Future<void> _chooseParent(FinanceCategory item) async {
    if (_saving || _mode != null || !widget.isOwner) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CategoryParentDialog(
        moving: item,
        tree: CategoryTree(_items),
        save: (parentId) async {
          if (!mounted || _saving) return;
          if (parentId == item.parentId) return;
          final error = CategoryTree(_items).parentError(item, parentId);
          if (error != null) throw StateError(error);
          final request = ++_request;
          setState(() => _saving = true);
          try {
            final saved = await widget.repository.editCategory(
              item,
              changeParent: true,
              parentId: parentId,
            );
            if (!mounted || request != _request) return;
            setState(() => _acceptSaved(saved, reveal: true));
          } finally {
            if (mounted && request == _request) setState(() => _saving = false);
          }
        },
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_saving) return;
    final request = ++_request;
    setState(() {
      _loading = true;
      _loadError = null;
      _mode = null;
      _saveError = null;
      _items = [];
      _selected.clear();
      _name.clear();
    });
    try {
      final rows = await widget.repository.loadCategories(
        widget.space.id,
        widget.kind,
      );
      if (!mounted || request != _request) return;
      setState(
        () => _acceptRows(
          rows
              .where(
                (c) => c.spaceId == widget.space.id && c.kind == widget.kind,
              )
              .toList(),
        ),
      );
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() => _loadError = categoryError(error));
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  void _edit(
    _EditMode mode, {
    FinanceCategory? target,
    FinanceCategory? parent,
  }) {
    if (_saving || !widget.isOwner) return;
    setState(() {
      _mode = mode;
      _target = target;
      _iconId = target?.iconId ?? 'category';
      _editedParentId = mode == _EditMode.create
          ? parent?.id
          : target?.parentId;
      _name.text = mode == _EditMode.rename ? target!.name : '';
      _saveError = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final formContext = _form.currentContext;
      if (formContext != null) {
        Scrollable.ensureVisible(
          formContext,
          duration: const Duration(milliseconds: 200),
        );
      }
    });
  }

  Future<void> _save() async {
    if (_saving || !widget.isOwner || _mode == null) return;
    if ((_mode == _EditMode.create || _mode == _EditMode.rename) &&
        !_form.currentState!.validate()) {
      return;
    }
    final parentChanged =
        _mode == _EditMode.create ||
        (_mode == _EditMode.rename && _editedParentId != _target!.parentId);
    if (parentChanged) {
      final error = CategoryTree(_items).parentError(
        _mode == _EditMode.create ? null : _target,
        _editedParentId,
        spaceId: widget.space.id,
        kind: widget.kind,
      );
      if (error != null) {
        setState(() => _saveError = error);
        return;
      }
    }
    final request = ++_request;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final saved = _mode == _EditMode.create
          ? await widget.repository.createCategory(
              widget.space.id,
              widget.kind,
              _name.text.trim(),
              _editedParentId,
              iconId: _iconId,
            )
          : await widget.repository.editCategory(
              _target!,
              name: _mode == _EditMode.rename ? _name.text.trim() : null,
              iconId: _mode == _EditMode.rename ? _iconId : null,
              archived: _mode == _EditMode.archive
                  ? true
                  : _mode == _EditMode.activate
                  ? false
                  : null,
              changeParent:
                  _mode == _EditMode.rename &&
                  _editedParentId != _target!.parentId,
              parentId: _editedParentId,
            );
      if (!mounted || request != _request) return;
      setState(() {
        _acceptSaved(saved, reveal: parentChanged);
        _mode = null;
        _name.clear();
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(
        () => _saveError =
            '${categoryError(error)} При потере ответа обновите список перед повтором: запись могла сохраниться.',
      );
    } finally {
      if (mounted && request == _request) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _request++;
    _highlightTimer?.cancel();
    _name.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Widget _parentField() {
    final target = _mode == _EditMode.rename ? _target : null;
    final tree = CategoryTree(_items);
    final choices = tree.parents(widget.space.id, widget.kind, moving: target);
    final oldParent = tree.byId(target?.parentId);
    // Keep an archived current parent visible, but never offer it as a new parent.
    final unavailableCurrent =
        target?.parentId != null &&
        !choices.any((item) => item.id == target!.parentId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey('parent:${target?.id ?? 'new'}'),
          initialValue: _editedParentId ?? '',
          isExpanded: true,
          itemHeight: null,
          decoration: const InputDecoration(
            labelText: 'Родительская категория',
            border: OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem(
              value: '',
              child: Text(
                'Без родительской категории',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (unavailableCurrent)
              DropdownMenuItem(
                value: target!.parentId,
                enabled: false,
                child: Text(
                  '${oldParent == null ? 'Текущий родитель' : tree.path(oldParent)} (в архиве или недоступен)',
                ),
              ),
            for (final item in choices)
              DropdownMenuItem(value: item.id, child: Text(tree.path(item))),
          ],
          onChanged: _saving
              ? null
              : (value) => setState(
                  () => _editedParentId = value == '' ? null : value,
                ),
        ),
        if (target != null && tree.height(target) > 1)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Ветвь переносится вместе со всеми подкатегориями. В списке только родители, при которых глубина всей ветви не превышает три уровня.',
            ),
          ),
      ],
    );
  }

  Widget _row(
    FinanceCategory item,
    CategoryTree tree,
    double step, {
    int depth = 1,
    bool filtering = false,
  }) {
    final archived = tree.archived(item);
    final inherited = !item.isArchived && archived;
    final hasChildren = tree.children(item.id).isNotEmpty;
    final open = _isOpen(item.id, filtering);
    final busy = _saving || _mode != null;
    final siblings = tree.ordered(
      _items.where((c) => c.parentId == item.parentId),
    );
    final siblingIndex = siblings.indexWhere((c) => c.id == item.id);
    final branch = tree.subtree(item.id);
    final checked = branch.every(_selected.contains);
    final partial = !checked && branch.any(_selected.contains);
    final rowWidget = LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 400;
        // Keep space for artwork, title and independent action targets,
        // including legacy histories deeper than three levels.
        final indent = ((depth - 1) * step).clamp(
          0.0,
          (constraints.maxWidth - 240).clamp(0.0, double.infinity),
        );
        return Padding(
          padding: EdgeInsets.only(left: indent),
          child: AnimatedContainer(
            key: _rowKeys.putIfAbsent(item.id, GlobalKey.new),
            duration: const Duration(milliseconds: 200),
            color: _highlightedId == item.id
                ? Theme.of(context).colorScheme.primaryContainer
                : null,
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                if (widget.isOwner)
                  Checkbox(
                    key: ValueKey('select-category:${item.id}'),
                    tristate: true,
                    value: partial ? null : checked,
                    onChanged: busy
                        ? null
                        : (_) => _selectBranch(item, !checked),
                    visualDensity: VisualDensity.compact,
                  ),
                CategoryMark(item.iconId, size: 64),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Tooltip(
                        message: tree.path(item),
                        triggerMode: TooltipTriggerMode.tap,
                        child: Text(
                          item.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      if (archived)
                        Text(
                          inherited
                              ? 'В архиве вместе с категорией'
                              : 'В архиве',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                if (hasChildren)
                  Semantics(
                    expanded: open,
                    child: IconButton(
                      key: ValueKey('expand-category:${item.id}'),
                      padding: EdgeInsets.zero,
                      constraints: BoxConstraints.tightFor(
                        width: compact ? 32 : 48,
                        height: 40,
                      ),
                      tooltip: open
                          ? 'Свернуть подкатегории: ${item.name}'
                          : 'Раскрыть подкатегории: ${item.name}',
                      onPressed: busy
                          ? null
                          : () => _toggleBranch(item, tree, filtering),
                      icon: Icon(open ? Icons.remove : Icons.add),
                    ),
                  ),
                if (widget.isOwner)
                  SizedBox(
                    width: compact ? 32 : 48,
                    child: PopupMenuButton<_CategoryAction>(
                      padding: EdgeInsets.zero,
                      key: ValueKey('category-menu:${item.id}'),
                      tooltip: 'Действия категории: ${item.name}',
                      enabled: !busy,
                      onSelected: (action) {
                        switch (action) {
                          case _CategoryAction.edit:
                            _edit(_EditMode.rename, target: item);
                          case _CategoryAction.archive:
                            _edit(_EditMode.archive, target: item);
                          case _CategoryAction.activate:
                            _edit(_EditMode.activate, target: item);
                          case _CategoryAction.createChild:
                            _edit(_EditMode.create, parent: item);
                          case _CategoryAction.move:
                            _chooseParent(item);
                          case _CategoryAction.up:
                            _move(item, -1);
                          case _CategoryAction.down:
                            _move(item, 1);
                          case _CategoryAction.delete:
                            _bulk('delete', single: item);
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: _CategoryAction.edit,
                          child: Text('Редактировать'),
                        ),
                        PopupMenuItem(
                          value: archived
                              ? _CategoryAction.activate
                              : _CategoryAction.archive,
                          enabled: !inherited,
                          child: Text(
                            archived ? 'Активировать' : 'Архивировать',
                          ),
                        ),
                        if (inherited)
                          const PopupMenuItem(
                            enabled: false,
                            child: Text(
                              'Сначала активируйте родительскую категорию',
                            ),
                          ),
                        PopupMenuItem(
                          value: _CategoryAction.createChild,
                          enabled: !archived && depth < 3,
                          child: const Text('Добавить подкатегорию'),
                        ),
                        const PopupMenuItem(
                          value: _CategoryAction.move,
                          child: Text('Добавить в родительскую категорию'),
                        ),
                        PopupMenuItem(
                          value: _CategoryAction.up,
                          enabled: siblingIndex > 0,
                          child: const Text('Поднять выше'),
                        ),
                        PopupMenuItem(
                          value: _CategoryAction.down,
                          enabled: siblingIndex < siblings.length - 1,
                          child: const Text('Опустить ниже'),
                        ),
                        const PopupMenuItem(
                          value: _CategoryAction.delete,
                          child: Text('Удалить'),
                        ),
                      ],
                    ),
                  ),
                if (widget.isOwner)
                  Draggable<String>(
                    key: ValueKey('drag-category:${item.id}'),
                    data: item.id,
                    maxSimultaneousDrags: busy ? 0 : 1,
                    feedback: Material(
                      elevation: 4,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(item.name),
                      ),
                    ),
                    childWhenDragging: const MouseRegion(
                      cursor: SystemMouseCursors.grabbing,
                      child: SizedBox(
                        width: 36,
                        height: 40,
                        child: Icon(Icons.menu, size: 26),
                      ),
                    ),
                    child: MouseRegion(
                      cursor: busy
                          ? SystemMouseCursors.basic
                          : SystemMouseCursors.grab,
                      child: Tooltip(
                        message: 'Перетащить ${item.name}',
                        child: SizedBox(
                          width: 36,
                          height: 40,
                          child: Icon(
                            Icons.menu,
                            size: 26,
                            color: busy
                                ? Theme.of(context).disabledColor
                                : Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
    return DragTarget<String>(
      onWillAcceptWithDetails: (d) =>
          widget.isOwner &&
          !busy &&
          d.data != item.id &&
          tree.byId(d.data) != null &&
          tree.byId(d.data)?.parentId == item.parentId,
      onMove: (d) {
        final box = _rowKeys[item.id]?.currentContext?.findRenderObject();
        if (box is RenderBox) {
          final after = box.globalToLocal(d.offset).dy > box.size.height / 2;
          if (after != _dropAfter) setState(() => _dropAfter = after);
        }
      },
      onAcceptWithDetails: (d) => _reorder(item, d.data, after: _dropAfter),
      builder: (_, candidates, _) => Column(
        children: [
          if (candidates.isNotEmpty && !_dropAfter)
            const Divider(thickness: 3, height: 3),
          rowWidget,
          if (candidates.isNotEmpty && _dropAfter)
            const Divider(thickness: 3, height: 3),
        ],
      ),
    );
  }

  List<Widget> _treeRows(CategoryTree tree, double step) {
    final filtering = _search.trim().isNotEmpty || _activity != 'Все';
    final query = _search.toLowerCase().replaceAll('ё', 'е').trim();
    final included = <String>{};
    if (filtering) {
      for (final item in _items) {
        final archived = tree.archived(item);
        if ((_activity == 'Активные' && archived) ||
            (_activity == 'В архиве' && !archived)) {
          continue;
        }
        if (!tree
            .path(item)
            .toLowerCase()
            .replaceAll('ё', 'е')
            .contains(query)) {
          continue;
        }
        included.add(item.id);
        included.addAll(tree.ancestry(item)?.map((c) => c.id) ?? []);
      }
    }
    final visited = <String>{};
    final result = <Widget>[];
    void visit(FinanceCategory item, int depth) {
      if (!visited.add(item.id)) return;
      if (filtering && !included.contains(item.id)) return;
      result.add(_row(item, tree, step, depth: depth, filtering: filtering));
      if (_isOpen(item.id, filtering)) {
        for (final child in tree.children(item.id)) {
          visit(child, depth + 1);
        }
      }
    }

    for (final root in tree.ordered(
      _items.where((c) => c.parentId == null || tree.byId(c.parentId) == null),
    )) {
      visit(root, 1);
    }
    // Malformed legacy chains remain reachable and cannot recurse forever.
    for (final item in _items.where((c) => tree.ancestry(c) == null)) {
      if (!visited.contains(item.id)) visit(item, 1);
    }
    if (result.isEmpty && _items.isNotEmpty) {
      result.add(
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text('Категории не найдены'),
        ),
      );
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_loadError != null)
          Text(
            _loadError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_mode == null && _saveError != null)
          Text(
            _saveError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        Wrap(
          spacing: 8,
          children: [
            if (widget.isOwner && _loadError == null && _mode == null)
              FilledButton(
                onPressed: _saving ? null : () => _edit(_EditMode.create),
                child: const Text('Добавить категорию'),
              ),
            TextButton(
              onPressed: _saving ? null : _load,
              child: Text(
                _loadError == null ? 'Обновить список' : 'Повторить попытку',
              ),
            ),
          ],
        ),
        if (_mode != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(switch (_mode!) {
                      _EditMode.create => 'Создать категорию',
                      _EditMode.rename => 'Редактирование: ${_target!.name}',
                      _EditMode.archive => 'Архивировать «${_target!.name}»?',
                      _EditMode.activate => 'Активировать «${_target!.name}»?',
                    }, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    if (_mode == _EditMode.archive ||
                        _mode == _EditMode.activate)
                      Text(
                        _mode == _EditMode.archive
                            ? 'Запись сохранится для истории. Подкатегории также будут считаться архивными.'
                            : 'Собственный архивный флаг будет снят. Собственные флаги подкатегорий сохранятся; архивный предок продолжает определять доступность ветви.',
                      )
                    else
                      TextFormField(
                        controller: _name,
                        enabled: !_saving,
                        maxLength: 100,
                        decoration: InputDecoration(
                          labelText: 'Название категории',
                          border: const OutlineInputBorder(),
                          prefixIcon: CategoryMark(_iconId),
                        ),
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                            ? 'Введите название категории.'
                            : value.trim().runes.length > 100
                            ? 'Не более 100 символов.'
                            : null,
                      ),
                    if (_mode == _EditMode.create ||
                        _mode == _EditMode.rename) ...[
                      CategoryIconField(
                        value: _iconId,
                        onChanged: _saving
                            ? null
                            : (id) => setState(() => _iconId = id),
                      ),
                      const SizedBox(height: 12),
                      _parentField(),
                    ],
                    if (_saveError != null)
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          _saveError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      children: [
                        FilledButton(
                          onPressed: _saving ? null : _save,
                          child: Text(_saving ? 'Сохраняем…' : 'Сохранить'),
                        ),
                        TextButton(
                          onPressed: _saving
                              ? null
                              : () => setState(() {
                                  _mode = null;
                                  _saveError = null;
                                  _name.clear();
                                }),
                          child: const Text('Отмена'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (_loadError == null && _items.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('Категорий пока нет'),
          ),
        const SizedBox(height: 12),
        TextField(
          controller: _searchController,
          decoration: const InputDecoration(
            labelText: 'Поиск категорий',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (value) => setState(() {
            _search = value;
            _filterCollapsed.clear();
          }),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final value in ['Все', 'Активные', 'В архиве'])
              FilterChip(
                label: Text(value),
                selected: _activity == value,
                onSelected: (_) => setState(() {
                  _activity = value;
                  _filterCollapsed.clear();
                }),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (widget.isOwner && _mode == null)
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton(
                onPressed: _saving
                    ? null
                    : () {
                        final tree = CategoryTree(_items);
                        for (final c in _items.where(
                          (c) => _matchesFilter(c, tree),
                        )) {
                          _selectBranch(c, true);
                        }
                      },
                child: const Text('Выделить все'),
              ),
              if (_selected.isNotEmpty) ...[
                Text('Выбрано: ${_selected.length}'),
                TextButton(
                  onPressed: _saving ? null : () => _bulk('archive'),
                  child: const Text('Архивировать'),
                ),
                TextButton(
                  onPressed: _saving ? null : () => _bulk('restore'),
                  child: const Text('Восстановить'),
                ),
                TextButton(
                  onPressed: _saving ? null : () => _bulk('delete'),
                  child: const Text('Удалить'),
                ),
                TextButton(
                  onPressed: _saving ? null : () => setState(_selected.clear),
                  child: const Text('Снять выделение'),
                ),
              ],
            ],
          ),
        LayoutBuilder(
          builder: (context, constraints) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _treeRows(
              CategoryTree(_items),
              constraints.maxWidth >= 720 ? 128 : 24,
            ),
          ),
        ),
      ],
    );
  }
}
