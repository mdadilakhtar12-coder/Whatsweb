import 'app_lock.dart';
import 'app_state.dart';
import 'notifications.dart';
import 'push.dart';
import 'repo.dart';

/// Log out: stop this phone's reminders, forget the PIN and the cached data.
Future<void> signOut() async {
  await Push.unregister();
  await Notifications.clearAll();
  await AppLock.instance.clear();
  AppState.instance.clear();
  await db.auth.signOut();
}
