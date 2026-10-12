import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'repo.dart';

/// New versions are uploaded by the GitHub build to Supabase Storage (bucket "app")
/// and announced in app_settings.app_release = {"build": 12, "file": "whatsweb.apk"}.
class AppUpdate {
  static const bucket = 'app';

  static Future<int> currentBuild() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return int.tryParse(info.buildNumber) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// The newer build number, or null if this app is up to date.
  static Future<int?> newerBuild() async {
    final release = await Repo.setting('app_release');
    final latest = (release?['build'] as num?)?.toInt();
    if (latest == null) return null;
    return latest > await currentBuild() ? latest : null;
  }

  static Future<String> _file() async {
    final release = await Repo.setting('app_release');
    return (release?['file'] as String?) ?? 'whatsweb.apk';
  }

  /// A download link that works for [validFor] (to share with a new team member).
  static Future<String> downloadLink({Duration validFor = const Duration(hours: 1)}) async {
    return db.storage.from(bucket).createSignedUrl(await _file(), validFor.inSeconds);
  }

  /// Opens the download in the browser; the phone then offers to install it.
  static Future<void> download(BuildContext context) async {
    try {
      final url = await downloadLink();
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Download failed: ${errorText(e)}')));
      }
    }
  }

  /// Asks to update when a newer build exists. [quiet] = say nothing when up to date.
  static Future<void> check(BuildContext context, {bool quiet = true}) async {
    if (kIsWeb) return; // the web page is always the latest build
    int? newer;
    try {
      newer = await newerBuild();
    } catch (_) {
      return;
    }
    if (!context.mounted) return;
    if (newer == null) {
      if (!quiet) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('You have the latest version')));
      }
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.system_update),
        title: const Text('New version available'),
        content: Text(
          'Build $newer is ready. Tap Update, let the download finish, then open it and tap "Update". '
          'Your data stays safe.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Later')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Update')),
        ],
      ),
    );
    if (ok == true && context.mounted) await download(context);
  }
}
