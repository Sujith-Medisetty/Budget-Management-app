import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Pocket's bottom nav is a Stack overlay, not a Scaffold `bottomNavigationBar`,
/// so ScaffoldMessenger doesn't know to push SnackBars above it. This
/// helper adds the margin that floating SnackBars need to clear the pill.
///
/// Pushed routes cover the pill, so they only get the standard margin —
/// the shell is the first route, hence the `isFirst` check.
void showPocketSnackBar(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 2),
}) {
  final overNavBar = ModalRoute.of(context)?.isFirst ?? true;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      margin: EdgeInsets.only(
        bottom: overNavBar ? AppSpacing.snackbarFloatingBarMargin : AppSpacing.lg,
        left: AppSpacing.lg,
        right: AppSpacing.lg,
      ),
      duration: duration,
    ),
  );
}