import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Centralized palette, spacing, radius + Material 3 themes for Pocket.
///
/// Brand: deep indigo (primary) + warm amber (accent). Light surfaces
/// lean cool slate; dark surfaces lean warm indigo-black. Inter type,
/// tight rhythm, refined radius scale.
class AppColors {
  AppColors._();

  static const indigo = Color(0xFF4F46E5);
  static const indigoDeep = Color(0xFF4338CA);
  static const indigoDark = Color(0xFF818CF8);
  static const indigoDarkDeep = Color(0xFF6366F1);

  static const amber = Color(0xFFF59E0B);
  static const amberDeep = Color(0xFFD97706);
  static const amberDark = Color(0xFFFCD34D);

  static const success = Color(0xFF10B981);
  static const successDark = Color(0xFF34D399);
  static const danger = Color(0xFFEF4444);
  static const dangerDark = Color(0xFFF87171);

  static const pageBgLight = Color(0xFFF6F7FB);
  static const pageBgDark = Color(0xFF0B0F1A);
}

class AppSpacing {
  AppSpacing._();
  static const xxs = 2.0;
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const xxl = 24.0;
  static const xxxl = 32.0;
  static const huge = 48.0;
  static const pagePadding = 16.0;
  static const sectionGap = 20.0;

  // Floating bottom nav: bar height (62) + bottom margin (10) + buffer
  // so the last list row clears the pill comfortably.
  static const floatingBarContentPadding = 104.0;

  // How far to lift a FAB so it clears the floating nav pill. Both are
  // inset by the bottom safe area, so it cancels out: pill top sits 72
  // (10 + 62) above the inset, the FAB sits 16 above it — 72 - 4 gap - 16
  // = 52. Sits close so the two feel like one continuous surface.
  static const fabFloatingNavLift = 52.0;

  // SnackBar bottom margin when shown above the floating nav pill. Pill
  // top sits 72 above the inset; we want 16dp gap, plus a touch more so the
  // snackbar doesn't visually crowd the pill.
  static const snackbarFloatingBarMargin = 92.0;

  // Compact pill-style FAB dimensions (used by [ShellFab]).
  // Sized to feel substantial next to the floating nav pill and to
  // match the height of the form "Save" buttons (52 dp).
  static const fabPillHeight = 48.0;
  static const fabPillHPad = 18.0;
  static const fabIconSize = 20.0;
  static const fabLabelSize = 14.0;
}

class AppRadius {
  AppRadius._();
  static const sm = 10.0;
  static const md = 14.0;
  static const lg = 16.0;
  static const xl = 28.0;
  static const pill = 999.0;
}

class AppTheme {
  AppTheme._();

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final primary = isDark ? AppColors.indigoDarkDeep : AppColors.indigo;
    final accent = isDark ? AppColors.amberDark : AppColors.amber;
    final bg = isDark ? AppColors.pageBgDark : AppColors.pageBgLight;

    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: brightness,
      primary: primary,
      secondary: accent,
      tertiary: accent,
      surface: isDark ? const Color(0xFF131726) : Colors.white,
      surfaceContainerLowest: isDark ? const Color(0xFF0B0F1A) : Colors.white,
      surfaceContainerLow: isDark ? const Color(0xFF11151F) : const Color(0xFFFAFBFE),
      surfaceContainer: isDark ? const Color(0xFF161B27) : const Color(0xFFF1F3F8),
      surfaceContainerHigh: isDark ? const Color(0xFF1C2230) : const Color(0xFFEAEDF3),
      surfaceContainerHighest: isDark ? const Color(0xFF222937) : const Color(0xFFE3E7EE),
      outline: isDark ? const Color(0xFF2C3344) : const Color(0xFFE5E8EE),
      outlineVariant: isDark ? const Color(0xFF1F2531) : const Color(0xFFEDEFF4),
      error: isDark ? AppColors.dangerDark : AppColors.danger,
      onPrimary: Colors.white,
      onSecondary: const Color(0xFF1A1500),
      onTertiary: const Color(0xFF1A1500),
    );

    final baseTypography =
        isDark ? Typography.whiteMountainView : Typography.blackMountainView;
    final textTheme = GoogleFonts.interTextTheme(baseTypography).copyWith(
      displayLarge: GoogleFonts.inter(
        fontSize: 40,
        fontWeight: FontWeight.w800,
        letterSpacing: -1.0,
        color: scheme.onSurface,
      ),
      displayMedium: GoogleFonts.inter(
        fontSize: 32,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.6,
        color: scheme.onSurface,
      ),
      headlineLarge: GoogleFonts.inter(
        fontSize: 26,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.4,
        color: scheme.onSurface,
      ),
      headlineMedium: GoogleFonts.inter(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
        color: scheme.onSurface,
      ),
      titleLarge: GoogleFonts.inter(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.1,
        color: scheme.onSurface,
      ),
      titleMedium: GoogleFonts.inter(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: scheme.onSurface,
      ),
      titleSmall: GoogleFonts.inter(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: scheme.onSurface,
      ),
      bodyLarge: GoogleFonts.inter(
        fontSize: 15,
        fontWeight: FontWeight.w500,
        color: scheme.onSurface,
      ),
      bodyMedium: GoogleFonts.inter(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: scheme.onSurface,
      ),
      bodySmall: GoogleFonts.inter(
        fontSize: 12.5,
        fontWeight: FontWeight.w500,
        color: scheme.onSurfaceVariant,
      ),
      labelLarge: GoogleFonts.inter(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
        color: scheme.onSurface,
      ),
      labelMedium: GoogleFonts.inter(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
        color: scheme.onSurface,
      ),
      labelSmall: GoogleFonts.inter(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.4,
        color: scheme.onSurfaceVariant,
      ),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      dividerColor: scheme.outlineVariant,
      textTheme: textTheme,
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: AppSpacing.pagePadding,
        toolbarHeight: 52,
        titleTextStyle: textTheme.titleLarge,
        actionsIconTheme: IconThemeData(color: scheme.onSurface, size: 22),
        iconTheme: IconThemeData(color: scheme.onSurface, size: 22),
      ),
      cardTheme: CardThemeData(
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: BorderSide(color: scheme.outlineVariant, width: 0.6),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          textStyle: textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.1,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          side: BorderSide(color: scheme.outline, width: 1),
          textStyle: textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          textStyle: textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        extendedTextStyle: textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.md,
        ),
        hintStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        labelStyle: textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: scheme.outline, width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: scheme.outline, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: primary, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: scheme.error, width: 1),
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
        ),
        side: BorderSide(color: scheme.outline, width: 1.4),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 0.8,
        space: 0,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: primary,
        linearTrackColor: scheme.surfaceContainerHigh,
        circularTrackColor: scheme.surfaceContainerHigh,
        linearMinHeight: 8,
      ),
    );
  }
}