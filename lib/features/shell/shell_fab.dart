import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Compact pill-style FAB: icon + label, 44 dp tall. Sized to content
/// (not a fixed 56 dp circle) so short labels stay unobtrusive.
class ShellFab extends StatelessWidget {
  const ShellFab({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = isDark ? AppColors.indigoDarkDeep : AppColors.indigo;

    return Material(
      color: primary,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.fabPillHeight / 2),
      ),
      elevation: 3,
      shadowColor: Colors.black.withValues(alpha: 0.2),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppSpacing.fabPillHeight / 2),
        child: Container(
          height: AppSpacing.fabPillHeight,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.fabPillHPad),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: AppSpacing.fabIconSize, color: scheme.onPrimary),
              const SizedBox(width: AppSpacing.sm),
              Text(
                label,
                style: TextStyle(
                  color: scheme.onPrimary,
                  fontSize: AppSpacing.fabLabelSize,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
