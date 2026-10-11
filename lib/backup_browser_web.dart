import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

web.Headers _headers(String token) =>
    web.Headers()..set('Authorization', 'Bearer $token');

Future<void> downloadBackup(String url, String token, String name) async {
  final response = await web.window
      .fetch(url.toJS, web.RequestInit(headers: _headers(token)))
      .toDart;
  if (!response.ok) throw StateError('Не удалось скачать проверенный архив.');
  final blob = await response.blob().toDart;
  final objectUrl = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = objectUrl
    ..download = name;
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  Timer(const Duration(minutes: 2), () => web.URL.revokeObjectURL(objectUrl));
}

Future<String?> uploadBackup(String url, String token) async {
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = '.zip,application/zip';
  final completer = Completer<web.File?>();
  input.addEventListener(
    'change',
    ((web.Event _) {
      if (!completer.isCompleted) completer.complete(input.files?.item(0));
    }).toJS,
  );
  input.addEventListener(
    'cancel',
    ((web.Event _) {
      if (!completer.isCompleted) completer.complete(null);
    }).toJS,
  );
  input.click();
  final file = await completer.future;
  if (file == null) return null;
  if (file.size > 2 * 1024 * 1024 * 1024) {
    throw StateError('Архив превышает ограничение 2 ГБ.');
  }
  final response = await web.window
      .fetch(
        url.toJS,
        web.RequestInit(method: 'POST', headers: _headers(token), body: file),
      )
      .toDart;
  final text = (await response.text().toDart).toDart;
  if (!response.ok) throw StateError('Архив не принят: $text');
  return text;
}
