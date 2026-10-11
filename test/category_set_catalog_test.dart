import 'dart:convert';

import 'package:finance_app/wallet_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'category sets and personal pack have 299 unique local assets',
    () async {
      expect(photorealCategoryIconCatalog, hasLength(299));
      expect(
        photorealCategoryIconCatalog.where((c) => c.id.startsWith('cat_exp_')),
        hasLength(130),
      );
      expect(
        photorealCategoryIconCatalog.where((c) => c.id.startsWith('cat_inc_')),
        hasLength(16),
      );
      expect(
        photorealCategoryIconCatalog.map((c) => c.id).toSet(),
        hasLength(299),
      );
      expect(
        photorealCategoryIconCatalog.map((c) => c.asset).toSet(),
        hasLength(299),
      );
      expect(
        photorealCategoryIconCatalog.where((c) => c.label == 'Наставничество'),
        hasLength(2),
      );
      final hashes = <String>{};
      for (final choice in photorealCategoryIconCatalog) {
        expect(choice.id, matches(RegExp(r'^[a-z][a-z0-9_-]{0,95}$')));
        final data = await rootBundle.load(choice.asset);
        expect(data.lengthInBytes, greaterThan(5000), reason: choice.id);
        hashes.add(base64Encode(data.buffer.asUint8List()));
      }
      expect(hashes, hasLength(299));
      expect(resolveCategoryIcon('cat_exp_food').label, 'Еда');
      expect(
        resolveCategoryIcon('cat_inc_agent_counterparty').label,
        'Агентское вознаграждение за Контрагента',
      );
      expect(resolveCategoryIcon('legacy-or-unknown').id, 'category');
    },
  );

  testWidgets('picker searches synonyms and shows 72px preview lazily', (
    t,
  ) async {
    await t.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => t.binding.setSurfaceSize(null));
    String? result;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CategoryIconField(
            value: 'cat_exp_food',
            onChanged: (value) => result = value,
          ),
        ),
      ),
    );
    await t.tap(find.byType(CategoryIconField));
    await t.pumpAndSettle();
    expect(find.text('Выбран: Еда'), findsOneWidget);
    expect(
      find.byWidgetPredicate((w) => w is CatalogMark && w.size == 72),
      findsWidgets,
    );
    await t.enterText(
      find.widgetWithText(TextField, 'Поиск значка'),
      'нейросеть',
    );
    await t.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('choose-icon:cat_exp_gpt_ai')),
      findsOneWidget,
    );
    await t.tap(find.byKey(const ValueKey('choose-icon:cat_exp_gpt_ai')));
    await t.pumpAndSettle();
    expect(result, 'cat_exp_gpt_ai');
    expect(t.takeException(), isNull);
  });
}

