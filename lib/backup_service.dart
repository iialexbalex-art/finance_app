import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'backup_browser.dart';
import 'config.dart';
import 'expense.dart';

String backupLocalTime(String? utc) {
  if (utc == null) return '—';
  final d = DateTime.parse(utc).toUtc().add(const Duration(hours: 5));
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}.${two(d.month)}.${d.year} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

String backupSize(num? bytes) {
  if (bytes == null) return '—';
  if (bytes < 1024) return '$bytes Б';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} КБ';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
}

class BackupService {
  BackupService(this.client, {http.Client? transport})
    : transport = transport ?? http.Client();
  final SupabaseClient client;
  final http.Client transport;
  bool get configured => AppConfig.backupApiUrl.isNotEmpty;
  String get token => client.auth.currentSession?.accessToken ?? '';
  String get base => AppConfig.backupApiUrl.replaceAll(RegExp(r'/$'), '');
  Future<dynamic> request(
    String path, {
    Map<String, dynamic>? body,
    bool delete = false,
  }) async {
    if (!configured) {
      throw StateError(
        'Сервер резервирования не подключён. Администратору нужно завершить настройку подключения.',
      );
    }
    if (path == '/capture' || path == '/restore') await syncLegacyTemplates();
    final uri = Uri.parse('$base$path');
    final headers = {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
    final response = delete
        ? await transport.delete(uri, headers: headers)
        : body == null
        ? await transport.get(uri, headers: headers)
        : await transport.post(uri, headers: headers, body: jsonEncode(body));
    final value = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode >= 400) {
      throw StateError(
        value is Map ? '${value['error']}' : 'Действие не выполнено.',
      );
    }
    return value;
  }

  Future<void> syncLegacyTemplates() async {
    final user = client.auth.currentUser?.id;
    if (user == null) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('report_templates_v1:$user');
    if (raw == null) return;
    try {
      final existing = await client
          .from('finance_settings')
          .select('revision')
          .eq('owner_id', user)
          .maybeSingle();
      if (existing == null) {
        await client.rpc(
          'backup_save_templates',
          params: {
            'p_request': newExpenseRequestId(),
            'p_expected': null,
            'p_templates': jsonDecode(raw),
          },
        );
      }
    } on PostgrestException catch (error) {
      if (!['42P01', 'PGRST205', '42703'].contains(error.code)) rethrow;
    }
  }

  Future<void> protect(String requestId, String reason) async {
    await request(
      '/capture',
      body: {'request_id': requestId, 'kind': 'before', 'comment': reason},
    );
  }

  Future<void> download(Map<String, dynamic> job) => downloadBackup(
    '$base/backups/${job['id']}/download',
    token,
    'finance_${backupLocalTime(job['captured_at'] as String).replaceAll('.', '-').replaceAll(':', '-').replaceAll(' ', '_')}_UTC+05.zip',
  );

  Future<Map<String, dynamic>?> importFile() async {
    final result = await uploadBackup('$base/import', token);
    return result == null
        ? null
        : Map<String, dynamic>.from(jsonDecode(result) as Map);
  }

  Future<void> restore(String identifier) async {
    await request(
      '/restore',
      body: {'source_id': identifier, 'request_id': newExpenseRequestId()},
    );
  }

  Future<void> undo(String operation) async {
    await request(
      '/undo',
      body: {'operation_id': operation, 'request_id': newExpenseRequestId()},
    );
  }

  Future<Uint8List> asset(String digest) async {
    final response = await transport.get(
      Uri.parse('$base/assets/$digest'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 200) {
      throw StateError('Оригинал изображения недоступен.');
    }
    return response.bodyBytes;
  }
}
