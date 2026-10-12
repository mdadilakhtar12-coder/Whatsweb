import 'package:flutter/material.dart';

import '../models.dart';

Color webinarStateColor(String state) => switch (state) {
      'paid' => Colors.green.shade700,
      'registered' => Colors.blueGrey.shade600,
      'failed' => Colors.orange.shade800,
      'refunded' => Colors.red.shade700,
      _ => Colors.grey.shade600,
    };

IconData webinarStateIcon(String state) => switch (state) {
      'paid' => Icons.paid_outlined,
      'registered' => Icons.how_to_reg_outlined,
      'failed' => Icons.error_outline,
      'refunded' => Icons.undo,
      _ => Icons.event_busy_outlined,
    };

/// "Paid ₹149 · Attended" on a lead card: what happened with the Webinar.gg webinar.
class WebinarBadge extends StatelessWidget {
  final Lead lead;

  const WebinarBadge(this.lead, {super.key});

  @override
  Widget build(BuildContext context) {
    final state = lead.webinarState;
    if (state == null) return const SizedBox.shrink();
    final color = webinarStateColor(state);
    final text = state == 'paid' && lead.webinarPaid > 0 ? 'Paid ${rupees(lead.webinarPaid)}' : webinarStateLabel(state);
    final attended = lead.webinarAttended;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(webinarStateIcon(state), size: 14, color: color),
        const SizedBox(width: 3),
        Text(text, style: TextStyle(fontSize: 12.5, color: color, fontWeight: FontWeight.w600)),
        if (attended != null) ...[
          Text('  ·  ', style: TextStyle(fontSize: 12.5, color: color)),
          Text(
            attended ? 'Attended' : 'Did not attend',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: attended ? Colors.green.shade700 : Colors.orange.shade800),
          ),
        ],
      ],
    );
  }
}
