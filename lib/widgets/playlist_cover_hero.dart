import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../core/layout/adaptive_navigator.dart';
import '../core/layout/responsive_layout.dart';
import '../core/layout/ui_density.dart';
import 'playlist_cover_flight_bus.dart';

// 登记簿拆独立文件以避免 `adaptive_navigator → 本文件 → adaptive_navigator`
// 的循环导入（openDetail 需要 armPanePush）；对外仍从本文件统一导出。
export 'playlist_cover_flight_bus.dart';

/// 歌单封面连贯过渡：列表卡片封面 → 歌单详情页头部封面。
///
/// **双路径**（两端组件一致，按「两端是否同栈」自动分派）：
///
/// 1. **框架 Hero 路径**（两端同 Navigator）：包 [Hero]，由框架完成 Overlay 飞行、
///    端点测量、pop 反向、中断接管；[flightShuttle] 让飞行中的**圆角与矩形位置取
///    同一个进度**（默认 shuttle 只显示终点 child，起点圆角会瞬间突变；而圆角自己
///    另套曲线或另算方向，又会在飞行途中与尺寸/位移脱节——见 `_flightShuttle`）。
///    覆盖搜索页专辑大封面过渡，以及
///    手机单栏下 B 类 tab（收藏/本地音乐…）列表 → 详情——`AdaptiveNav.openDetail`
///    在单栏几何把详情推到 Tab 中央栈，两端同栈且栈上有 HeroController。
/// 2. **pane 自绘路径**（两端跨栈）：真双栏几何下列表端封面在 master 列、详情在
///    面板的**嵌套 Navigator** 里——框架 Hero 只配对同一 Navigator 内的两端，
///    跨栈做不到；且嵌套 Navigator 被 HeroControllerScope 规则屏蔽拿不到控制器
///    （navigator.dart `_updateHeroController`）。此路径由
///    [PlaylistCoverFlightBus] + [PlaylistCoverFlightLayer] 自绘：
///    来源端探针在 paint 阶段持续上报矩形，目标端在路由进场/退场时取
///    「最近绘制过、且不在自己路由上」的来源矩形起飞，进度直接骑在
///    `_PaneDetailRoute` 的路由动画上——页面滑入/滑出的同时封面飞行。
///    面板内部跳转（详情页内「相似歌单」再开详情）两端虽同在面板栈内，但与
///    master→pane 共用同一套登记簿/武装机制，也走本路径。
///
/// **系统「减弱动态效果」降级**：`MediaQuery.disableAnimationsOf` 为 true 时
/// 两条路径都不飞，转场退化为页面自身过渡（与播放页封面形变的
/// `PlayerCoverMorphBus.reducedMotion` 同一口径）。
///
/// 为什么不复用播放页那套 `PlayerCoverMorphBus`：那套的存在理由是把封面飞行
/// 绑到 `playerExpansion` 这条跟手曲线上（拖拽/点击/顶栏下拉共用一个进度），
/// 并跨 MD/AM 两个播放页共享占位参数。歌单跳转是普通路由过渡，没有共享进度
/// 可复用；根路径的 Hero 端点测量/飞行/反向/接管都是现成的。
///
/// 用法（两端 tag 必须一致，id 口径见 [playlistCoverHeroTag]）：
/// ```dart
/// PlaylistCoverHero(
///   tag: playlistCoverHeroTag(brief.globalCollectionId ?? brief.id),
///   radius: AppRadius.smAll,
///   child: _coverImage(), // 未裁剪的封面内容，圆角由本组件统一施加
/// )
/// ```
class PlaylistCoverHero extends StatefulWidget {
  const PlaylistCoverHero({
    super.key,
    required this.tag,
    required this.radius,
    required this.child,
    this.destReady,
  });

  /// 两端一致；由 [playlistCoverHeroTag] 构造。
  final String tag;

  /// 静止状态下的封面圆角（与所在卡片/详情页现有 ClipRRect 取值一致）。
  final BorderRadius radius;

  /// **未裁剪**的封面内容（图片或占位）。圆角由本组件施加，飞行层也读它
  /// 绘制——不要把 ClipRRect 放进 child。
  final Widget child;

  /// 目标端「真实封面已经画出图片」的信号（可选）。给了之后，**进场飞行落位会保持
  /// 到它变 true** 再撤走：飞行中画的是来源卡片那份已缓存的小图，落位瞬间若直接交给
  /// 真实封面，而真实封面按页头规格另解码、此刻仍是兜底占位，就会闪一下灰底
  /// （真机反馈「第一次打开歌单详情封面会闪一下」）。
  ///
  /// 为什么由调用方给信号，而不是本组件按缓存键预热：`precacheImage` 在图片**出错时
  /// 也把 future 正常完成**，而且键必须与 `CachedNetworkImage` 实际解析的那份逐字一致
  /// （`memCacheWidth` 会在内部再包一层 `ResizeImage`）。真机日志里每个歌单都是
  /// `dest image ok +0ms`，说明这种猜测式就绪信号等不到东西。调用方用
  /// `CachedNetworkImage.imageBuilder`（只在图片加载完成后才被调用）置 true 才可靠。
  final ValueListenable<bool>? destReady;

  @override
  State<PlaylistCoverHero> createState() => _PlaylistCoverHeroState();
}

class _PlaylistCoverHeroState extends State<PlaylistCoverHero>
    with TickerProviderStateMixin {
  final PlaylistCoverFlightBus _bus = PlaylistCoverFlightBus.instance;

  /// 是否走 pane 自绘飞行（详见类文档）：**真双栏几何**（master 列 → 面板栈，
  /// 两端跨栈）或本体就在面板栈内（面板内部跳转）。单栏响应式壳层下列表 → 详情
  /// 由 openDetail 推到 Tab 中央栈，两端同栈，走框架 Hero。
  bool _flightOnPane = false;
  bool _reducedMotion = false;

  /// 转场结束后补飞用的本地控制器（仅 push 错过转场时创建，落位即销毁）。
  AnimationController? _selfDrive;

  /// pane 路径：来源登记条目（本实例 dispose 前一直有效，供其他页面反查）。
  CoverFlightSource? _sourceEntry;

  /// 本实例自己的探针 RenderBox（paint 时带上）。**按需实测**用它，不能只信
  /// paint 快照：祖先只做平移/缩放时子级不会重跑 paint，paint 快照会冻在
  /// 最后一次真绘制的位置（真机实测冻在被壳层推出屏幕后的 `L-377`）。
  RenderBox? _probeBox;

  /// 当前实测矩形（探针未挂载时返回 null，调用点自处理）。
  ///
  /// **必须同时刷新 [_latestLocalSize]**：`_settledDestRect` 用「实测宽 ÷ 本地布局宽」
  /// 反解预测性返回缩放，这两个值必须来自同一帧。页头首帧的 `coverSize` 会小于
  /// 140（随 flexibleSpace 可用高度收敛），拿旧的布局宽配新的实测宽就得到 s≠1，
  /// 终点会被往页面中心方向推并缩小——真机表现为「落点偏右」。
  Rect? _liveRect() {
    coverFlightDebugCountMeasure();
    final box = _probeBox;
    if (box == null || !box.attached || !box.hasSize) return null;
    _latestLocalSize = box.size;
    return MatrixUtils.transformRect(
      box.getTransformTo(_anchor),
      Offset.zero & box.size,
    );
  }

  /// 探针子树本地的布局尺寸（封面的 dp 尺寸），与探针实测矩形同帧采集：
  /// 二者相除得到页面当前的缩放比。
  Size? _latestLocalSize;

  /// 设计像素锚点（[DisplayScaleReference]），把 pane Navigator 的矩形换算到与
  /// 探针同一坐标空间。
  RenderObject? _anchor;

  /// 进场转场已开始、等首帧探针矩形后起飞。期间真实封面必须隐藏
  /// （页面自身还在淡入，不隐藏会在落点先露出一份再飞一份）。
  bool _pendingFlightBegin = false;

  /// 本实例发起、进行中的飞行（非空 = 隐藏真实封面，交给飞行层画）。
  ActiveCoverFlight? _myFlight;

  /// 飞行封面是否已经真的画出过一帧。退场起飞时先置 false，等飞行层重建出画面再藏原件
  /// （见 `_beginFlight` 里的说明）；进场由 `_pendingFlightBegin` 全程遮挡，默认 true。
  bool _flightPainted = true;

  ModalRoute<dynamic>? _listenedRoute;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    // dependOn 而非 maybeOf：twoPane 随旋转/折叠几何变化时要重估路径归属。
    final scope =
        context.dependOnInheritedWidgetOfExactType<DetailPaneScope>();
    final paneNav = scope?.detailKey.currentState;
    // 面板内点击（详情页里再开详情）：最近 Navigator 就是面板栈；真双栏下
    // master 列的点击虽然最近 Navigator 是 Tab 栈，但详情会推到面板栈（openDetail
    // 同条件分派）——两者都由自绘飞行接管。单栏下列表端封面随详情一起落 Tab
    // 中央栈，交给框架 Hero。
    _flightOnPane = scope != null &&
        (identical(Navigator.maybeOf(context), paneNav) || scope.twoPane);
    if (!_flightOnPane) _pendingFlightBegin = false;
    _anchor = DisplayScaleReference.anchorOf(context);
    // 目标端就绪信号（见 PlaylistCoverHero.destReady）：飞行落位后据此保持，
    // 避免交接时露出兜底占位。
    final destReady = widget.destReady;
    if (!identical(destReady, _destReady)) {
      _destReady?.removeListener(_onDestReadyChanged);
      _destReady = destReady;
      destReady?.addListener(_onDestReadyChanged);
    }
    final route = ModalRoute.of(context);
    // 开关关闭、或本实例不走自绘飞行（单栏框架 Hero 路径）时连来源都不登记：
    // 省下条目内存、省下武装时的遍历。
    // 已知边界：关闭期间**已挂载**的行不会被重新注册，重开后要等该行下次重建
    // 才成为来源——列表滚动/翻页本来就会重建，且此刻原件与飞行都不参与，
    // 不会出现"半开"状态；不为这点给每个 Hero 挂全局监听（那反而是常驻成本）。
    // 几何翻转（单↔双栏）无此边界：dependOn 会在 didChangeDependencies 重估并
    // 立即补登记/注销。
    if (kPlaylistCoverTransitionEnabled.value && _flightOnPane) {
      if (_sourceEntry == null) {
        _sourceEntry = _bus.registerSource(
          widget.tag,
          route ?? Object(),
          widget.radius,
          widget.child,
        );
      } else if (route != null && !identical(_sourceEntry!.route, route)) {
        _sourceEntry!.route = route;
      }
    } else if (_sourceEntry != null) {
      _bus.unregisterSource(widget.tag, _sourceEntry!);
      _sourceEntry = null;
    }
    _syncRouteAnimation(route);
  }

  void _syncRouteAnimation(ModalRoute<dynamic>? route) {
    if (identical(_listenedRoute, route)) return;
    _listenedRoute?.animation?.removeStatusListener(_onRouteStatus);
    _listenedRoute = route;
    route?.animation?.addStatusListener(_onRouteStatus);
    // 首次挂进一个「正在进场」的路由（监听挂上时动画已在跑，forward 状态
    // 事件不会再发）：标记待起飞，等首帧探针量到矩形后真正起飞。
    if (route != null && _flightOnPane && !_reducedMotion) {
      final anim = route.animation;
      if (anim != null && anim.status == AnimationStatus.forward) {
        _pendingFlightBegin = true;
      }
    }
  }

  void _onRouteStatus(AnimationStatus status) {
    if (!mounted) return;
    if (!_flightOnPane || _reducedMotion) return;
    // 排查日志：路由状态事件与当前进度（观察退场是否有反向动画）。
    // ignore: avoid_print
    print('[CoverHero] route $status '
        'v=${_listenedRoute?.animation?.value.toStringAsFixed(2)}');
    if (status == AnimationStatus.forward) {
      // 进场：探针首帧量到矩形后起飞（此刻页面可能还没 paint）。
      _pendingFlightBegin = true;
      setState(() {});
    } else if (status == AnimationStatus.reverse) {
      // 退场：页面仍在归位位置（v≈1，位移补偿自然为 0），立即原路飞回。
      _pendingFlightBegin = false;
      _beginFlight(isPop: true);
      setState(() {});
    } else if (status == AnimationStatus.completed) {
      // 只收尾**骑路由**的进场飞行；本地 300ms 自驱飞行由自己的控制器收尾，
      // 否则会在路由先落位时把补飞掐掉一半。
      final flight = _myFlight;
      if (flight != null &&
          !flight.isPop &&
          flight.routeAnimation == _listenedRoute?.animation) {
        // 落位：是否立即收尾由「落位 + 图就绪」双条件决定（held 时继续保持）。
        _onFlightLanded();
      }
      setState(() {});
    } else if (status == AnimationStatus.dismissed) {
      // 退场落位：不立即撤封面，改挂一小段尾巴（见 ActiveCoverFlight.tailHeld）。
      final flight = _myFlight;
      if (flight != null && flight.isPop) {
        _myFlight = null;
        _bus.holdTail(flight);
      }
      setState(() {});
    }
  }

  /// 探针回调（paint 阶段）：只允许写字段 + 通知登记簿，禁止 setState。
  void _onProbePaint(RenderBox box, Size logicalSize) {
    _probeBox = box;
    _latestLocalSize = logicalSize;
    final entry = _sourceEntry;
    if (entry != null) {
      _bus.publishSource(entry, widget.child, box: box, space: _anchor);
    }
    // 起飞判定：① 本状态在转场开始时就标记了 pending（页头随首帧一起构建的
    // 快路径）；② 本路由是 openDetail 刚武装的目标（页头晚于转场才构建的慢
    // 路径——加载歌曲期间页头不存在，转场结束后才首次绘制）。两者消费其一。
    // 非 pane 路径（框架 Hero 接管）两者恒不成立，不参与自绘起飞。
    final armed =
        _flightOnPane && _bus.consumeArmForRoute(_listenedRoute);
    if (!_pendingFlightBegin && !armed) return;
    if (_beginScheduled) return;
    _beginScheduled = true;
    // **起飞放到帧末回调**：探针跑在 paint 阶段，此时创建 AnimationController /
    // 起飞 / 通知飞行层重建全部撞上框架的「build/paint 期间不得 setState」断言
    // （真机上表现为航班存在但飞行层一行都没画）。帧末是合法时机。
    //
    // 标记**不在这里清**，留到下面的帧末回调：paint 里清掉的话，本帧之后真实封面会
    // 在转场中途（页面仍在横向滑入）露一帧才被航班接上——真机反馈「打开详情页时封面
    // 闪一下」。但必须在帧末无条件清掉，否则探针每次绘制都会重新排一次起飞。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _beginScheduled = false;
      if (!mounted) return;
      // 路由转场还在进行 → 骑路由动画，封面与页面同步滑入（无缝转场）；转场已
      // 结束（页头晚于转场才首次绘制的兜底场景）→ 本地 300ms 补飞一段。
      final anim = _listenedRoute?.animation;
      if (anim != null &&
          anim.status == AnimationStatus.forward &&
          anim.value < 0.95) {
        _beginFlight(isPop: false);
      } else {
        _beginSelfDrivenFlight();
      }
      // **一律在此清掉**（原来是 paint 回调里清，会露一帧真实封面）：帧末回调跑在
      // 下一帧构建之前，所以既不露帧也不会循环——留着它会让探针每次绘制都再排一次
      // 起飞，落位后 `_myFlight` 变空又能起一次，动画无限重复（真机回归）。
      // 隐藏职责由 `_myFlight != null` 接手；航班没建立就自动放行真实封面。
      _pendingFlightBegin = false;
      setState(() {});
    });
  }

  /// 转场期间**额外施加在页面上**的绘制位移（本组件坐标系），走到 Navigator 为止。
  ///
  /// 页面被滑入时被 `RenderFractionalTranslation`（material_ui FadeForwards 用它）
  /// 或纯平移的 `RenderTransform`（AnimatedSlide 等）平移；`getTransformTo` 量到的
  /// 矩形里已经含这些偏移。这里逐个把它们取出来换算到同一空间后求和——**读渲染树的
  /// 真实值**，而不是按「0.25×页宽 × 某条曲线」建模。建模一旦和实际转场有偏差
  /// （比例、曲线、嵌套层级），终点就会随进度漂移、末尾被拉回，观感是落点偏右+交接闪。
  Offset _transitionalDrift() {
    final start = _probeBox;
    final nav =
        _listenedRoute?.navigator?.context.findRenderObject() as RenderBox?;
    if (start == null || !start.attached || nav == null || !nav.attached) {
      return Offset.zero;
    }
    var total = Offset.zero;
    RenderObject? node = start;
    while (node != null && !identical(node, nav)) {
      Offset local = Offset.zero;
      if (node is RenderFractionalTranslation && node.hasSize) {
        final t = node.translation;
        local = Offset(t.dx * node.size.width, t.dy * node.size.height);
      } else if (node is RenderTransform && node.parent != null) {
        // 只认「纯平移」：线性部分必须是单位变换，否则（预测性返回的 scale）交给
        // _settledDestRect 的缩放反解处理。
        final toParent = node.getTransformTo(node.parent);
        final origin = MatrixUtils.transformPoint(toParent, Offset.zero);
        final dx = MatrixUtils.transformPoint(toParent, const Offset(1, 0)) - origin;
        final dy = MatrixUtils.transformPoint(toParent, const Offset(0, 1)) - origin;
        if (dx == const Offset(1, 0) && dy == const Offset(0, 1)) {
          local = origin;
        }
      }
      if (local != Offset.zero) {
        final toSpace = node.getTransformTo(_anchor);
        final origin = MatrixUtils.transformPoint(toSpace, Offset.zero);
        total += MatrixUtils.transformPoint(toSpace, local) - origin;
      }
      node = node.parent;
    }
    return total;
  }

  /// 目标端封面的**归位矩形**（终点）。飞行层画在页面之外、不继承页面的转场变换，
  /// 所以必须把转场期间叠加在矩形上的位移与缩放反解掉，才能瞄准页面落定后的位置。
  ///
  /// 1. 位移：[_transitionalDrift] 从渲染树取真实值，与曲线/比例无关；v=1 时为 0。
  /// 2. 缩放（仅手势 pop 的预测性返回）：s = 实测宽 ÷ 探针布局宽（同帧取，见
  ///    [_liveRect]）；页面铺满 pane Navigator，故以 Navigator 矩形中心为基准按 1/s
  ///    还原。非缩放场景 s≈1，本步自动退化为恒等。
  ///
  /// 结果在起飞前算好、整段飞行固定（不再每帧重算，避免终点随进度漂动）。
  Rect? _settledDestRect() {
    final live = _liveRect();
    final local = _latestLocalSize;
    if (live == null) return null;
    final drift = _transitionalDrift();
    var rect = live.shift(-drift);
    final navBox =
        _listenedRoute?.navigator?.context.findRenderObject() as RenderBox?;
    if (local == null ||
        local.width <= 0 ||
        navBox == null ||
        !navBox.hasSize ||
        !navBox.attached) {
      return rect;
    }
    final navRect = MatrixUtils.transformRect(
      navBox.getTransformTo(_anchor),
      Offset.zero & navBox.size,
    );
    final s = (rect.width / local.width).clamp(0.5, 1.5);
    if ((s - 1.0).abs() > 0.01) {
      rect = Rect.fromCenter(
        center: navRect.center + (rect.center - navRect.center) / s,
        width: rect.width / s,
        height: rect.height / s,
      );
    }
    return rect;
  }

  /// 目标端就绪信号（见 [PlaylistCoverHero.destReady]）与其监听句柄。
  ValueListenable<bool>? _destReady;
  Timer? _holdTimer;

  /// 进场飞行的两个收尾条件（**必须都满足**才撤飞行封面）：
  /// [flightLanded] —— 进度已到 1（页面落位）；
  /// [destImageDone] —— 目标端真实封面已画出加载完成的图片（落位后继续保持在
  /// 目标位置，避免交接瞬间露出页头的兜底占位）。
  ///
  /// 缺一不可：只等「图就绪」会在图已在缓存时把刚起飞的航班秒收，表现为
  /// 「进入动画没了」（真机反馈）；只等「落位」则首屏会闪一下兜底占位。
  /// 超时（2.5s）强制收尾，避免图片始终失败把页头永久藏住。
  bool flightLanded = false;
  bool destImageDone = false;

  /// 目标端封面图片就绪（由调用方在真实封面拿到图片时置 true）。
  void _onDestReadyChanged() {
    if (!_destReady!.value || destImageDone) return;
    destImageDone = true;
    // ignore: avoid_print
    print('[CoverHero] dest cover painted +${_since(_flightAt)}ms '
        'landed=$flightLanded tag=${widget.tag}');
    // **推迟到下一帧**再收尾：就绪只代表图片拿到了，真实封面要等下一次构建/绘制
    // 才画得出它。立即撤走飞行封面，让位的正是仍显示兜底占位的那一帧。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeFinishPushFlight();
    });
  }

  /// 进场飞行起飞：重置收尾条件、按需挂保持定时器。
  void _startPushFlightTracking({required bool held}) {
    flightLanded = false;
    destImageDone = false;
    _holdTimer?.cancel();
    _holdTimer = null;
    if (!held) return;
    // 图早已就绪（第二次进同一歌单）：直接记为完成，落位即可收尾。
    if (_destReady?.value == true) {
      destImageDone = true;
      return;
    }
    // 兜底：图片失败/超时不至于把页头永久藏住。
    _holdTimer = Timer(const Duration(milliseconds: 2500), () {
      _holdTimer = null;
      if (mounted && _myFlight != null && !_myFlight!.isPop) {
        // ignore: avoid_print
        print('[CoverHero] dest cover TIMEOUT tag=${widget.tag}');
        _revealThenDropFlight();
      }
    });
  }

  int _flightAt = 0;
  static int _since(int from) =>
      from == 0 ? -1 : DateTime.now().millisecondsSinceEpoch - from;

  /// 飞行进度到 1（落位）。
  void _onFlightLanded() {
    flightLanded = true;
    _maybeFinishPushFlight();
  }

  void _maybeFinishPushFlight() {
    final flight = _myFlight;
    if (!mounted || flight == null || flight.isPop) return;
    if (!flightLanded) return; // 还在飞：图先就绪也得飞完
    if (_revealing) return; // 已经在重叠收尾流程里
    if (!flight.held || destImageDone) {
      _holdTimer?.cancel();
      _holdTimer = null;
      _logLanding(flight);
      _revealThenDropFlight();
    }
  }

  /// 落位收尾用**重叠**而不是直接交换：先放行真实封面（飞行封面继续盖着），过一小段
  /// 再撤航班。
  ///
  /// 直接 `_endFlight() + setState` 看起来是同一帧生效，但飞行层的重建要经登记簿的
  /// 微任务派发，与本页的 setState 并不保证落在同一帧——只要有一帧两边都没画，
  /// 观感就是封面「闪一下」（真机逐轮排掉几何/曲线/图片就绪后剩下的就是这个空帧）。
  /// 尾巴期间两层重叠，画的是同一份像素，只可能多盖不可能露空。
  bool _revealing = false;
  Timer? _tailTimer;

  /// 重叠时长：够覆盖页头重新绘制/合成的那几帧即可，再长会让人觉出封面「停了一下」。
  static const Duration _handoverTail = Duration(milliseconds: 120);

  void _revealThenDropFlight() {
    if (_revealing) return;
    _revealing = true;
    setState(() {});
    _tailTimer?.cancel();
    _tailTimer = Timer(_handoverTail, () {
      _tailTimer = null;
      if (!mounted) return;
      _revealing = false;
      _endFlight();
      setState(() {});
    });
  }

  /// 设计像素空间的可见矩形（[DisplayScaleReference] 锚点自身 = 整屏设计尺寸）。
  /// 探针上报的矩形就在这一空间，故锚点矩形即“看得见”的范围——用来剔掉离屏的
  /// 同名副本来源（见 `PlaylistCoverFlightBus.freshestSource`）。
  Rect? _visibleBounds() {
    final anchor = _anchor;
    if (anchor is RenderBox && anchor.hasSize && anchor.attached) {
      return Offset.zero & anchor.size;
    }
    return null;
  }

  /// 转场结束/慢首帧时的补飞：本地 300ms 控制器驱动，落位后自行收尾。
  void _beginSelfDrivenFlight() {
    if (_myFlight != null || _selfDrive != null) return;
    if (!kPlaylistCoverTransitionEnabled.value) return;
    final bounds = _visibleBounds();
    final source = _bus.freshestSource(
      widget.tag,
      excludeRoute: _sourceEntry?.route,
      visibleBounds: bounds,
    );
    if (source == null || source.takeoffRect(bounds) == null) {
      // ignore: avoid_print
      print('[CoverHero] bail: no source for ${widget.tag}');
      return;
    }
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _selfDrive = controller;
    controller.addStatusListener((status) {
      if (status != AnimationStatus.completed) return;
      // 落位：是否立即收尾由「落位 + 图就绪」双条件决定。
      _onFlightLanded();
      // 不能在控制器自己的状态通知里同步 dispose 它，推迟到帧末；且只销毁
      // **自己这个**控制器（直接销毁 _selfDrive 会误杀后建的控制器）。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.dispose();
        if (identical(_selfDrive, controller)) _selfDrive = null;
      });
    });
    controller.forward();
    _myFlight = _bus.beginFlight(
      source: source,
      destRadius: widget.radius,
      content: _flightContent(source),
      destRect: _settledDestRect() ?? source.takeoffRect(bounds)!,
      routeAnimation: controller,
      beginValue: 0.0,
      isPop: false,
      held: _destReady != null,
      visibleBounds: bounds,
    );
    _startPushFlightTracking(held: _destReady != null);
    _flightAt = DateTime.now().millisecondsSinceEpoch;
    // ignore: avoid_print
    print('[CoverHero] pane flight push(self-driven) tag=${widget.tag} '
        'src=${coverFlightRectDebug(source.takeoffRect(bounds))} '
        'dest=${coverFlightRectDebug(_myFlight?.destRect)} '
        'sources=${_bus.debugDescribeSources(widget.tag, excludeRoute: _sourceEntry?.route)}');
  }

  /// 飞行途中画哪一份封面：**目标端就绪就用目标端自己的那份**。交接时飞行层撤走、
  /// 真实封面接手，两边必须是同一份像素，否则落位瞬间会「闪」一下（真机反馈：
  /// 页头图片首帧即就绪，而飞行画的是列表行那份 `memCacheWidth:156` 的小图，
  /// 放大到 140dp 再换成 420 的清晰图，就是那一次闪）。
  /// 目标端尚未就绪时才用来源卡片那份已缓存的小图兜住，避免飞一份占位图。
  Widget _flightContent(CoverFlightSource source) =>
      _destReady?.value == true ? widget.child : source.content;

  bool _beginScheduled = false;

  void _beginFlight({required bool isPop}) {
    if (_myFlight != null) return;
    // 开关可能在原件已经登记之后才被关掉：起飞处再判一次，别留下半程飞行。
    if (!kPlaylistCoverTransitionEnabled.value) return;
    final anim = _listenedRoute?.animation;
    // 实时实测（不是最后一次 paint 的快照）：转场中的位移只改祖先变换，
    // 子级不重跑 paint，快照会停在页面被壳层推走前的旧位置。
    final myRect = _liveRect();
    if (anim == null) {
      // ignore: avoid_print
      print('[CoverHero] bail: no route animation');
      return;
    }
    if (myRect == null) {
      // ignore: avoid_print
      print('[CoverHero] bail: no probe rect yet');
      return;
    }
    final bounds = _visibleBounds();
    final source = _bus.freshestSource(
      widget.tag,
      excludeRoute: _sourceEntry?.route,
      visibleBounds: bounds,
    );
    if (source == null || source.takeoffRect(bounds) == null) {
      // ignore: avoid_print
      print('[CoverHero] bail: no source for ${widget.tag}');
      return;
    }
    _flightAt = DateTime.now().millisecondsSinceEpoch;
    _myFlight = _bus.beginFlight(
      source: source,
      destRadius: widget.radius,
      content: _flightContent(source),
      destRect: _settledDestRect() ?? myRect,
      routeAnimation: anim,
      beginValue: anim.value,
      isPop: isPop,
      held: !isPop && _destReady != null,
      visibleBounds: bounds,
    );
    if (!isPop) _startPushFlightTracking(held: _destReady != null);
    if (isPop) {
      // 退场的原件要等飞行层**真的画出封面之后**才藏：飞行层的重建经登记簿的微任务
      // 派发，与本页 setState 不保证同帧。同帧藏原件就会露一帧「封面还没画、原件已经
      // 没了」的空档——真机反馈的「关闭时闪一下」（与进场落位的重叠尾巴互为另一半）。
      _flightPainted = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _myFlight == null) return;
        _flightPainted = true;
        setState(() {});
      });
    }
    // ignore: avoid_print
    print('[CoverHero] pane flight ${isPop ? 'pop' : 'push'} '
        'tag=${widget.tag} v=${anim.value.toStringAsFixed(2)} '
        'src=${coverFlightRectDebug(source.takeoffRect(bounds))} '
        'dest=${coverFlightRectDebug(_myFlight?.destRect)} '
        'measured=${coverFlightRectDebug(myRect)} '
        'sources=${_bus.debugDescribeSources(widget.tag, excludeRoute: _sourceEntry?.route)}');
  }

  /// 落位收尾时再打一次终点：`header` 是那一刻页头的**实测**位置（含残余转场），
  /// `dest` 是起飞前算好的固定终点——两者对不上就是「落点偏」的直接证据。
  void _logLanding(ActiveCoverFlight flight) {
    // ignore: avoid_print
    print('[CoverHero] push flight landed tag=${widget.tag} '
        'held=${flight.held} dest=${coverFlightRectDebug(flight.destRect)} '
        'header=${coverFlightRectDebug(_liveRect())} '
        'srcRest=${coverFlightRectDebug(flight.source.restRect)}');
  }

  void _endFlight() {
    final flight = _myFlight;
    if (flight == null) return;
    _myFlight = null;
    _bus.endFlight(flight);
  }

  @override
  void dispose() {
    _listenedRoute?.animation?.removeStatusListener(_onRouteStatus);
    _destReady?.removeListener(_onDestReadyChanged);
    _holdTimer?.cancel();
    _tailTimer?.cancel();
    _endFlight();
    _selfDrive?.dispose();
    _selfDrive = null;
    final entry = _sourceEntry;
    if (entry != null) _bus.unregisterSource(widget.tag, entry);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clipped = ClipRRect(
      borderRadius: widget.radius,
      child: widget.child,
    );
    // 系统「减弱动态效果」：不飞、不隐藏，转场退化为页面自身过渡。
    if (_reducedMotion) return clipped;
    // 设置项「封面连贯过渡」关闭：与减弱动态效果同一降级——不包 Hero、不挂探针，
    // 既不登记来源也不起飞，转场只剩页面自身的动画。
    if (!kPlaylistCoverTransitionEnabled.value) return clipped;
    // 探针包在 Opacity 外层：隐藏期间（Opacity 0）探针照常 paint 上报。
    final cover = _CoverRectProbe(
      onPaint: _onProbePaint,
      child: Opacity(
        // 只在 pane 自绘路径且本实例参与飞行时隐藏；框架 Hero 路径由 Hero 自行
        // 隐藏两端。
        // `_revealing` 期间放行真实封面，让飞行封面再盖一帧（见 _revealThenDropFlight）。
        opacity: _flightOnPane &&
                (_pendingFlightBegin ||
                    (_myFlight != null && _flightPainted && !_revealing))
            ? 0.0
            : 1.0,
        child: clipped,
      ),
    );
    if (_flightOnPane) return cover;
    return Hero(
      tag: widget.tag,
      flightShuttleBuilder: _flightShuttle,
      child: cover,
    );
  }

  static Widget _flightShuttle(
    BuildContext flightContext,
    Animation<double> animation,
    HeroFlightDirection flightDirection,
    BuildContext fromHeroContext,
    BuildContext toHeroContext,
  ) {
    // 两端的圆角与未裁剪内容从 PlaylistCoverHero 上读（它是 Hero 的直接父级，
    // findAncestorWidgetOfExactType 一步命中）。按非约定用法（裸 Hero）找不到
    // 时回退 Hero 自带 child——飞行中可能轻微双重裁剪，仅影响异常用法。
    final PlaylistCoverHero? from =
        fromHeroContext.findAncestorWidgetOfExactType<PlaylistCoverHero>();
    final PlaylistCoverHero? to =
        toHeroContext.findAncestorWidgetOfExactType<PlaylistCoverHero>();
    final Widget content = flightDirection == HeroFlightDirection.push
        ? (to?.child ?? (toHeroContext.widget as Hero).child)
        : (from?.child ?? (fromHeroContext.widget as Hero).child);
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        return ClipRRect(
          borderRadius: lerpCoverRadius(
            from?.radius ?? BorderRadius.zero,
            to?.radius ?? BorderRadius.zero,
            coverFlightProgress(flightDirection, animation),
          ),
          child: content,
        );
      },
    );
  }
}

/// 飞行中的圆角插值：[BorderRadius.lerp] 逐角插值，天然支持「只有上圆角」的
/// 卡片封面区形态（搜索/场景卡片）。
BorderRadius lerpCoverRadius(BorderRadius a, BorderRadius b, double t) =>
    BorderRadius.lerp(a, b, t.clamp(0.0, 1.0))!;

/// 框架 Hero 路径（[PlaylistCoverHero._flightShuttle]）飞行进度的取法：
/// **必须取「驱动飞行矩形的那一个值」**，语义 0=来源端（fromHero）、1=目标端（toHero）。
///
/// 框架的 `_HeroFlight._buildOverlay` 用 `heroRectTween.evaluate(proxy)` 算飞行
/// 矩形，而 shuttle builder 拿到的 `animation` 是**已按 [Hero.curve]
/// （默认 fastOutSlowIn）套过**的 CurvedAnimation：
/// - push：`proxy = manifest.animation`（heroes.dart:723-724）→ 矩形进度 = v；
/// - pop：`proxy = ReverseAnimation(manifest.animation)`（heroes.dart:720，
///   `ReverseAnimation.value == 1 - parent.value`）→ 矩形进度 = 1 - v。
///
/// 圆角若在这之外**再套一次曲线**（双重缓动），中段 v≈0.5 时角半径已被推到
/// ≈0.78 甚至更高，而矩形才走到 0.5——角远早于尺寸/位移到位、末尾又被硬拉
/// 对齐，观感就是「飞行途中圆角突变」；pop 若**不随矩形反向**，起飞瞬间角半径
/// 直接跳到另一端、落位再跳回来（真机观感同样是圆角突变）。
/// pane 自绘路径没有此问题：那里矩形与圆角共用同一个 `_progress(v)`。
@visibleForTesting
double coverFlightProgress(
  HeroFlightDirection direction,
  Animation<double> animation,
) =>
    (direction == HeroFlightDirection.pop
            ? 1.0 - animation.value
            : animation.value)
        .clamp(0.0, 1.0);


/// 歌单封面 Hero 的统一 tag 前缀。
const String kPlaylistCoverHeroTagPrefix = 'md3/playlist-cover/';

/// 由歌单 id 构造两端一致的 Hero tag。
///
/// **id 口径必须与该来源类型的 `toPlaylist()` 完全一致**（对不上 = 静默不飞）：
/// - `KugouPlaylistBrief`（收藏页/搜索/探索/场景/IP/相似歌单）→
///   `playlistCoverHeroTag(brief.globalCollectionId ?? brief.id)`
///   （对应 `KugouPlaylistBrief.toPlaylist` 的 `id: globalCollectionId ?? id`）；
/// - `KugouPlaylist` / `Playlist` → `playlistCoverHeroTag(x.id)`。
///
/// **同一路由子树内每个 tag 只能出现一次**（根路径 Hero 的硬约束，重复 tag 在
/// 转场收集阶段抛 FlutterError）。pane 路径无此断言（不走 Hero 收集），但仍按
/// 同一口径保证唯一。
String playlistCoverHeroTag(String playlistId) =>
    '$kPlaylistCoverHeroTagPrefix$playlistId';

/// 专辑封面连贯过渡的 tag 前缀（与歌单命名空间**分开**）。
const String kAlbumCoverHeroTagPrefix = 'md3/album-cover/';

/// 由专辑 id 构造两端一致的 Hero tag（大封面专辑卡 → 专辑详情页头）。
///
/// **必须独立于 [playlistCoverHeroTag]**：专辑 id 与歌单 id 都是裸数字串且并不
/// 互斥（`KugouPlaylistBrief.id` 可能直接带 albumid，收藏页专辑行也已经在用
/// `playlistCoverHeroTag(gid)`）。共用命名空间会让 pane 路径的 `freshestSource`
/// 挑到不相干的行（封面从别处起飞），根路径还会撞 Hero 重复 tag 断言。
///
/// **id 口径**：两端一律取 `Album.id`（卡片与 `AlbumDetailPage(album:)` 拿到的是
/// 同一个 Album，天然对齐）。不要用详情页的 `displayAlbum.id`（详情接口
/// `toAlbum()` 可能给出不同的 id），也不要用 `globalCollectionId`
/// （`Album.copyWith` 会丢字段，且 gid 已属于歌单命名空间）。
String albumCoverHeroTag(String albumId) =>
    '$kAlbumCoverHeroTagPrefix$albumId';

/// 听书专辑封面连贯过渡的 tag 前缀（第三个命名空间）。
const String kAudiobookCoverHeroTagPrefix = 'md3/audiobook-cover/';

/// 由听书专辑 id 构造两端一致的 Hero tag（听书主页大封面卡 → 听书专辑详情页头）。
///
/// 同样必须独立命名：`KugouLongAudioAlbum.id` 解析自
/// `json['id'] ?? json['album_id'] ?? json['albumid']`，是**无前缀裸数字串**
/// （样例 `202415911`），与专辑 id / 歌单 id 同形态，共用命名空间会让 pane 路径的
/// `freshestSource` 挑到不相干的行、根路径还会撞 Hero 重复 tag 断言。
///
/// **id 口径**：两端一律取 `KugouLongAudioAlbum.id`（卡片与
/// `AudiobookAlbumDetailPage(album:)` 拿到的是同一个对象，天然对齐）。
String audiobookCoverHeroTag(String audiobookAlbumId) =>
    '$kAudiobookCoverHeroTagPrefix$audiobookAlbumId';

/// 场景封面连贯过渡的 tag 前缀（第四个命名空间）。
const String kSceneCoverHeroTagPrefix = 'md3/scene-cover/';

/// 由场景 id 构造两端一致的 Hero tag（场景页大封面卡 → 场景详情页头）。
///
/// 同样必须独立命名：`KugouSceneInfo.id` 解析自 `json['id'] ?? json['scene_id']`，
/// 是裸数字串，与专辑/歌单 id 同形态，共用命名空间会让 pane 路径的
/// `freshestSource` 挑到不相干的卡、根路径还会撞 Hero 重复 tag 断言。
///
/// **id 口径**：两端一律取 `KugouSceneInfo.id`（卡片与
/// `SceneDetailPage(scene:)` 拿到的是同一个对象，天然对齐）。
String sceneCoverHeroTag(String sceneId) => '$kSceneCoverHeroTagPrefix$sceneId';

/// 频道封面连贯过渡的 tag 前缀（第五个命名空间）。
const String kChannelCoverHeroTagPrefix = 'md3/channel-cover/';

/// 由频道 id 构造两端一致的 Hero tag（频道页大封面卡 → 频道详情页头）。
///
/// **必须独立于 [playlistCoverHeroTag]**：`KugouYouthChannel.id` 解析自
/// `global_collection_id ?? id ?? channel_id`，首个来源是**带歌单语义的 gid**，
/// 与 `md3/playlist-cover/` 的 id 空间直接重叠——共用命名空间会撞
/// `freshestSource` 与 Hero 重复 tag 断言（与专辑/听书同一理由）。
///
/// **id 口径**：两端一律取 `KugouYouthChannel.id`（卡片与
/// `ChannelDetailPage(channel:)` 拿到的是同一个对象，天然对齐）。
String channelCoverHeroTag(String channelId) =>
    '$kChannelCoverHeroTagPrefix$channelId';

/// 每个 id 的**首次出现下标**表；空 id 不入表。
///
/// 框架 Hero 的硬约束是同一路由子树内 tag 唯一（重复 tag 在转场收集阶段抛
/// FlutterError）。听书主页 4 个推荐分区挂在同一棵 ListView 子树里、同一专辑会
/// 跨分区重复出现，编辑精选也可能返回重复 gid —— 用这张表只给首次出现的那张卡
/// 挂 tag，其余卡片 `heroTag` 传 null 即不参与飞行。
Map<String, int> firstIndexById(Iterable<String> ids) {
  final result = <String, int>{};
  var index = 0;
  for (final id in ids) {
    if (id.isNotEmpty) result.putIfAbsent(id, () => index);
    index++;
  }
  return result;
}

/// pane（详情面板嵌套 Navigator）路径的封面飞行登记簿。
///
/// **来源登记**：每个 [PlaylistCoverHero] 挂载时注册条目（携带所在路由与
/// 圆角），paint 阶段持续上报矩形；dispose 注销。被遮挡/Offstage 的页面停止
/// 画在 Navigator 之上的 pane 路径封面飞行层（挂在 app.dart 顶层 Stack，
/// 紧跟 `PlayerCoverMorphLayer`，同处 `DisplayScaleScope` 设计像素空间）。
class PlaylistCoverFlightLayer extends StatelessWidget {
  const PlaylistCoverFlightLayer({super.key});

  @override
  Widget build(BuildContext context) {
    final bus = PlaylistCoverFlightBus.instance;
    return AnimatedBuilder(
      animation: bus.revision,
      builder: (context, _) {
        if (bus.flights.isEmpty) return const SizedBox.shrink();
        return Positioned.fill(
          child: IgnorePointer(
            child: Stack(
              children: [
                for (final flight in bus.flights) _FlyingCover(flight: flight),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _FlyingCover extends StatelessWidget {
  const _FlyingCover({required ActiveCoverFlight flight})
      : _flight = flight;

  final ActiveCoverFlight _flight;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _flight.routeAnimation,
      // 封面子树交给 child：每帧只重建外层定位/裁剪，元素树上的封面不再重配。
      child: RepaintBoundary(child: _flight.content),
      builder: (context, child) {
        final rect = _currentRect();
        if (rect == null) return const SizedBox.shrink();
        return Positioned.fromRect(
          rect: rect,
          child: ClipRRect(
            borderRadius: _currentRadius(),
            child: child,
          ),
        );
      },
    );
  }

  /// 当前帧的封面矩形；返回 null = 这一帧不该画（端点交接/起飞前/落位后不保持）。
  Rect? _currentRect() {
    final v = _flight.routeAnimation.value;
    final t = _progress(v);
    if (t == null) return null;
    return Rect.lerp(_flight.sourceRect, _flight.liveDestRect, t);
  }

  BorderRadius _currentRadius() {
    final v = _flight.routeAnimation.value;
    return lerpCoverRadius(
      _flight.sourceRadius,
      _flight.destRadius,
      _progress(v) ?? 0.0,
    );
  }

  /// 进度换算：语义统一为「0=来源端，1=目标端」。返回 null 表示这一帧不画。
  double? _progress(double v) {
    // 端点不画：目标端 t=1 归真实封面；来源端只在 pop 落地（t=0）时交接。
    // push 起飞通常晚于 v=0（等目标端首帧实测矩形），把剩余区间重标定到
    // [beginValue, 1]，起飞后仍走完全程。
    //
    // 曲线必须与页面转场同一条（easeInOutCubicEmphasized）：飞行进度和页面滑入都是
    // routeAnimation 的同一个 v 驱动的，换成更靠前的曲线会让封面**先于页面到位**，
    // 悬在还在滑入的页面上，交接那一刻就是一次跳变（真机反馈「打开详情页闪一下」）。
    if (_flight.isPop) {
      // 落位（v=0） normally 不画，交给来源卡片自己显示；但挂上尾巴期间
      // （`tailHeld`）继续画在来源矩形上——来源页的淡入/归位可能比路由动画慢
      // 半拍，封面早撤一帧就露出还没变实的行（真机反馈「退场也会闪/发暗」）。
      if (v >= 1.0) return null;
      if (v <= 0.0) return _flight.tailHeld ? 0.0 : null;
      return Curves.easeInOutCubicEmphasized.transform(v);
    }
    final v0 = _flight.beginValue.clamp(0.0, 0.999);
    // 起飞前不画；到达归位后仅在「保持」期间继续画（等目标大图解码完再撤，
    // 否则交接瞬间会露出页头的兜底占位）。
    if (v <= v0) return null;
    if (v >= 1.0 && !_flight.held) return null;
    return Curves.easeInOutCubicEmphasized
        .transform((v.clamp(v0, 1.0) - v0) / (1.0 - v0));
  }
}

/// 封面矩形探针（设计像素锚点空间）。
///
/// 与 PlayerCoverMorph 的 [CoverGeometryProbe] 同一模式；此处独立实现，避免
/// widgets → modules 的反向依赖。回调里**只允许写全局字段，不得 setState**
/// （paint 阶段触发重建会崩）。
///
/// 回调只交出「绘制发生了」这件事：探针自己的 `RenderBox` 与布局尺寸。
/// 矩形一律由调用方按需实测（`_liveRect` / `CoverFlightSource.measure`）——
/// 祖先只做平移/缩放时子级不会重跑 paint，把 paint 时算出的快照当端点会冻在旧位置
/// （真机实测冻在 `L-377`），而每帧都算又是不折不扣的常驻成本。
class _CoverRectProbe extends SingleChildRenderObjectWidget {
  const _CoverRectProbe({
    required this.onPaint,
    required super.child,
  });

  /// 参数：探针自身 + 子树布局尺寸（设计像素）。
  final void Function(RenderBox box, Size logicalSize) onPaint;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderCoverRectProbe(onPaint);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderCoverRectProbe renderObject,
  ) {
    renderObject.onPaint = onPaint;
  }
}

class _RenderCoverRectProbe extends RenderProxyBox {
  _RenderCoverRectProbe(this.onPaint);

  void Function(RenderBox box, Size logicalSize) onPaint;

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    if (!attached || !hasSize) return;
    onPaint(this, size);
  }
}
