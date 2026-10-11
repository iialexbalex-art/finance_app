import 'dart:convert';

import 'package:finance_app/expense.dart';
import 'package:finance_app/expense_draft_store.dart';
import 'package:finance_app/finance_repository.dart';
import 'package:finance_app/money.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

PendingExpense draft({String? id}) => PendingExpense(
  requestId: id ?? newExpenseRequestId(),
  spaceId: 'space',
  walletId: 'wallet',
  categoryId: 'category',
  amountMinor: '9007199254740993',
  date: '2026-09-30',
  comment: 'Тест',
  currency: 'RUB',
  scale: 2,
  walletName: 'Касса',
  categoryPath: 'Ежедневные → Еда → Продукты',
);

void main() {
  for (final entry in {
    '1234,56': '123456',
    '0.01': '1',
    '90071992547409,93': '9007199254740993',
    '92233720368547758.07': '9223372036854775807',
  }.entries) {
    test(
      'Exact positive expense ${entry.key}',
      () => expect(
        parseExpenseMoney(entry.key, scale: 2).toString(),
        entry.value,
      ),
    );
  }
  for (final value in [
    '0',
    '-1',
    '1,234',
    '1e3',
    'NaN',
    '92233720368547758.08',
  ]) {
    test(
      'Reject expense $value',
      () => expect(
        () => parseExpenseMoney(value, scale: 2),
        throwsFormatException,
      ),
    );
  }
  test('Currency scale and unbounded negative aggregate', () {
    expect(parseExpenseMoney('12', scale: 0), BigInt.from(12));
    expect(() => parseExpenseMoney('1.1', scale: 0), throwsFormatException);
    expect(parseExpenseMoney('1,2345', scale: 4), BigInt.from(12345));
    expect(
      formatExactMoney(aggregateFromJson('-27670116110564327422')),
      '-276701161105643274,22',
    );
    expect(() => aggregateFromJson(9007199254740992), throwsFormatException);
    expect(() => parseExpenseDate('2026-02-30'), throwsFormatException);
    expect(expenseDate(parseExpenseDate('2024-02-29')), '2024-02-29');
  });
  test(
    'Stable journal payload scoped by account and space survives roundtrip',
    () async {
      final store = MemoryExpenseDraftStore();
      final p = draft();
      await store.write(
        'owner',
        PendingExpense.fromJson(
          jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>,
        ),
      );
      expect((await store.read('owner', 'space'))!.params, p.params);
      expect(await store.read('manager', 'space'), isNull);
      expect(await store.read('owner', 'other'), isNull);
      await store.clear('owner', 'space', requestId: 'different');
      expect(await store.read('owner', 'space'), isNotNull);
      await store.clear('owner', 'space', requestId: p.requestId);
      expect(await store.read('owner', 'space'), isNull);
      expect(
        p.requestId,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
    },
  );
  test(
    'RPC string money, no author parameter, keyset pagination and exact totals',
    () async {
      final requests = <http.Request>[];
      final client = SupabaseClient(
        'https://example.supabase.co',
        'publishable-test',
        accessToken: () async => 'session',
        httpClient: MockClient((req) async {
          requests.add(req);
          Object body;
          if (req.url.path.endsWith('/create_expense')) {
            body = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
          } else if (req.url.path.endsWith('/wallet_expense_balance')) {
            body = {
              'opening_minor': null,
              'expense_minor': '18446744073709551614',
              'current_minor': '-18446744073709551614',
            };
          } else {
            body = List.generate(
              26,
              (i) => {
                'id':
                    'aaaaaaaa-aaaa-4aaa-8aaa-${i.toString().padLeft(12, '0')}',
                'expense_date': '2026-09-30',
                'wallet_id': 'wallet',
                'category_id': 'category',
                'revision': 'revision',
                'amount_minor': '9007199254740993',
                'currency': 'RUB',
                'currency_scale': 2,
                'wallet_name': 'Касса',
                'category_path': 'Еда',
                'comment': '',
              },
            );
          }
          return http.Response(
            jsonEncode(body),
            200,
            headers: {'content-type': 'application/json'},
            request: req,
          );
        }),
      );
      addTearDown(client.dispose);
      final repo = SupabaseFinanceRepository(client);
      final p = draft();
      await repo.createExpense(p);
      await repo.createExpense(p);
      final page = await repo.loadExpenses('space');
      expect(page.items.length, 25);
      expect(page.hasMore, isTrue);
      await repo.loadExpenses('space', before: page.items.last);
      expect(page.items.first.amount.toString(), '9007199254740993');
      final balance = await repo.loadExpenseBalance('wallet');
      expect(balance.current.toString(), '-18446744073709551614');
      expect(requests[0].body, requests[1].body);
      expect(jsonDecode(requests[0].body), p.params);
      expect(jsonDecode(requests[0].body).containsKey('author_id'), isFalse);
      expect(requests[2].url.queryParameters['space_id'], 'eq.space');
      expect(
        requests[2].url.queryParameters['select'],
        contains('amount_minor::text'),
      );
      expect(
        requests[2].url.queryParameters['order'],
        'expense_date.desc.nullslast,id.desc.nullslast',
      );
      expect(
        requests[3].url.queryParameters['or'],
        contains('id.lt.${page.items.last.id}'),
      );
      for (final req in requests) {
        expect(req.headers['authorization'], 'Bearer session');
      }
    },
  );
}
