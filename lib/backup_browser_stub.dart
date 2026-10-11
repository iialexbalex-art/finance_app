import 'dart:typed_data';

Future<void> downloadBackup(String url, String token, String name) async {
  throw UnsupportedError('Скачивание доступно в браузере.');
}

Future<String?> uploadBackup(String url, String token) async {
  throw UnsupportedError('Импорт доступен в браузере.');
}

// Kept out of application memory when running on the web.
Future<Uint8List?> unusedBackupBytes() async => null;
