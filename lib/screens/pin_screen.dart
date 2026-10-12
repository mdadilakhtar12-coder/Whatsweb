import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_lock.dart';
import '../services/app_state.dart';
import '../services/session.dart';

/// Number pad with PIN dots.
class _PinPad extends StatelessWidget {
  final String entered;
  final ValueChanged<String> onChanged;

  const _PinPad({required this.entered, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget key(String label, {IconData? icon, VoidCallback? onTap}) => SizedBox(
          width: 76,
          height: 64,
          child: TextButton(
            onPressed: onTap ??
                () {
                  if (entered.length < AppLock.pinLength) {
                    HapticFeedback.selectionClick();
                    onChanged(entered + label);
                  }
                },
            child: icon != null ? Icon(icon, size: 26) : Text(label, style: const TextStyle(fontSize: 26)),
          ),
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < AppLock.pinLength; i++)
              Container(
                margin: const EdgeInsets.all(8),
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < entered.length ? scheme.primary : Colors.transparent,
                  border: Border.all(color: scheme.primary, width: 2),
                ),
              ),
          ],
        ),
        const SizedBox(height: 24),
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [for (final k in row) key(k)]),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(width: 76),
            key('0'),
            key(
              '',
              icon: Icons.backspace_outlined,
              onTap: entered.isEmpty ? null : () => onChanged(entered.substring(0, entered.length - 1)),
            ),
          ],
        ),
      ],
    );
  }
}

/// Covers the whole app while locked.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  String _pin = '';
  String? _error;
  int _wrong = 0;

  Future<void> _changed(String pin) async {
    setState(() {
      _pin = pin;
      _error = null;
    });
    if (pin.length < AppLock.pinLength) return;
    final ok = await AppLock.instance.unlock(pin);
    if (!mounted || ok) return;
    HapticFeedback.heavyImpact();
    setState(() {
      _wrong++;
      _pin = '';
      _error = 'Wrong PIN';
    });
  }

  Future<void> _forgot() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Forgot PIN?'),
        content: const Text('You will be logged out. Log in again with your password and set a new PIN.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Log out')),
        ],
      ),
    );
    if (ok == true) await signOut();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              children: [
                Icon(Icons.lock_outline, size: 40, color: scheme.primary),
                const SizedBox(height: 12),
                Text('Enter PIN', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 4),
                Text(AppState.instance.me?.displayName ?? '', style: TextStyle(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 16),
                _PinPad(entered: _pin, onChanged: _changed),
                SizedBox(
                  height: 28,
                  child: _error == null ? null : Text(_error!, style: TextStyle(color: scheme.error)),
                ),
                TextButton(
                  onPressed: _forgot,
                  child: Text(_wrong >= 3 ? 'Forgot PIN? Log out' : 'Forgot PIN?'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Choose a new PIN (entered twice). Returns true when saved.
class SetPinScreen extends StatefulWidget {
  /// Admin requires a PIN: no way to skip.
  final bool required;

  const SetPinScreen({super.key, this.required = false});

  @override
  State<SetPinScreen> createState() => _SetPinScreenState();
}

class _SetPinScreenState extends State<SetPinScreen> {
  String _pin = '';
  String? _first;
  String? _error;

  Future<void> _changed(String pin) async {
    setState(() {
      _pin = pin;
      _error = null;
    });
    if (pin.length < AppLock.pinLength) return;
    if (_first == null) {
      setState(() {
        _first = pin;
        _pin = '';
      });
      return;
    }
    if (pin != _first) {
      setState(() {
        _first = null;
        _pin = '';
        _error = 'PINs did not match — try again';
      });
      return;
    }
    await AppLock.instance.setPin(pin);
    if (mounted && Navigator.canPop(context)) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !widget.required,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('App lock PIN'),
          automaticallyImplyLeading: !widget.required,
          actions: [
            if (widget.required) TextButton(onPressed: signOut, child: const Text('Log out')),
          ],
        ),
        body: Center(
          child: SingleChildScrollView(
            child: Column(
              children: [
                Text(
                  _first == null ? 'Choose a ${AppLock.pinLength}-digit PIN' : 'Enter the same PIN again',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    widget.required
                        ? 'Your admin asks for a PIN on every phone. It is asked when the app opens.'
                        : 'The PIN is asked when the app opens and after 5 minutes away.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
                const SizedBox(height: 16),
                _PinPad(entered: _pin, onChanged: _changed),
                SizedBox(
                  height: 28,
                  child: _error == null ? null : Text(_error!, style: TextStyle(color: scheme.error)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
