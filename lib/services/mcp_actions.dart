import 'package:intl/intl.dart';

import '../models.dart';
import 'app_state.dart';
import 'notifications.dart';
import 'repo.dart';

/// Does what an approved request says, with the owner's own login (the same calls the screens make).
/// Returns a sentence about what happened; throws when it did not work.
Future<String> runMcpAction(McpAction a) async {
  final args = a.args;
  switch (a.kind) {
    case 'add_leads':
      {
        final rows = ((args['rows'] as List?) ?? const []).map((r) => (r as Map).cast<String, dynamic>()).toList();
        final batch = await Repo.createImportBatch('Claude · ${DateFormat('d MMM, h:mm a').format(DateTime.now())}', rows.length);
        final res = await Repo.importLeads(
          rows,
          assignTo: args['assign_to'] as String?,
          sourceDetail: args['campaign'] as String?,
          batchId: batch,
        );
        final added = (res['added'] as num?)?.toInt() ?? 0;
        final dupes = (res['duplicates'] as num?)?.toInt() ?? 0;
        return 'Added $added lead${added == 1 ? '' : 's'}'
            '${dupes > 0 ? ', $dupes already existed' : ''}. They are in More > Imported files > Claude.';
      }
    case 'edit_lead':
      {
        await Repo.updateLead(args['lead_id'] as String, (args['values'] as Map).cast<String, dynamic>());
        return 'Lead details changed.';
      }
    case 'set_status':
      {
        final ids = ((args['lead_ids'] as List?) ?? const []).map((e) => '$e').toList();
        await Repo.updateLeads(ids, (args['values'] as Map).cast<String, dynamic>());
        return 'Changed ${ids.length} lead${ids.length == 1 ? '' : 's'}.';
      }
    case 'add_remark':
      {
        await Repo.addActivity(args['lead_id'] as String, 'remark', body: args['text'] as String, meta: {'via': 'claude'});
        return 'Remark written.';
      }
    case 'set_reminder':
      {
        final userId = (args['user_id'] as String?) ?? currentUserId;
        final r = await Repo.addReminder(
          leadId: args['lead_id'] as String,
          at: DateTime.parse('${args['at']}').toLocal(),
          note: args['note'] as String?,
          userId: userId,
        );
        if (r.userId == currentUserId) await Notifications.schedule(r);
        return 'Reminder set.';
      }
    case 'assign':
      {
        final ids = ((args['lead_ids'] as List?) ?? const []).map((e) => '$e').toList();
        final agents = ((args['agent_ids'] as List?) ?? const []).map((e) => '$e').toList();
        final n = await Repo.assignLeads(ids, agents);
        return 'Gave $n lead${n == 1 ? '' : 's'} to the team.';
      }
    case 'wa_text':
      {
        final res = await Repo.wa('send', {'lead_id': args['lead_id'], 'mode': 'text', 'text': args['text']});
        if (res['ok'] == false) throw Exception('${res['error'] ?? 'WhatsApp did not accept the message'}');
        return 'WhatsApp message sent.';
      }
    case 'wa_template':
      {
        final entries = ((args['entries'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
        final values = ((args['values'] as Map?) ?? const {}).map((k, v) => MapEntry('$k', '$v'));
        final res = await Repo.waSendToNumbers(
          args['template_id'] as String,
          entries,
          name: 'Claude · ${args['template_name']}',
          params: values,
        );
        int n(String k) => (res[k] as num?)?.toInt() ?? 0;
        return 'Sending to ${n('sending')} (${n('new_leads')} new leads made'
            '${n('stopped') > 0 ? ', ${n('stopped')} asked to stop' : ''}'
            '${n('invalid') > 0 ? ', ${n('invalid')} invalid' : ''}). Progress is in WhatsApp > Broadcast.';
      }
    case 'wa_flow':
      {
        // replies first (they have their ids already, so the buttons can point to them), then the template as a DRAFT
        final replies = ((args['replies'] as List?) ?? const []).map((r) => (r as Map).cast<String, dynamic>()).toList();
        for (final r in replies) {
          await Repo.saveWaNode(null, {
            'id': r['id'],
            'name': r['name'],
            'kind': r['kind'],
            'header': r['header'],
            'body': r['body'],
            'footer': r['footer'],
            'buttons': r['buttons'] ?? const [],
            'list_button': r['list_button'],
            'sections': r['sections'] ?? const [],
          });
        }
        final t = (args['template'] as Map?)?.cast<String, dynamic>();
        if (t != null) {
          await Repo.saveWaTemplate(
            name: t['name'] as String,
            language: (t['language'] as String?) ?? 'en',
            category: (t['category'] as String?) ?? 'MARKETING',
            spec: (t['spec'] as Map).cast<String, dynamic>(),
          );
        }
        return [
          if (t != null) 'Template "${t['name']}" saved as a draft: open it in More > WhatsApp > Templates and tap Save & send to Meta.',
          if (replies.isNotEmpty) '${replies.length} automatic repl${replies.length == 1 ? 'y' : 'ies'} saved.',
        ].join(' ');
      }
    case 'wa_rule':
      {
        // saved paused: the owner switches it on (More > WhatsApp > Automatic reminders) after Meta approved the template
        final cfg = Map<String, dynamic>.from(await Repo.setting('whatsapp') ?? const {});
        final nudges = [...((cfg['nudges'] as List?) ?? const [])];
        nudges.add({...args, 'enabled': false, 'created_at': DateTime.now().toUtc().toIso8601String()});
        cfg['nudges'] = nudges;
        await Repo.saveSetting('whatsapp', cfg);
        await AppState.instance.reloadWa();
        return 'Reminder "${args['name']}" saved, paused. Switch it on in More > WhatsApp > Automatic reminders after Meta approves the template.';
      }
  }
  throw Exception('This kind of request is not known to this version of the app. Update the app.');
}
