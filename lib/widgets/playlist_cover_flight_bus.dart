import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// pane（详情面板嵌套 Navigator）路径的封面飞行登记簿。
///
/// **为什么存在**：MaterialApp 的 HeroController 只挂根 Navigator，且会屏蔽
/// 子树内的嵌套 Navigator——`DetailPaneScope` 内 `AdaptiveNav.openDetail` 的
/// push 没有任何观察者，框架 Hero 永远不飞。pane 路径的飞行由本登记簿 +
/// `PlaylistCoverFlightLayer`（见 playlist_cover_hero.dart）自绘。
///
/// **来源登记**：每个 PlaylistCoverHero 挂载时注册条目（携带所在路由与圆角），
/// paint 阶段持续上报矩形；dispose 注销。被遮挡/Offstage 的页面停止 paint，
/// 其条目停留在最后一次绘制位置——遮挡期间页面不位移，该位置即有效位置。
///
/// **来源挑选**：起飞时取同 tag 下「最近绘制过、且不在目标端自己路由上」的
/// 条目——排除自己路由是为了退场时飞回**列表页**的卡片，而不是飞向退场页上
/// 同 tag 的其他封面。
///
/// **pane push 武装**：详情页加载歌曲期间页头（含封面 Hero）可能晚于整个
/// 转场才首次绘制（真机实测 300ms+ vs 450ms 转场），仅靠「构建时转场还在跑」
/// 判断会让 push 永远错过。`AdaptiveNav.openDetail` 走 pane 路径时调用
/// [armPanePush] 记下目标路由；Hero 首次绘制时经 [consumeArmForRoute] 消费，
/// 决定骑路由动画或本地补飞。
class PlaylistCoverFlightBus {
  PlaylistCoverFlightBus._();

  static final PlaylistCoverFlightBus instance = PlaylistCoverFlightBus._();

  /// 来源/航班变化时通知飞行层重建（paint 阶段可安全 notify，监听者的重建
  /// 被框架推迟到下一帧，与播放页形变登记簿同一模式）。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  void _bump() {
    // **通知必须离开 build/paint 阶段**：登记簿的写入大量发生在探针的 paint
    // 回调里，此时直接 `revision.value++` 会同步触发飞行层 AnimatedBuilder 的
    // setState，被框架以「setState() or markNeedsBuild() called during build」
    // /「Build scheduled during frame」断言拒绝——图层永远不被标脏，航班存在
    // 却一行都画不出来（真机排查两轮才定位）。改为微任务里合并派发：微任务在
    // 整帧的 build/layout/paint 同步块结束后才执行，此时 setState 合法。
    if (_bumpScheduled) return;
    _bumpScheduled = true;
    scheduleMicrotask(() {
      _bumpScheduled = false;
      revision.value++;
    });
  }

  bool _bumpScheduled = false;

  int _stamp = 0;

  /// 武装时"算最近画过"的窗口：以全局 stamp 计。列表里十几个可见封面各画一帧
  /// 大约消耗十几个 stamp，240 足够覆盖「刚才那一帧」而不会覆盖早已停画的条目。
  static const int _armSnapshotStampWindow = 240;

  final Map<String, List<CoverFlightSource>> _sources = {};

  /// 进行中的航班（公开给图层遍历绘制；目标端状态机负责 begin/end 配对）。
  final List<ActiveCoverFlight> flights = [];

  Route<dynamic>? _armedRoute;
  DateTime? _armedAt;

  CoverFlightSource registerSource(
    String tag,
    Object route,
    BorderRadius radius,
    Widget content,
  ) {
    final entry = CoverFlightSource(route, radius, content);
    (_sources[tag] ??= []).add(entry);
    // 不通知飞行层：来源集合变化不改变画面（只有航班起止才需要整层重建），
    // 否则页面加载期几十次注册会换来几十次无谓的微任务 + 一次重建。
    return entry;
  }

  void unregisterSource(String tag, CoverFlightSource entry) {
    final list = _sources[tag];
    if (list == null) return;
    list.remove(entry);
    if (list.isEmpty) _sources.remove(tag);
  }

  /// 封面卡片每次绘制时"盖章"：刷新 stamp、带回最新封面子树与自己的 RenderBox。
  ///
  /// **不算矩形**：`getTransformTo` 要沿祖先链走一趟，列表里十几个可见封面 × 每帧
  /// 一次就是纯常驻成本，而且 paint 快照本来就不可靠（祖先只做平移/缩放时子级不重跑
  /// paint，矩形会冻在最后一次真绘制的位置，真机实测冻在 `L-377`）。
  /// 需要矩形时由调用方 `CoverFlightSource.measure()` 按需实测。
  void publishSource(
    CoverFlightSource entry,
    Widget content, {
    RenderBox? box,
    RenderObject? space,
  }) {
    entry
      ..content = content
      ..box = box ?? entry.box
      ..space = space ?? entry.space
      ..stamp = ++_stamp;
  }

  /// 仅供测试：伪造一次盖章（可选写入矩形），不经过真实渲染树。
  @visibleForTesting
  void debugPublish(CoverFlightSource entry, {Rect? rect}) {
    if (rect != null) entry.rect = rect;
    entry.stamp = ++_stamp;
  }

  /// 同 tag 下「最近绘制过、且不属于 [excludeRoute]」的来源；无则 null。
  ///
  /// [visibleBounds]（设计像素空间的可见矩形）非空时**优先取用户看得见的那份**：
  /// 同一个歌单可能登记在多份副本里（收藏页 TabBarView 的相邻页），纯按 stamp 挑
  /// 会选中一份滑走中的离屏副本（真机日志实测到 `src=L-377` / `L410` 这类屏外起飞点）。
  /// 全都在屏外时退回整体最近，至少保住动画不发生丢失。
  CoverFlightSource? freshestSource(
    String tag, {
    Object? excludeRoute,
    Rect? visibleBounds,
  }) {
    CoverFlightSource? best;
    CoverFlightSource? bestOnScreen;
    for (final entry in _sources[tag] ?? const <CoverFlightSource>[]) {
      if (identical(entry.route, excludeRoute)) continue;
      final takeoff = entry.takeoffRect(visibleBounds);
      if (takeoff == null) continue;
      if (best == null || entry.stamp > best.stamp) best = entry;
      if (visibleBounds != null && takeoff.overlaps(visibleBounds)) {
        if (bestOnScreen == null || entry.stamp > bestOnScreen.stamp) {
          bestOnScreen = entry;
        }
      }
    }
    return bestOnScreen ?? best;
  }

  /// 排查日志用：同 tag 全部来源的 `stamp:起飞矩形(实测/静止位)` 列表
  /// （定位选错副本、或静止位没抓到导致的屏外起飞）。
  String debugDescribeSources(String tag, {Object? excludeRoute}) {
    final list = _sources[tag];
    if (list == null || list.isEmpty) return 'none';
    return list
        .where((e) => !identical(e.route, excludeRoute))
        .map((e) =>
            '#${e.stamp} ${coverFlightRectDebug(e.takeoffRect())}'
            '(live=${coverFlightRectDebug(e.measure())}'
            ' rest=${coverFlightRectDebug(e.restRect)})')
        .join(' | ');
  }

  /// 见类文档「pane push 武装」。
  ///
  /// 武装的同时把所有来源的此刻矩形冻结进 [CoverFlightSource.restRect]：
  /// 响应式壳层在打开详情时会把列表页整体推出屏幕（真机实测最后一次 paint 停在
  /// `L-377`，正好一个页宽），列表页随后不再重绘（没人改它就没有 paint），
  /// 探针上报的位置就永久停在屏外。纯按「最近绘制」挑起点，飞行封面就从屏外起飞
  /// ——用户看到的是「页头位置先是空的、转场结束才冒出封面」。点击这一刻的矩形
  /// 才是用户真正指着的位置，所以在此处快照。
  void armPanePush(Route<dynamic> route) {
    _armedRoute = route;
    _armedAt = DateTime.now();
    // 只给「最近还真正在画」的条目做实测：其余早就停在屏外或已离屏页面上，
    // 不可能是一次点击的来源，没必要为它们各走一趟祖先链（一次导航要遍历全部
    // 登记条目，条目数可以到几百，这是转场入口上唯一剩下的 O(n) 成本）。
    // stamp<0 = 从未画过，同属「不是最近画的」：早期条目 stamp 都是个位数时，
    // 单靠窗口阈值（_stamp-240 为负）筛不掉它们，必须显式排除。
    final fresh = _stamp - _armSnapshotStampWindow;
    for (final list in _sources.values) {
      for (final entry in list) {
        final rect =
            entry.stamp < 0 || entry.stamp < fresh ? entry.rect : entry.measure();
        if (rect != null) entry.restRect = rect;
      }
    }
  }

  /// 仅当 [route] 是当前被武装的路由且未过期时消费一次（返回 true）。
  /// 消费即失效：同一路由上多个 Hero（页头 + 相似歌单行）只有最先绘制的
  /// 那个会起飞，避免多封面齐飞。
  bool consumeArmForRoute(Route<dynamic>? route) {
    if (_armedRoute == null || !identical(_armedRoute, route)) return false;
    _armedRoute = null;
    return DateTime.now().difference(_armedAt!) < const Duration(seconds: 3);
  }

  ActiveCoverFlight beginFlight({
    required CoverFlightSource source,
    required BorderRadius destRadius,
    required Widget content,
    required Rect destRect,
    required Animation<double> routeAnimation,
    required double beginValue,
    required bool isPop,
    required bool held,
    Rect? visibleBounds,
  }) {
    final flight = ActiveCoverFlight(
      source: source,
      sourceRect: source.takeoffRect(visibleBounds)!,
      sourceRadius: source.radius,
      destRadius: destRadius,
      content: content,
      destRect: destRect,
      routeAnimation: routeAnimation,
      beginValue: beginValue,
      isPop: isPop,
      held: held,
    );
    flights.add(flight);
    _bump();
    return flight;
  }

  void endFlight(ActiveCoverFlight flight) {
    if (flights.remove(flight)) _bump();
  }

  /// 把一条航班挂成「尾巴」：再盖一小段定时后自动收尾。
  ///
  /// 定时器由**登记簿**持有，发起端的 Hero 随路由销毁也照样生效（退场正是这种情况：
  /// 页面销毁时封面还得盖住来源页未完成的淡入）。幂等：已挂过就不再重复计时。
  void holdTail(ActiveCoverFlight flight, {int ms = 120}) {
    if (flight.tailHeld) return;
    flight.tailHeld = true;
    Timer(Duration(milliseconds: ms), () => endFlight(flight));
  }

  /// 仅供测试隔离使用。
  @visibleForTesting
  void debugReset() {
    _sources.clear();
    flights.clear();
    _stamp = 0;
    _armedRoute = null;
    _armedAt = null;
    _bump();
  }

  /// 仅供测试断言。
  @visibleForTesting
  Rect? debugFreshestSourceRect(String tag, {Object? excludeRoute}) =>
      freshestSource(tag, excludeRoute: excludeRoute)?.takeoffRect();

  /// 仅供测试/排查日志。
  @visibleForTesting
  int debugSourceCount(String tag) => (_sources[tag]?.length ?? 0);
}

/// 登记簿里的一条来源（某个 PlaylistCoverHero 实例）。
class CoverFlightSource {
  CoverFlightSource(this.route, this.radius, this.content);

  /// 所在路由（用于起飞时排除目标端自己路由上的同 tag 条目）。
  Object route;
  final BorderRadius radius;

  /// 来源端封面内容（未裁剪）。飞行**优先用它**：来源卡片此刻就在屏幕上，
  /// 它的图片已在 ImageCache 里（按卡片自己的 memCacheWidth 解码过），直接复用
  /// 就是同一份像素、无解码闪烁；目标端那份是按页头规格（更大 memCacheWidth）
  /// 另解码的，飞行途中大概率还是占位图。
  ///
  /// 每次盖章时刷新：动态封面行（如「我喜欢」）在登记之后才会换图，
  /// 停留在首次构建那份就会飞出错封或仍在占位的子树。
  Widget content;

  /// 最后一次已知的屏幕矩形（设计像素空间）。由 [measure] 按需实测回写；
  /// paint 回调**不再**写它。组件已卸载时 [measure] 就回退到这里。
  Rect? rect;

  /// 封面探针自己的 RenderBox 与测量空间（paint 时带上）。有了它就能**按需实测**
  /// 当前位置——祖先只做平移/缩放时子级不会重跑 `paint()`，只靠 paint 上报的
  /// [rect] 会被冻在最后一次真绘制的位置上（真机实测冻在 `L-377`）。
  RenderBox? box;
  RenderObject? space;

  /// pane push 武装那一刻冻结的**静止位**矩形（见 `armPanePush`）。
  Rect? restRect;
  int stamp = -1;

  /// 按当前渲染树实测矩形；组件已卸载/尚未布局时回退最后已知矩形。
  Rect? measure() {
    coverFlightDebugCountMeasure();
    final b = box;
    if (b == null || !b.attached || !b.hasSize) return rect;
    return rect = MatrixUtils.transformRect(
      b.getTransformTo(space),
      Offset.zero & b.size,
    );
  }

  /// 起飞/落位用的矩形。[visibleBounds] 非空且实测位在屏内时用**实测位**（那才是
  /// 封面此刻真正待着的地方，退场落位要与之重合）；实测位已在屏外（进场时列表页被
  /// 壳层推走）才回退点击那一刻的静止位快照。
  Rect? takeoffRect([Rect? visibleBounds]) {
    final live = measure();
    if (live != null && (visibleBounds == null || live.overlaps(visibleBounds))) {
      return live;
    }
    return restRect ?? live ?? rect;
  }
}

/// 一次进行中的飞行。矩形均为设计像素空间；进度骑在发起端所在路由的
/// 转场动画上（push 0→1 / pop 1→0，两个方向的语义都是 0=来源端 1=目标端）。
class ActiveCoverFlight {
  ActiveCoverFlight({
    required this.source,
    required this.sourceRect,
    required this.sourceRadius,
    required this.destRadius,
    required this.content,
    required this.routeAnimation,
    required this.destRect,
    this.destRectResolver,
    required this.beginValue,
    required this.isPop,
    required this.held,
  });

  /// 来源端登记条目（飞行内容、圆角与起飞矩形都从它取）。
  final CoverFlightSource source;

  /// 起飞瞬间定下的来源矩形（`CoverFlightSource.takeoffRect`，即点击那一刻的
  /// 静止位）。**全程固定**：来源页在转场中被壳层推走，跟着它飞等于把封面画到
  /// 屏幕外；框架 Hero 同样是在起飞时锁定两端。
  final Rect sourceRect;
  final BorderRadius sourceRadius;
  final BorderRadius destRadius;

  /// 目标端封面内容（未裁剪），飞行全程不透明（与播放页形变层同一取舍：
  /// 共享元素不参与页面自身的淡入淡出）。
  final Widget content;
  final Animation<double> routeAnimation;

  /// 目标端封面的**归位矩形**（目标端已反解掉路由转场的缩放，见
  /// `PlaylistCoverHero._settledDestRect`）。飞行层在页面之外不继承转场变换，
  /// 必须瞄归位位置，否则转场中会先落在偏右的缩放位置、落定时再跳回靠左。
  final Rect destRect;

  /// 每帧重算的归位矩形。**默认 null**：终点在起飞前一次算好、整段固定
  /// （真机教训：每帧跟着转场反解会让终点随进度漂动，落位时再被拉回一次）。
  /// 仅当调用方确实需要跟踪实时布局（如页头高度会边飞边变）才传解析函数。
  final Rect? Function()? destRectResolver;

  /// 每帧取用的终点矩形。
  Rect get liveDestRect => destRectResolver?.call() ?? destRect;

  /// 起飞那一刻的路由动画值。push 常晚于 0（目标端首帧 paint 才有矩形），
  /// 绘制时把剩余区间重标定到 [beginValue, 1]，起飞后走完全程不截断。
  final double beginValue;

  /// 是否为退场航班（pop：v 从 1→0，封面从目标端原路飞回来源端）。
  final bool isPop;

  /// 进场飞行落位后是否继续保持在目标位置：等目标端大图解码完成再撤走，
  /// 避免交接瞬间露出真实封面此刻的兜底占位。
  final bool held;

  /// 退场尾巴：路由已 dismissed（动画停在 0）但封面**继续盖一小段**再撤。
  /// 来源页的淡入/归位由壳层自己的动画驱动，可能比路由动画慢半拍；封面一撤而
  /// 底下的行还没完全不透明，观感就是「退场结束时发暗/闪一下」。
  bool tailHeld = false;
}

/// 排查日志用：dart:ui 的 `Rect.toString()` 只在 debug 生效，profile/release
/// 打出来是「Instance of 'Rect'」（真机取证读不到数值），这里显式格式化。
String coverFlightRectDebug(Rect? r) => r == null
    ? 'null'
    : 'L${r.left.toStringAsFixed(0)} T${r.top.toStringAsFixed(0)} '
      'W${r.width.toStringAsFixed(0)} H${r.height.toStringAsFixed(0)}';

/// 封面几何实测计数（**仅 debug 构建**，profile/release 里 `kDebugMode` 为 false，
/// 分支直接被常量折叠掉）。
///
/// 这是常驻成本的心电图：飞行只该在转场期发生，所以「列表滚动」「页面加载」这类
/// 场景必须一次都不调用实测。之前探针在 paint 里算矩形，等于每个封面每次绘制都
/// 沿祖先链走一趟 `getTransformTo` —— 算出来的值还没有消费者。
/// 数值断言见 `test/widgets/playlist_cover_flight_perf_test.dart`。
int coverFlightDebugMeasureCalls = 0;

void coverFlightDebugCountMeasure() {
  if (kDebugMode) coverFlightDebugMeasureCalls++;
}

/// 仅供测试：把计数清零。
@visibleForTesting
void coverFlightDebugResetMeasureCalls() => coverFlightDebugMeasureCalls = 0;
