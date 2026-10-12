import 'package:flutter/foundation.dart';

/// How many of Claude's requests wait for the owner (the badge on More and on its menu entry).
final claudePending = ValueNotifier<int>(0);
