import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'lyric_preferences.dart';

/// Apple Music 风格歌词布局常量
///
/// 参照 spec.md "Requirement: 字号与行距" 与 "行为参数" / "alpha 参数" 章节，
/// 集中定义所有字号、行距、缩放、弹簧、滚动等布局常量与计算函数。
///
/// 字号与行距支持用户偏好调节（[LyricPreferences]），不再使用固定值。
/// 默认字号 15px，默认行间距系数 1.5（可通过设置页滑块或长按菜单调整）。
class LyricLayout {
  LyricLayout._();

  // ============== 字号与行高（主行） ==============

  /// 字号：返回用户偏好的字号（[LyricPreferences.fontSize]）。
  ///
  /// 之前是 `max(8vw, 12px)` 固定公式，导致字号过大且不可调。
  /// 现在改为从 [LyricPreferences] 读取，默认 15px，范围 12~30px。
  /// 调用方仍传 [BuildContext]，保留以便未来根据屏幕尺寸自适应缩放。
  static double fontSize(BuildContext context) {
    return LyricPreferences.instance.fontSize;
  }

  /// 行高系数：返回用户偏好行高系数（基于 [LyricPreferences.lineSpacing]）。
  ///
  /// 公式：`lineHeight = (fontSize / defaultFontSize) * lineSpacing`
  /// 例如 fontSize=15, lineSpacing=1.5 → 1.5；
  /// fontSize=20, lineSpacing=1.0 → (20/15)*1.0 ≈ 1.33。
  ///
  /// 之前是固定 1.2，现在支持跟随字号缩放 + 用户调节。
  static double get lineHeight => LyricPreferences.instance.lineHeightMultiplier;

  /// 歌词 fontFamily：返回用户偏好的字体 family（system 模式为 null）。
  ///
  /// 所有歌词渲染/测量路径的 [TextStyle] 必须显式传入此值，否则
  /// TextPainter + Canvas 直接绘制路径不会继承 [ThemeData.fontFamily]。
  /// - null：Flutter 走系统字体链（Android 默认 Roboto + Noto Sans CJK）
  /// - 'SimHei'：内置打包字体
  /// - 'LyricUserCustomFont'：用户通过 SAF 选择并加载的自定义字体
  static String? get fontFamily => LyricPreferences.instance.effectiveFontFamily;

  /// 歌词字重：返回用户偏好的字重。
  ///
  /// 所有歌词渲染/测量路径的 [TextStyle] 必须显式传入此值，
  /// 否则 TextPainter + Canvas 直接绘制路径不会继承 `TextStyle.fontWeight`。
  static FontWeight get fontWeight => LyricPreferences.instance.fontWeight;

  // ============== 行 wrapper 间距 ==============

  /// 行 wrapper padding（垂直 0.4em，水平 1em）
  ///
  /// em 基于当前字号，需在调用处传入 [fontSize] 计算结果。
  static EdgeInsets linePadding(double fontSize) {
    return EdgeInsets.symmetric(
      vertical: fontSize * 0.4,
      horizontal: fontSize * 1.0,
    );
  }

  /// 行 wrapper 内 gap：0.3em
  static double lineGap(double fontSize) => fontSize * 0.3;

  // ============== 自动换行 ==============

  /// 换行行高系数：换行的内部行高 = 主行高 × 0.8。
  ///
  /// 用户确认（grill-me Q4）：换行行高 0.8x 正常行高，左边距与主行一致。
  /// 即一行歌词若换为 N 个视觉行（N≥1），总高度为：
  /// `mainLineHeight + (N - 1) * mainLineHeight * wrapLineHeightFactor`
  static const double wrapLineHeightFactor = 0.8;

  /// 计算视口内单行歌词可用的最大文字宽度（像素）。
  ///
  /// 左右边距各 1em（与 [linePadding] horizontal 一致，左对齐到 startX）。
  /// 超出此宽度即触发自动换行。
  static double maxLineWidth(double viewportWidth, double fontSize) {
    final sidePadding = fontSize * 1.0;
    final w = viewportWidth - sidePadding * 2;
    return w > 0 ? w : 0;
  }

  /// 测量指定行在视口宽度内实际占用的总高度（含自动换行）。
  ///
  /// - 无 word 时间戳：用 [TextPainter] 对整行 text 自动换行测量。
  /// - 有 word 时间戳：按 word 累加 dx 超过 [maxWidth] 即换行。
  ///
  /// [showTranslation] 为 true 时，把翻译副行高度（[translationFontSize] ×
  /// [translationLineHeight] + 0.3em 间隙）追加到返回值。调用方应仅对当前行
  /// 传 true，非当前行不预留空间，符合"只在当前行显示翻译"的视觉要求。
  ///
  /// 返回值即该行在垂直方向占用的像素高度。
  static double measureLineHeight(
    LyricLine line,
    double fontSize,
    double mainLineHeight,
    double maxWidth, {
    bool showTranslation = false,
  }) {
    if (maxWidth <= 0 || line.text.isEmpty) return mainLineHeight;

    double mainHeight;
    if (line.words.isEmpty) {
      // 纯文本行：用 TextPainter 自动换行
      final painter = TextPainter(
        text: TextSpan(
          text: line.text,
          // 显式注入歌词 fontFamily，必须与 line_renderer 渲染路径一致，
          // 否则行高测量与实际渲染不匹配会导致跳动
          style: TextStyle(fontSize: fontSize, height: lineHeight, fontFamily: fontFamily, fontWeight: fontWeight),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: maxWidth);
      final lineCount = painter.computeLineMetrics().length;
      mainHeight = lineCount <= 1
          ? mainLineHeight
          : mainLineHeight +
              (lineCount - 1) * mainLineHeight * wrapLineHeightFactor;
    } else {
      // 逐字行：按 word 累加，超宽即换行
      double dx = 0;
      int rowCount = 1;
      for (final word in line.words) {
        final painter = TextPainter(
          text: TextSpan(
            text: word.text,
            // 显式注入歌词 fontFamily，必须与 word_renderer 测量路径一致
            style: TextStyle(fontSize: fontSize, height: lineHeight, fontFamily: fontFamily, fontWeight: fontWeight),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        if (dx + painter.width > maxWidth && dx > 0) {
          dx = 0;
          rowCount++;
        }
        dx += painter.width;
      }
      mainHeight = rowCount <= 1
          ? mainLineHeight
          : mainLineHeight +
              (rowCount - 1) * mainLineHeight * wrapLineHeightFactor;
    }

    // 副行高度：按 displayMode 预留翻译或罗马音（与 renderer 绘制逻辑对齐——
    // 只音译无翻译的歌（粤语等）罗马音同样预留空间，否则副行会与下一行重叠）
    if (showTranslation) {
      final auxText =
          LyricPreferences.instance.displayMode == LyricDisplayMode.roma
          ? line.roma
          : line.translation;
      if (auxText != null && auxText.isNotEmpty) {
        final transFontSize = translationFontSize(fontSize);
        mainHeight += transFontSize * translationLineHeight +
            transFontSize * 0.3; // 0.3em 间隙，与 renderer 中绘制位置一致
      }
    }
    return mainHeight;
  }

  // ============== 副行（翻译） ==============

  /// 副行（翻译）字号：`max(0.7em, 12px)`
  ///
  /// 0.7em 为主行字号的 70%，再与 12px 取下限保护。
  static double translationFontSize(double fontSize) {
    final scaled = fontSize * 0.7;
    return scaled > 12 ? scaled : 12;
  }

  /// 副行行高：1.5em
  static const double translationLineHeight = 1.5;

  /// 副行透明度
  ///
  /// 0.5 居中于"已播字(0.8~1.0)"和"未播字(0.2~0.4)"之间，符合"翻译半透明介于已播未播之间"的视觉要求。
  static const double translationOpacity = 0.5;

  // ============== 背景行（人声） ==============

  /// 背景行（人声）透明度
  static const double backgroundLineOpacity = 0.4;

  /// 背景行字号缩放
  static const double backgroundLineFontScale = 0.7;

  // ============== 行缩放 ==============

  /// 当前行缩放
  static const double activeScale = 1.0;

  /// 非当前行缩放（enableScale=true 时）
  static const double inactiveScale = 0.97;

  /// 背景行：当前行缩放
  static const double backgroundActiveScale = 1.0;

  /// 背景行：非当前行缩放
  static const double backgroundInactiveScale = 0.75;

  /// 缩放基准点：默认 left（对唱行 right）
  static const Alignment scaleOrigin = Alignment.centerLeft;

  /// 对唱行缩放基准点
  static const Alignment scaleOriginDuet = Alignment.centerRight;

  // ============== 颜色 ==============

  /// 文字颜色（默认白色 #FFFFFF，浅色主题下改为黑色）
  ///
  /// 由 [AppleLyricsView] 在 build 时根据主题亮度设置：
  /// - 深色背景（AM 风格 / 暗色主题）→ 白色 0xFFFFFFFF
  /// - 浅色背景（非 AM 风格 + 亮色主题）→ 黑色 0xFF000000
  static int textColorValue = 0xFFFFFFFF;

  /// 文字颜色的 RGB 分量（0-255），供 Color.fromRGBO 使用
  static int get textRed => (textColorValue >> 16) & 0xFF;
  static int get textGreen => (textColorValue >> 8) & 0xFF;
  static int get textBlue => textColorValue & 0xFF;

  /// 背景颜色（半透明黑 rgba(0,0,0,0.35)）
  ///
  /// 0.35 * 255 ≈ 89 = 0x59，故 ARGB 为 0x59000000。
  static const int backgroundColorValue = 0x59000000;

  // ============== alpha 参数 ==============

  /// 当前字已播亮态 alpha（满 scale 时 1.0）
  static const double currentBrightAlpha = 1.0;

  /// 当前字未播暗态 alpha（满 scale 时 0.2）
  static const double currentDarkAlpha = 0.2;

  /// ATTACK 速度：当前字变亮指数渐变系数
  static const double attackSpeed = 50.0;

  /// RELEASE 速度：当前字变暗指数渐变系数
  static const double releaseSpeed = 7.0;

  /// alpha 渐变阈值：低于此值认为已收敛
  static const double alphaEpsilon = 0.001;

  // ============== 滚动与对齐 ==============

  /// 对齐位置：行中心位于视口高度 35% 处（不是 0.5）
  static const double alignPosition = 0.35;

  /// overscan：视口上下额外预渲染像素
  static const double overscanPx = 300;

  /// 间奏阈值：相邻行间隔 >= 此值时渲染间奏点
  static const int interludeThresholdMs = 4000;

  /// 间奏提前结束：间奏动画提前此毫秒数结束以准备下一行
  static const int interludeEarlyEndMs = 250;

  /// 点击判定阈值：< 此像素值视为点击，否则视为滚动
  static const double clickThresholdPx = 10;

  /// 用户滚动后自动回弹到当前行的超时时间
  static const int autoReturnMs = 3000;

  // ============== 弹簧参数：行缩放 ==============

  /// 主行缩放弹簧：mass
  static const double scaleSpringMass = 2;

  /// 主行缩放弹簧：damping
  static const double scaleSpringDamping = 25;

  /// 主行缩放弹簧：stiffness
  static const double scaleSpringStiffness = 100;

  // ============== 弹簧参数：背景行缩放 ==============

  /// 背景行缩放弹簧：mass
  static const double bgScaleSpringMass = 1;

  /// 背景行缩放弹簧：damping
  static const double bgScaleSpringDamping = 20;

  /// 背景行缩放弹簧：stiffness
  static const double bgScaleSpringStiffness = 50;

  // ============== 弹簧参数：posY seeking/间奏模式 ==============

  /// posY seeking/间奏模式：stiffness
  static const double posYSeekingStiffness = 90;

  /// posY seeking/间奏模式：damping
  static const double posYSeekingDamping = 15;

  // ============== 弹簧参数：posY 普通播放动态范围 ==============

  /// posY 普通播放 stiffness 下限
  static const double posYNormalStiffnessMin = 110;

  /// posY 普通播放 stiffness 上限
  static const double posYNormalStiffnessMax = 140;

  /// posY 普通播放 interval 下限（ms）
  static const int posYNormalIntervalMinMs = 100;

  /// posY 普通播放 interval 上限（ms）
  static const int posYNormalIntervalMaxMs = 800;

  /// 计算 posY 普通播放的 stiffness
  ///
  /// 公式（spec.md "Scenario: posY 滚动弹簧（普通播放）"）：
  /// ```
  /// ratio = (1 - (interval - 100) / 700) ** 0.2
  /// stiffness = 110 + ratio * 30
  /// ```
  /// 其中 intervalMs 会被 clamp 到 [100, 800]：
  /// - interval=100ms（密集）→ ratio=1.0 → stiffness=140（最灵敏）
  /// - interval=800ms（稀疏）→ ratio=0.0 → stiffness=110（最迟缓）
  static double posYNormalStiffness(int intervalMs) {
    final clamped =
        intervalMs.clamp(posYNormalIntervalMinMs, posYNormalIntervalMaxMs)
            .toDouble();
    final ratio = math.pow(1 - (clamped - 100) / 700, 0.2).toDouble();
    return posYNormalStiffnessMin + ratio * (posYNormalStiffnessMax - posYNormalStiffnessMin);
  }

  /// 计算 posY 普通播放的 damping
  ///
  /// 公式：`damping = sqrt(stiffness) * 2.2`
  ///
  /// 例：stiffness=220 → damping≈32.63；stiffness=170 → damping≈28.68。
  static double posYNormalDamping(double stiffness) {
    return math.sqrt(stiffness) * 2.2;
  }
}
