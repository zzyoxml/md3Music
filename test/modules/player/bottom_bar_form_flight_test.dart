// 底栏形态交叉过渡（一级常驻条 ↔ 二级悬浮胶囊）的**飞行窗口回归测试**。
//
// 前身是 2026-10-11 会诊时 D4 写的临时探针 `zz_probe_bar_form_flight_test.dart`，
// 本文件把它的逐帧录制改成正式断言（用户报的「切页严重跳变」＝ 会诊结论
// D1~D4 的合体故障）：
//   ① 飞行窗口必须在**导航时刻**开跑、覆盖整段路由转场（D1/D3）：否则转场期间
//      p 贴旧端点，转场收敛后胶囊先让位、常驻条凭空长出再变回胶囊；
//   ② 胶囊端点必须是**解析的可见本体几何**（16 内缩 / 宽 −32），不是转场中
//      实时登记的宿主外框（D2/D4：实测交棒差 −81.9 / −114px，解析后 ≤2px）；
//   ③ 常驻条端点取导航前最后一次结算态登记值并在飞行期间冻结（D2/D4）；
//   ④ 没有导航事件的翻转（转屏 / tab 配置装载 / 不挂条子页）不得播幻影交棒（D3）。
//
// 驱动是 `_MainLayoutState` 的逐句复刻（**改动 app.dart 的形态驱动必须同步
// 这里**，与 `hide_navbar_secondary_chain_test.dart` 的复刻口径同族）；三级控件
// （MiniPlayer / SecondaryMiniPlayer / BottomBarMorphOverlay）、壳层
// （ResponsiveScaffold / ResponsiveShell / PrimaryPagePersistentBar）与登记簿
// 全部是生产实现，形态信号走 `ResponsiveShell.onPageRouteEvent` 的真实链路。
import 'dart:async' show Zone;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/rendering.dart' show RenderOffstage, RenderParagraph;
import 'package:flutter/scheduler.dart'
    show SchedulerBinding, SchedulerPhase;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/layout/page_title_alignment.dart';
import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/core/layout/responsive_shell.dart';
import 'package:md3music/core/services/desktop_lyric_service.dart';
import 'package:md3music/core/theme/motion_constants.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/player/bottom_bar_morph_overlay.dart';
import 'package:md3music/modules/player/mini_player.dart';
import 'package:md3music/modules/player/player_bar_progress_painter.dart';
import 'package:md3music/modules/player/secondary_mini_player.dart';
import 'package:md3music/providers/car_mode_provider.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/widgets/smart_artwork_image.dart';

class _FakePlayer extends PlayerProvider {
  @override
  Song? get currentSong => const Song(
    id: 's0',
    title: '标题',
    artist: 'artist',
    album: 'album',
    duration: Duration(seconds: 60),
  );

  @override
  bool get isPlaying => true;

  @override
  Duration? get duration => const Duration(seconds: 60);

  @override
  Duration get position => const Duration(seconds: 12);
}

/// 长标题（拉丁文含空格 ⇒ 断词/省略号截断都可能留出「行宽 < 盒宽」的余量）。
///
/// `TextAlign` 唯一可能被看见的场景就是这一种：文字盒满宽（`Expanded` 撑满）、
/// 行宽不满宽，对齐把整行字形搬动，而盒子矩形不变 —— 短文案时盒跟着行收缩，
/// 对齐是完全 inert 的。
const String _kLongTitle = 'A Very Long Song Title That Will Not Fit';
const String _kLongArtist = 'Some Artist Name That Is Also Quite Long';

class _LongTitlePlayer extends _FakePlayer {
  @override
  Song? get currentSong => const Song(
    id: 's0',
    title: _kLongTitle,
    artist: _kLongArtist,
    album: 'album',
    duration: Duration(seconds: 60),
  );
}

const Size _kPhonePortrait = Size(400, 869);

/// 横屏手机档（rail 布局：宽 ≥ compactBreakpoint=600 且非桌面壳）。
/// 真机横屏 push/pop 交棒的左缘留白（rail 保留宽）连续性用例在此尺寸下跑。
const Size _kPhoneLandscape = Size(869, 400);

/// 底部安全区（真机手势条）。测试默认 0，这里显式给 24 —— 与生产同量级
/// （会诊 D4：兜底口径漏 safeBottom 时真机正好差这一段）。
const double _kSafeBottom = 24.0;

/// harness 的 tab：借真实预设（`pinnedTitle: true` + 默认可见），让
/// `PrimaryPagePersistentBar` 的 `isPrimaryNavPage` 判据在真实
/// `TabConfigProvider` 下成立（常驻条真身必须在树里，端点才有登记值）。
const TabItem _kPinnedTab = TabItem(
  id: 'discover',
  label: '发现',
  pinnedTitle: true,
);

/// 非一级导航页（标题居中）：形态目标恒为胶囊，用来验证「tab 配置装载」这根线。
const TabItem _kUnpinnedTab = TabItem(id: 'charts', label: '排行榜');

void _setViewport(WidgetTester tester, Size logical) {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = Size(logical.width * 3, logical.height * 3);
  addTearDown(tester.view.reset);
}

/// 胶囊**可见本体**（32dp 圆角 Material），不是宿主外框。
final Finder _capsuleVisual = find.descendant(
  of: find.byType(SecondaryMiniPlayer),
  matching: find.byWidgetPredicate(
    (Widget w) => w is Material && w.borderRadius == BorderRadius.circular(32),
  ),
);

/// 浮层那根条的**外框**（最外层 ClipRRect；内层还有封面圆角层）。
final Finder _overlayBarBox = find
    .descendant(
      of: find.byType(BottomBarMorphOverlay),
      matching: find.byType(ClipRRect),
    )
    .first;

/// 浮层内容行里的文字块（生产浮层专有 key；在树 = 正在画那根条）。
final Finder _overlayBarText = find.descendant(
  of: find.byType(BottomBarMorphOverlay),
  matching: find.byKey(const ValueKey<String>('morph-bar-text')),
);

/// 浮层当前帧的**可见形变进度**（painter 的 `formT`；浮层未渲染时 null）。
///
/// K1 之后 `kBottomBarFormProgress`（窗口进度）与浮层几何驱动量（可见形变进度）
/// 是两个值：窗口整段铺满（≈740ms），可见形变前置到窗口开头 260ms 内走完
/// （见 `resolveVisibleBarFormProgress`）。测几何/内容一律读后者。
double? _overlayFormT(WidgetTester tester) {
  final f = find.descendant(
    of: find.byType(BottomBarMorphOverlay),
    matching: find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is PlayerBarProgressPainter,
    ),
  );
  if (f.evaluate().isEmpty) return null;
  return (tester.widget<CustomPaint>(f.first).painter as PlayerBarProgressPainter)
      .formT;
}

// ───────────────────────── 逐帧录制 ─────────────────────────

class _Frame {
  _Frame({
    required this.tag,
    required this.p,
    required this.residentRect,
    required this.capsuleRect,
    required this.overlayRect,
    required this.residentStandDown,
    required this.capsuleStandDown,
  });

  final String tag;
  final double p;

  /// 常驻条真身 render box（不在树 / 零尺寸时 null）。
  final Rect? residentRect;

  /// 胶囊**可见本体**矩形（不在树 / 零尺寸 / 让位时 null）。
  final Rect? capsuleRect;

  /// 浮层那根条的矩形（未渲染时 null）。
  final Rect? overlayRect;

  /// 让位态（祖先链上有 `offstage: true` 的 `RenderOffstage`）。
  ///
  /// 让位从 `SizedBox.shrink()`（卸载子树）改成 `Offstage`（保挂载、不绘制）之后，
  /// 真身**仍在树上且照常布局** —— 内层 Finder 量得到非零尺寸，「在树」不再等于
  /// 「在画」。故「是否在画」必须看这个标志（= 不绘制、不命中、不占位）。
  final bool residentStandDown;
  final bool capsuleStandDown;

  bool get residentDrawn => residentRect != null && !residentStandDown;
  bool get capsuleDrawn => capsuleRect != null && !capsuleStandDown;
  bool get overlayDrawn => overlayRect != null;
  bool get windowOpen => p > 0.0 && p < 1.0;

  @override
  String toString() =>
      '$tag p=${p.toStringAsFixed(3)} '
      'resident=${_fmt(residentRect)}${residentStandDown ? '(让位)' : ''} '
      'capsule=${_fmt(capsuleRect)}${capsuleStandDown ? '(让位)' : ''} '
      'overlay=${_fmt(overlayRect)}';

  static String _fmt(Rect? r) => r == null
      ? '无'
      : '(${r.left.toStringAsFixed(1)},${r.top.toStringAsFixed(1)} '
            '${r.width.toStringAsFixed(1)}×${r.height.toStringAsFixed(1)})';
}

Rect? _rectOf(WidgetTester tester, Finder finder) {
  if (finder.evaluate().isEmpty) return null;
  // `Offstage(offstage: true)` 的盒子对父级报 `constraints.smallest`（常常是
  // 全宽 × 0 高），零面积即「不占位」；真身与浮层都不存在零面积的正常态。
  if (tester.getSize(finder.first).isEmpty) return null;
  return tester.getRect(finder.first);
}

/// Finder 命中的元素是否处在「让位」态：祖先链上有 `offstage == true` 的
/// `RenderOffstage`。
bool _standsDown(Finder finder) {
  if (finder.evaluate().isEmpty) return false;
  RenderObject? ro = finder.evaluate().first.renderObject;
  while (ro != null) {
    if (ro is RenderOffstage && ro.offstage) return true;
    ro = ro.parent;
  }
  return false;
}

_Frame _record(WidgetTester tester, String tag) {
  final double p = kBottomBarFormProgress.value;
  // 浮层在窗口内且当前有歌才渲染；本测试恒有歌，故「文本块在树」= 正在画。
  final bool overlayOn = _overlayBarText.evaluate().isNotEmpty;
  return _Frame(
    tag: tag,
    p: p,
    residentRect: _rectOf(tester, find.byType(MiniPlayer)),
    capsuleRect: _rectOf(tester, _capsuleVisual),
    overlayRect: overlayOn ? _rectOf(tester, _overlayBarBox) : null,
    residentStandDown: _standsDown(find.byType(MiniPlayer)),
    capsuleStandDown: _standsDown(_capsuleVisual),
  );
}

void _dump(List<_Frame> frames) {
  for (final f in frames) {
    debugPrint(f.toString());
  }
}

// ───────────── H1：让位保挂载 / 残留 3：文字对齐的读数助手 ─────────────

/// 常驻条真身封面。
///
/// **`skipOffstage: false` 是关键**：Finder 默认跳过 `Offstage` 子树，而本组
/// 用例要证的恰恰是「子树在让位期**仍在树上**（保挂载）」，必须看不跳过的树。
Finder _residentCover() => find.descendant(
  of: find.byType(MiniPlayer, skipOffstage: false),
  matching: find.byType(SmartArtworkImage, skipOffstage: false),
  skipOffstage: false,
);

/// 胶囊真身封面。
Finder _capsuleCover() => find.descendant(
  of: find.byType(SecondaryMiniPlayer, skipOffstage: false),
  matching: find.byType(SmartArtworkImage, skipOffstage: false),
  skipOffstage: false,
);

/// 某根条（[MiniPlayer] / [SecondaryMiniPlayer]）的**外壳**：该条最外层的
/// `ValueListenableBuilder<double>`，且 `valueListenable` 恒为全局
/// [kBottomBarFormProgress]。
///
/// 该 widget 实例只在外层 State 重建时换新（`Element.updateChild` 见新实例才
/// 建新的 `child:`），故「窗口内不同外壳实例数」= 外层 State 重建次数 + 1 =
/// 条体被换新实例的次数 —— 本次省帧（条体移入 `child:`）要钉的量。
/// `skipOffstage: false` 同 [_residentCover]：让位期子树仍在树上；作用域限定在
/// 该条内，不会误取形态交叉过渡浮层的同款 VLB。
Finder _barFormShell(Type barType) => find.descendant(
  of: find.byType(barType, skipOffstage: false),
  matching: find.byWidgetPredicate(
    (Widget w) =>
        w is ValueListenableBuilder<double> &&
        identical(w.valueListenable, kBottomBarFormProgress),
    skipOffstage: false,
  ),
  skipOffstage: false,
);

/// [长标题][_kLongTitle] 在某一根条里**首字符字形**的屏幕 x。
///
/// 盒子矩形测不出 `TextAlign`：文字盒满宽时对齐只搬字形、不动盒，故必须读
/// 段落的字形盒（`RenderParagraph.getBoxesForSelection` 是公开 API）。
double _titleGlyphLeft(WidgetTester tester, Finder scope) {
  final f = find.descendant(of: scope, matching: find.text(_kLongTitle));
  expect(f, findsWidgets, reason: '该条必须画着长标题');
  final para = tester.renderObject<RenderParagraph>(f.first);
  final boxes = para.getBoxesForSelection(
    const TextSelection(baseOffset: 0, extentOffset: 1),
  );
  expect(boxes, isNotEmpty, reason: '标题必须有可测字形');
  return tester.getTopLeft(f.first).dx + boxes.first.left;
}

/// 可见形变曲线（[M3ExpressiveMotion.barFormMorphEasing]）的最大斜率（数值）。
///
/// 用于把「逐帧自然位移」与「硬切台阶」分开：可见形变把全程位移压进窗口开头的
/// `kBarFormVisibleMorphDuration`，逐帧位移上界 = 全程位移 × 本斜率 × 帧间隔/260ms。
///
/// **必须用中心差分（δ = 1/100）**：`Cubic.transform` 内部是误差界 1e-3 的二分
/// 求解，δ 取太小（如 1/4000）时差分会被求解噪声淹没 —— 实测会把最大斜率从
/// ≈4 抬到 ≈23，上界随之虚高成 17px（硬切台阶就测不出来了）。
double _maxBarFormCurveSlope() {
  const Curve curve = M3ExpressiveMotion.barFormMorphEasing;
  const double delta = 0.01;
  var maxSlope = 0.0;
  for (var i = 0; i <= 100; i++) {
    final double u = i / 100;
    final double lo = (u - delta).clamp(0.0, 1.0);
    final double hi = (u + delta).clamp(0.0, 1.0);
    if (hi - lo < 1e-9) continue;
    final double slope = (curve.transform(hi) - curve.transform(lo)) / (hi - lo);
    if (slope > maxSlope) maxSlope = slope;
  }
  return maxSlope;
}

/// 交棒差：两端几何逐项取差的绝对值最大值（左缘 / 顶端 / 宽度）。
///
/// 高度不参与：常驻条真身 box 含底部净空（随底栏恢复收敛），交棒瞬间残留
/// 不足 1px（底栏收起曲线末端速度趋零），比较顶端即等价口径。
double _handoffDiff(Rect a, Rect b) => <double>[
  (a.left - b.left).abs(),
  (a.top - b.top).abs(),
  (a.width - b.width).abs(),
].reduce((x, y) => x > y ? x : y);

/// 一根条「已播放段」沿中心线的弧长（px）= `activeEnd − activeStart`。
///
/// 两真身的**已播放段口径不同**（这是本组用例对账的核心）：
/// - 常驻条（`mini_player.dart:908-924`，formT=0）= M3E determinate 的
///   `clamp(progress × size.width, capOffset, width − capOffset)` 前缀；
/// - 胶囊（`secondary_mini_player.dart:1664-1669`，formT=1）= `metric.length × p` 前缀。
/// 浮层（"同一根条"）两端都必须与它们逐值等价、中途连续 —— 一律用**同一套几何
/// 解算**（[resolveBarProgressGeometry]）取弧长，避免各写一份口径。
double _playedArc(
  Rect box, {
  required double formT,
  required double cornerRadius,
  required double progress,
  double gapSize = 0.0,
}) {
  final geo = resolveBarProgressGeometry(
    size: box.size,
    formT: formT,
    cornerRadius: cornerRadius,
    progress: progress,
    gapSize: gapSize,
  );
  return geo.activeEnd - geo.activeStart;
}

// ───────────────────────── 内容层探针（G1：端点内容等价） ─────────────────────────
//
// 四条用户报障（进度值 / 封面 / 文字对齐在交棒瞬间不一致）都是**内容层**差异，
// 几何 + 挡位测不出；这里逐帧读每一根在画的条的内容读数，对交棒两端直接对账。

/// 某一帧里一根条的内容层读数（该条未渲染时字段为 null）。
class _BodyContent {
  const _BodyContent({
    required this.p,
    required this.barRect,
    this.progress,
    this.progressBoxRect,
    this.coverRect,
    this.coverSizeParam,
    this.titleRect,
    this.artistRect,
  });

  final double p;

  /// 该条的盒（浮层 = 外框 ClipRRect；常驻条 = 自身 box；胶囊 = 可见本体）。
  final Rect? barRect;

  /// 进度 painter（浮层 / 常驻条用同一个 `PlayerBarProgressPainter`）。
  final PlayerBarProgressPainter? progress;

  /// 进度 CustomPaint 的盒。
  final Rect? progressBoxRect;

  /// 封面 `SmartArtworkImage` 实测矩形（含 FittedBox/Transform 缩放）。
  final Rect? coverRect;

  /// 封面解码尺寸参数（= `SmartArtworkImage.size`，参与 `cacheWidth` 与
  /// ImageCache key 的那一档）。
  final double? coverSizeParam;

  final Rect? titleRect;
  final Rect? artistRect;

  bool get drawn => coverRect != null;
}

_BodyContent _measureBody(
  WidgetTester tester,
  Finder scope,
  Finder barBox,
) {
  Rect? r(Finder f) {
    // `.first` 系 Finder 在父集为空时 evaluate 自身会抛（Bad state: No element），
    // 这里要表达的是「该子件不在树 = null」，故兜住。
    try {
      if (f.evaluate().isEmpty) return null;
      return tester.getRect(f.first);
    } catch (_) {
      return null;
    }
  }

  final cover = find.descendant(
    of: scope,
    matching: find.byType(SmartArtworkImage),
  );
  final title = find.descendant(of: scope, matching: find.text('标题'));
  final artist = find.descendant(of: scope, matching: find.text('artist'));
  final progressPaint = find.descendant(
    of: scope,
    matching: find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is PlayerBarProgressPainter,
    ),
  );
  return _BodyContent(
    p: kBottomBarFormProgress.value,
    barRect: r(barBox),
    progress: progressPaint.evaluate().isEmpty
        ? null
        : (tester.widget<CustomPaint>(progressPaint.first).painter
              as PlayerBarProgressPainter),
    progressBoxRect: r(progressPaint),
    coverRect: r(cover),
    coverSizeParam: cover.evaluate().isEmpty
        ? null
        : tester.widget<SmartArtworkImage>(cover.first).size,
    titleRect: r(title),
    artistRect: r(artist),
  );
}

/// 三种渲染器（浮层 / 常驻条 / 胶囊）在**当前帧**各自画的内容（未画 = 空壳）。
({_BodyContent overlay, _BodyContent resident, _BodyContent capsule})
_snapContent(WidgetTester tester) => (
  overlay: _measureBody(
    tester,
    find.byType(BottomBarMorphOverlay),
    _overlayBarBox,
  ),
  resident: _measureBody(tester, find.byType(MiniPlayer), find.byType(MiniPlayer)),
  capsule: _measureBody(
    tester,
    find.byType(SecondaryMiniPlayer),
    _capsuleVisual,
  ),
);

String _fmtR(Rect? r) => r == null
    ? '无'
    : '(${r.left.toStringAsFixed(2)},${r.top.toStringAsFixed(2)} '
          '${r.width.toStringAsFixed(2)}×${r.height.toStringAsFixed(2)})';

// ───────────────────────── 驱动复刻（_MainLayoutState） ─────────────────────────

class _FlightHost extends StatefulWidget {
  const _FlightHost({
    super.key,
    required this.player,
    required this.carMode,
    this.railLayout = false,
  });

  final PlayerProvider player;
  final CarModeProvider carMode;

  /// 横屏 rail 布局档位：镜像生产 `_barFormNavWillToggle` 的
  /// `usesNavigationRail(width)` 读数（harness 不真建 ResponsiveScaffold，
  /// 用旗标代替 MediaQuery 宽度判定）。
  final bool railLayout;

  @override
  State<_FlightHost> createState() => _FlightHostState();
}

class _FlightHostState extends State<_FlightHost> with TickerProviderStateMixin {
  final GlobalKey<ResponsiveShellState> _shellKey =
      GlobalKey<ResponsiveShellState>();

  List<TabItem> _tabs = const <TabItem>[_kPinnedTab];
  final int _selectedIndex = 0;

  /// 推迟上报的二级态（对应生产 `_secondaryPageOnTop`，只喂 hideNavigation）。
  bool _secondaryPageOnTop = false;

  /// 导航时刻的形态事实（对应生产 `_formSecondaryOnTop`）。
  bool _formSecondaryOnTop = false;
  int _lastSyncedTabIndex = 0;

  late final AnimationController _barFormController;
  late final CurvedAnimation _barFormCurve;
  bool _barFormTargetIsCapsule = false;

  /// 最近一次导航交棒的窗口顺延判据与飞行时长（横屏用例断言用）。
  bool lastNavWillToggle = false;
  Duration? lastFlightDuration;
  Duration lastFlightTransition = Duration.zero;

  // ── 生产同名：壳层可见性（被不透明路由盖住 = 整棵子树 ticker 静音）──
  // 交棒窗口只能由动画状态事件关闭，静音时事件永不产生 → 浮层残条永不消失。
  // 生产走 TickerMode.getValuesNotifier；本复刻同样走它——**不能**用
  // `isAnimating` 顶替判据：静音只是不回调，isActive 仍为 true。
  ValueListenable<TickerModeData>? _tickerModeNotifier;

  bool get _shellVisible => _tickerModeNotifier?.value.enabled ?? true;

  void _listenShellVisibility() {
    final ValueListenable<TickerModeData> next = TickerMode.getValuesNotifier(
      context,
    );
    if (identical(next, _tickerModeNotifier)) return;
    _tickerModeNotifier?.removeListener(_onTickerModeChanged);
    next.addListener(_onTickerModeChanged);
    _tickerModeNotifier = next;
  }

  void _onTickerModeChanged() {
    if (!mounted) return;
    if (_shellVisible) return;
    if (kBarFormFlightActive.value) _snapBarFormToTarget();
  }

  @override
  void initState() {
    super.initState();
    // 生产：kSecondaryPlayerEnabled=true, kSecondaryPlayerOnPrimaryPages=false。
    kSecondaryPlayerEnabled.value = true;
    kSecondaryPlayerOnPrimaryPages.value = false;
    _barFormTargetIsCapsule = _resolveBarFormTargetIsCapsule();
    kBarFormFlightActive.value = false;
    kBarFormResidentIsSource.value = !_barFormTargetIsCapsule;
    _lastSyncedTabIndex = _selectedIndex;
    _barFormController = AnimationController(
      vsync: this,
      duration: kBottomChromeToggleDuration,
      value: _barFormTargetIsCapsule ? 1.0 : 0.0,
    );
    _barFormCurve = CurvedAnimation(
      parent: _barFormController,
      curve: M3ExpressiveMotion.panelCollapseEasing,
      reverseCurve: M3ExpressiveMotion.panelExpandEasing,
    );
    _barFormController.addListener(_publish);
    _barFormController.addStatusListener(_onStatusChanged);
    kSecondaryPlayerEnabled.addListener(_onSettingChanged);
    kSecondaryPlayerOnPrimaryPages.addListener(_onSettingChanged);
    _publish();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 与生产 _MainLayoutState.didChangeDependencies 同款：订阅壳层可见性。
    _listenShellVisibility();
  }

  @override
  void dispose() {
    _tickerModeNotifier?.removeListener(_onTickerModeChanged);
    _tickerModeNotifier = null;
    kSecondaryPlayerEnabled.removeListener(_onSettingChanged);
    kSecondaryPlayerOnPrimaryPages.removeListener(_onSettingChanged);
    _barFormController.removeStatusListener(_onStatusChanged);
    _barFormController.removeListener(_publish);
    _barFormController.dispose();
    super.dispose();
  }

  void _publish() {
    kBottomBarFormProgress.value = _barFormCurve.value;
  }

  // ── 以下 _sync* / _start* / _snap* / _verify* 与 app.dart 同名方法逐句对照 ──

  bool _resolveBarFormTargetIsCapsule() {
    final tabs = _tabs;
    final tab = tabs.isEmpty
        ? null
        : tabs[_selectedIndex.clamp(0, tabs.length - 1)];
    return resolveBottomBarFormTarget(
          floatingEnabled: kSecondaryPlayerEnabled.value,
          onPrimaryPages: kSecondaryPlayerOnPrimaryPages.value,
          pageIsPrimaryNav: isPrimaryNavTab(
            tab,
            pushedRoute: _formSecondaryOnTop,
          ),
        ) >=
        0.5;
  }

  void _onPageRouteEvent(
    bool hasPushedPage,
    Route<dynamic> route,
    Duration transition,
  ) {
    if (!mounted) return;
    // 与生产同款：只有真正改变二级事实的路由事件才算导航（新建 tab 的 Navigator
    // 首路由、pushReplacement 一律 ambient 吸附）。
    final bool factChanged = hasPushedPage != _formSecondaryOnTop;
    _formSecondaryOnTop = hasPushedPage;
    if (!factChanged) {
      _syncBarFormTarget(cause: BarFormFlipCause.ambient);
      return;
    }
    _syncBarFormTarget(
      cause: BarFormFlipCause.navigation,
      transition: transition,
      navRoute: route,
    );
  }

  void _onSettingChanged() {
    _syncBarFormTarget(cause: BarFormFlipCause.settingsToggle);
  }

  void _syncBarFormTarget({
    BarFormFlipCause? cause,
    Duration? transition,
    Route<dynamic>? navRoute,
  }) {
    if (!mounted) return;
    final int tabIndex = _selectedIndex;
    final bool tabChanged = tabIndex != _lastSyncedTabIndex;
    _lastSyncedTabIndex = tabIndex;
    final resolvedCause =
        cause ??
        (tabChanged ? BarFormFlipCause.tabSwitch : BarFormFlipCause.ambient);
    if (tabChanged) {
      // 切 tab 后形态事实换成新 tab 的中央栈（与生产 app.dart 同口径）。
      _formSecondaryOnTop =
          _shellKey.currentState?.currentTabHasPushedPage() ?? false;
    }
    final target = _resolveBarFormTargetIsCapsule();
    if (target == _barFormTargetIsCapsule) return;
    _barFormTargetIsCapsule = target;
    switch (resolvedCause) {
      case BarFormFlipCause.navigation:
        final navWillToggle = _barFormNavWillToggle();
        final duration = resolveMorphFlightDuration(
          transition: transition ?? Duration.zero,
          navWillToggle: navWillToggle,
        );
        // 观测锚点（横屏窗口顺延用例断言用）：记录本次飞行的顺延判据与时长。
        lastNavWillToggle = navWillToggle;
        lastFlightDuration = duration;
        lastFlightTransition = transition ?? Duration.zero;
        if (target) {
          _driveBarFormFlight(
            duration,
            capsuleNavHiddenAtSettle: kHideNavBarOnSecondaryPages.value,
          );
          _verifyPushedPageHasCapsule(navRoute);
        } else {
          if (!BottomBarMorphRegistry.instance.hasCapsuleForRoute(navRoute)) {
            _snapBarFormToTarget();
            return;
          }
          _driveBarFormFlight(
            duration,
            capsuleNavHiddenAtSettle: kHideNavBarOnSecondaryPages.value,
          );
        }
      case BarFormFlipCause.settingsToggle:
      case BarFormFlipCause.tabSwitch:
        _driveBarFormFlight(
          kBottomChromeToggleDuration,
          capsuleNavHiddenAtSettle: false,
        );
      case BarFormFlipCause.ambient:
        _snapBarFormToTarget();
    }
  }

  // ── 生产同名：窗口顺延判据（横屏 rail 分支与 app.dart 逐句对照）──
  // 横屏 rail 的收起已是 260ms 逐帧动画且恒随二级页翻转（不受
  // kHideNavBarOnSecondaryPages 门控），与竖屏底栏同口径顺延。
  bool _barFormNavWillToggle() {
    if (widget.railLayout) {
      return _formSecondaryOnTop != _secondaryPageOnTop;
    }
    return (_formSecondaryOnTop && kHideNavBarOnSecondaryPages.value) !=
        (_secondaryPageOnTop && kHideNavBarOnSecondaryPages.value);
  }

  /// 生产同名：交棒飞行的唯一入口——**动画跑不起来就吸附**，不开窗。
  /// 两种跑不起来的情形：壳层被盖住（ticker 静音，状态事件永不产生）、
  /// 控制器已停在目标端点（`forward()` 零时长分支不重复上报同一状态）。
  void _driveBarFormFlight(
    Duration duration, {
    required bool capsuleNavHiddenAtSettle,
  }) {
    final double target = _barFormTargetIsCapsule ? 1.0 : 0.0;
    final bool alreadyAtTarget =
        !_barFormController.isAnimating && _barFormController.value == target;
    if (!_shellVisible || alreadyAtTarget) {
      _snapBarFormToTarget();
      return;
    }
    _startBarFormFlight(
      duration,
      capsuleNavHiddenAtSettle: capsuleNavHiddenAtSettle,
    );
  }

  void _startBarFormFlight(
    Duration duration, {
    required bool capsuleNavHiddenAtSettle,
  }) {
    BottomBarMorphRegistry.instance.freezeResidentRectForFlight(
      capsuleNavHiddenAtSettle: capsuleNavHiddenAtSettle,
    );
    _barFormController.duration = duration;
    if (_barFormTargetIsCapsule) {
      _barFormController.forward();
    } else {
      _barFormController.reverse();
    }
    kBarFormResidentIsSource.value = _barFormTargetIsCapsule;
    kBarFormFlightActive.value = true;
    // 生产同名兜底看门狗：两帧后窗口仍开而动画没在跑 → 吸附收窗。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!kBarFormFlightActive.value) return;
        if (_barFormController.isAnimating) return;
        _snapBarFormToTarget();
      });
    });
  }

  void _snapBarFormToTarget() {
    _barFormController.stop();
    BottomBarMorphRegistry.instance.clearFrozenResidentRect();
    void apply() {
      if (!mounted) return;
      kBarFormFlightActive.value = false;
      _barFormController.value = _barFormTargetIsCapsule ? 1.0 : 0.0;
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
  }

  void _onStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      kBarFormFlightActive.value = false;
      BottomBarMorphRegistry.instance.clearFrozenResidentRect();
    }
  }

  void _verifyPushedPageHasCapsule(Route<dynamic>? route) {
    if (route == null) return;
    var attempts = 0;
    void check() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_barFormTargetIsCapsule) return;
        if (BottomBarMorphRegistry.instance.hasCapsuleForRoute(route)) return;
        if (attempts++ == 0) {
          check();
          return;
        }
        _snapBarFormToTarget();
      });
    }

    check();
  }

  // ── 测试钩子（同文件私有类，供幻影用例直接改输入） ──

  void debugSetTabs(List<TabItem> tabs) {
    setState(() => _tabs = tabs);
  }

  /// 推迟上报的二级态（转屏 / 详情面板几何翻转的等价输入；生产由 shell 上报）。
  void debugSetSecondaryReport(bool secondary) {
    setState(() => _secondaryPageOnTop = secondary);
  }

  /// 生产同款：shell 的推迟上报直接落成 hideNavigation 的输入（底栏收起/恢复）。
  void _onSecondaryReport(bool secondary) {
    if (!mounted || _secondaryPageOnTop == secondary) return;
    setState(() => _secondaryPageOnTop = secondary);
  }

  @override
  Widget build(BuildContext context) {
    // 生产 _MainLayoutState.build 帧末统一重算目标（幂等；切 tab 走 tabSwitch，
    // 其余顺带重算一律 ambient 吸附 —— 见 _syncBarFormTarget）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncBarFormTarget();
    });
    final String currentTabId = _tabs.isEmpty
        ? 'discover'
        : _tabs[_selectedIndex.clamp(0, _tabs.length - 1)].id;
    return ResponsiveScaffold(
      destinations: const <NavigationDestination>[
        NavigationDestination(icon: Icon(Icons.explore_outlined), label: '发现'),
        NavigationDestination(icon: Icon(Icons.bar_chart), label: '排行榜'),
      ],
      railDestinations: const <NavigationRailDestination>[
        NavigationRailDestination(
          icon: Icon(Icons.explore_outlined),
          label: Text('发现'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.bar_chart),
          label: Text('排行榜'),
        ),
      ],
      drawerDestinations: const <NavigationDrawerDestination>[],
      selectedIndex: _selectedIndex,
      onDestinationSelected: (_) {},
      // 与生产 app.dart 的组合式一致：底栏收起/侧栏收起只跟推迟上报的
      // _secondaryPageOnTop 走，形态交棒与它解耦。
      hideNavigation: _secondaryPageOnTop && kHideNavBarOnSecondaryPages.value,
      hideRailNavigation: _secondaryPageOnTop,
      body: SecondaryMiniPlayerHost(
        ownsBottomBar: true,
        tabId: currentTabId,
        child: ResponsiveShell(
          key: _shellKey,
          visibleTabs: _tabs,
          selectedIndex: _selectedIndex,
          pageBuilder: (_) => const _LevelOnePage(),
          persistentBarBuilder: (tabId) =>
              PrimaryPagePersistentBar(tabId: tabId),
          // 与生产同一条推迟上报：底栏收起/侧栏收起跟随它，形态交棒与它解耦。
          onSecondaryRouteChanged: _onSecondaryReport,
          onPageRouteEvent: _onPageRouteEvent,
        ),
      ),
    );
  }
}

/// 一级页面：两个 push 入口（挂条 / 不挂条）。常驻条由 `ResponsiveShell` 的
/// `persistentBarBuilder`（PrimaryPagePersistentBar）挂在内容列底部，
/// 真身 MiniPlayer 与生产同构。
class _LevelOnePage extends StatelessWidget {
  const _LevelOnePage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FilledButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const _LevelTwoPage()),
              ),
              child: const Text('push'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const _BarlessPage()),
              ),
              child: const Text('push-barless'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 二级页面：生产形态 = 页面自包裹 SecondaryMiniPlayerHost（pushed → 胶囊）。
class _LevelTwoPage extends StatelessWidget {
  const _LevelTwoPage();

  @override
  Widget build(BuildContext context) {
    return SecondaryMiniPlayerHost(
      tabId: 'discover',
      child: Scaffold(
        backgroundColor: const Color(0xFF303030),
        body: Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('back'),
          ),
        ),
      ),
    );
  }
}

/// 不挂播放条的二级页（设置子页形态）：没有宿主、没有胶囊。
class _BarlessPage extends StatelessWidget {
  const _BarlessPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF303030),
      body: Center(
        child: TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('back'),
        ),
      ),
    );
  }
}

// ───────────────────────── 用例 ─────────────────────────

/// 在 FakeAsync 时区**外**预热桌面歌词单例。
///
/// `DesktopLyricService` 的构造器会启动 5s 周期巡检 Timer
/// （`_startNativeSyncProbe`），它在哪个用例的 FakeAsync 区内首次被构造，那个
/// 用例收尾就会被判「A Timer is still pending」。整文件跑时由首个用例（push，
/// 基线存量失败，勿动）吸收；单独跑横屏组时则会落在新用例上。这里把首次构造
/// 挪到根 Zone（真实 Timer 不参与用例收尾的 pending 检查），只给需要单独可跑
/// 的横屏用例调用 —— 整文件跑时单例已存在，本调用是空操作，既有失败集合不变。
void _prewarmDesktopLyricServiceOutsideFakeAsync() {
  Zone.root.run<void>(() => DesktopLyricService.instance);
}

void main() {
  late _FakePlayer player;
  late CarModeProvider carMode;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    kBottomBarFormProgress.value = 0.0;
    kSecondaryPlayerEnabled.value = true;
    kSecondaryPlayerOnPrimaryPages.value = false;
    kHideNavBarOnSecondaryPages.value = true;
    kBarFormFlightActive.value = false;
    kBarFormResidentIsSource.value = true;
    // 双栏开关三端通用后，discover tab 的双栏形态需显式开启（生产播种 true）。
    kWindowsTwoPaneEnabled.value = true;
    BottomBarMorphRegistry.instance.clearFrozenResidentRect();
    player = _FakePlayer();
    // 生产不变量：`_updatePosition` 把 `_position` 与 `positionNotifier` 一起写
    // （player_provider.dart:733-738），两者永远同值。假播放器只覆写 `position`
    // getter，不写 notifier 会让常驻条（读 notifier）与浮层（读 position）
    // 在测试里天然不同值 —— 那是 harness 不变量失真，不是被测行为。
    player.positionNotifier.value = player.position;
    carMode = CarModeProvider();
  });

  tearDown(() {
    kBottomBarFormProgress.value = 0.0;
    kSecondaryPlayerEnabled.value = true;
    kSecondaryPlayerOnPrimaryPages.value = true;
    kHideNavBarOnSecondaryPages.value = true;
    kBarFormFlightActive.value = false;
    kBarFormResidentIsSource.value = true;
    kWindowsTwoPaneEnabled.value = false;
    player.dispose();
    carMode.dispose();
  });

  /// 启动 harness 并稳定（tab 配置装载、导航栏就位），返回 host State 句柄。
  ///
  /// [playerOverride] 供「文字盒是否满宽」一类需要**特定文案**（长标题会被
  /// 省略号截断）的用例换一个假播放器；不传即用本组默认的那份。
  Future<GlobalKey<_FlightHostState>> pumpHost(
    WidgetTester tester, {
    PlayerProvider? playerOverride,
    bool tickerEnabled = true,
    bool railLayout = false,
    Size size = _kPhonePortrait,
  }) async {
    final activePlayer = playerOverride ?? player;
    _setViewport(tester, size);
    final key = GlobalKey<_FlightHostState>();
    final Widget shell = _FlightHost(
      key: key,
      player: player,
      carMode: carMode,
      railLayout: railLayout,
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: <SingleChildWidget>[
          ChangeNotifierProvider<PlayerProvider>.value(value: activePlayer),
          ChangeNotifierProvider<CarModeProvider>.value(value: carMode),
          ChangeNotifierProvider<DeviceProvider>(create: (_) => DeviceProvider()),
          ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
          ChangeNotifierProvider<TabConfigProvider>(
            create: (_) => TabConfigProvider(),
          ),
        ],
        child: MaterialApp(
          // MediaQuery 同生产量级：屏 400×869、底部安全区 24（设计像素）。
          // 浮层与壳层同栈（仍是「浮层在 tab Navigator 之上、壳层之外」的
          // 生产层序）；生产把这一栈挂在 MaterialApp.builder（Navigator 之上），
          // 测试放进 home 是因为 **Navigator 之上没有 Overlay 祖先**时浮层里
          // 的 Tooltip 会断言（W5 遗留的 debug-only 问题，不在本回归范围）。
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              viewPadding: EdgeInsets.only(bottom: _kSafeBottom),
              padding: EdgeInsets.only(bottom: _kSafeBottom),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                // [tickerEnabled] = false 精确模拟「壳层被不透明路由盖住」：
                // 生产的真实链路是 Overlay 给盖住的条目 tickerEnabled:false →
                // TickerProviderStateMixin 静音 ticker（`isActive` 仍为 true）。
                // 浮层**不**跟着静音——它挂在 Navigator 之上，这正是残条能画在
                // 最上面的前提，也是本用例要盯的那根条。
                TickerMode(enabled: tickerEnabled, child: shell),
                const BottomBarMorphOverlay(),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    return key;
  }

  testWidgets('push：窗口覆盖整段转场，无双条/空窗帧，交棒差 ≤2px，p 单调到 1', (tester) async {
    await pumpHost(tester);
    final boot = _record(tester, 'boot');
    expect(boot.p, 0.0, reason: '一级页面停在常驻条端点');
    expect(boot.residentDrawn, isTrue, reason: '常驻条真身在树');

    final frames = <_Frame>[];
    await tester.tap(find.text('push'));
    // 观察窗 = 转场 + 底栏收起之外再留一段（16ms × 80 ≈ 1280ms）。
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      frames.add(_record(tester, 'P$i'));
    }
    _dump(frames);

    // ① 窗口在导航时刻开跑：导航那帧仍是真身（转场同样才 0 进度），
    // 最迟第二帧进入 (0,1) —— 这是 ticker 的 elapsed=0 语义下限。
    expect(frames.first.p, 0.0);
    expect(frames.first.residentDrawn, isTrue, reason: '起跑帧源真身在画');
    expect(frames[1].windowOpen, isTrue,
        reason: '飞行窗口必须与路由转场同帧起跑（D1/D3）');
    // ② 无空窗帧：任何一帧至少有一个渲染器在画。
    for (final f in frames) {
      expect(f.residentDrawn || f.capsuleDrawn || f.overlayDrawn, isTrue,
          reason: '空窗帧：$f');
    }
    // ③ 窗口内浮层接管那一根条：浮层必在画，且**目的形态真身不得同屏**（否则双条）；
    //    源形态真身保持 onstage（浮层天然盖住它，保挂载）。
    for (final f in frames.where((f) => f.windowOpen)) {
      expect(f.overlayDrawn, isTrue, reason: '窗口内浮层未渲染：$f');
      expect(f.capsuleDrawn, isFalse, reason: '窗口内目的形态（胶囊）未让位：$f');
    }
    // ④ p 单调不减、起 0 终 1。
    for (var i = 1; i < frames.length; i++) {
      expect(frames[i].p >= frames[i - 1].p, isTrue,
          reason: 'p 非单调：${frames[i - 1].tag}→${frames[i].tag}');
    }
    expect(frames.last.p, 1.0, reason: '交棒必须走到胶囊端点');

    // ⑤ 交棒差：浮层最后一帧 vs 胶囊可见本体**接管后的首帧**（D4 的 e2 口径）。
    final lastOverlayIdx = frames.lastIndexWhere((f) => f.overlayDrawn);
    final firstCapsule = frames
        .skip(lastOverlayIdx + 1)
        .firstWhere(
          (f) => f.capsuleDrawn,
          orElse: () => throw StateError('交棒后胶囊从未渲染'),
        );
    final diff = _handoffDiff(
      frames[lastOverlayIdx].overlayRect!,
      firstCapsule.capsuleRect!,
    );
    debugPrint(
      '[HANDOFF-PUSH] 浮层末帧=${frames[lastOverlayIdx].overlayRect} '
      '胶囊首帧本体=${firstCapsule.capsuleRect} 差=${diff.toStringAsFixed(2)}px',
    );
    expect(diff <= 2.0, isTrue,
        reason: '交棒跳变 ${diff.toStringAsFixed(1)}px > 2px（D2/D4 的端点错位回归）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('pop：窗口覆盖整段转场，p 单调不增、交棒回常驻条端点', (tester) async {
    await pumpHost(tester);
    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();
    expect(kBottomBarFormProgress.value, 1.0, reason: 'push 完成后停在胶囊端点');

    final frames = <_Frame>[];
    await tester.tap(find.text('back'));
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      frames.add(_record(tester, 'Q$i'));
    }
    _dump(frames);

    expect(frames.first.p, 1.0, reason: 'pop 导航那帧仍是胶囊真身（p 贴起点）');
    expect(frames[1].windowOpen, isTrue, reason: 'pop 的窗口同样与转场同帧起跑');
    for (final f in frames) {
      expect(f.residentDrawn || f.capsuleDrawn || f.overlayDrawn, isTrue,
          reason: '空窗帧：$f');
    }
    // 窗口内浮层接管：目的形态（常驻条）不得同屏；源形态（胶囊）保持 onstage。
    for (final f in frames.where((f) => f.windowOpen)) {
      expect(f.overlayDrawn, isTrue, reason: '窗口内浮层未渲染：$f');
      expect(f.residentDrawn, isFalse, reason: '窗口内目的形态（常驻条）未让位：$f');
    }
    for (var i = 1; i < frames.length; i++) {
      expect(frames[i].p <= frames[i - 1].p, isTrue,
          reason: 'p 非单调：${frames[i - 1].tag}→${frames[i].tag}');
    }
    expect(frames.last.p, 0.0, reason: '交棒必须回到常驻条端点');

    final lastOverlayIdx = frames.lastIndexWhere((f) => f.overlayDrawn);
    final firstResident = frames
        .skip(lastOverlayIdx + 1)
        .firstWhere(
          (f) => f.residentDrawn,
          orElse: () => throw StateError('交棒后常驻条从未渲染'),
        );
    final diff = _handoffDiff(
      frames[lastOverlayIdx].overlayRect!,
      firstResident.residentRect!,
    );
    debugPrint(
      '[HANDOFF-POP] 浮层末帧=${frames[lastOverlayIdx].overlayRect} '
      '常驻条首帧=${firstResident.residentRect} 差=${diff.toStringAsFixed(2)}px',
    );
    expect(diff <= 2.0, isTrue, reason: '交棒跳变 ${diff.toStringAsFixed(1)}px > 2px');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      '横屏 rail：rail 逐帧收起恒顺延交棒窗口（+260ms+32ms），不受底栏设置开关门控',
      (tester) async {
    // 横屏（rail 布局）进二级页：rail 收起是 260ms 逐帧动画且恒随二级页翻转
    // （hideRailNavigation 不读 kHideNavBarOnSecondaryPages）。旧实现把 rail 当
    // 瞬时 Offstage、恒不顺延窗口 → rail 半滑出时交棒，胶囊 trackW/停靠位当场
    // 跳变（真机横屏报障）。竖屏开关关掉也不能影响横屏的顺延。
    _prewarmDesktopLyricServiceOutsideFakeAsync();
    kHideNavBarOnSecondaryPages.value = false;
    final key = await pumpHost(tester, railLayout: true);
    await tester.tap(find.text('push'));
    await tester.pump(const Duration(milliseconds: 16));

    final state = key.currentState!;
    expect(state.lastNavWillToggle, isTrue,
        reason: 'rail 恒随二级页翻转，顺延判据必须为真（与竖屏开关无关）');
    expect(
      state.lastFlightDuration,
      state.lastFlightTransition + kBottomChromeToggleDuration + kBarFormFlightSettleSlack,
      reason: '窗口必须覆盖 rail 滑出全程（260ms）+ 两帧容差，'
          '否则交棒发生在 rail 半滑出时（端点按已全宽解析 → 跳变）',
    );

    // 对照组（竖屏 + 开关关闭）见下一用例。
    expect(tester.takeException(), isNull);
  });

  testWidgets('横屏对照组：竖屏关掉「二级页收底栏」后无导航栏动画，不顺延窗口', (tester) async {
    _prewarmDesktopLyricServiceOutsideFakeAsync();
    kHideNavBarOnSecondaryPages.value = false;
    final key = await pumpHost(tester);
    await tester.tap(find.text('push'));
    await tester.pump(const Duration(milliseconds: 16));
    final state = key.currentState!;
    expect(state.lastNavWillToggle, isFalse,
        reason: '竖屏关掉「二级页收底栏」后没有导航栏动画，不顺延（原有行为）');
    expect(state.lastFlightDuration, state.lastFlightTransition);
    expect(tester.takeException(), isNull);
  });

  testWidgets('横屏 rail push：真 rail 几何下左缘留白全程连续、交棒差 ≤2px', (tester) async {
    // 真机横屏报障：点击（push 开始）瞬间与彻底进入二级页后的胶囊/浮层左缘
    // 留白不连续 —— 一端按 rail 在场（内容区从 rail 右缘起，留
    // navigationRailReservedWidth），另一端按 rail 已收（全宽，inset 0）。
    // 根因：可见形变前置在窗口开头 260ms 内走完（K1 + 强 ease-out），而 rail
    // 要等转场收敛后才起 260ms 滑出 —— 胶囊端点若按结算快照冻结成 inset 0，
    // 浮层会在 rail 仍在场时就把左缘推到全宽（盖住 rail）。修复后胶囊端点
    // 逐帧跟随 rail 槽位的实时保留宽（navigationRailVisibleInset）。
    // 本用例在**真 rail 几何**（横屏视口，ResponsiveScaffold 真建 rail）下
    // 逐帧录制，断言：① 浮层左缘全程不越入 rail 在场区；② rail 静止在场期
    // 浮层贴 rail 留白（不提前全宽）；③ 交棒差 ≤2px（端点守恒不减）。
    _prewarmDesktopLyricServiceOutsideFakeAsync();
    await pumpHost(tester, railLayout: true, size: _kPhoneLandscape);
    final boot = _record(tester, 'LAND-boot');
    debugPrint('[LAND] boot resident=${_fmtR(boot.residentRect)}');
    expect(boot.residentDrawn, isTrue, reason: '一级页面常驻条真身在树');
    expect(boot.residentRect!.left, closeTo(navigationRailReservedWidth, 2.0),
        reason: '横屏一级页常驻条左缘 = rail+分隔线保留宽');

    final frames = <_Frame>[];
    final insets = <double>[];
    final formTs = <double>[];
    await tester.tap(find.text('push'));
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      frames.add(_record(tester, 'LAND-$i'));
      insets.add(navigationRailVisibleInset);
      formTs.add(_overlayFormT(tester) ?? double.nan);
    }
    _dump(frames);

    // ① 全程左缘不越入 rail 在场区：窗口内每一帧，浮层条盒左缘 ≥ 该帧 rail
    //    可见保留宽（容差 8px = 一帧采样量化 + 曲线斜率残差；修复前浮层在
    //    rail 静止全场时左缘已到 16，越界 ≈97px）。
    for (var i = 0; i < frames.length; i++) {
      final f = frames[i];
      if (!f.windowOpen || f.overlayRect == null) continue;
      expect(f.overlayRect!.left, greaterThanOrEqualTo(insets[i] - 8.0),
          reason: '第 $i 帧浮层左缘 ${f.overlayRect!.left} 越入 rail 在场区 '
              '（该帧保留宽 ${insets[i]}）——胶囊端点未跟随 rail 滑出进度');
    }

    // ② rail 静止在场期（可见形变已饱和、rail 还没开始滑）：浮层贴 rail 留白，
    //    左缘 ≈ 保留宽 + 16（胶囊内缩），而不是结算态的 16。
    final saturated = <int>[
      for (var i = 0; i < frames.length; i++)
        if (frames[i].windowOpen &&
            frames[i].overlayRect != null &&
            formTs[i] >= 0.99 &&
            insets[i] >= navigationRailReservedWidth - 1.0)
          i,
    ];
    // 转场（≈450ms）长于可见形变（260ms）：饱和帧必然存在一段 rail 未动的窗口。
    expect(saturated, isNotEmpty, reason: '应存在「形变已饱和、rail 仍在场」的帧');
    for (final i in saturated) {
      expect(frames[i].overlayRect!.left,
          closeTo(navigationRailReservedWidth + 16.0, 8.0),
          reason: '第 $i 帧形变已饱和而 rail 仍在场，浮层必须贴 rail 留白 '
              '（实测左缘 ${frames[i].overlayRect!.left}，提前全宽 = 跳变根源）');
    }

    // ③ 交棒差：浮层末帧 ↔ 胶囊真身首帧 ≤2px（端点守恒口径，与竖屏用例同判据）。
    final lastOverlayIdx = frames.lastIndexWhere((f) => f.overlayDrawn);
    final firstCapsule = frames
        .skip(lastOverlayIdx + 1)
        .firstWhere(
          (f) => f.capsuleDrawn,
          orElse: () => throw StateError('交棒后胶囊从未渲染'),
        );
    final diff = _handoffDiff(
      frames[lastOverlayIdx].overlayRect!,
      firstCapsule.capsuleRect!,
    );
    debugPrint(
      '[LAND-HANDOFF] 浮层末帧=${frames[lastOverlayIdx].overlayRect} '
      '胶囊首帧本体=${firstCapsule.capsuleRect} 差=${diff.toStringAsFixed(2)}px',
    );
    expect(diff <= 2.0, isTrue,
        reason: '横屏交棒跳变 ${diff.toStringAsFixed(1)}px > 2px');
    expect(tester.takeException(), isNull);
  });

  testWidgets('幻影 ①：无导航事件的二级态翻转（转屏细节面板几何变化）不播交棒', (tester) async {
    final key = await pumpHost(tester);
    // 转屏 / 详情面板独占整宽翻转：只有推迟上报的二级态变了，没有路由事件。
    key.currentState!.debugSetSecondaryReport(true);
    final frames = <_Frame>[];
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      frames.add(_record(tester, 'A$i'));
    }
    _dump(frames);
    expect(frames.any((f) => f.windowOpen), isFalse,
        reason: '没有导航事件就不该开飞行窗口（D3 的幻影翻转 ①）');
    expect(kBottomBarFormProgress.value, 0.0, reason: '形态端点不动');
    expect(tester.takeException(), isNull);
  });

  testWidgets('幻影 ②：tab 配置装载把当前 tab 换成非一级页时吸附端点（不播交棒）', (tester) async {
    final key = await pumpHost(tester);
    // 模拟启动期 tab 配置装载：当前 tab 从「固定标题」变成「标题居中」，
    // 形态目标 0→1，但这不是用户动作 —— 直接吸附。
    key.currentState!.debugSetTabs(const <TabItem>[_kUnpinnedTab]);
    final frames = <_Frame>[];
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      frames.add(_record(tester, 'B$i'));
    }
    _dump(frames);
    // 切 tab 会触发 shell 的焦点校正 400ms 延时（`_ensureFocusNotStuck`），
    // 让它落地，避免挂到用例结束。
    await tester.pump(const Duration(milliseconds: 500));
    expect(frames.any((f) => f.windowOpen), isFalse,
        reason: '冷启动播种/配置装载的翻转不该开飞行窗口（D3 的幻影翻转 ②）');
    expect(kBottomBarFormProgress.value, 1.0, reason: '目标端点直接吸附到位');
    expect(tester.takeException(), isNull);
  });

  testWidgets('幻影 ③：push/pop 不挂播放条的页面（设置子页形态）不播交棒', (tester) async {
    await pumpHost(tester);
    final frames = <_Frame>[];
    await tester.tap(find.text('push-barless'));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      frames.add(_record(tester, 'C$i'));
    }
    _dump(frames);
    // 目的页没有胶囊：交棒没有落点 —— 数帧内吸附端点，之后不再有浮层帧。
    final windowFrames = frames.where((f) => f.windowOpen).toList();
    expect(windowFrames.length <= 4, isTrue,
        reason: '不挂条页面的 push 必须尽快撤销交棒（实测窗口帧 ${windowFrames.length}）');
    expect(frames.last.p, 1.0, reason: '撤销后吸附到目标端点');
    for (final f in frames.skip(5)) {
      expect(f.overlayDrawn, isFalse, reason: '撤销后浮层仍在画：$f');
    }

    // pop 回来同样不播：被弹出页不挂播放条，导航时刻即判定撤销。
    final popFrames = <_Frame>[];
    await tester.tap(find.text('back'));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      popFrames.add(_record(tester, 'D$i'));
    }
    _dump(popFrames);
    expect(popFrames.any((f) => f.windowOpen), isFalse,
        reason: '不挂条页面的 pop 必须直接吸附，不开窗口');
    expect(popFrames.last.p, 0.0);
    expect(tester.takeException(), isNull);
  });

  // ───────────────── K1：可见形变前置完成（窗口时长不砍） ─────────────────
  //
  // 用户报「底栏形态交叉过渡变形太慢」：形变原先与飞行窗口同长（= 转场 +
  // 底栏收起 260ms + 2 帧容差，本 SDK 下实测 ≈740ms，整段铺满）。修复**不缩短
  // 窗口**（窗口还承担：浮层独占渲染 / 覆盖整段路由转场 / 覆盖底栏收起落定 ——
  // 窗口一短，胶囊真身会在转场未结束时接管那根条，条跟着页面继续滑），只把
  // 「窗口进度 → 可见形态进度」的映射前置：窗口开头的
  // `kBarFormVisibleMorphDuration`（260ms）内走完全程、之后停在端点
  // （`resolveVisibleBarFormProgress`）。
  //
  // 判据全部落在**浮层自己的可见形变进度**（painter.formT）与窗口帧计数上：
  // ① 前 260ms 内到达端点（≥0.99 的绝对期限 + 精确 1.0）；② 其后停在端点
  // （几何不动、可见进度不回退）；③ 窗口本身仍是整段（实测 46 帧 / 736ms）且
  // 后段仍由浮层独占（真身不得接管）；④ 交棒差 ≤2px 原判据不减。
  testWidgets('K1：可见形变在窗口开头 260ms 内走完、其后停在端点（窗口时长与让位一字未动）',
      (tester) async {
    await pumpHost(tester);

    final vs = <double>[]; // 可见形变进度（浮层 painter.formT，未渲染时 nan）
    final windowOpen = <bool>[];
    final overlayRects = <Rect?>[];
    final residentDrawn = <bool>[];
    final capsuleDrawn = <bool>[];
    await tester.tap(find.text('push'));
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final f = _record(tester, 'K1-$i');
      vs.add(_overlayFormT(tester) ?? double.nan);
      windowOpen.add(f.windowOpen);
      overlayRects.add(f.overlayRect);
      residentDrawn.add(f.residentDrawn);
      capsuleDrawn.add(f.capsuleDrawn);
    }
    final windowFrames = <int>[
      for (var i = 0; i < windowOpen.length; i++)
        if (windowOpen[i]) i,
    ];
    final int first = windowFrames.first; // 挂载帧（窗口第 2 帧，formT 精确 0）
    final int last = windowFrames.last;
    final int firstSat = vs.indexWhere((v) => v >= 0.99);
    debugPrint(
      '[K1-push] 窗口帧=[$first..$last]（${windowFrames.length} 帧 ≈ '
      '${windowFrames.length * 16}ms）| 首个 ≥0.99 的帧=$firstSat '
      '（窗口起点 +${(firstSat - first) * 16}ms）| 末帧 formT=${vs[last]} | '
      '饱和后停在端点的帧数=${last - firstSat} '
      '（${(last - firstSat) * 16}ms）',
    );

    // ① 窗口整段保留（K1 只改曲线）：实测 46 帧 ≈736ms（= 转场 450ms + 底栏
    //    收起 260ms + 2 帧容差，16ms 采样下端点两侧各差一帧）。下限取 37 帧
    //    （≈592ms）留 SDK 转场时长差异的余量；**绝不能接近 260ms/16 = 17 帧**。
    expect(windowFrames.length, greaterThanOrEqualTo(37),
        reason: '窗口被砍短了（${windowFrames.length} 帧）：真身会在转场未结束时接管，'
            '条会跟着页面继续滑');

    // ② 可见形变在窗口开头 260ms 内走完：
    //    - 首帧 formT 贴 0（与让位前的真身同姿；浮层比窗口晚一帧挂载，故首帧已带
    //      一帧（16ms）的强 ease-out 推进 ≈0.048，端点交棒由浮层首帧=源端点保证）；
    //    - 首个 ≥0.99 的帧不晚于挂载帧 + 260ms（+1 帧采样量化余量；实测 224ms。
    //      连续时间下形变恰在 260ms 处到端点，第一帧"看见"它至多再晚一帧）；
    //    - 到达端点后不回退。
    expect(vs[first], lessThan(0.06),
        reason: '起飞首帧可见形变进度必须贴 0（实测 ${vs[first]}）');
    expect(firstSat, greaterThanOrEqualTo(0), reason: '整段飞行没达到 0.99');
    expect((firstSat - first) * 16, lessThanOrEqualTo(260 + 16),
        reason: '可见形变未在开头 260ms 内完成（实测 '
            '${(firstSat - first) * 16}ms 才到 0.99，容差 = 一帧采样量化）');
    for (var i = firstSat; i <= last; i++) {
      expect(vs[i], greaterThanOrEqualTo(0.99),
          reason: '第 $i 帧可见形变从端点回退了（${vs[i]}）');
    }

    // ③ 端点精确 + 之后停在端点：末帧 formT 恰为 1.0；饱和帧到末帧的条矩形不动。
    expect(vs[last], 1.0, reason: '交棒末帧可见形变进度必须精确贴 1');
    final Rect satRect = overlayRects[firstSat]!;
    expect(_handoffDiff(satRect, overlayRects[last]!), lessThan(0.5),
        reason: '形变走完后那根条必须停在端点（K1：不再整段铺满窗口）');
    expect((last - firstSat) * 16, greaterThanOrEqualTo(288),
        reason: '停在端点的后段太短（${(last - firstSat) * 16}ms）：形变被窗口掐断或窗口被砍');

    // ④ 窗口后段浮层仍在画（窗**未**提前关闭 = 目的真身没接管）：这是"条不会跟
    //    页面滑"的直接证据 —— 形变虽在 260ms 完成，浮层占据必须撑满整个窗口。
    //    源形态（常驻条）真身保持 onstage（浮层天然盖住它，保挂载）；目的形态
    //    （胶囊）真身不得同屏接管。
    for (var i = firstSat; i <= last; i++) {
      expect(overlayRects[i], isNotNull, reason: '饱和后第 $i 帧浮层不画了（窗口提前关闭）');
      expect(capsuleDrawn[i], isFalse, reason: '饱和后第 $i 帧目的形态（胶囊）真身接管了');
    }

    // ⑤ 交棒差原判据（浮层末帧 ↔ 胶囊接管首帧）不减：可见形变停在端点后逐值
    //    等于端点几何，实测差 ≈0（旧实现留窗口进度残差）。
    final int firstCapsule = <int>[
      for (var i = last + 1; i < capsuleDrawn.length; i++)
        if (capsuleDrawn[i]) i,
    ].first;
    final double diff = _handoffDiff(
      overlayRects[last]!,
      _rectOf(tester, _capsuleVisual)!,
    );
    debugPrint('[K1-push] 交棒差=${diff.toStringAsFixed(2)}px '
        '（胶囊接管帧=$firstCapsule）');
    expect(diff, lessThanOrEqualTo(2.0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('K1（反向）：可见形变在窗口开头 260ms 内回到常驻条端点、其后停住', (tester) async {
    await pumpHost(tester);
    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();
    expect(kBottomBarFormProgress.value, 1.0, reason: 'push 完成后停在胶囊端点');

    final vs = <double>[];
    final windowOpen = <bool>[];
    final overlayRects = <Rect?>[];
    final residentDrawn = <bool>[];
    await tester.tap(find.text('back'));
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final f = _record(tester, 'K1r-$i');
      vs.add(_overlayFormT(tester) ?? double.nan);
      windowOpen.add(f.windowOpen);
      overlayRects.add(f.overlayRect);
      residentDrawn.add(f.residentDrawn);
    }
    final windowFrames = <int>[
      for (var i = 0; i < windowOpen.length; i++)
        if (windowOpen[i]) i,
    ];
    final int first = windowFrames.first;
    final int last = windowFrames.last;
    final int firstSat = vs.indexWhere((v) => v <= 0.01);
    debugPrint(
      '[K1-pop] 窗口帧=[$first..$last]（${windowFrames.length} 帧 ≈ '
      '${windowFrames.length * 16}ms）| 首个 ≤0.01 的帧=$firstSat '
      '（窗口起点 +${(firstSat - first) * 16}ms）| 末帧 formT=${vs[last]} | '
      '停在端点的帧数=${last - firstSat}',
    );

    expect(windowFrames.length, greaterThanOrEqualTo(37),
        reason: '反向窗口同样不得砍短');
    // 反向起飞帧贴胶囊端点（1.0），方向是时间镜像（反向**开头**完成形变）。首帧
    // 因浮层晚一帧挂载，已带一帧（16ms）推进 ≈0.005（apex 附近斜率为 0）。
    expect(vs[first], greaterThan(0.99),
        reason: '反向起飞首帧可见形变进度必须贴 1（实测 ${vs[first]}）');
    expect(firstSat, greaterThanOrEqualTo(0), reason: '整段飞行没回到 0.01 以下');
    expect((firstSat - first) * 16, lessThanOrEqualTo(260 + 16),
        reason: '反向可见形变未在开头 260ms 内完成（实测 '
            '${(firstSat - first) * 16}ms 才到 ≤0.01，容差 = 一帧采样量化；'
            '注意时间镜像形态下 0.01 阈值比前向的 0.99 更晚触达，但 0.01 的'
            '可见量 ≈0.3px，端点保真不受影响）');
    for (var i = firstSat; i <= last; i++) {
      expect(vs[i], lessThanOrEqualTo(0.01),
          reason: '第 $i 帧可见形变从端点回退了（${vs[i]}）');
    }
    expect(vs[last], 0.0, reason: '反向交棒末帧可见形变进度必须精确贴 0');
    expect(
      _handoffDiff(overlayRects[firstSat]!, overlayRects[last]!),
      lessThan(0.5),
      reason: '形变走完后那根条必须停在常驻条端点',
    );
    final int firstResident = <int>[
      for (var i = last + 1; i < residentDrawn.length; i++)
        if (residentDrawn[i]) i,
    ].first;
    final double diff = _handoffDiff(
      overlayRects[last]!,
      _rectOf(tester, find.byType(MiniPlayer))!,
    );
    debugPrint('[K1-pop] 交棒差=${diff.toStringAsFixed(2)}px '
        '（常驻条接管帧=$firstResident）');
    expect(diff, lessThanOrEqualTo(2.0));
    expect(tester.takeException(), isNull);
  });

  // ───────────────────── G1：四条内容层报障的端点对账 ─────────────────────

  /// 逐帧收集内容读数（统一 post-process 取「交棒前后」的第一/末帧：
  /// 飞行窗口外两端真身都会渲染 —— push 的 K0 帧常驻条与刚入场的胶囊同框、
  /// pop 的 Q0 帧胶囊与即将回归的常驻条同框，直接 firstWhere 会取到转场中帧）。
  ///
  /// [firstStep]/[firstFrames]：起飞瞬间若直接按 16ms 采样，第一帧已带 ~2% 的
  /// 形变进度（封面 ~0.9px、行级居中 ~1.7px 位移），端点断言会被飞行自身的第一
  /// 帧推进污染。按 1ms 采样前几帧（p ≈ 0.001），端点差回到 ≤0.1px。
  Future<List<({_BodyContent overlay, _BodyContent resident, _BodyContent capsule})>>
      recordContent(
    WidgetTester tester,
    int frames, {
    Duration step = const Duration(milliseconds: 16),
    int fineFrames = 0,
    Duration fineStep = const Duration(milliseconds: 1),
  }) async {
    final out =
        <({_BodyContent overlay, _BodyContent resident, _BodyContent capsule})>[];
    for (var i = 0; i < frames; i++) {
      await tester.pump(i < fineFrames ? fineStep : step);
      out.add(_snapContent(tester));
    }
    return out;
  }

  testWidgets('报障①：切回常驻栏——浮层末帧进度与常驻条首帧同源同值，stop 点端点连续', (tester) async {
    await pumpHost(tester);
    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();
    expect(kBottomBarFormProgress.value, 1.0, reason: 'push 完成后停在胶囊端点');

    await tester.tap(find.text('back'));
    final frames = await recordContent(tester, 80);
    final lastOvIdx = frames.lastIndexWhere((f) => f.overlay.progress != null);
    expect(lastOvIdx, greaterThanOrEqualTo(0), reason: '飞行窗口内必须画出浮层');
    final lastOverlay = frames[lastOvIdx].overlay;
    final firstResident = frames
        .skip(lastOvIdx + 1)
        .map((f) => f.resident)
        .firstWhere((c) => c.progress != null,
            orElse: () => throw StateError('交棒后常驻条从未渲染'));
    final a = lastOverlay.progress!;
    final b = firstResident.progress!;
    debugPrint(
      '[G1-①] 浮层末帧 p=${lastOverlay.p.toStringAsFixed(4)} '
      'progress=${a.progress.toStringAsFixed(6)} formT=${a.formT.toStringAsFixed(4)} '
      'box=${_fmtR(lastOverlay.progressBoxRect)} | 常驻条首帧 '
      'progress=${b.progress.toStringAsFixed(6)} formT=${b.formT} '
      'box=${_fmtR(firstResident.progressBoxRect)}',
    );
    // ①-1 进度值同源同值（12s / 60s）：末帧与接管首帧逐位相等。
    expect(a.progress, closeTo(0.2, 1e-9));
    expect(a.progress, b.progress,
        reason: '浮层 ${a.progress} vs 常驻条 ${b.progress}：进度值来源必须同一份');
    // ①-2 外观参数端点逐项（缺一即端点跳变）。
    expect(a.formT, lessThan(0.05), reason: '末帧 formT 应贴 0 端点，实测 ${a.formT}');
    expect(b.formT, 0.0);
    expect(a.gapSize, b.gapSize);
    expect(a.gapSize, kPlayerBarProgressLineGap);
    expect(a.strokeCap, b.strokeCap);
    expect(a.strokeCap, StrokeCap.round);
    expect(a.stopIndicatorSize, b.stopIndicatorSize);
    expect(a.stopIndicatorSize, kPlayerBarProgressLineStopSize);
    expect(a.activeColor, b.activeColor);
    // 轨道色按 formT 插值（两端本就不同色），端点只允许 lerp 残差。
    expect((a.trackColor.a - b.trackColor.a).abs(), lessThan(0.02));
    // ①-3 stop 点：旧实现按 `isFlatLine` 二值门把飞行全程的 stop 点整段砍掉，
    // 交棒帧凭空多出/消失这 2dp（「切回常驻栏最后一刻进度闪一下」）。
    // 现按 formT 线性淡入，末帧 ≈ 满不透明、与常驻条端点近似等价。
    expect(resolveStopIndicatorMorphOpacity(b.formT), 1.0);
    expect(
      resolveStopIndicatorMorphOpacity(a.formT),
      closeTo(1.0 - a.formT / kPlayerBarProgressStopMorphFade, 1e-9),
    );
    expect(resolveStopIndicatorMorphOpacity(a.formT), greaterThan(0.85),
        reason: '末帧 stop 点不允许仍被整段砍掉（旧实现恒 0）');
    expect(resolveStopIndicatorMorphOpacity(0.5), 0.0,
        reason: '中段照旧没有 stop 点');
    // ①-4 进度盒：末帧高 = lerp(2, 64, **可见形变进度**)，常驻条恒 2；宽同源。
    // K1 之后几何吃的是可见形变进度（formT），不是窗口进度 p：末帧 formT 恰为 0
    // （形变早已完成并停在端点），盒高因此**逐值**等于常驻条端点（旧写法与 p
    // 挂钩会留 ≈0.15px 的窗口进度残差）。
    final boxA = lastOverlay.progressBoxRect!;
    final boxB = firstResident.progressBoxRect!;
    expect(boxB.height, 2.0);
    expect(boxA.height, closeTo(2.0 + 62.0 * a.formT, 0.2));
    expect(boxA.height - boxB.height, lessThan(0.7));
    expect((boxA.width - boxB.width).abs(), lessThan(0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('报障②：切换瞬间——浮层封面与常驻条末帧同矩形，解码档与真身共享（非独有第三档）', (tester) async {
    final key = await pumpHost(tester);

    // 起飞前常驻条的结算帧（tap 之前采样）：交棒瞬间浮层首帧应与它逐值同姿。
    final pre = _snapContent(tester).resident;
    await tester.tap(find.text('push'));
    final frames = await recordContent(tester, 80, fineFrames: 3);
    final firstOvIdx = frames.indexWhere((f) => f.overlay.drawn);
    expect(firstOvIdx, greaterThanOrEqualTo(0), reason: '飞行窗口内必须画出浮层');
    final firstOverlay = frames[firstOvIdx].overlay;
    final lastResident = pre;
    expect(lastResident.drawn, isTrue, reason: '起飞前常驻条必须已渲染');
    expect(key.currentState, isNotNull);
    final r0 = lastResident.coverRect!;
    final r1 = firstOverlay.coverRect!;
    debugPrint(
      '[G1-②] 常驻条末帧封面=${_fmtR(r0)} 解码档=${lastResident.coverSizeParam} | '
      '浮层首帧封面=${_fmtR(r1)} 解码档=${firstOverlay.coverSizeParam}',
    );
    // ②-1 切换瞬间封面矩形逐值不变（浮层首帧 = 常驻条末帧，≤0.5px）。
    expect((r1.left - r0.left).abs(), lessThan(0.5));
    expect((r1.top - r0.top).abs(), lessThan(0.5));
    expect((r1.width - r0.width).abs(), lessThan(0.5));
    expect(r0.width, closeTo(44.0, 0.3));
    // ②-2 解码档：浮层不与两端各占一档（旧 56 是三方独有档，每次飞行全新解码
    // → 首帧占位/淡入 = 「切换瞬间封面闪烁」）。现固定取两端最大可见档 58，
    // 与胶囊同键（见报障③），常驻条端靠 FittedBox 降采样到 44 逐值不变。
    expect(firstOverlay.coverSizeParam, kMorphCapsuleCoverSize);
    expect(firstOverlay.coverSizeParam, 58.0);
    expect(lastResident.coverSizeParam, kMorphResidentCoverSize);
    expect(lastResident.coverSizeParam, 44.0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('报障③：切为悬浮栏——浮层末帧封面 58@(3,3) 与胶囊可见封面逐值相等（含解码档同键）', (tester) async {
    await pumpHost(tester);

    await tester.tap(find.text('push'));
    final frames = await recordContent(tester, 80);
    final lastOvIdx = frames.lastIndexWhere((f) => f.overlay.drawn);
    expect(lastOvIdx, greaterThanOrEqualTo(0), reason: '飞行窗口内必须画出浮层');
    final ov = frames[lastOvIdx].overlay;
    final cap = frames
        .skip(lastOvIdx + 1)
        .map((f) => f.capsule)
        .firstWhere((c) => c.drawn,
            orElse: () => throw StateError('push 完成后胶囊从未渲染'));
    debugPrint(
      '[G1-③] 浮层末帧 p=${ov.p.toStringAsFixed(4)} 条盒=${_fmtR(ov.barRect)} '
      '封面=${_fmtR(ov.coverRect)} 档=${ov.coverSizeParam} | 胶囊首帧 '
      '本体=${_fmtR(cap.barRect)} 封面=${_fmtR(cap.coverRect)} 档=${cap.coverSizeParam}',
    );
    // ③-1 端点相对几何：浮层末帧封面锚在「胶囊可见封面」上 = 盒内 58@(3,3)。
    final ovBar = ov.barRect!;
    expect(ov.coverRect!.left - ovBar.left, closeTo(kMorphCapsuleCoverInset, 0.4));
    expect(ov.coverRect!.top - ovBar.top, closeTo(kMorphCapsuleCoverInset, 0.4));
    expect(ov.coverRect!.width, closeTo(58.0, 0.4));
    // ③-2 胶囊真身可见封面（形态展开、transform 恒等）同姿：58@(3,3)。
    final capBar = cap.barRect!;
    expect(cap.coverRect!.left - capBar.left, closeTo(3.0, 0.3));
    expect(cap.coverRect!.top - capBar.top, closeTo(3.0, 0.3));
    expect(cap.coverRect!.width, closeTo(58.0, 0.3));
    // ③-3 交棒逐值：末帧↔首帧（旧实现此处横移 3px、纵移 1px、大小 2dp 跳变）。
    expect(_handoffDiff(ov.coverRect!, cap.coverRect!), lessThan(0.6),
        reason: '封面交棒跳变（会诊 D2：56@left0 vs 58@left3）');
    // ③-4 解码档同键：浮层与胶囊都是 58 档（参与 cacheWidth / ImageCache key），
    // 飞行中把该档保持在缓存热区，胶囊交棒首帧不再走全新解码。
    expect(ov.coverSizeParam, cap.coverSizeParam);
    expect(ov.coverSizeParam, kMorphCapsuleCoverSize);
    expect(tester.takeException(), isNull);
  });

  testWidgets('报障④：双向交棒文字行级对齐端点等价（常驻端贴左、胶囊端逐行居中）', (tester) async {
    await pumpHost(tester);

    // ——— push：常驻条 → 浮层 → 胶囊 ———
    // 起飞前常驻条结算帧（tap 前采样，作为交棒起点基准）。
    final lastResident = _snapContent(tester).resident;
    expect(lastResident.drawn, isTrue, reason: '起飞前常驻条必须已渲染');
    await tester.tap(find.text('push'));
    final frames = await recordContent(tester, 80, fineFrames: 3);
    final firstOvIdx = frames.indexWhere((f) => f.overlay.drawn);
    final lastOvIdx = frames.lastIndexWhere((f) => f.overlay.drawn);
    expect(firstOvIdx, greaterThanOrEqualTo(0));
    expect(lastOvIdx, greaterThanOrEqualTo(firstOvIdx));
    final firstOverlay = frames[firstOvIdx].overlay;
    final lastOverlay = frames[lastOvIdx].overlay;
    final firstCapsule = frames
        .skip(lastOvIdx + 1)
        .map((f) => f.capsule)
        .firstWhere((c) => c.drawn,
            orElse: () => throw StateError('push 完成后胶囊从未渲染'));
    final rT = lastResident.titleRect!;
    final rA = lastResident.artistRect!;
    final oT = firstOverlay.titleRect!;
    final oA = firstOverlay.artistRect!;
    debugPrint(
      '[G1-④push起] 常驻条 标题=${_fmtR(rT)} 歌手=${_fmtR(rA)} | '
      '浮层首帧 标题=${_fmtR(oT)} 歌手=${_fmtR(oA)}',
    );
    // 起飞瞬间：浮层首帧两行仍贴左（与常驻条末帧 ≤0.5px；同一行时两行左缘对齐）。
    expect((oT.left - rT.left).abs(), lessThan(0.5));
    expect((oA.left - rA.left).abs(), lessThan(0.5));
    expect((oT.left - oA.left).abs(), lessThan(0.5), reason: '常驻端两行都贴左缘');

    // 完成时：浮层末帧 ↔ 胶囊首帧 —— 旧实现胶囊逐行居中、浮层块级居中，歌手行
    // （比歌名短）会从「块左缘」跳到「整行居中」（实测半个行宽差）。
    final fO = lastOverlay;
    final fC = firstCapsule;
    final oT2 = fO.titleRect!;
    final oA2 = fO.artistRect!;
    final cT = fC.titleRect!;
    final cA = fC.artistRect!;
    debugPrint(
      '[G1-④push尾] 浮层末帧 p=${fO.p.toStringAsFixed(4)} '
      '标题=${_fmtR(oT2)} 歌手=${_fmtR(oA2)} | 胶囊首帧 标题=${_fmtR(cT)} 歌手=${_fmtR(cA)}',
    );
    expect((oT2.left - cT.left).abs(), lessThan(1.5),
        reason: '标题行交棒横跳（旧实现 = 半个行宽差）');
    expect((oA2.left - cA.left).abs(), lessThan(1.5));
    // 胶囊端的对齐是**逐行居中**（真身 CrossAxisAlignment.center）：
    // 两行的左缘差 = (歌手宽 − 歌名宽) / 2 ≈ 22px（test 字体 = 1em/字符：
    // 歌名 2×14、歌手 6×12），块级居中会把它压成 0 —— 即旧 bug 的形状。
    final overlayDelta = oT2.left - oA2.left;
    final capsuleDelta = cT.left - cA.left;
    debugPrint(
      '[G1-④push尾] 两行左缘差：浮层末帧=${overlayDelta.toStringAsFixed(2)} '
      '胶囊=${capsuleDelta.toStringAsFixed(2)}',
    );
    expect((overlayDelta - capsuleDelta).abs(), lessThan(1.0));
    expect(capsuleDelta, greaterThan(15.0),
        reason: '胶囊端两行必须各自居中，(歌名宽−歌手宽)/2 = 22px，实测 $capsuleDelta');

    // ——— pop：胶囊 → 浮层 → 常驻条 ———
    // 起飞前胶囊结算帧（tap 前采样，作为回程起点基准）。
    final lastCapsule = _snapContent(tester).capsule;
    expect(lastCapsule.drawn, isTrue, reason: '回程起飞前胶囊必须已渲染');
    await tester.tap(find.text('back'));
    final popFrames = await recordContent(tester, 80);
    final firstOvIdx2 = popFrames.indexWhere((f) => f.overlay.drawn);
    final lastOvIdx2 = popFrames.lastIndexWhere((f) => f.overlay.drawn);
    expect(firstOvIdx2, greaterThanOrEqualTo(0));
    final firstOverlay2 = popFrames[firstOvIdx2].overlay;
    final lastOverlay2 = popFrames[lastOvIdx2].overlay;
    final firstResident2 = popFrames
        .skip(lastOvIdx2 + 1)
        .map((f) => f.resident)
        .firstWhere((c) => c.drawn,
            orElse: () => throw StateError('回程完成后常驻条从未渲染'));
    final lcT = lastCapsule.titleRect!;
    final lcA = lastCapsule.artistRect!;
    final fo2T = firstOverlay2.titleRect!;
    final fo2A = firstOverlay2.artistRect!;
    debugPrint(
      '[G1-④pop起] 胶囊末帧 标题=${_fmtR(lcT)} 歌手=${_fmtR(lcA)} | '
      '浮层首帧 标题=${_fmtR(fo2T)} 歌手=${_fmtR(fo2A)}',
    );
    // 回程起飞：浮层首帧两行与胶囊末帧逐值一致（逐行居中口径延续）。
    expect((fo2T.left - lcT.left).abs(), lessThan(1.5));
    expect((fo2A.left - lcA.left).abs(), lessThan(1.5));

    // 回程完成：浮层末帧 ↔ 常驻条首帧，两行都回到左缘（行差 → 0）。
    final lo2 = lastOverlay2;
    final fr2 = firstResident2;
    final lo2T = lo2.titleRect!;
    final lo2A = lo2.artistRect!;
    final fr2T = fr2.titleRect!;
    final fr2A = fr2.artistRect!;
    debugPrint(
      '[G1-④pop尾] 浮层末帧 p=${lo2.p.toStringAsFixed(4)} '
      '标题=${_fmtR(lo2T)} 歌手=${_fmtR(lo2A)} | 常驻条首帧 '
      '标题=${_fmtR(fr2T)} 歌手=${_fmtR(fr2A)}',
    );
    expect((lo2T.left - fr2T.left).abs(), lessThan(0.6));
    expect((lo2A.left - fr2A.left).abs(), lessThan(0.6));
    expect((lo2T.left - lo2A.left).abs(), lessThan(1.0),
        reason: '常驻端两行必须回到左缘对齐');
    expect((fr2T.left - fr2A.left).abs(), lessThan(0.5));
    expect(tester.takeException(), isNull);
  });

  // ─────────────── H1：让位必须是「保挂载、不绘制」而非卸载子树 ───────────────
  //
  // 让位原先用 `SizedBox.shrink()` 把整棵子树**卸载**，交棒首帧封面 State 重建 →
  // 本地音乐的封面走本地字节路径（`LocalArtworkImage` 重新异步读字节 / `Image.memory`
  // 换新 `Uint8List` → `MemoryImage` key 变 → 重新解码）→ 交棒瞬间 2~5 帧空白
  // （用户报障「封面闪烁」）。现在让位是 `Offstage`：保挂载（Element/State 不销毁）、
  // 只跳 paint/hit-test/占位。
  //
  // 判据取**封面 State 实例的同一性**：State 对象只在该 Element 被卸载重建时才换新
  // （`initState` 每份 State 只跑一次）。窗口内每一帧都是同一个对象 ⇒ 该子树在整个
  // 飞行期间从未被卸载重建 ⇒ 交棒首帧复用同一份 `ImageProvider`/已解码位图。

  testWidgets('让位保挂载①：飞行窗口内常驻条封面 State 不被卸载重建（交棒首帧复用已解码位图）',
      (tester) async {
    await pumpHost(tester);
    final cover = _residentCover();
    expect(cover, findsOneWidget, reason: '起飞前常驻条封面在树');
    final State before = tester.state<State>(cover);

    var windowFrames = 0;
    await tester.tap(find.text('push'));
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final p = kBottomBarFormProgress.value;
      if (p <= 0.0 || p >= 1.0) continue;
      windowFrames++;
      // 源形态真身在窗口内**保持挂载、保持在画**（浮层天然盖在 Navigor 之上把它
      // 盖住，无需 offstage）——「保挂载」的关键是**同一 State 实例**，不重建封面。
      expect(cover, findsOneWidget,
          reason: '让位期封面必须仍在树上（保挂载）：frame $i p=$p');
      expect(identical(tester.state<State>(cover), before), isTrue,
          reason: 'frame $i（p=$p）：封面 State 已被重建 —— 交棒卸载了子树，'
              '这正是「交棒瞬间封面闪烁」的直接来源');
    }
    expect(windowFrames, greaterThan(5), reason: '必须真的进过飞行窗口');

    // 交棒后仍是同一个 State：首帧直接复用已解码位图，不再走一遍异步读字节。
    await tester.pumpAndSettle();
    expect(kBottomBarFormProgress.value, 1.0);
    expect(cover, findsOneWidget, reason: '交棒后常驻条真身仍在树');
    expect(identical(tester.state<State>(cover), before), isTrue,
        reason: '交棒首帧的封面 State 必须与起飞前是同一实例');
    expect(tester.takeException(), isNull);
  });

  testWidgets('让位保挂载②：push 飞行窗口内胶囊真身已挂载，交棒首帧复用同一封面 State', (tester) async {
    // 这条直接钉住「交棒瞬间封面闪烁」的机理：让位若是卸载子树，胶囊真身的封面
    // State 会在**交棒那一帧**才创建（窗口内它整棵被 shrink 掉）→ `initState` 重新
    // 异步读本地封面字节 → 交棒后数帧空白。保挂载（`Offstage`）后，胶囊在窗口内
    // 就完成构建与读字节，交棒首帧直接复用。
    await pumpHost(tester);
    final cover = _capsuleCover();
    expect(cover, findsNothing, reason: '起飞前二级页还没建，胶囊真身尚不存在');

    State? duringFlight;
    State? atHandoff;
    var windowFrames = 0;
    await tester.tap(find.text('push'));
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final p = kBottomBarFormProgress.value;
      if (p > 0.0 && p < 1.0) {
        windowFrames++;
        expect(cover, findsOneWidget,
            reason: 'p=$p：让位期胶囊真身必须已挂载（交棒首帧不缺封面的前提）');
        expect(_standsDown(cover), isTrue, reason: 'p=$p：让位期胶囊真身不得绘制');
        duringFlight = tester.state<State>(cover);
        continue;
      }
      if (p >= 1.0) {
        atHandoff = tester.state<State>(cover);
        break;
      }
    }
    expect(windowFrames, greaterThan(5), reason: '必须真的进过飞行窗口');
    expect(duringFlight, isNotNull, reason: '窗口内胶囊真身必须已挂载');
    expect(atHandoff, isNotNull, reason: '交棒后胶囊真身必须渲染');
    expect(identical(atHandoff, duringFlight), isTrue,
        reason: '交棒首帧的胶囊封面 State 必须就是飞行窗口内那一份 —— 否则等于'
            '「交棒时才 initState」= 重新异步读封面字节 = 首帧空白的直接来源');
    expect(tester.takeException(), isNull);
  });

  // ───── H1-省帧：窗口帧不再重建条体（O1：条体移入 `ValueListenableBuilder.child`） ─────
  //
  // 修前：两端真身把条体**直接写在** `ValueListenableBuilder(kBottomBarFormProgress)`
  // 的 `builder` 里 → 窗口内每帧整棵条重建（常驻条约 40~70 节点、胶囊约 50~80）。
  // 修后：条体作为 `child:` 传入 —— 窗口帧只翻外层 `Offstage` 标志，条体实例恒定，
  // `Element.updateChild` 见同一实例即短路，整棵条不再重建。
  //
  // 判据 = **条体最深处的 `SmartArtworkImage` widget 实例数**：该实例只在条体
  // build（`_buildPlayerBar` / `_buildPlayerCard`）时才会 new 一个 —— 它是几层
  // 动画/子 VLB 的 `child:`（跨帧复用），本身不随那些层重建。故「窗口内不同封面
  // 实例数」= 条体 build 次数 + 1（修前 = 每帧一次 ≈ 窗口帧数 46；修后 O(1)）。
  //
  // 另记「外壳实例数」（该条最外层 VLB 的 widget 实例，只在外层 State 重建时换新）
  // = 外层 State 重建次数 + 1：胶囊侧修前还有个第二逐帧源 —— `_buildHost` 那段
  // 「底部预留」的 `ListenableBuilder` 读全量 `MediaQuery.of`，底栏收起/恢复的
  // `padding.bottom` 每帧变化 → 若 `SecondaryMiniPlayer` 留在里面就每帧换新 widget
  // 实例、胶囊 State 每帧 build（实测窗口后段 ≈17 帧全中）。本次已把悬浮条提到
  // builder 之外（见 省帧②）。

  testWidgets('省帧①：飞行窗口内常驻条条体不逐帧重建（封面实例全程 O(1)）',
      (tester) async {
    await pumpHost(tester);
    final cover = _residentCover();
    expect(cover, findsOneWidget, reason: '起飞前常驻条封面在树');

    final covers = <SmartArtworkImage>{};
    var windowFrames = 0;
    await tester.tap(find.text('push'));
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final p = kBottomBarFormProgress.value;
      if (p <= 0.0 || p >= 1.0) continue;
      windowFrames++;
      expect(cover, findsOneWidget, reason: 'frame $i p=$p：让位期封面仍在树');
      covers.add(tester.widget<SmartArtworkImage>(cover));
    }
    debugPrint(
      '[省帧①] 常驻条窗口帧=$windowFrames 封面不同实例数=${covers.length}'
      '（修前 = 窗口帧数 ≈46；修后 O(1)）',
    );
    expect(windowFrames, greaterThanOrEqualTo(37), reason: '必须真的进过整段窗口');
    expect(covers.length, lessThanOrEqualTo(2),
        reason: '窗口内常驻条被逐帧重建：不同封面实例数 ${covers.length}'
            '（修前 = 窗口帧数 $windowFrames）—— 条体没走 ValueListenableBuilder.child');
    // 具体数字口径：46 帧只允许 1~2 次条体构建（比值必须差一个数量级）。
    expect(covers.length * 10, lessThan(windowFrames),
        reason: '条体仍在逐帧重建：构建 ${covers.length} 次 / 窗口 $windowFrames 帧');
    expect(tester.takeException(), isNull);
  });

  testWidgets('省帧②：飞行窗口内胶囊条体不逐帧重建（封面/外壳实例全程 O(1)）',
      (tester) async {
    await pumpHost(tester);
    final cover = _capsuleCover();
    expect(cover, findsNothing, reason: '起飞前二级页还没建，胶囊真身尚不存在');

    final shells = <ValueListenableBuilder<double>>{};
    final covers = <SmartArtworkImage>{};
    var windowFrames = 0;
    await tester.tap(find.text('push'));
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final p = kBottomBarFormProgress.value;
      if (p <= 0.0 || p >= 1.0) continue;
      windowFrames++;
      final shell = _barFormShell(SecondaryMiniPlayer);
      if (shell.evaluate().isNotEmpty) {
        shells.add(tester.widget<ValueListenableBuilder<double>>(shell.first));
      }
      if (cover.evaluate().isNotEmpty) {
        covers.add(tester.widget<SmartArtworkImage>(cover));
      }
    }
    debugPrint(
      '[省帧②] 胶囊窗口帧=$windowFrames 外壳不同实例数=${shells.length} '
      '封面不同实例数=${covers.length}（修前两者均 = 窗口帧数 ≈46；修后 O(1)）',
    );
    expect(windowFrames, greaterThanOrEqualTo(37), reason: '必须真的进过整段窗口');
    expect(covers.length, lessThanOrEqualTo(2),
        reason: '窗口内胶囊被逐帧重建：不同封面实例数 ${covers.length}'
            '（修前 = 窗口帧数 $windowFrames）—— 卡体没走 ValueListenableBuilder.child');
    expect(covers.length * 10, lessThan(windowFrames),
        reason: '卡体仍在逐帧重建：构建 ${covers.length} 次 / 窗口 $windowFrames 帧');
    // 第二逐帧源（宿主保留预留那段 builder 里造悬浮条 + 全量 MediaQuery.of）：
    // 外层 State 不得逐帧重建（提到 builder 外后实测 = 1）。
    expect(shells.length, lessThanOrEqualTo(2),
        reason: '外层 State 在窗口内逐帧重建（外壳实例 ${shells.length} / 窗口 '
            '$windowFrames 帧）—— 悬浮条仍留在逐帧 builder 里');
    expect(tester.takeException(), isNull);
  });

  // ───────── 残留 3：浮层文字 `TextAlign` 硬切（中段跳一次） ─────────
  //
  // 实读结论（本条用例的打印就是证据）：
  // - 文字盒在浮层里**满宽**（`Expanded` 撑满，且被省略号截断的行会填满盒），
  //   所以 `TextAlign` 是**真的在起作用**的：长标题下 `start` ↔ `center`
  //   把整行字形搬动 `(盒宽 − 行宽)/2`。旧写法 `layout.t < 0.5 ? start : center`
  //   因此在中段留一条实测 **5.5px** 的台阶（短文案时盒跟着行收缩，台阶为 0，
  //   这正是既有用例测不出来的原因）。
  // - 修法 = 让摆位权回到连续的 `Align`：`PlayerBarText` 在 `lineAlignment`
  //   非空时用 `TextWidthBasis.longestLine` 把行盒收缩到**行宽**，于是
  //   `t=1` 的 `Align(center)` 位移与胶囊真身 `textAlign: center` 逐值相等、
  //   `t=0` 的 `Align(centerLeft)` 位移为 0 与常驻条真身逐值相等，中途连续。
  //   两端真身一个字节都没改（`longestLine` 只挂在浮层那条分支上）。

  testWidgets('残留3：长标题（省略号截断）下浮层文字对齐连续、两端与真身逐值等价',
      (tester) async {
    final longPlayer = _LongTitlePlayer();
    addTearDown(longPlayer.dispose);
    await pumpHost(tester, playerOverride: longPlayer);

    final residentX = _titleGlyphLeft(tester, find.byType(MiniPlayer));

    final xs = <double>[];
    final vs = <double?>[];
    await tester.tap(find.text('push'));
    for (var i = 0; i < 260; i++) {
      await tester.pump(const Duration(milliseconds: 6));
      if (find
          .byKey(const ValueKey<String>('morph-bar-text'))
          .evaluate()
          .isEmpty) {
        continue;
      }
      xs.add(_titleGlyphLeft(tester, find.byType(BottomBarMorphOverlay)));
      vs.add(_overlayFormT(tester));
    }
    await tester.pumpAndSettle();
    final capsuleX = _titleGlyphLeft(tester, find.byType(SecondaryMiniPlayer));
    expect(xs.length, greaterThan(40), reason: '必须采到整段飞行');

    // 相邻帧位移表（升序）：② 用「自然运动上界」判定台阶，③ 用上界钉已知残留。
    final List<double> steps = <double>[
      for (var i = 1; i < xs.length; i++) (xs[i] - xs[i - 1]).abs(),
    ]..sort();
    final double maxStep = steps.isEmpty ? 0.0 : steps.last;
    final double secondMax = steps.length > 1 ? steps[steps.length - 2] : 0.0;
    // K1 之后「形变时长」= 窗口开头的 `kBarFormVisibleMorphDuration`（260ms）：
    // 采样步长 6ms 下，逐帧自然位移上界 = 全程位移 × 曲线最大斜率 × 6/260。
    final double straight = (xs.last - xs.first).abs();
    final double curveSlope = _maxBarFormCurveSlope();
    final double naturalBound = straight * curveSlope * 6 / 260.0;
    debugPrint(
      '[G1-残留3] 常驻条(p=0)=${residentX.toStringAsFixed(2)} | '
      '浮层首帧=${xs.first.toStringAsFixed(2)} 末帧=${xs.last.toStringAsFixed(2)} | '
      '胶囊(p=1)=${capsuleX.toStringAsFixed(2)} | '
      '全程位移=${straight.toStringAsFixed(2)}px '
      '曲线最大斜率=${curveSlope.toStringAsFixed(2)} '
      '自然位移上界=${naturalBound.toStringAsFixed(2)}px '
      '最大相邻位移=${maxStep.toStringAsFixed(2)}px '
      '次大=${secondMax.toStringAsFixed(2)}px '
      '首帧可见=${vs.first}',
    );

    // ① 两端逐值等价真身（起飞首帧 ↔ 常驻条；交棒末帧 ↔ 胶囊）。
    expect((xs.first - residentX).abs(), lessThan(0.6),
        reason: '起飞首帧必须与常驻条真身同姿');
    expect((xs.last - capsuleX).abs(), lessThan(0.6),
        reason: '交棒末帧必须与胶囊真身同姿（旧实现靠硬切 textAlign 才凑到，'
            '现改由连续 Align 承担）');

    // ② 无对齐台阶（K1 重推）：相邻帧位移不得超过「自然运动上界」——旧实现
    //    （`textAlign` 在 t=0.5 硬切）长标题下会在中段多出一帧 5.5px 的台阶。
    //    K1 把可见形变压进窗口开头 260ms，逐帧自然位移按 590/260 放大到
    //    ≈2.3px（曲线最陡处），故上界从固定 1px 改为**按曲线/时长推导**的值；
    //    允许**至多一处**超界（ellipsis 台阶，见 ③，实测 7.01px 独占最大）。
    expect(secondMax, lessThanOrEqualTo(naturalBound + 0.5),
        reason: '出现额外台阶：次大相邻位移 ${secondMax.toStringAsFixed(2)}px > '
            '自然运动上界 ${(naturalBound + 0.5).toStringAsFixed(2)}px'
            '（TextAlign 硬切回归会在这里多出一帧 5.5px 台阶）');

    // ③ 已知残留（成因与 ② 不同，别混为一谈）：`TextOverflow.ellipsis` 截断
    //    以**字符**为粒度，行宽在末尾随盒宽跳一级（实测 Δ行宽 14.25px），
    //    对齐插值把它放大成 t·Δ/2 ≈ 7px 的末段位移。它是 ellipsis 的固有权
    //    重（旧实现同样有 7.19px），本次只钉上界防劣化，如实记录不假装已消除。
    //    （K1 后它落在可见进度 ≈0.96 处，仍是**单帧**一次跳变，量级未变。）
    expect(maxStep, lessThan(8.0),
        reason: '末段截断边界位移上界（实测 ${maxStep.toStringAsFixed(2)}px，旧实现 7.19px）');
    expect(vs.first, 0.0, reason: '起飞首帧可见形变进度必须精确贴 0（交棒无痕）');
    expect(tester.takeException(), isNull);
  });

  // ────────── 报障⑤：交棒瞬间「已播放段长度」连续（两端各自等价真身） ──────────
  //
  // 用户报障：「进度条的已播放条有硬切 —— 切到常驻栏的最后一刻、以及切到悬浮栏的
  // 最开始，进度对不上」。整条形变本身没问题（端点几何 / stop 点 / 文字对齐前几轮
  // 已对齐），坏的是**已播放段的长度**：两端进度分母口径不同（常驻条 = 盒宽 W，
  // 胶囊 = 中心线周长 L ≈ 2W），浮层若拿「当前路径长度」当分母，formT 离开 0 的
  // 那一帧分母就从 W 跳到 ≈2W，已播放段瞬时翻倍（W=400 / p=0.2：79 → 159px）。
  testWidgets('报障⑤：交棒两端已播放段长度连续（驻留端 / 胶囊端各 ≤2px）', (tester) async {
    await pumpHost(tester);
    // 与两端真身同源的进度值（_FakePlayer：12s / 60s）。
    const double progress = 12 / 60;

    // ——— push：常驻条 → 浮层 → 胶囊 ———
    await tester.tap(find.text('push'));
    final pushFrames = await recordContent(tester, 80, fineFrames: 3);
    final pushLastOvIdx = pushFrames.lastIndexWhere(
      (f) => f.overlay.progress != null,
    );
    expect(pushLastOvIdx, greaterThanOrEqualTo(0), reason: '飞行窗口内必须画出浮层');
    final pushOv = pushFrames[pushLastOvIdx].overlay;
    final firstCapsule = pushFrames
        .skip(pushLastOvIdx + 1)
        .map((f) => f.capsule)
        .firstWhere((c) => c.drawn,
            orElse: () => throw StateError('push 后胶囊从未渲染'));
    final ovArcPush = _playedArc(
      pushOv.progressBoxRect!,
      formT: pushOv.progress!.formT,
      cornerRadius: pushOv.progress!.cornerRadius,
      progress: pushOv.progress!.progress,
      gapSize: pushOv.progress!.gapSize,
    );
    // 胶囊真身的进度 painter 是 `_SecondaryProgressPainter`（不经过
    // PlayerBarProgressPainter），按其 formT=1 的同一几何口径解算可见本体盒。
    final capBox = firstCapsule.barRect!;
    final capArc = _playedArc(
      capBox,
      formT: 1.0,
      cornerRadius: capBox.height / 2,
      progress: progress,
    );
    debugPrint(
      '[G1-⑤push] 浮层末帧 formT=${pushOv.progress!.formT.toStringAsFixed(4)} '
      '盒=${_fmtR(pushOv.progressBoxRect)} 已播放=${ovArcPush.toStringAsFixed(2)}px | '
      '胶囊真身 盒=${_fmtR(capBox)} 已播放=${capArc.toStringAsFixed(2)}px',
    );
    expect(
      (ovArcPush - capArc).abs(),
      lessThanOrEqualTo(2.0),
      reason: '交棒瞬间已播放段长度差 '
          '${(ovArcPush - capArc).abs().toStringAsFixed(2)}px > 2px',
    );

    // ——— pop：胶囊 → 浮层 → 常驻条 ———
    await tester.tap(find.text('back'));
    final popFrames = await recordContent(tester, 80);
    final popLastOvIdx = popFrames.lastIndexWhere(
      (f) => f.overlay.progress != null,
    );
    expect(popLastOvIdx, greaterThanOrEqualTo(0), reason: '飞行窗口内必须画出浮层');
    final popOv = popFrames[popLastOvIdx].overlay;
    final firstResident = popFrames
        .skip(popLastOvIdx + 1)
        .map((f) => f.resident)
        .firstWhere((c) => c.progress != null,
            orElse: () => throw StateError('pop 后常驻条从未渲染'));
    final ovArcPop = _playedArc(
      popOv.progressBoxRect!,
      formT: popOv.progress!.formT,
      cornerRadius: popOv.progress!.cornerRadius,
      progress: popOv.progress!.progress,
      gapSize: popOv.progress!.gapSize,
    );
    final resArc = _playedArc(
      firstResident.progressBoxRect!,
      formT: firstResident.progress!.formT,
      cornerRadius: firstResident.progress!.cornerRadius,
      progress: firstResident.progress!.progress,
      gapSize: firstResident.progress!.gapSize,
    );
    debugPrint(
      '[G1-⑤pop] 浮层末帧 formT=${popOv.progress!.formT.toStringAsFixed(4)} '
      '盒=${_fmtR(popOv.progressBoxRect)} 已播放=${ovArcPop.toStringAsFixed(2)}px | '
      '常驻条首帧 盒=${_fmtR(firstResident.progressBoxRect)} '
      '已播放=${resArc.toStringAsFixed(2)}px',
    );
    expect(
      (ovArcPop - resArc).abs(),
      lessThanOrEqualTo(2.0),
      reason: '交棒瞬间已播放段长度差 '
          '${(ovArcPop - resArc).abs().toStringAsFixed(2)}px > 2px',
    );
    expect(tester.takeException(), isNull);
  });

  // ───────────────────── O2：静止尾巴不再逐帧重建（省帧） ─────────────────────
  //
  // 飞行窗口 ≈736ms，但可见形变在窗口开头 260ms 就**精确饱和**到端点；窗口后段
  // 浮层渲染的是**完全静止**的端点画面，旧实现却仍每帧重建整棵子树（≈28 帧/次，
  // 120Hz ≈57）。O2 把子树的驱动收敛到一个 `ValueNotifier<double>`：本层仍被窗口
  // 进度逐帧重建（只更新时钟 + 写 notifier），但 notifier 对相同值不 notify ——
  // 饱和后 `visible` 恒为端点常值 → 子树停止逐帧重建。
  //
  // **窗口判据与两端让位一字未动**：窗口仍覆盖整段转场（见 K1 用例），后段仍由
  // 浮层独占（真身不接管）。本用例只证"浮层自己不再逐帧重建"。
  testWidgets('O2：可见形变饱和后浮层不再逐帧重建子树（后段 0 次构建）', (tester) async {
    await pumpHost(tester);

    final int base = barMorphSubtreeBuildCount;
    final vs = <double>[]; // 可见形变进度（浮层 painter.formT，未渲染时 nan）
    final windowOpen = <bool>[];
    final counts = <int>[]; // 每帧累计子树构建次数（相对 base）
    final textWidgets = <Widget?>[]; // 该帧浮层文字块 widget 实例（判同一性）
    await tester.tap(find.text('push'));
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final f = _record(tester, 'O2-$i');
      vs.add(_overlayFormT(tester) ?? double.nan);
      windowOpen.add(f.windowOpen);
      counts.add(barMorphSubtreeBuildCount - base);
      final tf = find.byKey(const ValueKey<String>('morph-bar-text'));
      textWidgets.add(tf.evaluate().isEmpty ? null : tester.widget(tf));
    }

    final windowFrames = <int>[
      for (var i = 0; i < windowOpen.length; i++)
        if (windowOpen[i]) i,
    ];
    final int first = windowFrames.first;
    final int last = windowFrames.last;
    // 「精确饱和」帧 = formT 逐值等于端点 1.0 的第一帧（`Curve.transform` 对
    // t == 1 有精确短路，故饱和后每帧都是 1.0）。其后即"静止尾巴"。
    final int firstExact = vs.indexWhere((v) => v == 1.0);
    final int buildsInWindow = counts[last];
    final int buildsAfterSat = counts[last] - counts[firstExact];
    // 精确饱和帧**之后**的帧数 = 被砍掉的"静止尾巴"；旧实现在这里每帧重建 1 次。
    final int tailFrames = last - firstExact;
    debugPrint(
      '[O2] 窗口帧=[$first..$last]（${windowFrames.length} 帧 ≈ '
      '${windowFrames.length * 16}ms）| 精确饱和帧=$firstExact '
      '（窗口起点 +${(firstExact - first) * 16}ms）| 窗口内子树构建=$buildsInWindow 次 '
      '| 饱和后静止尾巴 $tailFrames 帧内构建=$buildsAfterSat 次 '
      '→ 每次飞行省 $tailFrames 次构建（旧实现 = 每帧 1 次）',
    );

    expect(firstExact, greaterThanOrEqualTo(0), reason: '整段飞行没到精确端点 1.0');
    // ① 静止尾巴不再重建：从精确饱和帧到窗口末帧，子树构建次数**零增长**。
    expect(buildsAfterSat, 0,
        reason: '饱和后仍在逐帧重建子树（$buildsAfterSat 次 / ${last - firstExact} 帧）：'
            '静止尾巴没砍掉');
    // ② 同一性证据（比计数更硬）：饱和后浮层文字块 widget **实例**逐帧同一 ——
    //    没重建就连 widget 对象都不换。
    for (var i = firstExact; i <= last; i++) {
      expect(textWidgets[i], isNotNull, reason: '第 $i 帧浮层文字块不在树（窗口提前关闭）');
      expect(identical(textWidgets[i], textWidgets[firstExact]), isTrue,
          reason: '饱和后第 $i 帧重建了子树（widget 实例变了）');
    }
    // ③ 窗口内整体构建次数远小于窗口帧数：只构建"形变推进"的那十几帧
    //    （≈260ms / 16ms ≈ 17 次），而不是每帧一次（旧实现 = 窗口帧数）。
    expect(buildsInWindow, lessThanOrEqualTo(24),
        reason: '窗口内子树构建 $buildsInWindow 次（窗口 ${windowFrames.length} 帧）：'
            '形变推进段也未能收敛（预期仅 ~17 次）');
    expect(windowFrames.length - buildsInWindow, greaterThanOrEqualTo(8),
        reason: '省帧不明显：窗口 ${windowFrames.length} 帧只省了 '
            '${windowFrames.length - buildsInWindow} 帧');
    // ④ 让位一字未动：饱和后窗口仍开着、可见形变仍停在端点、两端真身不接管。
    for (var i = firstExact; i <= last; i++) {
      expect(windowOpen[i], isTrue, reason: '第 $i 帧窗口提前关闭');
      expect(vs[i], 1.0, reason: '第 $i 帧可见形变从端点回退（${vs[i]}）');
    }
    expect(tester.takeException(), isNull);
  });

  // ── 真机报障回归：设置页切「悬浮迷你播放器」残留旧条，返回主页才消失 ──
  //
  // 生产的触发链（`tickerEnabled: false` 即其等价输入，见 pumpHost 的注释）：
  // 用户停在**推到根 Navigator** 的设置页 → 壳层被不透明路由盖住 → 框架给壳层
  // 所在 Overlay 条目关掉 TickerMode → `_barFormController` 的 ticker 只是静音
  // （`isActive` 仍 true、不产 tick）→ 此刻翻 `kSecondaryPlayerEnabled`：旧实现
  // 照样 `_startBarFormFlight` **开窗**，但 completed/dismissed 永不产生 →
  // `kBarFormFlightActive` 停在 true、进度冻在起飞端点 → 挂在 Navigator 之上的
  // 交棒浮层按端点形状把「切换前那根条」永久画在设置页上面；返回主页解除静音，
  // 动画补跑完才关窗 —— 与用户描述逐字吻合。
  //
  // 修复后的裁决在 `_driveBarFormFlight`：动画跑不起来（壳层不可见 / 已在目标
  // 端点）就**吸附不开窗**。断言三条：窗口不得开着、浮层那根条不得在画、进度
  // 必须落到目标端点（不是冻在起点）。
  testWidgets('壳层被静音（设置页盖住）时切悬浮开关：不开窗、浮层不残留那根条', (
    WidgetTester tester,
  ) async {
    // 整段会话都处在「被盖住」输入下：可见 → 被盖住的过渡由 pumpHost 的
    // tickerEnabled 一次性构造（等价于「已在设置页上」）。
    await pumpHost(tester, tickerEnabled: false);

    // ① 一级页面退回常驻条 → 悬浮条（settingsToggle 交棒线，默认产品形态起点）。
    kSecondaryPlayerOnPrimaryPages.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(kBarFormFlightActive.value, isFalse,
        reason: '静音壳层里交棒不得开窗（开窗=没人关=残条）');
    expect(kBottomBarFormProgress.value, 1.0,
        reason: '吸附必须直接落目标端点，不是冻在起飞端点 0');
    expect(_overlayBarText.evaluate(), isEmpty, reason: '浮层那根条不得在画');
    expect(BottomBarMorphRegistry.instance.frozenResidentRect, isNull,
        reason: '吸附路径不得留下冻结端点');

    // ② 反向（开 → 关）：正是报障操作本身。
    kSecondaryPlayerEnabled.value = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(kBarFormFlightActive.value, isFalse,
        reason: '关悬浮那条同样不得开窗（旧实现在这里把常驻条形态冻在设置页上）');
    expect(kBottomBarFormProgress.value, 0.0, reason: '吸附落到常驻条端点');
    expect(_overlayBarText.evaluate(), isEmpty, reason: '浮层那根条不得在画');

    // ③ 连续来回翻（第二次起控制器已停在目标端点 → `forward()` 的零时长分支
    // 不重复上报同一状态，旧实现同样会开窗不收）：必须持续幂等。
    kSecondaryPlayerEnabled.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(kBarFormFlightActive.value, isFalse, reason: '来回翻不得开窗');
    expect(_overlayBarText.evaluate(), isEmpty, reason: '来回翻不得残留浮层条');

    expect(tester.takeException(), isNull);
  });
}
