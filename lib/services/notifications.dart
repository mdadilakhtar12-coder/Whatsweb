import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:intl/intl.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models.dart';
import 'repo.dart';

/// Follow-up reminders, shown as phone notifications at the chosen time.
///
/// The server is the source of truth: every sync cancels what is scheduled on the
/// phone and schedules the logged-in user's open reminders again, so reminders
/// follow a lead when it is re-assigned and survive reinstalling the app.
class Notifications {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  /// Set by the app; called when a notification (or one of its buttons) is tapped.
  static void Function(NotificationResponse response)? onTap;

  static const _channel = AndroidNotificationDetails(
    'followups',
    'Follow-up reminders',
    channelDescription: 'Reminders to call or message a lead',
    importance: Importance.max,
    priority: Priority.high,
    category: AndroidNotificationCategory.reminder,
    actions: [
      AndroidNotificationAction('call', 'Call', showsUserInterface: true),
      AndroidNotificationAction('whatsapp', 'WhatsApp', showsUserInterface: true),
    ],
  );

  static Future<void> init() async {
    if (_ready || kIsWeb) return;
    tzdata.initializeTimeZones();
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (_) {
      tz.setLocalLocation(tz.getLocation('Asia/Kolkata'));
    }
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_notification'),
      ),
      onDidReceiveNotificationResponse: (r) => onTap?.call(r),
    );
    // Channel used by push notifications (new leads, alerts, morning summary).
    await _android?.createNotificationChannel(const AndroidNotificationChannel(
      'leads',
      'New leads & alerts',
      description: 'New leads assigned to you, leads waiting for a call, morning summary',
      importance: Importance.max,
    ));
    _ready = true;
  }

  /// Shows a push message that arrived while the app is open.
  static Future<void> showNow({required String title, String? body, Map<String, dynamic>? data}) async {
    if (kIsWeb) return;
    await init();
    await _plugin.show(
      id: DateTime.now().millisecondsSinceEpoch ~/ 1000 % 1000000000,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'leads',
          'New leads & alerts',
          importance: Importance.max,
          priority: Priority.high,
          icon: 'ic_stat_lead',
        ),
      ),
      payload: data == null ? null : jsonEncode(data),
    );
  }

  /// The notification that opened the app, if any.
  static Future<NotificationResponse?> launchResponse() async {
    if (kIsWeb) return null;
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details == null || !details.didNotificationLaunchApp) return null;
    return details.notificationResponse;
  }

  static AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  static Future<bool> requestPermission() async {
    if (kIsWeb) return true;
    final granted = await _android?.requestNotificationsPermission();
    return granted ?? true;
  }

  static Future<bool> enabled() async {
    if (kIsWeb) return true;
    return await _android?.areNotificationsEnabled() ?? true;
  }

  static Future<void> schedule(Reminder r) async {
    if (kIsWeb) return;
    await init();
    final lead = r.lead;
    if (lead == null || !r.remindAt.isAfter(DateTime.now()) || r.isDone) return;

    final exact = await _android?.canScheduleExactNotifications() ?? true;
    final title = 'Follow up: ${lead.displayName}';
    final body = [
      if ((r.note ?? '').isNotEmpty) r.note!,
      if (lead.hasPhone) lead.phone!,
      'Set for ${DateFormat('d MMM, h:mm a').format(r.remindAt)}',
    ].join(' · ');

    await _plugin.zonedSchedule(
      id: r.notifyId,
      title: title,
      body: body,
      scheduledDate: tz.TZDateTime.from(r.remindAt, tz.local),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.channelId,
          _channel.channelName,
          channelDescription: _channel.channelDescription,
          importance: _channel.importance,
          priority: _channel.priority,
          category: _channel.category,
          actions: _channel.actions,
          styleInformation: BigTextStyleInformation(body),
        ),
      ),
      androidScheduleMode:
          exact ? AndroidScheduleMode.exactAllowWhileIdle : AndroidScheduleMode.inexactAllowWhileIdle,
      payload: jsonEncode({'lead_id': lead.id, 'phone': lead.phone, 'name': lead.name}),
    );
  }

  static Future<void> cancel(Reminder r) async {
    if (kIsWeb) return;
    await init();
    await _plugin.cancel(id: r.notifyId);
  }

  /// Re-schedules the logged-in user's upcoming reminders from the server.
  static Future<void> sync() async {
    final uid = currentUserId;
    if (uid == null || kIsWeb) return;
    await init();
    final reminders = await Repo.openReminders(userId: uid);
    await _plugin.cancelAllPendingNotifications();
    final now = DateTime.now();
    // Android allows ~500 alarms per app; the nearest 300 are plenty.
    final upcoming = reminders.where((r) => r.remindAt.isAfter(now)).take(300);
    for (final r in upcoming) {
      await schedule(r);
    }
  }

  static Future<void> clearAll() async {
    if (kIsWeb) return;
    await init();
    await _plugin.cancelAll();
  }

  static Map<String, dynamic>? payloadOf(NotificationResponse r) {
    final p = r.payload;
    if (p == null || p.isEmpty) return null;
    try {
      return (jsonDecode(p) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }
}

/// Small helper shared by screens that show reminder times.
String friendlyTime(DateTime t) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = day.difference(today).inDays;
  final time = DateFormat('h:mm a').format(t);
  if (diff == 0) return 'Today, $time';
  if (diff == 1) return 'Tomorrow, $time';
  if (diff == -1) return 'Yesterday, $time';
  if (t.year == now.year) return DateFormat('d MMM, h:mm a').format(t);
  return DateFormat('d MMM yyyy, h:mm a').format(t);
}

String timeAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 7) return '${d.inDays}d ago';
  return DateFormat('d MMM').format(t);
}

Color followUpColor(BuildContext context, DateTime t) {
  final now = DateTime.now();
  if (t.isBefore(now)) return Colors.red.shade700;
  if (t.difference(now).inHours < 24) return Colors.orange.shade800;
  return Theme.of(context).colorScheme.primary;
}
