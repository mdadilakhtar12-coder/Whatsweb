import 'package:flutter/material.dart';

/// On a big screen (a computer) the app stays in a readable column in the middle.
Widget wideLayout(BuildContext context, Widget child) {
  const maxWidth = 1180.0;
  final media = MediaQuery.of(context);
  if (media.size.width <= maxWidth) return child;
  return ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxWidth),
        child: MediaQuery(
          data: media.copyWith(size: Size(maxWidth, media.size.height)),
          child: Material(elevation: 2, child: child),
        ),
      ),
    ),
  );
}
