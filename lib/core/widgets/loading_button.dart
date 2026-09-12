import 'package:flutter/material.dart';

enum LoadingButtonStyle { filled, outlined, text }

/// Button that visually communicates an in-flight network call by
/// swapping its label for a spinner (plus an optional `busyLabel`).
///
/// The parent owns the busy state — pass `busy: true` while an
/// `await` is in flight and `false` once it completes. When `busy`
/// is true the button is also disabled, so a fast double-tap can't
/// fire the same network call twice. This matches the existing
/// pattern in `email_filters_screen.dart` and `onboarding_screen.dart`,
/// which both keep their own `_busy` / `_saving` flags for status
/// rows and post-completion side effects (snackbars, invalidations).
class LoadingButton extends StatelessWidget {
  const LoadingButton({
    super.key,
    required this.label,
    required this.onPressed,
    required this.busy,
    this.busyLabel,
    this.icon,
    this.style = LoadingButtonStyle.filled,
    this.fullWidth = true,
  });

  const LoadingButton.filled({
    super.key,
    required this.label,
    required this.onPressed,
    required this.busy,
    this.busyLabel,
    this.icon,
    this.fullWidth = true,
  }) : style = LoadingButtonStyle.filled;

  const LoadingButton.outlined({
    super.key,
    required this.label,
    required this.onPressed,
    required this.busy,
    this.busyLabel,
    this.icon,
    this.fullWidth = true,
  }) : style = LoadingButtonStyle.outlined;

  const LoadingButton.text({
    super.key,
    required this.label,
    required this.onPressed,
    required this.busy,
    this.busyLabel,
    this.icon,
    this.fullWidth = false,
  }) : style = LoadingButtonStyle.text;

  final String label;
  final String? busyLabel;
  final VoidCallback? onPressed;
  final bool busy;
  final IconData? icon;
  final LoadingButtonStyle style;
  final bool fullWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final effectiveOnPressed = busy ? null : onPressed;

    Widget child;
    switch (style) {
      case LoadingButtonStyle.filled:
        child = FilledButton.icon(
          onPressed: effectiveOnPressed,
          icon: _buildLeading(theme),
          label: _buildLabel(theme, scheme.onPrimary, bold: true),
        );
      case LoadingButtonStyle.outlined:
        child = OutlinedButton.icon(
          onPressed: effectiveOnPressed,
          icon: _buildLeading(theme),
          label: _buildLabel(theme, scheme.primary, bold: false),
        );
      case LoadingButtonStyle.text:
        child = TextButton.icon(
          onPressed: effectiveOnPressed,
          icon: _buildLeading(theme),
          label: _buildLabel(theme, scheme.primary, bold: false),
        );
    }

    if (!fullWidth) return child;
    return SizedBox(width: double.infinity, child: child);
  }

  Widget _buildLeading(ThemeData theme) {
    if (busy) {
      return SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: _spinnerColor(theme),
        ),
      );
    }
    if (icon != null) return Icon(icon, size: 18);
    return const SizedBox.shrink();
  }

  Widget _buildLabel(
    ThemeData theme,
    Color baseColor, {
    required bool bold,
  }) {
    if (busy && busyLabel != null) {
      return Text(
        busyLabel!,
        style: theme.textTheme.labelLarge?.copyWith(
          color: baseColor,
          fontWeight: bold ? FontWeight.w600 : FontWeight.w500,
        ),
      );
    }
    if (busy) {
      // No busyLabel — spinner alone communicates the in-flight state.
      // The label is suppressed so the button width stays stable.
      return const SizedBox.shrink();
    }
    return Text(
      label,
      style: theme.textTheme.labelLarge?.copyWith(
        color: bold ? baseColor : null,
        fontWeight: bold ? FontWeight.w600 : FontWeight.w500,
      ),
    );
  }

  Color _spinnerColor(ThemeData theme) {
    switch (style) {
      case LoadingButtonStyle.filled:
        return theme.colorScheme.onPrimary;
      case LoadingButtonStyle.outlined:
      case LoadingButtonStyle.text:
        return theme.colorScheme.primary;
    }
  }
}

/// Compact icon-only loading affordance for AppBar slots where a
/// full-width button doesn't fit (e.g. email filters refresh icon).
/// Renders a spinner while [busy] is true, otherwise the supplied
/// icon — keeps the slot's footprint identical so the AppBar
/// doesn't reflow.
class LoadingIconButton extends StatelessWidget {
  const LoadingIconButton({
    super.key,
    required this.busy,
    required this.onPressed,
    required this.icon,
    this.tooltip,
    this.spinnerSize = 18,
    this.spinnerStroke = 2,
  });

  final bool busy;
  final VoidCallback? onPressed;
  final IconData icon;
  final String? tooltip;
  final double spinnerSize;
  final double spinnerStroke;

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return IconButton(
        tooltip: tooltip,
        onPressed: null,
        icon: SizedBox(
          width: spinnerSize,
          height: spinnerSize,
          child: CircularProgressIndicator(strokeWidth: spinnerStroke),
        ),
      );
    }
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon),
    );
  }
}
