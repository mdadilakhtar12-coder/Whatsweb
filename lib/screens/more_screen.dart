import 'package:csv/csv.dart' as csvlib;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import '../models.dart';
import '../services/app_lock.dart';
import '../services/app_state.dart';
import '../services/app_update.dart';
import '../services/file_save.dart';
import '../services/notifications.dart';
import '../services/repo.dart';
import '../services/session.dart';
import 'auto_assign_screen.dart';
import 'backup_screen.dart';
import 'import_screen.dart';
import 'imports_screen.dart';
import '../services/claude_state.dart';
import 'claude_connector_screen.dart';
import 'lead_sources_screen.dart';
import 'leaderboard_screen.dart';
import 'pin_screen.dart';
import 'speed_to_lead_screen.dart';
import 'lost_reasons_screen.dart';
import 'statuses_screen.dart';
import 'templates_screen.dart';
import 'api_screen.dart';
import 'appx_screen.dart';
import 'webinar_screen.dart';
import 'whatsapp_screen.dart';

class MoreScreen extends StatefulWidget {
  const MoreScreen({super.key});

  @override
  State<MoreScreen> createState() => _MoreScreenState();
}

class _MoreScreenState extends State<MoreScreen> {
  String _version = '';
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((p) {
      if (mounted) setState(() => _version = '${p.version} (${p.buildNumber})');
    }).catchError((_) {});
  }

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _push(Widget screen) => Navigator.push(context, MaterialPageRoute(builder: (_) => screen));

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final app = AppState.instance;
      final all = <Lead>[];
      while (true) {
        final page = await Repo.leads(const LeadFilter(), offset: all.length, limit: 1000);
        all.addAll(page);
        if (page.length < 1000) break;
      }
      String fmt(DateTime? d) => d == null ? '' : DateFormat('yyyy-MM-dd HH:mm').format(d);
      final rows = <List<dynamic>>[
        ['Name', 'Phone', 'Email', 'Status', 'Source', 'Source detail', 'Assigned to', 'Created', 'Last contacted', 'Next follow-up', 'Other details'],
        for (final l in all)
          [
            l.name,
            l.phone ?? '',
            l.email ?? '',
            l.status,
            sourceLabel(l.source),
            l.sourceDetail ?? '',
            l.assignedTo == null ? '' : app.memberName(l.assignedTo),
            fmt(l.createdAt),
            fmt(l.lastContactedAt),
            fmt(l.nextFollowUpAt),
            l.extra.entries.map((e) => '${e.key}: ${e.value}').join('; '),
          ],
      ];
      final csv = csvlib.Csv(addBom: true).encode(rows);
      await saveTextFile(
        name: 'leads_${DateFormat('yyyy-MM-dd').format(DateTime.now())}.csv',
        text: csv,
        mime: 'text/csv',
        note: '${all.length} leads exported from WhatsWeb',
      );
    } catch (e) {
      _toast(errorText(e));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _reminderCheck() async {
    await Notifications.requestPermission();
    final status = await Permission.ignoreBatteryOptimizations.request();
    final enabled = await Notifications.enabled();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reminder settings'),
        content: Text(
          'Notifications: ${enabled ? 'ON ✅' : 'OFF ❌ — turn on in phone settings'}\n'
          'Battery restriction removed: ${status.isGranted ? 'YES ✅' : 'NO ❌'}\n\n'
          'On Xiaomi / Redmi / Vivo / Oppo / Realme / OnePlus phones also open:\n'
          'Settings > Apps > WhatsWeb >\n'
          '• Autostart: ON\n'
          '• Battery saver: No restrictions\n\n'
          'Otherwise the phone may block reminders when the app is closed.',
        ),
        actions: [
          TextButton(onPressed: () => openAppSettings(), child: const Text('Open app settings')),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _pinSettings() async {
    final lock = AppLock.instance;
    if (!lock.hasPin) {
      await Navigator.push(context, MaterialPageRoute(builder: (_) => const SetPinScreen()));
      return;
    }
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Change PIN'),
              onTap: () => Navigator.pop(context, 'change'),
            ),
            if (!AppState.instance.requirePin)
              ListTile(
                leading: const Icon(Icons.lock_open_outlined),
                title: const Text('Turn off app lock'),
                onTap: () => Navigator.pop(context, 'off'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'change') {
      await Navigator.push(context, MaterialPageRoute(builder: (_) => const SetPinScreen()));
    } else if (choice == 'off') {
      await lock.removePin();
      _toast('App lock turned off');
    }
  }

  Future<void> _setRequirePin(bool value) async {
    try {
      await Repo.saveSetting('security', {'require_pin': value});
      AppState.instance.requirePin = value;
      setState(() {});
      if (value && !AppLock.instance.hasPin && mounted) {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => const SetPinScreen(required: true)));
      }
    } catch (e) {
      _toast(errorText(e));
    }
  }

  Future<void> _shareAppLink() async {
    try {
      final url = await AppUpdate.downloadLink(validFor: const Duration(days: 7));
      await SharePlus.instance.share(ShareParams(
        text: 'Install the WhatsWeb app (link works for 7 days):\n$url\n\n'
            'Open the link on your Android phone, download, then tap the file to install. '
            'If Play Protect warns, tap "More details" → "Install anyway".',
      ));
    } catch (e) {
      _toast('No app build uploaded yet: ${errorText(e)}');
    }
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text('Reminders will stop on this phone until you log in again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Log out')),
        ],
      ),
    );
    if (ok != true) return;
    await signOut();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final me = app.me;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: ListView(
        children: [
          ListTile(
            leading: CircleAvatar(child: Text((me?.displayName ?? '?').substring(0, 1).toUpperCase())),
            title: Text(me?.displayName ?? ''),
            subtitle: Text('${me?.isAdmin == true ? 'Admin' : 'Agent'} · ${me?.email ?? ''}'),
          ),
          const Divider(),
          if (app.isAdmin) ...[
            _section('WhatsApp'),
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: const Text('WhatsApp (Cloud API)'),
              subtitle: Text(app.waConnected ? 'Connected · automatic messages, templates, broadcast' : 'Not connected yet'),
              onTap: () async {
                await _push(const WhatsappScreen());
                if (mounted) setState(() {});
              },
            ),
            _section('Leads'),
            ListTile(
              leading: const Icon(Icons.upload_file),
              title: const Text('Import from Excel / CSV'),
              subtitle: const Text('Upload a file of leads'),
              onTap: () => _push(const ImportScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.folder_copy_outlined),
              title: const Text('Imported files'),
              subtitle: const Text('Every Excel upload as a folder, with its leads'),
              onTap: () => _push(const ImportsScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('Export all leads (backup)'),
              subtitle: const Text('CSV file — opens in Excel'),
              trailing: _exporting ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : null,
              onTap: _exporting ? null : _export,
            ),
            ListTile(
              leading: const Icon(Icons.add_to_drive),
              title: const Text('Google Drive backup'),
              subtitle: const Text('Every night, all leads and history'),
              onTap: () => _push(const BackupScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.emoji_events_outlined),
              title: const Text('Leaderboard'),
              subtitle: const Text('Team ranking and targets'),
              onTap: () => _push(const LeaderboardScreen()),
            ),
            ValueListenableBuilder<int>(
              valueListenable: claudePending,
              builder: (context, n, _) => ListTile(
                leading: Badge(isLabelVisible: n > 0, label: Text('$n'), child: const Icon(Icons.hub_outlined)),
                title: const Text('Claude connector'),
                subtitle: Text(n > 0 ? '$n request${n == 1 ? '' : 's'} waiting for your OK' : 'Ask the Claude app about your CRM and tell it what to do'),
                onTap: () => _push(const ClaudeConnectorScreen()),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.cast_for_education_outlined),
              title: const Text('Webinar.gg'),
              subtitle: const Text('Who registered, who paid, who came'),
              onTap: () => _push(const WebinarScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.api),
              title: const Text('API & webhooks'),
              subtitle: const Text('Keys and webhook for an outside AI assistant'),
              onTap: () => _push(const ApiScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.phone_android),
              title: const Text('AIFM Education app'),
              subtitle: const Text('Signups, purchases and cancelled payments from the app'),
              onTap: () => _push(const AppxScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('Lead sources'),
              subtitle: const Text('Landing page / Google Ads webhook address'),
              onTap: () => _push(const LeadSourcesScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('Call new leads fast'),
              subtitle: const Text('Alert / re-assign if not called in time'),
              onTap: () => _push(const SpeedToLeadScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.call_split),
              title: const Text('Auto-assign new leads'),
              subtitle: const Text('Meta / Google / website leads'),
              onTap: () => _push(const AutoAssignScreen()),
            ),
            _section('Settings'),
            ListTile(
              leading: const Icon(Icons.flag_outlined),
              title: const Text('Lead statuses'),
              subtitle: const Text('Interested, Not interested, …'),
              onTap: () => _push(const StatusesScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.help_outline),
              title: const Text('Reasons for not joining'),
              subtitle: const Text('Fees too high, too far, …'),
              onTap: () => _push(const LostReasonsScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.message_outlined),
              title: const Text('Message templates'),
              subtitle: const Text('Course details, fees, brochure… for WhatsApp / SMS / email'),
              onTap: () => _push(const TemplatesScreen()),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.pin_outlined),
              title: const Text('Require PIN on all phones'),
              subtitle: const Text('Everyone must set an app lock PIN'),
              value: app.requirePin,
              onChanged: _setRequirePin,
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('Share app download link'),
              subtitle: const Text('For a new team member — link works for 7 days'),
              onTap: _shareAppLink,
            ),
          ],
          _section('This phone'),
          ListenableBuilder(
            listenable: AppLock.instance,
            builder: (context, _) => ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text('App lock (PIN)'),
              subtitle: Text(AppLock.instance.hasPin ? 'On — tap to change or turn off' : 'Off'),
              onTap: _pinSettings,
            ),
          ),
          if (!kIsWeb) ...[
            ListTile(
              leading: const Icon(Icons.system_update_outlined),
              title: const Text('Check for updates'),
              onTap: () => AppUpdate.check(context, quiet: false),
            ),
            ListTile(
              leading: const Icon(Icons.notifications_active_outlined),
              title: const Text('Make reminders reliable'),
              subtitle: const Text('Notification & battery settings'),
              onTap: _reminderCheck,
            ),
          ],
          ListTile(
            leading: Icon(Icons.logout, color: scheme.error),
            title: Text('Log out', style: TextStyle(color: scheme.error)),
            onTap: _logout,
          ),
          if (_version.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('WhatsWeb $_version', textAlign: TextAlign.center, style: TextStyle(color: scheme.outline)),
            ),
        ],
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          title.toUpperCase(),
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.primary),
        ),
      );
}
