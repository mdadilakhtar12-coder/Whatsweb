import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'navigation.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'screens/pin_screen.dart';
import 'services/app_lock.dart';
import 'services/app_state.dart';
import 'services/notifications.dart';
import 'services/push.dart';
import 'services/repo.dart';
import 'services/retry_client.dart';
import 'services/session.dart';
import 'theme.dart';
import 'widgets/wide_layout.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (isConfigured) {
    await Supabase.initialize(
      url: supabaseUrl,
      publishableKey: supabaseKey,
      httpClient: ClockSkewRetryClient(),
    );
  }
  try {
    if (!kIsWeb) await Notifications.init();
  } catch (_) {
    // Reminders still save on the server; the phone schedules them on the next sync.
  }
  Notifications.onTap = openFromNotification;
  await Push.init();
  runApp(const WhatsWebApp());
}

class WhatsWebApp extends StatelessWidget {
  const WhatsWebApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WhatsWeb',
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: isConfigured ? const AuthGate() : const _NotConfigured(),
      // The PIN lock covers every screen, including ones opened from notifications.
      builder: (context, child) => ListenableBuilder(
        listenable: AppLock.instance,
        builder: (context, _) => Stack(
          children: [
            wideLayout(context, child!),
            if (AppLock.instance.locked) const Positioned.fill(child: LockScreen()),
          ],
        ),
      ),
    );
  }
}

/// Shows the login screen, or the app once the user's profile is loaded.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late final Stream<AuthState> _auth = db.auth.onAuthStateChange;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: _auth,
      builder: (context, snap) {
        final session = snap.data?.session ?? db.auth.currentSession;
        if (session == null) return const LoginScreen();
        return _Loader(key: ValueKey(session.user.id));
      },
    );
  }
}

class _Loader extends StatefulWidget {
  const _Loader({super.key});

  @override
  State<_Loader> createState() => _LoaderState();
}

class _LoaderState extends State<_Loader> {
  late Future<void> _future = _load();

  Future<void> _load() async {
    await AppState.instance.load();
    await AppLock.instance.start();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final me = AppState.instance.me;
        if (snap.hasError || me == null || !me.isActive) {
          return _Problem(
            message: snap.hasError
                ? errorText(snap.error!)
                : 'Your account is not active. Please contact your admin.',
            onRetry: snap.hasError ? () => setState(() => _future = _load()) : null,
          );
        }
        // Admin asks for a PIN on every phone: set one before using the app.
        return ListenableBuilder(
          listenable: AppLock.instance,
          builder: (context, _) => AppState.instance.requirePin && !AppLock.instance.hasPin
              ? const SetPinScreen(required: true)
              : const HomeScreen(),
        );
      },
    );
  }
}

class _Problem extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const _Problem({required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              if (onRetry != null) FilledButton(onPressed: onRetry, child: const Text('Try again')),
              TextButton(
                onPressed: signOut,
                child: const Text('Log out'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NotConfigured extends StatelessWidget {
  const _NotConfigured();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'This build has no server settings.\n\n'
            'Add SUPABASE_URL and SUPABASE_KEY as GitHub secrets and build the APK again.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
