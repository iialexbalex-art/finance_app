import 'category.dart';

/// UI projection only. Database constraints remain authoritative.
class CategoryTree {
  CategoryTree(this.items);
  final List<FinanceCategory> items;
  FinanceCategory? byId(String? id) =>
      items.where((c) => c.id == id).firstOrNull;
  List<FinanceCategory> children(String id) =>
      ordered(items.where((c) => c.parentId == id));

  /// Stable sibling order; old schemas and manually created rows keep load order.
  List<FinanceCategory> ordered(Iterable<FinanceCategory> rows) {
    final indexed = rows.toList().asMap().entries.toList();
    indexed.sort((a, b) {
      final aOrder = a.value.sortOrder == 0 ? 0x7fffffff : a.value.sortOrder;
      final bOrder = b.value.sortOrder == 0 ? 0x7fffffff : b.value.sortOrder;
      final order = aOrder.compareTo(bOrder);
      return order == 0 ? a.key.compareTo(b.key) : order;
    });
    return indexed.map((e) => e.value).toList();
  }

  List<FinanceCategory>? ancestry(FinanceCategory item) {
    final result = <FinanceCategory>[];
    final seen = <String>{};
    FinanceCategory? current = item;
    while (current != null) {
      if (!seen.add(current.id) ||
          current.spaceId != item.spaceId ||
          current.kind != item.kind) {
        return null;
      }
      result.add(current);
      if (current.parentId == null) return result.reversed.toList();
      current = byId(current.parentId);
      if (current == null) return null;
    }
    return null;
  }

  int depth(FinanceCategory item) => ancestry(item)?.length ?? 4;
  String path(FinanceCategory item) =>
      ancestry(item)?.map((c) => c.name).join(' → ') ?? item.name;
  bool archived(FinanceCategory item) =>
      ancestry(item)?.any((c) => c.isArchived) ?? true;

  Set<String> subtree(String id) {
    final result = <String>{};
    void visit(String next) {
      if (!result.add(next)) return;
      for (final child in children(next)) {
        visit(child.id);
      }
    }

    visit(id);
    return result;
  }

  int height(FinanceCategory item, [Set<String>? visited]) {
    final seen = {...?visited};
    if (!seen.add(item.id)) return 4;
    var result = 1;
    for (final child in children(item.id)) {
      final candidate = 1 + height(child, seen);
      if (candidate > result) result = candidate;
    }
    return result;
  }

  String? parentError(
    FinanceCategory? moving,
    String? parentId, {
    String? spaceId,
    CategoryKind? kind,
  }) {
    final branchHeight = moving == null ? 1 : height(moving);
    if (parentId == null) {
      return branchHeight > 3
          ? 'Глубина всей ветви превышает три уровня.'
          : null;
    }
    final parent = byId(parentId);
    if (parent == null ||
        parent.spaceId != (moving?.spaceId ?? spaceId) ||
        parent.kind != (moving?.kind ?? kind)) {
      return 'Родитель должен быть из того же пространства и типа категории.';
    }
    if (moving != null && subtree(moving.id).contains(parentId)) {
      return 'Нельзя переносить категорию в себя или своего потомка.';
    }
    if (archived(parent)) return 'Родитель и его предки должны быть активны.';
    if (depth(parent) + branchHeight > 3) {
      return 'После переноса глубина всей ветви превысит три уровня.';
    }
    return null;
  }

  List<FinanceCategory> parents(
    String spaceId,
    CategoryKind kind, {
    FinanceCategory? moving,
  }) {
    final excluded = moving == null ? <String>{} : subtree(moving.id);
    final branchHeight = moving == null ? 1 : height(moving);
    return items
        .where(
          (item) =>
              item.spaceId == spaceId &&
              item.kind == kind &&
              !excluded.contains(item.id) &&
              !archived(item) &&
              depth(item) + branchHeight <= 3,
        )
        .toList();
  }
}
