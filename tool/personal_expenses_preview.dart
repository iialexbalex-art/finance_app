// Isolated interactive QA. Stores fixture order only, never calls Supabase.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:finance_app/app_theme.dart';
import 'package:finance_app/personal_expense_catalog.dart';
import 'package:finance_app/categories_screen.dart';
import 'package:finance_app/category.dart';
import 'package:finance_app/finance_repository.dart';

const previewSpace = FinanceSpace(id: 'personal-qa', ownerUserId: 'qa', name: 'Личное', kind: 'personal');

class PersonalPreviewRepository extends FinanceRepository {
  PersonalPreviewRepository(this.preferences, this.categories);
  final SharedPreferences preferences;
  final List<FinanceCategory> categories;
  static const storageKey = 'personal_catalog_qa_v1';

  Future<void> persist() => preferences.setString(storageKey, jsonEncode([
    for (final c in categories) {
      'id': c.id, 'space_id': c.spaceId, 'kind': c.kind.value,
      'name': c.name, 'parent_id': c.parentId, 'is_archived': c.isArchived,
      'icon_id': c.iconId, 'sort_order': c.sortOrder, 'revision': c.revision,
    },
  ]));

  @override
  Future<List<FinanceCategory>> loadCategories(String spaceId, CategoryKind kind) async => categories.where((c) => c.spaceId == spaceId && c.kind == kind).toList();
  @override
  Future<void> reorderCategories(String requestId, String spaceId, CategoryKind kind, String? parentId, List<String> ids, List<FinanceCategory> snapshot) async {
    if (jsonEncode(categorySnapshot(snapshot)) != jsonEncode(categorySnapshot(categories)) ||
        ids.toSet().length != ids.length ||
        categories.where((c) => c.parentId == parentId).length != ids.length ||
        categories.where((c) => c.parentId == parentId).any((c) => !ids.contains(c.id))) {
      throw StateError('Incomplete siblings or stale revision');
    }
    for (final id in ids) {
      final index = categories.indexWhere((c) => c.id == id);
      final c = categories[index];
      categories[index] = FinanceCategory(id: c.id, spaceId: c.spaceId, kind: c.kind, name: c.name,
        parentId: c.parentId, iconId: c.iconId, isArchived: c.isArchived, sortOrder: ids.indexOf(id)+1,
        revision: DateTime.now().microsecondsSinceEpoch.toString());
    }
    await persist();
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('QA fixture action only');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getString(PersonalPreviewRepository.storageKey);
  final repo = PersonalPreviewRepository(prefs, saved == null ? personalExpenseFixtures(previewSpace.id) :
    (jsonDecode(saved) as List).map((x) => FinanceCategory.fromJson(Map<String,dynamic>.from(x))).toList());
  runApp(MaterialApp(
    title: 'Личные расходы · проверка каталога',
    theme: Uri.base.queryParameters['theme'] == 'dark' ? ThemeData.dark(useMaterial3: true) : financeTheme(),
    debugShowCheckedModeBanner: false, locale: const Locale('ru'),
    localizationsDelegates: GlobalMaterialLocalizations.delegates, supportedLocales: const [Locale('ru')],
    home: Scaffold(appBar: AppBar(title: const Text('Личные расходы · тестовый просмотр 16 + 127')),
      body: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Center(child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100), child: CategoriesScreen(space: previewSpace, isOwner: true, repository: repo))))),
  ));
}
