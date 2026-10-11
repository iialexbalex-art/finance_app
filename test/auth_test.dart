import 'package:finance_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'fake_auth.dart';
import 'fake_finance.dart';

void main() {
  for (final size in [const Size(320, 568), const Size(1440, 900)]) {
    testWidgets('Sign in, errors and sign out at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = FakeAuth();
      addTearDown(auth.dispose);
      await tester.pumpWidget(
        FinanceApp(auth: auth, repository: FakeFinance()),
      );
      await tester.pumpAndSettle();
      expect(find.text('Вход в приложение'), findsOneWidget);
      expect(find.text('Обзор'), findsNothing);

      await tester.ensureVisible(find.text('Войти'));
      await tester.tap(find.text('Войти'));
      await tester.pumpAndSettle();
      expect(find.text('Введите email.'), findsOneWidget);
      expect(find.text('Введите пароль.'), findsOneWidget);
      expect(auth.attempts, 0);

      await tester.enterText(
        find.byType(TextFormField).at(0),
        ' user@example.com ',
      );
      await tester.enterText(
        find.byType(TextFormField).at(1),
        ' password with spaces ',
      );
      auth.error = const AuthApiException(
        'Invalid login credentials',
        code: 'invalid_credentials',
        statusCode: '400',
      );
      await tester.ensureVisible(find.text('Войти'));
      await tester.tap(find.text('Войти'));
      await tester.pumpAndSettle();
      expect(find.text('Неверный email или пароль.'), findsOneWidget);
      expect(find.text('Обзор'), findsNothing);
      expect(auth.email, 'user@example.com');
      expect(auth.password, ' password with spaces ');
      expect(tester.takeException(), isNull);

      auth.error = null;
      await tester.ensureVisible(find.text('Войти'));
      await tester.tap(find.text('Войти'));
      await tester.pumpAndSettle();
      expect(find.text('Текущие учётные остатки'), findsOneWidget);
      expect(find.text('Вход в приложение'), findsNothing);

      auth.error = AuthRetryableFetchException(message: 'Network error');
      await tester.tap(find.text('Выйти'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Проверьте интернет'), findsOneWidget);
      expect(auth.isSignedIn, isTrue);

      auth.error = null;
      await tester.tap(find.text('Выйти'));
      await tester.pumpAndSettle();
      expect(find.text('Вход в приложение'), findsOneWidget);
      expect(find.text('Обзор'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Missing configuration does not reveal app sections', (
    tester,
  ) async {
    await tester.pumpWidget(const FinanceApp());
    expect(find.text('Подключение не настроено.'), findsOneWidget);
    expect(find.text('Обзор'), findsNothing);
  });
}
