// Browser QA only: this entry point never initializes or contacts Supabase.
// flutter run -d web-server -t tool/category_tree_preview.dart --web-port=8081
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:finance_app/app_theme.dart';
import 'package:finance_app/categories_screen.dart';
import 'package:finance_app/category.dart';
import 'package:finance_app/category_parent_dialog.dart';
import 'package:finance_app/category_tree.dart';
import 'package:finance_app/finance_repository.dart';

const personalSpace = FinanceSpace(
  id: 'personal',
  ownerUserId: 'preview',
  name: 'Личные финансы',
  kind: 'personal',
);

class _PreviewRepository extends FinanceRepository {
  final categories = <FinanceCategory>[...previewCategories];
  @override
  Future<List<FinanceCategory>> loadCategories(
    String spaceId,
    CategoryKind kind,
  ) async =>
      categories.where((c) => c.spaceId == spaceId && c.kind == kind).toList();
  @override
  Future<FinanceCategory> editCategory(
    FinanceCategory previous, {
    String? name,
    String? iconId,
    bool? archived,
    bool changeParent = false,
    String? parentId,
  }) async {
    final saved = FinanceCategory(
      id: previous.id,
      spaceId: previous.spaceId,
      kind: previous.kind,
      name: name ?? previous.name,
      iconId: iconId ?? previous.iconId,
      isArchived: archived ?? previous.isArchived,
      parentId: changeParent ? parentId : previous.parentId,
    );
    categories[categories.indexWhere((c) => c.id == saved.id)] = saved;
    return saved;
  }

  @override
  Future<FinanceCategory> createCategory(
    String spaceId,
    CategoryKind kind,
    String name,
    String? parentId, {
    String iconId = 'category',
  }) async {
    final saved = FinanceCategory(
      id: 'preview-${categories.length}',
      spaceId: spaceId,
      kind: kind,
      name: name,
      parentId: parentId,
      iconId: iconId,
    );
    categories.add(saved);
    return saved;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('The preview only supports category fixtures.');
}

final previewCategories = <FinanceCategory>[
  const FinanceCategory(
    id: 'daily',
    spaceId: 'personal',
    kind: CategoryKind.expense,
    name: 'Ежедневные',
    iconId: 'cat_exp_household_goods',
  ),
  const FinanceCategory(
    id: 'food',
    spaceId: 'personal',
    kind: CategoryKind.expense,
    name: 'Еда',
    parentId: 'daily',
    iconId: 'cat_exp_food',
  ),
  const FinanceCategory(
    id: 'meal',
    spaceId: 'personal',
    kind: CategoryKind.expense,
    name: 'Готовая еда',
    parentId: 'food',
    iconId: 'ready_meal_plov_bread_tea_v1',
  ),
  const FinanceCategory(
    id: 'groceries',
    spaceId: 'personal',
    kind: CategoryKind.expense,
    name: 'Продукты для дома и приготовления любимых блюд',
    parentId: 'food',
    iconId: 'cat_exp_food',
  ),
  const FinanceCategory(
    id: 'transport',
    spaceId: 'personal',
    kind: CategoryKind.expense,
    name: 'Транспорт',
    iconId: 'cat_exp_car',
  ),
  const FinanceCategory(
    id: 'fuel',
    spaceId: 'personal',
    kind: CategoryKind.expense,
    name: 'Бензин',
    parentId: 'transport',
    iconId: 'cat_exp_fuel',
  ),
  const FinanceCategory(
    id: 'archive',
    spaceId: 'personal',
    kind: CategoryKind.expense,
    name: 'Архивные категории',
    isArchived: true,
    iconId: 'cat_exp_air_tickets',
  ),
];

void main() => runApp(
  MaterialApp(
    title: 'Категории — контрольные данные',
    theme: financeTheme(),
    debugShowCheckedModeBanner: false,
    locale: const Locale('ru'),
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    supportedLocales: const [Locale('ru')],
    home: const _Preview(),
  ),
);

class _Preview extends StatefulWidget {
  const _Preview();
  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  final repository = _PreviewRepository();
  late final expansion = <String, Set<String>>{
    'personal:expense:true': Uri.base.queryParameters['view'] == 'collapsed'
        ? <String>{}
        : {'daily', 'food'},
  };
  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Scaffold(
        appBar: AppBar(title: const Text('Категории · контрольные данные')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1040),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Личные финансы', style: TextStyle(fontSize: 20)),
                  const SizedBox(height: 12),
                  CategoriesScreen(
                    space: personalSpace,
                    isOwner: true,
                    repository: repository,
                    expansionState: expansion,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      // Render the actual dialog widget deterministically for browser screenshots.
      // Opening and saving via the menu are covered by category_tree_update_test.
      if (Uri.base.queryParameters['view'] == 'parent')
        const ModalBarrier(color: Colors.black54, dismissible: false),
      if (Uri.base.queryParameters['view'] == 'parent')
        CategoryParentDialog(
          moving: previewCategories[2],
          tree: CategoryTree(repository.categories),
          save: (_) async {},
        ),
    ],
  );
}
