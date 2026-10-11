import 'dart:convert';

import 'package:finance_app/finance_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('Uses session token, scoped SELECT and only permitted wallet INSERT columns', () async {
    final requests = <http.Request>[];
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-publishable-key',
      accessToken: () async => 'test-user-session-token',
      httpClient: MockClient((request) async {
        requests.add(request);
        if (request.method == 'POST') {
          return http.Response('', 201, request: request);
        }
        return http.Response(
          jsonEncode(
            request.url.path.endsWith('/spaces')
                ? [
                    {
                      'id': 'space',
                      'owner_user_id': 'user',
                      'name': 'Бизнес',
                      'kind': 'business',
                    },
                  ]
                : [
                    {
                      'id': 'wallet',
                      'space_id': 'space',
                      'name': 'Касса',
                      'wallet_group': 'cash',
                      'currency': 'KZT',
                      'currency_scale': 2,
                    },
                  ],
          ),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    addTearDown(client.dispose);
    final repository = SupabaseFinanceRepository(client);
    expect((await repository.loadSpaces()).single.ownerUserId, 'user');
    expect(
      (await repository.loadWallets('space')).single.group,
      WalletGroup.cash,
    );
    await repository.createWallet(
      spaceId: 'space',
      name: 'Касса',
      group: WalletGroup.cash,
      currency: 'KZT',
    );
    expect(requests.length, 3);
    expect(requests[0].url.path, '/rest/v1/spaces');
    expect(
      requests[0].url.queryParameters.containsKey('owner_user_id'),
      isFalse,
    );
    expect(requests[1].url.queryParameters['space_id'], 'eq.space');
    expect(
      requests[1].url.queryParameters['select'],
      'id,space_id,name,wallet_group,currency,currency_scale,icon_id,sort_order,is_archived,revision',
    );
    expect(requests[2].url.path, '/rest/v1/wallets');
    expect(jsonDecode(requests[2].body), {
      'space_id': 'space',
      'name': 'Касса',
      'wallet_group': 'cash',
      'currency': 'KZT',
      'currency_scale': 2,
    });
    for (final request in requests) {
      expect(
        request.headers['authorization'],
        'Bearer test-user-session-token',
      );
      expect(request.url.path, isNot(contains('balance')));
    }
  });
}
