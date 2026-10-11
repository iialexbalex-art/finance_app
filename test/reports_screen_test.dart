import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:finance_app/main.dart';
import 'package:finance_app/expense.dart';
import 'package:finance_app/report_model.dart';
import 'package:finance_app/reports_screen.dart';

import 'fake_auth.dart';
import 'fake_finance.dart';
import 'reports_test.dart' show reportFixture, reportEntry;

final captureKey = GlobalKey();
FakeFinance currentReportFixture() {
  final repo = reportFixture(), now = DateTime.now();
  repo.expenseRows['business'] = [
    reportEntry(
      'a',
      date: expenseDate(now),
      amount: '12345',
      comment: 'Оплата поставщику',
    ),
    reportEntry(
      'b',
      date: expenseDate(DateTime(now.year, now.month)),
      amount: '1000',
      category: '',
      comment: 'Операция без категории',
    ),
    reportEntry('usd', date: expenseDate(now), currency: 'USD', amount: '500'),
    reportEntry(
      'previous',
      date: expenseDate(DateTime(now.year, now.month - 1)),
      amount: '6000',
    ),
  ];
  repo.expenseRows['personal'] = [
    reportEntry('personal', date: expenseDate(now), amount: '98765'),
  ];
  repo.incomeLedger.expenseRows['business'] = [
    reportEntry('income', date: expenseDate(now), amount: '55500'),
  ];
  return repo;
}

Future<void> clickText(WidgetTester tester, String text) async {
  final finder = find.text(text).first;
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> capture(WidgetTester tester, String name) async {
  await tester.runAsync(() async {
    final boundary =
        captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory('build/reports_qa').createSync(recursive: true);
    File('build/reports_qa/$name.png')
        .writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> openApp(
  WidgetTester tester, {
  Size size = const Size(1440, 1000),
  FakeFinance? repository,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final auth = FakeAuth(signedIn: true);
  addTearDown(auth.dispose);
  await tester.pumpWidget(
    RepaintBoundary(
      key: captureKey,
      child: FinanceApp(
        auth: auth,
        repository: repository ?? currentReportFixture(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await clickText(tester, 'Отчёты');
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final systemFont = File('C:/Windows/Fonts/arial.ttf');
    if (systemFont.existsSync()) {
      final font = FontLoader('Roboto')
        ..addFont(
          Future.value(ByteData.sublistView(systemFont.readAsBytesSync())),
        );
      await font.load();
    }
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  testWidgets(
    'catalog, business quick report, drilldown, saved template, repeated menu reset',
    (tester) async {
      await openApp(tester);
      expect(find.text('Расходы бизнеса'), findsOneWidget);
      await capture(tester, 'catalog_desktop');
      await clickText(tester, 'Расходы бизнеса');
      expect(find.textContaining('Расходы: 133,45 RUB'), findsOneWidget);
      expect(find.textContaining('987,65 RUB'), findsNothing);
      await tester.ensureVisible(find.textContaining('Расходы: 133,45 RUB'));
      await capture(tester, 'business_desktop');
      await clickText(tester, 'Расходы: 133,45 RUB • 2 оп.');
      expect(find.byType(ReportDetailScreen), findsOneWidget);
      expect(
        find.textContaining('Итог выбранного агрегата: 133,45 RUB'),
        findsOneWidget,
      );
      expect(find.text('Оплата поставщику'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'поставщику');
      await tester.pumpAndSettle();
      expect(find.text('Операция без категории'), findsNothing);
      expect(
        find.textContaining('Результат поиска: 123,45 RUB'),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('По категории').last);
      await tester.pumpAndSettle();
      expect(find.text('Операция без категории'), findsOneWidget);
      await capture(tester, 'detail_desktop');
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Фильтры (0)'), findsOneWidget);
      await clickText(tester, 'Сохранить шаблон');
      await tester.enterText(find.byType(TextField), 'Ежемесячный бизнес');
      await clickText(tester, 'Сохранить');
      await clickText(tester, 'Отчёты');
      expect(find.text('Каталог отчётов'), findsNothing);
      expect(find.text('Ежемесячный бизнес'), findsOneWidget);
      await clickText(tester, 'Ежемесячный бизнес');
      expect(find.textContaining('Расходы: 133,45 RUB'), findsOneWidget);
      await capture(tester, 'saved_report_desktop');
      await clickText(tester, 'Каталог отчётов');
      await clickText(tester, 'Сравнение расходов за периоды');
      expect(find.textContaining('Период B:'), findsOneWidget);
      expect(find.textContaining('Разница A − B:'), findsOneWidget);
      await tester.ensureVisible(find.textContaining('Разница A − B:'));
      await capture(tester, 'comparison_desktop');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('every catalog report opens and exports action is present', (
    tester,
  ) async {
    await openApp(tester);
    for (final kind in ReportKind.values) {
      await clickText(tester, kind.label);
      expect(find.text('Экспорт'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull, reason: kind.label);
      await clickText(tester, 'Каталог отчётов');
    }
  });
  testWidgets(
    '375px mobile catalog, filters, drilldown and monthly days do not overflow',
    (tester) async {
      await openApp(tester, size: const Size(375, 900));
      await capture(tester, 'catalog_mobile');
      await clickText(tester, 'Расходы бизнеса');
      await tester.ensureVisible(find.text('Фильтры (0)'));
      await capture(tester, 'business_mobile');
      await clickText(tester, 'Фильтры (0)');
      expect(find.text('Фильтры отчёта'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await clickText(tester, 'Отмена');
      await clickText(tester, 'Расходы: 133,45 RUB • 2 оп.');
      await capture(tester, 'detail_mobile');
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await clickText(tester, 'Каталог отчётов');
      await clickText(tester, 'Расходы по месяцам');
      final month =
          '${DateTime.now().month.toString().padLeft(2, '0')}.${DateTime.now().year} (неполный)';
      await clickText(tester, month);
      expect(find.textContaining('Итог месяца:'), findsOneWidget);
      final day = russianExpenseDate(
        parseExpenseDate(expenseDate(DateTime.now())),
      );
      await clickText(tester, day);
      expect(find.byType(ReportDetailScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('error is distinct from empty state and retry recovers', (
    tester,
  ) async {
    final repo = currentReportFixture()
      ..onExpenses = ((_, _) async => throw StateError('offline'));
    await openApp(tester, repository: repo);
    await clickText(tester, 'Расходы бизнеса');
    expect(find.text('Повторить попытку'), findsOneWidget);
    expect(find.textContaining('Нет операций за'), findsNothing);
    repo.onExpenses = null;
    await clickText(tester, 'Повторить попытку');
    expect(find.textContaining('Расходы: 133,45 RUB'), findsOneWidget);
  });
  testWidgets('templates are isolated between users', (tester) async {
    SharedPreferences.setMockInitialValues({
      'report_templates_v1:other': '[{"name":"Чужой шаблон"}]',
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ReportsScreen(
              repository: FakeFinance(),
              spaces: const [businessSpace],
              userId: 'owner',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Чужой шаблон'), findsNothing);
    expect(find.text('Пока нет сохранённых шаблонов'), findsOneWidget);
  });
  testWidgets(
    'wallet and category filters reset when changing scope; title stays accurate',
    (tester) async {
      await openApp(tester);
      await clickText(tester, 'Расходы бизнеса');
      await clickText(tester, 'Фильтры (0)');
      await clickText(tester, 'Архивный счёт · RUB (архив)');
      await clickText(tester, 'Расходы: Бизнес');
      await clickText(tester, 'Применить');
      expect(find.text('Фильтры (2)'), findsOneWidget);
      expect(find.textContaining('Расходы: 123,45 RUB'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('Пространство:business')),
      );
      await tester.tap(find.byKey(const ValueKey('Пространство:business')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Личное').last);
      await tester.pumpAndSettle();
      expect(find.text('Личные расходы'), findsOneWidget);
      expect(find.text('Фильтры (0)'), findsOneWidget);
      expect(find.textContaining('Расходы: 987,65 RUB'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('late report response cannot replace a newer period', (
    tester,
  ) async {
    final pending = Completer<ExpensePage>();
    final repo = currentReportFixture();
    var calls = 0;
    repo.onExpenses = (space, cursor) async {
      if (calls++ == 0) return pending.future;
      return ExpensePage([
        reportEntry(
          'latest-$space',
          date: expenseDate(DateTime.now()),
          amount: '100',
        ),
      ], false);
    };
    await openApp(tester, repository: repo);
    await tester.ensureVisible(find.text('Расходы бизнеса'));
    await tester.tap(find.text('Расходы бизнеса'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('Период:ReportPeriod.month')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Сегодня').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('Расходы: 1,00 RUB'), findsOneWidget);
    pending.complete(
      ExpensePage([
        reportEntry(
          'obsolete',
          date: expenseDate(DateTime.now()),
          amount: '99999',
        ),
      ], false),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('999,99'), findsNothing);
    expect(find.textContaining('Расходы: 1,00 RUB'), findsOneWidget);
  });
  testWidgets(
    'custom group filters, cancel, unique aggregate and template rename/delete',
    (tester) async {
      await openApp(tester);
      await clickText(tester, 'Настраиваемый отчёт');
      await clickText(tester, 'Добавить группу');
      await tester.enterText(find.byType(TextField), 'Бизнес группа');
      await clickText(tester, 'Сохранить');
      await clickText(tester, 'Отмена');
      expect(find.textContaining('Группы неаддитивны'), findsNothing);
      await clickText(tester, 'Добавить группу');
      await tester.enterText(find.byType(TextField), 'Бизнес группа');
      await clickText(tester, 'Сохранить');
      await tester.tap(find.byKey(const ValueKey('Пространство группы:all')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Бизнес').last);
      await tester.pumpAndSettle();
      await clickText(tester, 'Применить');
      expect(find.textContaining('Группы неаддитивны'), findsOneWidget);
      expect(find.textContaining('Уникальный итог:'), findsWidgets);
      await clickText(tester, 'Сохранить шаблон');
      await tester.enterText(find.byType(TextField), 'Группы месяца');
      await clickText(tester, 'Сохранить');
      await clickText(tester, 'Каталог отчётов');
      final menu = find.byType(PopupMenuButton<String>).last;
      await tester.ensureVisible(menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await clickText(tester, 'Переименовать');
      await tester.enterText(find.byType(TextField), 'Группы бизнеса');
      await clickText(tester, 'Сохранить');
      expect(find.text('Группы бизнеса'), findsOneWidget);
      expect(find.text('Группы месяца'), findsNothing);
      await tester.ensureVisible(menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await clickText(tester, 'Удалить шаблон');
      expect(find.text('Группы бизнеса'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
