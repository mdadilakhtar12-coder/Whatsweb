import 'package:flutter/material.dart';

import '../models.dart';
import '../services/app_state.dart';
import '../services/notifications.dart';
import 'contact_buttons.dart';
import 'status_chip.dart';
import 'wa_widgets.dart';
import 'appx_widgets.dart';
import 'webinar_widgets.dart';

class LeadCard extends StatelessWidget {
  final Lead lead;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onUpdated;

  const LeadCard({
    super.key,
    required this.lead,
    required this.onTap,
    this.onLongPress,
    this.onUpdated,
    this.selecting = false,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final app = AppState.instance;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5);
    final followUp = lead.nextFollowUpAt;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      color: selected ? scheme.primaryContainer : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (selecting)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Icon(
                        selected ? Icons.check_circle : Icons.radio_button_unchecked,
                        color: selected ? scheme.primary : scheme.outline,
                      ),
                    ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          lead.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          [if (lead.hasPhone) lead.phone!, if (lead.hasEmail) lead.email!].join('  ·  '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muted.copyWith(fontSize: 13.5),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      StatusChip(lead.status, dense: true),
                      if (lead.temperature != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            temperatureLabel(lead.temperature!),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: temperatureColor(lead.temperature!),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 12,
                runSpacing: 2,
                children: [
                  Text('${sourceLabel(lead.source)} · ${timeAgo(lead.createdAt)}', style: muted),
                  if (app.isAdmin)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.person_outline, size: 14, color: scheme.onSurfaceVariant),
                        const SizedBox(width: 2),
                        Text(
                          app.memberName(lead.assignedTo),
                          style: muted.copyWith(
                            color: lead.assignedTo == null ? Colors.orange.shade800 : null,
                            fontWeight: lead.assignedTo == null ? FontWeight.w600 : null,
                          ),
                        ),
                      ],
                    ),
                  if (lead.notContactedYet)
                    _NotCalledBadge(since: lead.assignedAt ?? lead.createdAt),
                  if (lead.waState != 'none') WaBadge(lead),
                  if (lead.webinarState != null) WebinarBadge(lead),
                  if (lead.appxState != null && lead.appxState != 'signed_up') AppxBadge(lead),
                  if (followUp != null)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.alarm, size: 14, color: followUpColor(context, followUp)),
                        const SizedBox(width: 2),
                        Text(
                          friendlyTime(followUp),
                          style: muted.copyWith(color: followUpColor(context, followUp), fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                ],
              ),
              if (!selecting) ...[
                const SizedBox(height: 8),
                ContactButtons(lead: lead, onUpdated: onUpdated),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// "Not called · 25m" — new leads should be called quickly.
class _NotCalledBadge extends StatelessWidget {
  final DateTime since;

  const _NotCalledBadge({required this.since});

  @override
  Widget build(BuildContext context) {
    final minutes = DateTime.now().difference(since).inMinutes;
    final late = minutes >= 15;
    final color = late ? Colors.red.shade700 : Colors.orange.shade800;
    final age = minutes < 60 ? '${minutes}m' : minutes < 1440 ? '${minutes ~/ 60}h' : '${minutes ~/ 1440}d';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.timer_outlined, size: 14, color: color),
        const SizedBox(width: 2),
        Text('Not called · $age', style: TextStyle(fontSize: 12.5, color: color, fontWeight: FontWeight.w600)),
      ],
    );
  }
}
