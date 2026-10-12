import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Writes [text] to a temporary file and opens the phone's share sheet.
Future<void> saveTextFile({required String name, required String text, required String mime, String? note}) async {
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/$name');
  await file.writeAsString(text);
  await SharePlus.instance.share(ShareParams(files: [XFile(file.path, mimeType: mime)], text: note));
}
