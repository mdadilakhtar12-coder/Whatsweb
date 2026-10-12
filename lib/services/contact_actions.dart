import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models.dart';
import '../navigation.dart';
import '../screens/wa_chat_screen.dart';
import 'app_state.dart';
import '../widgets/call_outcome_sheet.dart';
import '../widgets/template_picker.dart';
import 'call_log_sync.dart';
import 'repo.dart';

/// Call / WhatsApp / SMS / Email buttons. Each one is written to the lead's history.
class ContactActions {
  static const _channel = MethodChannel('whatsweb/phone');
  static AppLifecycleListener? _callListener;

  static String fill(String template, Lead lead) {
    final name = lead.name.trim().isEmpty ? 'there' : lead.name.trim();
    return template.replaceAll('{name}', name);
  }

  /// Digits with country code, as WhatsApp expects (no +).
  static String whatsappNumber(String phone) {
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    return digits.length == 10 ? '91$digits' : digits;
  }

  static void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  static void _log(Lead lead, String type) {
    Repo.logContact(lead.id, type).catchError((_) {});
  }

  /// Places the call directly (asks for the phone permissions the first time).
  /// After the call, when the user comes back to the app, shows how long it lasted and asks how it went.
  static Future<void> call(BuildContext context, Lead lead, {VoidCallback? onUpdated}) async {
    final phone = lead.phone;
    if (phone == null || phone.isEmpty) return _toast(context, 'No phone number');

    // A computer cannot place a call: copy the number to dial from a phone.
    if (kIsWeb) {
      await Clipboard.setData(ClipboardData(text: phone));
      if (context.mounted) _toast(context, 'Number $phone copied. Dial it from your phone.');
      return;
    }

    await Permission.phone.request();
    final startedAt = DateTime.now();
    try {
      await _channel.invokeMethod('call', {'number': phone});
    } on PlatformException {
      await launchUrl(Uri(scheme: 'tel', path: phone));
    } on MissingPluginException {
      await launchUrl(Uri(scheme: 'tel', path: phone));
    }
    // With call-log access the real call (and its length) is recorded from the call log instead.
    if (!await CallLogSync.hasPermission()) _log(lead, 'call');
    if (context.mounted) _askAfterCall(context, lead, startedAt, onUpdated);
  }

  static void _askAfterCall(BuildContext context, Lead lead, DateTime startedAt, VoidCallback? onUpdated) {
    _callListener?.dispose();
    var leftApp = false;
    late final AppLifecycleListener listener;
    listener = AppLifecycleListener(
      onHide: () => leftApp = true,
      onResume: () async {
        if (!leftApp) return;
        listener.dispose();
        if (identical(_callListener, listener)) _callListener = null;

        // The phone writes the call log a moment after the call ends.
        await Future<void>.delayed(const Duration(milliseconds: 700));
        final phoneCall = await CallLogSync.lastCallTo(lead.phone ?? '', startedAt);
        await CallLogSync.sync();

        // The list may have rebuilt while the call was on; fall back to the app's navigator.
        final ctx = context.mounted ? context : navigatorKey.currentContext;
        if (ctx != null && ctx.mounted) {
          final changed = await showCallOutcomeSheet(ctx, lead, phoneCall: phoneCall);
          if (changed == true || phoneCall != null) onUpdated?.call();
        }
      },
    );
    _callListener = listener;
  }

  static Future<void> whatsapp(BuildContext context, Lead lead) async {
    // The admin can switch WhatsApp to the Cloud API: the button then opens the in-app chat.
    if (AppState.instance.waButtonViaApi) {
      await Navigator.push(context, MaterialPageRoute(builder: (_) => WaChatScreen(lead: lead)));
      return;
    }
    final phone = lead.phone;
    if (phone == null || phone.isEmpty) return _toast(context, 'No phone number');
    final choice = await pickTemplate(context, 'whatsapp');
    if (choice == null || !context.mounted) return;
    final text = choice.template == null ? '' : fill(choice.template!.body, lead);
    final uri = Uri.https('wa.me', '/${whatsappNumber(phone)}', {if (text.isNotEmpty) 'text': text});
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) return _toast(context, 'WhatsApp is not installed');
    _log(lead, 'whatsapp');
  }

  static Future<void> sms(BuildContext context, Lead lead) async {
    final phone = lead.phone;
    if (phone == null || phone.isEmpty) return _toast(context, 'No phone number');
    final choice = await pickTemplate(context, 'sms');
    if (choice == null || !context.mounted) return;
    final text = choice.template == null ? '' : fill(choice.template!.body, lead);
    final uri = Uri(
      scheme: 'sms',
      path: phone,
      query: text.isEmpty ? null : 'body=${Uri.encodeComponent(text)}',
    );
    final ok = await launchUrl(uri);
    if (!ok && context.mounted) return _toast(context, 'Could not open the SMS app');
    _log(lead, 'sms');
  }

  static Future<void> email(BuildContext context, Lead lead) async {
    final email = lead.email;
    if (email == null || email.isEmpty) return _toast(context, 'No email address');
    final choice = await pickTemplate(context, 'email');
    if (choice == null || !context.mounted) return;
    final t = choice.template;
    final params = <String>[
      if ((t?.subject ?? '').isNotEmpty) 'subject=${Uri.encodeComponent(fill(t!.subject!, lead))}',
      if ((t?.body ?? '').isNotEmpty) 'body=${Uri.encodeComponent(fill(t!.body, lead))}',
    ];
    final uri = Uri(scheme: 'mailto', path: email, query: params.isEmpty ? null : params.join('&'));
    final ok = await launchUrl(uri);
    if (!ok && context.mounted) return _toast(context, 'No email app found');
    _log(lead, 'email');
  }
}
