import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/repo.dart';

/// The Google Apps Script the admin pastes into script.google.com (with this CRM's secret key).
String backupScript(String key) => '''
// WhatsWeb backup — saves the CSV files the CRM sends every night into Google Drive.
const SECRET = '$key';
const FOLDER = 'WhatsWeb Backups';
const KEEP_DAYS = 30;

function doPost(e) {
  const data = JSON.parse(e.postData.contents);
  if (data.key !== SECRET) return reply({ ok: false, error: 'Wrong key' });
  const folder = backupFolder();
  const files = (data.files || []).map(function (f) {
    return folder.createFile(f.name, f.content, MimeType.CSV).getUrl();
  });
  removeOld(folder);
  return reply({ ok: true, folder: folder.getUrl(), files: files });
}

function doGet() {
  return reply({ ok: true, message: 'WhatsWeb backup is ready' });
}

function backupFolder() {
  const found = DriveApp.getFoldersByName(FOLDER);
  return found.hasNext() ? found.next() : DriveApp.createFolder(FOLDER);
}

function removeOld(folder) {
  const cutoff = Date.now() - KEEP_DAYS * 24 * 60 * 60 * 1000;
  const files = folder.getFiles();
  while (files.hasNext()) {
    const f = files.next();
    if (f.getDateCreated().getTime() < cutoff) f.setTrashed(true);
  }
}

function reply(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}
''';

/// Admin: nightly backup of all leads and history into their own Google Drive.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  Map<String, dynamic> _cfg = {};
  bool _loading = true;
  bool _busy = false;
  final _url = TextEditingController();
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _url.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      var cfg = await Repo.setting('backup') ?? {};
      if ((cfg['key'] as String?)?.isNotEmpty != true) {
        // First visit: make the secret the script will check.
        final rnd = Random.secure();
        final key = List.generate(24, (_) => 'abcdefghijkmnpqrstuvwxyz23456789'[rnd.nextInt(32)]).join();
        cfg = {...cfg, 'key': key};
        await Repo.saveSetting('backup', cfg);
      }
      if (!mounted) return;
      setState(() {
        _cfg = cfg;
        _url.text = (cfg['url'] as String?) ?? '';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast(errorText(e));
    }
  }

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _copyScript() async {
    await Clipboard.setData(ClipboardData(text: backupScript('${_cfg['key']}')));
    _toast('Script copied');
  }

  Future<void> _shareScript() async {
    await SharePlus.instance.share(ShareParams(
      text: backupScript('${_cfg['key']}'),
      subject: 'WhatsWeb backup script',
    ));
  }

  Future<void> _saveUrl() async {
    final url = _url.text.trim();
    if (!url.startsWith('https://script.google.com/')) {
      _toast('Paste the Web app URL — it starts with https://script.google.com/');
      return;
    }
    setState(() => _busy = true);
    try {
      _cfg = {..._cfg, 'url': url};
      await Repo.saveSetting('backup', _cfg);
      _toast('Saved. Taking the first backup…');
      await _backupNow();
    } catch (e) {
      _toast(errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _backupNow() async {
    final before = _cfg['last_at'];
    try {
      await db.rpc('request_backup');
    } catch (e) {
      _toast(errorText(e));
      return;
    }
    // The backup runs on the server; check for the result for about a minute.
    _poll?.cancel();
    var tries = 0;
    _poll = Timer.periodic(const Duration(seconds: 5), (t) async {
      tries++;
      final cfg = await Repo.setting('backup').catchError((Object _) => null);
      if (!mounted) return t.cancel();
      if (cfg != null && cfg['last_at'] != before) {
        t.cancel();
        setState(() => _cfg = cfg);
        _toast(cfg['last_status'] == 'ok' ? 'Backup saved to Google Drive' : 'Backup failed: ${cfg['last_error']}');
      } else if (tries >= 14) {
        t.cancel();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant);
    final lastAt = DateTime.tryParse('${_cfg['last_at'] ?? ''}')?.toLocal();
    final ok = _cfg['last_status'] == 'ok';
    final counts = (_cfg['last_counts'] as Map?)?.cast<String, dynamic>();

    Widget step(int n, String title, Widget child) => Card(
          margin: const EdgeInsets.only(bottom: 10),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(radius: 12, child: Text('$n', style: const TextStyle(fontSize: 12))),
                    const SizedBox(width: 8),
                    Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700))),
                  ],
                ),
                const SizedBox(height: 8),
                child,
              ],
            ),
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Google Drive backup')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                if (lastAt != null)
                  Card(
                    color: ok ? Colors.green.shade50 : Colors.red.shade50,
                    child: ListTile(
                      leading: Icon(ok ? Icons.cloud_done : Icons.cloud_off, color: ok ? Colors.green.shade700 : scheme.error),
                      title: Text(ok ? 'Last backup: ${DateFormat('d MMM, h:mm a').format(lastAt)}' : 'Last backup failed'),
                      subtitle: Text(ok
                          ? '${counts?['leads'] ?? '?'} leads, ${counts?['history'] ?? '?'} history entries'
                          : '${_cfg['last_error'] ?? ''}'),
                      trailing: _cfg['folder_url'] == null
                          ? null
                          : IconButton(
                              tooltip: 'Open folder',
                              icon: const Icon(Icons.open_in_new),
                              onPressed: () => launchUrl(Uri.parse('${_cfg['folder_url']}'),
                                  mode: LaunchMode.externalApplication),
                            ),
                    ),
                  ),
                Text(
                  'Every night at 2 AM all leads and their history are saved as Excel-friendly CSV files in a '
                  '"WhatsWeb Backups" folder in your Google Drive (last 30 days kept). One-time setup, on a computer:',
                  style: muted,
                ),
                const SizedBox(height: 12),
                step(
                  1,
                  'Get the backup script',
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Send it to yourself (WhatsApp / email) to open it on a computer, or copy it.', style: muted),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          FilledButton.tonalIcon(
                            onPressed: _shareScript,
                            icon: const Icon(Icons.share),
                            label: const Text('Send script'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _copyScript,
                            icon: const Icon(Icons.copy),
                            label: const Text('Copy'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                step(
                  2,
                  'Put it in your Google account',
                  Text(
                    'Open script.google.com with the Google account whose Drive should keep the backups → '
                    'New project → delete what is there → paste → Save.',
                    style: muted,
                  ),
                ),
                step(
                  3,
                  'Deploy it',
                  Text(
                    'Deploy → New deployment → type "Web app" → Execute as: Me → Who has access: Anyone → '
                    'Deploy → Authorize access → choose your account → Advanced → Go to (unsafe) → Allow. '
                    'Copy the "Web app URL".',
                    style: muted,
                  ),
                ),
                step(
                  4,
                  'Paste the Web app URL here',
                  Column(
                    children: [
                      TextField(
                        controller: _url,
                        decoration: const InputDecoration(hintText: 'https://script.google.com/macros/s/…/exec'),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton(onPressed: _busy ? null : _saveUrl, child: const Text('Save')),
                      ),
                    ],
                  ),
                ),
                if ((_cfg['url'] as String?)?.isNotEmpty == true)
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _backupNow,
                    icon: const Icon(Icons.backup_outlined),
                    label: const Text('Backup now'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  ),
              ],
            ),
    );
  }
}
