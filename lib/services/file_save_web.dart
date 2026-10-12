import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Downloads [text] as a file through the browser.
Future<void> saveTextFile({required String name, required String text, required String mime, String? note}) async {
  final blob = web.Blob([text.toJS].toJS, web.BlobPropertyBag(type: '$mime;charset=utf-8'));
  final url = web.URL.createObjectURL(blob);
  final link = web.HTMLAnchorElement()
    ..href = url
    ..download = name;
  link.click();
  web.URL.revokeObjectURL(url);
}
