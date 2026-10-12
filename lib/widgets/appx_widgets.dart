import 'package:flutter/material.dart';

import '../models.dart';

Color appxStateColor(String state) => switch (state) {
      'purchased' => Colors.green.shade700,
      'signed_up' => Colors.blueGrey.shade600,
      'cancelled' => Colors.orange.shade800,
      'refunded' => Colors.red.shade700,
      _ => Colors.grey.shade600,
    };

IconData appxStateIcon(String state) => switch (state) {
      'purchased' => Icons.shopping_bag_outlined,
      'signed_up' => Icons.phone_android,
      'cancelled' => Icons.error_outline,
      'refunded' => Icons.undo,
      _ => Icons.help_outline,
    };

/// "Bought ₹4,999" on a lead card: what happened in the AIFM Education app.
class AppxBadge extends StatelessWidget {
  final Lead lead;

  const AppxBadge(this.lead, {super.key});

  @override
  Widget build(BuildContext context) {
    final state = lead.appxState;
    if (state == null) return const SizedBox.shrink();
    final color = appxStateColor(state);
    final text = switch (state) {
      'purchased' => lead.appxPaid > 0 ? 'App: bought ${rupees(lead.appxPaid)}' : 'App: bought',
      'signed_up' => 'App user',
      'cancelled' => 'App: payment cancelled',
      'refunded' => 'App: refunded',
      _ => state,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(appxStateIcon(state), size: 14, color: color),
        const SizedBox(width: 3),
        Text(text, style: TextStyle(fontSize: 12.5, color: color, fontWeight: FontWeight.w600)),
      ],
    );
  }
}
