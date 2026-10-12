import 'package:flutter/material.dart';

import '../models.dart';
import 'repo.dart';

/// Data every screen needs: who is logged in, the team, statuses, templates and settings.
class AppState extends ChangeNotifier {
  AppState._();
  static final instance = AppState._();

  Profile? me;
  List<Profile> team = [];
  List<LeadStatus> statuses = [];
  List<MessageTemplate> templates = [];
  List<String> lostReasons = [];
  bool requirePin = false;

  /// WhatsApp: the admin's settings, and what the server learned from Meta (connected, number, quality).
  Map<String, dynamic> wa = {};
  Map<String, dynamic> waStatus = {};

  bool get waConnected => waStatus['connected'] == true;

  /// The lead's WhatsApp button sends through the API (opens the in-app chat) instead of the WhatsApp app.
  bool get waButtonViaApi => waConnected && wa['button_via_api'] == true;

  bool get isAdmin => me?.isAdmin ?? false;

  List<Profile> get activeTeam => team.where((p) => p.isActive).toList();

  Profile? member(String? id) {
    if (id == null) return null;
    for (final p in team) {
      if (p.id == id) return p;
    }
    return null;
  }

  String memberName(String? id) => member(id)?.displayName ?? 'Unassigned';

  LeadStatus? status(String name) {
    for (final s in statuses) {
      if (s.name == name) return s;
    }
    return null;
  }

  Color statusColor(String name) => status(name)?.color ?? Colors.blueGrey;

  List<MessageTemplate> templatesFor(String channel) =>
      templates.where((t) => t.channel == channel).toList();

  Future<void> load() async {
    // Optional extras must never stop the app from opening.
    Future<Object?> optional(Future<Object?> f) => f.catchError((Object _) => null);
    final results = await Future.wait<Object?>([
      Repo.myProfile(),
      Repo.profiles(),
      Repo.statuses(),
      optional(Repo.templates()),
      optional(Repo.setting('lost_reasons')),
      optional(Repo.setting('security')),
      optional(Repo.setting('whatsapp')),
      optional(Repo.setting('whatsapp_status')),
    ]);
    me = results[0] as Profile?;
    team = results[1] as List<Profile>;
    statuses = results[2] as List<LeadStatus>;
    templates = (results[3] as List<MessageTemplate>?) ?? [];
    final reasons = results[4] as Map<String, dynamic>?;
    lostReasons = ((reasons?['reasons'] as List?) ?? const []).map((e) => '$e').toList();
    final security = results[5] as Map<String, dynamic>?;
    requirePin = (security?['require_pin'] as bool?) ?? false;
    wa = (results[6] as Map<String, dynamic>?) ?? {};
    waStatus = (results[7] as Map<String, dynamic>?) ?? {};
    notifyListeners();
  }

  Future<void> reloadWa() async {
    final results = await Future.wait<Map<String, dynamic>?>([
      Repo.setting('whatsapp').catchError((Object _) => null),
      Repo.setting('whatsapp_status').catchError((Object _) => null),
    ]);
    wa = results[0] ?? {};
    waStatus = results[1] ?? {};
    notifyListeners();
  }

  Future<void> reloadTeam() async {
    team = await Repo.profiles();
    notifyListeners();
  }

  Future<void> reloadStatuses() async {
    statuses = await Repo.statuses();
    notifyListeners();
  }

  Future<void> reloadTemplates() async {
    templates = await Repo.templates();
    notifyListeners();
  }

  void clear() {
    me = null;
    team = [];
    statuses = [];
    templates = [];
    lostReasons = [];
    requirePin = false;
    wa = {};
    waStatus = {};
    notifyListeners();
  }
}
