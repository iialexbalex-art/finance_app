// This file is selected only by the web conditional export.
// Browser download stays local; no report is uploaded to another service.
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'dart:typed_data';

void downloadReport(Uint8List bytes, String name, String mime) {
  final url = web.URL.createObjectURL(
    web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mime)),
  );
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = name;
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  Future<void>.delayed(
    const Duration(seconds: 30),
    () => web.URL.revokeObjectURL(url),
  );
}
