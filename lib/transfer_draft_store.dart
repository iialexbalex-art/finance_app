import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'transfer.dart';

abstract class TransferDraftStore {
  Future<PendingTransfer?> read(String user, String space);
  Future<bool> referencesWallet(String user, String space, String walletId);
  Future<void> write(String user, PendingTransfer draft);
  Future<void> clear(String user, String space, String request);
}

class LocalTransferDraftStore implements TransferDraftStore {
  late final _storage = SharedPreferencesAsync();
  String _prefix(String user, String space) =>
      'transfer_pending_v1:$user:$space:';
  @override
  Future<PendingTransfer?> read(String user, String space) async {
    final keys =
        (await _storage.getKeys())
            .where((k) => k.startsWith(_prefix(user, space)))
            .toList()
          ..sort();
    if (keys.isEmpty) return null;
    final raw = await _storage.getString(keys.first);
    if (raw == null) return null;
    final draft = PendingTransfer.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
    if (draft.spaceId != space) {
      throw const FormatException('Неверное пространство запроса.');
    }
    return draft;
  }

  @override
  Future<bool> referencesWallet(
    String user,
    String space,
    String walletId,
  ) async {
    final keys = (await _storage.getKeys()).where(
      (key) => key.startsWith(_prefix(user, space)),
    );
    for (final key in keys) {
      final raw = await _storage.getString(key);
      if (raw == null) continue;
      final draft = PendingTransfer.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      if (draft.spaceId == space &&
          (draft.data['source_id'] == walletId ||
              draft.data['target_id'] == walletId)) {
        return true;
      }
    }
    return false;
  }

  @override
  Future<void> write(String user, PendingTransfer draft) => _storage.setString(
    '${_prefix(user, draft.spaceId)}${draft.requestId}',
    jsonEncode(draft.toJson()),
  );
  @override
  Future<void> clear(String user, String space, String request) =>
      _storage.remove('${_prefix(user, space)}$request');
}

class MemoryTransferDraftStore implements TransferDraftStore {
  final items = <String, PendingTransfer>{};
  @override
  Future<PendingTransfer?> read(String user, String space) async => items
      .entries
      .where((e) => e.key.startsWith('$user:$space:'))
      .firstOrNull
      ?.value;
  @override
  Future<bool> referencesWallet(
    String user,
    String space,
    String walletId,
  ) async => items.entries.any(
    (entry) =>
        entry.key.startsWith('$user:$space:') &&
        (entry.value.data['source_id'] == walletId ||
            entry.value.data['target_id'] == walletId),
  );
  @override
  Future<void> write(String user, PendingTransfer draft) async {
    items['$user:${draft.spaceId}:${draft.requestId}'] = draft;
  }

  @override
  Future<void> clear(String user, String space, String request) async {
    items.remove('$user:$space:$request');
  }
}
