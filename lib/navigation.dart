import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'screens/claude_requests_screen.dart';
import 'screens/lead_detail_screen.dart';
import 'screens/wa_chat_screen.dart';
import 'services/contact_actions.dart';
import 'services/notifications.dart';
import 'services/repo.dart';

final navigatorKey = GlobalKey<NavigatorState>();

/// Push messages can ask for a tab: 'leads', 'followups' or 'dashboard'. HomeScreen listens.
final openTabRequest = ValueNotifier<String?>(null);

/// Notification tapped: open the lead, or call / WhatsApp straight away.
Future<void> openFromNotification(NotificationResponse response) =>
    openFromData(Notifications.payloadOf(response), actionId: response.actionId);

/// Opens what a notification points at ({"lead_id": ...} or {"open": "followups"}).
Future<void> openFromData(Map<String, dynamic>? data, {String? actionId}) async {
  final tab = data?['open'] as String?;
  if (tab == 'claude') {
    // Claude left a request: open the list where it can be approved
    if (currentUserId == null) return;
    navigatorKey.currentState?.popUntil((r) => r.isFirst);
    await navigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => const ClaudeRequestsScreen()));
    return;
  }
  if (tab != null) {
    navigatorKey.currentState?.popUntil((r) => r.isFirst);
    openTabRequest.value = tab;
    return;
  }
  final leadId = data?['lead_id'] as String?;
  final context = navigatorKey.currentContext;
  if (leadId == null || context == null || currentUserId == null) return;

  final lead = await Repo.lead(leadId);
  if (lead == null || !context.mounted) return;

  if (data?['chat'] == '1' && actionId == null) {
    await navigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => WaChatScreen(lead: lead)));
    return;
  }

  switch (actionId) {
    case 'call':
      await ContactActions.call(context, lead);
    case 'whatsapp':
      await ContactActions.whatsapp(context, lead);
    default:
      await navigatorKey.currentState?.push(
        MaterialPageRoute(builder: (_) => LeadDetailScreen(leadId: lead.id, initial: lead)),
      );
  }
}
