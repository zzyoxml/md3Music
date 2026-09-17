import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 实色背景上的文字不加阴影。
///
/// 启用背景图 + 「文字阴影」开关时，全局 textTheme 会被附加一层光晕
/// （见 `MyApp._applyBackgroundOverrides`），改善壁纸上的可读性。但被不透明
/// 表面（卡片、实色胶囊、对话框等）盖住的区域根本看不到壁纸，光晕在那里
/// 只会让文字发虚 —— 这类子树包进本组件即可。
///
/// 子树内的主题文字层级和 [DefaultTextStyle] 都会去掉阴影：不带 style 的
/// [Text] 走 [DefaultTextStyle]（由上层 Material 从带阴影的 textTheme 建好），
/// 只换 [Theme] 管不到那条路径。
///
/// 全局没有阴影时等价于原样透传，不必再判断开关状态。
class NoTextShadow extends StatelessWidget {
  const NoTextShadow({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final defaultStyle = DefaultTextStyle.of(context);
    return Theme(
      data: theme.copyWith(
        textTheme: AppTheme.stripTextShadows(theme.textTheme),
        primaryTextTheme: AppTheme.stripTextShadows(theme.primaryTextTheme),
      ),
      child: DefaultTextStyle(
        style: AppTheme.withoutTextShadow(defaultStyle.style)!,
        textAlign: defaultStyle.textAlign,
        softWrap: defaultStyle.softWrap,
        overflow: defaultStyle.overflow,
        maxLines: defaultStyle.maxLines,
        textWidthBasis: defaultStyle.textWidthBasis,
        textHeightBehavior: defaultStyle.textHeightBehavior,
        child: child,
      ),
    );
  }
}
