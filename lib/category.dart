enum CategoryKind {
  expense('expense', 'Расходы'),
  income('income', 'Доходы');

  const CategoryKind(this.value, this.label);
  final String value;
  final String label;
}

class FinanceCategory {
  const FinanceCategory({
    required this.id,
    required this.spaceId,
    required this.kind,
    required this.name,
    this.parentId,
    this.isArchived = false,
    this.iconId = 'category',
    this.sortOrder = 0,
    this.revision,
  });
  final String id;
  final String spaceId;
  final CategoryKind kind;
  final String name;
  final String? parentId;
  final bool isArchived;
  final String iconId;
  final int sortOrder;
  final String? revision;

  factory FinanceCategory.fromJson(Map<String, dynamic> row) => FinanceCategory(
    id: row['id'] as String,
    spaceId: row['space_id'] as String,
    kind: CategoryKind.values.firstWhere((kind) => kind.value == row['kind']),
    name: row['name'] as String,
    parentId: row['parent_id'] as String?,
    isArchived: row['is_archived'] as bool,
    iconId: row['icon_id'] as String? ?? 'category',
    sortOrder: row['sort_order'] as int? ?? 0,
    revision: row['revision'] as String?,
  );
}

List<Map<String, dynamic>> categorySnapshot(List<FinanceCategory> items) {
  final rows = [...items]..sort((a, b) => a.id.compareTo(b.id));
  return [
    for (final c in rows) {'id': c.id, 'revision': c.revision},
  ];
}
