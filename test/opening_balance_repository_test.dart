import 'dart:convert';

import 'package:finance_app/finance_repository.dart';
import 'package:finance_app/money.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test(
    'Bigint read/insert/update stays string across JSON, with narrow PATCH',
    () async {
      final requests = <http.Request>[];
      final values = <Object>[
        [],
        [
          {'amount_minor': '0'},
        ],
        [
          {'amount_minor': '9007199254740993'},
        ],
        {'amount_minor': maxMinor.toString()},
        {'amount_minor': minMinor.toString()},
        [
          {'amount_minor': 1},
        ],
      ];
      final client = SupabaseClient(
        'https://example.supabase.co',
        'test-key',
        accessToken: () async => 'session-token',
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode(values.removeAt(0)),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      addTearDown(client.dispose);
      final repository = SupabaseFinanceRepository(client);
      expect(await repository.loadOpeningBalance('wallet'), isNull);
      expect(await repository.loadOpeningBalance('wallet'), BigInt.zero);
      expect(
        (await repository.loadOpeningBalance('wallet')).toString(),
        '9007199254740993',
      );
      expect(
        await repository.saveOpeningBalance('wallet', maxMinor, previous: null),
        maxMinor,
      );
      expect(
        await repository.saveOpeningBalance(
          'wallet',
          minMinor,
          previous: maxMinor,
        ),
        minMinor,
      );
      await expectLater(
        repository.loadOpeningBalance('wallet'),
        throwsFormatException,
      );
      for (final request in requests) {
        expect(request.url.path, '/rest/v1/wallet_opening_balances');
        expect(request.url.queryParameters['select'], 'amount_minor::text,revision');
        expect(request.headers['authorization'], 'Bearer session-token');
      }
      expect(requests.first.url.queryParameters['wallet_id'], 'eq.wallet');
      expect(requests[3].method, 'POST');
      expect(jsonDecode(requests[3].body), {
        'wallet_id': 'wallet',
        'amount_minor': '9223372036854775807',
      });
      expect(requests[4].method, 'PATCH');
      expect(jsonDecode(requests[4].body), {
        'amount_minor': '-9223372036854775808',
      });
      expect(requests[4].url.queryParameters['wallet_id'], 'eq.wallet');
      expect(
        requests[4].url.queryParameters['amount_minor'],
        'eq.9223372036854775807',
      );
    },
  );
}
