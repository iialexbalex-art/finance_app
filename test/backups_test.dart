import 'package:finance_app/backup_service.dart';
import 'package:finance_app/backups_screen.dart';
import 'package:finance_app/finance_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'dart:convert';

class UnusedSupabaseClient implements SupabaseClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeBackups extends BackupService {
  FakeBackups(super.client);
  final calls = <String>[];
  @override
  bool get configured => true;
  final preview = {
    'id': 'snapshot',
    'captured_at': '2026-10-06T18:59:00Z',
    'counts': {'wallets': 2, 'categories': 3},
    'files': 4,
    'scope': ['Личное', 'Бизнес'],
    'warning': 'Более поздние записи будут заменены.',
  };
  @override
  Future<dynamic> request(
    String path, {
    Map<String, dynamic>? body,
    bool delete = false,
  }) async {
    calls.add(path);
    if (path == '/status') {
      return {
        'storage': 'Тестовое хранилище',
        'independent': false,
        'next_run': '2026-10-07T18:59:00Z',
        'stale': false,
        'last_ready': {'captured_at': '2026-10-06T18:59:00Z'},
        'jobs': [
          {
            'id': 'snapshot',
            'kind': 'manual',
            'state': 'ready',
            'captured_at': '2026-10-06T18:59:00Z',
            'comment': 'Проверенная копия',
            'new_bytes': 120,
            'export_bytes': 1024,
          },
        ],
      };
    }
    if (path == '/history') return [];
    if (path.endsWith('/preview')) return preview;
    return {'id': 'snapshot', 'state': 'ready'};
  }

  @override
  Future<void> restore(String id) async {
    calls.add('restore:$id');
  }

  @override
  Future<Map<String, dynamic>?> importFile() async => preview;
}

void main() {
  test('Backup dates are UTC+5 regardless of browser timezone', () {
    expect(backupLocalTime('2026-10-06T18:59:00Z'), '06.10.2026 23:59:00');
    expect(backupLocalTime('2026-10-06T20:00:00Z'), '07.10.2026 01:00:00');
  });
  for (final width in [320.0, 1100.0]) {
    testWidgets('Manual backup and confirmed restore at $width', (t) async {
      final client = UnusedSupabaseClient();
      final service = FakeBackups(client);
      var refreshed = 0;
      t.view.physicalSize = Size(width, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: BackupsScreen(
                service: service,
                onRestored: () => refreshed++,
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(
        find.text('Независимое хранилище не подтверждено.'),
        findsOneWidget,
      );
      expect(find.textContaining('06.10.2026 23:59:00'), findsWidgets);
      await t.tap(find.text('Сохранить сейчас'));
      await t.pumpAndSettle();
      expect(service.calls, contains('/capture'));
      await t.ensureVisible(find.text('Восстановить'));
      await t.tap(find.text('Восстановить'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Восстановить выбранную копию?'), findsOneWidget);
      expect(service.calls.where((s) => s.startsWith('restore:')), isEmpty);
      await t.tap(find.text('Отмена'));
      await t.pumpAndSettle();
      expect(refreshed, 0);
      await t.tap(find.text('Восстановить'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      await t.tap(find.widgetWithText(FilledButton, 'Восстановить'));
      await t.pumpAndSettle();
      expect(service.calls, contains('restore:snapshot'));
      expect(refreshed, 1);
      expect(t.takeException(), isNull);
    });
  }
  test(
    'Wallet and opening-balance writes carry expected server revisions',
    () async {
      final requests = <http.Request>[];
      final client = SupabaseClient(
        'https://example.supabase.co',
        'public-test',
        httpClient: MockClient((r) async {
          requests.add(r);
          final body = r.url.path.endsWith('/wallet_opening_balances')
              ? [
                  {
                    'amount_minor': '9007199254740993',
                    'revision': 'balance-revision',
                  },
                ]
              : r.url.path.endsWith('/wallets')
              ? [
                  {
                    'id': 'wallet',
                    'space_id': 'space',
                    'name': 'Wallet',
                    'wallet_group': 'cash',
                    'currency': 'RUB',
                    'currency_scale': 2,
                    'revision': 'wallet-revision',
                  },
                ]
              : {'amount_minor': '42', 'revision': 'new-balance-revision'};
          return http.Response(
            jsonEncode(body),
            200,
            request: r,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(client.dispose);
      final repo = SupabaseFinanceRepository(client);
      final wallet = (await repo.loadWallets('space')).single;
      await repo.editWallet(wallet, 'New', WalletGroup.cash);
      expect(requests.last.url.path, '/rest/v1/rpc/backup_write');
      expect(jsonDecode(requests.last.body)['p_expected'], 'wallet-revision');
      final balance = await repo.loadOpeningBalance('wallet');
      await repo.saveOpeningBalance(
        'wallet',
        BigInt.from(42),
        previous: balance,
      );
      final args = jsonDecode(requests.last.body) as Map;
      expect(args['p_expected'], 'balance-revision');
      expect(args['p_data'], {'amount_minor': '42'});
    },
  );
}
