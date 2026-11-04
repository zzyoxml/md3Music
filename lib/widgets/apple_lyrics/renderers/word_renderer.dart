/// 逐字 mask alpha 渲染器（核心渲染组件）
///
/// 参照 spec.md "Requirement: 逐字 mask alpha 渲染" 实现。
/// 文字本身固定白色，靠 mask alpha 区分已播 / 未播字：
/// - 当前行（GRADIENT 模式）：已播字 alpha = dynamicBrightAlpha，未播字 alpha = dynamicDarkAlpha，
///   当前字按指数衰减在两者之间过渡，左亮右暗。
/// - 非当前行（SOLID 模式）：整行均匀 alpha = dynamicDarkAlpha。
///
/// 本类不是 Widget，是核心绘制逻辑类，由外部 CustomPainter 调用 [paintLine]。
/// 动画驱动由外部 AnimationController + Ticker 调用 [tick] 实现（SubTask 7.7）。
library;

import 'dart:math';
import 'dart:ui';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show kDebugMode, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/widgets.dart';

import '../../../core/build_flags.dart';
import '../layout/duet_layout.dart';
import '../layout/lyric_layout.dart';
import '../layout/lyric_preferences.dart';
import 'package:md3music/core/utils/lyric_wrap_plan.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'emphasize_effect.dart';
import 'lyric_sweep_fill.dart';

/// 逐字 mask alpha 渲染器。
///
/// 持有当前 scale、isActive、currentLineProgress 与每个 word 的当前 alpha 值，
/// 通过 [tick] 推进指数衰减动画，通过 [paintLine] 用对应 alpha 逐字绘制白色文本。
class WordRenderer {
  WordRenderer();

  // ============== 内部状态 ==============

  /// 当前是否为当前行（GRADIENT 模式）。默认 false（SOLID）。
  bool _isActive = false;

  /// 当前行缩放，0.850（inactive）~1.0（active）。默认 inactive。
  double _scale = LyricLayout.inactiveScale;

  /// 当前绑定的 LyricLine。用于检测 line 切换并重置 alpha map。
  LyricLine? _boundLine;

  /// 缓存的字号（用于检测 fontSize 变化时重新测量 word 宽度）。
  double _boundFontSize = -1;

  /// 缓存的字重（用于检测 fontWeight 变化时重新测量 word 宽度）。
  int _boundFontWeight = -1;

  /// 缓存的行高系数（用于检测行间距变化时重新绑定）。
  ///
  /// 行盒高度与字形在盒内的垂直位置都由 `TextStyle.height`（= lineHeight）决定，
  /// 不进绑定键则调行间距后 painter 仍按旧行高绘制，表现为不刷新。
  double _boundLineHeight = -1;

  /// 每个 word 的缓存宽度（在 [_ensureBound] 时一次性测量）。
  ///
  /// **性能优化**：之前每帧 paintLine 都为每个 word 创建 TextPainter + layout
  /// 来测量宽度（用于换行判断）。现在只在 line 切换或 fontSize 变化时测量一次。
  /// 10 word/行 × 60fps = 每秒 600 次 layout → 缓存后降为 0 次/帧。
  List<double> _wordWidths = const <double>[];

  /// v4 优化：per-word TextPainter 实例列表。
  ///
  /// **背景**：v3 Task 1 用单实例 _painter + _lastSetAlphas 缓存导致"当前行重复显示同一字"bug
  /// （commit b56b7e9 已回滚）。根因：单实例 _painter 在循环中被多个 word 共用，下一个 word 的
  /// set text 会覆盖 painter.text，导致 _lastSetAlphas[i] 比较时基于"上次循环的最后一个 word"
  /// 状态而非该 word 自身上次状态。
  /// **v4 解决方案**：每个 word 独占一个 TextPainter 实例，alpha 不变时跳过 set text + layout 是安全的。
  /// 10 word/行 × 60fps = 每秒 600 次 layout → 缓存后降到 ~100-200 次/秒
  /// （仅当前字 + 边界附近 word 在过渡）。
  ///
  /// **v5 波浪化**：仅【非强调字】使用整词 painter；【强调字】拆成逐字符 painter（[_charPainters]），
  /// 该槽位为 null。
  List<TextPainter?> _wordPainters = const <TextPainter?>[];

  /// v4 优化：每个 word index 上次设置的 alpha（量化步进值）。
  /// 仅在量化值变化时才 set text + layout，避免每帧 N 次 layout。
  List<int> _lastSetAlphas = const <int>[];

  /// 每个 word index 的当前 alpha 值。
  List<double> _wordAlphas = const <double>[];

  /// v3 优化：renderer 是否已收敛（alpha 和 Y offset 都不再变化）。
  /// 用于 AppleLyricsView 判断是否可以停止 Ticker。
  bool _isConverged = true;

  /// 每个 word index 的当前 Y 轴偏移（上浮特效）。
  ///
  /// AMLL 规范：当前字会轻微上浮（最大约 -3px），用指数衰减平滑过渡。
  /// 已播字回到 0，未播字保持 0，当前字上浮。
  List<double> _wordYOffsets = const <double>[];

  /// 已播字上浮幅度（px，向上为负）。
  ///
  /// 由用户在设置页"歌词动画 → 已播字上浮高度"调节
  /// （[LyricPreferences.liftHeightPx]，默认 3.0）。0 = 完全不上浮。
  ///
  /// 每帧在 [tick] 内读取一次并缓存到局部变量，避免在 per-word 循环里重复
  /// 访问单例；偏好变化会在下一帧自然生效，无需重置绑定缓存。
  static double get _maxLiftPx => -LyricPreferences.instance.liftHeightPx;

  /// AMLL 上浮 ATTACK 速度：当前字上浮指数衰减系数。
  static const double _liftAttackSpeed = 30.0;

  /// AMLL 上浮 RELEASE 速度：当前字回落指数衰减系数。
  static const double _liftReleaseSpeed = 10.0;

  /// 强调辉光效果计算器（由外部注入）。
  EmphasizeEffect? _emphasizeEffect;

  /// v5 逐字符波浪：每个 word 的【逐字符辉光状态】列表。
  ///
  /// 仅强调字（[_wordEmphasisFlags] 为 true）有内容，长度 = 该字字符数；
  /// 非强调字为常量空列表。索引同 [_wordPainters]。
  List<List<EmphasizeState>> _emphasizeCharStates =
      const <List<EmphasizeState>>[];

  /// v5 逐字符波浪：每个 word 的逐字符 TextPainter 列表（仅强调字）。
  /// 字符宽度与相对起始 X 分别缓存在 [_charWidths] / [_charStartXs]。
  List<List<TextPainter>> _charPainters = const <List<TextPainter>>[];

  /// 每个强调字内每个字符的宽度（px）。
  List<List<double>> _charWidths = const <List<double>>[];

  /// 每个强调字内每个字符相对字首的起始 X（px）。
  List<List<double>> _charStartXs = const <List<double>>[];

  /// 每个强调字内每个字符上次设置的 alpha（量化步进值，同 [_lastSetAlphas]）。
  List<List<int>> _lastSetCharAlphas = const <List<int>>[];

  // ============== v6 自驱动波浪状态（逐字 per-word） ==============
  //
  // 波浪相位由帧时钟 dt 每帧推进（脱离播放位置流 _smoothPosMs），保证动画
  // 平滑、与视图重绘门控解耦；字切换 / seek 跳变时用绝对时间重新锚定相位，
  // 保持与音频对齐。
  //
  // **v8：逐字状态**。波浪不再只属于"当前字"：当前字唱完后，其错位启动的
  // 后续字符波浪可能还没走完，改为继续推进（"尾巴"）直到所有字符相位完成再
  // 消失——避免字尾整词被截断造成回落跳变。因此锚定/相位都按字索引独立存储。

  /// 各字锚定时的播放位置（毫秒，-1 = 未锚定/已走完，用于 seek 跳变检测）。
  List<double> _waveAnchorPosMs = const <double>[];

  /// 各字锚定后由帧 dt 累计推进的毫秒数（用于判断当前播放位置是否应重锚）。
  List<double> _waveAdvanceMs = const <double>[];

  /// 各字每字符凸起进度（0~1，超出即 clamp；强调字初始为 1.0=已完成）。
  List<List<double>> _waveBumpPhases = const <List<double>>[];

  /// 各字每字符正弦浮层进度（0~1，超出即 clamp）。
  List<List<double>> _waveFloatPhases = const <List<double>>[];

  /// seek 跳变检测容差（ms）：当前播放位置与自驱动预期位置偏差超过此值即重锚。
  static const double _waveReanchorToleranceMs = 150;

  /// 图片懒预生成提前量（ms）：强调字开始前多久请求字形图/辉光精灵，
  /// 把 toImage 从行切换一次性突发摊到各字激活前（P1 时序拆分）。
  static const double _imagePrewarmLeadMs = 250;

  /// 行级元数据判定缓存（行绑定期计算一次）。
  /// true 表示该行为元数据行（作词/作曲 等），整行禁用辉光。
  /// 仅依赖 [LyricLine.text]，在 [_ensureBound] 时计算，避免每帧重复正则匹配。
  bool _isMetadataLine = false;

  /// 上次 set text 时的文字颜色值。
  /// 主题切换时 textColorValue 变化，需清空 _lastSetAlphas 强制重建所有 word TextSpan。
  int _lastTextColorValue = -1;

  /// 当前行专用的文字颜色（ARGB int，仅 [_isActive] 时生效）。
  /// 动态字体颜色：由封面提取色按混色比例与白色混色得到（比例见
  /// `LyricPreferences.dynamicColorMixRatio`），
  /// null 表示不使用（回退到 LyricLayout.textColorValue）。
  int? _activeColorValue;

  /// 每字辉光判定缓存（行绑定期计算一次）。
  /// 与 [_wordPainters] / [_wordWidths] 同长度同索引。
  /// true 表示该 word 应触发辉光（已通过 duration + 内容过滤）。
  /// 仅依赖 [LyricWord.text] 与 [LyricWord.duration]，在 [_ensureBound] 时计算。
  List<bool> _wordEmphasisFlags = const <bool>[];

  /// 翻译副行专用 TextPainter（复用避免每帧创建，仅 active 行使用）。
  final TextPainter _translationPainter = TextPainter(
    textDirection: TextDirection.ltr,
  );

  /// 渐变路径复用的 Paint 实例（避免每帧新建，减少 GC）。
  /// 渐变路径稳态下每帧只改 shader，0 次 layout。
  final Paint _gradientPaint = Paint();

  /// 辉光层渐变调制复用的 Paint（`BlendMode.modulate`，与 [_gradientPaint] 同款）。
  ///
  /// 辉光需要像文字一样**沿字内进度逐段点亮**：精灵是纯白 alpha 贴图，
  /// 用 4 停 / 2 停渐变 modulate 它，就能让已唱侧达到峰值、未唱侧淡出。
  final Paint _glowRampPaint = Paint()..blendMode = BlendMode.modulate;

  /// 辉光层复用的 Paint 实例（避免每帧新建 Paint + ImageFilter）。
  final Paint _glowBlurPaint = Paint();

  /// P1-5 方案 1：辉光精灵缓存（wordIndex × charIndex → 最大 blur 的模糊白字图）。
  ///
  /// 字符激活时用 [PictureRecorder] + [ui.Image] 异步渲染一次，
  /// 之后每帧 [Canvas.drawImage] 贴图（透明度跟随 glowLevel），
  /// 替代每帧 `saveLayer + ImageFilter.blur` 的 GPU 开销。
  /// 仅在 _ensureBound 重置（切行/字号变化）与文字颜色变化时失效。
  /// 仅强调字有内容；非强调字为常量空列表。
  List<List<ui.Image?>> _charGlowSprites = const <List<ui.Image?>>[];

  /// 正在异步渲染辉光精灵的 (wordIndex:charIndex → rowHeight) 映射。
  ///
  /// 记录每个渲染任务对应的行盒，用于行盒竞态保护：旧行盒渲染未完成时，
  /// 若同一字被按新行盒重新请求，回调通过 [_glowSpriteRowHeight] 校验丢弃
  /// 过期结果，避免误用行盒不匹配（偏下）的精灵。
  final Map<String, double> _glowSpritePendingRow = <String, double>{};

  /// 每个辉光精灵生成时使用的行盒（wordIndex:charIndex → rowHeight）。
  ///
  /// 辉光精灵按绘制时的行盒（[LyricLayout.lineHeight] 或换行行的 0.8x）渲染，
  /// 与正文字形同盒顶对齐；行盒变化（换行行 ⇄ 非换行行）时据此释放旧精灵
  /// 并强制重新渲染，保证光晕始终贴合文字。
  final Map<String, double> _glowSpriteRowHeight = <String, double>{};

  /// 辉光行盒诊断日志去重标记：仅打印状态变化的换行行辉光记录。
  String _lastGlowDebug = '';

  /// 精灵渲染代数：_ensureBound / reset 时递增，
  /// 异步回调用代数校验，丢弃过期（renderer 已重置/切行）的渲染结果。
  int _spriteEpoch = 0;

  /// 辉光精灵贴图复用的 Paint（透明度由 glowLevel 经 ColorFilter 驱动）。
  ///
  /// **必须显式设 `filterQuality`**：精灵按 1× 逻辑像素渲染，绘制时被放大到
  /// DPR 倍（Android 典型 2.75~3.5×）。`Paint()` 默认 `FilterQuality.none`
  /// 是最近邻，会把高斯模糊的连续 alpha 斜坡量化成 DPR 像素宽的台阶
  /// （实测 alpha 档位 246 → 16、相邻像素跳变 255 → 73~93）。
  final Paint _glowImagePaint = Paint()
    ..filterQuality = FilterQuality.low;

  /// 辉光强度 >100% 时的追加层：同一张精灵用 [BlendMode.plus] 再叠一次。
  ///
  /// 单次绘制的 alpha 封顶 1.0，光晕最亮处（笔画外沿）无法再提亮；加法叠加
  /// 才能让"强度"在 100%~200% 区间真的有亮度增量（光晕本就是加性光）。
  final Paint _glowPlusPaint = Paint()
    ..filterQuality = FilterQuality.low
    ..blendMode = BlendMode.plus;

  /// v7 逐字符预渲染图片缓存（wordIndex × charIndex → 纯白字形图）。
  ///
  /// 波浪激活窗口内逐字符缩放/位移时，若直接用 TextPainter 每帧绘制文字，
  /// 字形会被重新栅格化到亚像素尺寸 → 边缘闪烁抖动（"缩放不够无极"）。
  /// 改为行绑定时把字符预渲染成图片，每帧只做 canvas 变换（GPU 双线性采样）
  /// + ColorFilter.matrix 上色（文字色 + mask alpha），画面平滑且成本更低。
  /// 仅强调字有内容；非强调字为常量空列表。
  List<List<ui.Image?>> _charImages = const <List<ui.Image?>>[];

  /// 正在异步渲染字符图片的 (wordIndex, charIndex) 集合（避免重复请求）。
  final Set<String> _charImagePending = <String>{};

  /// 字符图片绘制复用的 Paint（文字色 + alpha 经 ColorFilter 驱动）。
  ///
  /// 采样模式同 [_glowImagePaint]：字形图按 [_charImageSupersample] 逻辑像素
  /// 渲染，绘制时还要叠加强调凸起 `scale`（最高 1.12×），非 3.0 的 DPR 上
  /// 必然发生重采样。默认的最近邻会让字缘只剩 16 档 alpha（锯齿）。
  final Paint _charImagePaint = Paint()
    ..filterQuality = FilterQuality.low;

  /// 整词纯白字形图缓存（Windows 专用，见 [_glyphBlitActive]）。
  ///
  /// **为什么需要**：文本绘制的**垂直**位置会被栅格化量化到整 device 像素
  /// （Windows/Impeller 实测：y+0.375 与 y+0.0 逐像素完全相同，y+0.75 才跳
  /// 1 device px）。已播字上浮 1.77px × DPR 1.25 ≈ 2.2 device px，整段动画
  /// 只剩 2 个台阶 → 观感「卡住再被吸过去」（用户说的"像被自动吸附"）。
  /// 改为图片 + GPU 双线性采样后位移连续（做法同 [_charImages]）。
  List<ui.Image?> _wordGlyphImages = const <ui.Image?>[];

  /// 每张字形图渲染时使用的行盒高度（换行行 0.8x 行盒需按自身行盒重渲染）。
  List<double> _wordGlyphRowHeights = const <double>[];

  /// 正在异步渲染整词字形图的行内索引（避免同一字重复请求）。
  final Set<int> _wordGlyphPending = <int>{};

  /// 字形图代次：行绑定切换后异步回调若代次不符直接丢弃。
  int _wordGlyphEpoch = 0;

  /// 是否启用整词字形图路径（仅 Windows 且开启上浮时，见 [_ensureBound]）。
  bool _glyphBlitActive = false;

  /// 诊断/测试用：强制关闭整词字形图路径，用于对照"改前"的整像素台阶行为。
  @visibleForTesting
  static bool debugDisableGlyphBlit = false;

  /// 整词字形图超采样倍数（与 [_charImageSupersample] 同口径）。
  ///
  /// **口径提醒：这是「逻辑像素」倍数，不是「设备像素」倍数。**
  /// Windows 实测 DPR=1.25 → 3× 逻辑 = 2.40× 设备降采样；实测 2× 逻辑
  /// （1.60× 设备）配合双线性降采样反而更清晰（中间 alpha 占比 29.1% vs
  /// 20.5%，MAE 5.86 vs 6.43），显存还从 9× 降到 4×。改动前须重跑
  /// tmp/probe_glyph_resample.dart 对照。
  static const int _wordGlyphSupersample = 3;

  /// 字形图绘制复用的 Paint（均匀路径按 ColorFilter 上色，渐变路径保持纯白）。
  ///
  /// **必须显式设 `filterQuality`**：图按 [_wordGlyphSupersample] 逻辑像素渲染，
  /// 缩回原生尺寸时在 DPR≠3 的设备上必然重采样。`Paint()` 默认
  /// `FilterQuality.none` 是最近邻，等于把 3× 超采样的抗锯齿信息整体丢掉
  /// （实测 Windows 2.40× 降采样下 alpha 档位 228 → 16，字缘硬台阶）。
  final Paint _wordGlyphPaint = Paint()
    ..filterQuality = FilterQuality.low;

  // ============== 辉光剖面（字形最亮，向外递减）==============
  //
  // **观感契约**：辉光应当是「字形处最亮 → 向四周单调递减」的经典外发光。
  //
  // 反面做法（已废弃）：挖空字形本体（`dstOut`）只留笔画外侧的光。
  // 它看起来"贴笔画"，但亮度曲线是「字形内部 0 → 笔画边缘骤亮 → 向外递减」，
  // 峰值不在字形上而在字形边上；文字半透明时（扫光中段 alpha 会掉到 0.4）
  // 就露出一圈「字内暗 → 边缘亮 → 外侧又暗」的亮暗亮，越调越糟。
  //
  // 现做法：**不挖空**，直接把字形按多层半径模糊后叠加。高斯模糊天然满足
  // 「中心最亮、向外递减」，与字形叠加后字形处最亮。
  //
  // 多层半径（紧 → 松，权重递减）：紧层负责贴轮廓的实感，松层负责扩散范围。
  // 单层大半径会把汉字字怀（0.05~0.2em）糊满成一团，所以最内层必须够紧，
  // 由外层补足扩散——实测 32px「日」的最内层取 0.07em 时，
  // 沿笔画均匀度最好（cv 0.126、min/max 2.0；0.05em 时为 0.151 / 2.8）。
  //
  // 半径以 em 表达（随字号缩放），烘焙一次进精灵图；每帧只调颜色与 alpha。
  static const double _glowRimSigmaEm = 0.07;
  static const double _glowBloomSigmaEm = 0.14;
  static const double _glowHazeSigmaEm = 0.28;

  // 三层权重：不挖空后字形本体已经是满亮度，外层只需要做出可见的扩散过渡。
  // 权重和 < 1 是刻意的——层间 source-over 叠加后中心仍会接近饱和，
  // 但要避免外层叠太多把汉字笔画间隙糊平。
  static const double _glowRimWeight = 1.00;
  static const double _glowBloomWeight = 0.45;
  static const double _glowHazeWeight = 0.20;

  /// 辉光精灵外扩（px）：以最外层半径的 3σ 为准，保证光晕不被裁切。
  static double _glowSpritePad(double fontSize) =>
      _glowHazeSigmaEm * fontSize * 3;

  // ============== 渐变遮罩状态 ==============

  /// 当前正在演唱的 word 索引（-1 表示还未开始）。
  int _currentWordIdx = -1;

  /// 当前 word 内进度（0.0-1.0）。
  double _intraWordProgress = 0.0;

  /// 行级渐变 mask 位置（相对于行首的累计已播宽度）。
  ///
  /// **行级渐变模型**：mask 边界随演唱进度从行首移动到行尾，
  /// 跨越多个 word。长字上停留久（速度慢），短字上快速掠过，
  /// 自然实现"根据字长不同改变移动速度"。
  /// -1 表示无效（非当前行），double.infinity 表示已播完。
  double _maskX = -1.0;

  /// 过渡区半宽（固定值，行内字宽的平均）。
  ///
  /// 渐变过渡区宽度 = 2 × 半宽。**必须固定、不随当前字变化**：
  /// - 若直接用当前字宽，字切换瞬间半宽突变 → 过渡区尺寸瞬变，边缘字 alpha 断崖（闪）。
  /// - 若对半宽做平滑逼近，字切换瞬间过渡区短暂取上一字宽（偏大），下一个字整个处于
  ///   过渡区（偏亮"亮一下"），随后过渡区收缩（右边缘转暗"暗下来"），再随演唱变亮——
  ///   呈现"亮-暗-亮"的闪烁。
  /// 固定为行内平均字宽：字切换时过渡区尺寸恒定，消除上述两种闪烁。
  double _transitionHalfWidth = 0;

  /// 预计算的每个 word 在行内的起始 X 坐标（相对于行首）。
  /// 在 [_ensureBound] 时一次性计算，避免每帧 O(n²) 循环累加。
  List<double> _wordStartXs = const <double>[];

  // ============== sweep（扫光）模型状态 ==============

  /// 每个 word 的行内墨迹区间（行内累计 x 坐标，已排除字间空白）。
  ///
  /// 与 [_wordWidths] / [_wordStartXs] 同一时机（[_ensureBound] 行绑定期）
  /// 用各 word 的 TextPainter `getBoxesForSelection` 求真实字形覆盖并缓存；
  /// 拿不到 / 空 box 时回退 advance 区间 `[wordStartX, wordStartX + 宽度]`。
  /// 仅 sweep 模式消费；classic 不读它，行为完全不变。
  List<LyricInkSpan> _wordInkSpans = const <LyricInkSpan>[];

  /// 行内墨迹推进路径（sweep 专用）。由 [_wordInkSpans] 构造并**缓存在行绑定**，
  /// 不是每帧重建；行 / 字号 / 字重 / 行高变化时随 [_ensureBound] 一起重建。
  LyricSweepPath? _sweepPath;

  /// sweep 前端位置（行内累计 x 坐标；供测试断言与逐字符路径消费）。
  ///
  /// classic 模式 / 非当前行 / 墨迹为空时保持 0（不参与绘制）。
  double _sweepFront = 0;

  // ============== 状态查询 ==============

  /// 当前 alpha map（不可变视图，供测试断言）。
  ///
  /// 内部用 List 存储（性能优化），此处通过 [List.asMap] 返回 Map 视图，
  /// 保持测试接口兼容。仅测试调用，非热路径。
  @visibleForTesting
  Map<int, double> get wordAlphas => _wordAlphas.asMap();

  /// 当前逐字 alpha 的平均值。
  ///
  /// 行退场（当前行 → 非当前行）时作为清晰层淡出的起点：该期间渲染器实例
  /// 从 [WordRenderer] 换成 [LineRenderer]，若不把本值交接过去，新实例的
  /// alpha 停留在 0，明亮歌词会硬切成模糊图。
  double get averageWordAlpha {
    if (_wordAlphas.isEmpty) return dynamicDarkAlpha;
    double sum = 0;
    for (final a in _wordAlphas) {
      sum += a;
    }
    return sum / _wordAlphas.length;
  }

  /// 当前行级渐变 mask 位置（供测试断言字切换时的连续性）。
  @visibleForTesting
  double get maskX => _maskX;

  /// 当前演唱字索引（供测试断言）。
  @visibleForTesting
  int get currentWordIdx => _currentWordIdx;

  /// 指定字的逐字符强调状态引用（供测试断言波浪尾巴行为）。
  @visibleForTesting
  List<EmphasizeState> debugCharStatesRef(int wordIndex) =>
      _emphasizeCharStates[wordIndex];

  /// 过渡区半宽固定值（供测试断言字切换时的稳定性）。
  @visibleForTesting
  double get transitionHalfWidth => _transitionHalfWidth;

  /// 当前行的 sweep 墨迹路径（供测试断言区间过滤/合并与前端推进）。
  @visibleForTesting
  LyricSweepPath? get sweepPathDebug => _sweepPath;

  /// 上一次 paintLine 算出的 sweep 前端位置（行内累计 x 坐标）。
  @visibleForTesting
  double get sweepFrontDebug => _sweepFront;

  /// 每个 word 的行内起始 X（供测试断言过渡区计算）。
  @visibleForTesting
  List<double> get wordStartXsRef => _wordStartXs;

  /// 每个 word 的宽度（供测试断言过渡区计算）。
  @visibleForTesting
  List<double> get wordWidthsRef => _wordWidths;

  /// 每个 word 的当前 Y 偏移（上浮量，向上为负，供测试断言）。
  @visibleForTesting
  List<double> get wordYOffsetsRef => _wordYOffsets;

  /// 是否启用了整词字形图路径（Windows + 开启上浮，供测试断言门控）。
  @visibleForTesting
  bool get glyphBlitActiveForTest => _glyphBlitActive;

  /// 已就绪的整词字形图数量（供测试断言异步生成完成）。
  @visibleForTesting
  int get glyphImageCountForTest =>
      _wordGlyphImages.where((ui.Image? img) => img != null).length;

  /// 整词字形图绘制用的采样模式（供测试锁定"不得退回最近邻"）。
  @visibleForTesting
  FilterQuality get glyphFilterQualityForTest => _wordGlyphPaint.filterQuality;

  /// 强调字字形图绘制用的采样模式（供测试锁定"不得退回最近邻"）。
  @visibleForTesting
  FilterQuality get charImageFilterQualityForTest =>
      _charImagePaint.filterQuality;

  /// 辉光精灵超采样倍数（口径同 [_wordGlyphSupersample]：逻辑像素倍数）。
  ///
  /// **为什么必须超采样**：辉光精灵按 1× 逻辑像素烘焙，绘制时被 DPR 放大
  /// （Android 典型 2.75~3.5×）。高斯光晕的连续 alpha 斜坡在 1× 下先被量化成
  /// 整数台阶，再经双线性插值放大——台阶被一起放大，肉眼就是一圈锯齿。
  /// 实测 32px「日」的光晕过渡带相邻 alpha 跳变：1× + 硬边遮罩平均 23.5、
  /// 最大 117、>32 的硬台阶 228 处；本组合（2× + 软遮罩）平均 9.1、最大 34、
  /// 硬台阶 56 处（详见
  /// `test/widgets/apple_lyrics/renderers/word_renderer_glow_alias_test.dart`）。
  ///
  /// 取 2× 而非 3×：辉光本身是低频信号（最小层 sigma 仅 0.05em），2× 已把台阶
  /// 压到双线性插值可平滑的程度；3× 的显存与烘焙耗时翻 2.25 倍换来肉眼不可辨
  /// 的提升，不划算（与字形图 3× 的取舍不同，字形是高频信号）。
  static const int _glowSpriteSupersample = 2;

  /// 辉光精灵超采样倍数（供测试断言尺寸口径）。
  @visibleForTesting
  static int get glowSupersampleForTest => _glowSpriteSupersample;

  /// 辉光精灵绘制用的采样模式（供测试锁定"不得退回最近邻"）。
  @visibleForTesting
  FilterQuality get glowImageFilterQualityForTest =>
      _glowImagePaint.filterQuality;

  /// 辉光上色结果（供测试锁定"辉光颜色跟随动态混色比例"）。
  @visibleForTesting
  ColorFilter debugGlowTintForTest(int r, int g, int b, double alpha) =>
      _glowTint(r, g, b, alpha);

  /// 辉光层实际绘制 alpha（供测试锁定"强度倍数只调亮度、不改光形"）。
  @visibleForTesting
  ({double base, double extra}) debugGlowDrawAlphaForTest(double glowLevel) =>
      _glowDrawAlpha(glowLevel);

  /// 辉光精灵外扩量（px，供测试断言与绘制侧同口径）。
  @visibleForTesting
  double debugGlowSpritePadForTest(double fontSize) => _glowSpritePad(fontSize);

  /// 辉光剖面（sigma em，由内到外；供测试锁定"最内层必须足够紧"）。
  @visibleForTesting
  static List<double> get glowSigmaProfileEmForTest => const <double>[
    _glowRimSigmaEm,
    _glowBloomSigmaEm,
    _glowHazeSigmaEm,
  ];

  /// 辉光剖面权重（与 [glowSigmaProfileEmForTest] 同序；逐层 source-over 叠加）。
  @visibleForTesting
  static List<double> get glowWeightProfileForTest => const <double>[
    _glowRimWeight,
    _glowBloomWeight,
    _glowHazeWeight,
  ];

  /// 已烘焙的辉光精灵图（供测试断言"换颜色不重烘焙"）。
  @visibleForTesting
  ui.Image? debugGlowSpriteForTest(int wordIndex, int charIndex) {
    if (wordIndex < 0 || wordIndex >= _charGlowSprites.length) return null;
    final List<ui.Image?> chars = _charGlowSprites[wordIndex];
    if (charIndex < 0 || charIndex >= chars.length) return null;
    return chars[charIndex];
  }

  /// 直接烘焙一张辉光精灵（供测试断言尺寸口径与三层剖面可渲染）。
  @visibleForTesting
  Future<ui.Image?> debugRenderGlowSpriteForTest({
    required String text,
    required double fontSize,
    required double rowHeight,
  }) => _renderGlowSpriteImage(
    text,
    fontSize,
    _glowSpritePad(fontSize),
    rowHeight,
  );

  /// 转发 [alphaAtX] 供测试断言绘制 alpha 的连续性。
  @visibleForTesting
  double debugAlphaAtX(
    double x,
    double start,
    double span,
    double bright,
    double dark,
  ) => _alphaAtX(x, start, span, bright, dark);

  /// 当前 scale 对应的 factor（0~1）。
  ///
  /// 公式：`factor = clamp01((scale - inactiveScale) / (activeScale - inactiveScale))`
  double get factor {
    final raw =
        (_scale - LyricLayout.inactiveScale) /
        (LyricLayout.activeScale - LyricLayout.inactiveScale);
    return raw.clamp(0.0, 1.0).toDouble();
  }

  /// 动态暗态 alpha（未播字 / 非当前行 SOLID）。
  ///
  /// 公式：`dynamicDarkAlpha = factor * 0.2 + 0.2`，范围 0.2~0.4。
  double get dynamicDarkAlpha => factor * 0.2 + 0.2;

  /// 动态亮态 alpha（已播字 / 当前字目标）。
  ///
  /// 公式：`dynamicBrightAlpha = factor * 0.8 + 0.2`，范围 0.2~1.0。
  double get dynamicBrightAlpha => factor * 0.8 + 0.2;

  /// 当前是否为当前行。
  bool get isActive => _isActive;

  /// v3 优化：renderer 是否已收敛（alpha 和 Y offset 都不再变化）。
  /// 用于 AppleLyricsView 判断是否可以停止 Ticker。
  bool get isConverged => _isConverged;

  // ============== 状态设置 ==============

  /// 设置当前行状态。
  ///
  /// [isActive] 为 true 时启用 GRADIENT 模式（已播亮 / 未播暗），
  /// 为 false 时启用 SOLID 模式（整行均匀暗）。
  /// [scale] 是行缩放，0.850（inactive）~1.0（active）。
  /// [blurFade] 控制非当前行透明度：1.0=透明（模糊图片覆盖），0.0=正常显示。
  /// [blurActive] 是否启用高斯模糊：false 时不降低非当前行透明度。
  void setLineState({
    required bool isActive,
    required double scale,
    double blurFade = 1.0,
    bool blurActive = true,
    int? activeColorValue,
  }) {
    _isActive = isActive;
    _scale = scale;
    _activeColorValue = activeColorValue;
  }

  /// 设置强调辉光效果计算器。
  set emphasizeEffect(EmphasizeEffect? effect) => _emphasizeEffect = effect;

  /// 辉光触发阈值（ms）：500=快歌，1000=慢歌。
  ///
  /// 由歌曲 BPM / KRC 歌词字长推断（见 EmphasizeEffect.resolveThresholdMs），
  /// 切歌时由 AppleLyricsView 设置；_ensureBound 行绑定时据此判定强调字。
  int thresholdMs = 500;

  /// 翻译副行展开进度（0→1 副行"长出"）。由 AppleLyricsView 注入（当前行）。
  ///
  /// 仅当前行预留副行高度，本进度控制当前行副行的视觉浮出：
  /// progress=0 时副行贴主行底（隐藏位），progress=1 时到正常副行位置。
  double translationExpand = 0.0;

  /// 翻译副行显隐 alpha 进度（0→1 渐显，1→0 渐隐）。由 AppleLyricsView 注入。
  ///
  /// 当前实现与 [translationExpand] 同值注入（alpha 与位置同进度，
  /// 淡入淡出贯穿整个过渡时长，速率随行时长自适应）。
  double translationFade = 0.0;

  /// 副行是否处于**出场**阶段。由 AppleLyricsView 注入（与 LineRenderer 同义）。
  ///
  /// - false（当前行 / 入场）：绕副行底边，从下翻转出现；
  /// - true（收起中的退场行 / 出场）：绕副行顶边，向上翻转消失。
  ///
  /// WordRenderer 只负责当前行，生产路径恒为 false；字段保留是为了与
  /// LineRenderer 共用 [LyricLayout] 的翻转几何、跨渲染器切换时行为一致。
  bool translationExiting = false;

  // ============== 动画推进 ==============

  /// 推进动画。
  ///
  /// [dt] 距上一帧的时间间隔（秒）。[currentTimeMs] 当前播放位置（毫秒），
  /// 用于根据每个 word 的 [LyricWord.startTime] / [LyricWord.duration]
  /// 精确判断当前正在演唱的 word 及 word 内进度。
  /// 用指数衰减公式 `alpha += (target - alpha) * (1 - exp(-speed * dt))`
  /// 平滑过渡：变亮用 [LyricLayout.attackSpeed]（50.0），变暗用 [LyricLayout.releaseSpeed]（7.0）。
  /// 差值小于 [LyricLayout.alphaEpsilon]（0.001）时吸附到目标。
  ///
  /// **性能优化（上浮动画功耗优化）**：
  /// - 预计算 decay：dt 对所有 word 相同，speed 只有 attack/release 两值，
  ///   每帧只调 4 次 exp() 而非最多 2N 次（N=word 数）
  /// - 非激活行快速路径：跳过 currentWordIdx 计算、smoothstep、per-word target 分支，
  ///   所有 word 统一 target=dark / Y=0 / emphasis=idle
  /// - early-exit 已收敛字：90% 的字已收敛，跳过乘法运算
  void tick(double dt, int currentTimeMs, {bool isPlaying = true}) {
    if (dt <= 0) return;
    if (_boundLine == null || _boundLine!.words.isEmpty) return;

    final double dark = dynamicDarkAlpha;
    final double bright = dynamicBrightAlpha;
    final words = _boundLine!.words;
    final int wordCount = words.length;

    // === 预计算 decay 值（核心优化：每帧只调 4 次 exp()）===
    // 之前每 word 最多调 2 次 exp()（alpha + Y offset），10 word 行 = 20 次/帧
    // 现在固定 4 次/帧，与 word 数无关
    final double alphaAttackDecay = 1.0 - exp(-LyricLayout.attackSpeed * dt);
    final double alphaReleaseDecay = 1.0 - exp(-LyricLayout.releaseSpeed * dt);
    final double liftAttackDecay = 1.0 - exp(-_liftAttackSpeed * dt);
    final double liftReleaseDecay = 1.0 - exp(-_liftReleaseSpeed * dt);

    // 已播字上浮幅度：每帧读一次偏好（见 [_maxLiftPx] 的说明）
    final double maxLiftPx = _maxLiftPx;

    // === 非当前行快速路径 ===
    // 非当前行：所有 word alpha 目标 = dark，Y offset 目标 = 0，emphasis = idle
    // 跳过 currentWordIdx 查找、smoothstep、per-word target 分支判断
    if (!_isActive) {
      bool anyChanged = false;
      for (int i = 0; i < wordCount; i++) {
        // Alpha → dark（使用方向判断选 decay，兼容 dark 值随 scale 变化的情况）
        final double current = _wordAlphas[i];
        if ((current - dark).abs() >= LyricLayout.alphaEpsilon) {
          final double decay = dark >= current
              ? alphaAttackDecay
              : alphaReleaseDecay;
          double next = current + (dark - current) * decay;
          if ((next - dark).abs() < LyricLayout.alphaEpsilon) next = dark;
          _wordAlphas[i] = next;
          anyChanged = true;
        }
        // Y offset → 0（非当前行不上浮）
        final double currentY = _wordYOffsets[i];
        if (currentY.abs() >= 0.01) {
          final double yDecay = 0 >= currentY
              ? liftAttackDecay
              : liftReleaseDecay;
          double nextY = currentY + (0 - currentY) * yDecay;
          if (nextY.abs() < 0.01) nextY = 0;
          _wordYOffsets[i] = nextY;
          anyChanged = true;
        }
        // Emphasis: 非当前行一律 idle（逐字符）；自驱动波浪一并复位
        if (_waveAnchorPosMs.isNotEmpty) _waveAnchorPosMs[i] = -1;
        final List<EmphasizeState> charStates = _emphasizeCharStates[i];
        for (int k = 0; k < charStates.length; k++) {
          charStates[k] = EmphasizeState.idle;
        }
      }
      _isConverged = !anyChanged;
      _currentWordIdx = -1;
      _intraWordProgress = 0.0;
      _maskX = -1.0;
      return;
    }

    // === 当前行：完整 per-word 处理 ===
    // 找到当前正在演唱的 word 索引及 word 内进度
    int currentWordIdx = -1;
    double intraWordProgress = 0.0;

    for (int i = 0; i < wordCount; i++) {
      final w = words[i];
      if (currentTimeMs >= w.startTime &&
          currentTimeMs < w.startTime + w.duration) {
        currentWordIdx = i;
        intraWordProgress = w.duration > 0
            ? ((currentTimeMs - w.startTime) / w.duration).clamp(0.0, 1.0)
            : 0.0;
        break;
      } else if (currentTimeMs >= w.startTime + w.duration &&
          (i == wordCount - 1 || currentTimeMs < words[i + 1].startTime)) {
        // 当前 word 已结束，下一个 word 还没开始 → 保持当前 word 为"已播"
        currentWordIdx = i;
        intraWordProgress = 1.0;
      }
    }

    // 如果 currentTimeMs 在所有 word 之前，第一个 word 为当前
    if (currentWordIdx == -1 &&
        wordCount > 0 &&
        currentTimeMs < words[0].startTime) {
      currentWordIdx = 0;
      intraWordProgress = 0.0;
    }

    // 记录当前演唱状态，供 paintLine 中行级渐变使用
    _currentWordIdx = currentWordIdx;
    _intraWordProgress = intraWordProgress;

    // === 计算行级 mask 位置（核心：行级渐变模型）===
    // maskX = 已播字总宽度 + 当前字内进度 × 当前字宽
    // 渐变边界随演唱进度从行首移动到行尾，跨越多个 word。
    // 长字上停留久（速度慢），短字上快速掠过。
    //
    // 注意：_wordStartXs 是累计宽度，字切换时 wordStartXs[i+1] == wordEndXs[i]，
    // 故 maskX 天然连续，无需额外平滑。
    if (currentWordIdx < 0) {
      _maskX = -1.0; // 无效，全 dark
    } else if (currentWordIdx >= wordCount) {
      _maskX = double.infinity; // 已播完，全 bright
    } else {
      _maskX =
          _wordStartXs[currentWordIdx] +
          _wordWidths[currentWordIdx] * _intraWordProgress;
    }

    // 行级辉光判定（循环外计算一次）：
    // _isMetadataLine 在 _ensureBound 时缓存（行切换时才更新）；
    // _isActive / useGlowEffect / _emphasizeEffect 运行时可变，每帧检查。
    final bool skipLineEmphasis =
        _emphasizeEffect == null ||
        !LyricPreferences.instance.useGlowEffect ||
        _isMetadataLine;

    bool anyChanged = false;
    // 性能优化：内联 target 计算 + early-exit 已收敛字 + 预计算 decay
    // 90% 的字在任意时刻已收敛到目标值，跳过乘法运算可大幅降低 CPU 开销
    for (int i = 0; i < wordCount; i++) {
      // P1 时序拆分：图片懒预生成——强调字临近开始（提前 _imagePrewarmLeadMs）
      // 才请求字形图与辉光精灵。toImage 为异步，提前 250ms 触发足够在字激活前
      // 就绪；把行切换瞬间的一次性 N 个并发 toImage 摊到各字激活前逐字生成，
      // 消除行切换时刻 raster/GPU 突发造成的掉帧。
      if (_wordEmphasisFlags[i]) {
        final LyricWord w = words[i];
        if (currentTimeMs >= w.startTime - _imagePrewarmLeadMs &&
            currentTimeMs < w.startTime + w.duration) {
          final List<int> runes = w.text.runes.toList();
          for (int k = 0; k < runes.length; k++) {
            final String charText = String.fromCharCode(runes[k]);
            _requestCharImage(i, k, charText, _boundFontSize);
            // 预热阶段尚未布局，默认按整行行盒渲染；
            // 若该字实际位于换行行（0.8x 行盒），绘制时会检测行盒变化并重渲染。
            // rebuildOnMismatch: false —— 预热不干预已建立的正确精灵/进行中的
            // 渲染任务，避免每帧预热与换行行绘制反复释放重建导致光晕闪烁。
            _requestCharGlowSprite(
              i,
              k,
              charText,
              _boundFontSize,
              LyricLayout.lineHeight,
              rebuildOnMismatch: false,
            );
          }
        }
      }
      // === Alpha 动画 ===
      final double target;
      if (i < currentWordIdx) {
        target = bright;
      } else if (i > currentWordIdx) {
        target = dark;
      } else {
        target = dark + (bright - dark) * intraWordProgress;
      }

      final double current = _wordAlphas[i];
      if ((current - target).abs() < LyricLayout.alphaEpsilon) {
        // 已收敛：直接吸附到目标，跳过乘法
        if (current != target) _wordAlphas[i] = target;
      } else {
        // 使用预计算的 decay，避免每 word 调 exp()
        final double decay = target >= current
            ? alphaAttackDecay
            : alphaReleaseDecay;
        double next = current + (target - current) * decay;
        if ((next - target).abs() < LyricLayout.alphaEpsilon) {
          next = target;
        }
        _wordAlphas[i] = next;
        anyChanged = true;
      }

      // === Y 偏移动画（上浮特效）===
      final double targetY;
      if (i < currentWordIdx) {
        targetY = maxLiftPx;
      } else if (i == currentWordIdx) {
        // smoothstep 缓动（仅 3 次乘法 + 1 次加法，开销极低）
        final double eased =
            intraWordProgress * intraWordProgress * (3 - 2 * intraWordProgress);
        targetY = maxLiftPx * eased;
      } else {
        targetY = 0;
      }

      final double currentY = _wordYOffsets[i];
      // Y offset 用 0.01px epsilon（3px 范围，0.3% 不可见）
      if ((currentY - targetY).abs() < 0.01) {
        // 已收敛：直接吸附到目标，跳过乘法
        if (currentY != targetY) _wordYOffsets[i] = targetY;
      } else {
        // 使用预计算的 decay，避免每 word 调 exp()
        final double yDecay = targetY >= currentY
            ? liftAttackDecay
            : liftReleaseDecay;
        double nextY = currentY + (targetY - currentY) * yDecay;
        if ((nextY - targetY).abs() < 0.01) {
          nextY = targetY;
        }
        _wordYOffsets[i] = nextY;
        anyChanged = true;
      }

      // === 强调辉光效果（v6 自驱动逐字符波浪） ===
      // 相位由帧时钟 dt 每帧推进，脱离播放位置流，天然平滑且不依赖视图重绘门控：
      // 波浪进行中标记 anyChanged（isConverged=false）→ 重绘持续；完成即收敛，
      // Ticker 可正常停止（性能零空闲开销）。字切换 / seek 跳变时用绝对时间
      // [EmphasizeEffect.phasesAt] 锚定一次初始相位，保持与音频对齐。
      // 字级判定（含正则匹配）在 _ensureBound 时已缓存，此处仅 O(1) 数组读取。
      //
      // **v8：波浪按字独立锚定/推进**。当前字唱完（isCurrentWord 转移到下一字）
      // 后，其错位启动的后续字符波浪可能还没走完——此处继续推进（"尾巴"）直到
      // 所有字符相位完成再消失，避免字尾整词被截断造成回落跳变。
      final bool isCurrentWord = i == currentWordIdx;
      final List<EmphasizeState> charStates = _emphasizeCharStates[i];
      if (charStates.isNotEmpty) {
        final LyricWord w = words[i];
        final int anchorCharCount = w.text.runes.length;
        final double du = EmphasizeEffect.duMs(w);
        // 当前字：锚定 / 重锚（字进入当前、或 seek 前后跳变）
        if (!skipLineEmphasis && isCurrentWord) {
          final bool wasAnchored = _waveAnchorPosMs[i] >= 0;
          final bool needReanchor =
              !wasAnchored ||
              (currentTimeMs - (_waveAnchorPosMs[i] + _waveAdvanceMs[i]))
                      .abs() >
                  _waveReanchorToleranceMs;
          if (needReanchor) {
            _waveAnchorPosMs[i] = currentTimeMs.toDouble();
            _waveAdvanceMs[i] = 0;
            for (int k = 0; k < charStates.length; k++) {
              final EmphasizePhases phases = EmphasizeEffect.phasesAt(
                word: w,
                currentTimeMs: currentTimeMs,
                wordIndex: k,
                anchorCharCount: anchorCharCount,
              );
              _waveBumpPhases[i][k] = phases.bumpPhase;
              _waveFloatPhases[i][k] = phases.floatPhase;
            }
          }
        }
        final bool anchored = _waveAnchorPosMs[i] >= 0;
        if (anchored) {
          // 推进相位（当前字与已播完的尾巴都推进）。
          // **暂停时冻结**：相位与 _waveAdvanceMs 都不推进、也不标记动画 → 波浪
          // 静止并收敛停 Ticker，避免暂停后辉光仍在持续涨落造成边缘闪烁。
          if (isPlaying) {
            _waveAdvanceMs[i] += dt * 1000;
            final double bumpStep = dt * 1000 / du;
            final double floatStep =
                dt * 1000 / (du * EmphasizeEffect.floatDurationFactor);
            for (int k = 0; k < charStates.length; k++) {
              _waveBumpPhases[i][k] = min(
                1.0,
                _waveBumpPhases[i][k] + bumpStep,
              );
              _waveFloatPhases[i][k] = min(
                1.0,
                _waveFloatPhases[i][k] + floatStep,
              );
            }
          }
          // 由（推进后 / 冻结的）相位计算状态；波浪进行中标记动画保证重绘
          bool waveAnimating = false;
          for (int k = 0; k < charStates.length; k++) {
            if (_waveBumpPhases[i][k] < 1.0 || _waveFloatPhases[i][k] < 1.0) {
              waveAnimating = true;
            }
            final EmphasizeState next = _emphasizeEffect!
                .computeStateFromPhases(
                  word: w,
                  bumpPhase: _waveBumpPhases[i][k],
                  floatPhase: _waveFloatPhases[i][k],
                  isLastWord: i == wordCount - 1,
                  wordIndex: k,
                  anchorCharCount: anchorCharCount,
                );
            if (next != charStates[k]) anyChanged = true;
            charStates[k] = next;
          }
          // 尾巴走完后的复位：仅【非当前字】的尾巴走完才复位锚定标记；
          // 当前字即使波浪走完也保持锚定，避免字还在唱时被误判重锚导致波浪重播。
          if (!waveAnimating && !isCurrentWord) {
            _waveAnchorPosMs[i] = -1;
          }
          // 波浪进行中必须持续重绘（防止被视图"无视觉变化"门控冻结）；暂停时不标记，
          // 让画面静止、Ticker 正常停止。
          if (isPlaying && waveAnimating) anyChanged = true;
        } else {
          // 未锚定（从未进入当前字 / 波浪已走完）：整词 idle，走整词渲染路径
          for (int k = 0; k < charStates.length; k++) {
            if (charStates[k] != EmphasizeState.idle) anyChanged = true;
            charStates[k] = EmphasizeState.idle;
          }
        }
      }
    }
    // v3 优化：跟踪 alpha/Y offset 是否仍在变化（用于 AppleLyricsView 判断停止 Ticker）
    _isConverged = !anyChanged;
  }

  // ============== 绘制 ==============

  /// 绘制单行歌词。
  ///
  /// [offset] 是行起始绘制原点。文字颜色固定白色 #FFFFFFFF，
  /// 通过逐字 alpha 区分已播 / 未播。
  ///
  /// [maxWidth] 为该行可用最大文字宽度（视口宽 - 左右 1em 边距）。
  /// 断点由换行计划给出（[wrapPlan] 注入，缺省时现场取同一份计划）：走到计划标记的
  /// 行起点才换行，dx 归零，currentY += mainLineHeight × wrapLineHeightFactor（0.8x 行高）。
  ///
  /// **性能优化**：
  /// - word 宽度用 [_wordWidths] 缓存（[_ensureBound] 时一次性测量），
  ///   换行断点由 [LyricWrapPlanner] 的结果缓存提供，两者都不再每帧 layout
  /// - **v4 优化**：per-word TextPainter 实例 + alpha 缓存。
  ///   仅在 alpha 变化时才 set text + layout，alpha 不变时直接 paint。
  ///   这与 v3 Task 1 共享 painter 不同：每个 word 独占一个 TextPainter 实例，
  ///   不会出现"下一个 word 覆盖 painter.text 导致 _lastSetAlphas[i] 错乱"的 bug。
  void paintLine(
    Canvas canvas,
    Offset offset,
    LyricLine line,
    double fontSize, {
    double maxWidth = double.infinity,
    DuetAlignment alignment = DuetAlignment.defaultAlign,
    double viewportWidth = 0,
    LyricWrapPlan? wrapPlan,
    LyricWrapPlan? auxPlan,
  }) {
    // 断点唯一来源：外部（AppleLyricsView 的行高重算处）注入的计划；
    // 未注入时现场取同一份计划兜底。本方法内**禁止**再自行判断换行条件，
    // 否则测量与绘制会岔开（历史重叠 bug 的根因）。
    final bool balanced = LyricPreferences.instance.lineBalance;
    final LyricWrapPlan plan =
        wrapPlan ??
        LyricWrapPlanner.forLine(
          line,
          LyricLayout.mainStyle(fontSize),
          maxWidth,
          balanced: balanced,
        );
    // 临时调试：行切换时打印换行分析（定位歌词重叠）
    final bool isNewLine =
        !identical(_boundLine, line) || _boundFontSize != fontSize;
    _ensureBound(line, fontSize);
    if (isNewLine) {
      _debugLogWrap(line, fontSize, maxWidth, plan);
    }

    // 解析当前行实际文字颜色：动态字体颜色（仅当前行）优先，否则回退主题默认色。
    // 颜色变化时清空 alpha 缓存强制重建所有 word TextSpan。
    final int textColorValue = (_isActive && _activeColorValue != null)
        ? _activeColorValue!
        : LyricLayout.textColorValue;
    if (textColorValue != _lastTextColorValue) {
      // 哨兵 -2 = 未初始化：与渐变路径的白色缓存（-1）和 uniform 的
      // alphaStep（0~20）都不同，保证首次绘制必定重新 set text + layout。
      _lastSetAlphas = List<int>.filled(_lastSetAlphas.length, -2);
      // v5：逐字符 alpha 缓存一并失效
      for (int i = 0; i < _lastSetCharAlphas.length; i++) {
        _lastSetCharAlphas[i] = List<int>.filled(
          _lastSetCharAlphas[i].length,
          -2,
        );
      }
      _lastTextColorValue = textColorValue;
      // 辉光精灵**不再**随颜色失效：精灵是「纯白字形 + 固定三层剖面」，
      // 颜色由绘制期 [_glowTint] 逐帧上色。拖动「动态颜色混色比例」时
      // textColorValue 每帧都变，若在此重建精灵会每帧 toImage（真机必掉帧）。
    }
    final int textRed = (textColorValue >> 16) & 0xFF;
    final int textGreen = (textColorValue >> 8) & 0xFF;
    final int textBlue = textColorValue & 0xFF;

    if (line.words.isEmpty) {
      _paintSolidFallback(
        canvas,
        offset,
        line,
        fontSize,
        maxWidth: maxWidth,
        alignment: alignment,
        viewportWidth: viewportWidth,
        plan: plan,
      );
      return;
    }

    // 每视觉行的宽度来自计划（供换行后重算 baseX 对齐）
    final List<double> visualLineWidths = plan.rowWidths;
    int visualLineIndex = 0;
    // 下一个「行起点」的 word 下标；超出即本行到行尾
    final int firstNextRowStart = plan.rowCount > 1
        ? plan.rowStarts[1]
        : line.words.length;
    int nextRowStart = firstNextRowStart;
    double baseX = _alignX(
      alignment,
      offset.dx,
      visualLineWidths.isNotEmpty ? visualLineWidths[0] : 0,
      viewportWidth,
    );

    double dx = 0; // 相对 baseX 的水平偏移
    double currentY = offset.dy; // 当前视觉行的 y 坐标
    final double dark = dynamicDarkAlpha;
    final double bright = dynamicBrightAlpha;
    // 主行行高 = 主行高（完整行盒）；换行行盒模型与 measureLineHeight 一致：
    // 主行完整行高，换行行 0.8x 行高、从主行底开始，行盒=行距避免相邻行重叠。
    final double mainLineHeight = fontSize * LyricLayout.lineHeight;
    // 换行内部行高 = 主行高 × 0.8（与 LyricLayout.measureLineHeight 一致）
    final double wrapLineHeight =
        mainLineHeight * LyricLayout.wrapLineHeightFactor;
    final double lineHeight = LyricLayout.lineHeight;

    // === 行级渐变参数（核心：行级 maskX 模型）===
    // 过渡区以 _maskX 为中心，宽度 = 2 × 当前字宽，让渐变跨越 2-3 个 word。
    // 长字过渡区宽，渐变在字上移动慢；短字过渡区窄，移动快。
    // _maskX < 0 表示非当前行或未开始，全 dark。
    final bool useGradient =
        _isActive &&
        _boundLine != null &&
        _boundLine!.words.length == line.words.length &&
        _maskX >= 0;
    final double transitionHalfWidth =
        useGradient &&
            _currentWordIdx >= 0 &&
            _currentWordIdx < _wordWidths.length
        ? _transitionHalfWidth
        : 0.0;
    final double transitionStart = _maskX - transitionHalfWidth;
    final double transitionEnd = _maskX + transitionHalfWidth;
    final double transitionSpan = transitionEnd - transitionStart;

    // === sweep（扫光）模型参数（classic 不读这些字段，行为完全不变）===
    // 前端按「墨迹长度」推进：相位 = (已过字墨迹长 + 当前字内进度 × 当前字墨迹长)
    // ÷ 总墨迹长；再由 LyricSweepPath 把相位映射成行内 x（字间空白瞬时跨越）。
    // 行级羽化只用于把前端行程域外扩 feather/2（保证扫光带在行首尾完整进出）。
    final bool sweepMode =
        useGradient &&
        LyricPreferences.instance.fillMode == LyricFillMode.sweep &&
        _sweepPath != null &&
        !_sweepPath!.isEmpty;
    final double sweepLineFeather = sweepMode
        ? _sweepFeatherForWord(_currentWordIdx, fontSize, lineHeight)
        : 0;
    _sweepFront = sweepMode
        ? _sweepPath!.frontX(_sweepPhase(), feather: sweepLineFeather)
        : 0;

    for (int i = 0; i < line.words.length; i++) {
      final LyricWord word = line.words[i];
      // AMLL 上浮特效：当前字 Y 偏移（上浮）
      final double yOffset = i < _wordYOffsets.length ? _wordYOffsets[i] : 0;
      // 用缓存宽度推进 dx 并给渐变/矩形定位（换行断点由计划给出，不再用宽度判断）
      final double width = i < _wordWidths.length ? _wordWidths[i] : 0;
      // 走到计划标记的行起点才换行（断点由 LyricWrapPlanner 决定）
      if (i == nextRowStart) {
        dx = 0;
        // 第一个换行行从主行底部（offset.dy + mainLineHeight）开始，
        // 后续换行行之间 0.8x 行高（与 lineHeightForRows 一致，避免行盒重叠）
        currentY = visualLineIndex == 0
            ? offset.dy + mainLineHeight
            : currentY + wrapLineHeight;
        visualLineIndex++;
        if (visualLineIndex < visualLineWidths.length) {
          baseX = _alignX(
            alignment,
            offset.dx,
            visualLineWidths[visualLineIndex],
            viewportWidth,
          );
        }
        nextRowStart = visualLineIndex + 1 < plan.rowStarts.length
            ? plan.rowStarts[visualLineIndex + 1]
            : line.words.length;
      }

      // 换行行用 0.8x 行盒（行盒=行距，避免行盒重叠）；主行用完整行高
      final double rowHeight = visualLineIndex > 0
          ? LyricLayout.lineHeight * LyricLayout.wrapLineHeightFactor
          : LyricLayout.lineHeight;

      final double wordX = baseX + dx;
      final double wordY = currentY + yOffset;

      // Windows：按需渲染整词字形图（图未就绪时下方绘制自动退回文本路径）
      _requestWordGlyph(i, rowHeight);

      // === 逐字符 vs 整词渲染分支 ===
      // v5 波浪化：强调字（_charPainters 非空）且【处于激活窗口】（任一字符非 idle）
      // 才逐字符渲染（逐字符 scale/位移/辉光）；idle 时走整词渲染，避免逐字符
      // layout/渐变 shader 每帧开销导致位移与缩放卡顿。
      final List<TextPainter> charPainters = i < _charPainters.length
          ? _charPainters[i]
          : const <TextPainter>[];
      final bool charModeActive =
          charPainters.isNotEmpty && _hasActiveEmphasis(i);
      if (charModeActive) {
        _paintEmphasizedWord(
          canvas,
          wordX: wordX,
          wordY: wordY,
          fontSize: fontSize,
          lineHeight: lineHeight,
          rowHeight: rowHeight,
          wordIndex: i,
          textRed: textRed,
          textGreen: textGreen,
          textBlue: textBlue,
          bright: bright,
          dark: dark,
          transitionStart: transitionStart,
          transitionSpan: transitionSpan,
          useGradient: useGradient,
          sweepMode: sweepMode,
          sweepFront: _sweepFront,
          sweepFeather: _sweepFeatherForWord(i, fontSize, rowHeight),
        );
      } else if (sweepMode) {
        // === sweep（扫光）整词路径（新增；classic 分支不受影响）===
        // 前端换算到 canvas 坐标：行内累计坐标 - 该词的行内起点 + wordX
        // （即加上 wordX - wordStartX，抵消对齐 baseX 与换行行的行起点偏移）。
        final double sweepRowOffset =
            wordX - (i < _wordStartXs.length ? _wordStartXs[i] : 0);
        _paintSweepWord(
          canvas,
          painter: _wordPainters[i]!,
          wordIndex: i,
          wordX: wordX,
          wordY: wordY,
          width: width,
          rowHeight: rowHeight,
          fontSize: fontSize,
          front: _sweepFront + sweepRowOffset,
          feather: _sweepFeatherForWord(i, fontSize, rowHeight),
          textRed: textRed,
          textGreen: textGreen,
          textBlue: textBlue,
          bright: bright,
          dark: dark,
          uniformAlpha: i < _wordAlphas.length ? _wordAlphas[i] : dark,
        );
      } else {
        // === 非强调字：整词渲染（原 alpha 路径）===
        // 行级 maskX 模型：基于 word 在行内的累计 X 坐标计算边缘 alpha。
        // 已播区（maskX 左侧远端）= bright，未播区（maskX 右侧远端）= dark，
        // 过渡区内线性插值，实现跨字平滑渐变。
        final double leftAlpha;
        final double rightAlpha;
        if (!useGradient) {
          leftAlpha = rightAlpha = i < _wordAlphas.length
              ? _wordAlphas[i]
              : dark;
        } else {
          final double wordStartX = i < _wordStartXs.length
              ? _wordStartXs[i]
              : 0;
          final double wordEndX = wordStartX + width;
          leftAlpha = _alphaAtX(
            wordStartX,
            transitionStart,
            transitionSpan,
            bright,
            dark,
          );
          rightAlpha = _alphaAtX(
            wordEndX,
            transitionStart,
            transitionSpan,
            bright,
            dark,
          );
        }

        final TextPainter painter = _wordPainters[i]!;

        // === 渲染文字 ===
        // 性能优化（核心）：左右 alpha 几乎一致时用均匀绘制（量化缓存，跳过 layout）。
        // 过渡区内的 word 走渐变路径，用 saveLayer + BlendMode.modulate 应用渐变。
        //
        // **layout 复用原理**：
        // - 渐变路径保持 painter.text 为 plain white（color=white, alpha=1.0）
        // - TextSpan.== 比较时 plain white 的 color/fontSize/fontFamily 不变 → 不触发 relayout
        // - 渐变通过 saveLayer + drawRect(modulate) 事后应用，不影响 layout
        // - 稳态下 0 次 layout/帧（仅路径切换时 1 次 layout）
        //
        // **BlendMode.modulate 公式**：result = src × dst（逐分量含 alpha）
        // - dst = 白色文字（color=white, alpha=文字形状）
        // - src = 渐变（color=white, alpha=leftAlpha→rightAlpha）
        // - result.color = white × white = white
        // - result.alpha = 渐变alpha × 文字形状 ✓
        final bool isUniform = (leftAlpha - rightAlpha).abs() < 0.01;
        if (isUniform) {
          // === 均匀路径 ===
          final double uniformAlpha = (leftAlpha + rightAlpha) * 0.5;
          final int alphaStep = (uniformAlpha * 20).round();
          if (_lastSetAlphas[i] != alphaStep) {
            // 量化值变化或从渐变路径切换过来：重新 set text + layout
            painter.text = TextSpan(
              text: word.text,
              style: TextStyle(
                color: Color.fromRGBO(
                  textRed,
                  textGreen,
                  textBlue,
                  uniformAlpha,
                ),
                fontSize: fontSize,
                height: rowHeight,
                fontFamily: LyricLayout.fontFamily,
                fontWeight: LyricLayout.fontWeight,
              ),
            );
            painter.layout();
            _lastSetAlphas[i] = alphaStep;
          }
          _wordGlyphPaint.colorFilter = _wordGlyphTint(
            textRed,
            textGreen,
            textBlue,
            uniformAlpha,
          );
          if (!_blitWordGlyph(
            canvas,
            i,
            wordX,
            wordY,
            width,
            fontSize,
            rowHeight,
          )) {
            painter.paint(canvas, Offset(wordX, wordY));
          }
        } else {
          // === 渐变路径（saveLayer + modulate，复用 layout）===
          // 确保 painter 处于 plain white 状态（只在切换时 set text + layout）
          if (_lastSetAlphas[i] != -1) {
            painter.text = TextSpan(
              text: word.text,
              style: TextStyle(
                color: const Color.fromRGBO(255, 255, 255, 1.0), // plain white
                fontSize: fontSize,
                height: rowHeight,
                fontFamily: LyricLayout.fontFamily,
                fontWeight: LyricLayout.fontWeight,
              ),
            );
            painter.layout();
            _lastSetAlphas[i] = -1; // 标记 plain white 已缓存
          }
          final Rect wordRect = Rect.fromLTWH(
            wordX,
            wordY,
            width,
            fontSize * rowHeight,
          );
          canvas.saveLayer(wordRect, Paint());
          _wordGlyphPaint.colorFilter = null; // 纯白字形，渐变由 modulate 着色
          if (!_blitWordGlyph(
            canvas,
            i,
            wordX,
            wordY,
            width,
            fontSize,
            rowHeight,
          )) {
            painter.paint(
              canvas,
              Offset(wordX, wordY),
            ); // dst = 白色文字（layout 已缓存，不重算）
          }
          // 复用 _gradientPaint 实例，只改 shader 和 blendMode。
          // 注意：不要对渐变 alpha 做量化缓存（曾引入 5% 可见阶跃闪烁 + 频繁清空重建反而卡顿）。
          _gradientPaint.shader = LinearGradient(
            colors: [
              Color.fromRGBO(textRed, textGreen, textBlue, leftAlpha),
              Color.fromRGBO(textRed, textGreen, textBlue, rightAlpha),
            ],
            stops: const <double>[0.0, 1.0],
          ).createShader(wordRect);
          _gradientPaint.blendMode = BlendMode.modulate;
          canvas.drawRect(wordRect, _gradientPaint); // src = 渐变
          canvas.restore();
        }
      }

      dx += width;
    }

    // 辅助副行（翻译或罗马音）：WordRenderer 仅在当前行（KRC）被调用，故无需再判 _isActive。
    // 根据 displayMode 选择显示 translation 还是 roma。
    // 副行字号为主行 70%；alpha = translationOpacity × translationFade（渐显渐隐），
    // 位置随 translationExpand 从主行底平滑浮出（占位高度由动画进度动态叠加）。
    // **不读 showTranslation 做立即短路**：关闭翻译时注入进度衰减到 0、
    // alpha 平滑渐隐至消失——若在此短路，关闭瞬间副行直接消失无动画。
    final auxText =
        LyricPreferences.instance.displayMode == LyricDisplayMode.roma
        ? line.roma
        : line.translation;
    final double transAlpha = LyricLayout.translationOpacity * translationFade;
    if (transAlpha > 0.001 && auxText != null && auxText.isNotEmpty) {
      final transFontSize = LyricLayout.translationFontSize(fontSize);
      // currentY 是循环结束后的最后视觉行 Y。
      // 副行 Y = 最后视觉行底部 + 0.3em 间隙：单行用完整行高，
      // 多行时最后一行是换行行（0.8x 行高），与 measureLineHeight 压缩模型一致，
      // 避免翻译副行向下偏移与下一行歌词重叠。
      final double lastRowHeight = visualLineIndex > 0
          ? fontSize * LyricLayout.lineHeight * LyricLayout.wrapLineHeightFactor
          : fontSize * LyricLayout.lineHeight;
      // 副行"长出"偏移：translationExpand=0 时贴主行底（隐藏位），=1 时到正常位。
      // 先布局副行文本，再按**实际视觉行数**取副行高度：副行过长换行时高度随行数
      // 增长，与 AppleLyricsView 的逐行副行预留（LyricLayout.auxSubHeight）严格同式，
      // 否则预留槽位与副行终点错位（多出来的行压到下一行歌词上）。
      // 副行同样只认计划：把计划的行文本用 \n 连起来绘制，行数直接取 rowCount，
      // 于是「副行占位（AppleLyricsView._auxSubHeights）」与「副行绘制终点」必然同式。
      // 关闭平衡时计划即 painterWrap，\n 的位置就是原来的自动换行位置，观感不变。
      final LyricWrapPlan resolvedAuxPlan =
          auxPlan ??
          LyricWrapPlanner.forText(
            auxText,
            LyricLayout.auxStyle(fontSize),
            maxWidth,
            balanced: balanced,
          );
      _translationPainter.text = TextSpan(
        text: resolvedAuxPlan.rowTexts.join('\n'),
        style: TextStyle(
          color: Color.fromRGBO(textRed, textGreen, textBlue, transAlpha),
          fontSize: transFontSize,
          height: LyricLayout.translationLineHeight,
          fontFamily: LyricLayout.fontFamily,
          fontWeight: LyricLayout.fontWeight,
        ),
      );
      _translationPainter.layout(
        maxWidth: maxWidth == double.infinity ? double.infinity : maxWidth,
      );
      final int subRows = resolvedAuxPlan.rowCount;
      final double subH = LyricLayout.auxSubHeight(fontSize, subRows);
      final double transY =
          currentY +
          lastRowHeight +
          transFontSize * 0.3 +
          subH * (translationExpand - 1.0);
      // 翻译副行对齐跟随原文，按副行自身宽度计算 x
      final double transX = _alignX(
        alignment,
        offset.dx,
        _translationPainter.width,
        viewportWidth,
      );
      // 多行翻译副行需设置 textAlign 让每条视觉行独立对齐到 transX
      // 单行时 textAlign 不影响，_alignX 已计算正确 x
      _translationPainter.textAlign = _duetToTextAlign(alignment);
      _paintTranslation(canvas, Offset(transX, transY));
    }
  }

  /// 绘制翻译副行（含日历式翻转）。
  ///
  /// [at] 为副行文本的绘制原点（左上角）。入场绕副行底边从下翻出、出场绕副行
  /// 顶边向上翻走（见 [LyricLayout.sublineFlipAngle]）。角度为 0 时不施加任何
  /// 画布变换，与改造前逐像素一致。
  void _paintTranslation(Canvas canvas, Offset at) {
    final double angle = LyricLayout.sublineFlipAngle(
      translationExpand,
      exiting: translationExiting,
    );
    if (angle == 0) {
      _translationPainter.paint(canvas, at);
      return;
    }
    // 锚点同时给出 x（= 副行水平中点，透视投影中心）与 y（旋转锚线）：
    // 只平移 y 会让透视除法绕画布左上角进行，翻转时副行整体左漂。
    final Offset anchor = LyricLayout.sublineFlipAnchor(
      transX: at.dx,
      sublineWidth: _translationPainter.width,
      transY: at.dy,
      sublineHeight: _translationPainter.height,
      exiting: translationExiting,
    );
    canvas.save();
    canvas.transform(
      LyricLayout.sublineFlipMatrix(angle: angle, anchor: anchor).storage,
    );
    _translationPainter.paint(canvas, at);
    canvas.restore();
  }

  /// 该字是否处于强调激活窗口（任一字符状态非 idle）。
  ///
  /// idle 判定基于 [EmphasizeState.idle] 常量（scale=1、无辉光、无位移）。
  /// 仅当前演唱字内的字符在各自错位窗口内可能非 idle，因此该判断绝大多数
  /// 时间为 false → 走整词渲染，避免逐字符渲染的每帧开销。
  bool _hasActiveEmphasis(int wordIndex) {
    final List<EmphasizeState> states = _emphasizeCharStates[wordIndex];
    for (final s in states) {
      if (s != EmphasizeState.idle) return true;
    }
    return false;
  }

  /// 当前行的 sweep 相位（墨迹长度域，0~1）。
  ///
  /// `phase = (已过字的墨迹长之和 + 当前字内进度 × 当前字墨迹长) ÷ 总墨迹长`
  /// ——与 classic 的 `maskX`（宽度域）同源，但**以墨迹长度为度量**，
  /// 字间空白不占推进距离（由 `LyricSweepPath.frontX` 瞬时跨越）。
  double _sweepPhase() {
    final LyricSweepPath? path = _sweepPath;
    if (path == null || path.isEmpty) return 0;
    final int idx = _currentWordIdx;
    if (idx < 0) return 0;
    if (idx >= _wordInkSpans.length) return 1; // 已播完
    double inkBefore = 0;
    for (int i = 0; i < idx; i++) {
      final double len = _wordInkSpans[i].end - _wordInkSpans[i].start;
      if (len > 0) inkBefore += len;
    }
    final double currentInk = _wordInkSpans[idx].end - _wordInkSpans[idx].start;
    final double total = path.totalInk;
    if (total <= 0) return idx <= 0 ? 0 : 1;
    final double ink =
        inkBefore + (currentInk > 0 ? currentInk * _intraWordProgress : 0);
    return (ink / total).clamp(0.0, 1.0).toDouble();
  }

  /// 第 [i] 个 word 的 sweep 羽化宽度（px）。
  ///
  /// 字宽优先取墨迹区间长度（与 myune 的 `fragment.sweep.length` 同口径），
  /// 墨迹为空时回退 advance 宽度；时长取该字的 [LyricWord.duration]。
  /// [rowHeightFactor] 为行盒系数（主行 = [LyricLayout.lineHeight]，换行行 × 0.8）。
  double _sweepFeatherForWord(int i, double fontSize, double rowHeightFactor) {
    final double inkWidth = i >= 0 && i < _wordInkSpans.length
        ? _wordInkSpans[i].end - _wordInkSpans[i].start
        : 0;
    final double advanceWidth = i >= 0 && i < _wordWidths.length
        ? _wordWidths[i]
        : 0;
    return sweepFeather(
      fontSize: fontSize,
      rowHeightFactor: rowHeightFactor,
      wordWidth: inkWidth > 0 ? inkWidth : advanceWidth,
      wordDuration: _wordDurationOf(i),
    );
  }

  /// 第 [i] 个 word 的时长（无逐字时间戳时为 0 → sweepFeather 落基线）。
  Duration _wordDurationOf(int i) {
    final LyricLine? line = _boundLine;
    if (line == null || i < 0 || i >= line.words.length) return Duration.zero;
    return Duration(milliseconds: line.words[i].duration);
  }

  /// 整词 sweep（扫光）绘制。
  ///
  /// - [sweepRampFor] 返回非空：白字 + `saveLayer(wordRect)` + 4 停
  ///   [LinearGradient] + [BlendMode.modulate]（复用 [_gradientPaint] 实例）；
  /// - 返回 null（退化：无可见过渡带 / 参数非法）：沿用 [_wordAlphas] 均匀
  ///   alpha 快路径，零 saveLayer。
  ///
  /// 仅 [LyricFillMode.sweep] 走本方法；classic 路径不进这里。
  void _paintSweepWord(
    Canvas canvas, {
    required TextPainter painter,
    required int wordIndex,
    required double wordX,
    required double wordY,
    required double width,
    required double rowHeight,
    required double fontSize,
    required double front,
    required double feather,
    required int textRed,
    required int textGreen,
    required int textBlue,
    required double bright,
    required double dark,
    required double uniformAlpha,
  }) {
    final Rect wordRect = Rect.fromLTWH(
      wordX,
      wordY,
      width,
      fontSize * rowHeight,
    );
    final ({List<double> stops, List<Color> colors})? ramp = sweepRampFor(
      rect: wordRect,
      front: front,
      feather: feather,
      active: Color.fromRGBO(textRed, textGreen, textBlue, bright),
      inactive: Color.fromRGBO(textRed, textGreen, textBlue, dark),
      rtl: false, // 本仓歌词按 LTR 排版（TextDirection.ltr）
    );
    if (ramp == null) {
      // 退化：均匀 alpha（与 classic 均匀路径同款量化缓存，避免每帧 layout）
      final int alphaStep = (uniformAlpha * 20).round();
      if (_lastSetAlphas[wordIndex] != alphaStep) {
        painter.text = TextSpan(
          text: painter.text?.toPlainText(),
          style: TextStyle(
            color: Color.fromRGBO(
              textRed,
              textGreen,
              textBlue,
              uniformAlpha,
            ),
            fontSize: fontSize,
            height: rowHeight,
            fontFamily: LyricLayout.fontFamily,
            fontWeight: LyricLayout.fontWeight,
          ),
        );
        painter.layout();
        _lastSetAlphas[wordIndex] = alphaStep;
      }
      _wordGlyphPaint.colorFilter = _wordGlyphTint(
        textRed,
        textGreen,
        textBlue,
        uniformAlpha,
      );
      if (!_blitWordGlyph(
        canvas,
        wordIndex,
        wordX,
        wordY,
        width,
        fontSize,
        rowHeight,
      )) {
        painter.paint(canvas, Offset(wordX, wordY));
      }
      return;
    }
    // 渐变路径：painter 保持纯白（lastSetAlphas = -1 标记白色已缓存），
    // 渐变事后用 drawRect(modulate) 应用，稳态 0 次 layout/帧。
    if (_lastSetAlphas[wordIndex] != -1) {
      painter.text = TextSpan(
        text: painter.text?.toPlainText(),
        style: TextStyle(
          color: const Color.fromRGBO(255, 255, 255, 1.0),
          fontSize: fontSize,
          height: rowHeight,
          fontFamily: LyricLayout.fontFamily,
          fontWeight: LyricLayout.fontWeight,
        ),
      );
      painter.layout();
      _lastSetAlphas[wordIndex] = -1;
    }
    canvas.saveLayer(wordRect, Paint());
    _wordGlyphPaint.colorFilter = null; // 纯白字形，渐变由 modulate 着色
    if (!_blitWordGlyph(
      canvas,
      wordIndex,
      wordX,
      wordY,
      width,
      fontSize,
      rowHeight,
    )) {
      painter.paint(canvas, Offset(wordX, wordY)); // dst = 白色文字
    }
    _gradientPaint.shader = LinearGradient(
      colors: ramp.colors,
      stops: ramp.stops,
    ).createShader(wordRect);
    _gradientPaint.blendMode = BlendMode.modulate;
    canvas.drawRect(wordRect, _gradientPaint); // src = 4 停渐变
    canvas.restore();
  }

  /// v5 逐字符波浪：逐字符绘制强调字。
  ///
  /// 每个字符独立应用 [EmphasizeState] 的 scale（绕字符中心缩放）、水平外扩
  /// offsetXEm、上浮 offsetYEm + 正弦浮层 floatYEm，以及逐字符辉光精灵与
  /// 行级 mask 渐变采样。整词上浮（[_wordYOffsets]）已含在 [wordY] 中，所有
  /// 字符统一叠加，保留 AMLL 的 float-word 与逐字 float 双层效果。
  ///
  /// [wordIndex] 该字在行内的索引（用于取逐字符缓存与行内起始 X）。
  void _paintEmphasizedWord(
    Canvas canvas, {
    required double wordX,
    required double wordY,
    required double fontSize,
    required double lineHeight,
    required double rowHeight,
    required int wordIndex,
    required int textRed,
    required int textGreen,
    required int textBlue,
    required double bright,
    required double dark,
    required double transitionStart,
    required double transitionSpan,
    required bool useGradient,
    bool sweepMode = false,
    double sweepFront = 0,
    double sweepFeather = 0,
  }) {
    final List<TextPainter> charPainters = _charPainters[wordIndex];
    final List<double> charWidths = _charWidths[wordIndex];
    final List<double> charStartXs = _charStartXs[wordIndex];
    final List<EmphasizeState> charStates = _emphasizeCharStates[wordIndex];
    final List<int> lastSetAlphas = _lastSetCharAlphas[wordIndex];
    final List<ui.Image?> glowSprites = _charGlowSprites[wordIndex];
    final List<ui.Image?> charImages = _charImages[wordIndex];
    final double wordStartX = wordIndex < _wordStartXs.length
        ? _wordStartXs[wordIndex]
        : 0;
    // 非渐变（maskX 无效）时逐字符共用整词 alpha
    final double solidAlpha = wordIndex < _wordAlphas.length
        ? _wordAlphas[wordIndex]
        : dark;
    // sweep 前端在行内累计坐标系，而字符 rect 在 canvas 坐标系：
    // 用本词的行内起点换算（对齐 baseX / 换行行都会产生这个常量偏移）。
    final double sweepFrontCanvas = sweepFront + (wordX - wordStartX);

    for (int k = 0; k < charPainters.length; k++) {
      final double cw = k < charWidths.length ? charWidths[k] : 0;
      final double charStartX = k < charStartXs.length ? charStartXs[k] : 0;
      final EmphasizeState st = k < charStates.length
          ? charStates[k]
          : EmphasizeState.idle;
      final TextPainter painter = charPainters[k];

      // 行级 maskX 模型按字符中心采样单一 alpha（uniform）。
      // **P6 优化**：激活窗口内逐字符不再用 saveLayer + 渐变 shader（单字内渐变
      // 肉眼不可辨），改为中心采样均匀 alpha 直接写入文字颜色，消除每帧
      // saveLayer/shader 创建的 GPU 开销，避免真机掉帧导致缩放位移卡顿。
      final double charGlobalCenter = wordStartX + charStartX + cw / 2;
      final double charAlpha;
      if (!useGradient) {
        charAlpha = solidAlpha;
      } else if (sweepMode) {
        // sweep：点采样 myune 的逐像素公式（highlight ∈ [0,1] → alpha ∈ [dark, bright]）
        charAlpha =
            dark +
            (bright - dark) *
                sweepAlphaAt(sweepFront, sweepFeather, charGlobalCenter);
      } else {
        charAlpha = _alphaAtX(
          charGlobalCenter,
          transitionStart,
          transitionSpan,
          bright,
          dark,
        );
      }

      final double charX = wordX + charStartX;
      final double charY = wordY;
      final Offset charPos = Offset(charX, charY);

      // === 逐字符强调 transform ===
      // scale 绕字符中心缩放；位移在缩放后应用，避免被 scale 放大。
      final bool needEmphasis =
          st.scale != 1.0 ||
          st.glowLevel > 0 ||
          st.offsetXEm != 0 ||
          st.offsetYEm != 0 ||
          st.floatYEm != 0;
      if (needEmphasis) {
        canvas.save();
        final double centerX = charX + cw / 2;
        final double centerY = charY + fontSize * rowHeight / 2;
        canvas.translate(centerX, centerY);
        canvas.scale(st.scale, st.scale);
        canvas.translate(-centerX, -centerY);
        // em → px：水平外扩 offsetXEm，上浮 offsetYEm + 正弦浮层 floatYEm
        canvas.translate(
          st.offsetXEm * fontSize,
          (st.offsetYEm + st.floatYEm) * fontSize,
        );
      }

      // === 逐字符渐变参数（辉光层与文字层**共用**同一份）===
      // 必须在辉光之前算：辉光要先画（在文字下面），但它也要按同一套
      // 字内进度前沿逐段上色，才能"跟着扫光推进"。
      final double charLeftX = wordStartX + charStartX;
      final double charRightX = charLeftX + cw;
      final double charRectH = fontSize * rowHeight;
      final Rect charRect = Rect.fromLTWH(charX, charY, cw, charRectH);
      double leftAlpha = charAlpha;
      double rightAlpha = charAlpha;
      // sweep：字符级用与整词路径同一套 4 停渐变（myune 逐像素斜坡的等价段）
      ({List<double> stops, List<Color> colors})? sweepRamp;
      if (useGradient && sweepMode) {
        sweepRamp = sweepRampFor(
          rect: charRect,
          front: sweepFrontCanvas,
          feather: sweepFeather,
          active: Color.fromRGBO(textRed, textGreen, textBlue, bright),
          inactive: Color.fromRGBO(textRed, textGreen, textBlue, dark),
          rtl: false,
        );
      } else if (useGradient) {
        leftAlpha = _alphaAtX(
          charLeftX,
          transitionStart,
          transitionSpan,
          bright,
          dark,
        );
        rightAlpha = _alphaAtX(
          charRightX,
          transitionStart,
          transitionSpan,
          bright,
          dark,
        );
      }
      final bool needGradient =
          sweepRamp != null || (rightAlpha - leftAlpha).abs() >= 0.01;

      // === 逐字符辉光层 ===
      // 强度 = glowLevel × 用户辉光强度倍数（glowLevel 已随字时长/末尾字加强）；
      // 光晕剖面固定（见 [_glowRimSigmaEm]），保证方块字的字怀不被糊满。
      if (st.glowLevel > 0) {
        // 辉光颜色跟随当前文字色（= 动态取色混色结果），不再恒为白色。
        final ({double base, double extra}) glowAlpha = _glowDrawAlpha(
          st.glowLevel,
        );
        final ColorFilter glowTint = _glowTint(
          textRed,
          textGreen,
          textBlue,
          glowAlpha.base,
        );
        final double pad = _glowSpritePad(fontSize);
        final glowRect = Rect.fromLTWH(
          charX - pad,
          charY - pad,
          cw + pad * 2,
          fontSize * rowHeight + pad * 2,
        );
        // 优先用预渲染辉光精灵贴图（颜色/透明度经 ColorFilter 逐帧驱动）
        // 行盒失效检测：精灵可能是预热阶段按整行行盒（lineHeight）生成的，
        // 若当前为换行行（rowHeight=0.8x），旧精灵字形偏下、光晕错位。
        // 这里在绘制前主动核对行盒，不一致则释放并强制按当前 rowHeight 重生成
        // （_requestCharGlowSprite 只在精灵为 null 时才请求，故必须在此先释放）。
        final String glowKey = '$wordIndex:$k';
        final double? cachedGlowRow = _glowSpriteRowHeight[glowKey];
        if (cachedGlowRow != null &&
            (cachedGlowRow - rowHeight).abs() > 1e-6) {
          _glowSpriteRowHeight.remove(glowKey);
          final old = k < glowSprites.length ? glowSprites[k] : null;
          old?.dispose();
          if (wordIndex < _charGlowSprites.length &&
              k < _charGlowSprites[wordIndex].length) {
            _charGlowSprites[wordIndex][k] = null;
          }
        }
        final ui.Image? sprite = k < glowSprites.length
            ? glowSprites[k]
            : null;
        // 换行行辉光诊断日志（节流：仅状态变化时打印一次，供真机抓 log 定位）
        if ((rowHeight - lineHeight).abs() > 1e-6) {
          final String dbg =
              'w$wordIndex:c$k row=${rowHeight.toStringAsFixed(3)} '
              'cached=${cachedGlowRow?.toStringAsFixed(3) ?? 'null'} '
              'sprite=${sprite != null} y=${charY.toStringAsFixed(1)}';
          if (dbg != _lastGlowDebug) {
            _lastGlowDebug = dbg;
            // ignore: avoid_print
            if (kDebugMode) print('[GlowDbg] $dbg');
          }
        }
        if (sprite != null) {
          // 精灵按 [_glowSpriteSupersample] 超采样烘焙，这里缩回逻辑尺寸
          // （drawImageRect + 双线性）。pad 与烘焙侧同口径。
          final Rect srcRect = Rect.fromLTWH(
            0,
            0,
            sprite.width.toDouble(),
            sprite.height.toDouble(),
          );
          final Rect dstRect = Rect.fromLTWH(
            charX - pad,
            charY - pad,
            sprite.width / _glowSpriteSupersample.toDouble(),
            sprite.height / _glowSpriteSupersample.toDouble(),
          );
          _drawGlowSpriteWithRamp(
            canvas: canvas,
            sprite: sprite,
            srcRect: srcRect,
            dstRect: dstRect,
            rampRect: charRect,
            glowAlpha: glowAlpha,
            sweepRamp: sweepRamp,
            leftAlpha: leftAlpha,
            rightAlpha: rightAlpha,
            red: textRed,
            green: textGreen,
            blue: textBlue,
          );
        } else {
          // 精灵未就绪（字符激活早期，glowLevel≈0 几乎不可见）：
          // 异步请求渲染，本帧降级单层锐边 blur 保证视觉连续。
          _requestCharGlowSprite(
            wordIndex,
            k,
            painter.text?.toPlainText() ?? '',
            fontSize,
            rowHeight,
          );
          final double rimSigma = _glowRimSigmaEm * fontSize;
          _glowBlurPaint.imageFilter = ImageFilter.blur(
            sigmaX: tvBlurSigma(rimSigma),
            sigmaY: tvBlurSigma(rimSigma),
          );
          _glowBlurPaint.colorFilter = glowTint;
          canvas.saveLayer(glowRect, _glowBlurPaint);
          painter.paint(canvas, charPos);
          canvas.restore();
        }
      }

      // === 文字绘制 ===
      // v7：优先用预渲染纯白字形图（3× 超采样，图片变换平滑缩放，无文字重栅格化
      // 闪烁、无放大马赛克），经 ColorFilter.matrix 上色为文字色 + mask alpha，
      // drawImageRect 缩放到原生字符尺寸；图片未就绪时降级 TextPainter 均匀
      // alpha 路径（量化缓存），视觉等价。
      //
      // 换行行（rowHeight < lineHeight，0.8x 行盒）：字形图按 1.5 行盒生成，
      // 直接缩放到 0.8x 行盒会把字形垂直压扁变形 → 换行行改用 TextPainter
      // （按 rowHeight 行盒渲染），与整词路径行盒一致，避免激活/idle 切换瞬移。
      //
      // **方案 C：辉光字与普通字一致的渐变模型**。普通字整词路径按字左右边缘
      // 采样行级渐变（maskX 左亮右暗，向右推进）；辉光字此前（P6）改为字符中心
      // 采样 uniform，单字内无渐变，导致中文单字在 maskX 扫过时"整字变亮"、
      // 渐变带凭空消失显得硬切。这里对每个字符按左右边缘采样，差异明显时
      // saveLayer + LinearGradient modulate（与整词路径一致），恢复向右推进感。
      final bool sameRowBox = (rowHeight - lineHeight).abs() < 1e-6;
      final ui.Image? charImg = sameRowBox && k < charImages.length
          ? charImages[k]
          : null;
      // 渐变参数（charLeftX / charRightX / leftAlpha / rightAlpha /
      // sweepRamp / needGradient）已在辉光层之前统一算好，此处直接复用。
      if (needGradient) {
        // 渐变路径：先画纯白字形，再 LinearGradient modulate（复用 _gradientPaint）。
        final double charH =
            fontSize * (charImg != null ? lineHeight : rowHeight);
        final Rect charRect = Rect.fromLTWH(charX, charY, cw, charH);
        canvas.saveLayer(charRect, Paint());
        if (charImg != null) {
          _charImagePaint.colorFilter = const ColorFilter.matrix(<double>[
            1,
            0,
            0,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            0,
            1,
            0,
          ]); // 纯白字形（modulate 后由渐变着色）
          canvas.drawImageRect(
            charImg,
            Rect.fromLTWH(
              0,
              0,
              charImg.width.toDouble(),
              charImg.height.toDouble(),
            ),
            charRect,
            _charImagePaint,
          );
        } else {
          // 渐变路径 painter 保持纯白（lastSetAlphas = -1 标记白色已缓存）
          if (k >= lastSetAlphas.length || lastSetAlphas[k] != -1) {
            painter.text = TextSpan(
              text: painter.text?.toPlainText(),
              style: TextStyle(
                color: const Color.fromRGBO(255, 255, 255, 1.0),
                fontSize: fontSize,
                height: rowHeight,
                fontFamily: LyricLayout.fontFamily,
                fontWeight: LyricLayout.fontWeight,
              ),
            );
            painter.layout();
            if (k < lastSetAlphas.length) lastSetAlphas[k] = -1;
          }
          painter.paint(canvas, charPos);
        }
        // sweep 用 4 停带（颜色顺序随 rtl 镜像）；classic 仍是左右边缘 alpha 的 2 停。
        final List<Color> gradientColors =
            sweepRamp?.colors ??
            <Color>[
              Color.fromRGBO(textRed, textGreen, textBlue, leftAlpha),
              Color.fromRGBO(textRed, textGreen, textBlue, rightAlpha),
            ];
        final List<double> gradientStops =
            sweepRamp?.stops ?? const <double>[0.0, 1.0];
        _gradientPaint.shader = LinearGradient(
          colors: gradientColors,
          stops: gradientStops,
        ).createShader(charRect);
        _gradientPaint.blendMode = BlendMode.modulate;
        canvas.drawRect(charRect, _gradientPaint);
        canvas.restore();
      } else if (charImg != null) {
        // uniform（差异可忽略）：现有字形图路径
        _charImagePaint.colorFilter = ColorFilter.matrix(<double>[
          textRed / 255,
          0,
          0,
          0,
          0,
          0,
          textGreen / 255,
          0,
          0,
          0,
          0,
          0,
          textBlue / 255,
          0,
          0,
          0,
          0,
          0,
          charAlpha,
          0,
        ]);
        canvas.drawImageRect(
          charImg,
          Rect.fromLTWH(
            0,
            0,
            charImg.width.toDouble(),
            charImg.height.toDouble(),
          ),
          Rect.fromLTWH(charX, charY, cw, fontSize * lineHeight),
          _charImagePaint,
        );
      } else {
        // uniform：TextPainter 均匀 alpha（量化缓存）
        final int alphaStep = (charAlpha * 20).round();
        if (k >= lastSetAlphas.length || lastSetAlphas[k] != alphaStep) {
          painter.text = TextSpan(
            text: painter.text?.toPlainText(),
            style: TextStyle(
              color: Color.fromRGBO(textRed, textGreen, textBlue, charAlpha),
              fontSize: fontSize,
              height: rowHeight,
              fontFamily: LyricLayout.fontFamily,
              fontWeight: LyricLayout.fontWeight,
            ),
          );
          painter.layout();
          if (k < lastSetAlphas.length) lastSetAlphas[k] = alphaStep;
        }
        painter.paint(canvas, charPos);
      }

      if (needEmphasis) {
        canvas.restore();
      }
    }
  }

  /// 计算指定 X 坐标处的 alpha 值（行级渐变模型核心）。
  ///
  /// 过渡区 [transitionStart, transitionStart + transitionSpan]：
  /// - x <= transitionStart：bright（已播区）
  /// - x >= transitionStart + transitionSpan：dark（未播区）
  /// - 过渡区内：bright → dark 线性插值
  ///
  /// 通过此函数计算每个 word 左右边缘的 alpha，决定均匀绘制还是渐变 shader。
  /// 渐变边界随 maskX 移动跨越多个 word，自然实现"长字慢、短字快"。
  static double _alphaAtX(
    double x,
    double transitionStart,
    double transitionSpan,
    double bright,
    double dark,
  ) {
    if (transitionSpan <= 0) return x <= transitionStart ? bright : dark;
    if (x <= transitionStart) return bright;
    final double t = (x - transitionStart) / transitionSpan;
    if (t >= 1.0) return dark;
    return bright + (dark - bright) * t;
  }

  /// 根据对唱对齐方式计算文本起始 x 坐标。
  /// [leftPadding] 为左侧 1em 边距（即 offset.dx），右侧对称留白。
  double _alignX(
    DuetAlignment alignment,
    double leftPadding,
    double textWidth,
    double viewportWidth,
  ) {
    if (viewportWidth <= 0 ||
        alignment == DuetAlignment.defaultAlign ||
        alignment == DuetAlignment.left) {
      return leftPadding;
    }
    if (alignment == DuetAlignment.right) {
      return viewportWidth - leftPadding - textWidth;
    }
    // center
    return (viewportWidth - textWidth) / 2;
  }

  /// 对唱对齐方式 → TextAlign 映射（用于多行翻译副行内部对齐）。
  /// left/defaultAlign → start（左对齐）
  /// right → end（右对齐）
  /// center → center（居中）
  static TextAlign _duetToTextAlign(DuetAlignment alignment) {
    switch (alignment) {
      case DuetAlignment.center:
        return TextAlign.center;
      case DuetAlignment.right:
        return TextAlign.end;
      default:
        return TextAlign.start;
    }
  }

  /// 整行降级绘制（无 word 时间戳时使用）。
  ///
  /// 断点一律来自 [plan]（与行高测量同源），本方法内不再自行判断换行；
  /// [maxWidth] 仅保留给调用方签名一致，不参与断行。
  /// 用临时 TextPainter 实例（仅在 fallback 路径，频率低不缓存）。
  void _paintSolidFallback(
    Canvas canvas,
    Offset offset,
    LyricLine line,
    double fontSize, {
    double maxWidth = double.infinity,
    DuetAlignment alignment = DuetAlignment.defaultAlign,
    double viewportWidth = 0,
    required LyricWrapPlan plan,
  }) {
    if (line.text.isEmpty) return;
    final double alpha = dynamicDarkAlpha;
    // 动态字体颜色（仅当前行）优先，否则回退主题默认色
    final int colorValue = (_isActive && _activeColorValue != null)
        ? _activeColorValue!
        : LyricLayout.textColorValue;
    final int textRed = (colorValue >> 16) & 0xFF;
    final int textGreen = (colorValue >> 8) & 0xFF;
    final int textBlue = colorValue & 0xFF;

    // 与 LineRenderer._paintMultiLineAligned 同一套行盒模型：主行完整行高、
    // 换行行 0.8x 行高且从主行底部起，与 lineHeightForRows 的预留严格对应。
    final double mainLineHeight = fontSize * LyricLayout.lineHeight;
    final double wrapLineHeight =
        mainLineHeight * LyricLayout.wrapLineHeightFactor;
    final painter = TextPainter(textDirection: TextDirection.ltr);
    for (int i = 0; i < plan.rowTexts.length; i++) {
      final bool isFirstRow = i == 0;
      painter.text = TextSpan(
        text: plan.rowTexts[i],
        style: TextStyle(
          color: Color.fromRGBO(textRed, textGreen, textBlue, alpha),
          fontSize: fontSize,
          height: isFirstRow
              ? LyricLayout.lineHeight
              : LyricLayout.lineHeight * LyricLayout.wrapLineHeightFactor,
          fontFamily: LyricLayout.fontFamily,
          fontWeight: LyricLayout.fontWeight,
        ),
      );
      painter.layout(maxWidth: double.infinity);
      final double x = _alignX(
        alignment,
        offset.dx,
        painter.width,
        viewportWidth,
      );
      final double y = isFirstRow
          ? offset.dy
          : offset.dy + mainLineHeight + (i - 1) * wrapLineHeight;
      painter.paint(canvas, Offset(x, y));
    }
    painter.dispose();
  }

  /// 辉光层实际绘制 alpha 拆分：`lit = glowLevel × 强度倍数`（上限 2.0）。
  ///
  /// - [base]：常规 source-over 的 alpha（0~1）；
  /// - [extra]：`lit > 1` 的部分，改用 [BlendMode.plus] 追加一层——单次绘制的
  ///   alpha 不可能超过 1，靠加法叠加才能让"更强"真的有亮度收益。
  ///
  /// 强度只乘亮度、不改剖面半径（[glowSigmaProfileEmForTest]），
  /// 所以「贴笔画」的光形不会被强度调糊；见 [LyricPreferences.glowIntensity]。
  ({double base, double extra}) _glowDrawAlpha(double glowLevel) {
    final double lit =
        (glowLevel * LyricPreferences.instance.glowIntensity).clamp(0.0, 2.0);
    return (base: lit.clamp(0.0, 1.0), extra: (lit - 1.0).clamp(0.0, 1.0));
  }

  /// 辉光上色：颜色 = 当前文字色（含 alpha = [alpha]），与输入像素 RGB 无关。
  ///
  /// 用 [BlendMode.srcIn] 而不是矩阵乘法：源颜色整体替换为文字色、alpha 取
  /// 光晕自身的 alpha。这样无论输入是纯白精灵还是已带文字色的 TextPainter
  /// 降级路径，上色结果都一致（矩阵乘法会在「已着色文字」上二次相乘变暗）。
  ///
  /// 旧实现把 RGB 恒为 1（白）只改 alpha，导致辉光永远是白色、
  /// 不跟随「歌词动态颜色」的混色比例。
  ColorFilter _glowTint(int r, int g, int b, double alpha) =>
      ColorFilter.mode(
        Color.fromRGBO(r, g, b, alpha.clamp(0.0, 1.0)),
        BlendMode.srcIn,
      );

  /// 按字内进度前沿**逐段**绘制辉光精灵。
  ///
  /// 辉光要跟着扫光推进：已唱侧达到峰值、前沿处过渡、未唱侧淡出。
  /// 做法与文字层完全同源（[BlendMode.modulate] + [LinearGradient]）：
  /// 1. `saveLayer(layerRect)`，在层内用纯白 Paint 画精灵（精灵本身是 alpha 贴图）；
  /// 2. 用文字那套渐变（sweep 的 4 停 / classic 的 2 停）modulate 该层；
  /// 3. 强度 >100% 的 `extra` 部分改用 [BlendMode.plus] 追加，**同一渐变**，
  ///    否则两层推进位置不一致会出现重影。
  ///
  /// **两个 rect 必须区分开**（写错会把光晕裁成矩形硬边）：
  /// - [layerRect] = 精灵的 `dstRect`（含左右各 `pad` 的光晕外扩）→ 这是
  ///   `saveLayer` 的边界，必须够大，否则光晕被裁出竖直硬边；
  /// - [rampRect] = **字符 rect**（与文字渐变同坐标系）→ 这是渐变 shader 的
  ///   锚点，用它才能让光晕前沿与文字前沿严格对齐。
  void _drawGlowSpriteWithRamp({
    required Canvas canvas,
    required ui.Image sprite,
    required Rect srcRect,
    required Rect dstRect,
    required Rect rampRect,
    required ({double base, double extra}) glowAlpha,
    required ({List<double> stops, List<Color> colors})? sweepRamp,
    required double leftAlpha,
    required double rightAlpha,
    required int red,
    required int green,
    required int blue,
  }) {
    // 辉光用文字色，alpha 取「文字在该处 alpha × 辉光强度基准」。
    // 渐变 stops 直接沿用文字那套（sweep 4 停 / classic 两端），
    // 因此辉光前沿与文字前沿严格同位置。
    final List<double> stops = sweepRamp?.stops ?? const <double>[0.0, 1.0];

    Color rampColor(double textAlpha, double glowBase) => Color.fromRGBO(
      red,
      green,
      blue,
      (textAlpha * glowBase).clamp(0.0, 1.0),
    );

    final List<Color> baseColors = sweepRamp == null
        ? <Color>[
            rampColor(leftAlpha, glowAlpha.base),
            rampColor(rightAlpha, glowAlpha.base),
          ]
        : <Color>[
            for (final Color c in sweepRamp.colors)
              rampColor(c.a, glowAlpha.base),
          ];

    // saveLayer 用 dstRect（包容光晕）。
    canvas.saveLayer(dstRect, Paint());
    // 层内先贴纯白精灵（alpha 由精灵自带，颜色交给渐变）
    _glowImagePaint.colorFilter = null;
    canvas.drawImageRect(sprite, srcRect, dstRect, _glowImagePaint);
    // **关键：渐变要建在 dstRect 上、并把 stops 重映射到 dstRect 坐标系**。
    // 若直接 createShader(rampRect)，LinearGradient 在 rampRect 之外是钳制的，
    // 而精灵在左右 pad 区仍有光晕 → 该区域拿到边缘色，形成矩形亮框。
    _glowRampPaint.shader = LinearGradient(
      colors: baseColors,
      stops: _remapStopsToRect(stops: stops, rampRect: rampRect, dst: dstRect),
    ).createShader(dstRect);
    _glowRampPaint.blendMode = BlendMode.modulate;
    canvas.drawRect(dstRect, _glowRampPaint);
    canvas.restore();

    // 强度 >100%：同一渐变、加法叠加（单次 alpha 封顶 1.0）。
    if (glowAlpha.extra > 0) {
      final List<Color> extraColors = sweepRamp == null
          ? <Color>[
              rampColor(leftAlpha, glowAlpha.extra),
              rampColor(rightAlpha, glowAlpha.extra),
            ]
          : <Color>[
              for (final Color c in sweepRamp.colors)
                rampColor(c.a, glowAlpha.extra),
            ];
      canvas.saveLayer(dstRect, Paint());
      _glowPlusPaint.colorFilter = null;
      canvas.drawImageRect(sprite, srcRect, dstRect, _glowPlusPaint);
      _glowRampPaint.shader = LinearGradient(
        colors: extraColors,
        stops: _remapStopsToRect(stops: stops, rampRect: rampRect, dst: dstRect),
      ).createShader(dstRect);
      _glowRampPaint.blendMode = BlendMode.modulate;
      canvas.drawRect(dstRect, _glowRampPaint);
      canvas.restore();
    }
  }

  /// 把「相对 [rampRect] 的 stops」重映射成「相对 [dst] 的 stops」。
  ///
  /// 辉光的渐变 shader 建在外扩后的 `dst`（含 pad）上，但 stops 是按字符
  /// `rampRect` 算的——直接复用会让前沿位置整体偏移 pad/宽度。
  /// 这里按两个 rect 的左边界与宽度做线性换算，`dst` 之外的段被钳到 0/1。
  static List<double> _remapStopsToRect({
    required List<double> stops,
    required Rect rampRect,
    required Rect dst,
  }) {
    if (dst.width <= 0) return stops;
    final double scale = rampRect.width / dst.width;
    final double shift = (rampRect.left - dst.left) / dst.width;
    return <double>[
      for (final double s in stops) (shift + s * scale).clamp(0.0, 1.0),
    ];
  }

  /// P1-5 方案 1：异步渲染单个字符的辉光精灵图并缓存。
  ///
  /// 精灵内容 = 纯白字符 + **三层高斯剖面**（见 [_glowRimSigmaEm] 等常量），
  /// 只在行盒/字号变化时重烘焙；每帧用 [ColorFilter] 按当前文字色与
  /// `glowLevel` 上色，因此调「动态颜色混色比例」不需要重建精灵。
  ///
  /// 幂等保护：key（wordIndex:charIndex）已在缓存或渲染中时直接返回。
  /// 异步回调用 [_spriteEpoch] 校验，renderer 已重置/切行时丢弃结果。
  void _requestCharGlowSprite(
    int wordIndex,
    int charIndex,
    String text,
    double fontSize,
    double rowHeight, {
    bool rebuildOnMismatch = true,
  }) {
    final String key = '$wordIndex:$charIndex';
    // 行盒变化（换行行 ⇄ 非换行行）时旧精灵行盒与当前文字不一致：
    // 释放旧精灵，强制按新行盒重新渲染，保证光晕始终贴合文字。
    // 仅【绘制路径】允许重建；预热路径不干预，避免预热（lineHeight）每帧
    // 与绘制（rowHeight）反复互相释放重建 → 光晕闪烁。
    if (rebuildOnMismatch) {
      final double? cachedRow = _glowSpriteRowHeight[key];
      if (cachedRow != null && (cachedRow - rowHeight).abs() > 1e-6) {
        _glowSpriteRowHeight.remove(key);
        if (wordIndex < _charGlowSprites.length &&
            charIndex < _charGlowSprites[wordIndex].length) {
          _charGlowSprites[wordIndex][charIndex]?.dispose();
          _charGlowSprites[wordIndex][charIndex] = null;
        }
      }
    } else {
      // 预热：已有精灵（无论行盒）或已有渲染任务（无论行盒）都直接返回，
      // 不破坏绘制已按正确行盒建立的精灵。
      if (wordIndex < _charGlowSprites.length &&
          charIndex < _charGlowSprites[wordIndex].length &&
          _charGlowSprites[wordIndex][charIndex] != null) {
        return;
      }
      if (_glowSpritePendingRow.containsKey(key)) return;
    }
    if (wordIndex < _charGlowSprites.length &&
        charIndex < _charGlowSprites[wordIndex].length &&
        _charGlowSprites[wordIndex][charIndex] != null) {
      return; // 已有匹配当前行盒的精灵
    }
    // 行盒竞态保护：旧行盒（如预热 lineHeight）的渲染可能仍在异步进行。
    // 仅当"正在渲染的行盒与当前 rowHeight 相同"时才复用该渲染任务；
    // 否则重新请求，并用回调行盒校验丢弃过期结果。
    final double? pendingRow = _glowSpritePendingRow[key];
    if (pendingRow != null && (pendingRow - rowHeight).abs() < 1e-6) {
      return; // 同行盒渲染中
    }
    _glowSpritePendingRow[key] = rowHeight;
    _glowSpriteRowHeight[key] = rowHeight;
    final int epoch = _spriteEpoch;
    // 外扩以最外层（薄雾层）半径的 3σ 为准：blur 光晕实际扩散约 3σ，
    // 仅留 2σ 会在换行行（0.8x 行盒，字形更靠上）把向上光晕裁切，
    // 光晕只剩下方、像垫在文字底下。
    final double pad = _glowSpritePad(fontSize);
    final double wordH = fontSize * rowHeight;
    // 空字符安全保护
    if (text.isEmpty || wordH <= 0) {
      _glowSpritePendingRow.remove(key);
      _glowSpriteRowHeight.remove(key);
      return;
    }
    // 异步渲染（toImage 在光栅线程执行，回调回 UI 线程）
    _renderGlowSpriteImage(text, fontSize, pad, rowHeight).then((image) {
      _glowSpritePendingRow.remove(key);
      if (image == null) return;
      if (epoch != _spriteEpoch) {
        // renderer 已重置/切行：过期结果直接释放
        image.dispose();
        return;
      }
      // 行盒校验：回调时若记录的行盒已不是本次渲染的行盒
      // （被换行行重新请求覆盖），丢弃本次结果，避免误用偏下精灵。
      final double? curRow = _glowSpriteRowHeight[key];
      if (curRow == null || (curRow - rowHeight).abs() > 1e-6) {
        image.dispose();
        return;
      }
      if (wordIndex < _charGlowSprites.length &&
          charIndex < _charGlowSprites[wordIndex].length) {
        _charGlowSprites[wordIndex][charIndex]?.dispose();
        _charGlowSprites[wordIndex][charIndex] = image;
      }
    });
  }

  /// 渲染单张辉光精灵图（纯白 + 三层高斯剖面，异步）。
  ///
  /// 按绘制时的行盒 [rowHeight] 渲染，与正文字形同盒顶对齐：
  /// 换行行（0.8x 行盒）用 rowHeight，非换行行等于 lineHeight，
  /// 保证光晕与文字上下完全贴合，不再需要额外垂直偏移补偿。
  ///
  /// **挖空字形本体**：每层先画模糊后的字形，再用 `dstOut` 扣掉未模糊的本体，
  /// 只留笔画外侧的光。这是"沿笔画发光"而非"字后垫一块发光方块"的关键。
  ///
  /// **按 [_glowSpriteSupersample] 超采样烘焙**：字号、sigma、外扩、画布全部
  /// 同乘倍数，得到一张高分辨率精灵；绘制期 `drawImageRect` 缩回逻辑尺寸，
  /// 光晕的连续 alpha 斜坡得以保留（否则 1× 量化台阶被 DPR 放大成锯齿）。
  ///
  /// 内部 try-catch 兜底：任何渲染失败（如 GPU 资源紧张）返回 null，
  /// 下次 _requestCharGlowSprite 会重新尝试。
  Future<ui.Image?> _renderGlowSpriteImage(
    String text,
    double fontSize,
    double pad,
    double rowHeight,
  ) async {
    try {
      final double ss = _glowSpriteSupersample.toDouble();
      final TextPainter fillPainter = TextPainter(textDirection: TextDirection.ltr)
        ..text = TextSpan(
          text: text,
          style: TextStyle(
            // 与渐变路径 painter 一致：plain white，颜色由绘制期 ColorFilter 决定
            color: const Color.fromRGBO(255, 255, 255, 1.0),
            // 字号同乘倍数：字形按高分辨率栅格化，而非事后 canvas 放大
            fontSize: fontSize * ss,
            height: rowHeight,
            fontFamily: LyricLayout.fontFamily,
            fontWeight: LyricLayout.fontWeight,
          ),
        )
        ..layout();
      final int imgW = (fillPainter.width + pad * 2 * ss).ceil();
      // 字形高度也要同乘倍数：字号已放大，行盒内容随之为 fontSize×ss×rowHeight，
      // 漏乘会把放大后的字形底部裁掉（画布不够高 → 一条硬切线）。
      final int imgH = (fontSize * ss * rowHeight + pad * 2 * ss).ceil();
      if (imgW <= 0 || imgH <= 0) {
        fillPainter.dispose();
        return null;
      }

      final recorder = ui.PictureRecorder();
      final glowCanvas = Canvas(recorder);
      final Rect bounds = Rect.fromLTWH(0, 0, imgW.toDouble(), imgH.toDouble());
      final Offset at = Offset(pad * ss, pad * ss);
      // 由紧到松：贴轮廓层 → 柔光层 → 氛围层。
      const List<double> sigmasEm = <double>[
        _glowRimSigmaEm,
        _glowBloomSigmaEm,
        _glowHazeSigmaEm,
      ];
      const List<double> weights = <double>[
        _glowRimWeight,
        _glowBloomWeight,
        _glowHazeWeight,
      ];
      for (int layer = 0; layer < sigmasEm.length; layer++) {
        // sigma 同乘倍数：光晕半径在放大后的坐标系里保持相同的"逻辑尺寸"
        final double sigma = sigmasEm[layer] * fontSize * ss;
        // 每层一个组：把字形按该半径模糊后按权重叠加。
        // **不挖空**——高斯模糊天然「中心最亮、向外递减」，与字形叠加后
        // 字形处最亮，正是需要的观感（见剖面常量的说明）。
        glowCanvas.saveLayer(
          bounds,
          Paint()
            ..imageFilter = ui.ImageFilter.blur(
              sigmaX: tvBlurSigma(sigma),
              sigmaY: tvBlurSigma(sigma),
            )
            // 用图层 alpha 作权重：逐层 source-over 叠加，内层最亮、外层衰减，
            // 不改变 glowLevel 对整体亮度的线性控制。
            ..color = Color.fromRGBO(255, 255, 255, weights[layer]),
        );
        fillPainter.paint(glowCanvas, at);
        glowCanvas.restore();
      }
      fillPainter.dispose();

      final picture = recorder.endRecording();
      final image = await picture.toImage(imgW, imgH);
      // toImage 经 native 回调栅格化，future 完成后 Picture 不再被引用，此刻释放才安全。
      picture.dispose();
      return image;
    } catch (_) {
      return null;
    }
  }

  /// v7：异步渲染单个字符的纯白字形图（无 blur）并缓存。
  ///
  /// 波浪激活窗口内逐字符缩放/位移改用该图片 + canvas 变换绘制，
  /// 避免 TextPainter 每帧重新栅格化字形导致的亚像素闪烁。
  /// **按 [_charImageSupersample] 超采样渲染**：绘制时经 drawImageRect 缩放到
  /// 原生尺寸，波浪放大到 1.12× 仍保持清晰，避免低分辨率图片放大出现马赛克。
  /// 幂等保护同 [_requestCharGlowSprite]，异步回调用 [_spriteEpoch] 校验。
  void _requestCharImage(
    int wordIndex,
    int charIndex,
    String text,
    double fontSize,
  ) {
    final String key = '$wordIndex:$charIndex';
    if (_charImagePending.contains(key)) return;
    if (wordIndex < _charImages.length &&
        charIndex < _charImages[wordIndex].length &&
        _charImages[wordIndex][charIndex] != null) {
      return;
    }
    _charImagePending.add(key);
    final int epoch = _spriteEpoch;
    final double charH = fontSize * LyricLayout.lineHeight;
    if (text.isEmpty || charH <= 0) {
      _charImagePending.remove(key);
      return;
    }
    _renderCharImage(text, fontSize).then((image) {
      _charImagePending.remove(key);
      if (image == null) return;
      if (epoch != _spriteEpoch) {
        image.dispose();
        return;
      }
      if (wordIndex < _charImages.length &&
          charIndex < _charImages[wordIndex].length) {
        _charImages[wordIndex][charIndex]?.dispose();
        _charImages[wordIndex][charIndex] = image;
      }
    });
  }

  /// 字符图片超采样倍数：以 3× 分辨率渲染字形，绘制时缩放到原生尺寸，
  /// 波浪放大（最高 1.12×）仍保持清晰锐利。
  static const int _charImageSupersample = 3;

  /// 请求整词纯白字形图（异步一次，幂等）。
  ///
  /// 仅在 [_glyphBlitActive]（Windows + 开启上浮）时生效；图未就绪的帧由调用方
  /// 退回 TextPainter 绘制，视觉与改动前一致，不会出现空字。
  void _requestWordGlyph(int wordIndex, double rowHeight) {
    if (!_glyphBlitActive) return;
    if (wordIndex < 0 || wordIndex >= _wordGlyphImages.length) return;
    if (_wordGlyphPending.contains(wordIndex)) return;
    if (_wordGlyphImages[wordIndex] != null &&
        (_wordGlyphRowHeights[wordIndex] - rowHeight).abs() < 1e-6) {
      return;
    }
    final LyricLine? line = _boundLine;
    if (line == null || wordIndex >= line.words.length) return;
    final double fontSize = _boundFontSize;
    final double wordWidth =
        wordIndex < _wordWidths.length ? _wordWidths[wordIndex] : 0;
    if (fontSize <= 0 || wordWidth <= 0 || rowHeight <= 0) return;
    _wordGlyphPending.add(wordIndex);
    final int epoch = _wordGlyphEpoch;
    _renderWordGlyph(line.words[wordIndex].text, fontSize, rowHeight, wordWidth)
        .then((ui.Image? image) {
      _wordGlyphPending.remove(wordIndex);
      if (image == null) return;
      if (epoch != _wordGlyphEpoch) {
        image.dispose();
        return;
      }
      if (wordIndex < _wordGlyphImages.length) {
        _wordGlyphImages[wordIndex]?.dispose();
        _wordGlyphImages[wordIndex] = image;
        _wordGlyphRowHeights[wordIndex] = rowHeight;
      }
    });
  }

  /// 渲染整词纯白字形图（尺寸 = 词宽 × 行盒高 × 超采样倍数）。
  ///
  /// 用放大后的字号渲染而非 canvas 缩放：字形按超采样分辨率栅格化，
  /// 绘制时 drawImageRect 缩回原生尺寸 → 得到高质量降采样。
  Future<ui.Image?> _renderWordGlyph(
    String text,
    double fontSize,
    double rowHeight,
    double wordWidth,
  ) async {
    try {
      final double renderFontSize = fontSize * _wordGlyphSupersample;
      final TextPainter textPainter = TextPainter(textDirection: TextDirection.ltr)
        ..text = TextSpan(
          text: text,
          style: TextStyle(
            // 纯白字形：绘制时经 ColorFilter 上色为文字色 + alpha
            color: const Color.fromRGBO(255, 255, 255, 1.0),
            fontSize: renderFontSize,
            height: rowHeight,
            fontFamily: LyricLayout.fontFamily,
            fontWeight: LyricLayout.fontWeight,
          ),
        )
        ..layout();
      final int imgW = (wordWidth * _wordGlyphSupersample).ceil();
      final int imgH = (renderFontSize * rowHeight).ceil();
      if (imgW <= 0 || imgH <= 0) {
        textPainter.dispose();
        return null;
      }
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder);
      textPainter.paint(canvas, Offset.zero);
      textPainter.dispose();
      final ui.Picture picture = recorder.endRecording();
      final ui.Image image = await picture.toImage(imgW, imgH);
      // toImage 经 native 回调栅格化，future 完成后 Picture 才可安全释放。
      picture.dispose();
      return image;
    } catch (_) {
      return null;
    }
  }

  /// 用整词字形图绘制（分数 y 位移连续，不产生整像素台阶）。
  ///
  /// 返回 false 表示图未就绪 / 行盒不匹配 / 未启用，调用方退回文本绘制。
  bool _blitWordGlyph(
    Canvas canvas,
    int wordIndex,
    double wordX,
    double wordY,
    double width,
    double fontSize,
    double rowHeight,
  ) {
    if (!_glyphBlitActive) return false;
    if (wordIndex < 0 || wordIndex >= _wordGlyphImages.length) return false;
    final ui.Image? image = _wordGlyphImages[wordIndex];
    if (image == null) return false;
    if ((_wordGlyphRowHeights[wordIndex] - rowHeight).abs() > 1e-6) return false;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(wordX, wordY, width, fontSize * rowHeight),
      _wordGlyphPaint,
    );
    return true;
  }

  /// 字形图上色（文字色 + alpha），用于均匀性绘制路径。
  ColorFilter _wordGlyphTint(int r, int g, int b, double a) =>
      ColorFilter.matrix(<double>[
        r / 255,
        0,
        0,
        0,
        0,
        0,
        g / 255,
        0,
        0,
        0,
        0,
        0,
        b / 255,
        0,
        0,
        0,
        0,
        0,
        a,
        0,
      ]);

  /// 渲染单个字符的纯白字形图（异步，尺寸 = 字符宽 × 行高 × 超采样倍数）。
  Future<ui.Image?> _renderCharImage(String text, double fontSize) async {
    try {
      final double renderFontSize = fontSize * _charImageSupersample;
      final textPainter = TextPainter(textDirection: TextDirection.ltr)
        ..text = TextSpan(
          text: text,
          style: TextStyle(
            // 纯白字形：绘制时经 ColorFilter 上色为文字色 + mask alpha
            color: const Color.fromRGBO(255, 255, 255, 1.0),
            fontSize: renderFontSize,
            height: LyricLayout.lineHeight,
            fontFamily: LyricLayout.fontFamily,
            fontWeight: LyricLayout.fontWeight,
          ),
        )
        ..layout();
      final int imgW = textPainter.width.ceil();
      final int imgH = (renderFontSize * LyricLayout.lineHeight).ceil();
      if (imgW <= 0 || imgH <= 0) {
        textPainter.dispose();
        return null;
      }
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      textPainter.paint(canvas, Offset.zero);
      textPainter.dispose();
      final picture = recorder.endRecording();
      final image = await picture.toImage(imgW, imgH);
      // toImage 经 native 回调栅格化，future 完成后 Picture 不再被引用，此刻释放才安全。
      picture.dispose();
      return image;
    } catch (_) {
      return null;
    }
  }

  /// 临时调试：打印行换行分析（word 累加 vs TextPainter 行数），定位歌词重叠。
  void _debugLogWrap(
    LyricLine line,
    double fontSize,
    double maxWidth,
    LyricWrapPlan plan,
  ) {
    // 诊断日志仅在 debug 构建产出：layout + computeLineMetrics 有实打实的开销，
    // release 包不应为一条被丢弃的 print 付这笔账。
    if (!kDebugMode) return;
    final StringBuffer sb = StringBuffer();
    sb.write(
      '[LyricWrap] WR hasWord=${line.hasWordTiming} '
      'text="${line.text}" maxW=${maxWidth.toStringAsFixed(1)} fs=$fontSize',
    );
    if (line.hasWordTiming) {
      // 行数/断点来自换行计划（与 paintLine / measureLineHeight 同源）
      sb.write(' planRows=${plan.rowCount} starts=${plan.rowStarts}');
      // TextPainter 整行自动换行行数
      final TextPainter tp = TextPainter(
        text: TextSpan(
          text: line.text,
          style: TextStyle(
            fontSize: fontSize,
            height: LyricLayout.lineHeight,
            fontFamily: LyricLayout.fontFamily,
            fontWeight: LyricLayout.fontWeight,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: maxWidth);
      sb.write(' tpRows=${tp.computeLineMetrics().length}');
      tp.dispose();
      sb.write(' words[');
      for (int i = 0; i < line.words.length; i++) {
        sb.write(
          '"${line.words[i].text}"(${_wordWidths[i].toStringAsFixed(1)}) ',
        );
      }
      sb.write(']');
    }
    // ignore: avoid_print
    if (kDebugMode) print(sb.toString());
  }

  /// 检测 line 切换并重置 alpha map，同时测量并缓存所有 word 宽度。
  ///
  /// 若传入的 line 与当前绑定不是同一对象引用（[identical] 失败），
  /// 或 fontSize 变化，重新初始化每个 word 的 alpha 为 [dynamicDarkAlpha]，
  /// 并测量每个 word 的宽度缓存到 [_wordWidths]。
  ///
  /// **v4 性能优化**：
  /// - 用 per-word TextPainter 实例列表替代共享 _painter
  /// - word 宽度只在此时测量一次，paintLine 用缓存宽度做换行判断
  /// - _lastSetAlphas 在 line 切换时清空，强制下次 paintLine 重新 set text + layout
  void _ensureBound(LyricLine line, double fontSize) {
    final sameLine = identical(_boundLine, line);
    final sameFontSize = _boundFontSize == fontSize;
    final sameFontWeight =
        _boundFontWeight == LyricPreferences.instance.fontWeightValue;
    final sameLineHeight = _boundLineHeight == LyricLayout.lineHeight;
    if (sameLine &&
        sameFontSize &&
        sameFontWeight &&
        sameLineHeight &&
        _wordPainters.length == line.words.length) {
      return; // 缓存命中
    }
    _boundLine = line;
    _boundFontSize = fontSize;
    _boundFontWeight = LyricPreferences.instance.fontWeightValue;
    _boundLineHeight = LyricLayout.lineHeight;
    // 注意：_wordAlphas/_wordYOffsets/_lastSetAlphas 不能用 .clear()，
    // 因为它们可能被 const <T>[] 初始化（不可修改）。后面会直接重新赋值，无需 clear。

    // 行级元数据判定缓存：作词/作曲/编曲 等元数据行整行禁用辉光。
    // 仅依赖 line.text（行绑定后不变），此处计算一次，tick 中仅读取字段。
    _isMetadataLine = EmphasizeEffect.shouldSkipEmphasizeForLine(line);

    // 释放旧 per-word painter 与 per-char painter（line 缩短时避免泄漏）
    for (final painter in _wordPainters) {
      painter?.dispose();
    }
    for (final charList in _charPainters) {
      for (final p in charList) {
        p.dispose();
      }
    }

    final double dark = dynamicDarkAlpha;
    // P1-5：行绑定切换（切行/字号变化）时失效辉光精灵缓存——
    // 旧行的 word 文本/字号不同，精灵图不再匹配；异步渲染中的结果也丢弃。
    _spriteEpoch++;
    for (final charList in _charGlowSprites) {
      for (final img in charList) {
        img?.dispose();
      }
    }
    _glowSpritePendingRow.clear();
    _glowSpriteRowHeight.clear();
    // v7：释放旧行逐字符字形图
    for (final charList in _charImages) {
      for (final img in charList) {
        img?.dispose();
      }
    }
    _charImagePending.clear();
    // 整词字形图（Windows 上浮平滑）：行绑定切换即整体失效，代次 +1 丢弃在途结果
    _wordGlyphEpoch++;
    for (final ui.Image? img in _wordGlyphImages) {
      img?.dispose();
    }
    _wordGlyphPending.clear();
    // 测量所有 word 宽度并初始化 per-word / per-char TextPainter
    _wordWidths = List<double>.filled(line.words.length, 0);
    // v5：非强调字用整词 painter（槽位），强调字该槽位为 null（改用逐字符）
    _wordPainters = List<TextPainter?>.filled(line.words.length, null);
    // 预分配辉光判定缓存数组（与 _wordPainters 同长度同索引）
    _wordEmphasisFlags = List<bool>.filled(line.words.length, false);
    // 预计算 word 起始 X 坐标（避免每帧 O(n²) 循环累加）
    _wordStartXs = List<double>.filled(line.words.length, 0);
    // 预分配 alpha / Y offset / lastSetAlphas 数组
    _wordAlphas = List<double>.filled(line.words.length, dark);
    _wordYOffsets = List<double>.filled(line.words.length, 0);
    _lastSetAlphas = List<int>.filled(line.words.length, -2);
    // v5 逐字符缓存：仅强调字有内容
    _charPainters = List.generate(
      line.words.length,
      (_) => const <TextPainter>[],
    );
    _charWidths = List.generate(line.words.length, (_) => const <double>[]);
    _charStartXs = List.generate(line.words.length, (_) => const <double>[]);
    _lastSetCharAlphas = List.generate(line.words.length, (_) => const <int>[]);
    _emphasizeCharStates = List.generate(
      line.words.length,
      (_) => const <EmphasizeState>[],
    );
    _charGlowSprites = List.generate(
      line.words.length,
      (_) => const <ui.Image?>[],
    );
    // v7：逐字符纯白字形图缓存（仅强调字有内容）
    _charImages = List.generate(line.words.length, (_) => const <ui.Image?>[]);
    _charImagePending.clear();
    // 整词字形图：仅 Windows + 开启上浮时启用（见 [_glyphBlitActive] 说明）。
    // 平台用 defaultTargetPlatform 判定：flutter test 下为 android，测试保持
    // 原文本绘制路径，不被新路径影响。
    _glyphBlitActive =
        !debugDisableGlyphBlit &&
        defaultTargetPlatform == TargetPlatform.windows &&
        LyricPreferences.instance.liftHeightPx > 0.01;
    _wordGlyphImages = List<ui.Image?>.filled(line.words.length, null);
    _wordGlyphRowHeights = List<double>.filled(line.words.length, -1);
    // v8：行绑定切换时复位逐字波浪状态（锚定位置/推进按字；每字符相位在
    // 强调字构建时分配，见下方循环）
    _waveAnchorPosMs = List<double>.filled(line.words.length, -1);
    _waveAdvanceMs = List<double>.filled(line.words.length, 0);
    _waveBumpPhases = List.generate(line.words.length, (_) => const <double>[]);
    _waveFloatPhases = List.generate(
      line.words.length,
      (_) => const <double>[],
    );

    double accumWidth = 0;
    for (int i = 0; i < line.words.length; i++) {
      // 缓存该 word 的辉光判定结果（含正则匹配，仅在此执行一次）
      // tick 中通过 _wordEmphasisFlags[i] O(1) 读取，避免每帧重复正则匹配
      _wordEmphasisFlags[i] = EmphasizeEffect.shouldEmphasize(
        line.words[i],
        thresholdMs: thresholdMs,
      );
      // === 整词 painter：所有字都创建 ===
      // 强调字在 idle（未进入激活窗口）时走整词渲染路径（单次 layout/渐变），
      // 避免逐字符渲染的每帧开销导致卡顿；仅激活窗口内才切逐字符。
      _wordPainters[i] = TextPainter(textDirection: TextDirection.ltr)
        ..text = TextSpan(
          text: line.words[i].text,
          style: TextStyle(
            fontSize: fontSize,
            height: LyricLayout.lineHeight,
            // 显式注入歌词 fontFamily，必须与 paintLine 渲染路径一致，
            // 否则 word 宽度测量会出错导致换行错位
            fontFamily: LyricLayout.fontFamily,
            fontWeight: LyricLayout.fontWeight,
          ),
        )
        ..layout();
      _wordWidths[i] = _wordPainters[i]!.width;
      if (_wordEmphasisFlags[i]) {
        // === 强调字：额外拆成逐字符 TextPainter（仅激活窗口内使用） ===
        // 逐字符波浪需要每字符独立缩放/位移/辉光，整词 painter 无法实现。
        final List<int> runes = line.words[i].text.runes.toList();
        final int n = runes.length;
        final List<TextPainter> chars = List.generate(
          n,
          (_) => TextPainter(textDirection: TextDirection.ltr),
        );
        final List<double> widths = List<double>.filled(n, 0);
        final List<double> starts = List<double>.filled(n, 0);
        double charAccum = 0;
        for (int k = 0; k < n; k++) {
          final String charText = String.fromCharCode(runes[k]);
          chars[k].text = TextSpan(
            text: charText,
            style: TextStyle(
              // 初始纯白占位：首次绘制时均匀路径会用目标 alpha 重新 set text + layout
              color: const Color.fromRGBO(255, 255, 255, 1.0),
              fontSize: fontSize,
              height: LyricLayout.lineHeight,
              fontFamily: LyricLayout.fontFamily,
              fontWeight: LyricLayout.fontWeight,
            ),
          );
          chars[k].layout();
          widths[k] = chars[k].width;
          starts[k] = charAccum;
          charAccum += chars[k].width;
        }
        _charPainters[i] = chars;
        _charWidths[i] = widths;
        _charStartXs[i] = starts;
        _lastSetCharAlphas[i] = List<int>.filled(n, -2);
        _emphasizeCharStates[i] = List<EmphasizeState>.filled(
          n,
          EmphasizeState.idle,
        );
        _charGlowSprites[i] = List<ui.Image?>.filled(n, null);
        // v7：逐字符纯白字形图缓存（激活窗口内用图片变换绘制，避免文字重栅格化闪烁）
        _charImages[i] = List<ui.Image?>.filled(n, null);
        // v8：每字符波浪相位分配，初始 1.0（已完成=idle），字成为当前字时再锚定
        _waveBumpPhases[i] = List<double>.filled(n, 1.0);
        _waveFloatPhases[i] = List<double>.filled(n, 1.0);
        // P1 时序拆分：字形图与辉光精灵改为【懒预生成】——不再行绑定批量 toImage，
        // 而是在 tick 中检测"即将成为当前字的强调字"（提前 _imagePrewarmLeadMs）
        // 才请求，把行切换瞬间的一次性 N 个并发 toImage 分摊到各字激活前逐字生成，
        // 消除行切换时刻 raster/GPU 突发造成的掉帧。
      }
      _wordStartXs[i] = accumWidth;
      accumWidth += _wordWidths[i];
    }
    // 过渡区半宽固定为行内平均字宽（稳定，不随当前字变化，避免字切换闪烁）
    if (_wordWidths.isEmpty) {
      _transitionHalfWidth = 0;
    } else {
      double sum = 0;
      for (final w in _wordWidths) {
        sum += w;
      }
      _transitionHalfWidth = sum / _wordWidths.length;
    }
    // === sweep 模型：行内墨迹区间 + 推进路径（行绑定期构建一次，缓存复用）===
    // TextPainter.getBoxesForSelection 只在此处（行切换 / 字号 / 字重 / 行高变化）
    // 调用，paintLine 每帧只做 LyricSweepPath 的数值查询，0 次测量。
    _wordInkSpans = _buildWordInkSpans(line);
    _sweepPath = LyricSweepPath(_wordInkSpans);
    _sweepFront = 0;
  }

  /// 行绑定期构建每个 word 的行内墨迹区间（sweep 模型输入）。
  ///
  /// 用该 word 的 TextPainter `getBoxesForSelection` 求真实字形覆盖（相对
  /// painter 坐标），再加上 `wordStartX` 转成行内累计坐标；取所有 box 的并集。
  /// 拿不到 box（空文本 / 未布局 / 异常）时回退 advance 区间
  /// `[wordStartX, wordStartX + 宽度]`，保证 sweep 至少等价于「按字宽推进」。
  List<LyricInkSpan> _buildWordInkSpans(LyricLine line) {
    final List<LyricInkSpan> spans = List<LyricInkSpan>.filled(
      line.words.length,
      const LyricInkSpan(0, 0),
    );
    for (int i = 0; i < line.words.length; i++) {
      final double startX = i < _wordStartXs.length ? _wordStartXs[i] : 0;
      final double width = i < _wordWidths.length ? _wordWidths[i] : 0;
      final String text = line.words[i].text;
      double left = double.infinity;
      double right = double.negativeInfinity;
      final TextPainter? painter = i < _wordPainters.length
          ? _wordPainters[i]
          : null;
      if (painter != null && text.isNotEmpty) {
        try {
          final List<TextBox> boxes = painter.getBoxesForSelection(
            TextSelection(baseOffset: 0, extentOffset: text.length),
          );
          for (final TextBox box in boxes) {
            if (!box.left.isFinite || !box.right.isFinite) continue;
            if (box.right <= box.left) continue;
            if (box.left < left) left = box.left;
            if (box.right > right) right = box.right;
          }
        } catch (_) {
          // painter 未布局等异常：落回 advance 区间（下方分支）
        }
      }
      if (right > left) {
        spans[i] = LyricInkSpan(startX + left, startX + right);
      } else {
        spans[i] = LyricInkSpan(startX, startX + width);
      }
    }
    return spans;
  }

  /// 重置状态：清空 alpha map、Y 偏移、归零 progress、scale 回到 inactive、isActive=false、解绑 line。
  ///
  /// **v4 优化**：dispose 所有 per-word TextPainter 实例避免内存泄漏。
  void reset() {
    _isActive = false;
    _scale = LyricLayout.inactiveScale;
    _boundLine = null;
    _activeColorValue = null;
    _boundFontSize = -1;
    _boundFontWeight = -1;
    _boundLineHeight = -1;
    _wordWidths = const <double>[];
    _wordStartXs = const <double>[];
    _currentWordIdx = -1;
    _intraWordProgress = 0.0;
    _maskX = -1.0;
    _transitionHalfWidth = 0;
    // sweep 模型缓存一并复位（避免 reset 后残留上一行的墨迹路径）
    _wordInkSpans = const <LyricInkSpan>[];
    _sweepPath = null;
    _sweepFront = 0;
    // 清理辉光判定缓存
    _wordEmphasisFlags = const <bool>[];
    _isMetadataLine = false;
    // v4 优化：dispose per-word TextPainter 实例；v5 追加 per-char 实例
    for (final painter in _wordPainters) {
      painter?.dispose();
    }
    for (final charList in _charPainters) {
      for (final p in charList) {
        p.dispose();
      }
    }
    _wordPainters = const <TextPainter?>[];
    _wordAlphas = const <double>[];
    _wordYOffsets = const <double>[];
    _lastSetAlphas = const <int>[];
    // v5 逐字符缓存复位
    _emphasizeCharStates = const <List<EmphasizeState>>[];
    _charPainters = const <List<TextPainter>>[];
    _charWidths = const <List<double>>[];
    _charStartXs = const <List<double>>[];
    _lastSetCharAlphas = const <List<int>>[];
    // P1-5：reset 时失效辉光精灵缓存（dispose 图片 + 代数递增丢弃异步结果）
    _spriteEpoch++;
    for (final charList in _charGlowSprites) {
      for (final img in charList) {
        img?.dispose();
      }
    }
    _charGlowSprites = const <List<ui.Image?>>[];
    _glowSpritePendingRow.clear();
    _glowSpriteRowHeight.clear();
    // v7：释放逐字符字形图
    for (final charList in _charImages) {
      for (final img in charList) {
        img?.dispose();
      }
    }
    _charImages = const <List<ui.Image?>>[];
    _charImagePending.clear();
    // 整词字形图缓存（Windows 上浮平滑）
    for (final ui.Image? img in _wordGlyphImages) {
      img?.dispose();
    }
    _wordGlyphImages = const <ui.Image?>[];
    _wordGlyphRowHeights = const <double>[];
    _wordGlyphPending.clear();
    // v8：复位逐字波浪状态
    _waveAnchorPosMs = const <double>[];
    _waveAdvanceMs = const <double>[];
    _waveBumpPhases = const <List<double>>[];
    _waveFloatPhases = const <List<double>>[];
  }

  /// 最终释放渲染器；与可复用的 [reset] 不同，此后不再绘制。
  void dispose() {
    reset();
    _translationPainter.dispose();
  }
}
