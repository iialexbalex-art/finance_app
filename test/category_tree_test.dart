import 'package:finance_app/category.dart';
import 'package:finance_app/category_tree.dart';
import 'package:flutter_test/flutter_test.dart';

FinanceCategory c(
  String id, {
  String? parent,
  bool archived = false,
  String space = 's',
  CategoryKind kind = CategoryKind.expense,
}) => FinanceCategory(
  id: id,
  spaceId: space,
  kind: kind,
  name: id,
  parentId: parent,
  isArchived: archived,
);

void main() {
  test('Three levels, full paths and eligible parents for new category', () {
    final tree = CategoryTree([
      c('Daily'),
      c('Food', parent: 'Daily'),
      c('Groceries', parent: 'Food'),
      c('Other'),
      c('foreign', space: 'x'),
      c('income', kind: CategoryKind.income),
    ]);
    expect(tree.depth(tree.byId('Groceries')!), 3);
    expect(tree.path(tree.byId('Groceries')!), 'Daily → Food → Groceries');
    expect(tree.parents('s', CategoryKind.expense).map((c) => c.id), [
      'Daily',
      'Food',
      'Other',
    ]);
  });
  test('Moving subtree excludes self, all descendants and excessive resulting depth', () {
    final tree = CategoryTree([
      c('A'),
      c('B', parent: 'A'),
      c('C', parent: 'B'),
      c('D'),
      c('E', parent: 'D'),
    ]);
    expect(
      tree
          .parents('s', CategoryKind.expense, moving: tree.byId('A'))
          .map((c) => c.id),
      isEmpty,
    );
    expect(
      tree
          .parents('s', CategoryKind.expense, moving: tree.byId('B'))
          .map((c) => c.id),
      ['A', 'D'],
    );
    expect(
      tree
          .parents('s', CategoryKind.expense, moving: tree.byId('C'))
          .map((c) => c.id),
      ['A', 'B', 'D', 'E'],
    );
    expect(tree.height(tree.byId('B')!), 2);
  });
  test(
    'Archive at any ancestor excludes entire branch without changing own flags',
    () {
      final tree = CategoryTree([
        c('A', archived: true),
        c('B', parent: 'A'),
        c('C', parent: 'B'),
        c('D'),
      ]);
      expect(tree.archived(tree.byId('C')!), isTrue);
      expect(tree.byId('C')!.isArchived, isFalse);
      expect(tree.parents('s', CategoryKind.expense).map((c) => c.id), ['D']);
    },
  );
  test('Broken or cyclic tree fails closed rather than infinite recursion', () {
    final tree = CategoryTree([
      c('A', parent: 'B'),
      c('B', parent: 'A'),
      c('C', parent: 'missing'),
    ]);
    expect(tree.parents('s', CategoryKind.expense), isEmpty);
    expect(tree.height(tree.byId('A')!), greaterThan(3));
  });
}
