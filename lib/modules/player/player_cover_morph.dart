import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show kDebugMode, kProfileMode, visibleForTesting;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart' show FrameTiming, SchedulerBinding;
import 'package:material_ui/material_ui.dart';

import '../../core/layout/ui_density.dart';

/// MiniPlayer 封面圆角（dp）。与 `mini_player.dart` 里 ClipRRect 的取值一致。
const double kCoverMorphMiniRadius = 6.0;

/// FullPlayer 封面圆角（dp）。
/// MD `full_player.dart` 的 `_buildCrossfadeArtworkWrapper` 与 AM
/// `full_player_am.dart` 的 `_buildArtworkWithDynamicCover` 都是 16，改动时需同步。
const double kCoverMorphFullRadius = 16.0;

/// 飞行中的最大倾角（弧度，约 1.5°）。
///
/// 用 `sin(π·t)` 调制：两端为 0（与真实封面完全对齐、不会在交接处跳一下），
/// 中点最大，给机械的直线平移一点生气。
const double kCoverMorphTilt = 0.026;

/// 飞行轨迹的弓高系数：沿直线中点额外上提 `|位移| × 该系数` 的距离。
/// 两端为 0，只让中段略微"抬"一下，避免死板的匀速直线感。
const double kCoverMorphBow = 0.04;

/// 形变插值参数。
///
/// **直接等于** [playerExpansion]：它已经带上了跟手线性 / 松手 easeOutCubic /
/// 点击 expressiveEasing，再叠第二条曲线等于把缓动做两遍，起飞会明显发飘。
double coverMorphT(double expansion) => expansion.clamp(0.0, 1.0);

/// 圆角过渡，返回**局部坐标**下的半径。
///
/// [t] 是形变进度，[scale] 是整棵子树被 `Transform` 缩放的倍数（= 屏幕上显示的
/// 边长 ÷ [kCoverMorphFullRadius] 对应的 settled 边长）。
///
/// **必须除以 [scale]**：`ClipRRect` 的半径写在盒子的局部坐标里，而盒子恒为
/// settled 尺寸（336dp），随后整棵子树被缩放。所以屏幕上的实际圆角 =
/// 局部半径 × scale。不除的话起点处只有 `6 × (44/336) ≈ 0.8dp`，而 MiniPlayer
/// 封面是 6dp —— 交接瞬间圆角会「突变」成近直角。
double coverMorphLocalRadius(double t, double scale) {
  final onScreen = kCoverMorphMiniRadius +
      (kCoverMorphFullRadius - kCoverMorphMiniRadius) * t.clamp(0.0, 1.0);
  return scale <= 0 ? onScreen : onScreen / scale;
}

/// 飞行中的倾角（弧度）：两端 0、中点最大。
double coverMorphTilt(double t) =>
    kCoverMorphTilt * math.sin(math.pi * t.clamp(0.0, 1.0));

/// ── 文字侧的档位（第五轮，治 `textLayout`）────────────────────────────────
///
/// **要治的是什么**：真机仪表 v3 定案，转场期每帧 3~5.6ms 的 UI 成本全在形变层
/// 文字块的重排上（`textLayout` 的 `n` 恰等于帧数 = 每帧都重排，`resid` 只剩
/// 0.8~1.2ms）。根因有两条，缺一都治不干净：
/// 1. `_buildText` 每帧 `TextStyle.lerp` 出一套**新的**字号 / 字重 / 字距 / 行高；
/// 2. 省略号那行拿到的是**逐帧插值出来的紧约束块宽**（中文标题两串通常同串，
///    走的正是那一支），宽度每帧变 → 段落每帧按新宽度重排。
/// 本档位治 (1)，(2) 在 `player_cover_morph_layer.dart` 的 `_buildTextLine` 里
/// 改成无界排版 + 裁切解决（块宽因此保持连续，居中的文字不会台阶式抖）。
///
/// **为什么档位化是安全的**：`TextStyle` 与 `TextSpan` 都是**值相等**语义
/// （`RenderParagraph` 的 `text` setter 里就是 `_text != text` 的判断），
/// 连续几帧拿到同一套**值** → 不标脏 → 段落复用上一帧的排版结果。
/// 所以**不需要缓存实例**：只要「这一帧的值 == 上一帧的值」就已经省下重排，
/// 加一层 memo 反而多出一个失效判据要维护（本仓上一轮刚在 memo 签名上踩过）。
///
/// **为什么是吸附进度 `t`，而不是给每个字段定绝对步长**（第一版就是这么写的，
/// 真机反馈「拖动过程中行间距会突变」）：这些字段的单位根本不一致——`fontSize`
/// 与 `letterSpacing` 是 dp（而 letterSpacing 的量程常常不足 1dp，按 1.0 一档
/// 等于把它从 0 直接抬到 1dp），`height` 是**倍数**（行高 = fontSize × height）。
/// 按 1.0 吸附 `height` 时，两端 1.43 / 1.27 会一起收成 1.0，但插值途中一旦跨过
/// 1.5 就跳到 2.0 —— 行盒当场翻倍，视觉上就是两行之间突然裂开；`fontSize` 按
/// 2dp 一档同样让行盒一跳 2dp。而样式里**任一**字段逐帧变化都会让整套 TextStyle
/// 不相等、照样重排，所以「只量化其中几个字段」也拿不到收益。
/// 吸附 `t` 同时满足两件事：整套样式能连续若干帧保持完全相等（省重排），
/// 而每个字段只走**自己量程的 1/kCoverMorphTextSteps**（跳变量与连续版同量级）。
const int kCoverMorphTextSteps = 8;

/// 把连续进度吸附成 [kCoverMorphTextSteps] 档；非有限值按 0 处理。
double coverMorphTextSteppedProgress(double t) {
  if (!t.isFinite) return 0.0;
  final p = t.clamp(0.0, 1.0);
  return (p * kCoverMorphTextSteps).roundToDouble() / kCoverMorphTextSteps;
}

/// 档位化进度后的文字样式插值——[TextStyle.lerp] 的替身。
///
/// `t=0` / `t=1` 由吸附天然给出 0.0 / 1.0，所以两端**逐位等于**真实迷你条 /
/// 播放页的样式，交接那一帧不会差半档（真实字号常常不在整数档位上，例如 15→25）。
TextStyle? coverMorphLerpTextStyle(TextStyle? a, TextStyle? b, double t) =>
    TextStyle.lerp(a, b, coverMorphTextSteppedProgress(t));

/// 播放页封面**布局矩形**经缩放后的**真实屏幕矩形**。
///
/// [scale] 为 1.0（播放中）时恒等于 [layout]；暂停时播放页封面会缩到 0.85，
/// 此时形变层必须落到缩小后的矩形，否则松手瞬间真实封面会再动画缩一次。
/// [anchor] 是播放页 `AnimatedScale` 的 `alignment`（横竖屏均 center：封面绕自身
/// 视觉中心收，暂停态才不会偏离所在栏的中轴），决定往哪个角收。
Rect coverSettledVisualRect({
  required Rect layout,
  required double scale,
  required Alignment anchor,
}) {
  if (scale <= 0 || scale == 1.0) return layout;
  final anchorOffset = anchor.alongSize(Size(layout.width, layout.height));
  return Rect.fromLTWH(
    layout.left + anchorOffset.dx * (1 - scale),
    layout.top + anchorOffset.dy * (1 - scale),
    layout.width * scale,
    layout.height * scale,
  );
}

/// 本帧的封面目标矩形：两端与端点严格相等，中间带一点向上弓高。
///
/// 两端必须是**严格的端点矩形**（`t` 取 0/1 时不叠弓高），否则形变层在
/// `playerExpansion` 跨过 0 / 1 那一刻与真实封面之间会出现亚像素错位。
Rect coverMorphTargetRect({
  required Rect mini,
  required Rect settled,
  required double t,
}) {
  final e = t.clamp(0.0, 1.0);
  final base = Rect.lerp(mini, settled, e)!;
  if (e <= 0.0 || e >= 1.0) return base;
  final travel = (settled.center.dy - mini.center.dy).abs();
  final lift = -travel * kCoverMorphBow * math.sin(math.pi * e);
  return base.shift(Offset(0, lift));
}

/// 把「本帧实测的封面矩形」换算成「页面归位（dy=0）时的矩形」。
///
/// [measured] 是探针在 **paint 阶段**量到的屏幕矩形（已含页面自身的 `dy` 位移
/// 与 `DisplayScaleScope` 的 `FittedBox` 缩放）；[pageOffset] 是页面在
/// **build 阶段**登记的位移（页面本地坐标）；[pageToScreen] 是页面本地 →
/// 屏幕的缩放比。
///
/// **为什么两者必须同帧取值**：`RenderTransform._effectiveTransform` 在 `paint()`
/// 里才更新，build 阶段读到的是上一帧的值。若用 build 期的 `playerExpansion`
/// 配 paint 期的 `measured` 反推归位矩形，松手 300ms 内页面每帧可移动
/// 100~250px，封面会肉眼可见地"慢半拍追页面"。这里 [pageOffset] 与 [measured]
/// 取自同一帧（N 帧 build 写 offset、N 帧 paint 量矩形），dy 被精确抵消，
/// 结果与 `Transform` 的更新时机无关。
///
/// [pageToScreen] 只能实测（不能用 `ThemeProvider.displayScale` 反推），
/// 因为缩放比一旦与实际不符，抵消就不干净。
Rect coverMorphSettledRect({
  required Rect measured,
  required Offset pageOffset,
  required double pageToScreen,
}) =>
    measured.shift(-pageOffset * pageToScreen);

/// 封面形变的全局登记簿（多写一读）。
///
/// 写入方：
/// - MiniPlayer 的 [CoverGeometryProbe] → [publishMini]
/// - 播放页的 [CoverGeometryProbe]（经 `PlayerCoverSlot`）→ [publishFull]
/// - 路由过渡 / 拖拽覆盖层 → [pageOffset] 字段
///
/// 读取方：`PlayerCoverMorphLayer`。
///
/// **只写不清**：`playerExpansion ∈ (0,1)` 的任何时刻都必然存在一个存活的
/// FullPlayer（拖拽期是覆盖层里那个，交接后是路由里那个），残留的陈旧值永远
/// 读不到；反倒是"dispose 时清空"会在交接帧制造一帧空洞——覆盖层先销毁、
/// 路由还没画，形变层就会闪一下。
class PlayerCoverMorphBus {
  PlayerCoverMorphBus._();

  static final PlayerCoverMorphBus instance = PlayerCoverMorphBus._();

  /// MiniPlayer 封面在屏幕上的矩形（由**可见**的那份 MiniPlayer 上报）。
  Rect? miniRect;

  /// FullPlayer 封面「页面归位」后的屏幕矩形。
  Rect? settledRect;

  /// 页面本地 → 屏幕的缩放比（`DisplayScaleScope` 非 1.0 档位时 ≠ 1）。
  double pageToScreen = 1.0;

  /// 页面本帧施加的位移（页面本地坐标），由路由过渡 / 拖拽覆盖层在 build 阶段写入。
  Offset pageOffset = Offset.zero;

  /// **封面**形变是否可用。频谱圆盘 / 写真 / 3D 深度封面 / 动态封面 /
  /// 车机常驻面板为 false，此时封面一侧完全不介入，行为与改动前完全一致。
  /// 文字一侧另有 [textEligible]（与本字段**故意不同源**）。
  bool eligible = false;

  /// 形变层画什么（与两端保持同一套参数，保证交接处像素级对齐）。
  String? artworkUri;
  String? fallbackFilePath;
  double iconSize = 48.0;
  Color placeholderColor = const Color(0xFF000000);

  /// 播放页封面的阴影色（宿主页面的 `colorScheme.shadow`），由槽位经
  /// [publishFull] 一并上报。形变飞行途中阴影由形变层代画并随进度淡入
  /// （迷你端无阴影），否则阴影只在两端由真实封面画——展开/收起那一刻会
  /// 突现/突消。null（测试裸挂 / 槽位未上报）时形变层不画阴影，与旧行为一致。
  ///
  /// 由槽位上报而不是形变层自己 `Theme.of`：形变层挂在 app.dart 的 Stack 里、
  /// 在两个播放页路由**之外**，取到的 ColorScheme 未必是播放页正在用的那套。
  Color? shadowColor;

  /// 登记的歌曲 id：切歌后旧值立即失效，避免用 A 的封面飞向 B 的位置。
  String? songId;

  /// 播放页封面**稳定态**的缩放：播放中 1.0，暂停 0.85（频谱圆盘恒 1.0）。
  ///
  /// 探针刻意放在 `AnimatedScale` **外层**，量到的是**布局矩形**（永远满尺寸）。
  /// 暂停时真实封面会缩到 0.85，若形变层仍按满尺寸收尾，松手那一刻形变层消失、
  /// 真实封面恢复，`AnimatedScale` 就从 1.0 动画缩到 0.85 —— 表现为
  /// "松手后还有个缩放动画"。登记这个值让形变层直接落到**暂停态**的真实矩形，
  /// 交接瞬间两者已重合，一步到位。
  double settledArtworkScale = 1.0;

  /// 播放页 `AnimatedScale` 的 `alignment`（竖屏封面 tab 是 center，
  /// 横屏/平板左栏是 bottomLeft）。决定缩小时往哪个角收。
  Alignment settledArtworkAnchor = Alignment.center;

  // ── 文字形变（歌曲名 + 歌手） ──
  //
  // 与封面同一套机制，但**不做整体缩放**：迷你条与播放页的「文字/封面尺寸比」
  // 根本不同（14px/44px ≈ 0.32 vs 24px/300px ≈ 0.08），同一个缩放系数不可能
  // 同时对上两端，硬缩放还会把放大那一侧糊掉。
  // 因此文字**盒子和字号各自插值**：`TextStyle.lerp` 插值字号/字重/字距，
  // 矩形用 `coverMorphTargetRect` 插值，内容只在中段做交叉淡入。
  // 结果：t=0 与真实迷你文字逐像素一致，t=1 与真实标题一致，全程清晰。

  /// 迷你条「标题 + 歌手」文字块在屏幕上的矩形。
  Rect? miniTextRect;
  /// 播放页标题块「页面归位」后的屏幕矩形。
  Rect? settledTextRect;

  String? miniTitleText;
  String? miniSubtitleText;
  TextStyle? miniTitleStyle;
  TextStyle? miniSubtitleStyle;

  String? fullTitleText;
  String? fullSubtitleText;
  TextStyle? fullTitleStyle;
  TextStyle? fullSubtitleStyle;

  /// 播放页标题块的水平对齐（竖屏居中 / 横屏左对齐），飞行途中从"左对齐"过渡过去。
  Alignment fullTitleAlign = Alignment.centerLeft;

  /// 本次转场是否接管文字块。
  ///
  /// 与封面的 [eligible] **不同源**（各自锁存，见 [latchedTextEligible]）：
  /// 频谱圆盘 / 写真只压封面一侧，文字照飞。分开存只是为了让「槽位隐藏条件」与
  /// 「形变层绘制条件」逐字一致，不会出现某一侧被判据差异漏掉而留出空洞。
  bool textEligible = false;

  /// 系统「减弱动态效果」是否开启。
  ///
  /// 由 PlayerCoverMorphLayer 每次 build 时从 `MediaQuery` 刷新。置 true 时形变
  /// **整体关闭**（绘制侧与两端让位侧同时失效，判据同源，不会留出"谁都不画"的
  /// 空洞），转场退化为纯交叉淡入淡出；`playerExpansion` 仍照常被路由写成端点值。
  bool reducedMotion = false;

  /// 形变层本帧是否画文字块。
  bool get textWillDraw {
    if (reducedMotion) return false;
    if (!playerCoverVisible.value) return false;
    if (!textEligible) return false;
    final a = miniTextRect;
    final b = settledTextRect;
    if (a == null || b == null || b.width <= 0 || b.height <= 0) return false;
    return true;
  }

  /// 登记内容或资格变化时通知形变层重建（形变层平时只监听 `playerExpansion`，
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  void _bump() => revision.value++;

  /// 形变层**本帧是否真的会画**。
  ///
  /// [PlayerCoverSlot] 必须用**同一个**判据决定"要不要隐藏真实封面"。
  /// 两者判据一旦不一致，就会出现「形变层不画 + 真实封面已被隐藏」=
  /// 整段转场封面凭空消失——正是槽位无条件隐藏、形变层却在 `eligible == false`
  /// 时拒绝绘制所导致的回退路径劣化。
  ///
  /// [playerCoverVisible] 在这里求值而不是只进 `eligible`：后者由槽位在
  /// **它自己那一页**的 build 里算出，竖屏停在歌词 / 评论 tab 时封面槽位根本不
  /// 构建，判断就永远不会被求值、`eligible` 会停在过期值。本判据在**绘制那一刻**
  /// 由常驻的形变层 / MiniPlayer 读取，才真正拦得住。
  bool willDraw({required bool eligible}) {
    if (reducedMotion) return false;
    if (!playerCoverVisible.value) return false;
    if (!eligible) return false;
    if (miniRect == null) return false;
    final s = settledRect;
    if (s == null || s.width <= 0 || s.height <= 0) return false;
    return true;
  }

  /// 形变层是否**此刻**真的会画（用登记簿里已记录的 `eligible`）。
  ///
  /// MiniPlayer 用它决定自己的封面要不要让位——判据与形变层、播放页槽位
  /// 三方同源，不会出现「谁也不画 → 封面凭空消失」。
  bool get layerWillDraw => willDraw(eligible: eligible);

  /// 写真封面生效时置 true：**封面**形变整体关闭（页面上没有方形封面可交接，
  /// 飞行中的专辑封面会「突然出现」——真机反馈）。**文字形变不受影响**。
  ///
  /// 与 [eligible] 分离：eligible 在转场起点锁存且封面/文字共用，
  /// 本标志每帧现算，只作用于封面一侧的绘制与让位判据。
  bool coverSuppressed = false;

  /// [coverSuppressed] 的**写入者令牌**（登记最后一次写 true 的页面实例）。
  ///
  /// 拖拽交接时两个 FullPlayer 实例短暂共存：路由实例首建写 true 后，
  /// 覆盖层实例才 dispose——若无条件复位会把刚写上的 true 抹掉，整个
  /// fling 期间页面子树不再重建、无人补写，专辑封面就会重新起飞
  /// （真机日志实锤：morph cover DRAW suppressed=false）。dispose 只允许
  /// 由当前 owner 复位；被接管（owner≠this）时跳过。
  Object? coverSuppressOwner;

  /// 形变层此刻是否画封面 = 原有交接判据 && 未被写真抑制。
  /// MiniPlayer 的让位判断必须用同一判据（三方同源，防止谁都不画的空洞）。
  bool get coverLayerWillDraw => !coverSuppressed && layerWillDraw;

  /// 本次转场**锁存**的封面侧资格（null = 不在转场中 / 尚未锁存）。
  bool? latchedCoverEligible;

  /// 本次转场**锁存**的文字侧资格。
  ///
  /// **刻意与 [latchedCoverEligible] 分成两路**：频谱圆盘（圆形裁切 + 旋转，
  /// 形变层还原不出）与写真封面只抑制**封面**一侧，文字形变照旧（用户要求）。
  /// 共用一个锁存时「先到者胜」会把某一侧的答案强加给另一侧 —— 表现为
  /// 圆盘开着时歌名跟着飞、封面也跟着飞（本该只飞歌名）。
  bool? latchedTextEligible;

  /// 解析本次转场的**封面**形变资格：**在转场起点锁存，全程不再改变**。
  ///
  /// 为什么必须锁存、不能实时求值：资格一旦在转场途中翻转，形变层会立刻停画、
  /// 槽位同时交还真实封面 —— 表现就是「上拉一点、封面刚动一下动画就被打断」。
  /// 这个坑真机上出现过两次：一次是资格里含 `_dynamicCoverActive`（视频在播放页
  /// 挂载约 250ms 后就绪，正好落在拖拽途中），一次是锁存没在 p=0 复位导致上一程的
  /// 「不合格」泄漏到下一程。
  /// 现在资格本身已经只含转场期间不变的结构条件，锁存作为**不变量护栏**保留：
  /// 将来若有人再往资格里加异步状态，这里也保证它不会半路改判。
  ///
  /// 锁存语义：转场开始时合格 → 全程接管；开始时不合格 → 全程回退。
  /// 两端（p=0 / p=1）清除锁存，下一次离开端点时重新判定。
  ///
  /// 放在登记簿而不是各槽位自己存：拖拽期是覆盖层那个播放页、交接后是路由那个，
  /// 中途换人；锁存必须跨实例存活，否则新实例会用**途中**的值重新锁存。
  ///
  /// **资格必须是同步可读的**：跟手覆盖层里的播放页是当场新建的，首帧就在
  /// 0<p<1，此时它自己的异步偏好（频谱开关）必然还是默认值。判据里凡是异步
  /// 状态，一律先落成全局镜像（见 `kSpectrumDiscCoverActive`）。
  bool resolveCoverEligible({required double expansion, required bool live}) {
    if (expansion <= 0.0 || expansion >= 1.0) {
      latchedCoverEligible = null;
      return live;
    }
    final latched = latchedCoverEligible;
    if (latched != null) return latched;
    latchedCoverEligible = live;
    return live;
  }

  /// 文字侧资格，锁存语义与 [resolveCoverEligible] 完全相同，只是**独立**存放。
  bool resolveTextEligible({required double expansion, required bool live}) {
    if (expansion <= 0.0 || expansion >= 1.0) {
      latchedTextEligible = null;
      return live;
    }
    final latched = latchedTextEligible;
    if (latched != null) return latched;
    latchedTextEligible = live;
    return live;
  }

  /// MiniPlayer 上报自己的封面矩形。
  void publishMini(Rect rect) {
    if (miniRect == rect) return;
    miniRect = rect;
    _bump();
  }

  /// MiniPlayer 上报「歌曲名 + 歌手」文字块。
  void publishMiniText({
    required Rect rect,
    required String title,
    required String subtitle,
    required TextStyle? titleStyle,
    required TextStyle? subtitleStyle,
  }) {
    final changed = miniTextRect != rect ||
        miniTitleText != title ||
        miniSubtitleText != subtitle ||
        miniTitleStyle != titleStyle ||
        miniSubtitleStyle != subtitleStyle;
    miniTextRect = rect;
    miniTitleText = title;
    miniSubtitleText = subtitle;
    miniTitleStyle = titleStyle;
    miniSubtitleStyle = subtitleStyle;
    if (changed) _bump();
  }

  /// 播放页上报「标题块」的目标矩形、两套文字与绘制参数。
  ///
  /// 与 [publishFull] 同样只填不画；`measured` 与 `pageOffset` 必须同帧取值
  /// （见 [coverMorphSettledRect]）。
  void publishFullText({
    required Rect measured,
    required Size logicalSize,
    required Offset pageOffset,
    required String title,
    required String subtitle,
    required TextStyle? titleStyle,
    required TextStyle? subtitleStyle,
    required Alignment align,
    required bool eligible,
  }) {
    final scale = (logicalSize.width <= 0 || measured.width <= 0)
        ? 1.0
        : measured.width / logicalSize.width;
    final settled = coverMorphSettledRect(
      measured: measured,
      pageOffset: pageOffset,
      pageToScreen: scale,
    );
    final changed = settledTextRect != settled ||
        fullTitleText != title ||
        fullSubtitleText != subtitle ||
        fullTitleStyle != titleStyle ||
        fullSubtitleStyle != subtitleStyle ||
        fullTitleAlign != align ||
        textEligible != eligible;
    settledTextRect = settled;
    fullTitleText = title;
    fullSubtitleText = subtitle;
    fullTitleStyle = titleStyle;
    fullSubtitleStyle = subtitleStyle;
    fullTitleAlign = align;
    textEligible = eligible;
    if (changed) _bump();
  }

  /// 播放页上报「归位后的封面矩形」与绘制参数。
  ///
  /// [logicalSize] 是探针子树的**布局**尺寸（页面本地坐标）；[measured] 是同一次
  /// paint 量到的屏幕矩形。缩放比由二者相除得出。
  void publishFull({
    required Rect measured,
    required Size logicalSize,
    required Offset pageOffset,
    required String? songId,
    required String? artworkUri,
    required String? fallbackFilePath,
    required double iconSize,
    required Color placeholderColor,
    Color? shadowColor,
    required bool eligible,
    required double settledArtworkScale,
    required Alignment settledArtworkAnchor,
  }) {
    final scale = (logicalSize.width <= 0 || measured.width <= 0)
        ? 1.0
        : measured.width / logicalSize.width;
    final settled = coverMorphSettledRect(
      measured: measured,
      pageOffset: pageOffset,
      pageToScreen: scale,
    );
    // 归位矩形在一次转场里是常量（页面布局不变，只有 dy 在动），所以逐帧
    // publishFull 通常不会触发 _bump；只有真正变化（切歌 / 转屏 / 资格翻转）
    // 才通知形变层，避免播放页每次重绘都空转重建一次形变层。
    // 与参数同名的字段必须保留 `this.` 前缀以便区分；未遮蔽的去掉以免
    // 触发 unnecessary_this。
    final changed =
        settled != settledRect ||
        scale != pageToScreen ||
        songId != this.songId ||
        artworkUri != this.artworkUri ||
        fallbackFilePath != this.fallbackFilePath ||
        iconSize != this.iconSize ||
        placeholderColor != this.placeholderColor ||
        shadowColor != this.shadowColor ||
        eligible != this.eligible ||
        settledArtworkScale != this.settledArtworkScale ||
        settledArtworkAnchor != this.settledArtworkAnchor;
    settledRect = settled;
    pageToScreen = scale;
    this.songId = songId;
    this.artworkUri = artworkUri;
    this.fallbackFilePath = fallbackFilePath;
    this.iconSize = iconSize;
    this.placeholderColor = placeholderColor;
    this.shadowColor = shadowColor;
    this.eligible = eligible;
    this.settledArtworkScale = settledArtworkScale;
    this.settledArtworkAnchor = settledArtworkAnchor;
    if (changed) _bump();
  }

  /// 仅供测试隔离使用。
  @visibleForTesting
  void reset() {
    miniRect = null;
    settledRect = null;
    pageToScreen = 1.0;
    pageOffset = Offset.zero;
    eligible = false;
    artworkUri = null;
    fallbackFilePath = null;
    iconSize = 48.0;
    placeholderColor = const Color(0xFF000000);
    shadowColor = null;
    songId = null;
    settledArtworkScale = 1.0;
    settledArtworkAnchor = Alignment.center;
    latchedCoverEligible = null;
    latchedTextEligible = null;
    miniTextRect = null;
    settledTextRect = null;
    miniTitleText = null;
    miniSubtitleText = null;
    miniTitleStyle = null;
    miniSubtitleStyle = null;
    fullTitleText = null;
    fullSubtitleText = null;
    fullTitleStyle = null;
    fullSubtitleStyle = null;
    fullTitleAlign = Alignment.centerLeft;
    textEligible = false;
    reducedMotion = false;
    _bump();
  }
}

/// 封面此刻是否真的可见（形变资格里**与「哪个 FullPlayer 实例」无关**的那部分）。
///
/// **只装「结构门」**（车机面板 + 当前 tab 是否含封面），**不装封面独有的压制项**
/// （频谱圆盘 / 写真）：本信号被封面与文字两侧共用（[PlayerCoverMorphBus.willDraw]
/// 与 `textWillDraw` 都读它），把封面那一侧的答案写进来会把文字连贯一起掐掉。
/// 封面独有的压制走各自锁存的 `eligible` / `textEligible`。
///
/// 为什么要做成全局信号，而不是让槽位各自判断：
/// 槽位只在**自己那一页被构建时**才会执行判断。竖屏停在歌词 / 评论 tab 时，
/// 封面 tab 的槽位**根本不构建**，那个判断就永远不会被求值 —— `eligible` 会一直
/// 停在封面 tab 上一次留下的 `true`，于是下拉收起照样飞出封面和歌名。
/// （这正是「把 tab 条件加进槽位资格」完全无效的原因。）
///
/// 判定必须放在**绘制那一刻**求值，而形变层与 MiniPlayer 都是常驻的，所以信号
/// 由播放页在 tab / 结构变化时写入，由 [PlayerCoverMorphBus.willDraw] 在绘制时读取。
final ValueNotifier<bool> playerCoverVisible = ValueNotifier<bool>(true);

/// 在 **paint 阶段**把自己在屏幕上的矩形上报出去的探针。
///
/// 为什么不挂 `GlobalKey`：
/// - MiniPlayer 的封面在 `AnimatedSwitcher` 里，切歌过渡期间新旧两份同时存在，
///   同一个 GlobalKey 挂两份会直接触发 "Duplicate GlobalKey" 断言；
/// - 探针是 `RenderProxyBox`，两份并存也只是"后画的那份赢"，而两份位置本就重合。
///
/// 为什么在 paint 而不是 build / post-frame：
/// 祖先 `Transform.translate` 的矩阵到 paint 阶段才生效（见
/// [coverMorphSettledRect] 的说明），这是拿到"变换后屏幕矩形"的唯一正确时机。
///
/// 回调里**只允许写全局字段，不得 `setState`**（paint 阶段触发重建会崩）。
class CoverGeometryProbe extends SingleChildRenderObjectWidget {
  const CoverGeometryProbe({
    super.key,
    required this.onRect,
    // 走父类的 `child` 字段（`Widget get child`），不再重复声明一份：
    // 重复声明会触发 overridden_fields / annotate_overrides。
    required Widget super.child,
  });

  /// 参数：屏幕矩形 + 子树的布局尺寸（页面本地坐标）。
  final void Function(Rect screenRect, Size logicalSize) onRect;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      // 锚点在第二帧才挂进子树（DisplayScaleAnchor post-frame 回填），
      // 那时探针整棵**重新 mount**、只走 createRenderObject，不补这里
      // spaceRef 会永远停在 null（上报仍是窗口像素）。
      _RenderCoverGeometryProbe(onRect)
        ..spaceRef = DisplayScaleReference.anchorOf(context);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderCoverGeometryProbe)
      ..onRect = onRect
      // 设计像素锚点；不在 DisplayScaleScope 内为 null → 回退根空间（现状不变）。
      ..spaceRef = DisplayScaleReference.anchorOf(context);
  }
}

class _RenderCoverGeometryProbe extends RenderProxyBox {
  _RenderCoverGeometryProbe(this._onRect);

  void Function(Rect screenRect, Size logicalSize) _onRect;

  set onRect(void Function(Rect screenRect, Size logicalSize) value) =>
      _onRect = value;

  /// 测量目标空间（[DisplayScaleScope] 锚点）；null = RenderView 根。
  RenderObject? spaceRef;

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    if (!attached || !hasSize) return;
    // 必须用 transformRect 而非 `localToGlobal(Offset.zero) & size`：
    // 后者的宽高取自**布局**尺寸（页面本地坐标），祖先的缩放根本进不了
    // 上报的矩形，页面位移换算时就会整体偏移。
    // 变换目标为**锚点空间（设计像素）**：形变层与探针同处 DisplayScaleScope
    // 的 FittedBox 内，量到窗口像素再画进设计空间会偏 s 倍（0.9/1.1 档过渡
    // 偏差的根因）。锚点空间内祖先链无缩放，`pageToScreen` 恒 ≈1，dy 抵消
    // 仍然成立且不再依赖实测缩放比；无锚点（测试裸挂探针）时 spaceRef 为
    // null，getTransformTo(null) ≡ 变换到根，保留旧行为与实测。
    // 实测 + 上报整段计入 `probe` 热点（publishX 里的逐字段比较也在其中）。
    // release 直接调 `_measureAndReport()`：热点包装要求传一个闭包，而这个探针在
    // release 的渲染树里每帧都跑，不该为它每帧分配一个闭包对象。
    if (coverMorphPerfLogEnabled) {
      coverMorphHot<void>('probe', _measureAndReport);
    } else {
      _measureAndReport();
    }
  }

  void _measureAndReport() {
    final rect = MatrixUtils.transformRect(
      getTransformTo(spaceRef),
      Offset.zero & size,
    );
    coverMorphDebugCountProbeMeasure();
    _onRect(rect, size);
  }
}

/// 封面形变（mini→full）的**常驻/转场成本**计数器。
///
/// 生效范围是 **debug + profile**：profile 才是测真实性能的档（AOT + 预热好的 SkSL），
/// 而本仓 `dumpsys gfxinfo` 的帧数不可信，只能靠应用内计数器读数（AGENTS.md 第 0 节
/// 第 1 条：状态判断必须以日志为准）——取证用的包必须能在 profile 下出数。
/// release 下 `kDebugMode || kProfileMode` 恒为 false，分支被常量折叠掉、零残留。
///
/// 取证日志的生效档（debug + profile），供**本模块之外**的取证代码复用
/// （目前是 `mini_player.dart` 的封面纹理预热日志）。判据必须与 [_kPerfTraceEnabled] 同源：
/// 只认 `kDebugMode` 的话 profile 包一行都不出，而 profile 才是测真实性能的档。
const bool coverMorphPerfLogEnabled = kDebugMode || kProfileMode;

/// 本文件内部的同名别名：计数器、`[CoverMorphPerf]` 摘要日志与预热日志共用一个判据，
/// 避免两处各写一遍 `kDebugMode || kProfileMode` 而悄悄分叉。
const bool _kPerfTraceEnabled = coverMorphPerfLogEnabled;

int playerCoverMorphDebugLayerBuilds = 0;
int playerCoverMorphDebugArtworkBuilds = 0;
int playerCoverMorphDebugProbeMeasures = 0;

void coverMorphDebugCountLayerBuild() {
  if (_kPerfTraceEnabled) playerCoverMorphDebugLayerBuilds++;
}

void coverMorphDebugCountArtworkBuild() {
  if (_kPerfTraceEnabled) playerCoverMorphDebugArtworkBuilds++;
}

void coverMorphDebugCountProbeMeasure() {
  if (_kPerfTraceEnabled) playerCoverMorphDebugProbeMeasures++;
}

/// 仅供测试：把三个计数清零。
@visibleForTesting
void coverMorphDebugResetCounters() {
  playerCoverMorphDebugLayerBuilds = 0;
  playerCoverMorphDebugArtworkBuilds = 0;
  playerCoverMorphDebugProbeMeasures = 0;
}

/// 转场收口（`playerExpansion` 落到 0/1 端点）时打一行成本摘要，随后清零，
/// 使每段转场各出一行、可直接比对。debug / profile 生效，release 不打印。
///
/// 期望读法：`builds` ≈ 该段转场的帧数（**降了说明逐帧重建被打破，是回归**），
/// `artwork` 应为 1（签名全程不变时）。
void coverMorphDebugLogFlight(PlayerCoverMorphBus bus) {
  if (!_kPerfTraceEnabled) return;
  if (playerCoverMorphDebugLayerBuilds == 0) return;
  // ignore: avoid_print
  print(
    '[CoverMorphPerf] flight builds=$playerCoverMorphDebugLayerBuilds '
    'artwork=$playerCoverMorphDebugArtworkBuilds '
    'probe=$playerCoverMorphDebugProbeMeasures rev=${bus.revision.value}',
  );
  coverMorphDebugResetCounters();
}

/// 转场期间的 **UI / Raster 线程归因**探针（仅 debug / profile）。
///
/// **为什么还要它**：上面三个计数器只回答「谁在逐帧重建」，回答不了「卡在哪条线程」，
/// 而本仓 `dumpsys gfxinfo` 的帧数不可信。`FrameTiming` 由引擎在每帧结束后送达，
/// 把一帧拆成 `buildDuration`（UI 线程：build / layout / 录制 paint）与
/// `rasterDuration`（Raster 线程：真正栅格化）。下一步该「少重建」还是「少栅格化」
/// 只能由这两个数决定——猜错方向就是白做一轮。顺带给出转场期**实测帧率**
/// （`(帧数-1) ÷ 首末帧间隔`），这就是 gfxinfo 本该给我们的那个数。
///
/// **收口时机（按此读日志才不会误判）**：端点那次 build 只把桶标成 closing，**不立刻打印**。
/// 引擎是异步上报 timing 的，端点立刻收口会稳定漏掉最后 1~2 帧，把 `build` / `raster`
/// 的 max 报得偏乐观。所以真正的一行由**下一批到达的 timing**触发冲刷（正常就是紧接着
/// 的那一帧）；若屏幕此后完全静止、再没有帧上报，则这行会推迟到**下一段转场起爆**时
/// 才打出来——样本不丢，只是迟到。两段的样本永远各成一行，不混。
///
/// **这里刻意不用 `Timer` 做尾窗**：本探针会被任何 pump 过形变层的 widget 测试连带触发，
/// 挂着的 Timer 会让那些毫不相干的测试报「A Timer is still pending」而失败（实测踩过）。
///
/// 回调挂上后常驻到进程结束（仅 debug / profile）：反复注销重挂会让跨转场的那几帧
/// 归属丢失，而空转成本只是一次小 List 遍历。
class CoverMorphFrameTrace {
  CoverMorphFrameTrace._();

  static final CoverMorphFrameTrace instance = CoverMorphFrameTrace._();

  /// 一帧的时间预算：120Hz 约 8ms（`dart:ui` 的 `FrameTiming` 文档口径）。
  /// `build` 或 `raster` 任一超它即计入 `over8`，用来回答「这段转场掉了几帧」。
  static const int _frameBudgetUs = 8000;

  bool _listenerAttached = false;
  bool _open = false;
  bool _closing = false;
  final Stopwatch _wall = Stopwatch();

  int _frames = 0;
  int _firstFrameUs = 0;
  int _lastFrameUs = 0;
  int _timed = 0;
  int _buildSumUs = 0;
  int _buildMaxUs = 0;
  int _rasterSumUs = 0;
  int _rasterMaxUs = 0;
  int _overBudget = 0;
  String _lastSummary = '';
  final List<String> _summaries = [];

  /// 相邻两帧的间隔（微秒），用来算中位/p95/max。
  final List<int> _intervalsUs = [];

  /// 本段最坏的几帧（总跨度 / UI / GPU，单位微秒），跨度大的在前。见 [_noteWorst]。
  final _worst = <({int span, int ui, int gpu})>[];

  /// UI 线程热点归因：key → 累计/峰值/次数（见 [coverMorphHot]）。
  final Map<String, _CoverMorphUsAccum> _hot = {
    for (final key in coverMorphHotKeys) key: _CoverMorphUsAccum(),
  };

  /// 转场窗口内整页 build 的次数（理想是 0：页面应作为 `child` 被复用，
  /// 只由外层面板裁剪。一旦 > 0 就说明整页在逐帧重建，那是 UI 侧最大的一笔）。
  int _pageBuilds = 0;
  final Set<int> _pageInstances = <int>{};
  int? _pageFirstFrame;

  /// 本段是否出现过「拖拽覆盖层活着」的帧 → `kind=drag`，否则 `kind=tap`。
  bool _dragSeen = false;

  /// 首/末帧的展开进度 → `dir=expand|collapse`。
  double _progressFirst = 0;
  double _progressLast = 0;

  /// 转场中每帧调用一次（形变层的 in-flight build）。
  ///
  /// [progress] 与 [drag] 用来给**整段转场贴身份**（仪表 v3）：本轮实测发现
  /// 「最卡的段」与「建页最多的段」根本不是同一批，而日志里的段自己说不出
  /// 「我是拖拽起飞还是点按起飞、是展开还是收起」，只能靠帧数与时间戳猜。
  /// 身份错配过一次判据（B3 的 `pageInst/pageFirst` 判据被这轮数据否证），
  /// 所以从现在起每行都必须自带 `kind=` / `dir=`。
  void noteFlightFrame({required double progress, required bool drag}) {
    if (!_kPerfTraceEnabled) return;
    // 上一段还在等尾批，新转场就起爆了：先冲刷，两段的样本不混进同一行。
    if (_closing) _flush();
    if (!_open) _startBucket();
    _open = true;
    _closing = false;
    final now = _wall.elapsedMicroseconds;
    if (_frames > 0) _intervalsUs.add(now - _lastFrameUs);
    if (_frames == 0) {
      _firstFrameUs = now;
      _progressFirst = progress;
    }
    _lastFrameUs = now;
    _progressLast = progress;
    if (drag) _dragSeen = true;
    _frames++;
  }

  /// 记录某个 UI 热点本帧花了多少微秒。
  void noteHot(String key, int us) => _hot[key]?.add(us);

  /// 记录一次整页 build。**只统计飞行中的**：落位后的尾批里页面还会重建若干次
  /// （歌词提交就是在端点之后冲刷的），无门槛累加会把它们算进本段、
  /// 让 `pageBuilds` 虚高到看不出问题出在哪一帧（实测曾因此报成 6）。
  ///
  /// 同时记**实例数**与**首次发生时的进度**：`FullPlayer.build` 被调用既可能是
  /// 同一实例被反复重建（要治），也可能是「拖拽期覆盖层新建实例、松手后路由又接管
  /// 一个」这种**实例创建**（属设计固有，不是 bug）。只报次数会把两者混为一谈，
  /// 上一轮我就是因此误判过成因。
  void notePageBuild(Object host) {
    if (!_kPerfTraceEnabled || !_open) return;
    _pageBuilds++;
    _pageInstances.add(identityHashCode(host));
    // 记在飞行期的**第几帧**（不是进度值）：本文件不引 full_player_route，
    // 而 `_frames` 已经是飞行帧序号，足够区分「一起飞就建」与「快落位才建」。
    _pageFirstFrame ??= _frames;
  }

  /// 转场收口（`playerExpansion` 落到 0/1 端点）：只标 closing，
  /// 真正的一行由下一批到达的 timing（或下一段转场起爆）冲刷出来。
  void closeFlight() {
    if (!_kPerfTraceEnabled || !_open) return;
    _open = false;
    _closing = true;
  }

  void _startBucket() {
    _frames = 0;
    _firstFrameUs = 0;
    _lastFrameUs = 0;
    _timed = 0;
    _buildSumUs = 0;
    _buildMaxUs = 0;
    _rasterSumUs = 0;
    _rasterMaxUs = 0;
    _overBudget = 0;
    _pageBuilds = 0;
    _pageInstances.clear();
    _pageFirstFrame = null;
    _dragSeen = false;
    _progressFirst = 0;
    _progressLast = 0;
    _intervalsUs.clear();
    _worst.clear();
    for (final accum in _hot.values) {
      accum.reset();
    }
    _wall
      ..reset()
      ..start();
    if (!_listenerAttached) {
      _listenerAttached = true;
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
    }
  }

  void _onTimings(List<FrameTiming> timings) {
    // 桶开着（转场中）或正在等尾帧（closing）才入账；其余时机的帧与本次归因无关。
    if (!_open && !_closing) return;
    for (final timing in timings) {
      final buildUs = timing.buildDuration.inMicroseconds;
      final rasterUs = timing.rasterDuration.inMicroseconds;
      _timed++;
      _buildSumUs += buildUs;
      _rasterSumUs += rasterUs;
      if (buildUs > _buildMaxUs) _buildMaxUs = buildUs;
      if (rasterUs > _rasterMaxUs) _rasterMaxUs = rasterUs;
      if (buildUs > _frameBudgetUs || rasterUs > _frameBudgetUs) _overBudget++;
      _noteWorst(timing.totalSpan.inMicroseconds, buildUs, rasterUs);
    }
    // 收口后到达的第一批就是「转场的最后一帧」，收下它们再冲刷。
    if (_closing) _flush();
  }

  /// 记下本段最坏的几帧（按 `totalSpan` = vsync 到栅格完成的总跨度排序）。
  ///
  /// **为什么段级 avg/max 不够用**：实测真机上有若干段 `build avg` 只有 5ms 上下，
  /// 却出现 41~83ms 的单帧（`gapMax`）。均值正常而单帧爆表，说明成本是一次性的
  /// （首建/首帧上传纹理/首次编译着色器），必须把那一帧单独拆成 UI 与 GPU 两段，
  /// 才知道该往哪边动手——否则又是白做一轮。
  void _noteWorst(int spanUs, int uiUs, int gpuUs) {
    final entry = (span: spanUs, ui: uiUs, gpu: gpuUs);
    if (_worst.length < _kPerfWorstKeep) {
      _worst.add(entry);
      _worst.sort((a, b) => b.span.compareTo(a.span));
      return;
    }
    // 已满三个：比最坏里最小的那个还小就不占位。
    if (spanUs <= _worst.last.span) return;
    _worst.removeLast();
    _worst.add(entry);
    _worst.sort((a, b) => b.span.compareTo(a.span));
  }

  void _flush() {
    _open = false;
    _closing = false;
    if (_frames == 0) return;
    _lastSummary = _summary();
    _summaries.add(_lastSummary);
    // ignore: avoid_print
    print('[CoverMorphPerf] $_lastSummary');
    _frames = 0;
  }

  String _summary() {
    final spanUs = _lastFrameUs - _firstFrameUs;
    final fps = _frames > 1 && spanUs > 0
        ? (_frames - 1) * 1000000 / spanUs
        : 0.0;
    // avg 的分母用**实际入账的帧数** `_timed`，不是 UI 重建帧数 `_frames`：
    // 收口后到达的尾批会多收或少收几帧，拿 `_frames` 当分母会把 avg 摊薄，
    // 反过来还可能除零。
    final counted = _timed == 0 ? 1 : _timed;
    final gap = _percentiles(_intervalsUs);
    // 已归因的 UI 成本（按帧均摊）与**残差**：`FrameTiming.buildDuration` 覆盖整帧的
    // build + layout + 录制 paint，而四个热点只量到各自那一小段。
    // 残差大 → 钱在页面别处（歌词/控件/布局），得再挂热点或走 timeline；
    // 残差小而热点大 → 优化点就在这四处里。
    final hotUs = _hot.values.fold(0, (int sum, accum) => sum + accum.sum);
    final buildAvgUs = _buildSumUs ~/ counted;
    final hotAvgUs = hotUs ~/ counted;
    return 'frames=$_frames kind=${_dragSeen ? 'drag' : 'tap'} '
        'dir=${_progressLast >= _progressFirst ? 'expand' : 'collapse'} '
        'fps=${fps.toStringAsFixed(1)} timed=$_timed '
        'gapMed=${_ms(gap.median)} gapP95=${_ms(gap.p95)} '
        'gapMax=${_ms(gap.max)} '
        'build=avg${_ms(buildAvgUs)}/max${_ms(_buildMaxUs)}ms '
        'raster=avg${_ms(_rasterSumUs ~/ counted)}/max${_ms(_rasterMaxUs)}ms '
        'over8=$_overBudget hotAvg=${_ms(hotAvgUs)} '
        'resid=${_ms(buildAvgUs - hotAvgUs)} '
        '${_hotSummary()} pageBuilds=$_pageBuilds'
        // 实例数与首次发生的飞行帧序号：区分「同一实例被反复重建」（要治）与
        // 「覆盖层新建实例 + 路由再接管」这种设计固有的实例创建（不是 bug）。
        ' pageInst=${_pageInstances.length}'
        ' pageFirst=${_pageFirstFrame ?? 0}'
        ' $_worstSummary';
  }

  /// 各 UI 热点的 avg/max（毫秒）。avg 的分母是该热点**自己的调用次数**：
  /// 形变层每帧一次、面板每帧一次、探针每帧两次，混用同一个分母会互相稀释。
  String _hotSummary() {
    final parts = <String>[];
    for (final key in coverMorphHotKeys) {
      final accum = _hot[key]!;
      parts.add(
        '$key=avg${_ms(accum.avgUs)}/max${_ms(accum.max)}ms'
        '(n=${accum.count})',
      );
    }
    return 'hot ${parts.join(' ')}';
  }

  /// 本段最坏的几帧，格式 `worst=跨度/UI/GPU,跨度/UI/GPU,…`（单位 ms）。
  /// 读法：`GPU` 占大头 → 栅格侧（纹理上传、模糊、首次编译着色器）；
  /// `UI` 占大头 → 建页/布局侧（首建整页、歌词与 tab 内容挂载）。
  String get _worstSummary {
    if (_worst.isEmpty) return 'worst=-';
    return 'worst=${_worst.map((e) => '${_ms(e.span)}/${_ms(e.ui)}/${_ms(e.gpu)}').join(',')}';
  }

  static String _ms(int us) => (us / 1000).toStringAsFixed(1);

  /// 仅供测试：立刻冲刷（真机上由下一批 timing 触发，测试里不必等帧）。
  @visibleForTesting
  void debugFlushNow() => _flush();

  /// 仅供测试：注入合成的 `FrameTiming`（其工厂在 dart:ui 里就标注了「unit test only」）。
  @visibleForTesting
  void debugFeedTimings(List<FrameTiming> timings) => _onTimings(timings);

  /// 仅供测试：已经冲刷出来的每一行（按转场顺序）。
  @visibleForTesting
  List<String> get debugSummaries => List<String>.unmodifiable(_summaries);

  /// 仅供测试：喂一个帧间隔序列，检查分位算法（单位与输入一致）。
  @visibleForTesting
  static ({int median, int p95, int max}) debugPercentilesOf(
    List<int> samples,
  ) => _percentiles(samples);

  /// 仅供测试：清掉桶与历史行，让每个用例互不串味。
  @visibleForTesting
  void debugResetTrace() {
    // 用例之间绑定实例可能换掉，连挂载标记一起复位，下一次重新挂。
    _listenerAttached = false;
    _open = false;
    _closing = false;
    _frames = 0;
    _timed = 0;
    _firstFrameUs = 0;
    _lastFrameUs = 0;
    _buildSumUs = 0;
    _buildMaxUs = 0;
    _rasterSumUs = 0;
    _rasterMaxUs = 0;
    _overBudget = 0;
    _pageBuilds = 0;
    _pageInstances.clear();
    _pageFirstFrame = null;
    _dragSeen = false;
    _progressFirst = 0;
    _progressLast = 0;
    _lastSummary = '';
    _summaries.clear();
    _intervalsUs.clear();
    _worst.clear();
    for (final accum in _hot.values) {
      accum.reset();
    }
  }
}

/// 要归因的 UI 热点，顺序即日志里的输出顺序。
///
/// **构造类**（build 阶段，量的是 widget 对象的重配次数与耗时）：
/// - `layer`：形变层本帧的产出（**含文字侧** `TextStyle.lerp` 引发的整套 widget 重配）；
/// - `cover`：飞行封面本帧的矩阵 / 局部圆角 / 阴影构造（封面本体已被 memo 挡住）；
/// - `panel`：`PlayerPanelFrame` 的几何 + 裁剪窗口重建（每帧都在改 `Padding`/`SizedBox`）；
/// - `probe`：封面几何探针的 `getTransformTo` + `transformRect`（转场中每帧两次）。
///
/// **阶段类**（仪表 v3，量的是 layout / paint **阶段**里那棵子树的真实耗时，见
/// [CoverMorphPhaseProbe]）：
/// - `pageLayout` / `pagePaint`：面板里**整页播放页**那一棵；
/// - `textLayout` / `textPaint`：形变层的**文字块**那一棵（两套 `TextStyle.lerp`
///   逐帧变字号 → 每帧重排文字，这部分从不经过上面任何一个构造热点）；
/// - `coverLayout` / `coverPaint`：形变层的**飞行封面**那一棵（Transform + 局部圆角
///   + 两层 BoxShadow 的录制）。
///
/// **这三棵必须互不相交**：`hotAvg` 是把所有热点相加再算 `resid = build - hotAvg`，
/// 一旦嵌套（外层把内层一起算进去）就会重复计数、把 `resid` 压成负数。
/// 目前唯一已知的包含关系是 `probe ⊂ pagePaint`（探针挂在页面内的槽位上），
/// 而 `probe` 实测恒为 0.0ms，可忽略；将来若给页面内部再挂阶段热点，别再套一层。
const List<String> coverMorphHotKeys = <String>[
  'layer',
  'cover',
  'panel',
  'probe',
  'pageLayout',
  'pagePaint',
  'textLayout',
  'textPaint',
  'coverLayout',
  'coverPaint',
];

/// 给一棵子树的 **layout / paint 阶段**计时的探针（仪表 v3）。
///
/// **为什么需要它**：四个构造热点跑完，真机上仍然是 `hotAvg≈0`、`resid ≈ build` 全额
/// —— 也就是说 UI 线程的钱**根本不花在 widget 构造上**，而 `FrameTiming.buildDuration`
/// 覆盖的是「build + layout + 录制 paint」整段。要归因只能往阶段里量：`RenderProxyBox`
/// 原样透传约束、不改几何，`performLayout` / `paint` 各包一层计时，就把那棵子树在
/// 对应阶段里的真实耗时量出来（含它全部后代）。
///
/// **放的位置就是结论**：三棵（整页 / 形变文字 / 飞行封面）两两不相交，见
/// [coverMorphHotKeys] 的口径说明。
///
/// **release 必须零残留**：判据关闭时本组件直接返回 `child`，渲染树里**不会**多出
/// 那个 `RenderProxyBox`。所以它是一个 StatelessWidget 而不是渲染对象组件——
/// 挂在飞行子树上的额外节点是真实的 layout/paint 转发成本，不能因为「release 不计时」
/// 就留在树里。真正的渲染节点在 [_CoverMorphPhaseProbeBox]。
class CoverMorphPhaseProbe extends StatelessWidget {
  const CoverMorphPhaseProbe({
    super.key,
    required this.layoutKey,
    required this.paintKey,
    required this.child,
  });

  /// 该子树 layout 阶段计入的热点名。
  final String layoutKey;

  /// 该子树 paint（录制 display list）阶段计入的热点名。
  final String paintKey;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!coverMorphPerfLogEnabled) return child;
    return _CoverMorphPhaseProbeBox(
      layoutKey: layoutKey,
      paintKey: paintKey,
      child: child,
    );
  }
}

class _CoverMorphPhaseProbeBox extends SingleChildRenderObjectWidget {
  const _CoverMorphPhaseProbeBox({
    required this.layoutKey,
    required this.paintKey,
    required Widget super.child,
  });

  final String layoutKey;
  final String paintKey;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderCoverMorphPhaseProbe(layoutKey, paintKey);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderObject renderObject,
  ) {
    // 形参写 RenderObject 再转型（与 CoverGeometryProbe 同一写法）：直接写私有
    // 类型会撞 library_private_types_in_public_api。
    (renderObject as _RenderCoverMorphPhaseProbe)
      ..layoutKey = layoutKey
      ..paintKey = paintKey;
  }
}

class _RenderCoverMorphPhaseProbe extends RenderProxyBox {
  _RenderCoverMorphPhaseProbe(this._layoutKey, this._paintKey);

  String _layoutKey;
  String _paintKey;

  set layoutKey(String value) => _layoutKey = value;

  set paintKey(String value) => _paintKey = value;

  @override
  void performLayout() =>
      coverMorphHot<void>(_layoutKey, super.performLayout);

  @override
  void paint(PaintingContext context, Offset offset) =>
      coverMorphHot<void>(
        _paintKey,
        () => super.paint(context, offset),
      );
}

/// 最坏帧在日志里保留几个：够定位又是哪条线程，且不至于把一行拉太长。
const int _kPerfWorstKeep = 3;

/// 给某个 UI 热点计时。
///
/// 用法：`coverMorphHot('layer', () => ...本帧的真实工作...)`。
/// release 下 [_kPerfTraceEnabled] 恒为 false，整个包装折叠成直接执行 `body()`；
/// debug / profile 每帧多一次 `Stopwatch` 与一次闭包分配——这是仪表自身的成本，
/// 读**绝对值**时记得它不是零，但比较各热点之间的高低不受影响。
T coverMorphHot<T>(String key, T Function() body) {
  if (!_kPerfTraceEnabled) return body();
  final watch = Stopwatch()..start();
  try {
    return body();
  } finally {
    CoverMorphFrameTrace.instance.noteHot(key, watch.elapsedMicroseconds);
  }
}

/// 记一次整页 build（`FullPlayer` / `AmStyleFullPlayer`）。
///
/// **期望是 0**：路由的 `buildTransitions` 把页面作为 `child` 传下去、面板只做裁剪，
/// 转场期间整页不该重建。一旦大于 0，UI 侧的大头就在「整页逐帧重建」上，
/// 其余 UI 优化都得先给这件事让路。
/// 记录一次整页 build（由两个播放页 `build` 的首行调用）。
///
/// 判据关闭时**必须在这里就返回**，而不是让 [CoverMorphFrameTrace.notePageBuild] 自己早退：
/// 后者是实例方法，写成 `CoverMorphFrameTrace.instance.notePageBuild(...)` 会先把单例取出来，
/// release 就为了一个空操作把仪表对象建了起来。
void coverMorphCountPageBuild(Object host) {
  if (!coverMorphPerfLogEnabled) return;
  CoverMorphFrameTrace.instance.notePageBuild(host);
}

/// 单个热点的累计器。
class _CoverMorphUsAccum {
  int sum = 0;
  int max = 0;
  int count = 0;

  int get avgUs => count == 0 ? 0 : sum ~/ count;

  void add(int us) {
    sum += us;
    count++;
    if (us > max) max = us;
  }

  void reset() {
    sum = 0;
    max = 0;
    count = 0;
  }
}

/// 帧间隔的 median / p95 / max。
///
/// **median 才是判定刷新率的依据**：mean 会被个别长帧拉偏。
/// 中位 ≈8.3ms → 面板在 120Hz；≈11.1ms → 90Hz；≈16.7ms → 60Hz。
/// 这直接决定 `over8`（8ms = 120Hz 一帧预算）能不能被当成「掉帧」来读。
({int median, int p95, int max}) _percentiles(List<int> samples) {
  if (samples.isEmpty) return (median: 0, p95: 0, max: 0);
  final sorted = List<int>.of(samples)..sort();
  int at(double q) => sorted[((sorted.length - 1) * q).round()];
  return (median: at(0.5), p95: at(0.95), max: sorted.last);
}
