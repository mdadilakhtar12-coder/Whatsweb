import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'repo.dart';

/// One call from the phone's call log.
class PhoneCall {
  final String number;

  /// out, in, missed or rejected
  final String direction;
  final int durationSeconds;
  final DateTime at;

  const PhoneCall(this.number, this.direction, this.durationSeconds, this.at);

  bool get answered => durationSeconds > 0;

  factory PhoneCall.fromMap(Map m) => PhoneCall(
        '${m['number'] ?? ''}',
        '${m['direction']}',
        (m['duration'] as num?)?.toInt() ?? 0,
        DateTime.fromMillisecondsSinceEpoch((m['at'] as num).toInt()),
      );

  Map<String, dynamic> toJson() => {
        'number': number,
        'direction': direction,
        'duration': durationSeconds,
        'at': at.toUtc().toIso8601String(),
      };
}

String _last10(String phone) {
  final d = phone.replaceAll(RegExp(r'\D'), '');
  return d.length > 10 ? d.substring(d.length - 10) : d;
}

String formatDuration(int seconds) {
  if (seconds < 60) return '${seconds}s';
  final m = seconds ~/ 60, s = seconds % 60;
  if (m < 60) return s == 0 ? '${m}m' : '${m}m ${s}s';
  return '${m ~/ 60}h ${m % 60}m';
}

/// Reads the phone's call log and records calls with leads (who, when, how long).
/// Only numbers that belong to a lead are kept; every other call is ignored by the server.
class CallLogSync {
  static const _channel = MethodChannel('whatsweb/phone');
  static bool _running = false;

  static Future<bool> hasPermission() async {
    if (kIsWeb) return false;
    try {
      return await _channel.invokeMethod<bool>('hasCallLog') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Calls after [since]; null when the call log cannot be read.
  static Future<List<PhoneCall>?> callsSince(DateTime since) async {
    if (kIsWeb) return null;
    try {
      final rows = await _channel.invokeMethod<List>('callLog', {'since': since.millisecondsSinceEpoch});
      return rows?.cast<Map>().map(PhoneCall.fromMap).toList();
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// The latest call with [phone] after [since] (used right after calling from the app).
  static Future<PhoneCall?> lastCallTo(String phone, DateTime since) async {
    final calls = await callsSince(since.subtract(const Duration(seconds: 5)));
    if (calls == null) return null;
    final key = _last10(phone);
    PhoneCall? found;
    for (final c in calls) {
      if (c.direction == 'out' && _last10(c.number) == key) found = c;
    }
    return found;
  }

  /// Sends new calls to the server. Returns how many were recorded against leads.
  static Future<int> sync() async {
    final uid = currentUserId;
    if (_running || uid == null) return 0;
    _running = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'call_log_synced_until_$uid';
      final now = DateTime.now();
      final saved = prefs.getInt(key);
      // First time on this phone: look back two days.
      final since = saved == null
          ? now.subtract(const Duration(days: 2))
          : DateTime.fromMillisecondsSinceEpoch(saved);

      final calls = await callsSince(since);
      if (calls == null || calls.isEmpty) return 0;

      var added = 0;
      for (var i = 0; i < calls.length; i += 200) {
        final part = calls.sublist(i, min(i + 200, calls.length));
        added += await Repo.logCalls(part.map((c) => c.toJson()).toList());
      }
      await prefs.setInt(key, calls.map((c) => c.at.millisecondsSinceEpoch).reduce(max));
      return added;
    } catch (_) {
      return 0;
    } finally {
      _running = false;
    }
  }
}
