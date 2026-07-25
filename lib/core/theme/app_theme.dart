import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AppTheme {
  AppTheme._();

  /// 8 个预设种子色，取自 Material 3 官方 Theme Builder 的 key tone 40。
  /// 顺序：色环顺序（紫→蓝→青→绿→黄→橙→红→粉）。
  /// 索引 0 是默认色，与 [defaultSeedColor] 保持一致。
  static const List<Color> presetSeedColors = [
    Color(0xFF6750A4), // 紫（M3 默认）
    Color(0xFF0061A4), // 蓝
    Color(0xFF006A6A), // 青绿
    Color(0xFF386A20), // 绿
    Color(0xFF7E5700), // 黄
    Color(0xFF8C4A00), // 橙
    Color(0xFFB3261E), // 红
    Color(0xFF984061), // 粉
  ];

  /// 默认种子色（紫色），用于未启用系统主题色且未手动选择时的兜底。
  /// 必须独立定义为 const，不能引用 [presetSeedColors] 的索引（非常量表达式）。
  static const Color defaultSeedColor = Color(0xFF6750A4);

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
      seedColor: defaultSeedColor,
      brightness: Brightness.light,
    );
    return _buildTheme(colorScheme, Brightness.light);
  }

  static ThemeData get darkTheme {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: defaultSeedColor,
      brightness: Brightness.dark,
    );
    return _buildTheme(colorScheme, Brightness.dark);
  }

  /// 根据传入的种子色构建浅色主题。
  ///
  /// 用于「莫奈色」开关启用时，由 ThemeProvider 传入系统提取的主色。
  static ThemeData lightThemeFromSeed(Color seedColor) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.light,
    );
    return _buildTheme(colorScheme, Brightness.light);
  }

  /// 根据传入的种子色构建深色主题。
  ///
  /// [useOledBlack] 为 true 时启用 OLED 纯黑变体：
  /// 将 [ColorScheme] 的 surface 系列覆盖为 [Colors.black] / 极深灰，
  /// 保留 onSurface 等前景色不变（保证对比度），
  /// surfaceContainerHigh/Highest 用极深灰保留卡片层级感。
  static ThemeData darkThemeFromSeed(Color seedColor, {bool useOledBlack = false}) {
    var colorScheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.dark,
    );
    if (useOledBlack) {
      colorScheme = colorScheme.copyWith(
        surface: Colors.black,
        surfaceContainerLowest: Colors.black,
        surfaceContainerLow: Colors.black,
        surfaceContainer: Colors.black,
        // High/Highest 保留极深灰，让卡片/底栏仍有微妙层级感
        surfaceContainerHigh: const Color(0xFF111111),
        surfaceContainerHighest: const Color(0xFF1A1A1A),
        // onSurface 等前景色保持不变，确保文字对比度
        // inverseSurface 保持不变，确保 Snackbar 反色正常
      );
    }
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
        // 显式设置状态栏样式，避免 ScrollAwareAppBar 透明背景时
        // Flutter 根据 Colors.transparent（luminance=0）误判为深色背景，
        // 导致浅色主题下状态栏图标变白看不清。
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness:
              isLight ? Brightness.dark : Brightness.light,
          statusBarBrightness:
              isLight ? Brightness.light : Brightness.dark,
        ),
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
