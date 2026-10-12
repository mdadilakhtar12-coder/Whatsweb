import 'package:flutter/material.dart';

import '../services/app_state.dart';

class StatusChip extends StatelessWidget {
  final String status;
  final bool dense;

  const StatusChip(this.status, {super.key, this.dense = false});

  @override
  Widget build(BuildContext context) {
    final color = AppState.instance.statusColor(status);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 10, vertical: dense ? 2 : 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        status,
        style: TextStyle(
          color: color,
          fontSize: dense ? 11.5 : 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
