import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/services/windows_default_font.dart';
import 'lyric_aux_scope.dart';

/// 歌词字体来源枚举（与全局 [FontSource] 解耦，允许歌词使用与 UI 不同的字体）。
///
/// - [LyricFontSource.system]：使用手机系统字体（默认，符合"优先展示用户手机字体"需求）
/// - [LyricFontSource.bundled]：已废弃（内置 SimHei 已移除，仅保留枚举值以稳定
///   `fontSource.index` 的原生契约 0=system 1=bundled 2=custom），行为等同 system
/// - [LyricFontSource.custom]：使用用户通过 SAF 选择的 TTF/OTF 文件
enum LyricFontSource { system, bundled, custom }

/// 歌词辅助行显示模式：翻译 or 罗马音。
///
/// - [LyricDisplayMode.translation]：显示中文翻译（默认）
/// - [LyricDisplayMode.roma]：显示罗马音/音译
///
/// 仅当 [LyricPreferences.showTranslation] 为 true 时副行才显示，
/// [displayMode] 决定显示哪个字段。
enum LyricDisplayMode { translation, roma }

/// 字内渐变（当前行扫光）模型：classic = 本仓原有宽过渡带；sweep = 移植自 myune 的扫光。
///
/// - [LyricFillMode.classic]：原有「行内累计宽度 maskX + 固定过渡半宽（行内平均字宽）」
///   模型，过渡带宽、边缘柔和。
/// - [LyricFillMode.sweep]：myune 扫光模型——前端沿**墨迹长度**推进（字间空白瞬时跨越），
///   羽化宽度按字宽 + 时长自适应（快字宽、慢字窄），过渡带更锐利（默认）。
///
/// 与 [LyricFontSource] / [LyricDisplayMode] 一样，持久化时存 `name`，未知值回退默认。
enum LyricFillMode { classic, sweep }

/// 辉光触发判定模式：自适应 or 固定时长。
///
/// - [GlowThresholdMode.adaptive]：原有判定——按歌曲 BPM / KRC 歌词字长中位数
///   × 阈值系数（[LyricPreferences.glowThresholdFactor]）自适应推断触发阈值。
/// - [GlowThresholdMode.fixed]：固定时长判定——字时长 >= 固定阈值
///   （[LyricPreferences.glowFixedThresholdMs]，默认 1000ms）才触发辉光（默认）。
///
/// 与 [LyricFillMode] 一样，持久化时存 `name`，未知值回退默认。
enum GlowThresholdMode { adaptive, fixed }

/// 歌词显示偏好设置（字号 + 行间距 + 字体）。
///
/// 提供全局静态访问 + ChangeNotifier 通知，供 AppleLyricsView、
/// 设置页滑块、长按菜单共同读写。
///
/// 偏好通过 SharedPreferences 持久化。
///
/// 字号范围：[minFontSize] ~ [maxFontSize]，默认 [defaultFontSize]。
/// 行间距系数范围：[minLineSpacing] ~ [maxLineSpacing]，默认 [defaultLineSpacing]。
/// 实际行高 = (fontSize / defaultFontSize) * lineSpacing。
///
/// 字体来源（[fontSource]）独立于全局 ThemeProvider，允许歌词使用专属字体。
/// 自定义字体通过 Flutter [FontLoader] 动态注册，family 名固定为
/// [lyricCustomFontFamily]；切换为 system/bundled 时该 family 不会被使用。
class LyricPreferences extends ChangeNotifier {
  LyricPreferences._();
  static final LyricPreferences instance = LyricPreferences._();

  /// 歌词自定义字体注册到 Flutter 的 family 名（固定）
  static const String lyricCustomFontFamily = 'LyricUserCustomFont';

  // ============== 范围与默认值 ==============

  /// 字号最小值（px）；缩放后的最终字号由
  /// [LyricLayout.clampReadableFontSize] 兜可读下限，不靠此值。
  static const double minFontSize = 12;

  /// 字号最大值（px）
  static const double maxFontSize = 50;

  /// 字号默认值（px）
  ///
  /// 这是公式 `(fontSize / defaultFontSize) * lineSpacing` 中的分母，
  /// 保持 15px 不变。改动此值会影响所有用户计算出的实际行高。
  static const double defaultFontSize = 15;

  /// 用户首选项的字号默认值（px）
  ///
  /// 新用户首次进入时歌词显示的字号。保持 22px 让初始实际行高为
  /// (22/15)*1.5 = 2.20×，更符合阅读习惯。
  static const double defaultUserFontSize = 22;

  /// 行间距系数最小值
  ///
  /// 下限 0.5 允许把行间距压到比默认行高更紧（0.5×），用于紧凑排版偏好。
  static const double minLineSpacing = 0.5;

  /// 行间距系数最大值
  static const double maxLineSpacing = 2.0;

  /// 行间距系数默认值
  static const double defaultLineSpacing = 1.5;

  /// 字重最小值（FontWeight.value，细体）
  static const int minFontWeight = 300;

  /// 字重最大值（FontWeight.value，黑体）
  ///
  /// FontWeight 构造允许 0~1000 的连续数值；歌词上限按 900（黑体）截断，
  /// 再高在部分平台字体会被合成加粗，观感失真。
  static const int maxFontWeight = 900;

  /// 字重默认值（FontWeight.value，常规）
  ///
  /// 与当前未设置字重时的渲染外观（Flutter 默认 FontWeight.normal=400）一致。
  static const int defaultFontWeight = 400;

  /// 辉光触发阈值系数最小值
  ///
  /// 触发阈值 = 歌词字长中位数 × 该系数；系数越小越容易触发辉光。
  static const double minGlowThresholdFactor = 1.0;

  /// 辉光触发阈值系数最大值
  static const double maxGlowThresholdFactor = 2.0;

  /// 辉光触发阈值系数默认值
  static const double defaultGlowThresholdFactor = 1.2;

  /// 辉光固定时长判定阈值下限（ms，安卓/全局基线）。
  static const double minGlowFixedThresholdMs = 500;

  /// 辉光固定时长判定阈值上限（ms，安卓/全局基线）。
  static const double maxGlowFixedThresholdMs = 2000;

  /// 辉光固定时长判定阈值默认值（ms，安卓/全局基线）。
  static const double defaultGlowFixedThresholdMs = 1000;

  /// 非当前行缩放最小值（安卓/全局基线）。
  ///
  /// 0.80 时背景行明显后退，再小会与当前行脱节。
  static const double minInactiveScale = 0.80;

  /// 非当前行缩放最大值。1.0 = 关闭缩放（所有行等大）。
  static const double maxInactiveScale = 1.00;

  /// 非当前行缩放默认值（安卓/全局基线）。
  ///
  /// 0.850：默认让背景行比当前行略小，突出当前行。仅对新安装用户生效，
  /// 已持久化的旧值不会被覆盖。
  static const double defaultInactiveScale = 0.850;

  /// 非当前行缩放滑块档位：0.80~1.00 共 40 档，步长 0.005。
  static const int inactiveScaleDivisions = 40;

  /// 当前行垂直锚位最小值（视口高度比例）。
  ///
  /// 0.15 时当前行贴近顶部，上方几乎不显示已唱过的行。
  static const double minAlignPosition = 0.15;

  /// 当前行垂直锚位最大值。
  ///
  /// 0.65 时当前行偏下，下方待唱行明显多于上方。
  static const double maxAlignPosition = 0.65;

  /// 当前行垂直锚位默认值。
  ///
  /// 保持历史写死值 0.35（AMLL 默认偏中上），确保升级后视觉不变。
  static const double defaultAlignPosition = 0.35;

  /// 锚位滑块档位：0.15~0.65 共 50 档，步长 0.01。
  static const int alignPositionDivisions = 50;

  /// 级联错峰最大延迟下限（ms，安卓/全局基线）。
  static const double minCascadeMaxDelayMs = 100;

  /// 级联错峰最大延迟上限（ms，安卓/全局基线）。
  static const double maxCascadeMaxDelayMs = 2000;

  /// 级联错峰最大延迟默认（ms，安卓/全局基线）：越靠下的行最大"粘"这么久才回位。
  static const double defaultCascadeMaxDelayMs = 750;

  /// 级联错峰步长下限（ms，安卓/全局基线）。
  static const double minCascadeBaseStepMs = 20;

  /// 级联错峰步长上限（ms，安卓/全局基线）。
  static const double maxCascadeBaseStepMs = 200;

  /// 级联错峰步长默认（ms，安卓/全局基线）：相邻行的错峰时间间隔。
  static const double defaultCascadeBaseStepMs = 60;

  /// 级联衰减分母下限（x in 1/x，安卓/全局基线）。
  static const double minCascadeDecayX = 1.0;

  /// 级联衰减分母上限（x in 1/x，安卓/全局基线）。
  static const double maxCascadeDecayX = 2.0;

  /// 级联衰减分母默认（x in 1/x，安卓/全局基线）：每越过一行步长 × 1/x。
  static const double defaultCascadeDecayX = 1.1;

  // ============== 预启动提前量微调 ==============

  /// 预启动提前量微调下限（ms）：0 = 不微调（当前行恰在音频边界释放）。
  static const double minPreStartBiasMs = 0;

  /// 预启动提前量微调上限（ms）：300ms 足以覆盖最慢弹簧的收敛尾巴；
  /// 再大会让滚动明显早于上一行结束，观感突兀。
  static const double maxPreStartBiasMs = 300;

  /// 预启动提前量微调默认（ms）：0 = 与未引入微调时行为一致。
  ///
  /// 关闭「错峰从当前行上方开始」的预启动会把当前行释放对齐到音频边界，
  /// 但弹簧到位 ≠ 收敛：边界时刻当前行可能仍在收敛尾巴上。本值把级联
  /// 整体再提前这么多毫秒，给弹簧留出收敛时间（真机手感微调用）。
  static const double defaultPreStartBiasMs = 0;

  /// 已播字上浮高度最小值（px，安卓/全局基线）。0 = 完全不上浮。
  static const double minLiftHeightPx = 0.0;

  /// 已播字上浮高度最大值（px，安卓/全局基线）。
  ///
  /// 10px 已明显超过一行字高的十分之一量级，再大会让当前行"飘"离基线。
  static const double maxLiftHeightPx = 10.0;

  /// 已播字上浮高度默认值（px，安卓/全局基线）。
  ///
  /// 保持历史写死值 3.0（AMLL：当前字最大上浮 -3px），确保升级后视觉不变。
  /// 渲染侧取负值作为 Y 偏移（向上为负）。
  static const double defaultLiftHeightPx = 3.0;

  // ============== 已播 / 未播歌词透明度 ==============

  /// 已播歌词透明度下限（0 = 完全隐藏）。
  static const double minPlayedOpacity = 0.0;

  /// 已播歌词透明度上限（alpha 物理上限 1.0，故不做中轴对称）。
  static const double maxPlayedOpacity = 1.0;

  /// 已播歌词透明度默认值：1.0 = 原 `dynamicBrightAlpha` 满 factor 值。
  static const double defaultPlayedOpacity = 1.0;

  /// 未播歌词透明度下限（0 = 完全隐藏）。
  static const double minUnplayedOpacity = 0.0;

  /// 未播歌词透明度上限（alpha 物理上限 1.0，故不做中轴对称）。
  static const double maxUnplayedOpacity = 1.0;

  /// 未播歌词透明度默认值：0.4 = 原 `dynamicDarkAlpha` 满 factor 值。
  ///
  /// 渐隐基线取本值的一半（默认 0.2），使默认值代入新公式后逐点退化为
  /// 原 `factor*0.8+0.2` / `factor*0.2+0.2`，升级后视觉不变。
  static const double defaultUnplayedOpacity = 0.4;

  // ============== Windows 便携版歌词动画参数（用户实调值即默认/中轴） ======
  //
  // 用户把便携版「歌词动画」页调到了自己满意的手感，这里把这些值固化为
  // Windows 默认值，并把滑块范围改为「以该默认值为中轴、左右尽量对称」，
  // 保证默认值落在滑条中央而不是贴着某一端（贴边会让一侧几乎无可用行程）。
  // 安卓端继续走上面的全局常量，行为完全不变。

  /// 歌词字号（默认 50px，范围 12~88 关于 50 对称）。
  ///
  /// 旧上限恰好就是 50，等于「默认值贴死右端」；这里上沿放到 88，
  /// 让 50 落在正中，两侧各留 38 的可调行程。
  static double get minFontSizeForCurrentPlatform =>
      Platform.isWindows ? 12 : minFontSize;
  static double get maxFontSizeForCurrentPlatform =>
      Platform.isWindows ? 88 : maxFontSize;
  static double get defaultFontSizeForCurrentPlatform =>
      Platform.isWindows ? 50 : _deviceDefaultFontSize;

  /// 字重（默认 900 黑体，范围 300~900）。
  ///
  /// 900 是 Flutter [FontWeight] 中歌词可用的最高档（再高会被合成加粗、
  /// 观感失真），同时 9 档步进决定滑块只能离散取值，故无法做数学居中；
  /// 用户可选范围仍是完整 300~900 全档。
  static int get minFontWeightForCurrentPlatform =>
      Platform.isWindows ? 300 : minFontWeight;
  static int get maxFontWeightForCurrentPlatform =>
      Platform.isWindows ? 900 : maxFontWeight;
  static int get defaultFontWeightForCurrentPlatform =>
      Platform.isWindows ? 900 : _deviceDefaultFontWeight;

  /// 行间距（默认 0.8×，范围 0.4~1.2 关于 0.8 对称）。
  ///
  /// 旧下限 0.5，且用户取 0.8 时同样贴边；这里把上下放宽到 0.4~1.2，
  /// 0.8 正好落在正中。下沿仍留 0.4，避免行高小到文字互相压叠。
  static double get minLineSpacingForCurrentPlatform =>
      Platform.isWindows ? 0.4 : minLineSpacing;
  static double get maxLineSpacingForCurrentPlatform =>
      Platform.isWindows ? 1.2 : maxLineSpacing;
  static double get defaultLineSpacingForCurrentPlatform =>
      Platform.isWindows ? 0.8 : _deviceDefaultLineSpacing;

  /// 非当前行缩放（默认 0.60，范围 0~1 全覆盖；1 = 与当前行等大）。
  /// 上沿 1.00 是物理边界：非当前行不可大于当前行（activeScale=1.0）。
  /// 下沿放到 0 让左侧行程充足；渲染侧对 <0.01 的值做极小平滑钳制，
  /// 避免 canvas.scale(0) 导致离屏模糊矩阵退化。
  static double get minInactiveScaleForCurrentPlatform =>
      Platform.isWindows || Platform.isAndroid ? 0.0 : minInactiveScale;
  static double get maxInactiveScaleForCurrentPlatform => maxInactiveScale;
  static double get defaultInactiveScaleForCurrentPlatform =>
      Platform.isWindows || Platform.isAndroid ? 0.60 : defaultInactiveScale;

  /// 当前行垂直锚位（默认 0.35，范围 0.05~0.65 关于 0.35 对称）。
  ///
  /// 上沿保留原全局上限 0.65（当前行偏下），下沿由 0.15 放宽到 0.05
  /// （当前行更贴近顶部），使 0.35 正好落在正中、两侧各 0.30 行程。
  static double get minAlignPositionForCurrentPlatform =>
      Platform.isWindows || Platform.isAndroid ? 0.05 : minAlignPosition;
  static double get maxAlignPositionForCurrentPlatform =>
      Platform.isWindows || Platform.isAndroid ? 0.65 : maxAlignPosition;
  static double get defaultAlignPositionForCurrentPlatform =>
      Platform.isWindows || Platform.isAndroid ? 0.35 : defaultAlignPosition;

  /// 已播字上浮高度（默认 1.7px，范围 0.0~3.4 关于 1.7 对称）。
  static double get minLiftHeightPxForCurrentPlatform =>
      Platform.isWindows || Platform.isAndroid ? 0.0 : minLiftHeightPx;
  static double get maxLiftHeightPxForCurrentPlatform =>
      Platform.isWindows || Platform.isAndroid ? 3.4 : maxLiftHeightPx;
  static double get defaultLiftHeightPxForCurrentPlatform =>
      Platform.isWindows || Platform.isAndroid ? 1.7 : defaultLiftHeightPx;

  /// 间奏点水平起点（默认 1.5×字号，范围 0.0~3.0 关于 1.5 对称）。
  static double get minInterludeDotsStartXForCurrentPlatform =>
      Platform.isWindows || Platform.isAndroid ? 0.0 : minInterludeDotsStartX;
  static double get maxInterludeDotsStartXForCurrentPlatform =>
      Platform.isWindows || Platform.isAndroid ? 3.0 : maxInterludeDotsStartX;
  static double get defaultInterludeDotsStartXForCurrentPlatform =>
      Platform.isWindows || Platform.isAndroid ? 1.5 : defaultInterludeDotsStartX;

  /// 间奏点半径（默认 0.18×字号，范围 0.04~0.32 关于 0.18 对称）。
  static double get minInterludeDotRadiusForCurrentPlatform =>
      Platform.isWindows || Platform.isAndroid ? 0.04 : minInterludeDotRadius;
  static double get maxInterludeDotRadiusForCurrentPlatform =>
      Platform.isWindows || Platform.isAndroid ? 0.32 : maxInterludeDotRadius;
  static double get defaultInterludeDotRadiusForCurrentPlatform =>
      Platform.isWindows || Platform.isAndroid ? 0.18 : defaultInterludeDotRadius;

  /// 间奏点间距（默认 0.90×字号，范围 0.30~1.50 关于 0.90 对称）。
  static double get minInterludeDotSpacingForCurrentPlatform =>
      Platform.isWindows || Platform.isAndroid ? 0.30 : minInterludeDotSpacing;
  static double get maxInterludeDotSpacingForCurrentPlatform =>
      Platform.isWindows || Platform.isAndroid ? 1.50 : maxInterludeDotSpacing;
  static double get defaultInterludeDotSpacingForCurrentPlatform =>
      Platform.isWindows || Platform.isAndroid ? 0.90 : defaultInterludeDotSpacing;

  /// 错峰上限（默认 990ms，范围 0~1980 关于 990 对称）。
  ///
  /// 左端 0 = 完全不粘滞（负延迟与 0 语义相同，均立即释放，故无需再下探）；
  /// 右端 1980 贴近原全局上限 2000，保证两侧各 990ms 的等长行程。
  static double get minCascadeMaxDelayMsForCurrentPlatform =>
      Platform.isWindows || Platform.isAndroid ? 0 : minCascadeMaxDelayMs;
  static double get maxCascadeMaxDelayMsForCurrentPlatform =>
      Platform.isWindows || Platform.isAndroid ? 1980 : maxCascadeMaxDelayMs;
  static double get defaultCascadeMaxDelayMsForCurrentPlatform =>
      Platform.isWindows || Platform.isAndroid ? 990 : defaultCascadeMaxDelayMs;

  /// 错峰步长（默认 80ms，范围 0~160 关于 80 对称）。
  ///
  /// 左端 0 = 无逐行错峰；右端 160 为加快错峰保留行程。
  static double get minCascadeBaseStepMsForCurrentPlatform =>
      Platform.isWindows || Platform.isAndroid ? 0 : minCascadeBaseStepMs;
  static double get maxCascadeBaseStepMsForCurrentPlatform =>
      Platform.isWindows || Platform.isAndroid ? 160 : maxCascadeBaseStepMs;
  static double get defaultCascadeBaseStepMsForCurrentPlatform =>
      Platform.isWindows || Platform.isAndroid ? 80 : defaultCascadeBaseStepMs;

  /// 错峰衰减（默认 1.00，范围 0.50~1.50 关于 1.00 对称）。
  ///
  /// 渲染侧用 `1/x`：x<1 时步长逐行放大（下方行更"粘"，延迟仍被
  /// cascadeMaxDelay 裁剪，不会发散）；x>1 时衰减更快。
  /// 下沿取 0.50 而非 0，避免 1/x 在 x→0 时趋于无穷。
  static double get minCascadeDecayXForCurrentPlatform =>
      Platform.isWindows || Platform.isAndroid ? 0.50 : minCascadeDecayX;
  static double get maxCascadeDecayXForCurrentPlatform =>
      Platform.isWindows || Platform.isAndroid ? 1.50 : maxCascadeDecayX;
  static double get defaultCascadeDecayXForCurrentPlatform =>
      Platform.isWindows || Platform.isAndroid ? 1.00 : defaultCascadeDecayX;

  /// 辉光固定时长（默认 500ms，范围 100~900 关于 500 对称）。
  /// 下沿从原来的 500 放宽到 100，让默认值居中而不是贴死在滑条最左端。
  static double get minGlowFixedThresholdMsForCurrentPlatform =>
      Platform.isWindows || Platform.isAndroid ? 100 : minGlowFixedThresholdMs;
  static double get maxGlowFixedThresholdMsForCurrentPlatform =>
      Platform.isWindows || Platform.isAndroid ? 900 : maxGlowFixedThresholdMs;
  static double get defaultGlowFixedThresholdMsForCurrentPlatform =>
      Platform.isWindows || Platform.isAndroid ? 500 : defaultGlowFixedThresholdMs;

  /// 歌词模糊强度（默认 1.0，范围 0.5~1.5 关于 1.0 对称）。
  /// 下沿保留 0.5（再小等于关闭模糊的死档）；上沿由 2.0 收到 1.5，
  /// 让默认值居中后两侧对称。
  static double get minBlurIntensityForCurrentPlatform =>
      Platform.isWindows ? 0.5 : minBlurIntensity;
  static double get maxBlurIntensityForCurrentPlatform =>
      Platform.isWindows ? 1.5 : maxBlurIntensity;
  static double get defaultBlurIntensityForCurrentPlatform => defaultBlurIntensity;

  /// 动态颜色混色比例（默认 0.15，范围 0.00~0.30 关于 0.15 对称）。
  /// 0.00 是物理下限（纯白），左侧无法再扩，故上沿收到 0.30 换取居中。
  static double get minDynamicColorMixRatioForCurrentPlatform => minDynamicColorMixRatio;
  static double get maxDynamicColorMixRatioForCurrentPlatform =>
      Platform.isWindows ? 0.30 : maxDynamicColorMixRatio;
  static double get defaultDynamicColorMixRatioForCurrentPlatform =>
      defaultDynamicColorMixRatio;

  /// 辉光强度（默认 1.0，范围 0.2~1.8 关于 1.0 对称）。
  /// 下沿保留 0.2（再小等于关掉辉光的死档）；上沿由 2.0 收到 1.8。
  static double get minGlowIntensityForCurrentPlatform => minGlowIntensity;
  static double get maxGlowIntensityForCurrentPlatform =>
      Platform.isWindows ? 1.8 : maxGlowIntensity;
  static double get defaultGlowIntensityForCurrentPlatform => defaultGlowIntensity;

  /// 辉光触发阈值系数（默认 1.2，范围 0.6~1.8 关于 1.2 对称）。
  /// 仅自适应判定模式显示；下沿放宽到 0.6（更易触发），上沿由 2.0 收到 1.8。
  static double get minGlowThresholdFactorForCurrentPlatform =>
      Platform.isWindows ? 0.6 : minGlowThresholdFactor;
  static double get maxGlowThresholdFactorForCurrentPlatform =>
      Platform.isWindows ? 1.8 : maxGlowThresholdFactor;
  static double get defaultGlowThresholdFactorForCurrentPlatform =>
      defaultGlowThresholdFactor;

  /// 级联错峰是否从当前行开始（默认 true）。
  ///
  /// - true：仅当前行及以下的行错峰跟随，当前行 delay=0，上方行不参与
  ///   「按住等错峰」，随全局滚动同步回位；
  /// - false：历史行为，从视口顶部行开始逐行累加错峰（上方行也错峰）。
  ///   关闭时当前行延迟随视口顶部位置（`_cascadeTopLine`，随视口高度/字号/
  ///   机型浮动）累加，AppleLyricsView 以预启动消除滞后：慢歌在边界前
  ///   `min(D_raw, 上限)` 进入预启动窗口，级联时间线锚定窗口起点 + 滚动
  ///   目标提前推进（当前行恰在音频边界释放、零滞后、瀑布提前可见）；
  ///   预测失效（快歌/seek/暂停）时回落为固定窗口压缩（滞后恒 3×步长）。
  static const bool defaultStaggerFromCurrentLine = true;

  /// 已播 / 未播歌词透明度：alpha 物理上限为 1.0，各平台同值，
  /// 不套用「默认值居中」约定（见 docs/lyric-animation-params.md 物理边界优先）。
  static double get minPlayedOpacityForCurrentPlatform => minPlayedOpacity;
  static double get maxPlayedOpacityForCurrentPlatform => maxPlayedOpacity;
  static double get defaultPlayedOpacityForCurrentPlatform =>
      defaultPlayedOpacity;
  static double get minUnplayedOpacityForCurrentPlatform => minUnplayedOpacity;
  static double get maxUnplayedOpacityForCurrentPlatform => maxUnplayedOpacity;
  static double get defaultUnplayedOpacityForCurrentPlatform =>
      defaultUnplayedOpacity;

  // ============== 歌词模糊强度 ==============

  /// 歌词模糊强度倍数下限。
  ///
  /// 0.5 时非当前行几乎清晰，是"关闭模糊观感"与"保留距离分级"的折中下限。
  static const double minBlurIntensity = 0.5;

  /// 歌词模糊强度倍数上限。
  ///
  /// 2.0 时最远行 sigma 达 10（原上限 5），再大会让整屏文字不可辨认，
  /// 且离屏渲染的模糊图尺寸（padding=σ×3）显著膨胀。
  static const double maxBlurIntensity = 2.0;

  /// 歌词模糊强度倍数默认值。
  ///
  /// 1.0 = 历史行为（sigma 等于距离分级值 1~5），确保升级后视觉不变。
  static const double defaultBlurIntensity = 1.0;

  // ============== 歌词动态颜色 ==============

  /// 动态颜色混色比例下限。
  ///
  /// 0.0 = 纯白（等于关闭取色观感），用户仍可保留开关只调比例。
  static const double minDynamicColorMixRatio = 0.0;

  /// 动态颜色混色比例上限。
  ///
  /// 1.0 = 完全使用封面提取色（渲染侧仍会把明度抬到 ≥ 0.78 保证深色底可读）。
  static const double maxDynamicColorMixRatio = 1.0;

  /// 动态颜色混色比例默认值。
  ///
  /// 0.15 = 历史行为（85% 白 + 15% 封面提取色），确保升级后视觉不变。
  static const double defaultDynamicColorMixRatio = 0.15;

  /// 上方已播行是否跟随已播颜色的默认值（默认关闭 = 历史行为）。
  static const bool defaultUseAboveLinesPlayedColor = false;

  // ============== 歌词辉光强度 ==============

  /// 辉光强度倍数下限。
  ///
  /// 0.2 时辉光只剩一层极淡的光晕，接近"关闭辉光观感"但保留开关状态，
  /// 不会出现"开关开着却完全没效果"的死档。
  static const double minGlowIntensity = 0.2;

  /// 辉光强度倍数上限。
  ///
  /// 2.0 时紧贴笔画的环带 alpha 从约 0.25 提到约 0.45（实测），再高会
  /// 让白色歌词的笔画边缘过曝、与背景对比度反转。
  static const double maxGlowIntensity = 2.0;

  /// 辉光强度倍数默认值。
  ///
  /// 1.0 = 历史行为（辉光剖面按 `EmphasizeEffect.glowLevel` 原样输出），
  /// 确保升级后视觉不变。
  static const double defaultGlowIntensity = 1.0;

  // ============== 辉光字符缩放开关 ==============

  /// 辉光字符缩放开关默认值。
  ///
  /// true = 历史行为：强调字凸起时放大（最高 1.12×）并左右外扩。
  /// false = 只停掉放大与水平外扩，仍保留上浮、正弦浮层与辉光呼吸——
  /// 让不喜欢"字被顶大"的用户能保留发光但不要弹跳。
  static const bool defaultGlowCharScale = true;

  // ============== 间奏点（节奏点）自定义 ==============

  /// 间奏点水平起点系数下限（× 字号）。0 = 贴左边缘（与歌词左边界对齐）。
  static const double minInterludeDotsStartX = 0.0;

  /// 间奏点水平起点系数上限（× 字号）。
  ///
  /// 6em 已明显超过一行的常用字数，再大在中窄屏上会把整组点推出可视区
  /// （由 ClipRect 裁掉，等于看不见），故以此为上限。
  static const double maxInterludeDotsStartX = 6.0;

  /// 间奏点水平起点系数默认值（× 字号）。
  ///
  /// 1.5 = 历史写死值（比歌词左对齐起点右移 0.5em，让整组点视觉更居中），
  /// 确保升级后视觉不变。
  static const double defaultInterludeDotsStartX = 1.5;

  /// 单个间奏点半径系数下限（× 字号）。0.04 时点几乎是一个像素，接近"看不见"。
  static const double minInterludeDotRadius = 0.04;

  /// 单个间奏点半径系数上限（× 字号）。
  ///
  /// 0.40 时整组点直径 0.8em，仍在间奏占位行（约 2.2em 高）内不溢出。
  static const double maxInterludeDotRadius = 0.40;

  /// 单个间奏点半径系数默认值（× 字号）。
  ///
  /// 0.18 = 历史写死值（AMLL 风格：fontSize=24 时直径约 8.6px），
  /// 确保升级后视觉不变。
  static const double defaultInterludeDotRadius = 0.18;

  /// 间奏点间距系数下限（× 字号，圆心到圆心）。
  ///
  /// 0.3 时三点几乎叠成一个整体，是"合并成一坨"的下限。
  static const double minInterludeDotSpacing = 0.3;

  /// 间奏点间距系数上限（× 字号，圆心到圆心）。
  static const double maxInterludeDotSpacing = 2.5;

  /// 间奏点间距系数默认值（× 字号，圆心到圆心，安卓/全局基线）。
  ///
  /// 0.9 = 历史写死值，确保升级后视觉不变。
  static const double defaultInterludeDotSpacing = 0.9;

  // ============== 按设备类型的默认值（手机 / Pad） ==============

  /// 按设备类型的字号默认：手机 29px，Pad 40px。
  /// Windows AM 播放页默认 50px（见 [defaultFontSizeForCurrentPlatform]）。
  static double get _deviceDefaultFontSize =>
      Platform.isWindows ? 50 : (_isPadDevice() ? 40 : 29);

  /// 按设备类型的字重默认：手机半粗(w600)，Pad 黑体(w900)。
  /// Windows AM 播放页默认特粗(w900)。
  static int get _deviceDefaultFontWeight =>
      Platform.isWindows ? 900 : (_isPadDevice() ? 900 : 600);

  /// 按设备类型的行间距默认：手机 1.4x，Pad 0.9x。
  /// Windows AM 播放页默认 0.8x（见 [defaultLineSpacingForCurrentPlatform]）。
  static double get _deviceDefaultLineSpacing =>
      Platform.isWindows ? 0.8 : (_isPadDevice() ? 0.9 : 1.4);

  /// 是否 Pad 设备（物理屏幕最短边 >= 600dp），与 DeviceProvider 判断一致。
  /// 用于首次使用 / 重置时按设备类型提供差异化歌词默认值。
  static bool _isPadDevice() {
    final view = ui.PlatformDispatcher.instance.views.first;
    final size = view.physicalSize / view.devicePixelRatio;
    return size.shortestSide >= 600;
  }

  // ============== SharedPreferences keys ==============

  static const String _keyFontSize = 'lyric_font_size';
  static const String _keyLineSpacing = 'lyric_line_spacing';
  static const String _keyFontWeight = 'lyric_font_weight';
  static const String _keyUseGaussianBlur = 'lyric_use_gaussian_blur';
  static const String _keyBlurIntensity = 'lyric_blur_intensity';
  static const String _keyUseGlowEffect = 'lyric_use_glow_effect';
  static const String _keyGlowIntensity = 'lyric_glow_intensity';
  static const String _keyGlowCharScale = 'lyric_glow_char_scale';
  static const String _keyUseFlowingBackground = 'lyric_use_flowing_background';
  static const String _keyFontSource = 'lyric_font_source';
  static const String _keyCustomFontPath = 'lyric_custom_font_path';
  static const String _keyCustomTextColor = 'lyric_custom_text_color';
  static const String _keyShowTranslation = 'lyric_show_translation';
  static const String _keyDisplayMode = 'lyric_display_mode';
  static const String _keyUseDuetLayout = 'lyric_use_duet_layout';
  static const String _keyLineBalance = 'lyric_line_balance';
  static const String _keyEcoMode = 'lyric_eco_mode';
  static const String _keyUseDynamicLyricColor = 'lyric_dynamic_color';
  static const String _keyDynamicColorMixRatio =
      'lyric_dynamic_color_mix_ratio';
  static const String _keyAboveLinesPlayedColor =
      'lyric_above_lines_played_color';
  static const String _keyGlowThresholdFactor = 'lyric_glow_threshold_factor';
  static const String _keyGlowThresholdMode = 'lyric_glow_threshold_mode';
  static const String _keyGlowFixedThresholdMs = 'lyric_glow_fixed_threshold_ms';
  static const String _keyInactiveScale = 'lyric_inactive_scale';
  static const String _keyAlignPosition = 'lyric_align_position';
  static const String _keyCascadeMaxDelayMs = 'lyric_cascade_max_delay_ms';
  static const String _keyCascadeBaseStepMs = 'lyric_cascade_base_step_ms';
  static const String _keyCascadeDecayX = 'lyric_cascade_decay_x';
  static const String _keyPreStartBiasMs = 'lyric_prestart_bias_ms';
  static const String _keyLiftHeightPx = 'lyric_lift_height_px';
  static const String _keyStaggerFromCurrentLine =
      'lyric_stagger_from_current';
  static const String _keyFillMode = 'lyric_fill_mode';
  static const String _keyHideLyricCredits = 'lyric_hide_credits';
  static const String _keyCreditPattern = 'lyric_credit_pattern';
  static const String _keyInterludeDotsStartX = 'lyric_interlude_dots_start_x';
  static const String _keyInterludeDotRadius = 'lyric_interlude_dot_radius';
  static const String _keyInterludeDotSpacing = 'lyric_interlude_dot_spacing';
  static const String _keyPlayedOpacity = 'lyric_played_opacity';
  static const String _keyUnplayedOpacity = 'lyric_unplayed_opacity';
  static const String _keyAuxScope = 'lyric_aux_scope';

  // ============== 当前值 ==============

  double _fontSize = defaultFontSizeForCurrentPlatform;
  double _lineSpacing = defaultLineSpacingForCurrentPlatform;
  int _fontWeight = defaultFontWeightForCurrentPlatform;
  bool _useGaussianBlur = false;
  // 歌词模糊强度倍数（默认 1.0 = 历史行为）
  double _blurIntensity = defaultBlurIntensityForCurrentPlatform;
  bool _useGlowEffect = false;
  // 辉光强度倍数（默认 1.0 = 历史行为）
  double _glowIntensity = defaultGlowIntensityForCurrentPlatform;
  // 辉光字符缩放开关（默认开启 = 历史行为：凸起放大 + 左右外扩）
  bool _glowCharScale = defaultGlowCharScale;
  bool _useFlowingBackground = false;
  bool _useDuetLayout = false;
  // 平衡行换行默认关闭：保持歌词布局的原始自动换行行为。
  bool _lineBalance = false;
  bool _showTranslation = true;
  LyricDisplayMode _displayMode = LyricDisplayMode.translation;
  LyricFontSource _fontSource = LyricFontSource.system;
  String? _customFontPath;
  ui.Color? _customTextColor;
  // 歌词省电模式默认关闭。
  bool _ecoMode = false;
  // 动态字体颜色默认关闭，仅 AM 播放器可用。
  bool _useDynamicLyricColor = false;
  // 动态颜色混色比例（默认 0.15 = 历史行为：85% 白 + 15% 封面提取色）
  double _dynamicColorMixRatio = defaultDynamicColorMixRatioForCurrentPlatform;
  // 当前行以上的行是否跟随当前行已播颜色（默认关闭）
  bool _useAboveLinesPlayedColor = defaultUseAboveLinesPlayedColor;
  // 辉光触发阈值系数（默认 1.2）：触发阈值 = 歌词字长中位数 × 该系数
  double _glowThresholdFactor = defaultGlowThresholdFactorForCurrentPlatform;
  // 辉光触发判定模式（默认固定时长）：adaptive = BPM/字长中位数 × 系数，fixed = 固定阈值
  GlowThresholdMode _glowThresholdMode = GlowThresholdMode.fixed;
  // 辉光固定时长判定阈值（ms，默认 1000）：仅 fixed 模式生效
  double _glowFixedThresholdMs = defaultGlowFixedThresholdMsForCurrentPlatform;
  // 非当前行缩放（默认 0.850）：清晰层非当前行与 AM 模糊层共用此值
  double _inactiveScale = defaultInactiveScaleForCurrentPlatform;
  // 当前行垂直锚位（默认 0.35）：当前行中心落在视口高度的该比例处
  double _alignPosition = defaultAlignPositionForCurrentPlatform;
  // 级联错峰三参数（默认 = 当前调好的手感值）
  double _cascadeMaxDelayMs = defaultCascadeMaxDelayMsForCurrentPlatform;
  double _cascadeBaseStepMs = defaultCascadeBaseStepMsForCurrentPlatform;
  double _cascadeDecayX = defaultCascadeDecayXForCurrentPlatform;
  // 预启动提前量微调（ms）：级联比音频边界再提前这么多，给弹簧留收敛时间。
  double _preStartBiasMs = defaultPreStartBiasMs;
  // AM 歌词细节参数：已播字上浮高度（px）
  double _liftHeightPx = defaultLiftHeightPxForCurrentPlatform;
  // 级联错峰起点：true = 从当前行开始（默认），false = 从视口顶部开始（历史行为）
  bool _staggerFromCurrentLine = defaultStaggerFromCurrentLine;
  // 字内渐变模型：默认 sweep（myune 扫光移植），classic 为本仓原有观感
  LyricFillMode _fillMode = LyricFillMode.sweep;
  // 屏蔽歌词作者信息（默认关闭，对齐 EchoMusic lyricFilterEnabled）：
  // 开启后显示面剔除作词/作曲/编曲等制作名单与版权声明行，只留纯歌词。
  bool _hideLyricCredits = false;
  // 自定义过滤正则（空串 = 用 LyricCreditFilter.defaultPattern）。
  String _creditPattern = '';
  // AM 间奏点（节奏点）自定义：水平起点 / 单点半径 / 间距，均为 × 字号系数。
  // 默认值 = 历史写死值，升级用户视觉不变。
  double _interludeDotsStartX = defaultInterludeDotsStartX;
  double _interludeDotRadius = defaultInterludeDotRadius;
  double _interludeDotSpacing = defaultInterludeDotSpacingForCurrentPlatform;
  // 已播 / 未播歌词透明度（满 factor 时的目标 alpha，默认复刻历史观感）
  double _playedOpacity = defaultPlayedOpacityForCurrentPlatform;
  double _unplayedOpacity = defaultUnplayedOpacityForCurrentPlatform;
  // 副行（翻译 / 罗马音）显示范围（默认仅当前行 = 引入本设置前的观感）
  LyricAuxScope _auxScope = LyricAuxScope.currentLine;
  // 运行时加载成功后填充的 family（仅 custom 模式且加载成功时非 null）
  String? _loadedCustomFontFamily;
  bool _loaded = false;

  double get fontSize => _fontSize;
  double get lineSpacing => _lineSpacing;

  /// 歌词字重（FontWeight.value 数值，范围 [minFontWeight]~[maxFontWeight]）。
  int get fontWeightValue => _fontWeight;

  /// 歌词字重对应 [FontWeight]（供 TextStyle 使用）。
  FontWeight get fontWeight => FontWeight(_fontWeight);
  bool get useGaussianBlur => _useGaussianBlur;

  /// 歌词模糊强度倍数（范围 [minBlurIntensity]~[maxBlurIntensity]）。
  ///
  /// 非当前行模糊图的 sigma = 距离分级值 × 本倍数，见
  /// AppleLyricsView._blurGeometry。倍数保持"离当前行越远越糊"的相对关系。
  double get blurIntensity => _blurIntensity;

  bool get useGlowEffect => _useGlowEffect;

  /// 歌词辉光强度倍数（范围 [minGlowIntensity]~[maxGlowIntensity]）。
  ///
  /// 辉光层每帧的 alpha = `EmphasizeState.glowLevel × 本倍数`（clamp 到 1.0），
  /// 只影响亮度、不改剖面半径，保证"贴笔画"的光形不随强度变形。
  double get glowIntensity => _glowIntensity;

  /// 辉光字符缩放开关（默认 true = 历史行为）。
  ///
  /// 只控制强调字凸起时的**放大**（`EmphasizeState.scale`）与**水平外扩**
  /// （`EmphasizeState.offsetXEm`）。关闭后字符尺寸与横向位置不变，
  /// 上浮（`offsetYEm`）、正弦浮层（`floatYEm`）与辉光亮度（`glowLevel`）
  /// 全部保留——发光仍在，只是不再"顶大"。
  bool get useGlowCharScale => _glowCharScale;
  bool get useFlowingBackground => _useFlowingBackground;
  bool get useDuetLayout => _useDuetLayout;

  /// 平衡行换行是否开启（默认关闭）。
  ///
  /// 开启后长歌词行的断点由 `LyricWrapPlanner` 用 DP 求「各行宽度最均匀」的方案；
  /// 关闭则退回旧的「累加宽度超可用宽即换行」贪心（行为与改造前逐字一致）。
  bool get lineBalance => _lineBalance;
  bool get showTranslation => _showTranslation;
  LyricDisplayMode get displayMode => _displayMode;

  /// 副行（翻译 / 罗马音）显示范围，AM 与 MD3 两张播放页共用。
  LyricAuxScope get auxScope => _auxScope;
  LyricFontSource get fontSource => _fontSource;
  String? get customFontPath => _customFontPath;
  ui.Color? get customTextColor => _customTextColor;

  /// 歌词省电模式是否开启（默认关闭）。
  bool get ecoMode => _ecoMode;

  /// 歌词动态字体颜色是否开启（默认关闭，仅 AM 播放器生效）。
  bool get useDynamicLyricColor => _useDynamicLyricColor;

  /// 动态颜色混色比例（范围 [minDynamicColorMixRatio]~[maxDynamicColorMixRatio]）。
  ///
  /// 当前行歌词颜色 = 白色与封面提取色按该比例混色，再把明度抬到 ≥ 0.78
  /// （保留色相与饱和度）保证深色背景可读。默认 0.15 = 历史观感。
  double get dynamicColorMixRatio => _dynamicColorMixRatio;

  /// 当前行以上的行是否使用与当前行已播字相同的颜色（默认关闭）。
  ///
  /// 开启后「已播行」不再用主题默认歌词色，而是复用当前行的高亮色
  /// （含高斯模糊层）；颜色来源仍由 [useDynamicLyricColor] /
  /// [customTextColor] 决定，两者都未启用时本开关无视觉变化。
  bool get useAboveLinesPlayedColor => _useAboveLinesPlayedColor;

  /// 辉光触发阈值系数（范围 [minGlowThresholdFactor]~[maxGlowThresholdFactor]）。
  ///
  /// 触发阈值 = 歌词字长中位数 × 该系数；系数越小越容易触发辉光。
  double get glowThresholdFactor => _glowThresholdFactor;

  /// 辉光触发判定模式（默认 [GlowThresholdMode.fixed]）。
  ///
  /// [GlowThresholdMode.adaptive] = 原有判定（BPM/字长中位数 × 系数），
  /// [GlowThresholdMode.fixed] = 固定时长判定（[glowFixedThresholdMs]）。
  GlowThresholdMode get glowThresholdMode => _glowThresholdMode;

  /// 辉光固定时长判定阈值（ms，范围 [minGlowFixedThresholdMs]~
  /// [maxGlowFixedThresholdMs]）。仅 [glowThresholdMode] 为 fixed 时生效。
  double get glowFixedThresholdMs => _glowFixedThresholdMs;

  /// 非当前行缩放（范围 [minInactiveScale]~[maxInactiveScale]）。
  ///
  /// 清晰层非当前行的 canvas.scale 与 AM 歌词模糊层离屏渲染缩放共用此值，
  /// 因此调节后两层始终严格重合，改变的只是背景行相对当前行的后退程度。
  double get inactiveScale => _inactiveScale;

  /// 当前行垂直锚位（范围 [minAlignPosition]~[maxAlignPosition]）。
  ///
  /// 滚动目标公式 `targetY = -(lineTop + lineHeight/2 - viewportHeight × 本值)`，
  /// 即当前行中心停在视口高度的该比例处。
  double get alignPosition => _alignPosition;

  /// 级联错峰最大延迟（ms）。范围 [minCascadeMaxDelayMs]~[maxCascadeMaxDelayMs]。
  double get cascadeMaxDelayMs => _cascadeMaxDelayMs;

  /// 级联错峰步长（ms）。范围 [minCascadeBaseStepMs]~[maxCascadeBaseStepMs]。
  double get cascadeBaseStepMs => _cascadeBaseStepMs;

  /// 级联衰减分母（x in 1/x）。范围 [minCascadeDecayX]~[maxCascadeDecayX]。
  double get cascadeDecayX => _cascadeDecayX;

  /// 级联衰减因子（已折算 1/x）。供推进循环直接用。
  double get cascadeStepDecay => 1.0 / _cascadeDecayX;

  /// 预启动提前量微调（ms）。范围 [minPreStartBiasMs]~[maxPreStartBiasMs]。
  ///
  /// 仅关闭「错峰从当前行上方开始」的预启动路径消费：级联释放整体比音频
  /// 边界再提前本值，给当前行弹簧留出收敛时间（0 = 恰在边界释放）。
  double get preStartBiasMs => _preStartBiasMs;

  /// 已播字上浮高度（px，范围 [minLiftHeightPx]~[maxLiftHeightPx]）。
  ///
  /// 当前行中"已唱过"的字（word 索引小于当前演唱字）稳定停留在这个上浮量上，
  /// 未唱字保持 0；渲染侧使用的 Y 偏移为其负值。
  double get liftHeightPx => _liftHeightPx;

  /// 级联错峰是否从当前行开始（默认 true）。
  bool get staggerFromCurrentLine => _staggerFromCurrentLine;
  LyricFillMode get fillMode => _fillMode;

  /// 屏蔽歌词作者信息是否开启（默认关闭）。
  ///
  /// 开启后各歌词显示面（播放页 / 桌面悬浮窗 / 锁屏 / 车机）按
  /// `LyricCreditFilter` 剔除制作名单与版权声明行，只显示纯歌词。
  bool get hideLyricCredits => _hideLyricCredits;

  /// 自定义过滤正则（空串 = 内置默认模式，见 `LyricCreditFilter.defaultPattern`）。
  String get creditPattern => _creditPattern;

  /// 间奏点水平起点系数（× 字号，范围 [minInterludeDotsStartX]~[maxInterludeDotsStartX]）。
  ///
  /// 整组 3 个点的左边缘 x = fontSize × 本值（相对视口左缘）。默认 1.5 =
  /// 历史写死值（歌词左边界 1em 再右移 0.5em）。
  double get interludeDotsStartX => _interludeDotsStartX;

  /// 单个间奏点半径系数（× 字号，范围 [minInterludeDotRadius]~[maxInterludeDotRadius]）。
  double get interludeDotRadius => _interludeDotRadius;

  /// 间奏点间距系数（× 字号，圆心到圆心，范围
  /// [minInterludeDotSpacing]~[maxInterludeDotSpacing]）。
  double get interludeDotSpacing => _interludeDotSpacing;

  /// 已播歌词透明度（满 factor 时的亮态 alpha，范围
  /// [minPlayedOpacity]~[maxPlayedOpacity]）。
  ///
  /// 作用于当前行已唱过的字（GRADIENT 亮态）与整行高亮；渐变基线由
  /// [unplayedOpacity] 推导，保留随行缩放的 factor 联动。
  double get playedOpacity => _playedOpacity;

  /// 未播歌词透明度（满 factor 时的暗态 alpha，范围
  /// [minUnplayedOpacity]~[maxUnplayedOpacity]）。
  ///
  /// 作用于当前行未唱的字（GRADIENT 暗态）与非当前行整行（SOLID）。
  double get unplayedOpacity => _unplayedOpacity;

  /// 自定义字体（[LyricFontSource.custom]）是否加载成功。
  ///
  /// 面板提示「已应用自定义字体 / 字体加载失败」必须用它：
  /// [effectiveFontFamily] 在 Windows 的 system 档也非 null（内置思源黑体），
  /// 用它判断会把「回落到默认字体」误报成「自定义字体已生效」。
  bool get customFontLoaded => _loadedCustomFontFamily != null;

  /// 当前生效的 fontFamily（传给 TextPainter 的 TextStyle）：
  /// - [LyricFontSource.system]：Windows 返回内置思源黑体（与全局 UI 同族，
  ///   否则「还原所有设置」后歌词会掉到引擎兜底字形）；其他平台返回 null，
  ///   让 Flutter 走系统字体链
  /// - [LyricFontSource.bundled]：已废弃（内置 SimHei 已移除），等同 system
  /// - [LyricFontSource.custom]：返回 [_loadedCustomFontFamily]，
  ///   加载失败时降级为对应平台默认字体（Windows = 内置思源黑体）
  String? get effectiveFontFamily {
    switch (_fontSource) {
      case LyricFontSource.system:
      case LyricFontSource.bundled:
        return WindowsDefaultFont.loadedFamily;
      case LyricFontSource.custom:
        return _loadedCustomFontFamily ?? WindowsDefaultFont.loadedFamily;
    }
  }

  /// 计算实际行高系数。
  ///
  /// 公式：`actualLineHeight = (fontSize / defaultFontSize) * lineSpacing`
  /// 例如：
  /// - fontSize=15, lineSpacing=1.5 → (15/15)*1.5 = 1.5
  /// - fontSize=15, lineSpacing=1.0 → (15/15)*1.0 = 1.0
  /// - fontSize=20, lineSpacing=1.0 → (20/15)*1.0 ≈ 1.33
  double get lineHeightMultiplier =>
      (_fontSize / defaultFontSize) * _lineSpacing;

  /// 从 SharedPreferences 加载。App 启动时调用一次。
  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    // 首次使用（key 不存在）时按设备类型提供差异化默认：
    // 手机 29px/半粗(600)/1.4x；Pad 40px/黑体(900)/0.9x。
    // 用户后续手动调整后会持久化，届时尊重用户设置。
    _fontSize = (prefs.getDouble(_keyFontSize) ??
            defaultFontSizeForCurrentPlatform)
        .clamp(minFontSizeForCurrentPlatform, maxFontSizeForCurrentPlatform);
    _lineSpacing =
        (prefs.getDouble(_keyLineSpacing) ??
                defaultLineSpacingForCurrentPlatform)
            .clamp(minLineSpacingForCurrentPlatform,
                maxLineSpacingForCurrentPlatform);
    _fontWeight =
        (prefs.getInt(_keyFontWeight) ?? defaultFontWeightForCurrentPlatform)
            .clamp(minFontWeightForCurrentPlatform,
                maxFontWeightForCurrentPlatform);
    _useGaussianBlur = prefs.getBool(_keyUseGaussianBlur) ?? false;
    _blurIntensity =
        (prefs.getDouble(_keyBlurIntensity) ??
                defaultBlurIntensityForCurrentPlatform)
            .clamp(minBlurIntensityForCurrentPlatform,
                maxBlurIntensityForCurrentPlatform);
    _useGlowEffect = prefs.getBool(_keyUseGlowEffect) ?? false;
    _glowIntensity =
        (prefs.getDouble(_keyGlowIntensity) ??
                defaultGlowIntensityForCurrentPlatform)
            .clamp(minGlowIntensityForCurrentPlatform,
                maxGlowIntensityForCurrentPlatform);
    _glowCharScale =
        prefs.getBool(_keyGlowCharScale) ?? defaultGlowCharScale;
    _useFlowingBackground = prefs.getBool(_keyUseFlowingBackground) ?? false;
    _useDuetLayout = prefs.getBool(_keyUseDuetLayout) ?? false;
    _lineBalance = prefs.getBool(_keyLineBalance) ?? false;
    _showTranslation = prefs.getBool(_keyShowTranslation) ?? true;
    _displayMode = _displayModeFromName(prefs.getString(_keyDisplayMode));
    _auxScope = auxScopeFromName(prefs.getString(_keyAuxScope));
    _fontSource = _fontSourceFromName(prefs.getString(_keyFontSource));
    _customFontPath = prefs.getString(_keyCustomFontPath);
    final colorValue = prefs.getInt(_keyCustomTextColor);
    _customTextColor = colorValue == null ? null : ui.Color(colorValue);
    _ecoMode = prefs.getBool(_keyEcoMode) ?? false;
    _useDynamicLyricColor = prefs.getBool(_keyUseDynamicLyricColor) ?? false;
    _dynamicColorMixRatio =
        (prefs.getDouble(_keyDynamicColorMixRatio) ??
                defaultDynamicColorMixRatioForCurrentPlatform)
            .clamp(minDynamicColorMixRatioForCurrentPlatform,
                maxDynamicColorMixRatioForCurrentPlatform);
    _useAboveLinesPlayedColor =
        prefs.getBool(_keyAboveLinesPlayedColor) ??
            defaultUseAboveLinesPlayedColor;
    _glowThresholdFactor =
        (prefs.getDouble(_keyGlowThresholdFactor) ??
                defaultGlowThresholdFactorForCurrentPlatform)
            .clamp(minGlowThresholdFactorForCurrentPlatform,
                maxGlowThresholdFactorForCurrentPlatform);
    _glowThresholdMode = _glowThresholdModeFromName(
        prefs.getString(_keyGlowThresholdMode));
    _glowFixedThresholdMs =
        (prefs.getDouble(_keyGlowFixedThresholdMs) ??
                defaultGlowFixedThresholdMsForCurrentPlatform)
            .clamp(minGlowFixedThresholdMsForCurrentPlatform,
                maxGlowFixedThresholdMsForCurrentPlatform);
    _inactiveScale = (prefs.getDouble(_keyInactiveScale) ??
            defaultInactiveScaleForCurrentPlatform)
        .clamp(minInactiveScaleForCurrentPlatform,
            maxInactiveScaleForCurrentPlatform);
    _alignPosition =
        (prefs.getDouble(_keyAlignPosition) ??
                defaultAlignPositionForCurrentPlatform)
            .clamp(minAlignPositionForCurrentPlatform,
                maxAlignPositionForCurrentPlatform);
    _cascadeMaxDelayMs =
        (prefs.getDouble(_keyCascadeMaxDelayMs) ??
                defaultCascadeMaxDelayMsForCurrentPlatform)
            .clamp(minCascadeMaxDelayMsForCurrentPlatform,
                maxCascadeMaxDelayMsForCurrentPlatform);
    _cascadeBaseStepMs =
        (prefs.getDouble(_keyCascadeBaseStepMs) ??
                defaultCascadeBaseStepMsForCurrentPlatform)
            .clamp(minCascadeBaseStepMsForCurrentPlatform,
                maxCascadeBaseStepMsForCurrentPlatform);
    _cascadeDecayX =
        (prefs.getDouble(_keyCascadeDecayX) ??
                defaultCascadeDecayXForCurrentPlatform)
            .clamp(minCascadeDecayXForCurrentPlatform,
                maxCascadeDecayXForCurrentPlatform);
    _preStartBiasMs =
        (prefs.getDouble(_keyPreStartBiasMs) ?? defaultPreStartBiasMs)
            .clamp(minPreStartBiasMs, maxPreStartBiasMs);
    _liftHeightPx =
        (prefs.getDouble(_keyLiftHeightPx) ??
                defaultLiftHeightPxForCurrentPlatform)
            .clamp(minLiftHeightPxForCurrentPlatform,
                maxLiftHeightPxForCurrentPlatform);
    _staggerFromCurrentLine =
        prefs.getBool(_keyStaggerFromCurrentLine) ??
            defaultStaggerFromCurrentLine;
    _fillMode = _fillModeFromName(prefs.getString(_keyFillMode));
    _hideLyricCredits = prefs.getBool(_keyHideLyricCredits) ?? false;
    _creditPattern = prefs.getString(_keyCreditPattern) ?? '';
    _interludeDotsStartX =
        (prefs.getDouble(_keyInterludeDotsStartX) ??
                defaultInterludeDotsStartXForCurrentPlatform)
            .clamp(minInterludeDotsStartXForCurrentPlatform,
                maxInterludeDotsStartXForCurrentPlatform);
    _interludeDotRadius =
        (prefs.getDouble(_keyInterludeDotRadius) ??
                defaultInterludeDotRadiusForCurrentPlatform)
            .clamp(minInterludeDotRadiusForCurrentPlatform,
                maxInterludeDotRadiusForCurrentPlatform);
    _interludeDotSpacing =
        (prefs.getDouble(_keyInterludeDotSpacing) ??
                defaultInterludeDotSpacingForCurrentPlatform)
            .clamp(minInterludeDotSpacingForCurrentPlatform,
                maxInterludeDotSpacingForCurrentPlatform);
    _playedOpacity =
        (prefs.getDouble(_keyPlayedOpacity) ??
                defaultPlayedOpacityForCurrentPlatform)
            .clamp(minPlayedOpacityForCurrentPlatform,
                maxPlayedOpacityForCurrentPlatform);
    _unplayedOpacity =
        (prefs.getDouble(_keyUnplayedOpacity) ??
                defaultUnplayedOpacityForCurrentPlatform)
            .clamp(minUnplayedOpacityForCurrentPlatform,
                maxUnplayedOpacityForCurrentPlatform);
    _loaded = true;
    notifyListeners();
    // 若已配置自定义字体，立即尝试加载（Fire-and-forget，加载完成后会 notifyListeners）
    if (_fontSource == LyricFontSource.custom) {
      await _tryLoadCustomFont();
    }
  }

  /// 设置字号并持久化。会触发 [notifyListeners]。
  Future<void> setFontSize(double size) async {
    final clamped = size.clamp(
        minFontSizeForCurrentPlatform, maxFontSizeForCurrentPlatform);
    if (clamped == _fontSize) return;
    _fontSize = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyFontSize, _fontSize);
  }

  /// 设置行间距系数并持久化。
  Future<void> setLineSpacing(double spacing) async {
    final clamped = spacing.clamp(
        minLineSpacingForCurrentPlatform, maxLineSpacingForCurrentPlatform);
    if (clamped == _lineSpacing) return;
    _lineSpacing = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyLineSpacing, _lineSpacing);
  }

  /// 设置字重并持久化。会触发 [notifyListeners]。
  Future<void> setFontWeight(int value) async {
    final clamped = value.clamp(
        minFontWeightForCurrentPlatform, maxFontWeightForCurrentPlatform);
    if (clamped == _fontWeight) return;
    _fontWeight = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyFontWeight, _fontWeight);
  }

  /// 设置高斯模糊开关并持久化。
  Future<void> setUseGaussianBlur(bool enabled) async {
    if (_useGaussianBlur == enabled) return;
    _useGaussianBlur = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyUseGaussianBlur, enabled);
  }

  /// 设置歌词模糊强度倍数并持久化。
  Future<void> setBlurIntensity(double value) async {
    final clamped = value.clamp(minBlurIntensityForCurrentPlatform,
        maxBlurIntensityForCurrentPlatform);
    if (clamped == _blurIntensity) return;
    _blurIntensity = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyBlurIntensity, _blurIntensity);
  }

  /// 设置辉光效果开关并持久化。
  Future<void> setUseGlowEffect(bool enabled) async {
    if (_useGlowEffect == enabled) return;
    _useGlowEffect = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyUseGlowEffect, enabled);
  }

  /// 设置辉光强度倍数并持久化。
  Future<void> setGlowIntensity(double value) async {
    final clamped = value.clamp(
        minGlowIntensityForCurrentPlatform, maxGlowIntensityForCurrentPlatform);
    if (clamped == _glowIntensity) return;
    _glowIntensity = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyGlowIntensity, _glowIntensity);
  }

  /// 设置辉光字符缩放开关并持久化。
  Future<void> setUseGlowCharScale(bool enabled) async {
    if (_glowCharScale == enabled) return;
    _glowCharScale = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyGlowCharScale, enabled);
  }

  /// 设置动态流光背景开关并持久化。
  Future<void> setUseFlowingBackground(bool enabled) async {
    if (_useFlowingBackground == enabled) return;
    _useFlowingBackground = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyUseFlowingBackground, enabled);
  }

  /// 设置男女对唱歌词优化开关并持久化。
  Future<void> setUseDuetLayout(bool enabled) async {
    if (_useDuetLayout == enabled) return;
    _useDuetLayout = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyUseDuetLayout, enabled);
  }

  /// 设置平衡行换行开关并持久化。
  Future<void> setLineBalance(bool enabled) async {
    if (_lineBalance == enabled) return;
    _lineBalance = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyLineBalance, enabled);
  }

  /// 设置歌词省电模式开关并持久化。
  /// 开启后歌词界面锁定 60fps，用户上下滑动歌词时临时解锁帧率限制。
  Future<void> setEcoMode(bool enabled) async {
    if (_ecoMode == enabled) return;
    _ecoMode = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyEcoMode, enabled);
  }

  /// 设置歌词动态字体颜色开关并持久化。
  /// 开启后当前行歌词颜色按「(1 - 比例) 白 + 比例 封面提取色」混色（仅 AM 播放器生效）。
  Future<void> setUseDynamicLyricColor(bool enabled) async {
    if (_useDynamicLyricColor == enabled) return;
    _useDynamicLyricColor = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyUseDynamicLyricColor, enabled);
  }

  /// 设置动态颜色混色比例并持久化。
  ///
  /// 范围 [minDynamicColorMixRatio]~[maxDynamicColorMixRatio]，默认 0.15。
  /// 同值早退（不重复落盘 / 通知）；比例变化由已订阅 [LyricPreferences] 的
  /// 歌词视图重算当前行颜色，下一帧即生效。
  Future<void> setDynamicColorMixRatio(double ratio) async {
    final clamped = ratio.clamp(
        minDynamicColorMixRatioForCurrentPlatform,
        maxDynamicColorMixRatioForCurrentPlatform);
    if (clamped == _dynamicColorMixRatio) return;
    _dynamicColorMixRatio = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyDynamicColorMixRatio, _dynamicColorMixRatio);
  }

  /// 设置「上方行使用已播颜色」开关并持久化。
  ///
  /// 只影响当前行以上的行（清晰层与模糊层），当前行/下方行不变。
  Future<void> setUseAboveLinesPlayedColor(bool enabled) async {
    if (_useAboveLinesPlayedColor == enabled) return;
    _useAboveLinesPlayedColor = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAboveLinesPlayedColor, enabled);
  }

  /// 设置辉光触发阈值系数并持久化。
  ///
  /// 触发阈值 = 歌词字长中位数 × 该系数，范围 [minGlowThresholdFactor]~
  /// [maxGlowThresholdFactor]（默认 [defaultGlowThresholdFactor]=1.2）。
  /// 系数越小越容易触发辉光。
  Future<void> setGlowThresholdFactor(double value) async {
    final clamped = value.clamp(minGlowThresholdFactorForCurrentPlatform,
        maxGlowThresholdFactorForCurrentPlatform);
    if (clamped == _glowThresholdFactor) return;
    _glowThresholdFactor = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyGlowThresholdFactor, _glowThresholdFactor);
  }

  /// 设置辉光触发判定模式（自适应 / 固定时长）并持久化。
  ///
  /// 同值早退（不重复落盘 / 通知）；切换后由 AppleLyricsView 的
  /// LyricPreferences 监听触发阈值重算，下一帧即生效。
  Future<void> setGlowThresholdMode(GlowThresholdMode mode) async {
    if (_glowThresholdMode == mode) return;
    _glowThresholdMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyGlowThresholdMode, mode.name);
  }

  /// 设置辉光固定时长判定阈值（ms）并持久化。
  ///
  /// 范围 [minGlowFixedThresholdMsForCurrentPlatform]~
  /// [maxGlowFixedThresholdMsForCurrentPlatform]。仅 fixed 判定模式生效。
  Future<void> setGlowFixedThresholdMs(double value) async {
    final clamped = value.clamp(minGlowFixedThresholdMsForCurrentPlatform,
        maxGlowFixedThresholdMsForCurrentPlatform);
    if (clamped == _glowFixedThresholdMs) return;
    _glowFixedThresholdMs = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyGlowFixedThresholdMs, _glowFixedThresholdMs);
  }

  /// 设置非当前行缩放并持久化。
  ///
  /// 该值同时驱动清晰层非当前行的 canvas.scale 与 AM 歌词模糊层离屏渲染缩放，
  /// 因此调节后两层始终严格重合，改变的只是背景行相对当前行的后退程度。
  Future<void> setInactiveScale(double value) async {
    final clamped = value.clamp(
        minInactiveScaleForCurrentPlatform, maxInactiveScaleForCurrentPlatform);
    if (clamped == _inactiveScale) return;
    _inactiveScale = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyInactiveScale, _inactiveScale);
  }

  /// 设置当前行垂直锚位并持久化。
  ///
  /// 锚位变化由 posY 弹簧在下一次 `setCurrentLine` 时重新求 target 自然生效，
  /// 无需额外失效任何布局缓存（行高/行顶与锚位无关）。
  Future<void> setAlignPosition(double value) async {
    final clamped = value.clamp(
        minAlignPositionForCurrentPlatform, maxAlignPositionForCurrentPlatform);
    if (clamped == _alignPosition) return;
    _alignPosition = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyAlignPosition, _alignPosition);
  }

  /// 设置级联错峰最大延迟并持久化。
  Future<void> setCascadeMaxDelayMs(double value) async {
    final clamped = value.clamp(minCascadeMaxDelayMsForCurrentPlatform,
        maxCascadeMaxDelayMsForCurrentPlatform);
    if (clamped == _cascadeMaxDelayMs) return;
    _cascadeMaxDelayMs = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyCascadeMaxDelayMs, _cascadeMaxDelayMs);
  }

  /// 设置级联错峰步长并持久化。
  Future<void> setCascadeBaseStepMs(double value) async {
    final clamped = value.clamp(minCascadeBaseStepMsForCurrentPlatform,
        maxCascadeBaseStepMsForCurrentPlatform);
    if (clamped == _cascadeBaseStepMs) return;
    _cascadeBaseStepMs = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyCascadeBaseStepMs, _cascadeBaseStepMs);
  }

  /// 设置级联衰减分母（x in 1/x）并持久化。
  Future<void> setCascadeDecayX(double value) async {
    final clamped = value.clamp(
        minCascadeDecayXForCurrentPlatform, maxCascadeDecayXForCurrentPlatform);
    if (clamped == _cascadeDecayX) return;
    _cascadeDecayX = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyCascadeDecayX, _cascadeDecayX);
  }

  /// 设置预启动提前量微调（ms）并持久化。
  Future<void> setPreStartBiasMs(double value) async {
    final clamped = value.clamp(minPreStartBiasMs, maxPreStartBiasMs);
    if (clamped == _preStartBiasMs) return;
    _preStartBiasMs = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyPreStartBiasMs, _preStartBiasMs);
  }

  /// 设置已播字上浮高度（px）并持久化。
  Future<void> setLiftHeightPx(double value) async {
    final clamped = value.clamp(
        minLiftHeightPxForCurrentPlatform, maxLiftHeightPxForCurrentPlatform);
    if (clamped == _liftHeightPx) return;
    _liftHeightPx = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyLiftHeightPx, _liftHeightPx);
  }

  /// 设置已播歌词透明度并持久化。
  Future<void> setPlayedOpacity(double value) async {
    final clamped = value.clamp(
        minPlayedOpacityForCurrentPlatform, maxPlayedOpacityForCurrentPlatform);
    if (clamped == _playedOpacity) return;
    _playedOpacity = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyPlayedOpacity, _playedOpacity);
  }

  /// 设置未播歌词透明度并持久化。
  Future<void> setUnplayedOpacity(double value) async {
    final clamped = value.clamp(minUnplayedOpacityForCurrentPlatform,
        maxUnplayedOpacityForCurrentPlatform);
    if (clamped == _unplayedOpacity) return;
    _unplayedOpacity = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyUnplayedOpacity, _unplayedOpacity);
  }

  /// 设置级联错峰起点（从当前行开始）并持久化。
  Future<void> setStaggerFromCurrentLine(bool enabled) async {
    if (_staggerFromCurrentLine == enabled) return;
    _staggerFromCurrentLine = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyStaggerFromCurrentLine, enabled);
  }

  /// 设置字内渐变模型（classic / sweep）并持久化。
  ///
  /// 同值早退（不重复落盘 / 通知）；切换后由 AppleLyricsView 的
  /// LyricPreferences 监听触发重绘，下一帧即生效。
  Future<void> setFillMode(LyricFillMode mode) async {
    if (_fillMode == mode) return;
    _fillMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyFillMode, mode.name);
  }

  /// 设置歌词翻译副行显示开关并持久化。
  Future<void> setShowTranslation(bool enabled) async {
    if (_showTranslation == enabled) return;
    _showTranslation = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyShowTranslation, enabled);
  }

  /// 设置辅助行显示模式（翻译/罗马音）并持久化。
  Future<void> setDisplayMode(LyricDisplayMode mode) async {
    if (_displayMode == mode) return;
    _displayMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDisplayMode, mode.name);
  }

  /// 设置副行显示范围并持久化。
  ///
  /// 两张播放页各自监听本类：AM 页把范围解析成逐行展开进度并平滑过渡，
  /// MD3 页按范围重算行高，因此这里只负责落值 + 通知，不做任何渲染逻辑。
  Future<void> setAuxScope(LyricAuxScope scope) async {
    if (_auxScope == scope) return;
    _auxScope = scope;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyAuxScope, scope.name);
  }

  /// 设置「屏蔽歌词作者信息」开关并持久化。
  ///
  /// 各显示面通过监听本类的 notifyListeners 即时重过滤，无需切歌。
  Future<void> setHideLyricCredits(bool enabled) async {
    if (_hideLyricCredits == enabled) return;
    _hideLyricCredits = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyHideLyricCredits, enabled);
  }

  /// 设置自定义过滤正则并持久化（空串 = 恢复内置默认模式）。
  ///
  /// 合法性由调用方（设置页）经 `LyricCreditFilter.isValidPattern` 校验；
  /// 即使存入非法正则，过滤器侧也会编译失败回退默认，不会崩溃或误滤。
  Future<void> setCreditPattern(String pattern) async {
    final trimmed = pattern.trim();
    if (_creditPattern == trimmed) return;
    _creditPattern = trimmed;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (trimmed.isEmpty) {
      await prefs.remove(_keyCreditPattern);
    } else {
      await prefs.setString(_keyCreditPattern, trimmed);
    }
  }

  // ============== 间奏点（节奏点）自定义 ==============

  /// 设置间奏点水平起点系数（× 字号）并持久化。
  ///
  /// 渲染侧在 `paint()` 即时读取本值，调整无需切歌即生效。
  Future<void> setInterludeDotsStartX(double value) async {
    final clamped = value.clamp(minInterludeDotsStartXForCurrentPlatform,
        maxInterludeDotsStartXForCurrentPlatform);
    if (clamped == _interludeDotsStartX) return;
    _interludeDotsStartX = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyInterludeDotsStartX, _interludeDotsStartX);
  }

  /// 设置单个间奏点半径系数（× 字号）并持久化。
  Future<void> setInterludeDotRadius(double value) async {
    final clamped = value.clamp(minInterludeDotRadiusForCurrentPlatform,
        maxInterludeDotRadiusForCurrentPlatform);
    if (clamped == _interludeDotRadius) return;
    _interludeDotRadius = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyInterludeDotRadius, _interludeDotRadius);
  }

  /// 设置间奏点间距系数（× 字号，圆心到圆心）并持久化。
  Future<void> setInterludeDotSpacing(double value) async {
    final clamped = value.clamp(minInterludeDotSpacingForCurrentPlatform,
        maxInterludeDotSpacingForCurrentPlatform);
    if (clamped == _interludeDotSpacing) return;
    _interludeDotSpacing = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyInterludeDotSpacing, _interludeDotSpacing);
  }

  // ============== 歌词动画参数导入/导出（JSON / 预设） ==============

  /// 数值型参数键（JSON key = 本类 getter 名）。
  static const List<String> _animationNumValueKeys = <String>[
    'inactiveScale',
    'alignPosition',
    'liftHeightPx',
    'interludeDotsStartX',
    'interludeDotRadius',
    'interludeDotSpacing',
    'cascadeMaxDelayMs',
    'cascadeBaseStepMs',
    'cascadeDecayX',
    'preStartBiasMs',
    'dynamicColorMixRatio',
    'blurIntensity',
    'glowIntensity',
    'glowThresholdFactor',
    'glowFixedThresholdMs',
    'playedOpacity',
    'unplayedOpacity',
  ];

  /// 枚举型参数键及合法取值（持久化/导出均用 name 字符串）。
  static const Map<String, Set<String>> _animationEnumValueKeys =
      <String, Set<String>>{
    'glowThresholdMode': <String>{'adaptive', 'fixed'},
    'fillMode': <String>{'classic', 'sweep'},
  };

  /// 歌词动画页可导入/导出的全部参数键。
  static const List<String> animationValueKeys = <String>[
    ..._animationNumValueKeys,
    'staggerFromCurrentLine',
    ...<String>['glowThresholdMode', 'fillMode'],
  ];

  /// 把任意 JSON 值过滤成仅含合法键 + 合法类型的参数表。
  ///
  /// - 数值键只接受 [num]（int/double），统一转 double
  /// - 布尔键只接受 [bool]
  /// - 枚举键只接受已知 name 字符串（adaptive/fixed、classic/sweep）
  /// - 未知键、类型不符、非法枚举值一律丢弃
  static Map<String, Object?> sanitizeAnimationValues(Object? raw) {
    if (raw is! Map) return <String, Object?>{};
    final result = <String, Object?>{};
    for (final key in _animationNumValueKeys) {
      final value = raw[key];
      if (value is num) result[key] = value.toDouble();
    }
    final stagger = raw['staggerFromCurrentLine'];
    if (stagger is bool) result['staggerFromCurrentLine'] = stagger;
    for (final entry in _animationEnumValueKeys.entries) {
      final value = raw[entry.key];
      if (value is String && entry.value.contains(value)) {
        result[entry.key] = value;
      }
    }
    return result;
  }

  /// 导出本页 20 项当前值（数值均为 double，枚举为 name 字符串）。
  Map<String, Object?> exportAnimationValues() => <String, Object?>{
        'inactiveScale': _inactiveScale,
        'alignPosition': _alignPosition,
        'liftHeightPx': _liftHeightPx,
        'interludeDotsStartX': _interludeDotsStartX,
        'interludeDotRadius': _interludeDotRadius,
        'interludeDotSpacing': _interludeDotSpacing,
        'cascadeMaxDelayMs': _cascadeMaxDelayMs,
        'cascadeBaseStepMs': _cascadeBaseStepMs,
        'cascadeDecayX': _cascadeDecayX,
        'staggerFromCurrentLine': _staggerFromCurrentLine,
        'preStartBiasMs': _preStartBiasMs,
        'dynamicColorMixRatio': _dynamicColorMixRatio,
        'blurIntensity': _blurIntensity,
        'glowIntensity': _glowIntensity,
        'glowThresholdMode': _glowThresholdMode.name,
        'glowThresholdFactor': _glowThresholdFactor,
        'glowFixedThresholdMs': _glowFixedThresholdMs,
        'fillMode': _fillMode.name,
        'playedOpacity': _playedOpacity,
        'unplayedOpacity': _unplayedOpacity,
      };

  /// 应用本页参数。
  ///
  /// - 只处理 [sanitizeAnimationValues] 保留下来的键；缺失键保持当前值不变
  ///   （支持局部导入 / 前后版本兼容）
  /// - 逐项调用现有 setter，自动复用 setter 内部的 clamp 与持久化逻辑
  Future<void> applyAnimationValues(Map<String, Object?> rawValues) async {
    final values = sanitizeAnimationValues(rawValues);
    if (values.isEmpty) return;

    final inactiveScale = values['inactiveScale'];
    if (inactiveScale is double) await setInactiveScale(inactiveScale);
    final alignPosition = values['alignPosition'];
    if (alignPosition is double) await setAlignPosition(alignPosition);
    final liftHeightPx = values['liftHeightPx'];
    if (liftHeightPx is double) await setLiftHeightPx(liftHeightPx);
    final interludeDotsStartX = values['interludeDotsStartX'];
    if (interludeDotsStartX is double) {
      await setInterludeDotsStartX(interludeDotsStartX);
    }
    final interludeDotRadius = values['interludeDotRadius'];
    if (interludeDotRadius is double) {
      await setInterludeDotRadius(interludeDotRadius);
    }
    final interludeDotSpacing = values['interludeDotSpacing'];
    if (interludeDotSpacing is double) {
      await setInterludeDotSpacing(interludeDotSpacing);
    }
    final cascadeMaxDelayMs = values['cascadeMaxDelayMs'];
    if (cascadeMaxDelayMs is double) {
      await setCascadeMaxDelayMs(cascadeMaxDelayMs);
    }
    final cascadeBaseStepMs = values['cascadeBaseStepMs'];
    if (cascadeBaseStepMs is double) {
      await setCascadeBaseStepMs(cascadeBaseStepMs);
    }
    final cascadeDecayX = values['cascadeDecayX'];
    if (cascadeDecayX is double) await setCascadeDecayX(cascadeDecayX);
    final staggerFromCurrentLine = values['staggerFromCurrentLine'];
    if (staggerFromCurrentLine is bool) {
      await setStaggerFromCurrentLine(staggerFromCurrentLine);
    }
    final preStartBiasMs = values['preStartBiasMs'];
    if (preStartBiasMs is double) await setPreStartBiasMs(preStartBiasMs);
    final dynamicColorMixRatio = values['dynamicColorMixRatio'];
    if (dynamicColorMixRatio is double) {
      await setDynamicColorMixRatio(dynamicColorMixRatio);
    }
    final blurIntensity = values['blurIntensity'];
    if (blurIntensity is double) await setBlurIntensity(blurIntensity);
    final glowIntensity = values['glowIntensity'];
    if (glowIntensity is double) await setGlowIntensity(glowIntensity);
    final glowThresholdMode = values['glowThresholdMode'];
    if (glowThresholdMode is String) {
      await setGlowThresholdMode(
        glowThresholdMode == 'adaptive'
            ? GlowThresholdMode.adaptive
            : GlowThresholdMode.fixed,
      );
    }
    final glowThresholdFactor = values['glowThresholdFactor'];
    if (glowThresholdFactor is double) {
      await setGlowThresholdFactor(glowThresholdFactor);
    }
    final glowFixedThresholdMs = values['glowFixedThresholdMs'];
    if (glowFixedThresholdMs is double) {
      await setGlowFixedThresholdMs(glowFixedThresholdMs);
    }
    final fillMode = values['fillMode'];
    if (fillMode is String) {
      await setFillMode(
        fillMode == 'classic' ? LyricFillMode.classic : LyricFillMode.sweep,
      );
    }
    final playedOpacity = values['playedOpacity'];
    if (playedOpacity is double) await setPlayedOpacity(playedOpacity);
    final unplayedOpacity = values['unplayedOpacity'];
    if (unplayedOpacity is double) await setUnplayedOpacity(unplayedOpacity);
  }

  // ============== 歌词字体来源 ==============

  /// 设置字体来源并持久化。
  Future<void> setFontSource(LyricFontSource source) async {
    if (_fontSource == source) return;
    _fontSource = source;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyFontSource, source.name);
  }

  /// 设置自定义字体文件路径并立即尝试加载注册。
  /// 传 null 清除路径并卸载已加载的字体（实际效果降级到 system）。
  Future<void> setCustomFontPath(String? path) async {
    if (_customFontPath == path) return;
    _customFontPath = path;
    final prefs = await SharedPreferences.getInstance();
    if (path != null) {
      await prefs.setString(_keyCustomFontPath, path);
      await _tryLoadCustomFont();
    } else {
      await prefs.remove(_keyCustomFontPath);
      _loadedCustomFontFamily = null;
      notifyListeners();
    }
  }

  Future<void> setCustomTextColor(ui.Color? color) async {
    if (_customTextColor?.toARGB32() == color?.toARGB32()) return;
    _customTextColor = color;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (color == null) {
      await prefs.remove(_keyCustomTextColor);
    } else {
      await prefs.setInt(_keyCustomTextColor, color.toARGB32());
    }
  }

  /// 内部：尝试用 FontLoader 加载 [_customFontPath] 指向的字体文件。
  /// 加载成功则填充 [_loadedCustomFontFamily] 并 notifyListeners。
  ///
  /// 注意：Flutter 的 FontLoader 不支持对同一 family name 重复调用 load()，
  /// 否则会抛异常。因此每次加载使用带计数器的唯一 family name。
  int _fontLoadCounter = 0;
  Future<void> _tryLoadCustomFont() async {
    final path = _customFontPath;
    if (path == null || path.isEmpty) {
      _loadedCustomFontFamily = null;
      return;
    }
    final file = File(path);
    if (!file.existsSync()) {
      print('[LyricPreferences] 字体文件不存在: $path');
      _loadedCustomFontFamily = null;
      return;
    }
    try {
      final bytes = await file.readAsBytes();
      // 每次使用唯一的 family name，避免 FontLoader 重复注册同一 family 抛异常
      _fontLoadCounter++;
      final familyName = '$lyricCustomFontFamily#$_fontLoadCounter';
      final loader = FontLoader(familyName);
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
      _loadedCustomFontFamily = familyName;
      notifyListeners();
    } catch (e) {
      print('[LyricPreferences] 字体加载失败: $e');
      _loadedCustomFontFamily = null;
      notifyListeners();
    }
  }

  /// 历史值 'bundled'（内置 SimHei 已移除）迁移为 [LyricFontSource.system]。
  static LyricFontSource _fontSourceFromName(String? name) {
    switch (name) {
      case 'custom':
        return LyricFontSource.custom;
      default:
        // 'bundled' 与未知值一并归入 system（bundled 字体已不再打包）
        return LyricFontSource.system;
    }
  }

  static LyricDisplayMode _displayModeFromName(String? name) {
    return name == 'roma' ? LyricDisplayMode.roma : LyricDisplayMode.translation;
  }

  /// 仅 'classic' → [LyricFillMode.classic]，其余（含 null / 未知值）→ sweep（默认）。
  static LyricFillMode _fillModeFromName(String? name) {
    return name == 'classic' ? LyricFillMode.classic : LyricFillMode.sweep;
  }

  /// 仅 'adaptive' → [GlowThresholdMode.adaptive]，其余（含 null / 未知值）→ fixed（默认）。
  static GlowThresholdMode _glowThresholdModeFromName(String? name) {
    return name == 'adaptive'
        ? GlowThresholdMode.adaptive
        : GlowThresholdMode.fixed;
  }

  /// 重置为默认值（按设备类型：手机 / Pad 差异化默认）。
  Future<void> reset() async {
    _fontSize = defaultFontSizeForCurrentPlatform;
    _lineSpacing = defaultLineSpacingForCurrentPlatform;
    _fontWeight = defaultFontWeightForCurrentPlatform;
    _useGaussianBlur = false;
    _blurIntensity = defaultBlurIntensity;
    _useGlowEffect = false;
    _useFlowingBackground = false;
    _useDuetLayout = false;
    _lineBalance = false;
    _showTranslation = true;
    _displayMode = LyricDisplayMode.translation;
    _fontSource = LyricFontSource.system;
    _customFontPath = null;
    _customTextColor = null;
    _loadedCustomFontFamily = null;
    _ecoMode = false;
    _useDynamicLyricColor = false;
    _dynamicColorMixRatio = defaultDynamicColorMixRatioForCurrentPlatform;
    _useAboveLinesPlayedColor = defaultUseAboveLinesPlayedColor;
    _glowThresholdFactor = defaultGlowThresholdFactorForCurrentPlatform;
    _glowThresholdMode = GlowThresholdMode.fixed;
    _glowFixedThresholdMs = defaultGlowFixedThresholdMsForCurrentPlatform;
    _glowIntensity = defaultGlowIntensityForCurrentPlatform;
    _glowCharScale = defaultGlowCharScale;
    _inactiveScale = defaultInactiveScaleForCurrentPlatform;
    _alignPosition = defaultAlignPositionForCurrentPlatform;
    _cascadeMaxDelayMs = defaultCascadeMaxDelayMsForCurrentPlatform;
    _cascadeBaseStepMs = defaultCascadeBaseStepMsForCurrentPlatform;
    _cascadeDecayX = defaultCascadeDecayXForCurrentPlatform;
    _preStartBiasMs = defaultPreStartBiasMs;
    _liftHeightPx = defaultLiftHeightPxForCurrentPlatform;
    _staggerFromCurrentLine = defaultStaggerFromCurrentLine;
    _fillMode = LyricFillMode.sweep;
    _hideLyricCredits = false;
    _creditPattern = '';
    _interludeDotsStartX = defaultInterludeDotsStartXForCurrentPlatform;
    _interludeDotRadius = defaultInterludeDotRadiusForCurrentPlatform;
    _interludeDotSpacing = defaultInterludeDotSpacingForCurrentPlatform;
    _playedOpacity = defaultPlayedOpacityForCurrentPlatform;
    _unplayedOpacity = defaultUnplayedOpacityForCurrentPlatform;
    _auxScope = LyricAuxScope.currentLine;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyFontSize, _fontSize);
    await prefs.setDouble(_keyLineSpacing, _lineSpacing);
    await prefs.setInt(_keyFontWeight, _fontWeight);
    await prefs.setBool(_keyUseGaussianBlur, _useGaussianBlur);
    await prefs.remove(_keyBlurIntensity);
    await prefs.setBool(_keyUseGlowEffect, _useGlowEffect);
    await prefs.setBool(_keyUseFlowingBackground, _useFlowingBackground);
    await prefs.setBool(_keyUseDuetLayout, _useDuetLayout);
    await prefs.setBool(_keyLineBalance, _lineBalance);
    await prefs.setBool(_keyShowTranslation, _showTranslation);
    await prefs.setString(_keyDisplayMode, _displayMode.name);
    await prefs.remove(_keyEcoMode);
    await prefs.remove(_keyUseDynamicLyricColor);
    await prefs.remove(_keyDynamicColorMixRatio);
    await prefs.remove(_keyAboveLinesPlayedColor);
    await prefs.remove(_keyGlowThresholdFactor);
    await prefs.remove(_keyGlowThresholdMode);
    await prefs.remove(_keyGlowFixedThresholdMs);
    await prefs.remove(_keyGlowIntensity);
    await prefs.remove(_keyGlowCharScale);
    await prefs.remove(_keyInactiveScale);
    await prefs.remove(_keyAlignPosition);
    await prefs.remove(_keyCascadeMaxDelayMs);
    await prefs.remove(_keyCascadeBaseStepMs);
    await prefs.remove(_keyCascadeDecayX);
    await prefs.remove(_keyPreStartBiasMs);
    await prefs.remove(_keyLiftHeightPx);
    await prefs.remove(_keyStaggerFromCurrentLine);
    await prefs.remove(_keyFillMode);
    await prefs.remove(_keyHideLyricCredits);
    await prefs.remove(_keyCreditPattern);
    await prefs.remove(_keyInterludeDotsStartX);
    await prefs.remove(_keyInterludeDotRadius);
    await prefs.remove(_keyInterludeDotSpacing);
    await prefs.remove(_keyPlayedOpacity);
    await prefs.remove(_keyUnplayedOpacity);
    await prefs.remove(_keyAuxScope);
    await prefs.remove(_keyFontSource);
    await prefs.remove(_keyCustomFontPath);
    await prefs.remove(_keyCustomTextColor);
  }
}
