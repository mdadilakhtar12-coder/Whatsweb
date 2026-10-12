import 'package:flutter/material.dart';

import '../models.dart';
import '../services/contact_actions.dart';

const whatsappGreen = Color(0xFF25D366);

/// The four buttons shown on every lead: Call, WhatsApp, SMS, Email.
class ContactButtons extends StatelessWidget {
  final Lead lead;
  final bool large;
  final VoidCallback? onUpdated;

  const ContactButtons({super.key, required this.lead, this.large = false, this.onUpdated});

  @override
  Widget build(BuildContext context) {
    final items = [
      _Item(Icons.call, 'Call', Colors.green.shade700, lead.hasPhone,
          () => ContactActions.call(context, lead, onUpdated: onUpdated)),
      _Item(Icons.chat, 'WhatsApp', whatsappGreen, lead.hasPhone,
          () => ContactActions.whatsapp(context, lead)),
      _Item(Icons.sms_outlined, 'SMS', Colors.blue.shade700, lead.hasPhone,
          () => ContactActions.sms(context, lead)),
      _Item(Icons.email_outlined, 'Email', Colors.deepOrange.shade600, lead.hasEmail,
          () => ContactActions.email(context, lead)),
    ];

    return Row(
      children: [
        for (final item in items)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: large ? _LargeButton(item) : _SmallButton(item),
            ),
          ),
      ],
    );
  }
}

class _Item {
  final IconData icon;
  final String label;
  final Color color;
  final bool enabled;
  final VoidCallback onTap;

  const _Item(this.icon, this.label, this.color, this.enabled, this.onTap);
}

class _SmallButton extends StatelessWidget {
  final _Item item;

  const _SmallButton(this.item);

  @override
  Widget build(BuildContext context) {
    final color = item.enabled ? item.color : Colors.grey.shade400;
    return Material(
      color: color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: item.enabled ? item.onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              Icon(item.icon, size: 20, color: color),
              const SizedBox(height: 2),
              Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LargeButton extends StatelessWidget {
  final _Item item;

  const _LargeButton(this.item);

  @override
  Widget build(BuildContext context) {
    final color = item.enabled ? item.color : Colors.grey.shade400;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: item.enabled ? item.onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: color.withValues(alpha: 0.14),
              child: Icon(item.icon, color: color),
            ),
            const SizedBox(height: 6),
            Text(item.label, style: TextStyle(fontSize: 12.5, color: color, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
