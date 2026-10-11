import 'dart:convert';

import 'package:finance_app/category.dart';
import 'package:finance_app/finance_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'fake_auth.dart';
import 'fake_finance.dart';
import 'categories_screen_test.dart' show click, open, expandAll;

FinanceCategory category(String id, {String? parent, bool archived = false}) =>
    FinanceCategory(
      id: id,
      spaceId: 'personal',
      kind: CategoryKind.expense,
      name: id,
      parentId: parent,
      isArchived: archived,
    );

Future<void> edit(WidgetTester tester, String name) async {
  await expandAll(tester);
  final row = find
      .ancestor(of: find.text(name), matching: find.byType(Row))
      .first;
  final menu = find.descendant(
    of: row,
    matching: find.byWidgetPredicate((w) => w is PopupMenuButton),
  );
  await tester.ensureVisible(menu);
  await tester.tap(menu);
  await tester.pumpAndSettle();
  await click(tester, 'Редактировать');
}

Future<void> choose(WidgetTester tester, String name) async {
  final field = find.byType(DropdownButtonFormField<String>).last;
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.pumpAndSettle();
  await click(tester, name);
}

void main() {
  for (final size in [const Size(320, 568), const Size(1440, 900)]) {
    testWidgets('Move existing archived ID root-child-other-root at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = FakeAuth(signedIn: true);
      addTearDown(auth.dispose);
      final repo = FakeFinance()
        ..categories.addAll([
          category('Еда', archived: true),
          category('Ежедневные'),
          category('Другой'),
          category('Архив', archived: true),
          category('Вложенная', parent: 'Другой'),
        ]);
      await open(tester, repo, auth);
      for (final parent in [
        'Ежедневные',
        'Другой',
        'Без родительской категории',
      ]) {
        await edit(tester, 'Еда');
        final field = tester.widget<DropdownButton<String>>(
          find.descendant(
            of: find.byType(DropdownButtonFormField<String>).last,
            matching: find.byType(DropdownButton<String>),
          ),
        );
        expect(field.items!.map((item) => item.value), [
          '',
          'Ежедневные',
          'Другой',
          'Вложенная',
        ]);
        await choose(tester, parent);
        await click(tester, 'Сохранить');
        final saved = repo.categories.firstWhere((item) => item.id == 'Еда');
        expect(
          saved.parentId,
          parent == 'Без родительской категории' ? null : parent,
        );
        expect(saved.isArchived, isTrue);
        expect(repo.categories.length, 5);
        expect(find.text('Еда'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets(
    'Subtree move is available; archived current parent stays visible',
    (tester) async {
      final auth = FakeAuth(signedIn: true);
      addTearDown(auth.dispose);
      final repo = FakeFinance()
        ..categories.addAll([
          category('Архив', archived: true),
          category('Еда', parent: 'Архив'),
          category('Новый'),
        ]);
      await open(tester, repo, auth);
      await edit(tester, 'Архив');
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byType(DropdownButtonFormField<String>).last,
            )
            .onChanged,
        isNotNull,
      );
      expect(find.textContaining('Ветвь переносится'), findsOneWidget);
      await click(tester, 'Отмена');
      await edit(tester, 'Еда');
      final field = tester.widget<DropdownButtonFormField<String>>(
        find.byType(DropdownButtonFormField<String>).last,
      );
      expect(field.initialValue, 'Архив');
      expect(
        tester
            .widget<DropdownButton<String>>(
              find.descendant(
                of: find.byType(DropdownButtonFormField<String>).last,
                matching: find.byType(DropdownButton<String>),
              ),
            )
            .items!
            .firstWhere((item) => item.value == 'Архив')
            .enabled,
        isFalse,
      );
      await tester.enterText(find.byType(TextFormField), 'Продукты');
      await click(tester, 'Сохранить');
      expect(
        repo.categories.firstWhere((item) => item.id == 'Еда').parentId,
        'Архив',
      );
      await edit(tester, 'Продукты');
      await choose(tester, 'Новый');
      repo.onCategorySave = () async =>
          throw const PostgrestException(message: 'archived', code: '23514');
      await click(tester, 'Сохранить');
      expect(
        find.textContaining('Создание или перенос недоступны'),
        findsOneWidget,
      );
      expect(
        repo.categories.firstWhere((item) => item.id == 'Еда').parentId,
        'Архив',
      );
    },
  );

  test(
    'PATCH parent preserves ID/archive and compares old parent including NULL',
    () async {
      final requests = <http.Request>[];
      final client = SupabaseClient(
        'https://example.supabase.co',
        'publishable-test',
        accessToken: () async => 'session',
        httpClient: MockClient((req) async {
          requests.add(req);
          return http.Response(
            jsonEncode({
              'id': 'food',
              'space_id': 'personal',
              'kind': 'expense',
              'name': 'food',
              'parent_id': jsonDecode(req.body)['parent_id'],
              'is_archived': true,
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: req,
          );
        }),
      );
      addTearDown(client.dispose);
      final repo = SupabaseFinanceRepository(client);
      await repo.editCategory(
        category('food', archived: true),
        changeParent: true,
        parentId: 'daily',
      );
      await repo.editCategory(
        category('food', parent: 'daily', archived: true),
        changeParent: true,
        parentId: 'other',
      );
      await repo.editCategory(
        category('food', parent: 'other', archived: true),
        changeParent: true,
        parentId: null,
      );
      expect(requests.map((req) => jsonDecode(req.body)), [
        {'parent_id': 'daily'},
        {'parent_id': 'other'},
        {'parent_id': null},
      ]);
      expect(requests.map((req) => req.url.queryParameters['parent_id']), [
        'is.null',
        'eq.daily',
        'eq.other',
      ]);
      for (final req in requests) {
        expect(req.method, 'PATCH');
        expect(req.url.queryParameters['id'], 'eq.food');
        expect(req.url.queryParameters['kind'], 'eq.expense');
        expect(req.url.queryParameters['is_archived'], 'eq.true');
        expect(req.headers['authorization'], 'Bearer session');
      }
    },
  );
}
