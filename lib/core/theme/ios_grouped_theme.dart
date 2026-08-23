import 'package:flutter/material.dart';

/// iOS 分组卡片风格共享工具（一级页面用）。
///
/// 语义色与「设置」/「我的」页一致：中性色固定、tint 用主题品牌色、浅深色自适应。
abstract final class IosColors {
  // ---- 中性色（浅 / 深） ----
  static const Color _lightBg = Colors.white;
  static const Color _darkBg = Color(0xFF000000);
  static const Color _lightCard = Colors.white;
  static const Color _darkCard = Color(0xFF1C1C1E);
  static const Color _lightLabel = Color(0xFF1C1C1E);
  static const Color _darkLabel = Colors.white;
  static const Color _lightSecondary = Color(0xFF8E8E93);
  static const Color _darkSecondary = Color(0xFFAEAEB2);
  static const Color _lightSeparator = Color(0xFFE5E5E5);
  static const Color _darkSeparator = Color(0xFF38383A);

  static bool _isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  /// 页面背景
  static Color bg(BuildContext context) => _isDark(context) ? _darkBg : _lightBg;

  /// 卡片背景
  static Color card(BuildContext context) =>
      _isDark(context) ? _darkCard : _lightCard;

  /// 主标签文字
  static Color label(BuildContext context) =>
      _isDark(context) ? _darkLabel : _lightLabel;

  /// 副标签 / 说明文字
  static Color secondary(BuildContext context) =>
      _isDark(context) ? _darkSecondary : _lightSecondary;

  /// 分隔线
  static Color separator(BuildContext context) =>
      _isDark(context) ? _darkSeparator : _lightSeparator;

  /// 卡片圆角
  static const double radius = 12;

  /// 语义色覆盖（tint 保持主题 primary）
  static ColorScheme scheme(BuildContext context) {
    final base = Theme.of(context).colorScheme;
    return base.copyWith(
      surface: card(context),
      onSurface: label(context),
      onSurfaceVariant: secondary(context),
      surfaceContainerLowest: bg(context),
    );
  }

  /// 圆角卡片装饰（card 底色 + 圆角）
  static BoxDecoration cardDecoration(BuildContext context) => BoxDecoration(
        color: card(context),
        borderRadius: BorderRadius.circular(radius),
      );
}

/// iOS 风格圆角卡片容器：可选行间缩进分隔线（分隔线颜色取主题 dividerColor）。
class IosCard extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsetsGeometry? margin;
  final EdgeInsetsGeometry padding;
  final bool separated;

  const IosCard({
    super.key,
    required this.children,
    this.margin,
    this.padding = EdgeInsets.zero,
    this.separated = true,
  });

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (separated && i > 0) {
        rows.add(const Divider(height: 0.5, thickness: 0.5, indent: 16));
      }
      rows.add(children[i]);
    }
    return Container(
      margin: margin,
      padding: padding,
      decoration: IosColors.cardDecoration(context),
      clipBehavior: Clip.antiAlias,
      child: Column(children: rows),
    );
  }
}
