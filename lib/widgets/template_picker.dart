import 'package:flutter/material.dart';

import '../models.dart';
import '../services/app_state.dart';

/// What to send: a template, or (template == null) an empty message.
typedef TemplateChoice = ({MessageTemplate? template});

/// No templates: empty message. One template: use it. Several: let the user pick.
/// Returns null if the user closed the picker.
Future<TemplateChoice?> pickTemplate(BuildContext context, String channel) async {
  final templates = AppState.instance.templatesFor(channel);
  if (templates.isEmpty) return (template: null);
  if (templates.length == 1) return (template: templates.first);

  return showModalBottomSheet<TemplateChoice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75),
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text('Choose a message', style: Theme.of(context).textTheme.titleLarge),
              ),
              for (final t in templates)
                ListTile(
                  leading: const Icon(Icons.message_outlined),
                  title: Text(t.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    t.subject?.isNotEmpty == true ? '${t.subject}\n${t.body}' : t.body,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.pop(context, (template: t)),
                ),
              ListTile(
                leading: Icon(Icons.edit_note, color: scheme.outline),
                title: const Text('Without a template'),
                subtitle: const Text('Open the chat and type yourself'),
                onTap: () => Navigator.pop(context, (template: null)),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    },
  );
}
