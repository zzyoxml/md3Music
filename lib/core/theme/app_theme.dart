import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/app_background.dart';

/// 路由过渡：M3 FadeForwards 动效 + 页面自带背景。
///
/// 启用全局背景图时页面背景透明，路由过渡中新旧页面内容会叠加重叠。
/// 本 builder 给每个 MaterialPageRoute 的过渡 child **内嵌 [AppBackground]**，
/// 使背景图作为页面的一部分一起滑动入场（随画面位移，无跳变），且背景图
/// 不透明盖住下层旧页面（无重叠）。对所有 MaterialPageRoute 全局生效。
class _BgSafeFadeForwardsBuilder extends PageTransitionsBuilder {
  const _BgSafeFadeForwardsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 背景作为页面底层，随 FadeForwards 一起滑动/淡入
    final withBg = Stack(
      fit: StackFit.expand,
      children: [
        const AppBackground(),
        child,
      ],
    );
    // FadeForwards 基础动效：新页面右侧滑入 + 淡入（无白色屏障层）
    return FadeForwardsPageTransitionsBuilder().buildTransitions(
      route,
      context,
      animation,
      secondaryAnimation,
      withBg,
    );
  }
}

class AppTheme {
  AppTheme._();

  /// 8 个预设种子色，取自 Material 3 官方 Theme Builder 的 key tone 40。
  /// 顺序：色环顺序（蓝→紫→青→绿→黄→橙→红→粉）。
  /// 索引 0 是默认色，与 [defaultSeedColor] 保持一致。
  static const List<Color> presetSeedColors = [
    Color(0xFF0061A4), // 蓝（默认）
    Color(0xFF6750A4), // 紫（M3 默认）
    Color(0xFF006A6A), // 青绿
    Color(0xFF386A20), // 绿
    Color(0xFF7E5700), // 黄
    Color(0xFF8C4A00), // 橙
    Color(0xFFB3261E), // 红
    Color(0xFF984061), // 粉
  ];

  /// 默认种子色（蓝色），用于未启用系统主题色且未手动选择时的兜底。
  /// 必须独立定义为 const，不能引用 [presetSeedColors] 的索引（非常量表达式）。
  static const Color defaultSeedColor = Color(0xFF0061A4);

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
  ///
  /// [fontFamily] 控制全局字体：
  /// - null：使用系统字体优先（让 Flutter 走系统字体链，SimHei 仅作 fallback）
  /// - 'SimHei'：使用内置打包的 SimHei
  /// - 'UserCustomFont'：使用用户通过 SAF 选择并加载的自定义字体
  static ThemeData lightThemeFromSeed(Color seedColor, {String? fontFamily}) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.light,
    );
    return _buildTheme(colorScheme, Brightness.light, fontFamily: fontFamily);
  }

  /// 根据传入的种子色构建深色主题。
  ///
  /// [useOledBlack] 为 true 时启用 OLED 纯黑变体：
  /// 将 [ColorScheme] 的 surface 系列覆盖为 [Colors.black] / 极深灰，
  /// 保留 onSurface 等前景色不变（保证对比度），
  /// surfaceContainerHigh/Highest 用极深灰保留卡片层级感。
  ///
  /// [fontFamily] 控制全局字体，参见 [lightThemeFromSeed]。
  static ThemeData darkThemeFromSeed(
    Color seedColor, {
    bool useOledBlack = false,
    String? fontFamily,
  }) {
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
    return _buildTheme(colorScheme, Brightness.dark, fontFamily: fontFamily);
  }

  static ThemeData _buildTheme(
    ColorScheme colorScheme,
    Brightness brightness, {
    String? fontFamily,
  }) {
    final isLight = brightness == Brightness.light;

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      brightness: brightness,
      // 全局路由过渡：Android 用 FadeForwards（滑动 + 淡入）+ 过渡期间
      // 背景遮罩（避免透明页面过渡重叠，完成后再露出背景图）。
      // 其余平台（iOS/macOS）保留系统默认 Cupertino 过渡。
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: _BgSafeFadeForwardsBuilder(),
        },
      ),
      // fontFamily 为 null 时，Flutter 会走系统字体链（Android 上是 Roboto +
      // Noto Sans CJK），符合"优先展示用户手机字体"需求。
      // fontFamilyFallback 兜底链保证 SimHei 在系统字体缺字符时仍能命中。
      fontFamily: fontFamily,
      fontFamilyFallback: _cjkFontFallback,
      scaffoldBackgroundColor: colorScheme.surface,
      cardTheme: CardThemeData(
        elevation: isLight ? 1 : 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        color: colorScheme.surfaceContainer,
        surfaceTintColor: colorScheme.surfaceTint,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: isLight ? 3 : 1,
        surfaceTintColor: colorScheme.surfaceTint,
        centerTitle: true,
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
        // 显式传 fontFamily，确保 AppBar 标题在切换自定义字体时立即生效
        // （ThemeData.fontFamily 不会自动注入到 *ThemeData 中独立设置的 TextStyle）
        titleTextStyle: _buildTextStyle(
          colorScheme.onSurface,
          22,
          FontWeight.w400,
          fontFamily: fontFamily,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 80,
        backgroundColor: colorScheme.surface,
        // 关掉 Flutter 原生 NavigationIndicator：改由 _AnimatedTabIcon 自己画
        // 带 M3E Expressive 风格的弹簧胶囊（单轴 X 拉伸 + 过冲）
        indicatorColor: Colors.transparent,
        surfaceTintColor: colorScheme.surfaceTint,
        elevation: 0,
        // 只有选中 tab 显示文字：原生会自动上移 icon 让位 + 淡入 label
        // （见 navigation_bar.dart _NavigationDestinationLayoutDelegate）
        labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: colorScheme.onSecondaryContainer);
          }
          return IconThemeData(color: colorScheme.onSurfaceVariant);
        }),
        // 显式传 fontFamily：NavigationBar 的 labelTextStyle 走 WidgetStateProperty，
        // 不会自动合并 ThemeData.fontFamily，必须显式指定才能让 tab 栏文字跟随自定义字体
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return _buildTextStyle(
              colorScheme.onSecondaryContainer,
              12,
              FontWeight.w600,
              fontFamily: fontFamily,
            );
          }
          return _buildTextStyle(
            colorScheme.onSurfaceVariant,
            12,
            FontWeight.w500,
            fontFamily: fontFamily,
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
          fontFamily: fontFamily,
        ),
        unselectedLabelTextStyle: _buildTextStyle(
          colorScheme.onSurfaceVariant,
          12,
          FontWeight.w500,
          fontFamily: fontFamily,
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
        // 显式传 fontFamily：搜索历史/热门搜索 chip 的 label 走这里，
        // 不指定的话不会跟随 ThemeData.fontFamily
        labelStyle: _buildTextStyle(
          colorScheme.onSurface,
          14,
          FontWeight.w500,
          fontFamily: fontFamily,
        ),
        secondaryLabelStyle: _buildTextStyle(
          colorScheme.onSecondaryContainer,
          14,
          FontWeight.w500,
          fontFamily: fontFamily,
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
      // 显式把 fontFamily 注入 textTheme：发现页"每日推荐"标题、搜索页"搜索历史"/"热门搜索"标题
      // 都用 Theme.of(context).textTheme.titleLarge/titleMedium，必须显式 apply 才能跟随自定义字体
      textTheme: _buildTextTheme(colorScheme, fontFamily: fontFamily),
      primaryTextTheme: _buildTextTheme(colorScheme, fontFamily: fontFamily),
    );
  }

  static TextStyle _buildTextStyle(
    Color color,
    double size,
    FontWeight weight, {
    String? fontFamily,
  }) {
    return TextStyle(
      color: color,
      fontSize: size,
      fontWeight: weight,
      // 显式指定 fontFamily：未指定时 Flutter 不会自动从 ThemeData.fontFamily 继承
      // （仅在 DefaultTextStyle 合并路径下继承；*ThemeData 中独立设置的 TextStyle 不走该路径）
      fontFamily: fontFamily,
      letterSpacing: size >= 20 ? 0 : 0.25,
      height: size >= 20 ? 1.3 : 1.4,
    );
  }

  static TextTheme _buildTextTheme(ColorScheme colorScheme, {String? fontFamily}) {
    return TextTheme(
      displayLarge: TextStyle(
        fontSize: 57,
        fontWeight: FontWeight.w400,
        height: 1.12,
        letterSpacing: -0.25,
        color: colorScheme.onSurface,
        fontFamily: fontFamily,
      ),
      displayMedium: TextStyle(
        fontSize: 45,
        fontWeight: FontWeight.w400,
        height: 1.16,
        letterSpacing: 0,
        color: colorScheme.onSurface,
        fontFamily: fontFamily,
      ),
      displaySmall: TextStyle(
        fontSize: 36,
        fontWeight: FontWeight.w400,
        height: 1.22,
        letterSpacing: 0,
        color: colorScheme.onSurface,
        fontFamily: fontFamily,
      ),
      headlineLarge: TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w400,
        height: 1.25,
        letterSpacing: 0,
        color: colorScheme.onSurface,
        fontFamily: fontFamily,
      ),
      headlineMedium: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w400,
        height: 1.29,
        letterSpacing: 0,
        color: colorScheme.onSurface,
        fontFamily: fontFamily,
      ),
      headlineSmall: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w400,
        height: 1.33,
        letterSpacing: 0,
        color: colorScheme.onSurface,
        fontFamily: fontFamily,
      ),
      titleLarge: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        height: 1.27,
        letterSpacing: 0,
        color: colorScheme.onSurface,
        fontFamily: fontFamily,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.5,
        letterSpacing: 0.15,
        color: colorScheme.onSurface,
        fontFamily: fontFamily,
      ),
      titleSmall: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        height: 1.43,
        letterSpacing: 0.1,
        color: colorScheme.onSurface,
        fontFamily: fontFamily,
      ),
      bodyLarge: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        height: 1.5,
        letterSpacing: 0.5,
        color: colorScheme.onSurface,
        fontFamily: fontFamily,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        height: 1.43,
        letterSpacing: 0.25,
        color: colorScheme.onSurface,
        fontFamily: fontFamily,
      ),
      bodySmall: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        height: 1.33,
        letterSpacing: 0.4,
        color: colorScheme.onSurface,
        fontFamily: fontFamily,
      ),
      labelLarge: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        height: 1.43,
        letterSpacing: 0.1,
        color: colorScheme.onSurface,
        fontFamily: fontFamily,
      ),
      labelMedium: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        height: 1.33,
        letterSpacing: 0.5,
        color: colorScheme.onSurface,
        fontFamily: fontFamily,
      ),
      labelSmall: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        height: 1.45,
        letterSpacing: 0.5,
        color: colorScheme.onSurface,
        fontFamily: fontFamily,
      ),
    );
  }
}
