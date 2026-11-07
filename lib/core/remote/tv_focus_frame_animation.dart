import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter/animation.dart' show Curve, Curves;

/// tv: 焦点框连贯移动 + 形变的**运动模型**（纯 Dart，无 Flutter widget 依赖）。
///
/// ## 为什么单独一个文件
///
/// `kTvBuild` 在普通构建里是 `const false`，`if (kTvBuild)` 内的接线会被 AOT 树摇剔除，
/// `flutter test` 根本执行不到那段代码（仓内先例：`test/core/remote/tv_scroll_region_test.dart`
/// 就是在断言这件事；同一口径见 `tv_seek_stepper.dart` 的文件头注释）。把「时长怎么算、
/// 何时插值何时贴合、半径怎么变」这些**与 widget 无关的判断**放在普通构建同样编译的类里，
/// 才能被单测钉住；控件侧（`tv_focus_highlight.dart`）只留接线，不写第二套判断。
///
/// 本文件**刻意不 import material_ui / m3e_core**：纯 Dart 让单测零依赖、秒开；
/// 缓动曲线在本地常量化（不从 `core/theme/motion_constants.dart` 引——那会把整套主题
/// 依赖拖进来，而这里的判断必须在普通构建下可测）。
///
/// ## 模型要点
///
/// 一次 [TvFocusFrameMotion.update] 描述本帧的**目标姿态**（矩形 + 圆角），并说明
/// 这次目标变化来自哪种成因。判据由调用方提供：`focusSwitched` = **这一帧之前
/// [FocusManager] 通知过焦点变化**（焦点真的换了停点）。之所以不在这里比对节点
/// identity：节点对象在 rebuild / 重挂载时会换 identity（`ValueKey`/`GlobalKey`
/// 重建、列表项复用时都是常态），那种抖动会被误判成"焦点在跳"，让红框在滚动中
/// 反复起跑（越拖越远）。[FocusManager] 的通知只在焦点**真的**在节点间转移时
/// 发出——滚动 / 路由转场 / 布局变化都不触发。
///
/// - 焦点切换 → **滑行插值**（连贯移动），时长 120~420ms 随距离增长；
///   滑行途中目标又被滚动带着走 → 吸收为新终点、保留时间轴（[_absorb]）；
/// - 焦点没换、目标却动了 → 元素自己在动（滚动、路由转场、布局重排）→
///   **立即贴合**。这里刻意不用"单帧位移阈值"判：快速 fling 每帧位移不过几十 px，
///   阈值法会在起步的 1~2 帧放过它、起跑一段 120~420ms 的滑行，红框随后以
///   `滚动速度 × 时长` 远远落在卡片后面（拖影可达数百 px）。"焦点没变"本身就是
///   "内容在动"的充分条件。
///
/// 滑行中再次切换焦点时**保持原起跑点与时间轴**，只把终点挪到新目标：连续按方向键
/// （连发 110ms/步、滑行最短 120ms）时红框沿同一条缓动连续前进，不会每一步都
/// 重新从零加速——这正是"连贯"观感的来源。
class TvFocusFrameMotion {
  /// 最短滑行时长。120ms = 7 帧（60fps），略高于"闪一下"的知觉阈值，
  /// 短距离移动也看得出"它在动"而不是瞬移。
  static const Duration kMinGlide = Duration(milliseconds: 120);

  /// 最长滑行时长。封顶避免跨屏横移（顶栏 ↔ 底部常驻条 ≈ 900px）像慢镜头。
  static const Duration kMaxGlide = Duration(milliseconds: 420);

  /// 滑行时长里的固定起步项（ms）。取与 [kMinGlide] 同值：这样 0px 距离
  /// 也落在最短档上，任何一次切换都有一段"看得见在动"的时间；再靠距离项拉开档位。
  static const double kBaseGlideMs = 120;

  /// 距离项系数（ms/px）。300px → 210ms，900px → 450ms（被 [kMaxGlide] 夹到 420）。
  static const double kMsPerPixel = 0.40;

  /// 形变半径下限：与原 `_FocusFramePainter` 的 `Radius.circular(6)` 一致
  /// （小图标钮 / 复选框 / 密排行），这类框改动前后观感相同。
  static const double kMinRadius = 6;

  /// 形变半径上限（px）。封顶防止大封面 / 大卡片的框被圆角吃成胶囊。
  static const double kMaxRadius = 24;

  /// 半径 = `min(w, h) * kRadiusRatio`：40px 方框 → 8.8、56px → 12.3、110px → 24（封顶）。
  static const double kRadiusRatio = 0.22;

  /// 滑行缓动。起步即有明显速度（一阶导大，有跟手感），末端速度趋零（柔停、
  /// 不"啪"地撞到目标）。`Curves.easeOutCubic` 正是这个形态，无需自建曲线。
  static const Curve kGlideEasing = Curves.easeOutCubic;

  /// 起终点距离小于该值（px）视为已到位：此时插值是恒等的，早退免得空转 140ms。
  static const double _snapDistance = 0.5;

  /// 系统「减弱动态效果」：置 true 后滑行时长恒 0，逐帧贴合。
  /// 口径同 `PlayerCoverMorphLayer` 与 `app.dart` 的 `didChangeDependencies`——
  /// 都读 `MediaQuery.disableAnimationsOf`。
  var reducedMotion = false;

  /// 当前姿态；`null` = 本帧不该画框（焦点落在 scope 上 / 无尺寸节点）。
  TvFocusFramePose? get pose => _pose;
  TvFocusFramePose? _pose;

  /// 滑行起点；`null` = 当前不在插值中（已到位）。
  TvFocusFramePose? _from;

  /// 本帧目标。插值进行中即滑行终点，否则等于 [pose]。
  TvFocusFramePose? _to;

  /// 本段滑行总时长；0 = 不插值（已到位 / 贴合）。
  Duration _duration = Duration.zero;

  /// 已走过的时间；[_duration] 为 0 时无意义。
  Duration _elapsed = Duration.zero;

  /// 是否已收敛（pose == 目标）。稳态持续调用 [tick] 时不该产出任何变化。
  bool get isSettled => _duration <= Duration.zero || _elapsed >= _duration;

  /// 无焦点可画：姿态复位。调用方的下一帧将不绘制任何框。
  void reset() {
    _pose = null;
    _from = null;
    _to = null;
    _duration = Duration.zero;
    _elapsed = Duration.zero;
  }

  /// 本帧更新。
  ///
  /// - [target]：本帧目标矩形（调用方已完成外扩）；`null` / 非有限 = 焦点不可绘制。
  /// - [focusSwitched]：本帧之前焦点**真的换了停点**（[FocusManager] 通知过）。
  ///
  /// 判据只有两条，刻意不用"单帧位移阈值"那种写法：
  ///
  /// 1. **焦点换了停点** → 从当前姿态起跑一段滑行（连贯移动；
  ///    reducedMotion 时时长为 0，退化成逐帧贴合）。
  /// 2. **焦点没换、目标却动了** → 元素自己在动（滚动、路由转场平移、布局重排），
  ///    一律贴合。这里不用 `>24px` 之类阈值：快速 fling 每帧位移不过几十 px，
  ///    阈值法会在 fling 起步的 1~2 帧放过它、起跑一段 120~420ms 的滑行，
  ///    于是红框以 `滚动速度 × 时长` 远远落在卡片后面（实测拖影可达数百 px）。
  ///    "焦点没变"本身就是"内容在动"的充分条件。
  ///
  /// 例外：**滑行途中**目标仍被滚动带着走时，只更新终点、保留时间轴（[ _absorb ]）——
  /// 此时滚动是把焦点项送进视野的过程，与滑行同向，跟着走比切断更连贯。
  ///
  /// 幂等：已收敛且目标未变时再次调用不产生任何变化（不分配、不改姿态）。
  void update({required Rect? target, required bool focusSwitched}) {
    if (target == null || !target.isFinite) {
      reset();
      return;
    }
    final TvFocusFramePose next = TvFocusFramePose(
      rect: target,
      radius: tvFocusFrameRadiusFor(target),
    );

    // 静止态同值刷新：只更新目标、不重新起跑。element rebuild 带来的尺寸小数点抖动
    // 会让红框反复"抽搐"，这里必须拦住；同时保证稳态零分配。
    if (isSettled && _to == next) return;

    if (!isSettled) {
      _absorb(next);
      return;
    }

    // —— 以下均为已收敛态 ——
    // 首帧（还没有任何目标）直接落位，不补一段空滑行：红框此前不可见，
    // 从屏幕外某个旧位置飞过来只会是一团莫名其妙的红影。
    if (_to == null) {
      _snapTo(next);
      return;
    }
    // 焦点换了停点 → 起跑滑行。目标几乎没动（亚像素级布局抖动）时直接落位，
    // 否则会为 0.x px 的位移空转 140ms。
    if (focusSwitched) {
      final double distance = (_pose!.rect.center - next.rect.center).distance;
      if (distance <= _snapDistance) {
        _snapTo(next);
        return;
      }
      _beginGlide(_pose!, next);
      return;
    }
    // 焦点没换、目标却动了 → 元素自己在动 → 贴合（见方法注释第 2 条）。
    _snapTo(next);
  }

  /// 推进 [dt]（通常来自 ticker 的帧间隔）。已收敛后空转：不分配、不改姿态。
  void tick(Duration dt) {
    if (isSettled || dt <= Duration.zero) return;
    final TvFocusFramePose from = _from!;
    final TvFocusFramePose to = _to!;
    _elapsed += dt;
    if (_elapsed >= _duration) {
      // 精确落位：不用插值结果（easeOutCubic 末端极慢，浮点误差下右 / 下边界可能
      // 残留零点几 px，静止时表现为"框比控件小一丝"）。
      _snapTo(to);
      return;
    }
    final double t = kGlideEasing.transform(
      _elapsed.inMicroseconds / _duration.inMicroseconds,
    );
    _pose = TvFocusFramePose(
      rect: Rect.lerp(from.rect, to.rect, t)!,
      radius: math.max(0.0, from.radius + (to.radius - from.radius) * t),
    );
  }

  /// 滑行途中目标被挪动（滚动把焦点项带过来 / 焦点又移了一格）。
  ///
  /// **保持原起跑点与时间轴**，只把终点换成新目标：连续按方向键
  /// （`TvKeyRepeatLayer` 连发 110ms/步，滑行最短 120ms）时红框始终沿同一条缓动
  /// 前进，不会每一步都从零重新加速——这正是"连贯"的观感来源。若把时间轴也重置，
  /// 连发期间每步都在"起步→被迫打断"，表现为一抖一抖的点射。
  ///
  /// 例外：新目标已被当前姿态追到（距离 ≤ [_snapDistance]）→ 就地收敛，不为
  /// 零点几 px 的残差跑完剩余时长。
  void _absorb(TvFocusFramePose next) {
    if ((_pose!.rect.center - next.rect.center).distance <= _snapDistance) {
      _snapTo(next);
      return;
    }
    _to = next;
  }

  /// 起一段从 [from] 到 [to] 的滑行。时长为 0（reducedMotion / 距离为 0）时直接贴合。
  void _beginGlide(TvFocusFramePose from, TvFocusFramePose to) {
    final Duration duration = tvFocusFrameGlideFor(
      (from.rect.center - to.rect.center).distance,
      reducedMotion: reducedMotion,
    );
    if (duration <= Duration.zero) {
      _snapTo(to);
      return;
    }
    _from = from;
    _to = to;
    _duration = duration;
    _elapsed = Duration.zero;
    _pose = from;
  }

  /// 立即落到 [next]（[pose] 与目标都写入，供下一帧判定"元素自己在动"）。
  void _snapTo(TvFocusFramePose next) {
    _pose = next;
    _from = null;
    _to = next;
    _duration = Duration.zero;
    _elapsed = Duration.zero;
  }
}

/// 焦点框的当前**姿态**：矩形 + 圆角半径。按值比较，供 `CustomPainter.shouldRepaint`
/// 与「本帧是否真的动了」直接用 `==` 判定。
class TvFocusFramePose {
  const TvFocusFramePose({required this.rect, required this.radius});

  /// 绘制矩形（已外扩）。
  final Rect rect;

  /// 绘制圆角半径（px）。
  final double radius;

  @override
  bool operator ==(Object other) =>
      other is TvFocusFramePose &&
      other.rect == rect &&
      other.radius == radius;

  @override
  int get hashCode => Object.hash(rect, radius);

  @override
  String toString() =>
      'TvFocusFramePose(${rect.left.toStringAsFixed(1)},'
      '${rect.top.toStringAsFixed(1)} '
      '${rect.width.toStringAsFixed(1)}×${rect.height.toStringAsFixed(1)} '
      'r=${radius.toStringAsFixed(1)})';
}

/// 目标矩形对应的绘制圆角半径。
///
/// 与短边成正比（圆形图标钮保持正圆、长条形行接近胶囊），并夹在
/// [TvFocusFrameMotion.kMinRadius] ~ [TvFocusFrameMotion.kMaxRadius]。
/// 空 / 非有限矩形返回下限。
double tvFocusFrameRadiusFor(Rect rect) {
  if (rect.isEmpty || !rect.isFinite) return TvFocusFrameMotion.kMinRadius;
  final double target =
      math.min(rect.width, rect.height) * TvFocusFrameMotion.kRadiusRatio;
  return target.clamp(
    TvFocusFrameMotion.kMinRadius,
    TvFocusFrameMotion.kMaxRadius,
  );
}

/// 两点中心距对应的滑行时长（夹在 [TvFocusFrameMotion.kMinGlide] ~ [kMaxGlide]）。
///
/// `reducedMotion = true`（系统「减弱动态效果」）恒为 0：直接落位不播过渡。
Duration tvFocusFrameGlideFor(
  double distance, {
  bool reducedMotion = false,
  double msPerPixel = TvFocusFrameMotion.kMsPerPixel,
}) {
  if (reducedMotion) return Duration.zero;
  final double ms =
      TvFocusFrameMotion.kBaseGlideMs + math.max(0.0, distance) * msPerPixel;
  final int clamped = ms.round().clamp(
    TvFocusFrameMotion.kMinGlide.inMilliseconds,
    TvFocusFrameMotion.kMaxGlide.inMilliseconds,
  );
  return Duration(milliseconds: clamped);
}

/// 单帧步进上限（ticker 恢复时的 dt 保护）。掉帧 / 后台回前台时一帧可能跨数百 ms，
/// 直接累加会让滑行一步跳完。调用方须先夹取再喂给 [TvFocusFrameMotion.tick]。
const Duration kTvFocusFrameMaxTick = Duration(milliseconds: 100);
