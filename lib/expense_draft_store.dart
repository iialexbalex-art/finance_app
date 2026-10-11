import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'expense.dart';

abstract class ExpenseDraftStore {
  Future<PendingExpense?> read(String userId, String spaceId);
  Future<bool> referencesWallet(String userId, String spaceId, String walletId);
  Future<void> write(String userId, PendingExpense draft);
  Future<void> clear(
    String userId,
    String spaceId, {
    required String requestId,
  });
}

class LocalExpenseDraftStore implements ExpenseDraftStore {
  LocalExpenseDraftStore({this.namespace = 'expense_pending_v1'});
  final String namespace;
  late final SharedPreferencesAsync _storage = SharedPreferencesAsync();
  String _key(String user, String space) => '$namespace:$user:$space';
  @override
  Future<PendingExpense?> read(String userId, String spaceId) async {
    final prefix = '${_key(userId, spaceId)}:';
    final keys =
        (await _storage.getKeys()).where((k) => k.startsWith(prefix)).toList()
          ..sort();
    // The old single-entry journal is still readable after upgrading from 005.
    final text = await _storage.getString(
      keys.firstOrNull ?? _key(userId, spaceId),
    );
    if (text == null) return null;
    final draft = PendingExpense.fromJson(
      jsonDecode(text) as Map<String, dynamic>,
    );
    if (draft.spaceId != spaceId) {
      throw const FormatException('Неверное пространство черновика.');
    }
    return draft;
  }

  @override
  Future<bool> referencesWallet(
    String userId,
    String spaceId,
    String walletId,
  ) async {
    final base = _key(userId, spaceId);
    final keys = (await _storage.getKeys()).where(
      (key) => key == base || key.startsWith('$base:'),
    );
    for (final key in keys) {
      final text = await _storage.getString(key);
      if (text == null) continue;
      final draft = PendingExpense.fromJson(
        jsonDecode(text) as Map<String, dynamic>,
      );
      if (draft.spaceId == spaceId && draft.walletId == walletId) return true;
    }
    return false;
  }

  @override
  Future<void> write(String userId, PendingExpense draft) => _storage.setString(
    '${_key(userId, draft.spaceId)}:${draft.requestId}',
    jsonEncode(draft.toJson()),
  );
  @override
  Future<void> clear(
    String userId,
    String spaceId, {
    required String requestId,
  }) async {
    await _storage.remove('${_key(userId, spaceId)}:$requestId');
    final legacy = await _storage.getString(_key(userId, spaceId));
    if (legacy != null &&
        (jsonDecode(legacy) as Map<String, dynamic>)['p_request_id'] ==
            requestId) {
      await _storage.remove(_key(userId, spaceId));
    }
  }
}

class MemoryExpenseDraftStore implements ExpenseDraftStore {
  final Map<String, PendingExpense> items = {};
  @override
  Future<PendingExpense?> read(String userId, String spaceId) async => items
      .entries
      .where((e) => e.key.startsWith('$userId:$spaceId:'))
      .firstOrNull
      ?.value;
  @override
  Future<bool> referencesWallet(
    String userId,
    String spaceId,
    String walletId,
  ) async => items.entries.any(
    (entry) =>
        entry.key.startsWith('$userId:$spaceId:') &&
        entry.value.walletId == walletId,
  );
  @override
  Future<void> write(String userId, PendingExpense draft) async {
    items['$userId:${draft.spaceId}:${draft.requestId}'] = draft;
  }

  @override
  Future<void> clear(
    String userId,
    String spaceId, {
    required String requestId,
  }) async {
    items.remove('$userId:$spaceId:$requestId');
  }
}
