import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  static const _primary = Color(0xFF3B82F6);
  static const _primaryPressed = Color(0xFF2563EB);
  static const _error = Color(0xFFDC2626);

  static ThemeData get dark {
    const scaffoldColor = Color(0xFF1E293B);
    const appBarColor = Color(0xFF111827);
    const surface = Color(0xFF1F2937);
    const surfaceVariant = Color(0xFF374151);
    const mutedText = Color(0xFF9CA3AF);

    final colorScheme = ColorScheme(
      brightness: Brightness.dark,
      primary: _primary,
      onPrimary: Colors.white,
      secondary: _primaryPressed,
      onSecondary: Colors.white,
      error: _error,
      onError: Colors.white,
      surface: surface,
      onSurface: Colors.white,
      surfaceContainerHighest: surfaceVariant,
      onSurfaceVariant: mutedText,
      outline: surfaceVariant,
    );

    return _themeFrom(
      colorScheme: colorScheme,
      scaffoldColor: scaffoldColor,
      appBarColor: appBarColor,
      surface: surface,
      mutedText: mutedText,
    );
  }

  static ThemeData get light {
    const scaffoldColor = Color(0xFFF3F4F6);
    const surface = Colors.white;
    const text = Color(0xFF111827);
    const mutedText = Color(0xFF6B7280);

    final colorScheme = ColorScheme(
      brightness: Brightness.light,
      primary: _primary,
      onPrimary: Colors.white,
      secondary: _primaryPressed,
      onSecondary: Colors.white,
      error: _error,
      onError: Colors.white,
      surface: surface,
      onSurface: text,
      surfaceContainerHighest: const Color(0xFFE5E7EB),
      onSurfaceVariant: mutedText,
      outline: const Color(0xFFE5E7EB),
    );

    return _themeFrom(
      colorScheme: colorScheme,
      scaffoldColor: scaffoldColor,
      appBarColor: surface,
      surface: surface,
      mutedText: mutedText,
    );
  }

  static ThemeData _themeFrom({
    required ColorScheme colorScheme,
    required Color scaffoldColor,
    required Color appBarColor,
    required Color surface,
    required Color mutedText,
  }) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: scaffoldColor,
      appBarTheme: AppBarTheme(
        backgroundColor: appBarColor,
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      textTheme: ThemeData(brightness: colorScheme.brightness).textTheme.apply(
        bodyColor: colorScheme.onSurface,
        displayColor: colorScheme.onSurface,
      ),
      iconTheme: IconThemeData(color: colorScheme.onSurface),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surface,
        contentTextStyle: TextStyle(color: colorScheme.onSurface),
        behavior: SnackBarBehavior.floating,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style:
            ElevatedButton.styleFrom(
              backgroundColor: _primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ).copyWith(
              overlayColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.pressed)
                    ? _primaryPressed
                    : null,
              ),
            ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        hintStyle: TextStyle(color: mutedText),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _primary, width: 2),
        ),
      ),
    );
  }
}
