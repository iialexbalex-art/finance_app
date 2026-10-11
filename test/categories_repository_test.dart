import 'dart:convert';

import 'package:finance_app/category.dart';
import 'package:finance_app/finance_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('Scoped category requests use session and minimal columns with conflict detection', () async {
    final requests = <http.Request>[];
    final row = {
      'id': 'child',
      'space_id': 'business',
      'kind': 'expense',
      'name': 'Аренда',
      'parent_id': 'root',
      'is_archived': false,
      'icon_id': 'home',
    };
    final client = SupabaseClient(
      'https://example.supabase.co',
      'publishable-test',
      accessToken: () async => 'user-session',
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode(request.method == 'GET' ? [row] : row),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    addTearDown(client.dispose);
    final repo = SupabaseFinanceRepository(client);
    final loaded = (await repo.loadCategories(
      'business',
      CategoryKind.expense,
    )).single;
    expect(loaded.parentId, 'root');
    await repo.createCategory(
      'business',
      CategoryKind.expense,
      'Аренда',
      'root',
      iconId: 'home',
    );
    await repo.editCategory(loaded, name: 'Офис', iconId: 'office');
    await repo.editCategory(loaded, archived: true);
    expect(requests.first.url.queryParameters['space_id'], 'eq.business');
    expect(requests.first.url.queryParameters['kind'], 'eq.expense');
    expect(jsonDecode(requests[1].body), {
      'space_id': 'business',
      'kind': 'expense',
      'name': 'Аренда',
      'parent_id': 'root',
      'icon_id': 'home',
    });
    expect(jsonDecode(requests[2].body), {'name': 'Офис', 'icon_id': 'office'});
    expect(jsonDecode(requests[3].body), {'is_archived': true});
    for (final req in requests.skip(2)) {
      expect(req.url.queryParameters['id'], 'eq.child');
      expect(req.url.queryParameters['space_id'], 'eq.business');
      expect(req.url.queryParameters['kind'], 'eq.expense');
      expect(req.url.queryParameters['name'], 'eq.Аренда');
      expect(req.url.queryParameters['is_archived'], 'eq.false');
      expect(req.url.queryParameters['icon_id'], 'eq.home');
    }
    for (final req in requests) {
      expect(req.url.path, '/rest/v1/categories');
      expect(req.headers['authorization'], 'Bearer user-session');
    }
  });
}
