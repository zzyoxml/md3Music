/// 歌词行级文字颜色规则（纯函数，不依赖任何 widget）。
///
/// 两件事集中在这里，避免渲染层与设置演示卡各算一遍而口径漂移：
/// 1. [resolveActiveLineColorValue]：当前行「已播色」怎么来
///    （自定义歌词文字色 > 动态取色混色 > 无）；
/// 2. [lineColorOverrideValue]：某一行该不该用「已播色」
///    （当前行恒用；上方行由独立开关决定）。
library;

import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// 当前行「已播色」的最小明度。
///
/// 深色背景下封面提取色可能过暗导致不可读，混色后统一把明度抬到该下限
/// （只抬明度、保留色相与饱和度，视觉上仍是封面色调的浅色）。
const double kActiveLyricMinLightness = 0.78;

/// 解析当前行「已播色」ARGB 值；null 表示回退主题默认歌词色。
///
/// 优先级（与改造前 `AppleLyricsView.build` 完全一致）：
/// 1. [customTextColor] 非空 → 直接使用（用户显式指定，压过一切）；
/// 2. [useDynamicColor] 且 [accentColor] 非空 → 白色与封面色按 [mixRatio]
///    线性混色，再把明度抬到 ≥ [kActiveLyricMinLightness]；
/// 3. 其余情况 → null（渲染层用 `LyricLayout.textColorValue`）。
///
/// [mixRatio] 非有限值按 0 处理，并夹到 [0, 1]。
int? resolveActiveLineColorValue({
  required bool useDynamicColor,
  required Color? accentColor,
  required Color? customTextColor,
  required double mixRatio,
}) {
  if (customTextColor != null) return customTextColor.toARGB32();
  if (!useDynamicColor || accentColor == null) return null;
  final double ratio = mixRatio.isFinite ? mixRatio.clamp(0.0, 1.0) : 0.0;
  final Color mixed = Color.lerp(const Color(0xFFFFFFFF), accentColor, ratio)!;
  final HSLColor hsl = HSLColor.fromColor(mixed);
  return hsl
      .withLightness(math.max(hsl.lightness, kActiveLyricMinLightness))
      .toColor()
      .toARGB32();
}

/// 某一行当前该用的颜色覆盖值；null = 用主题默认歌词色。
///
/// - 当前行：[activeLineColorValue]（可能为 null，则回退默认色）；
/// - 上方行：[aboveLineColorValue]（调用方已在开关关闭时传 null）；
/// - 其余（当前行以下）：null。
///
/// 两个入参都为 null 时一律返回 null——没有「已播色」可用时保持默认色。
int? lineColorOverrideValue({
  required int? activeLineColorValue,
  required int? aboveLineColorValue,
  required bool isActive,
  required bool isAboveCurrent,
}) {
  if (isActive) return activeLineColorValue;
  if (isAboveCurrent) return aboveLineColorValue;
  return null;
}
