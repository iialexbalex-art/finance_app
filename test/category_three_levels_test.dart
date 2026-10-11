import 'package:finance_app/category_tree.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_auth.dart';
import 'fake_finance.dart';
import 'categories_screen_test.dart' show click, open, categoryAction;
import 'category_parent_test.dart' show category, choose, edit;

void main() {
  for (final size in [const Size(320, 568), const Size(1440, 900)]) {
    testWidgets(
      'Create via full path, preselect action and render third level at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final auth = FakeAuth(signedIn: true);
        addTearDown(auth.dispose);
        final repo = FakeFinance()
          ..categories.addAll([
            category('Ежедневные'),
            category('Еда', parent: 'Ежедневные'),
          ]);
        await open(tester, repo, auth);
        await click(tester, 'Добавить категорию');
        expect(
          tester
              .widget<DropdownButtonFormField<String>>(
                find.byType(DropdownButtonFormField<String>).last,
              )
              .initialValue,
          '',
        );
        await choose(tester, 'Ежедневные → Еда');
        await tester.enterText(find.byType(TextFormField), 'Продукты');
        await click(tester, 'Сохранить');
        expect(repo.categories.last.parentId, 'Еда');
        expect(find.text('Продукты'), findsOneWidget);
        expect(find.text('Продукты'), findsOneWidget);
        await click(tester, 'Добавить подкатегорию'); // второй уровень
        expect(
          tester
              .widget<DropdownButtonFormField<String>>(
                find.byType(DropdownButtonFormField<String>).last,
              )
              .initialValue,
          'Еда',
        );
        await tester.enterText(find.byType(TextFormField), 'Кафе');
        await click(tester, 'Сохранить');
        expect(repo.categories.last.parentId, 'Еда');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Move subtree, preserve descendants, render inherited grandparent archive',
    (tester) async {
      final auth = FakeAuth(signedIn: true);
      addTearDown(auth.dispose);
      final repo = FakeFinance()
        ..categories.addAll([
          category('Еда'),
          category('Продукты', parent: 'Еда'),
          category('Ежедневные'),
          category('Другое'),
          category('Вложенное', parent: 'Другое'),
        ]);
      final oldChild = repo.categories[1];
      await open(tester, repo, auth);
      await edit(tester, 'Еда');
      final dropdown = tester.widget<DropdownButton<String>>(
        find.descendant(
          of: find.byType(DropdownButtonFormField<String>).last,
          matching: find.byType(DropdownButton<String>),
        ),
      );
      expect(dropdown.items!.map((i) => i.value), ['', 'Ежедневные', 'Другое']);
      await choose(tester, 'Ежедневные');
      await click(tester, 'Сохранить');
      expect(repo.categories[1], same(oldChild));
      expect(
        CategoryTree(repo.categories).path(oldChild),
        'Ежедневные → Еда → Продукты',
      );
      await edit(tester, 'Ежедневные');
      expect(
        tester
            .widget<DropdownButton<String>>(
              find.descendant(
                of: find.byType(DropdownButtonFormField<String>).last,
                matching: find.byType(DropdownButton<String>),
              ),
            )
            .items!
            .map((i) => i.value),
        [''],
      );
      await click(tester, 'Отмена');
      await categoryAction(tester, 'Ежедневные', 'Архивировать');
      await click(tester, 'Сохранить');
      expect(find.text('В архиве вместе с категорией'), findsNWidgets(2));
      await edit(tester, 'Продукты');
      expect(find.textContaining('Ежедневные → Еда (в архиве'), findsWidgets);
      expect(repo.categories[1].isArchived, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
