import '../models.dart';
import 'notifications.dart';
import 'repo.dart';

/// Changes to a lead that more than one screen makes.
class LeadOps {
  static Future<void> setStatus(Lead lead, String status, {String? reason}) async {
    if (status == lead.status && reason == null) return;
    await Repo.updateLead(lead.id, {
      'status': status,
      if (reason != null && reason.trim().isNotEmpty) 'lost_reason': reason.trim(),
    });
  }

  /// hot, warm, cold, or null to clear.
  static Future<void> setTemperature(Lead lead, String? temperature) async {
    if (temperature == lead.temperature) return;
    await Repo.updateLead(lead.id, {'temperature': temperature});
  }

  static Future<void> addRemark(Lead lead, String text) async {
    if (text.trim().isEmpty) return;
    await Repo.addActivity(lead.id, 'remark', body: text.trim());
  }

  /// Saves the reminder for whoever handles the lead and, if that is me, puts it on this phone.
  static Future<Reminder> addReminder(Lead lead, DateTime at, String? note) async {
    final forUser = lead.assignedTo ?? currentUserId;
    final r = await Repo.addReminder(leadId: lead.id, at: at, note: note, userId: forUser);
    if (r.userId == currentUserId) {
      await Notifications.schedule(r);
    }
    return r;
  }

  static Future<void> completeReminder(Reminder r) async {
    await Repo.completeReminder(r.id);
    await Notifications.cancel(r);
  }

  static Future<void> deleteReminder(Reminder r) async {
    await Repo.deleteReminder(r.id);
    await Notifications.cancel(r);
  }
}
