import 'package:flutter/material.dart';

/// Light design system for Anker Recorder.
class AppColors {
  AppColors._();

  static const bg = Color(0xFFF5F6F8);
  static const bgElevated = Color(0xFFFFFFFF);
  static const bgCard = Color(0xFFFFFFFF);
  static const bgCardHover = Color(0xFFF0F2F5);
  static const border = Color(0xFFE2E5EB);
  static const borderFocus = Color(0xFF3D8BFF);

  static const textPrimary = Color(0xFF12141A);
  static const textSecondary = Color(0xFF5C6578);
  static const textMuted = Color(0xFF8B93A7);

  static const accent = Color(0xFF3B7CFF);
  static const accentSoft = Color(0xFFE8F0FF);
  static const mint = Color(0xFF12B886);
  static const amber = Color(0xFFE67700);
  static const coral = Color(0xFFE03131);
  static const violet = Color(0xFF7950F2);

  static const gradientTop = Color(0xFFFAFBFC);
  static const gradientBottom = Color(0xFFF0F2F5);

  /// Soft drop shadow for cards on light surfaces.
  static List<BoxShadow> get cardShadow => [
    BoxShadow(
      color: const Color(0xFF0B0D12).withValues(alpha: 0.06),
      blurRadius: 16,
      offset: const Offset(0, 4),
    ),
    BoxShadow(
      color: const Color(0xFF0B0D12).withValues(alpha: 0.03),
      blurRadius: 4,
      offset: const Offset(0, 1),
    ),
  ];
}

class AppTheme {
  static ThemeData get light {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: AppColors.bg,
      colorScheme: const ColorScheme.light(
        surface: AppColors.bgElevated,
        primary: AppColors.accent,
        secondary: AppColors.mint,
        error: AppColors.coral,
        onPrimary: Colors.white,
        onSurface: AppColors.textPrimary,
        outline: AppColors.border,
      ),
    );

    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
          letterSpacing: -0.3,
        ),
        iconTheme: IconThemeData(color: AppColors.textPrimary),
      ),
      textTheme: const TextTheme(
        displayLarge: TextStyle(
          fontSize: 34,
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary,
          letterSpacing: -1,
          height: 1.1,
        ),
        headlineMedium: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
          letterSpacing: -0.4,
        ),
        titleMedium: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
        ),
        bodyLarge: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w400,
          color: AppColors.textPrimary,
          height: 1.4,
        ),
        bodyMedium: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w400,
          color: AppColors.textSecondary,
          height: 1.4,
        ),
        labelLarge: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
          color: AppColors.textPrimary,
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.border,
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.bgElevated,
        contentTextStyle: const TextStyle(color: AppColors.textPrimary),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        behavior: SnackBarBehavior.floating,
        elevation: 4,
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(AppColors.bgCard),
        ),
      ),
    );
  }

  /// Backward-compatible alias.
  static ThemeData get dark => light;
}
