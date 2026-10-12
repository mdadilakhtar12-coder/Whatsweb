import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:firebase_messaging/firebase_messaging.dart';

import '../navigation.dart';
import 'notifications.dart';
import 'repo.dart';

/// Firebase settings, passed at build time (from the FIREBASE_CONFIG GitHub secret).
const _apiKey = String.fromEnvironment('FIREBASE_API_KEY');
const _appId = String.fromEnvironment('FIREBASE_APP_ID');
const _senderId = String.fromEnvironment('FIREBASE_SENDER_ID');
const _projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');

/// Messages arriving while the app is closed are shown by Android itself.
@pragma('vm:entry-point')
Future<void> _onBackgroundMessage(RemoteMessage message) async {}

/// Push notifications from the server: new leads, leads waiting for a call, morning summary.
/// Does nothing until Firebase is set up.
class Push {
  static bool get configured =>
      !kIsWeb &&
      _apiKey.isNotEmpty && _appId.isNotEmpty && _senderId.isNotEmpty && _projectId.isNotEmpty;

  static bool _ready = false;
  static String? _token;
  static final _subscriptions = <StreamSubscription<Object?>>[];

  static Future<void> init() async {
    if (!configured || _ready) return;
    try {
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: _apiKey,
          appId: _appId,
          messagingSenderId: _senderId,
          projectId: _projectId,
        ),
      );
      FirebaseMessaging.onBackgroundMessage(_onBackgroundMessage);
      _ready = true;
    } catch (_) {
      // No push this time; everything else still works.
    }
  }

  /// After login: tell the server which phone this user is on, and listen for messages.
  static Future<void> register() async {
    if (!_ready || currentUserId == null) return;
    final messaging = FirebaseMessaging.instance;
    try {
      _token = await messaging.getToken();
      if (_token != null) await Repo.registerDevice(_token!);
    } catch (_) {
      return;
    }

    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions
      ..clear()
      ..add(messaging.onTokenRefresh.listen((t) {
        _token = t;
        Repo.registerDevice(t).catchError((_) {});
      }))
      // App open: Android does not show it by itself, so show it here.
      ..add(FirebaseMessaging.onMessage.listen((m) {
        final n = m.notification;
        if (n == null) return;
        Notifications.showNow(title: n.title ?? 'WhatsWeb', body: n.body, data: m.data);
      }))
      // App in the background and the notification was tapped.
      ..add(FirebaseMessaging.onMessageOpenedApp.listen((m) => openFromData(m.data)));

    // App was closed and opened from a notification.
    final initial = await messaging.getInitialMessage();
    if (initial != null) await openFromData(initial.data);
  }

  /// On logout: this phone should stop getting this user's notifications.
  static Future<void> unregister() async {
    final token = _token;
    if (!_ready || token == null) return;
    try {
      await Repo.unregisterDevice(token);
    } catch (_) {}
  }
}
