import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:m3e_core/m3e_core.dart';

import '../../core/build_flags.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../discover/home_discover_refill.dart';
import '../personal_fm/personal_fm_core.dart'
    show FmStation, PersonalFmWidgetActions, kFmStations;
import '../player/full_player_route.dart';
import '../../widgets/scroll_aware_app_bar.dart';
import 'coverflow_source.dart';

/// 封面流页横屏沉浸开关（用户请求语义）：
/// - 长按封面流页面切换（横屏有效）；
/// - 沉浸中按返回键恢复；
/// - _MainLayout 据此 + 当前 tab + 方向计算实际沉浸状态 [kCoverFlowImmersiveActive]。
final ValueNotifier<bool> kCoverFlowImmersive = ValueNotifier<bool>(false);

/// 封面流页横屏「实际生效」的沉浸状态：仅 coverflow tab + 横屏 + 用户请求时
/// 为 true，由 _MainLayout 同步，_SystemUiUpdater 据此跳过系统栏模式覆盖。
final ValueNotifier<bool> kCoverFlowImmersiveActive = ValueNotifier<bool>(false);

/// 封面流当前居中歌曲的下标。
/// 横竖屏切换时 _MainLayout 会在 ResponsiveScaffold 的 compact/medium 槽位间
/// 切换，整棵子树会被卸载重建（State 丢失、回到第一张封面）。
/// 用模块级变量在重建间保留当前位置，避免旋转后回到第一张。
int kCoverFlowIndex = 0;

/// 封面流 Tab 页：以 CoverFlow 3D 封面流展示歌单源内容。
///
/// 歌单源由设置页「播放 → 列表与交互 → 封面流」选择（[kCoverFlowSource]，默认
/// 每日推荐）；私人FM 细分档（红心/探索/小众）摊平为独立源值（口径同
/// StartupAutoPlaySource），档位映射见 [CoverFlowSource.fmStationIndex]。
/// 数据复用 [KugouProvider] 既有列表与缓存，不新增 API。
/// 私人FM / 刷歌推荐在接近列表末尾时自动补货（[_CoverFlowPageState._maybeLoadMore]）；
/// 点击起播时会给播放队列挂对应源的续播器（[_CoverFlowView._playFromIndex]），
/// 队列播到末尾自动接新歌；每日推荐是固定日列表，无翻页接口。
/// 横竖屏自适应：竖屏单卡约占屏宽 62%，横屏约 34%。
class CoverFlowPage extends StatefulWidget {
  const CoverFlowPage({super.key});

  @override
  State<CoverFlowPage> createState() => _CoverFlowPageState();
}

class _CoverFlowPageState extends State<CoverFlowPage> {
  /// 当前居中的歌曲下标（横竖屏切换重建封面流时保留位置）。
  /// 初始值取模块级 [kCoverFlowIndex]，重建后继续上次的位置。
  int _currentIndex = kCoverFlowIndex;

  /// 居中下标距列表末尾小于该值时触发自动补货（私人FM / 刷歌推荐）。
  /// 3 = 一次拖拽手势通常翻 1~2 页，留出余量让下一批在滑到头前到位。
  static const int _refillThreshold = 3;

  /// 补货在飞标记：onPageChanged 在拖动/吸附中高频触发，靠它防重入。
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    kCoverFlowSource.addListener(_onSourceChanged);
    // provider 内 5 分钟 TTL，重复进入自动复用缓存；跨天失效自动重拉
    _loadForSource(kCoverFlowSource.value);
  }

  @override
  void dispose() {
    kCoverFlowSource.removeListener(_onSourceChanged);
    super.dispose();
  }

  /// 当前源对应的 FM 电台档；非 FM 源返回 null。
  FmStation? get _currentStation {
    final index = kCoverFlowSource.value.fmStationIndex;
    if (index == null) return null;
    return kFmStations[index.clamp(0, kFmStations.length - 1)];
  }

  /// 歌单源切换（设置页改选，含 FM 细分档切换）：复位居中位置并按新源拉取。
  /// 各源在 provider 内各有独立缓存与 TTL，切回最近用过的源秒出。
  void _onSourceChanged() {
    if (!mounted) return;
    setState(() {
      kCoverFlowIndex = 0;
      _currentIndex = 0;
    });
    _loadForSource(kCoverFlowSource.value);
  }

  /// 按源触发拉取（无参调用走 provider 各自的 TTL 缓存）。
  void _loadForSource(CoverFlowSource source) {
    final kugou = context.read<KugouProvider>();
    switch (source) {
      case CoverFlowSource.daily:
        kugou.getRecommendDaily();
      case CoverFlowSource.fmHeart:
      case CoverFlowSource.fmExplore:
      case CoverFlowSource.fmNiche:
      case CoverFlowSource.fmRadio:
        final station = _currentStation!;
        kugou.getPersonalFm(
          mode: station.mode,
          songPoolId: station.songPoolId,
        );
      case CoverFlowSource.homeDiscover:
        kugou.getHomeDiscover();
    }
  }

  Future<void> _refresh() async {
    final kugou = context.read<KugouProvider>();
    switch (kCoverFlowSource.value) {
      case CoverFlowSource.daily:
        await kugou.getRecommendDaily(forceRefresh: true);
      case CoverFlowSource.fmHeart:
      case CoverFlowSource.fmExplore:
      case CoverFlowSource.fmNiche:
      case CoverFlowSource.fmRadio:
        final station = _currentStation!;
        await kugou.getPersonalFm(
          mode: station.mode,
          songPoolId: station.songPoolId,
          forceRefresh: true,
        );
      case CoverFlowSource.homeDiscover:
        await kugou.getHomeDiscover(forceRefresh: true);
    }
  }

  /// 接近列表末尾时自动补货（私人FM / 刷歌推荐；每日推荐是固定日列表无翻页接口）。
  ///
  /// 由 [onPageChanged]（居中下标变更，已去重）驱动。FM 的补货语义与 FM 页
  /// 续播器（personal_fm_core FmRefill）一致：以列表最后一首为游标取下一批，
  /// 结果经 appendFmSongs 去重并入列表——fetchMorePersonalFm 本身不替换列表。
  Future<void> _maybeLoadMore(int index) async {
    if (_loadingMore) return;
    final source = kCoverFlowSource.value;
    if (source == CoverFlowSource.daily) return;
    final kugou = context.read<KugouProvider>();
    final songs = switch (source) {
      CoverFlowSource.daily => const <KugouSongDetail>[],
      CoverFlowSource.fmHeart ||
      CoverFlowSource.fmExplore ||
      CoverFlowSource.fmNiche ||
      CoverFlowSource.fmRadio => kugou.personalFmSongs,
      CoverFlowSource.homeDiscover => kugou.homeDiscoverSongs,
    };
    if (songs.isEmpty || index < songs.length - _refillThreshold) return;
    _loadingMore = true;
    try {
      switch (source) {
        case CoverFlowSource.daily:
          break;
        case CoverFlowSource.fmHeart:
        case CoverFlowSource.fmExplore:
        case CoverFlowSource.fmNiche:
        case CoverFlowSource.fmRadio:
          final station = _currentStation!;
          final fresh = await kugou.fetchMorePersonalFm(
            mode: station.mode,
            songPoolId: station.songPoolId,
            hash: songs.last.hash,
            songId: songs.last.songId,
          );
          if (fresh != null && fresh.isNotEmpty) {
            kugou.appendFmSongs(fresh);
          }
        case CoverFlowSource.homeDiscover:
          // 内部完成游标推进 / 去重 / 追加列表 / notifyListeners
          await kugou.fetchMoreHomeDiscover();
      }
    } finally {
      _loadingMore = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final source = kCoverFlowSource.value;
    return Scaffold(
      // 横屏沉浸模式：隐藏顶栏
      appBar: isLandscape
          ? null
          : ScrollAwareAppBar(title: '封面流', opaque: true),
      body: Consumer<KugouProvider>(
        builder: (context, kugou, _) {
          final songs = switch (source) {
            CoverFlowSource.daily => kugou.recommendSongs,
            CoverFlowSource.fmHeart ||
            CoverFlowSource.fmExplore ||
            CoverFlowSource.fmNiche ||
            CoverFlowSource.fmRadio => kugou.personalFmSongs,
            CoverFlowSource.homeDiscover => kugou.homeDiscoverSongs,
          };
          if (songs.isEmpty && kugou.isLoading) {
            return const Center(child: M3ELoadingIndicator());
          }
          if (songs.isEmpty) {
            return _buildEmpty(source);
          }
          return Column(
            children: [
              Expanded(
                child: _CoverFlowView(
                  // 源切换必然换歌单列表：用 source 作 key 强制重建视图，
                  // 内部 _pageNotifier / _lastReported 等状态随之归零，
                  // 避免旧 page 越过新列表边界。
                  key: ValueKey<CoverFlowSource>(source),
                  songs: songs,
                  initialIndex: _currentIndex,
                  onPageChanged: (index) {
                    // 同步回模块级变量，供横竖屏切换重建页面时恢复位置
                    kCoverFlowIndex = index;
                    setState(() => _currentIndex = index);
                    // 接近末尾自动补货（私人FM / 刷歌推荐）
                    unawaited(_maybeLoadMore(index));
                  },
                  onRefresh: _refresh,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildEmpty(CoverFlowSource source) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.album_outlined,
            size: 64,
            color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            source.emptyHint,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            onPressed: _refresh,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('刷新'),
          ),
        ],
      ),
    );
  }
}

/// CoverFlow 3D 封面流控件（参考 iOS CoverFlow 视觉：中间正面、两侧绕 Y 轴旋转）。
///
/// 自绘布局（非 PageView，修复两个固有缺陷）：
/// - **z 顺序**：卡片按「离中心距离」降序绘制（远处在下、近处在上），
///   中央卡片永远最上层，两侧近者盖远者，避免 PageView 按 index 绘制导致
///   右侧卡片盖住中央卡片；
/// - **超界消失**：外层 Stack 以视口为界裁剪，卡片部分滑出视口时仅被视口
///   自然裁切，完全移出视口（中心偏移 + 半径 > 半视口）才不构建，
///   实现「等完全超出再消失」，而非 PageView 页边界的硬切。
class _CoverFlowView extends StatefulWidget {
  final List<KugouSongDetail> songs;
  final int initialIndex;
  final ValueChanged<int> onPageChanged;

  /// 首/尾越界拖拽触发的下拉刷新（自绘手势无 Scrollable，替代 RefreshIndicator）。
  final Future<void> Function() onRefresh;

  const _CoverFlowView({
    super.key,
    required this.songs,
    required this.initialIndex,
    required this.onPageChanged,
    required this.onRefresh,
  });

  @override
  State<_CoverFlowView> createState() => _CoverFlowViewState();
}

class _CoverFlowViewState extends State<_CoverFlowView>
    with TickerProviderStateMixin {
  /// 当前滚动位置（页索引，double；整数部分 = 居中的歌曲下标）。
  ///
  /// 用 ValueNotifier 驱动：拖动/吸附每帧只更新 notifier，卡片变换与
  /// 底部信息条各自订阅，不再 setState 重建整棵页面树。
  late final ValueNotifier<double> _pageNotifier =
      ValueNotifier<double>(widget.initialIndex.toDouble());
  double get _page => _pageNotifier.value;
  /// 已上报的整数页（onPageChanged 去重）。
  late int _lastReported = widget.initialIndex;
  /// 上一次的页值，用于判断滑动方向（决定文字淡入淡出顺序）。
  late double _lastPageValue = _page;
  /// 手势开始时记录的起始页与累计主轴位移（跟手滑动）。
  double _dragStartPage = 0;
  double _dragCumulative = 0;
  /// 吸附动画（惯性停止 + 点击两侧聚焦居中共用）。
  AnimationController? _snap;
  Animation<double>? _snapAnim;
  /// 下拉刷新状态。
  bool _refreshing = false;
  bool _refreshArmed = true;
  double _overscrollPull = 0;

  // 布局参数（每次 build 由 LayoutBuilder 重算，横竖屏切换自动生效）
  bool _isPortrait = true;
  double _mainAxis = 0; // 主轴（滑动方向）尺寸
  double _crossAxis = 0; // 交叉轴尺寸
  double _cardWidth = 0; // 正方形封面边长
  double _slot = 0; // 页槽（惯性吸附换算用）
  double _near = 0; // 相邻卡中心距
  double _far = 0; // 更远卡递进距离

  @override
  void dispose() {
    _snap?.dispose();
    _pageNotifier.dispose();
    super.dispose();
  }

  /// 按当前方向计算布局参数。
  void _updateParams(BoxConstraints constraints) {
    _isPortrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    _mainAxis = _isPortrait ? constraints.maxHeight : constraints.maxWidth;
    _crossAxis = _isPortrait ? constraints.maxWidth : constraints.maxHeight;
    // 卡片宽度按方向自适应，上限不超过可用高度，保证竖屏/横屏都不溢出。
    _cardWidth = (_isPortrait
            ? (constraints.maxWidth * 0.62)
                .clamp(0.0, constraints.maxHeight * 0.62)
            : (constraints.maxWidth * 0.3)
                .clamp(0.0, constraints.maxHeight * 0.6))
        .toDouble();
    _slot = _mainAxis * (_isPortrait ? 0.45 : 0.2);
    _near = _mainAxis * (_isPortrait ? 0.50 : 0.22);
    _far = _mainAxis * (_isPortrait ? 0.58 : 0.27);
  }

  /// 卡片相对视口中心的主轴偏移：近密远疏扇形堆叠
  /// （参考 coverflow_carousel 的 getCardPosition：近卡间距 [ _near]，远卡递进 [ _far]）。
  double _cardPos(double d) {
    final ad = d.abs();
    if (ad <= 1) return d * _near;
    return d.sign * (_near + (ad - 1) * _far);
  }

  void _reportPage() {
    final rounded = _page.round().clamp(0, widget.songs.length - 1).toInt();
    if (rounded != _lastReported) {
      _lastReported = rounded;
      widget.onPageChanged(rounded);
    }
  }

  /// 吸附动画到 [target] 页（点击聚焦与惯性停止共用，时长放缓避免吸附过猛）。
  void _animateTo(double target) {
    _snap?.dispose();
    _snap = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _snapAnim = Tween<double>(begin: _page, end: target).animate(
      CurvedAnimation(parent: _snap!, curve: Curves.easeOutCubic),
    );
    _snap!.addListener(() {
      // 每帧只更新 notifier：卡片变换与信息条各自订阅重建，
      // 不再 setState 重建整棵页面树
      _pageNotifier.value = _snapAnim!.value;
      _reportPage();
    });
    _snap!.forward();
  }

  // ---- 手势：竖屏垂直、横屏水平；跟手滑动 + 惯性吸附 + 越界刷新 ----

  void _onDragStart(DragStartDetails d) {
    _snap?.stop(); // 打断吸附动画，继续跟手
    _dragStartPage = _page;
    _dragCumulative = 0;
    _overscrollPull = 0;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    final delta = _isPortrait ? d.delta.dy : d.delta.dx;
    _dragCumulative += delta;
    final raw = _dragStartPage - _dragCumulative / _slot;
    final maxPage = (widget.songs.length - 1).toDouble();
    final clamped = raw.clamp(0.0, maxPage);
    // 越界拖拽：已到首/尾页仍继续向外拖 → 累计位移超阈值后触发下拉刷新
    final pulling =
        (clamped <= 0 && raw > 0) || (clamped >= maxPage && raw < maxPage);
    if (pulling && _refreshArmed) {
      _overscrollPull += delta.abs();
      if (_overscrollPull > 80 && !_refreshing) {
        _refreshing = true;
        _refreshArmed = false;
        widget.onRefresh().whenComplete(() {
          if (!mounted) return;
          setState(() => _refreshing = false);
          // 冷却后再允许触发，避免连续拖拽反复刷新
          Future.delayed(const Duration(milliseconds: 600), () {
            if (mounted) _refreshArmed = true;
          });
        });
      }
    }
    // 只更新 notifier：卡片/信息条订阅者自行重建，无需 setState
    _pageNotifier.value = clamped;
    _reportPage();
  }

  void _onDragEnd(DragEndDetails d) {
    final v = _isPortrait
        ? d.velocity.pixelsPerSecond.dy
        : d.velocity.pixelsPerSecond.dx;
    // 速度换算成页速后外推 0.25s 取整页吸附（方向与拖动一致）
    final pageVelocity = -v / _slot;
    final target = (_page + pageVelocity * 0.25)
        .round()
        .clamp(0, widget.songs.length - 1)
        .toDouble();
    _animateTo(target);
  }

  @override
  Widget build(BuildContext context) {
    final isPortrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    final colorScheme = Theme.of(context).colorScheme;
    return Focus(
      // TV：封面流单焦点停点（autofocus 仅 TV 构建开启，进页即可方向键翻页）
      autofocus: kTvBuild,
      onKeyEvent: _handleTvKey,
      child: Stack(
        children: [
          // 底层：卡片层（全屏）。ClipRect 双重保险：卡片/阴影/3D 变换的
          // 任何溢出绘制都被裁剪在本区域内，不会盖到左侧 tab 栏（NavigationRail）。
          Positioned.fill(
            child: ClipRect(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  _updateParams(constraints);
                  final n = widget.songs.length;
                  final halfMain = _mainAxis / 2;
                  final halfCard = _cardWidth / 2;
                  // 卡片定位：交叉轴居中、主轴中心对齐视口中心。
                  // 注意横屏时主轴=宽、交叉轴=高，left/top 需按方向取对应轴。
                  final left0 = (_isPortrait ? _crossAxis : _mainAxis) / 2 -
                      halfCard;
                  final top0 = (_isPortrait ? _mainAxis : _crossAxis) / 2 -
                      halfCard;
                  // 拖动/吸附期间只重建本 builder（可见性筛选 + 轻量卡片包装），
                  // 每张卡片的封面 widget 实例（CachedNetworkImage）经 child
                  // 参数复用，不随帧重建。
                  return ValueListenableBuilder<double>(
                    valueListenable: _pageNotifier,
                    builder: (context, page, _) {
                      // 视口内可见卡片：中心偏移 + 卡片半径与视口相交才绘制
                      // （完全移出视口才消失，滑出部分由 Stack 按视口边界裁剪）
                      final visible = <int>[];
                      for (var i = 0; i < n; i++) {
                        if (_cardPos(i - page).abs() > halfMain + halfCard) {
                          continue;
                        }
                        visible.add(i);
                      }
                      // z 顺序：按「离中心距离」降序绘制——远处先画（在下层）、
                      // 中央最后画（最上层），保证当前专辑不被左右两侧卡片遮挡
                      // （横屏时两侧卡片绕 Y 轴旋转，会与中央区域视觉重叠）。
                      visible.sort((a, b) {
                        final da = (a - page).abs();
                        final db = (b - page).abs();
                        return db.compareTo(da);
                      });
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onVerticalDragStart: _isPortrait ? _onDragStart : null,
                        onVerticalDragUpdate: _isPortrait ? _onDragUpdate : null,
                        onVerticalDragEnd: _isPortrait ? _onDragEnd : null,
                        onHorizontalDragStart: _isPortrait ? null : _onDragStart,
                        onHorizontalDragUpdate: _isPortrait ? null : _onDragUpdate,
                        onHorizontalDragEnd: _isPortrait ? null : _onDragEnd,
                        // 横屏长按：切换封面流沉浸（隐藏/恢复 tab 栏），返回键可恢复
                        onLongPress: () {
                          if (MediaQuery.orientationOf(context) ==
                              Orientation.landscape) {
                            kCoverFlowImmersive.value =
                                !kCoverFlowImmersive.value;
                          }
                        },
                        child: Stack(
                          // 以视口为界裁剪：部分滑出仅切掉界外部分，而非页边界硬切
                          clipBehavior: Clip.hardEdge,
                          children: [
                            for (final i in visible) _buildCard(i, left0, top0),
                            if (_refreshing)
                              Positioned(
                                top: 12,
                                left: 0,
                                right: 0,
                                child: Center(
                                  child: SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: M3ECircularProgressIndicator(
                                        size: 20, strokeWidth: 2),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
          // 中层：竖屏底部大范围渐变（介于专辑卡片与文字之间），
          // 覆盖文字条并向上延伸到封面区，提升文字可读性；
          // IgnorePointer 保证不拦截卡片的手势/点击。
          if (isPortrait)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 160,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.0),
                        colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.95),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          // 顶层：底部歌曲信息文字（绘制在渐变之上）
          Positioned(left: 0, right: 0, bottom: 0, child: _buildSongInfoBar()),
        ],
      ),
    );
  }

  /// TV 遥控：封面流整页单焦点停点，方向键在 onKeyEvent 内消费为翻页。
  /// 移植自 TV 参考实现（旧仓库 coverflow_page.dart:342-375），按本仓
  /// 自绘轮播的 [_animateTo]/[_playFromIndex]/[kCoverFlowImmersive] 适配。
  KeyEventResult _handleTvKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final songs = widget.songs;
    if (songs.isEmpty) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      final delta = key == LogicalKeyboardKey.arrowLeft ? -1 : 1;
      final target =
          (_page.round() + delta).clamp(0, songs.length - 1).toDouble();
      _animateTo(target);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter) {
      final center = _page.round().clamp(0, songs.length - 1).toInt();
      // 与触摸路径完全一致（见卡片 onTap）：已居中 → 起播**并进入全屏播放页**；
      // 未居中 → 先把目标卡吸到中央（等价于点击侧卡）。
      // 2026-10-04 修正：原先只调 _playFromIndex、漏了 openFullPlayer，
      // 表现为「按 OK 起播了但不自动进播放页」。
      if ((_page - center).abs() < 0.35) {
        _playFromIndex(center);
        openFullPlayer(context);
      } else {
        _animateTo(center.toDouble());
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.contextMenu) {
      // 遥控菜单键 ↔ 触屏长按等效：切换沉浸模式（返回键可恢复）
      kCoverFlowImmersive.value = !kCoverFlowImmersive.value;
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 点击中央卡起播，并按源给播放队列挂上续播器：
  /// - 私人FM 各档：[PersonalFmWidgetActions.armRefill]（FmRefill，与 FM 页 /
  ///   桌面小部件同一条链路，含杀后台后恢复续播器的会话标记）；
  /// - 刷歌推荐：[HomeDiscoverRefill.arm]（与发现页同一条链路）；
  /// - 每日推荐：固定日列表无翻页接口，不挂。
  ///
  /// 顺序照抄发现页 `_play`（discover_page.dart）的三条铁律：**先起播再 arm**
  /// （arm 靠识别当前曲目归属决定留场，队列在 playOnlinePlaylist 里落地）、
  /// **立即补一批**（PlayerProvider 一次只灌当前一首，不补播到队尾就停）、
  /// **播放源取权威快照**（此处 widget.songs 即 provider 列表本身，不另存副本）。
  /// 队列的提前补货 / 播完补货 / 停摆自愈随后全由续播器接管——封面流自己的
  /// _maybeLoadMore 只负责展示列表，两者互不干扰。
  void _playFromIndex(int index) {
    final kugou = context.read<KugouProvider>();
    final player = context.read<PlayerProvider>();
    final source = kCoverFlowSource.value;
    unawaited(() async {
      await player.playOnlinePlaylist(
        widget.songs.map((e) => e.toSong()).toList(),
        index,
      );
      switch (source) {
        case CoverFlowSource.daily:
          break;
        case CoverFlowSource.fmHeart:
        case CoverFlowSource.fmExplore:
        case CoverFlowSource.fmNiche:
        case CoverFlowSource.fmRadio:
          final refill = PersonalFmWidgetActions.armRefill(
            kugou,
            player,
            source.fmStationIndex!,
          );
          unawaited(refill?.append());
        case CoverFlowSource.homeDiscover:
          final refill = HomeDiscoverRefill.arm(kugou, player);
          unawaited(refill?.append());
      }
    }());
  }

  /// 单张卡片：定位在视口中心 → 沿主轴平移 [pos] → 绕自身中心透视/旋转/缩放。
  ///
  /// 每张卡片独立订阅 [_pageNotifier]：拖动/吸附每帧只重算本卡变换
  /// （Transform/阴影均为轻量 widget），封面 widget 实例经 child 参数
  /// 复用不重建（其 Element/RenderObject 保持不变，无重绘）。
  Widget _buildCard(int index, double left0, double top0) {
    final song = widget.songs[index];
    final half = _cardWidth / 2;
    return ValueListenableBuilder<double>(
      valueListenable: _pageNotifier,
      // 封面子树静态复用：不随 page 变化重建
      child: _buildArtwork(song, _cardWidth),
      builder: (context, page, artwork) {
        final d = index - page;
        final pos = _cardPos(d);
        final distance = d.abs();
        // 两侧卡片朝中心倾斜（竖屏绕 X 轴上下、横屏绕 Y 轴左右），
        // 正号使左/上侧卡片面向右下、右/下侧卡片面向左上 → 向内堆叠；角度设上限
        final angle = (d * 0.55).clamp(-0.85, 0.85).toDouble();
        // 分级缩放（参考 coverflow_carousel）：中心 100% → 相邻 88% → 更远 72%
        final double scale;
        if (distance < 1) {
          scale = 1.0 - 0.12 * distance;
        } else if (distance < 2) {
          scale = 0.88 - 0.16 * (distance - 1);
        } else {
          scale = 0.72;
        }
        // 阴影强度：中心卡最强，远处逐层减弱
        final intensity = (1 - distance * 0.25).clamp(0.25, 1.0).toDouble();
        final isCenter = distance < 0.5;
        // 透视 + 以卡片中心为轴的旋转/缩放（先平移到中心，旋转缩放，再平移回）
        final matrix = Matrix4.identity()
          ..setEntry(3, 2, 0.0016) // 透视
          ..multiply(Matrix4.translationValues(half, half, 0))
          ..multiply(
            _isPortrait ? Matrix4.rotationX(angle) : Matrix4.rotationY(angle),
          )
          ..multiply(Matrix4.diagonal3Values(scale, scale, 1))
          ..multiply(Matrix4.translationValues(-half, -half, 0));
        return Positioned(
          left: left0,
          top: top0,
          child: Transform(
            // 主轴平移放最外层（最先作用于顶点）：整体偏移后再绕自身中心旋转缩放
            transform: Matrix4.translationValues(
              _isPortrait ? 0 : pos,
              _isPortrait ? pos : 0,
              0,
            ),
            child: Transform(
              transform: matrix,
              child: GestureDetector(
                onTap: () {
                  // 点击：中央专辑播放并进入播放器；两侧专辑自动滚动聚焦到中心
                  if (isCenter) {
                    _playFromIndex(index);
                    openFullPlayer(context);
                  } else {
                    _animateTo(index.toDouble());
                  }
                },
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black
                            .withValues(alpha: 0.22 * intensity),
                        blurRadius: 22 * intensity,
                        offset: Offset(0, 8 * intensity),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: artwork,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 底部歌曲信息条：透明度绑定滑动进度（[_pageNotifier]），
  /// 顺序过渡——上一首先完全淡出，下一首才开始淡入（非同时交叉）。
  /// 独立订阅 page 通道：拖动/吸附每帧只重建本条，不连坐页面其他部分。
  Widget _buildSongInfoBar() {
    return ValueListenableBuilder<double>(
      valueListenable: _pageNotifier,
      builder: (context, page, _) {
        final colorScheme = Theme.of(context).colorScheme;
        final textTheme = Theme.of(context).textTheme;
        final n = widget.songs.length;
        // 记录方向：page 增大 = 向右/下滑动，减小 = 向左/上滑动
        final isIncreasing = page >= _lastPageValue;
        _lastPageValue = page;
        // 进入页 = 滑动目标方向的整数页；离开页 = 另一侧
        final entering =
            (isIncreasing ? page.ceil() : page.floor()).clamp(0, n - 1).toInt();
        final leaving =
            (isIncreasing ? page.floor() : page.ceil()).clamp(0, n - 1).toInt();
        // 相对离开页的位移 d（0→1 完成一次翻页）：
        // 前一半（d<0.5）离开页淡出，后一半（d>=0.5）进入页淡入
        final d = (page - leaving).abs();
        final leavingOpacity = d < 0.5 ? (1 - d / 0.5) : 0.0;
        final enteringOpacity = d >= 0.5 ? (d - 0.5) / 0.5 : 0.0;
        return SafeArea(
          top: false,
          child: SizedBox(
            height: 64,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // 正在离开（或当前稳定）的歌曲：先淡出
                _buildSongInfoText(
                  widget.songs[leaving],
                  leavingOpacity,
                  colorScheme,
                  textTheme,
                ),
                // 正在进入的歌曲：离开页淡出完成后才淡入
                if (entering != leaving)
                  _buildSongInfoText(
                    widget.songs[entering],
                    enteringOpacity,
                    colorScheme,
                    textTheme,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSongInfoText(
    KugouSongDetail song,
    double opacity,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    return Opacity(
      opacity: opacity,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            song.songName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            song.artistName ?? '未知歌手',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 圆角封面内容（圆角与阴影/点击包装在 [_buildCard] 的 builder 内）。
  Widget _buildArtwork(KugouSongDetail song, double cardWidth) {
    final colorScheme = Theme.of(context).colorScheme;
    final artwork = song.artworkUri != null && song.artworkUri!.isNotEmpty
        ? CachedNetworkImage(
            imageUrl: song.artworkUri!,
            memCacheWidth: 750,
            memCacheHeight: 750,
            width: cardWidth,
            height: cardWidth,
            fit: BoxFit.cover,
            placeholder: (_, _) => _buildArtworkPlaceholder(cardWidth, colorScheme),
            errorWidget: (_, _, _) => _buildArtworkPlaceholder(cardWidth, colorScheme),
          )
        : _buildArtworkPlaceholder(cardWidth, colorScheme);
    return artwork;
  }

  Widget _buildArtworkPlaceholder(
    double size,
    ColorScheme colorScheme,
  ) {
    return Container(
      width: size,
      height: size,
      color: colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.music_note,
        size: size * 0.3,
        color: colorScheme.onSurfaceVariant,
      ),
    );
  }
}
