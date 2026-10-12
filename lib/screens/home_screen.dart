import 'dart:async';

import 'package:flutter/material.dart';

import '../navigation.dart';
import '../services/claude_state.dart';
import '../services/app_state.dart';
import '../services/app_update.dart';
import '../services/call_log_sync.dart';
import '../services/notifications.dart';
import '../services/push.dart';
import '../services/repo.dart';
import 'dashboard_screen.dart';
import 'followups_screen.dart';
import 'leaderboard_screen.dart';
import 'leads_screen.dart';
import 'more_screen.dart';
import 'team_screen.dart';
import 'wa_chats_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  late final AppLifecycleListener _lifecycle;
  int _unread = 0;
  Timer? _unreadTimer;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () {
      _syncReminders();
      _checkUnread();
    });
    openTabRequest.addListener(_openTab);
    _unreadTimer = Timer.periodic(const Duration(seconds: 30), (_) => _checkUnread());
    _checkUnread();
    _start();
  }

  @override
  void dispose() {
    openTabRequest.removeListener(_openTab);
    _unreadTimer?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  /// Number of WhatsApp chats waiting for a reply (the badge on the Chats tab).
  Future<void> _checkUnread() async {
    if (AppState.instance.isAdmin) {
      try {
        claudePending.value = await Repo.mcpPendingCount();
      } catch (_) {
        // offline, or the server part is not there yet
      }
    }
    if (!AppState.instance.waConnected) return;
    try {
      final n = await Repo.waUnreadCount();
      if (mounted && n != _unread) setState(() => _unread = n);
    } catch (_) {
      // offline
    }
  }

  /// The tabs on screen: (name, page, button).
  List<(String, Widget, NavigationDestination)> _tabs() {
    final app = AppState.instance;
    final admin = app.isAdmin;
    return [
      ('leads', const LeadsScreen(), const NavigationDestination(icon: Icon(Icons.people_outline), selectedIcon: Icon(Icons.people), label: 'Leads')),
      if (app.waConnected)
        (
          'chats',
          const WaChatsScreen(),
          NavigationDestination(
            icon: Badge(isLabelVisible: _unread > 0, label: Text('$_unread'), child: const Icon(Icons.chat_bubble_outline)),
            selectedIcon: Badge(isLabelVisible: _unread > 0, label: Text('$_unread'), child: const Icon(Icons.chat_bubble)),
            label: 'Chats',
          ),
        ),
      ('followups', const FollowUpsScreen(), const NavigationDestination(icon: Icon(Icons.alarm_outlined), selectedIcon: Icon(Icons.alarm), label: 'Follow-ups')),
      if (admin)
        ('dashboard', const DashboardScreen(), const NavigationDestination(icon: Icon(Icons.insights_outlined), selectedIcon: Icon(Icons.insights), label: 'Dashboard'))
      else
        ('stats', const LeaderboardScreen(), const NavigationDestination(icon: Icon(Icons.emoji_events_outlined), selectedIcon: Icon(Icons.emoji_events), label: 'My stats')),
      if (admin) ('team', const TeamScreen(), const NavigationDestination(icon: Icon(Icons.groups_outlined), selectedIcon: Icon(Icons.groups), label: 'Team')),
      (
        'more',
        const MoreScreen(),
        NavigationDestination(
          icon: ValueListenableBuilder<int>(
            valueListenable: claudePending,
            builder: (context, n, _) => Badge(isLabelVisible: admin && n > 0, label: Text('$n'), child: const Icon(Icons.menu)),
          ),
          label: 'More',
        ),
      ),
    ];
  }

  void _openTab() {
    final name = openTabRequest.value;
    if (name == null) return;
    openTabRequest.value = null;
    final index = _tabs().indexWhere((t) => t.$1 == name);
    if (index >= 0 && mounted) setState(() => _tab = index);
  }

  Future<void> _start() async {
    await Notifications.requestPermission();
    await Push.register();
    await _syncReminders();
    final launch = await Notifications.launchResponse();
    if (launch != null) await openFromNotification(launch);
    if (mounted) await AppUpdate.check(context);
  }

  Future<void> _syncReminders() async {
    try {
      await Notifications.sync();
    } catch (_) {
      // offline: try again next time the app opens
    }
    // Calls made from the phone's own dialer to leads are recorded too.
    await CallLogSync.sync();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppState.instance,
      builder: (context, _) {
        final tabs = _tabs();
        final tab = _tab.clamp(0, tabs.length - 1);
        final pages = IndexedStack(index: tab, children: [for (final t in tabs) t.$2]);

        // Wide screens (a computer): the tabs go to a side bar instead of the bottom bar.
        if (MediaQuery.sizeOf(context).width >= 760) {
          return Scaffold(
            body: Row(
              children: [
                NavigationRail(
                  selectedIndex: tab,
                  onDestinationSelected: (i) => setState(() => _tab = i),
                  labelType: NavigationRailLabelType.all,
                  leading: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'Lead\nCRM',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.primary, height: 1.1),
                    ),
                  ),
                  destinations: [
                    for (final t in tabs)
                      NavigationRailDestination(
                        icon: t.$3.icon,
                        selectedIcon: t.$3.selectedIcon ?? t.$3.icon,
                        label: Text(t.$3.label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: pages),
              ],
            ),
          );
        }

        return Scaffold(
          body: pages,
          bottomNavigationBar: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: [for (final t in tabs) t.$3],
          ),
        );
      },
    );
  }
}
