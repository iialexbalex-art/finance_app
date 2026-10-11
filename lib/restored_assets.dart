import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'backup_service.dart';

/// Owner-specific immutable originals selected during a restore. Stored on the
/// server; no user data is persisted in a global/shared asset cache.
class RestoredAssets extends ChangeNotifier {
  static final instance = RestoredAssets();
  Map<String, dynamic> _files = {};
  BackupService? _service;
  final Map<String, Future<Uint8List>> _cache = {};
  int _epoch = 0;

  bool contains(String path) =>
      _files.containsKey(path) && _service?.configured == true;
  Future<Uint8List> bytes(String path) {
    final digest = (_files[path] as Map)['sha256'] as String;
    if (!_cache.containsKey(digest) && _cache.length >= 16) {
      _cache.remove(_cache.keys.first);
    }
    return _cache.putIfAbsent(digest, () => _service!.asset(digest));
  }

  void clear() {
    _epoch++;
    _files = {};
    _cache.clear();
    _service = null;
    notifyListeners();
  }

  Future<void> load(SupabaseClient client) async {
    final epoch = ++_epoch;
    final user = client.auth.currentUser?.id;
    if (user == null) {
      clear();
      return;
    }
    try {
      final row = await client
          .from('finance_settings')
          .select('asset_manifest')
          .eq('owner_id', user)
          .maybeSingle();
      if (epoch != _epoch || client.auth.currentUser?.id != user) return;
      _files = Map<String, dynamic>.from(
        (row?['asset_manifest'] as Map?) ?? {},
      );
      _cache.clear();
      _service = BackupService(client);
      notifyListeners();
    } on PostgrestException catch (error) {
      // Legacy schema continues displaying the unchanged embedded originals.
      if (!['42P01', 'PGRST205', '42703'].contains(error.code)) rethrow;
    }
  }
}
