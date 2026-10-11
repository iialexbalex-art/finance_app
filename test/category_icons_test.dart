import 'dart:io';

import 'package:finance_app/category.dart';
import 'package:finance_app/wallet_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'categories_screen_test.dart' show click;
import 'expense_filters_test.dart' show capture;
import 'incomes_transfers_test.dart' show prepared, open, enter;
import 'wallet_identity_test.dart' show tab, navigate;

Future<void> choose(WidgetTester t, String id, String query) async {
  final field = find.byType(CategoryIconField);
  await t.ensureVisible(field);
  await t.tap(field);
  await t.pumpAndSettle();
  await t.enterText(find.widgetWithText(TextField, 'Поиск значка'), query);
  await t.pumpAndSettle();
  await t.tap(find.byKey(ValueKey('choose-icon:$id')));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    if (const bool.fromEnvironment('CAPTURE_QA')) {
      await (FontLoader('Roboto')..addFont(
            File('C:/Windows/Fonts/arial.ttf')
                .readAsBytes()
                .then(ByteData.sublistView),
          ))
          .load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });
  for (final size in [const Size(320, 568), const Size(1440, 900)]) {
    testWidgets(
      'Icons create/edit at all three levels of both category trees $size',
      (t) async {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final repo = prepared()..categories.clear();
        await open(t, repo, 'Категории');
        for (final kind in CategoryKind.values) {
          await tab(t, kind.label);
          String? parent;
          for (var level = 0; level < 3; level++) {
            await click(
              t,
              level == 0 ? 'Добавить категорию' : 'Добавить подкатегорию',
            );
            await enter(
              t,
              'Название категории',
              '${kind.label} уровень ${level + 1} с длинным названием',
            );
            final id = [
              'cat_exp_cafe_restaurant',
              'cat_exp_fuel',
              'cat_exp_air_tickets',
            ][level];
            await choose(t, id, ['кафе', 'бензин', 'самолёт'][level]);
            await click(t, 'Сохранить');
            final row = repo.categories.last;
            expect(row.kind, kind);
            expect(row.iconId, id);
            expect(row.parentId, parent);
            parent = row.id;
          }
          final before = repo.categories.last;
          await click(t, 'Редактировать');
          await choose(t, 'cat_exp_dentist', 'стоматолог');
          await click(t, 'Сохранить');
          final after = repo.categories.last;
          expect(after.id, before.id);
          expect(after.name, before.name);
          expect(after.parentId, before.parentId);
          expect(after.kind, before.kind);
          expect(after.iconId, 'cat_exp_dentist');
          for (final id in [
            'cat_exp_cafe_restaurant',
            'cat_exp_fuel',
            'cat_exp_dentist',
          ]) {
            expect(
              find.byWidgetPredicate((w) => w is CategoryMark && w.id == id),
              findsOneWidget,
            );
          }
          await capture(
            t,
            'category-icons-${kind.value}-${size.width.toInt()}',
          );
        }
        await navigate(t, 'Кошельки');
        await navigate(t, 'Категории');
        expect(
          find.byWidgetPredicate(
            (w) => w is CategoryMark && w.id == 'cat_exp_dentist',
          ),
          findsOneWidget,
        );
        expect(t.takeException(), isNull);
      },
    );
  }
}
