import 'package:flutter/material.dart';

/// M3 Expressive Typography 构建器
///
/// 参考：https://m3.material.io/styles/typography/type-scale-tokens
/// M3 Expressive 相对原 M3 的关键变化：
/// - Display Large 57→64sp，字重 w400→w300（更细更长，强调"展示性"）
/// - Display Medium 45→52sp（更大）
/// - Headline 引入 w500 字重对比（原全 w400）
/// - Title Large 字重 w600→w500（更柔和的标题强调）
/// - Label Large 字重 w600→w700（按钮文字更突出，对比更强）
///
/// fontFamily/fontFamilyFallback 仍由调用方（app_theme.dart）透传控制，
/// 本函数只负责字号/字重/行高/字间距的 M3 Expressive 规范。
class M3ExpressiveTypography {
  M3ExpressiveTypography._();

  /// 构建 M3 Expressive TextTheme
  ///
  /// [onSurfaceColor] 通常传 `colorScheme.onSurface`
  /// [fontFamily] 透传给所有 TextStyle（null 时走系统字体链）
  static TextTheme build(Color onSurfaceColor, {String? fontFamily}) {
    return TextTheme(
      // Display — 大标题/数字展示，M3E 强调"细长大"
      displayLarge: TextStyle(
        fontSize: 64,
        fontWeight: FontWeight.w300,
        height: 1.12,
        letterSpacing: -0.25,
        color: onSurfaceColor,
        fontFamily: fontFamily,
      ),
      displayMedium: TextStyle(
        fontSize: 52,
        fontWeight: FontWeight.w400,
        height: 1.15,
        letterSpacing: 0,
        color: onSurfaceColor,
        fontFamily: fontFamily,
      ),
      displaySmall: TextStyle(
        fontSize: 36,
        fontWeight: FontWeight.w400,
        height: 1.22,
        letterSpacing: 0,
        color: onSurfaceColor,
        fontFamily: fontFamily,
      ),
      // Headline — 区块标题，M3E 引入 w500 对比
      headlineLarge: TextStyle(
        fontSize: 36,
        fontWeight: FontWeight.w500,
        height: 1.25,
        letterSpacing: 0,
        color: onSurfaceColor,
        fontFamily: fontFamily,
      ),
      headlineMedium: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w400,
        height: 1.29,
        letterSpacing: 0,
        color: onSurfaceColor,
        fontFamily: fontFamily,
      ),
      headlineSmall: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w400,
        height: 1.33,
        letterSpacing: 0,
        color: onSurfaceColor,
        fontFamily: fontFamily,
      ),
      // Title — 卡片/列表项标题，M3E 把 w600 调为 w500（更柔和）
      titleLarge: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w500,
        height: 1.27,
        letterSpacing: 0,
        color: onSurfaceColor,
        fontFamily: fontFamily,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        height: 1.5,
        letterSpacing: 0.15,
        color: onSurfaceColor,
        fontFamily: fontFamily,
      ),
      titleSmall: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        height: 1.43,
        letterSpacing: 0.1,
        color: onSurfaceColor,
        fontFamily: fontFamily,
      ),
      // Body — 正文，保持原 M3 规范
      bodyLarge: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        height: 1.5,
        letterSpacing: 0.5,
        color: onSurfaceColor,
        fontFamily: fontFamily,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        height: 1.43,
        letterSpacing: 0.25,
        color: onSurfaceColor,
        fontFamily: fontFamily,
      ),
      bodySmall: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        height: 1.33,
        letterSpacing: 0.4,
        color: onSurfaceColor,
        fontFamily: fontFamily,
      ),
      // Label — 按钮/标签，M3E 把 w600 调为 w700（更突出对比）
      labelLarge: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        height: 1.43,
        letterSpacing: 0.1,
        color: onSurfaceColor,
        fontFamily: fontFamily,
      ),
      labelMedium: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        height: 1.33,
        letterSpacing: 0.5,
        color: onSurfaceColor,
        fontFamily: fontFamily,
      ),
      labelSmall: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        height: 1.45,
        letterSpacing: 0.5,
        color: onSurfaceColor,
        fontFamily: fontFamily,
      ),
    );
  }
}
