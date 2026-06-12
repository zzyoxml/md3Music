import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  static const Color _seedColor = Color(0xFF6750A4);

  // CJK 字体回退链 - 按平台优先级排序:
  // 1) Web 浏览器(Windows + Edge) 优先用系统自带的 "Microsoft YaHei" (无需下载)
  // 2) macOS / iOS: PingFang SC
  // 3) Linux: WenQuanYi Micro Hei
  // 4) 打包的 SimHei (assets/fonts/simhei.ttf) 兜底
  // 5) 通用 sans-serif
  // 注意: fontFamilyFallback 在 Flutter Web 里会映射为 CSS font-family 链,
  // 浏览器会按顺序查找已安装的字体, 命中即用. 所以系统字体优先能避免走 Google CDN.
  static const List<String> _cjkFontFallback = [
    'Microsoft YaHei',
    'Microsoft YaHei UI',
    'PingFang SC',
    'Hiragino Sans GB',
    'WenQuanYi Micro Hei',
    'Source Han Sans CN',
    'Source Han Sans SC',
    'Noto Sans CJK SC',
    'Noto Sans SC',
    'SimHei',
    'sans-serif',
  ];

  static ThemeData get lightTheme {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: _seedColor,
      brightness: Brightness.light,
    );
    return _buildTheme(colorScheme, Brightness.light);
  }

  static ThemeData get darkTheme {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: _seedColor,
      brightness: Brightness.dark,
    );
    return _buildTheme(colorScheme, Brightness.dark);
  }

  static ThemeData _buildTheme(ColorScheme colorScheme, Brightness brightness) {
    final isLight = brightness == Brightness.light;

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      brightness: brightness,
      fontFamily: 'SimHei',
      fontFamilyFallback: _cjkFontFallback,
      scaffoldBackgroundColor: colorScheme.surface,
      cardTheme: CardThemeData(
        elevation: isLight ? 1 : 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        color: colorScheme.surfaceContainerLow,
        surfaceTintColor: colorScheme.surfaceTint,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: isLight ? 3 : 1,
        surfaceTintColor: colorScheme.surfaceTint,
        centerTitle: false,
        titleTextStyle: _buildTextStyle(
          colorScheme.onSurface,
          22,
          FontWeight.w400,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 80,
        backgroundColor: colorScheme.surface,
        indicatorColor: colorScheme.secondaryContainer,
        surfaceTintColor: colorScheme.surfaceTint,
        elevation: 0,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: colorScheme.onSecondaryContainer);
          }
          return IconThemeData(color: colorScheme.onSurfaceVariant);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return _buildTextStyle(
              colorScheme.onSecondaryContainer,
              12,
              FontWeight.w600,
            );
          }
          return _buildTextStyle(
            colorScheme.onSurfaceVariant,
            12,
            FontWeight.w500,
          );
        }),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: colorScheme.surface,
        indicatorColor: colorScheme.secondaryContainer,
        elevation: 0,
        minWidth: 80,
        minExtendedWidth: 256,
        labelType: NavigationRailLabelType.all,
        selectedIconTheme: IconThemeData(
          color: colorScheme.onSecondaryContainer,
        ),
        unselectedIconTheme: IconThemeData(color: colorScheme.onSurfaceVariant),
        selectedLabelTextStyle: _buildTextStyle(
          colorScheme.onSecondaryContainer,
          12,
          FontWeight.w600,
        ),
        unselectedLabelTextStyle: _buildTextStyle(
          colorScheme.onSurfaceVariant,
          12,
          FontWeight.w500,
        ),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: colorScheme.surface,
        surfaceTintColor: colorScheme.surfaceTint,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colorScheme.surfaceContainerLow,
        surfaceTintColor: colorScheme.surfaceTint,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colorScheme.primaryContainer,
        foregroundColor: colorScheme.onPrimaryContainer,
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: colorScheme.surfaceContainerLow,
        selectedColor: colorScheme.secondaryContainer,
        labelStyle: _buildTextStyle(colorScheme.onSurface, 14, FontWeight.w500),
        secondaryLabelStyle: _buildTextStyle(
          colorScheme.onSecondaryContainer,
          14,
          FontWeight.w500,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: colorScheme.primary,
        inactiveTrackColor: colorScheme.surfaceContainerHighest,
        thumbColor: colorScheme.primary,
        overlayColor: colorScheme.primary.withValues(alpha: 0.12),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colorScheme.primary,
        linearTrackColor: colorScheme.surfaceContainerHighest,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: colorScheme.onSurfaceVariant,
        textColor: colorScheme.onSurface,
        selectedColor: colorScheme.primary,
        selectedTileColor: colorScheme.secondaryContainer,
      ),
      dividerTheme: DividerThemeData(
        color: colorScheme.outlineVariant,
        thickness: 1,
      ),
      textTheme: _buildTextTheme(colorScheme),
    );
  }

  static TextStyle _buildTextStyle(
    Color color,
    double size,
    FontWeight weight,
  ) {
    return TextStyle(
      color: color,
      fontSize: size,
      fontWeight: weight,
      letterSpacing: size >= 20 ? 0 : 0.25,
      height: size >= 20 ? 1.3 : 1.4,
    );
  }

  static TextTheme _buildTextTheme(ColorScheme colorScheme) {
    return TextTheme(
      displayLarge: TextStyle(
        fontSize: 57,
        fontWeight: FontWeight.w400,
        height: 1.12,
        letterSpacing: -0.25,
        color: colorScheme.onSurface,
      ),
      displayMedium: TextStyle(
        fontSize: 45,
        fontWeight: FontWeight.w400,
        height: 1.16,
        letterSpacing: 0,
        color: colorScheme.onSurface,
      ),
      displaySmall: TextStyle(
        fontSize: 36,
        fontWeight: FontWeight.w400,
        height: 1.22,
        letterSpacing: 0,
        color: colorScheme.onSurface,
      ),
      headlineLarge: TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w400,
        height: 1.25,
        letterSpacing: 0,
        color: colorScheme.onSurface,
      ),
      headlineMedium: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w400,
        height: 1.29,
        letterSpacing: 0,
        color: colorScheme.onSurface,
      ),
      headlineSmall: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w400,
        height: 1.33,
        letterSpacing: 0,
        color: colorScheme.onSurface,
      ),
      titleLarge: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w400,
        height: 1.27,
        letterSpacing: 0,
        color: colorScheme.onSurface,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.5,
        letterSpacing: 0.15,
        color: colorScheme.onSurface,
      ),
      titleSmall: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        height: 1.43,
        letterSpacing: 0.1,
        color: colorScheme.onSurface,
      ),
      bodyLarge: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        height: 1.5,
        letterSpacing: 0.5,
        color: colorScheme.onSurface,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        height: 1.43,
        letterSpacing: 0.25,
        color: colorScheme.onSurface,
      ),
      bodySmall: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        height: 1.33,
        letterSpacing: 0.4,
        color: colorScheme.onSurface,
      ),
      labelLarge: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        height: 1.43,
        letterSpacing: 0.1,
        color: colorScheme.onSurface,
      ),
      labelMedium: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        height: 1.33,
        letterSpacing: 0.5,
        color: colorScheme.onSurface,
      ),
      labelSmall: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        height: 1.45,
        letterSpacing: 0.5,
        color: colorScheme.onSurface,
      ),
    );
  }
}
