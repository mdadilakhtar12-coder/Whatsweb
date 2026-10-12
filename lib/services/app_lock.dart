import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'repo.dart';

/// PIN lock for this phone. The PIN is stored only on the phone (salted hash),
/// per logged-in user. The app locks when opened and after 5 minutes in the background.
class AppLock extends ChangeNotifier {
  AppLock._();
  static final instance = AppLock._();

  static const lockAfter = Duration(minutes: 5);
  static const pinLength = 4;

  bool _locked = false;
  bool _hasPin = false;
  DateTime? _hiddenAt;
  AppLifecycleListener? _lifecycle;

  bool get locked => _locked && currentUserId != null;
  bool get hasPin => _hasPin;

  String get _key => 'pin_${currentUserId ?? ''}';

  /// Call after login: loads the PIN state and locks if a PIN is set.
  Future<void> start() async {
    final prefs = await SharedPreferences.getInstance();
    _hasPin = prefs.getString(_key) != null;
    _locked = _hasPin;
    _lifecycle ??= AppLifecycleListener(
      onHide: () => _hiddenAt ??= DateTime.now(),
      onShow: _maybeLock,
    );
    notifyListeners();
  }

  void _maybeLock() {
    final hiddenAt = _hiddenAt;
    _hiddenAt = null;
    if (_hasPin && hiddenAt != null && DateTime.now().difference(hiddenAt) >= lockAfter) {
      _locked = true;
      notifyListeners();
    }
  }

  static String _hash(String salt, String pin) => sha256.convert(utf8.encode('$salt:$pin')).toString();

  Future<void> setPin(String pin) async {
    final rnd = Random.secure();
    final salt = base64Encode(List<int>.generate(16, (_) => rnd.nextInt(256)));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, '$salt|${_hash(salt, pin)}');
    _hasPin = true;
    _locked = false;
    notifyListeners();
  }

  Future<bool> check(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_key);
    if (stored == null) return true;
    final parts = stored.split('|');
    return parts.length == 2 && _hash(parts[0], pin) == parts[1];
  }

  Future<bool> unlock(String pin) async {
    if (!await check(pin)) return false;
    _locked = false;
    notifyListeners();
    return true;
  }

  Future<void> removePin() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
    _hasPin = false;
    _locked = false;
    notifyListeners();
  }

  /// On logout: forget this user's PIN (a forgotten PIN is reset by logging in again).
  Future<void> clear() async {
    await removePin();
  }
}
