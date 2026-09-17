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
  /// - 'LyricUserCustomFont'：用户通过 SAF 选择并加载的自定义字体
  /// （内置 SimHei 已移除；bundled 为废弃遗留值，行为等同 null）
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
  /// [showTranslation] 为 true 时，把副行高度（[auxSubHeight]，按副行实际视觉行数
  /// 计算，含 0.3em 间隙）追加到返回值。调用方应仅对当前行
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
    // 只音译无翻译的歌（粤语等）罗马音同样预留空间，否则副行会与下一行重叠）。
    // 副行过长换行时按实际视觉行数预留（见 [auxSubHeight]）。
    if (showTranslation) {
      final auxText =
          LyricPreferences.instance.displayMode == LyricDisplayMode.roma
          ? line.roma
          : line.translation;
      mainHeight += auxSubHeight(
        fontSize,
        measureAuxRows(auxText, fontSize, maxWidth),
      );
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

  /// 副行（翻译/罗马音）占用的垂直高度。
  ///
  /// 公式：`rows × transFontSize × translationLineHeight + transFontSize × 0.3`，
  /// 其中 0.3em 为副行与主行之间的间隙（与 renderer 绘制位置一致）。
  ///
  /// [rows] 为该副行在可用宽度内的**实际视觉行数**（过长换行时 > 1）；
  /// `rows <= 0` 表示无副行，返回 0。
  ///
  /// **行数必须参与高度计算**：副行过长换行时若仍按单行预留，多出来的视觉行
  /// 会压到下一行歌词上（行距未调整）。布局预留（`AppleLyricsView` 的逐行副行
  /// 占位）与绘制位移（`LineRenderer` / `WordRenderer` 的副行"长出"偏移）必须
  /// 共用本公式且取值相等，否则副行最终位置与预留槽位错位。
  static double auxSubHeight(double fontSize, int rows) {
    if (rows <= 0) return 0;
    final trans = translationFontSize(fontSize);
    return rows * trans * translationLineHeight + trans * 0.3;
  }

  /// 测量副行文本在 [maxWidth] 内的视觉行数（无副行文本 → 0）。
  ///
  /// 与 renderer 绘制副行所用的 [TextPainter] 完全同 style（0.7em 字号、
  /// height = [translationLineHeight]、同 [fontFamily]/[fontWeight]），
  /// 保证测量行数与实际绘制的换行结果一致。
  static int measureAuxRows(String? auxText, double fontSize, double maxWidth) {
    if (auxText == null || auxText.isEmpty) return 0;
    final trans = translationFontSize(fontSize);
    final painter = TextPainter(
      text: TextSpan(
        text: auxText,
        style: TextStyle(
          fontSize: trans,
          height: translationLineHeight,
          fontFamily: fontFamily,
          fontWeight: fontWeight,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    if (maxWidth.isFinite && maxWidth > 0) {
      painter.layout(maxWidth: maxWidth);
    } else {
      painter.layout();
    }
    final int rows = painter.computeLineMetrics().length;
    painter.dispose();
    return rows < 1 ? 1 : rows;
  }

  /// 副行透明度
  ///
  /// 0.5 居中于"已播字(0.8~1.0)"和"未播字(0.2~0.4)"之间，符合"翻译半透明介于已播未播之间"的视觉要求。
  static const double translationOpacity = 0.5;

  // ============== 副行日历式翻转动效 ==============

  /// 副行翻转的最大转角（弧度）= 90°（侧立 → 就位）。
  static const double _sublineFlipHalfTurn = math.pi / 2;

  /// 翻转「剩余角」的衰减指数。
  ///
  /// 副行的位置与 alpha 与展开进度同源（指数趋近，前 200ms 即走完约 74%），
  /// 若角度线性跟随进度，等副行不透明时旋转已基本结束，翻转几乎看不见。
  /// 对剩余角取平方根（0.5）让旋转滞后于进度：半透明阶段保留较大转角，
  /// 末段再平落就位。取 1.0 即退化为与进度线性同步。
  static const double sublineFlipRemainPower = 0.5;

  /// 翻转「离位量」的死区：`q = 1 - expand` ≤ 该值时角度直接归零。
  ///
  /// 入场进度是指数趋近（τ≈150ms），若角度一路跟到 q→0，末尾会留下 0.3~1s
  /// 的「几度几度慢慢压平」拖尾（真机观感僵硬）。提前归零后翻转在约 280ms
  /// 处干净落位，剩下的进度只影响 alpha 与位置，不再拖尾。
  static const double sublineFlipSettleCut = 0.15;

  /// 翻转透视强度（`Matrix4.setEntry(3, 2, ·)`）。
  ///
  /// 以像素为单位的深度倒数权重：副行文字高约 18~30px，翻转中离轴端 z 最大
  /// ≈ 该高度，0.006 → 近/远端 w ≈ 1∓0.11（约 ±11% 缩放），有立体感但不夸张。
  /// 置 0 退化为正交压扁（无透视，纯高度压缩）。
  static const double sublineFlipPerspective = 0.006;

  /// 副行翻转角度（弧度）。
  ///
  /// - [exiting] = false（入场）：绕副行底边，`expand` 0→1 对应 -90°→0°，
  ///   副行从底边向上翻起出现；
  /// - [exiting] = true（出场）：绕副行顶边，`expand` 1→0 对应 0°→+90°，
  ///   副行向上翻起消失。
  ///
  /// `expand` 为渲染器 `translationExpand` 注入的展开进度（出场行注入的是
  /// `1 - 收起进度`，故 1 = 就位、0 = 完全转走）；越界值钳制到 [0, 1]。
  /// 返回 0 表示已就位，调用方应跳过任何画布变换（零开销直绘路径）。
  ///
  /// 两端对称：同一 `expand` 下入场/出场的转角**大小相同、符号相反**，故切行
  /// 交接帧的副行视觉高度严格连续，只有锚线与倾斜方向镜像（见计划文档「已知代价」）。
  static double sublineFlipAngle(double expand, {required bool exiting}) {
    final double p = expand.clamp(0.0, 1.0);
    // 离位量 q：0 = 完全就位，1 = 完全转走（入场 1→0，出场 0→1，同一标量）
    final double q = 1.0 - p;
    // 死区：q 落到 [sublineFlipSettleCut] 以内即归零，杜绝指数拖尾
    final double t =
        ((q - sublineFlipSettleCut) / (1.0 - sublineFlipSettleCut))
            .clamp(0.0, 1.0);
    final double remaining = math.pow(t, sublineFlipRemainPower).toDouble();
    return exiting
        ? _sublineFlipHalfTurn * remaining
        : -_sublineFlipHalfTurn * remaining;
  }

  /// 副行翻转的锚点：**既是旋转锚线，也是透视的投影中心**。
  ///
  /// - x = 副行水平中点：透视除法（`w = 1 + perspective·z`）绕该 x 进行。
  ///   不平移 x 的话，投影中心会落在画布原点（左上角），副行在翻转中会整体
  ///   向左漂移（w≈1.11 时 x=250 处偏移可达 25px，真机观感「偏左」）；
  /// - y = 旋转锚线：入场取副行**底边**（`transY + 副行高`）从下翻出；
  ///   出场取副行**顶边**（`transY`）向上翻走。
  ///
  /// [sublineHeight] 传副行 `TextPainter.height`（= 视觉行数 × 副行字号 ×
  /// [translationLineHeight]），不要传 [auxSubHeight]：后者含底部的 0.3em 间隙，
  /// 会让入场锚线下移 0.3em 而与文字底边错位。
  /// [sublineWidth] 传副行 `TextPainter.width`。
  static Offset sublineFlipAnchor({
    required double transX,
    required double sublineWidth,
    required double transY,
    required double sublineHeight,
    required bool exiting,
  }) {
    return Offset(transX + sublineWidth / 2,
        exiting ? transY : transY + sublineHeight);
  }

  /// 副行翻转的画布变换矩阵：
  /// `T(anchor) · P · Rx(angle) · T(-anchor)`。
  ///
  /// 即以 [anchor] 为轴心做 3D 旋转（角度由 [sublineFlipAngle] 给出），
  /// [perspective] 为透视强度。**锚点必须同时给出 x**：透视除法绕锚点进行，
  /// 只平移 y 会让投影中心停在画布左上角，副行翻转时整体左漂。
  /// 锚线（y = anchor.dy）上的点 z=0 → w=1 → 变换后严格不动。
  static Matrix4 sublineFlipMatrix({
    required double angle,
    required Offset anchor,
    double perspective = sublineFlipPerspective,
  }) {
    final Matrix4 rot = Matrix4.identity()
      ..setEntry(3, 2, perspective)
      ..rotateX(angle);
    return Matrix4.translationValues(anchor.dx, anchor.dy, 0)
      ..multiply(rot)
      ..multiply(Matrix4.translationValues(-anchor.dx, -anchor.dy, 0));
  }

  // ============== 背景行（人声） ==============

  /// 背景行（人声）透明度
  static const double backgroundLineOpacity = 0.4;

  /// 背景行字号缩放
  static const double backgroundLineFontScale = 0.7;

  // ============== 行缩放 ==============

  /// 当前行缩放
  static const double activeScale = 1.0;

  /// 非当前行缩放（enableScale=true 时）。
  ///
  /// 由用户在设置页调节（[LyricPreferences.inactiveScale]），默认 0.97。
  /// 清晰层非当前行与 AM 歌词模糊层共用此值：模糊图在离屏渲染时烘焙同一
  /// pivot+scale 变换，保证两层字形尺寸在任何取值下都严格一致。
  static double get inactiveScale => LyricPreferences.instance.inactiveScale;

  /// 模糊层离屏渲染缩放：与清晰层非当前行 scale 完全同源，不叠任何额外因子。
  ///
  /// 必须与 `_LyricsPainter.paint` 中非当前行的 scale 取值口径一致
  /// （enableScale=false 时清晰层非当前行为 [activeScale]），否则两层再次错位。
  static double blurRenderScale({required bool enableScale}) =>
      enableScale ? inactiveScale : activeScale;

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

  /// 对齐位置：行中心位于视口高度的该比例处（默认 0.35，不是 0.5）。
  ///
  /// 由用户在设置页调节（[LyricPreferences.alignPosition]）。
  static double get alignPosition => LyricPreferences.instance.alignPosition;

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
