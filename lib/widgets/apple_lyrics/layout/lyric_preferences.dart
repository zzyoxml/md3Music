import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/services/windows_default_font.dart';

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

  /// 辉光固定时长判定阈值下限（ms）。
  static const double minGlowFixedThresholdMs = 500;

  /// 辉光固定时长判定阈值上限（ms）。
  static const double maxGlowFixedThresholdMs = 2000;

  /// 辉光固定时长判定阈值默认值（ms）。
  static const double defaultGlowFixedThresholdMs = 1000;

  /// 非当前行缩放最小值。
  ///
  /// 0.80 时背景行明显后退，再小会与当前行脱节。
  static const double minInactiveScale = 0.80;

  /// 非当前行缩放最大值。1.0 = 关闭缩放（所有行等大）。
  static const double maxInactiveScale = 1.00;

  /// 非当前行缩放默认值。
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

  /// 级联错峰最大延迟下限（ms）。
  static const double minCascadeMaxDelayMs = 100;

  /// 级联错峰最大延迟上限（ms）。
  static const double maxCascadeMaxDelayMs = 2000;

  /// 级联错峰最大延迟默认（ms）：越靠下的行最大"粘"这么久才回位。
  static const double defaultCascadeMaxDelayMs = 750;

  /// 级联错峰步长下限（ms）。
  static const double minCascadeBaseStepMs = 20;

  /// 级联错峰步长上限（ms）。
  static const double maxCascadeBaseStepMs = 200;

  /// 级联错峰步长默认（ms）：相邻行的错峰时间间隔。
  static const double defaultCascadeBaseStepMs = 60;

  /// 级联衰减分母下限（x in 1/x）。
  static const double minCascadeDecayX = 1.0;

  /// 级联衰减分母上限（x in 1/x）。
  static const double maxCascadeDecayX = 2.0;

  /// 级联衰减分母默认（x in 1/x）：每越过一行步长 × 1/x。
  static const double defaultCascadeDecayX = 1.1;

  /// 已播字上浮高度最小值（px）。0 = 完全不上浮。
  static const double minLiftHeightPx = 0.0;

  /// 已播字上浮高度最大值（px）。
  ///
  /// 10px 已明显超过一行字高的十分之一量级，再大会让当前行"飘"离基线。
  static const double maxLiftHeightPx = 10.0;

  /// 已播字上浮高度默认值（px）。
  ///
  /// 保持历史写死值 3.0（AMLL：当前字最大上浮 -3px），确保升级后视觉不变。
  /// 渲染侧取负值作为 Y 偏移（向上为负）。
  static const double defaultLiftHeightPx = 3.0;

  /// 级联错峰是否从当前行开始（默认 true）。
  ///
  /// - true：仅当前行及以下的行错峰跟随，当前行 delay=0，上方行不参与
  ///   「按住等错峰」，随全局滚动同步回位；
  /// - false：历史行为，从视口顶部行开始逐行累加错峰（上方行也错峰）。
  static const bool defaultStaggerFromCurrentLine = true;

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

  /// 间奏点间距系数默认值（× 字号，圆心到圆心）。
  ///
  /// 0.9 = 历史写死值，确保升级后视觉不变。
  static const double defaultInterludeDotSpacing = 0.9;

  // ============== 按设备类型的默认值（手机 / Pad） ==============

  /// 按设备类型的字号默认：手机 29px，Pad 40px。
  /// Windows AM 播放页默认 50px。
  static double get _deviceDefaultFontSize =>
      Platform.isWindows ? 50 : (_isPadDevice() ? 40 : 29);

  /// 按设备类型的字重默认：手机半粗(w600)，Pad 黑体(w900)。
  /// Windows AM 播放页默认特粗(w900)。
  static int get _deviceDefaultFontWeight =>
      Platform.isWindows ? 900 : (_isPadDevice() ? 900 : 600);

  /// 按设备类型的行间距默认：手机 1.4x，Pad 0.9x。
  /// Windows AM 播放页默认 1.0x。
  static double get _deviceDefaultLineSpacing =>
      Platform.isWindows ? 1.0 : (_isPadDevice() ? 0.9 : 1.4);

  /// Windows 歌词动画默认值；其他平台继续使用原有默认值。
  static double get defaultAlignPositionForCurrentPlatform =>
      Platform.isWindows ? 0.45 : defaultAlignPosition;
  static double get defaultCascadeMaxDelayMsForCurrentPlatform =>
      Platform.isWindows ? 990 : defaultCascadeMaxDelayMs;
  static double get defaultCascadeBaseStepMsForCurrentPlatform =>
      Platform.isWindows ? 80 : defaultCascadeBaseStepMs;
  static double get defaultLiftHeightPxForCurrentPlatform =>
      Platform.isWindows ? 2.5 : defaultLiftHeightPx;

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
  static const String _keyLiftHeightPx = 'lyric_lift_height_px';
  static const String _keyStaggerFromCurrentLine =
      'lyric_stagger_from_current';
  static const String _keyFillMode = 'lyric_fill_mode';
  static const String _keyHideLyricCredits = 'lyric_hide_credits';
  static const String _keyCreditPattern = 'lyric_credit_pattern';
  static const String _keyInterludeDotsStartX = 'lyric_interlude_dots_start_x';
  static const String _keyInterludeDotRadius = 'lyric_interlude_dot_radius';
  static const String _keyInterludeDotSpacing = 'lyric_interlude_dot_spacing';

  // ============== 当前值 ==============

  double _fontSize = Platform.isWindows ? 50 : defaultUserFontSize;
  double _lineSpacing = Platform.isWindows ? 1.0 : defaultLineSpacing;
  int _fontWeight = Platform.isWindows ? 900 : defaultFontWeight;
  bool _useGaussianBlur = false;
  // 歌词模糊强度倍数（默认 1.0 = 历史行为）
  double _blurIntensity = defaultBlurIntensity;
  bool _useGlowEffect = false;
  // 辉光强度倍数（默认 1.0 = 历史行为）
  double _glowIntensity = defaultGlowIntensity;
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
  double _dynamicColorMixRatio = defaultDynamicColorMixRatio;
  // 当前行以上的行是否跟随当前行已播颜色（默认关闭）
  bool _useAboveLinesPlayedColor = defaultUseAboveLinesPlayedColor;
  // 辉光触发阈值系数（默认 1.2）：触发阈值 = 歌词字长中位数 × 该系数
  double _glowThresholdFactor = defaultGlowThresholdFactor;
  // 辉光触发判定模式（默认固定时长）：adaptive = BPM/字长中位数 × 系数，fixed = 固定阈值
  GlowThresholdMode _glowThresholdMode = GlowThresholdMode.fixed;
  // 辉光固定时长判定阈值（ms，默认 1000）：仅 fixed 模式生效
  double _glowFixedThresholdMs = defaultGlowFixedThresholdMs;
  // 非当前行缩放（默认 0.850）：清晰层非当前行与 AM 模糊层共用此值
  double _inactiveScale = defaultInactiveScale;
  // 当前行垂直锚位（默认 0.35）：当前行中心落在视口高度的该比例处
  double _alignPosition = defaultAlignPositionForCurrentPlatform;
  // 级联错峰三参数（默认 = 当前调好的手感值）
  double _cascadeMaxDelayMs = defaultCascadeMaxDelayMsForCurrentPlatform;
  double _cascadeBaseStepMs = defaultCascadeBaseStepMsForCurrentPlatform;
  double _cascadeDecayX = defaultCascadeDecayX;
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
  double _interludeDotSpacing = defaultInterludeDotSpacing;
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
    _fontSize = prefs.getDouble(_keyFontSize) ?? _deviceDefaultFontSize;
    _lineSpacing = prefs.getDouble(_keyLineSpacing) ?? _deviceDefaultLineSpacing;
    _fontWeight =
        (prefs.getInt(_keyFontWeight) ?? _deviceDefaultFontWeight)
            .clamp(minFontWeight, maxFontWeight);
    _useGaussianBlur = prefs.getBool(_keyUseGaussianBlur) ?? false;
    _blurIntensity =
        (prefs.getDouble(_keyBlurIntensity) ?? defaultBlurIntensity)
            .clamp(minBlurIntensity, maxBlurIntensity);
    _useGlowEffect = prefs.getBool(_keyUseGlowEffect) ?? false;
    _glowIntensity =
        (prefs.getDouble(_keyGlowIntensity) ?? defaultGlowIntensity)
            .clamp(minGlowIntensity, maxGlowIntensity);
    _glowCharScale =
        prefs.getBool(_keyGlowCharScale) ?? defaultGlowCharScale;
    _useFlowingBackground = prefs.getBool(_keyUseFlowingBackground) ?? false;
    _useDuetLayout = prefs.getBool(_keyUseDuetLayout) ?? false;
    _lineBalance = prefs.getBool(_keyLineBalance) ?? false;
    _showTranslation = prefs.getBool(_keyShowTranslation) ?? true;
    _displayMode = _displayModeFromName(prefs.getString(_keyDisplayMode));
    _fontSource = _fontSourceFromName(prefs.getString(_keyFontSource));
    _customFontPath = prefs.getString(_keyCustomFontPath);
    final colorValue = prefs.getInt(_keyCustomTextColor);
    _customTextColor = colorValue == null ? null : ui.Color(colorValue);
    _ecoMode = prefs.getBool(_keyEcoMode) ?? false;
    _useDynamicLyricColor = prefs.getBool(_keyUseDynamicLyricColor) ?? false;
    _dynamicColorMixRatio =
        (prefs.getDouble(_keyDynamicColorMixRatio) ??
                defaultDynamicColorMixRatio)
            .clamp(minDynamicColorMixRatio, maxDynamicColorMixRatio);
    _useAboveLinesPlayedColor =
        prefs.getBool(_keyAboveLinesPlayedColor) ??
            defaultUseAboveLinesPlayedColor;
    _glowThresholdFactor =
        (prefs.getDouble(_keyGlowThresholdFactor) ?? defaultGlowThresholdFactor)
            .clamp(minGlowThresholdFactor, maxGlowThresholdFactor);
    _glowThresholdMode = _glowThresholdModeFromName(
        prefs.getString(_keyGlowThresholdMode));
    _glowFixedThresholdMs =
        (prefs.getDouble(_keyGlowFixedThresholdMs) ?? defaultGlowFixedThresholdMs)
            .clamp(minGlowFixedThresholdMs, maxGlowFixedThresholdMs);
    _inactiveScale = (prefs.getDouble(_keyInactiveScale) ?? defaultInactiveScale)
        .clamp(minInactiveScale, maxInactiveScale);
    _alignPosition =
        (prefs.getDouble(_keyAlignPosition) ??
                defaultAlignPositionForCurrentPlatform)
            .clamp(minAlignPosition, maxAlignPosition);
    _cascadeMaxDelayMs =
        (prefs.getDouble(_keyCascadeMaxDelayMs) ??
                defaultCascadeMaxDelayMsForCurrentPlatform)
            .clamp(minCascadeMaxDelayMs, maxCascadeMaxDelayMs);
    _cascadeBaseStepMs =
        (prefs.getDouble(_keyCascadeBaseStepMs) ??
                defaultCascadeBaseStepMsForCurrentPlatform)
            .clamp(minCascadeBaseStepMs, maxCascadeBaseStepMs);
    _cascadeDecayX =
        (prefs.getDouble(_keyCascadeDecayX) ?? defaultCascadeDecayX)
            .clamp(minCascadeDecayX, maxCascadeDecayX);
    _liftHeightPx =
        (prefs.getDouble(_keyLiftHeightPx) ??
                defaultLiftHeightPxForCurrentPlatform)
            .clamp(minLiftHeightPx, maxLiftHeightPx);
    _staggerFromCurrentLine =
        prefs.getBool(_keyStaggerFromCurrentLine) ??
            defaultStaggerFromCurrentLine;
    _fillMode = _fillModeFromName(prefs.getString(_keyFillMode));
    _hideLyricCredits = prefs.getBool(_keyHideLyricCredits) ?? false;
    _creditPattern = prefs.getString(_keyCreditPattern) ?? '';
    _interludeDotsStartX =
        (prefs.getDouble(_keyInterludeDotsStartX) ?? defaultInterludeDotsStartX)
            .clamp(minInterludeDotsStartX, maxInterludeDotsStartX);
    _interludeDotRadius =
        (prefs.getDouble(_keyInterludeDotRadius) ?? defaultInterludeDotRadius)
            .clamp(minInterludeDotRadius, maxInterludeDotRadius);
    _interludeDotSpacing =
        (prefs.getDouble(_keyInterludeDotSpacing) ?? defaultInterludeDotSpacing)
            .clamp(minInterludeDotSpacing, maxInterludeDotSpacing);
    _loaded = true;
    notifyListeners();
    // 若已配置自定义字体，立即尝试加载（Fire-and-forget，加载完成后会 notifyListeners）
    if (_fontSource == LyricFontSource.custom) {
      await _tryLoadCustomFont();
    }
  }

  /// 设置字号并持久化。会触发 [notifyListeners]。
  Future<void> setFontSize(double size) async {
    final clamped = size.clamp(minFontSize, maxFontSize);
    if (clamped == _fontSize) return;
    _fontSize = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyFontSize, _fontSize);
  }

  /// 设置行间距系数并持久化。
  Future<void> setLineSpacing(double spacing) async {
    final clamped = spacing.clamp(minLineSpacing, maxLineSpacing);
    if (clamped == _lineSpacing) return;
    _lineSpacing = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyLineSpacing, _lineSpacing);
  }

  /// 设置字重并持久化。会触发 [notifyListeners]。
  Future<void> setFontWeight(int value) async {
    final clamped = value.clamp(minFontWeight, maxFontWeight);
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
    final clamped = value.clamp(minBlurIntensity, maxBlurIntensity);
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
    final clamped = value.clamp(minGlowIntensity, maxGlowIntensity);
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
    final clamped =
        ratio.clamp(minDynamicColorMixRatio, maxDynamicColorMixRatio);
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
    final clamped =
        value.clamp(minGlowThresholdFactor, maxGlowThresholdFactor);
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
  /// 范围 [minGlowFixedThresholdMs]~[maxGlowFixedThresholdMs]
  /// （默认 [defaultGlowFixedThresholdMs]=1000）。仅 fixed 判定模式生效。
  Future<void> setGlowFixedThresholdMs(double value) async {
    final clamped =
        value.clamp(minGlowFixedThresholdMs, maxGlowFixedThresholdMs);
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
    final clamped = value.clamp(minInactiveScale, maxInactiveScale);
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
    final clamped = value.clamp(minAlignPosition, maxAlignPosition);
    if (clamped == _alignPosition) return;
    _alignPosition = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyAlignPosition, _alignPosition);
  }

  /// 设置级联错峰最大延迟并持久化。
  Future<void> setCascadeMaxDelayMs(double value) async {
    final clamped = value.clamp(minCascadeMaxDelayMs, maxCascadeMaxDelayMs);
    if (clamped == _cascadeMaxDelayMs) return;
    _cascadeMaxDelayMs = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyCascadeMaxDelayMs, _cascadeMaxDelayMs);
  }

  /// 设置级联错峰步长并持久化。
  Future<void> setCascadeBaseStepMs(double value) async {
    final clamped = value.clamp(minCascadeBaseStepMs, maxCascadeBaseStepMs);
    if (clamped == _cascadeBaseStepMs) return;
    _cascadeBaseStepMs = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyCascadeBaseStepMs, _cascadeBaseStepMs);
  }

  /// 设置级联衰减分母（x in 1/x）并持久化。
  Future<void> setCascadeDecayX(double value) async {
    final clamped = value.clamp(minCascadeDecayX, maxCascadeDecayX);
    if (clamped == _cascadeDecayX) return;
    _cascadeDecayX = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyCascadeDecayX, _cascadeDecayX);
  }

  /// 设置已播字上浮高度（px）并持久化。
  Future<void> setLiftHeightPx(double value) async {
    final clamped = value.clamp(minLiftHeightPx, maxLiftHeightPx);
    if (clamped == _liftHeightPx) return;
    _liftHeightPx = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyLiftHeightPx, _liftHeightPx);
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
    final clamped = value.clamp(minInterludeDotsStartX, maxInterludeDotsStartX);
    if (clamped == _interludeDotsStartX) return;
    _interludeDotsStartX = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyInterludeDotsStartX, _interludeDotsStartX);
  }

  /// 设置单个间奏点半径系数（× 字号）并持久化。
  Future<void> setInterludeDotRadius(double value) async {
    final clamped = value.clamp(minInterludeDotRadius, maxInterludeDotRadius);
    if (clamped == _interludeDotRadius) return;
    _interludeDotRadius = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyInterludeDotRadius, _interludeDotRadius);
  }

  /// 设置间奏点间距系数（× 字号，圆心到圆心）并持久化。
  Future<void> setInterludeDotSpacing(double value) async {
    final clamped = value.clamp(minInterludeDotSpacing, maxInterludeDotSpacing);
    if (clamped == _interludeDotSpacing) return;
    _interludeDotSpacing = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyInterludeDotSpacing, _interludeDotSpacing);
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
    _fontSize = _deviceDefaultFontSize;
    _lineSpacing = _deviceDefaultLineSpacing;
    _fontWeight = _deviceDefaultFontWeight;
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
    _dynamicColorMixRatio = defaultDynamicColorMixRatio;
    _useAboveLinesPlayedColor = defaultUseAboveLinesPlayedColor;
    _glowThresholdFactor = defaultGlowThresholdFactor;
    _glowThresholdMode = GlowThresholdMode.fixed;
    _glowFixedThresholdMs = defaultGlowFixedThresholdMs;
    _glowIntensity = defaultGlowIntensity;
    _glowCharScale = defaultGlowCharScale;
    _inactiveScale = defaultInactiveScale;
    _alignPosition = defaultAlignPositionForCurrentPlatform;
    _cascadeMaxDelayMs = defaultCascadeMaxDelayMsForCurrentPlatform;
    _cascadeBaseStepMs = defaultCascadeBaseStepMsForCurrentPlatform;
    _cascadeDecayX = defaultCascadeDecayX;
    _liftHeightPx = defaultLiftHeightPxForCurrentPlatform;
    _staggerFromCurrentLine = defaultStaggerFromCurrentLine;
    _fillMode = LyricFillMode.sweep;
    _hideLyricCredits = false;
    _creditPattern = '';
    _interludeDotsStartX = defaultInterludeDotsStartX;
    _interludeDotRadius = defaultInterludeDotRadius;
    _interludeDotSpacing = defaultInterludeDotSpacing;
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
    await prefs.remove(_keyLiftHeightPx);
    await prefs.remove(_keyStaggerFromCurrentLine);
    await prefs.remove(_keyFillMode);
    await prefs.remove(_keyHideLyricCredits);
    await prefs.remove(_keyCreditPattern);
    await prefs.remove(_keyInterludeDotsStartX);
    await prefs.remove(_keyInterludeDotRadius);
    await prefs.remove(_keyInterludeDotSpacing);
    await prefs.remove(_keyFontSource);
    await prefs.remove(_keyCustomFontPath);
    await prefs.remove(_keyCustomTextColor);
  }
}
