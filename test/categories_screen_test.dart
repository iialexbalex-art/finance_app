import 'dart:async';

import 'package:finance_app/category.dart';
import 'package:finance_app/main.dart';
import 'package:finance_app/wallet_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'fake_auth.dart';
import 'fake_finance.dart';

Future<void> click(WidgetTester tester, String text) async {
  const actions = [
    'Редактировать',
    'Архивировать',
    'Активировать',
    'Добавить подкатегорию',
    'Добавить в родительскую категорию',
  ];
  if (find.text(text).evaluate().isEmpty && actions.contains(text)) {
    final menus = find.byWidgetPredicate(
      (w) =>
          w is PopupMenuButton &&
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('category-menu:'),
    );
    for (var i = menus.evaluate().length - 1; i >= 0; i--) {
      await tester.ensureVisible(menus.at(i));
      await tester.tap(menus.at(i));
      await tester.pumpAndSettle();
      final entry = find.text(text);
      if (entry.evaluate().isNotEmpty &&
          tester
              .widget<PopupMenuItem>(
                find
                    .ancestor(
                      of: entry,
                      matching: find.byWidgetPredicate(
                        (w) => w is PopupMenuItem,
                      ),
                    )
                    .first,
              )
              .enabled) {
        break;
      }
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();
    }
  }
  await tester.ensureVisible(find.text(text).last);
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

Future<void> expandAll(WidgetTester tester) async {
  while (true) {
    final buttons = find.byWidgetPredicate(
      (w) =>
          w is IconButton &&
          w.tooltip?.startsWith('Раскрыть подкатегории:') == true,
    );
    if (buttons.evaluate().isEmpty) return;
    await tester.ensureVisible(buttons.first);
    await tester.tap(buttons.first);
    await tester.pumpAndSettle();
  }
}

Future<void> categoryAction(
  WidgetTester tester,
  String id,
  String action,
) async {
  final menu = find.byKey(ValueKey('category-menu:$id'));
  await tester.ensureVisible(menu);
  await tester.tap(menu);
  await tester.pumpAndSettle();
  await click(tester, action);
}

Future<void> open(WidgetTester tester, FakeFinance repo, FakeAuth auth) async {
  await tester.pumpWidget(FinanceApp(auth: auth, repository: repo));
  await tester.pumpAndSettle();
  await click(tester, 'Категории');
}

const root = FinanceCategory(
  id: 'root',
  spaceId: 'personal',
  kind: CategoryKind.expense,
  name: 'Покупки',
);

void main() {
  for (final size in [const Size(320, 568), const Size(1440, 900)]) {
    testWidgets('Owner creates, renames and archives tree at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = FakeAuth(signedIn: true);
      addTearDown(auth.dispose);
      final repo = FakeFinance();
      await open(tester, repo, auth);
      expect(find.text('Категорий пока нет'), findsOneWidget);
      await click(tester, 'Добавить категорию');
      await click(tester, 'Сохранить');
      expect(find.text('Введите название категории.'), findsOneWidget);
      expect(repo.categoryWrites, 0);
      await tester.enterText(find.byType(TextFormField), '  Покупки  ');
      final pending = Completer<void>();
      repo.onCategorySave = () => pending.future;
      await click(tester, 'Сохранить');
      await click(tester, 'Сохраняем…');
      expect(repo.categoryWrites, 1);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Сохраняем…'),
            )
            .onPressed,
        isNull,
      );
      pending.complete();
      await tester.pumpAndSettle();
      repo.onCategorySave = null;
      expect(find.text('Покупки'), findsOneWidget);
      expect(tester.widget<CategoryMark>(find.byType(CategoryMark)).size, 64);
      await click(tester, 'Добавить подкатегорию');
      await tester.enterText(find.byType(TextFormField), 'Продукты');
      await click(tester, 'Сохранить');
      expect(repo.categories.last.parentId, repo.categories.first.id);
      expect(find.byWidgetPredicate((w) => w is PopupMenuButton), findsWidgets);
      await click(tester, 'Редактировать');
      await tester.enterText(find.byType(TextFormField), 'Еда');
      await click(tester, 'Сохранить');
      expect(find.text('Еда'), findsOneWidget);
      // Archive the root; children remain visible as archived history.
      await categoryAction(tester, repo.categories.first.id, 'Архивировать');
      await click(tester, 'Сохранить');
      expect(repo.categories.length, 2);
      expect(repo.categories.first.isArchived, isTrue);
      expect(find.text('В архиве вместе с категорией'), findsOneWidget);
      expect(find.text('Добавить подкатегорию'), findsNothing);
      final incomeTab = find.descendant(
        of: find.byType(TabBar),
        matching: find.text('Доходы'),
      );
      await tester.ensureVisible(incomeTab);
      await tester.tap(incomeTab);
      await tester.pumpAndSettle();
      expect(find.text('Еда'), findsNothing);
      await click(tester, 'Добавить категорию');
      await tester.enterText(find.byType(TextFormField), 'Зарплата');
      await click(tester, 'Сохранить');
      expect(repo.categories.last.kind, CategoryKind.income);
      await click(tester, 'Личные финансы');
      await click(tester, 'Бизнес');
      expect(find.text('Зарплата'), findsNothing);
      expect(find.text('Категорий пока нет'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Manager only requests expenses, has no editing actions', (
    tester,
  ) async {
    final auth = FakeAuth(signedIn: true)..userId = 'manager';
    addTearDown(auth.dispose);
    final repo = FakeFinance()..spaces = [businessSpace];
    final requested = <CategoryKind>[];
    repo.onCategories = (space, kind) async {
      expect(space, 'business');
      requested.add(kind);
      return [
        const FinanceCategory(
          id: 'expense',
          spaceId: 'business',
          kind: CategoryKind.expense,
          name: 'Аренда',
        ),
      ];
    };
    await open(tester, repo, auth);
    expect(requested, [CategoryKind.expense]);
    expect(find.text('Аренда'), findsOneWidget);
    for (final text in [
      'Доходы',
      'Добавить категорию',
      'Добавить подкатегорию',
      'Редактировать',
      'Архивировать',
    ]) {
      expect(find.text(text), findsNothing);
    }
  });

  testWidgets('Load retry and rejected save preserve draft', (tester) async {
    final auth = FakeAuth(signedIn: true);
    addTearDown(auth.dispose);
    final repo = FakeFinance()
      ..onCategories = (_, _) async =>
          throw const PostgrestException(message: 'missing', code: 'PGRST205');
    await open(tester, repo, auth);
    expect(find.textContaining('Категории ещё не подключены'), findsOneWidget);
    repo.onCategories = null;
    await click(tester, 'Повторить попытку');
    await click(tester, 'Добавить категорию');
    await tester.enterText(find.byType(TextFormField), 'Черновик');
    repo.onCategorySave = () async =>
        throw const PostgrestException(message: 'denied', code: '42501');
    await click(tester, 'Сохранить');
    expect(find.textContaining('Недостаточно прав'), findsOneWidget);
    expect(find.text('Черновик'), findsOneWidget);
    repo.onCategorySave = null;
    await click(tester, 'Сохранить');
    expect(find.byType(TextFormField), findsNothing);
    expect(find.text('Черновик'), findsOneWidget);
  });

  testWidgets('Late read cannot cross space; late save cannot cross logout', (
    tester,
  ) async {
    final auth = FakeAuth(signedIn: true);
    addTearDown(auth.dispose);
    final repo = FakeFinance();
    final pending = Completer<List<FinanceCategory>>();
    repo.onCategories = (space, _) =>
        space == 'personal' ? pending.future : Future.value([]);
    await tester.pumpWidget(FinanceApp(auth: auth, repository: repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Категории'));
    await tester.pump();
    await tester.tap(find.text('Личные финансы'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Бизнес').last);
    await tester.pumpAndSettle();
    pending.complete([root]);
    await tester.pumpAndSettle();
    expect(find.text('Покупки'), findsNothing);
    final save = Completer<void>();
    repo.onCategorySave = () => save.future;
    await click(tester, 'Добавить категорию');
    await tester.enterText(find.byType(TextFormField), 'Поздняя запись');
    await click(tester, 'Сохранить');
    await click(tester, 'Выйти');
    save.complete();
    await tester.pumpAndSettle();
    expect(find.text('Вход в приложение'), findsOneWidget);
    expect(find.text('Поздняя запись'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Switching kind discards pending expense response and draft', (
    tester,
  ) async {
    final auth = FakeAuth(signedIn: true);
    addTearDown(auth.dispose);
    final repo = FakeFinance();
    await open(tester, repo, auth);
    final save = Completer<void>();
    repo.onCategorySave = () => save.future;
    await click(tester, 'Добавить категорию');
    await tester.enterText(find.byType(TextFormField), 'Расход');
    await click(tester, 'Сохранить');
    await click(tester, 'Доходы');
    save.complete();
    await tester.pumpAndSettle();
    expect(find.text('Расход'), findsNothing);
    expect(find.byType(TextFormField), findsNothing);
    expect(find.text('Категорий пока нет'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
