import 'dart:io';

import 'package:finance_app/category.dart';
import 'package:finance_app/wallet_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'expense_filters_test.dart' show capture;
import 'incomes_transfers_test.dart' show open, prepared;
import 'wallet_identity_test.dart' show cashFlow, navigate;

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
      'Pilot photoreal assets in real category picker and history $size',
      (t) async {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final repo = prepared();
        final expenseCategory = repo.categories.firstWhere(
          (c) => c.id == 'groceries',
        );
        final incomeCategory = repo.categories.firstWhere(
          (c) => c.id == 'bonus',
        );
        await repo.editCategory(expenseCategory, iconId: 'cat_exp_food');
        await repo.editCategory(
          incomeCategory,
          name: 'Агентское вознаграждение за Контрагента',
          iconId: 'cat_inc_agent_counterparty',
        );
        repo.commitExpense(cashFlow('Еда для проверки', expenseCategory.id));
        repo.incomeLedger.commitExpense(
          cashFlow('Агентское вознаграждение', incomeCategory.id),
        );
        await open(t, repo, 'Расходы');
        await t.ensureVisible(find.text('Еда для проверки'));
        await t.pumpAndSettle();
        expect(
          find.byWidgetPredicate(
            (w) => w is CategoryMark && w.id == 'cat_exp_food',
          ),
          findsWidgets,
        );
        await capture(t, 'photoreal-expense-${size.width.toInt()}');
        await navigate(t, 'Доходы');
        await t.ensureVisible(find.text('Агентское вознаграждение'));
        await t.pumpAndSettle();
        expect(
          find.byWidgetPredicate(
            (w) => w is CategoryMark && w.id == 'cat_inc_agent_counterparty',
          ),
          findsWidgets,
        );
        await capture(t, 'photoreal-income-${size.width.toInt()}');
        await navigate(t, 'Категории');
        final incomeTab = find.descendant(
          of: find.byType(TabBar),
          matching: find.text(CategoryKind.income.label),
        );
        await t.tap(incomeTab);
        await t.pumpAndSettle();
        await t.tap(find.text('Добавить категорию'));
        await t.pumpAndSettle();
        await t.tap(find.byType(CategoryIconField));
        await t.pumpAndSettle();
        expect(find.text('Выбран: Без специального значка'), findsOneWidget);
        await t.enterText(
          find.widgetWithText(TextField, 'Поиск значка'),
          'агент контрагент',
        );
        await t.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('choose-icon:cat_inc_agent_counterparty')),
          findsOneWidget,
        );
        if (const bool.fromEnvironment('CAPTURE_QA')) {
          await capture(t, 'photoreal-picker-${size.width.toInt()}');
        }
        expect(t.takeException(), isNull);
      },
    );
  }
}
