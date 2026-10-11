import 'package:finance_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_auth.dart';
import 'fake_finance.dart';

void main() {
  for (final size in [const Size(320, 568), const Size(1440, 900)]) {
    testWidgets('Navigation and empty states at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final auth = FakeAuth(signedIn: true);
      addTearDown(auth.dispose);
      await tester.pumpWidget(
        FinanceApp(auth: auth, repository: FakeFinance()),
      );
      await tester.pumpAndSettle();
      expect(find.text('Финансы'), findsOneWidget);
      expect(find.text('Текущие учётные остатки'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(find.text('Перейти к кошелькам'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Перейти к кошелькам'));
      await tester.pumpAndSettle();
      for (final label in ['Наличные', 'Счета', 'Карты']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('Кошельков пока нет'), findsNWidgets(3));
      await tester.ensureVisible(find.text('Карты'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Расходы'));
      await tester.pumpAndSettle();
      expect(find.text('По выбранным фильтрам расходов нет'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Обзор'));
      await tester.pumpAndSettle();
      expect(find.text('Текущие учётные остатки'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
