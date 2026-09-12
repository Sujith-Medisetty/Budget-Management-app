import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Tiny wrapper around `path_provider` + `share_plus` for CSV exports.
/// The file is written to the temp directory and handed off to the
/// system share sheet so the user can pick Excel / Drive / Email.
class ShareFile {
  ShareFile._();

  static Future<void> shareCsv({
    required String filename,
    required String csvBody,
  }) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$filename');
    await file.writeAsString(csvBody, flush: true);
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'text/csv')],
      subject: filename,
    );
  }
}
