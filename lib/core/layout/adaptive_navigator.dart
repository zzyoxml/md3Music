import 'package:material_ui/material_ui.dart';

import '../build_flags.dart';
import '../../data/repositories/settings_repository.dart';
import '../../widgets/playlist_cover_flight_bus.dart';
import '../../widgets/resizable_splitter.dart';
import '../theme/app_dimens.dart';
import 'page_layout.dart';

/// 混合导航分派与双栏 Master-Detail（横屏平板重设计计划 4.4 B）。
///
/// - [AdaptiveNav.openDetail]：详情入口的统一分派——处于双栏 [DetailPaneScope]
///   内（横屏平板 B 类页面）则 push 进右侧详情面板的嵌套 Navigator；否则退回
///   [Navigator.push]（中央内容导航 A 类 / 手机整屏，行为完全不变）。
/// - [DesktopTwoPane]：把一个「主列表」页装进左窄列 + 可拖拽分隔条 + 右侧详情
///   面板（嵌套 Navigator，初始为空态占位）。仅在桌面布局的 B 类 Tab 使用。

/// 详情面板作用域：由 [DesktopTwoPane] 注入，[AdaptiveNav.openDetail] 据此
/// 找到右侧详情面板的 Navigator。用 InheritedWidget 传递而非全局单例，天然
/// 支持多个双栏 Tab 各自独立的详情栈。
class DetailPaneScope extends InheritedWidget {
  const DetailPaneScope({
    super.key,
    required this.detailKey,
    this.history,
    this.twoPane = true,
    required super.child,
  });

  final GlobalKey<NavigatorState> detailKey;

  /// 该详情面板的前进历史（外壳注入，供工具栏「前进」）。
  final ForwardHistory? history;

  /// 详情面板当前是否处于**真双栏几何**（master 与详情并排）。
  ///
  /// 响应式壳层在窄宽度（手机竖屏）下 scope 依然存在、详情栈仍挂面板 Navigator，
  /// 但视觉上是单栏整屏。[AdaptiveNav.openDetail] 据此分派：单栏几何下详情改推
  /// Tab 中央栈，让封面连贯过渡走框架 Hero（两端同栈且栈上有控制器）；真双栏
  /// 保持推面板栈（跨栈两端框架 Hero 配对不了，走自绘飞行）。
  final bool twoPane;

  /// 查最近的详情面板 Navigator key（不建立重建依赖）。
  static GlobalKey<NavigatorState>? maybeOf(BuildContext context) {
    return _maybeOf(context)?.detailKey;
  }

  /// 查最近的详情面板前进历史（不建立重建依赖）。
  static ForwardHistory? historyOf(BuildContext context) {
    return _maybeOf(context)?.history;
  }

  static DetailPaneScope? _maybeOf(BuildContext context) {
    final el =
        context.getElementForInheritedWidgetOfExactType<DetailPaneScope>();
    return el?.widget as DetailPaneScope?;
  }

  @override
  bool updateShouldNotify(DetailPaneScope old) =>
      detailKey != old.detailKey ||
      history != old.history ||
      twoPane != old.twoPane;
}

/// 响应式右栏的局部尺寸；手机整屏与桌面版详情继续使用原来的头部高度。
class DetailPaneContent extends InheritedWidget {
  const DetailPaneContent({
    super.key,
    required this.narrow,
    required this.twoPane,
    required super.child,
  });
  final bool narrow;
  final bool twoPane;

  static bool isTwoPaneOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DetailPaneContent>()?.twoPane ?? false;

  static double headerHeight(BuildContext context, double original) =>
      context.dependOnInheritedWidgetOfExactType<DetailPaneContent>()?.narrow ==
          true
      ? 220
      : original;

  @override
  bool updateShouldNotify(DetailPaneContent oldWidget) =>
      narrow != oldWidget.narrow || twoPane != oldWidget.twoPane;
}

/// 详情面板的「前进」历史栈（计划 4.3 顶部工具栏前进/后退）。
///
/// 记录被「后退」弹出的详情页构建器，以便工具栏「前进」原样重建。仅覆盖经
/// [AdaptiveNav.openDetail] 进入详情面板的导航（该处会给路由打上
/// [ForwardTag] 供观察者在 pop 时回收 builder）。新的正向导航（非重放）会
/// 清空前进栈，符合浏览器式前进/后退语义。
class ForwardHistory extends ChangeNotifier {
  final List<WidgetBuilder> _stack = [];

  /// 正在重放前进项时置真：抑制观察者把这次 push 误判为「新导航」而清栈。
  bool replaying = false;

  /// 程序化复位详情栈（切 Tab）时置真：抑制把复位 pop 记进前进栈。
  bool suppressRecord = false;

  bool get canGoForward => _stack.isNotEmpty;

  /// 记录一次「后退」弹出的详情页。
  void recordBack(WidgetBuilder builder) {
    if (suppressRecord) return;
    _stack.add(builder);
    notifyListeners();
  }

  /// 取出下一个「前进」目标（无则 null）。
  WidgetBuilder? takeNext() {
    if (_stack.isEmpty) return null;
    final b = _stack.removeLast();
    notifyListeners();
    return b;
  }

  /// 正向导航发生：清空前进栈。
  void invalidate() {
    if (_stack.isEmpty) return;
    _stack.clear();
    notifyListeners();
  }
}

/// 路由标签：携带该详情路由的构建器，供前进历史在 pop 时回收重建。
class ForwardTag {
  const ForwardTag(this.builder);
  final WidgetBuilder builder;
}

/// 详情导航分派入口。各 B 类页面的详情入口把
/// `Navigator.push(context, MaterialPageRoute(builder: b))` 改为
/// `AdaptiveNav.openDetail(context, b)` 即可，无需自行判断布局。
class AdaptiveNav {
  const AdaptiveNav._();

  static Future<T?> openDetail<T>(
    BuildContext context,
    WidgetBuilder builder,
  ) {
    final scope = DetailPaneScope._maybeOf(context);
    final detailNav = scope?.detailKey.currentState;
    // 点击发生在面板栈内部（如详情页里的「相似歌单」再开详情）：最近 Navigator
    // 就是面板栈本身。此时不论几何是单栏还是双栏都必须继续留在面板栈内——推到
    // 中央栈会与面板栈形成两棵并行的二级栈，且两端 Hero 分属不同栈配不上。
    final nearestIsPane = detailNav != null &&
        identical(Navigator.maybeOf(context), detailNav);
    // ignore: avoid_print
    print('[FlashTrace] openDetail scope=${scope != null} '
        'twoPane=${scope?.twoPane} nearestIsPane=$nearestIsPane '
        'paneCanPopBeforePush=${detailNav?.canPop()} '
        'target=${builder.hashCode}');
    if (detailNav != null && (nearestIsPane || (scope?.twoPane ?? false))) {
      // 进入详情面板：打标签供前进历史回收；正向导航清空既有前进栈。
      final history = scope?.history;
      if (history != null && !history.replaying) history.invalidate();
      final route = _PaneDetailRoute<T>(
        builder: builder,
        settings: RouteSettings(arguments: ForwardTag(builder)),
      );
      // 武装歌单封面连贯过渡：详情页加载期间页头（含封面 Hero）可能晚于整个
      // 转场才首次绘制，靠路由动画状态判断会永远错过（真机实测 push 不飞）。
      PlaylistCoverFlightBus.instance.armPanePush(route);
      return detailNav.push(route);
    }
    // 单栏几何（手机整屏）：与搜索页等 A 类入口一样推最近的中央栈。Tab 内容栈
    // 自带 HeroController（responsive_shell 的 HeroControllerScope），两端同栈，
    // 封面连贯过渡由框架 Hero 完成——与搜索页专辑大封面过渡同一条链路。
    //
    // 中央内容导航（桌面 A 类）：最近的 Navigator 即当前 Tab 的中央栈；
    // 手机 / 竖屏：根 Navigator。两种情况都走 Navigator.push，行为不变。
    return Navigator.of(context).push(MaterialPageRoute<T>(builder: builder));
  }
}

/// 「页面形态」一级页面自带的双栏壳：LaunchPad「打开为页面」、快捷方式、发现页
/// 搜索图标等**不经 tab 壳层**的整屏入口用。宽屏（≥1000dp）下页面自带左列表 +
/// 右详情面板，与 tab 形态观感一致；窄屏由 [DesktopTwoPane] 的响应式分支退化成
/// 单栏整屏，同一条降级路径。
///
/// tab master 由壳层按 [kTwoPaneTabs] 已包过 [DesktopTwoPane]，**勿在 tab 形态
/// 下再套本组件**（会双层双栏）。TV 构建原样返回不包装——页面形态的面板栈拿不到
/// 壳层注入的 TV 焦点校正观察者，TV 行为保持与历史版本一致。
///
/// 返回键语义与 tab 形态对齐（响应式壳层 maybePop 的顺序）：先弹本页面板栈里的
/// 详情，栈空了才关掉本页面——否则详情还开着时按返回会整页直接消失。
class TwoPanePage extends StatefulWidget {
  const TwoPanePage({super.key, required this.child});

  /// 一级页面本体（如 SearchPage / AudiobookPage），作为左栏 master。
  final Widget child;

  @override
  State<TwoPanePage> createState() => _TwoPanePageState();
}

class _TwoPanePageState extends State<TwoPanePage> {
  final GlobalKey<NavigatorState> _detailKey = GlobalKey<NavigatorState>();

  Future<void> _handlePop(bool didPop) async {
    if (didPop) return;
    final detail = _detailKey.currentState;
    if (detail != null && await detail.maybePop()) return;
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    if (kTvBuild) return widget.child;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) => _handlePop(didPop),
      child: DesktopTwoPane(
        responsive: true,
        detailKey: _detailKey,
        master: widget.child,
      ),
    );
  }
}

/// 双栏 Master-Detail 容器：左侧主列表 + 可拖拽分隔条 + 右侧详情面板。
///
/// [detailKey]/[detailObservers] 由外壳（[DesktopShell]）注入，使工具栏返回键
/// 与系统返回能作用于详情面板栈；未注入时内部自建 key（独立使用场景）。
class DesktopTwoPane extends StatefulWidget {
  const DesktopTwoPane({
    super.key,
    required this.master,
    this.detailKey,
    this.detailObservers = const [],
    this.history,
    this.emptyState,
  this.responsive = false,
    this.masterFooter,
    this.onDetailFullscreenChanged,
  });

  /// 左侧主列表页（通常是原 Tab 页，如收藏 / 本地乐库）。
  final Widget master;

  /// 详情面板 Navigator key（外壳注入以驱动返回键）。
  final GlobalKey<NavigatorState>? detailKey;

  /// 详情面板 Navigator 观察者（外壳注入 ToolbarSync 以刷新返回键可用态）。
  final List<NavigatorObserver> detailObservers;

  /// 详情面板前进历史（外壳注入，供工具栏「前进」）。
  final ForwardHistory? history;

  /// 详情为空时的占位（默认居中提示）。
  final Widget? emptyState;

  /// 响应式壳层在窄窗将详情栈铺满；桌面外壳保持原来的固定双栏。
  final bool responsive;

  /// 主列表列**底部**的固定槽（默认 null = 不占位，行为与从前一致）。
  ///
  /// 用途：一级页面退回底部常驻播放条、而二级页面仍用悬浮条时，常驻条必须只占
  /// 左栏宽度 —— 挂在壳层底部会横贯两栏，右栏就会出现「悬浮条 + 全宽常驻条」上下
  /// 两条。放进 master 列则天然跟随分隔条拖拽，且窄窗退化成单栏时 master 就是
  /// 全宽，槽也随之全宽，不会与 [resolvePaneGeometry] 的判定错配。
  final Widget? masterFooter;

  /// 详情面板是否**独占整宽**（单栏态：详情铺满、master 被遮住）时回调。
  ///
  /// 只由响应式壳层使用。详情经 [AdaptiveNav.openDetail] 挂在**详情面板自己的
  /// Navigator** 上，壳层挂在中央 Navigator 的深度观察者看不见它，于是「收藏 →
  /// 歌单详情」这类单栏整屏的二级页面不会被认定为二级（底部导航栏收不起来）。
  /// 双栏态（master 仍在场）必须报 false —— 那时用户看到的还是一级列表页。
  final ValueChanged<bool>? onDetailFullscreenChanged;

  @override
  State<DesktopTwoPane> createState() => _DesktopTwoPaneState();
}

class _DesktopTwoPaneState extends State<DesktopTwoPane> {
  static const double _kMinMaster = 280.0;
  static const double _kMaxMaster = 560.0;
  static const double _kDefaultFraction = 0.34;

  final SettingsRepository _settings = SettingsRepository();
  late final GlobalKey<NavigatorState> _detailKey =
      widget.detailKey ?? GlobalKey<NavigatorState>();

  double _masterFraction = _kDefaultFraction;
  double _lastTotalWidth = 1200.0;

  bool _hasDetail = false;

  /// 单栏态下 master 列是否可以被隐藏：**顶层详情路由的进场动画播完才为真**。
  ///
  /// 旧实现只看 [_hasDetail]（push 当帧即翻真）：master 在详情还在淡入/上滑时就被
  /// Offstage，用户看到「列表突然消失 → 空背景上半路播着的详情页」的硬切。
  /// 保持 master 在场直到动画收敛，转场底下就是列表本身（与手机原生 push 视觉
  /// 一致）；收敛后才 Offstage+停 ticker，不违反不可见限帧原则。
  bool _masterCovered = true;

  /// 详情路由**退场动画进行中**：canPop 在 pop 首帧即变 false（Flutter 3.44 起
  /// 被 pop 路由立刻离开 present 态），[_hasDetail] 不再能代表「面板上有内容」；
  /// 单栏态若此时按旧条件 Offstage 面板，退场页会凭空消失（硬切）。用本标志把
  /// 面板留在原位播完退场，底下由仍在场的 master 垫底。
  bool _popOutActive = false;
  Animation<double>? _coverAnim;

  late final NavigatorObserver _responsiveObserver = _DetailStackObserver(
    _onDetailChanged,
    onPushed: _onTopRoutePushed,
    onPopped: _onTopRoutePopped,
  );

  /// push 可能发生在 build 期间（嵌套 Navigator 首帧挂载 restoreState 也走
  /// didPush），与 [_onDetailChanged] 同理必须推迟到帧末再 setState。
  void _onTopRoutePushed(Route<dynamic> route) {
    if (!widget.responsive) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _coverAnim?.removeStatusListener(_onCoverStatus);
      _coverAnim = null;
      setState(() {
        _masterCovered = false;
        _popOutActive = false;
      });
      final anim = _paneAnimationOf(route);
      if (anim == null) {
        setState(() => _masterCovered = true);
        return;
      }
      _coverAnim = anim
        ..addStatusListener(_onCoverStatus);
      if (anim.isCompleted) setState(() => _masterCovered = true);
    });
  }

  void _onTopRoutePopped(Route<dynamic> route) {
    if (!widget.responsive) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _coverAnim?.removeStatusListener(_onCoverStatus);
      _coverAnim = null;
      final anim = _paneAnimationOf(route);
      final keepForPop =
          anim != null && anim.status != AnimationStatus.dismissed;
      setState(() {
        // 退场动画期间 master 必须在场，垫在被移出的详情页底下。
        _masterCovered = false;
        _popOutActive = keepForPop;
      });
      if (keepForPop) {
        _coverAnim = anim
          ..addStatusListener(_onCoverStatus);
      }
    });
  }

  /// [Route.animation] 是 @protected，仅 [AdaptiveNav.openDetail] 专用路由
  /// （[_PaneDetailRoute]）在此暴露；其余路由（理论不存在于本面板）退回
  /// 「立即收敛」= 维持修复前行为。
  Animation<double>? _paneAnimationOf(Route<dynamic> route) =>
      route is _PaneDetailRoute ? route.transitionAnimation : null;

  void _onCoverStatus(AnimationStatus status) {
    if (!mounted) return;
    if (status == AnimationStatus.dismissed &&
        _popOutActive &&
        !_hasDetail) {
      // 退场动画播完（反向到 0 是 dismissed）且面板上已无 present 路由：
      // 交回 [_hasDetail] 逻辑把空面板 Offstage。
      setState(() => _popOutActive = false);
      return;
    }
    if (status == AnimationStatus.completed && _hasDetail && !_masterCovered) {
      setState(() => _masterCovered = true);
    }
  }

  void _onDetailChanged() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final hasDetail = _detailKey.currentState?.canPop() ?? false;
      if (hasDetail != _hasDetail) {
        // ignore: avoid_print
        print('[FlashTrace] pane hasDetail:$_hasDetail->$hasDetail '
            'responsive=${widget.responsive}');
        setState(() => _hasDetail = hasDetail);
      }
    });
  }

  /// 上一次上报的「详情独占整宽」，用于去重（build 期间写的普通字段，非 setState）。
  bool _reportedDetailFullscreen = false;

  /// 单栏态下详情铺满整宽（master 被遮住）= 用户看到的是二级页面，上报给壳层收起
  /// 底部导航栏；双栏态 master 仍在场，报 false（见 [onDetailFullscreenChanged]）。
  void _reportDetailFullscreen(bool fullscreen) {
    if (!widget.responsive || fullscreen == _reportedDetailFullscreen) return;
    _reportedDetailFullscreen = fullscreen;
    // 壳层只登记帧末回调，build 期间同步调用是安全的。
    widget.onDetailFullscreenChanged?.call(fullscreen);
  }

  @override
  void initState() {
    super.initState();
    if (!widget.responsive) _loadRatio();
  }

  @override
  void dispose() {
    _coverAnim?.removeStatusListener(_onCoverStatus);
    super.dispose();
  }

  Future<void> _loadRatio() async {
    final r = await _settings.getDesktopDetailRatio();
    if (!mounted || r == null) return;
    setState(() => _masterFraction = r.clamp(0.15, 0.6));
  }

  void _onDelta(double dx) {
    setState(() {
      if (widget.responsive) {
        // 从当前显示的宽度开始拖，避免在窄面板上碰到上限后出现回拖死区。
        final current = resolvePaneGeometry(
          width: _lastTotalWidth,
          masterFraction: _masterFraction,
        ).masterWidth;
        final master = (current + dx).clamp(
          AppLayout.twoPaneMasterWidth, _lastTotalWidth - 496,
        );
        _masterFraction = master / _lastTotalWidth;
        return;
      }
      final master = (_masterFraction * _lastTotalWidth + dx)
          .clamp(_kMinMaster, _kMaxMaster);
      _masterFraction = (master / _lastTotalWidth).clamp(0.0, 1.0);
    });
  }

  void _persist() {
    if (widget.responsive) return;
    // ignore: discarded_futures
    _settings.setDesktopDetailRatio(_masterFraction);
  }

  /// 把 [DesktopTwoPane.masterFooter] 贴在主列表列底部（不传槽时原样返回）。
  Widget _withMasterFooter(Widget master) {
    final footer = widget.masterFooter;
    if (footer == null) return master;
    return Column(children: [Expanded(child: master), footer]);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        _lastTotalWidth = c.maxWidth;
        final masterW =
            (_masterFraction * c.maxWidth).clamp(_kMinMaster, _kMaxMaster,
        );
        if (widget.responsive) {
          final mq = MediaQuery.of(context);
          // 响应式内容位于 rail 右侧并已消费横向 SafeArea。displayFeatures 是
          // 窗口坐标，先扣除 rail/左安全区的占位，再按面板局部宽度求值。
          final leftInset = mq.size.width - c.maxWidth - mq.viewPadding.right;
          final obstructions = [
            for (final feature in mq.displayFeatures)
              if (feature.bounds.height > feature.bounds.width &&
                  feature.bounds.height >= mq.size.height / 2)
                feature.bounds.shift(Offset(-leftInset, 0)),
          ];
          final geometry = resolvePaneGeometry(
            width: c.maxWidth,
            masterFraction: _masterFraction,
            verticalObstructions: obstructions,
          );
          final twoPane = geometry.twoPane;
          final width = geometry.masterWidth;
          // 单栏 + 有详情 = 详情整屏盖住 master，壳层据此认定二级页面。
          _reportDetailFullscreen(!twoPane && _hasDetail);
          // 单栏 + 有详情 + 顶层路由动画已收敛 = 才允许藏起 master；
          // 转场进行中转场底下仍是列表本体（见 [_masterCovered]）。
          final masterHidden = !twoPane && _hasDetail && _masterCovered;
          // 两个 Navigator 始终处于同一位置。旋转只改布局约束，不复制路由，
          // 因此表单、滚动位置、返回值 Future 及多层详情栈均保留。
          return DetailPaneScope(
            detailKey: _detailKey,
            twoPane: twoPane,
            child: Stack(
              children: [
                Positioned(
                  left: geometry.masterLeft,
                  top: 0,
                  bottom: 0,
                  width: width,
                  child: Offstage(
                    offstage: masterHidden,
                    child: TickerMode(
                      enabled: !masterHidden,
                      child: _withMasterFooter(
                        ContentWidth(child: widget.master),
                      ),
                    ),
                  ),
                ),
                if (twoPane && obstructions.isEmpty)
                  Positioned(
                    left: width,
                    top: 0,
                    bottom: 0,
                    child: ResizableSplitter(
                      onDelta: _onDelta,
                      onDragEnd: _persist,
                    ),
                  ),
                Positioned(
                  key: const ValueKey('responsive-detail'),
                  left: geometry.detailLeft,
                  width: geometry.detailWidth,
                  top: 0,
                  bottom: 0,
                  child: Offstage(
                    // 退场动画未播完时面板不能 Offstage（见 [_popOutActive]）。
                    offstage: !twoPane && !_hasDetail && !_popOutActive,
                    child: TickerMode(
                      enabled: twoPane || _hasDetail || _popOutActive,
                      child: ContentWidth(
                        maxWidth: twoPane
                            ? AppLayout.twoPaneDetailMaxWidth
                            : AppLayout.maxContentWidth,
                        child: DetailPaneContent(
                          narrow: twoPane && geometry.detailWidth < 720,
                          twoPane: twoPane,
                          child: Navigator(
                            key: _detailKey,
                            observers: [
                              _responsiveObserver,
                              ...widget.detailObservers,
                            ],
                            onGenerateRoute: (s) =>
                                MaterialPageRoute<void>(
                              settings: s,
                              builder: (_) => _ResponsiveDetailBase(
                                emptyState: widget.emptyState ??
                                    const DetailEmptyState(),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        }
        return DetailPaneScope(
          detailKey: _detailKey,
          history: widget.history,
          // 桌面外壳恒为并排双栏。
          twoPane: true,
          child: Row(
            children: [
              SizedBox(width: masterW, child: _withMasterFooter(widget.master)),
              ResizableSplitter(onDelta: _onDelta, onDragEnd: _persist),
              Expanded(
                child: Navigator(
                  key: _detailKey,
                  observers: widget.detailObservers,
                  onGenerateRoute: (s) => MaterialPageRoute(
                    settings: s,
                    builder: (_) =>
                        widget.emptyState ?? const DetailEmptyState(),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// [AdaptiveNav.openDetail] 推入详情面板的专用路由：把 @protected 的进场/退场
/// 动画对外暴露为 [transitionAnimation]，供 `_DesktopTwoPaneState` 判断
/// 「转场是否收敛」以决定单栏态 master 列的藏匿时机（见 `_masterCovered`）。
class _PaneDetailRoute<T> extends MaterialPageRoute<T> {
  _PaneDetailRoute({required super.builder, super.settings});

  Animation<double>? get transitionAnimation => animation;
}

class _DetailStackObserver extends NavigatorObserver {
  _DetailStackObserver(
    this.onChanged, {
    this.onPushed,
    this.onPopped,
  });
  final VoidCallback onChanged;

  /// 顶层路由进场/退场的起止事件（响应式单栏用于 master 藏匿时机，见
  /// `_DesktopTwoPaneState._masterCovered`）。
  final void Function(Route<dynamic> route)? onPushed;
  final void Function(Route<dynamic> route)? onPopped;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    onChanged();
    onPushed?.call(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    onChanged();
    onPopped?.call(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      onChanged();

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      onChanged();
}

/// 响应式详情面板栈底路由：双栏显示空态占位，单栏渲染空白。
///
/// 单栏（宽度 < twoPaneBreakpoint）时详情仍经 [AdaptiveNav.openDetail] 挂在
/// 本嵌套 Navigator 上（旋转只改约束、不复制路由的既有不变量）；若栈底继续
/// 渲染 [DetailEmptyState]，进场/返回转场动画期间会在页面下方露出
/// 「从左侧选择一项查看详情」，手机上表现为整屏闪现。渲染空白让转场在
/// 背景上完成，无任何文案闪现。
///
/// 依赖 [DetailPaneContent]（随几何重建，updateShouldNotify 覆盖 twoPane 变化）：
/// 单/双栏切换时栈底随之自动切换占位/空白。
class _ResponsiveDetailBase extends StatelessWidget {
  const _ResponsiveDetailBase({required this.emptyState});

  final Widget emptyState;

  @override
  Widget build(BuildContext context) =>
      DetailPaneContent.isTwoPaneOf(context)
      ? emptyState
      : const SizedBox.shrink();
}

/// 详情面板空态占位（未选中任何项时）。
///
/// 桌面外壳（[DesktopTwoPane]）与设置页 Pad 双列共用。默认参数保持
/// 桌面外壳原行为；[icon]/[text] 可定制文案与图标，[color] 覆盖背景色
/// （null = surface；悬浮于壁纸之上的页面传 [Colors.transparent]）。
class DetailEmptyState extends StatelessWidget {
  const DetailEmptyState({
    super.key,
    this.icon = Icons.library_music_outlined,
    this.text = '从左侧选择一项查看详情',
    this.color,
  });

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: color ?? cs.surface,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: cs.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              text,
              style: Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
