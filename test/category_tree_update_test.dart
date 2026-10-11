import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:finance_app/categories_screen.dart';
import 'package:finance_app/category.dart';
import 'package:finance_app/category_tree.dart';
import 'package:finance_app/wallet_icons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'categories_screen_test.dart' show click, categoryAction;
import 'fake_finance.dart';
import 'expense_filters_test.dart' show row;

FinanceCategory node(
  String id, {
  String? parent,
  String? name,
  String space = 'personal',
  CategoryKind kind = CategoryKind.expense,
  bool archived = false,
  String icon = 'cat_exp_food',
}) => FinanceCategory(
  id: id,
  spaceId: space,
  kind: kind,
  name: name ?? id,
  parentId: parent,
  isArchived: archived,
  iconId: icon,
);

Future<void> mount(
  WidgetTester t,
  FakeFinance repo, {
  Size size = const Size(1440, 900),
  bool owner = true,
  Map<String, Set<String>>? expansion,
  String key = 'screen',
  bool business = false,
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: CategoriesScreen(
            key: ValueKey(key),
            space: business ? businessSpace : personalSpace,
            isOwner: owner,
            repository: repo,
            expansionState: expansion,
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

Future<void> toggle(WidgetTester t, String id) async {
  final button = find.byKey(ValueKey('expand-category:$id'));
  await t.ensureVisible(button);
  await t.tap(button);
  await t.pumpAndSettle();
}

Future<void> move(WidgetTester t, String id, String? parent) async {
  await categoryAction(t, id, 'Добавить в родительскую категорию');
  final option = find.byKey(ValueKey('parent-choice:${parent ?? 'root'}'));
  await t.ensureVisible(option);
  await t.tap(option);
  await t.pumpAndSettle();
  await click(t, 'Сохранить');
}

void main() {
  for (final width in [320.0, 600.0, 1440.0]) {
    testWidgets(
      'Collapse, nested toggle and adaptive offsets at width $width',
      (t) async {
        final repo = FakeFinance()
          ..categories.addAll([
            node('root'),
            node('child', parent: 'root'),
            node(
              'leaf',
              parent: 'child',
              name: 'Очень длинное название под-подкатегории целиком',
            ),
          ]);
        await mount(t, repo, size: Size(width, 900));
        expect(find.text('child'), findsNothing);
        expect(repo.categoryWrites, 0);
        await toggle(t, 'root');
        expect(find.text('child'), findsOneWidget);
        expect(find.text(repo.categories.last.name), findsOneWidget);
        final marks = find.byType(CategoryMark);
        final step = width >= 752 ? 128.0 : 24.0;
        expect(
          t.getTopLeft(marks.at(1)).dx - t.getTopLeft(marks.first).dx,
          step,
        );
        expect(
          t.getTopLeft(marks.at(2)).dx - t.getTopLeft(marks.first).dx,
          2 * step,
        );
        expect(t.getTopLeft(marks.at(1)).dy - t.getTopLeft(marks.first).dy, 76);
        expect(
          find.byKey(const ValueKey('expand-category:leaf')),
          findsNothing,
        );
        expect(
          find.byTooltip('root → child → ${repo.categories.last.name}'),
          findsOneWidget,
        );
        await toggle(t, 'child');
        expect(find.text(repo.categories.last.name), findsNothing);
        await toggle(t, 'root');
        expect(find.text('child'), findsNothing);
        await toggle(t, 'root');
        expect(find.text(repo.categories.last.name), findsOneWidget);
        expect(repo.categoryWrites, 0);
        expect(t.takeException(), isNull);
      },
    );
  }

  for (final business in [false, true]) {
    for (final kind in CategoryKind.values) {
      testWidgets(
        'Move branch, leaf, root and reload ${business ? 'business' : 'personal'} ${kind.value}',
        (t) async {
          final space = business ? 'business' : 'personal';
          final repo = FakeFinance()
            ..categories.addAll([
              node('branch', kind: kind, space: space),
              node(
                'child',
                parent: 'branch',
                kind: kind,
                space: space,
                icon: 'ready_meal_plov_bread_tea_v1',
                archived: true,
              ),
              node('destination', kind: kind, space: space),
            ]);
          final operation = row(1, category: 'child');
          repo.expenseRows[space] = [operation];
          final descendant = repo.categories[1];
          await mount(t, repo, business: business);
          if (kind == CategoryKind.income) await click(t, 'Доходы');
          await move(t, 'branch', 'destination');
          expect(
            CategoryTree(repo.categories).path(descendant),
            'destination → branch → child',
          );
          expect(repo.categories[1], same(descendant));
          expect(find.text('branch'), findsOneWidget);
          expect(find.text('child'), findsOneWidget);
          await move(t, 'child', null);
          expect(repo.categories[1].parentId, isNull);
          expect(repo.categories[1].isArchived, isTrue);
          expect(repo.categories[1].iconId, descendant.iconId);
          await move(t, 'child', 'branch');
          await move(t, 'branch', null);
          expect(repo.categories.length, 3);
          expect(repo.categories.map((c) => c.id).toSet(), {
            'branch',
            'child',
            'destination',
          });
          expect(repo.expenseRows[space]!.single, same(operation));
          expect(repo.expenseRows[space]!.single.categoryId, 'child');
          expect(repo.expenseRows[space]!.single.amount, operation.amount);
          await mount(t, repo, business: business, key: 'refreshed');
          if (kind == CategoryKind.income) await click(t, 'Доходы');
          expect(find.text('child'), findsNothing); // fresh page collapses
          await toggle(t, 'branch');
          expect(find.text('child'), findsOneWidget);
          expect(repo.categories[1].parentId, 'branch');
          expect(repo.categories[1].iconId, 'ready_meal_plov_bread_tea_v1');
          expect(t.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'Parent search uses IDs/full paths, current marker and entire-branch exclusions',
    (t) async {
      final repo = FakeFinance()
        ..categories.addAll([
          node('A'),
          node('B'),
          node('same-a', parent: 'A', name: 'Одинаково'),
          node('same-b', parent: 'B', name: 'Одинаково'),
          node('moving', parent: 'A'),
          node('own-child', parent: 'moving'),
          node('foreign', space: 'business'),
          node('income', kind: CategoryKind.income),
          node('archived', archived: true),
        ]);
      await mount(t, repo);
      await toggle(t, 'A');
      await categoryAction(t, 'moving', 'Добавить в родительскую категорию');
      expect(find.byKey(const ValueKey('parent-choice:moving')), findsNothing);
      expect(
        find.byKey(const ValueKey('parent-choice:own-child')),
        findsNothing,
      );
      for (final id in ['same-a', 'same-b', 'foreign', 'income', 'archived']) {
        expect(find.byKey(ValueKey('parent-choice:$id')), findsNothing);
      }
      expect(find.text('Текущий родитель'), findsOneWidget);
      await click(t, 'Отмена');
      await categoryAction(t, 'own-child', 'Добавить в родительскую категорию');
      await t.enterText(
        find.widgetWithText(TextField, 'Поиск родителя'),
        'одинаково',
      );
      await t.pumpAndSettle();
      expect(find.text('A → Одинаково'), findsOneWidget);
      expect(find.text('B → Одинаково'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('parent-choice:same-b')));
      await click(t, 'Сохранить');
      expect(
        repo.categories.firstWhere((c) => c.id == 'own-child').parentId,
        'same-b',
      );
      expect(find.text('own-child'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'Rejected move stays in old place, retries and duplicate saves are guarded',
    (t) async {
      final repo = FakeFinance()
        ..categories.addAll([node('moving'), node('destination')]);
      await mount(t, repo);
      await categoryAction(t, 'moving', 'Добавить в родительскую категорию');
      await t.tap(find.byKey(const ValueKey('parent-choice:destination')));
      final pending = Completer<void>();
      repo.onCategorySave = () => pending.future;
      await click(t, 'Сохранить');
      expect(repo.categoryWrites, 1);
      await click(t, 'Сохраняем…');
      expect(repo.categoryWrites, 1);
      pending.completeError(
        const PostgrestException(message: 'denied', code: '23514'),
      );
      await t.pumpAndSettle();
      expect(
        find.textContaining('Создание или перенос недоступны'),
        findsOneWidget,
      );
      expect(repo.categories.first.parentId, isNull);
      repo.onCategorySave = null;
      await click(t, 'Сохранить');
      expect(repo.categories.first.parentId, 'destination');
      expect(repo.categories.length, 2);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'Search/filter reveal ancestors temporarily; session state survives scope switches',
    (t) async {
      final expansion = <String, Set<String>>{};
      final repo = FakeFinance()
        ..categories.addAll([
          node('root'),
          node('leaf', parent: 'root'),
          node('archive', archived: true),
          node('inactive-leaf', parent: 'archive'),
          node('income-root', kind: CategoryKind.income),
          node(
            'income-child',
            parent: 'income-root',
            kind: CategoryKind.income,
          ),
        ]);
      await mount(t, repo, expansion: expansion);
      await t.enterText(
        find.widgetWithText(TextField, 'Поиск категорий'),
        'leaf',
      );
      await t.pumpAndSettle();
      expect(find.text('root'), findsOneWidget);
      expect(find.text('leaf'), findsWidgets);
      expect(find.text('В архиве вместе с категорией'), findsOneWidget);
      await t.enterText(find.widgetWithText(TextField, 'Поиск категорий'), '');
      await t.pumpAndSettle();
      expect(find.text('leaf'), findsNothing);
      await toggle(t, 'root');
      await click(t, 'Доходы');
      expect(find.text('income-child'), findsNothing);
      await toggle(t, 'income-root');
      await click(t, 'Расходы');
      expect(find.text('leaf'), findsOneWidget);
      await t.tap(find.widgetWithText(FilterChip, 'В архиве'));
      await t.pumpAndSettle();
      expect(find.text('archive'), findsOneWidget);
      expect(find.text('inactive-leaf'), findsOneWidget);
      expect(find.text('root'), findsNothing);
      await click(t, 'Все');
      expect(find.text('inactive-leaf'), findsNothing);
      await mount(
        t,
        repo,
        expansion: expansion,
        business: true,
        key: 'business',
      );
      await mount(t, repo, expansion: expansion, key: 'personal-again');
      expect(find.text('leaf'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'Activation respects inherited archive and managers have no actions',
    (t) async {
      final repo = FakeFinance()
        ..categories.addAll([
          node('archive', archived: true),
          node('child', parent: 'archive'),
        ]);
      await mount(t, repo);
      await toggle(t, 'archive');
      await categoryAction(t, 'archive', 'Активировать');
      await click(t, 'Сохранить');
      expect(repo.categories.first.isArchived, isFalse);
      expect(repo.categories.last.isArchived, isFalse);
      expect(find.text('В архиве вместе с категорией'), findsNothing);
      await mount(t, repo, owner: false, key: 'manager');
      expect(find.byWidgetPredicate((w) => w is PopupMenuButton), findsNothing);
      await toggle(t, 'archive');
      expect(find.text('child'), findsOneWidget);
    },
  );

  testWidgets(
    'Legacy history deeper than three levels remains visible on mobile',
    (t) async {
      final repo = FakeFinance()
        ..categories.addAll([
          node('a'),
          node('b', parent: 'a'),
          node('c', parent: 'b'),
          node('d', parent: 'c'),
        ]);
      await mount(t, repo, size: const Size(320, 900));
      await toggle(t, 'a');
      expect(find.text('d'), findsOneWidget);
      expect(repo.categories.length, 4);
      expect(t.takeException(), isNull);
    },
  );

  test(
    'Save validation rejects foreign scope, self, descendants and branch depth',
    () {
      final items = [
        node('a'),
        node('b', parent: 'a'),
        node('c', parent: 'b'),
        node('other'),
        node('foreign', space: 'business'),
        node('income', kind: CategoryKind.income),
      ];
      final tree = CategoryTree(items);
      for (final parent in ['a', 'b', 'c', 'foreign', 'income', 'other']) {
        expect(tree.parentError(items.first, parent), isNotNull);
      }
      expect(tree.parentError(items[1], 'other'), isNull);
      expect(tree.parentError(items.first, null), isNull);
    },
  );

  testWidgets(
    'Approved meal PNG retains bytes, RGBA, full composition and DPR decoding',
    (t) async {
      final data = await rootBundle.load(
        'assets/category_photoreal/ready_meal_plov_bread_tea_v1.png',
      );
      await t.runAsync(() async {
        if (!kIsWeb) {
          expect(
            data.buffer.asUint8List(),
            await File('design/category-tree-update/assets/ready-meal.png')
                .readAsBytes(),
          );
        }
        final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 1254);
        expect(frame.image.height, 1254);
        final rgba = await frame.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        expect(rgba!.getUint8(3), 0);
        frame.image.dispose();
        codec.dispose();
      });
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(
        const MaterialApp(
          home: CategoryMark('ready_meal_plov_bread_tea_v1', size: 64),
        ),
      );
      final image = t.widget<Image>(find.byType(Image));
      expect(image.fit, BoxFit.contain);
      expect((image.image as ResizeImage).width, 192);
      expect(image.filterQuality, FilterQuality.high);
    },
  );
}
