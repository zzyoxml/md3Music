import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:m3e_core/m3e_core.dart';

import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../player/full_player_route.dart';
import '../../widgets/scroll_aware_app_bar.dart';

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

/// 封面流 Tab 页：以 CoverFlow 3D 封面流展示每日推荐。
///
/// 数据复用 [KugouProvider.recommendSongs]（与发现页「每日推荐」同一数据源），
/// 不新增 API。横竖屏自适应：竖屏单卡约占屏宽 62%，横屏约 34%。
class CoverFlowPage extends StatefulWidget {
  const CoverFlowPage({super.key});

  @override
  State<CoverFlowPage> createState() => _CoverFlowPageState();
}

class _CoverFlowPageState extends State<CoverFlowPage> {
  /// 当前居中的歌曲下标（横竖屏切换重建封面流时保留位置）。
  /// 初始值取模块级 [kCoverFlowIndex]，重建后继续上次的位置。
  int _currentIndex = kCoverFlowIndex;

  @override
  void initState() {
    super.initState();
    // provider 内 5 分钟 TTL，重复进入自动复用缓存；跨天失效自动重拉
    context.read<KugouProvider>().getRecommendDaily();
  }

  Future<void> _refresh() async {
    await context.read<KugouProvider>().getRecommendDaily(forceRefresh: true);
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    return Scaffold(
      // 横屏沉浸模式：隐藏顶栏
      appBar: isLandscape
          ? null
          : ScrollAwareAppBar(title: '封面流', opaque: true),
      body: Consumer<KugouProvider>(
        builder: (context, kugou, _) {
          final songs = kugou.recommendSongs;
          if (songs.isEmpty && kugou.isLoading) {
            return const Center(child: M3ELoadingIndicator());
          }
          if (songs.isEmpty) {
            return _buildEmpty();
          }
          return Column(
            children: [
              Expanded(
                child: _CoverFlowView(
                  songs: songs,
                  initialIndex: _currentIndex,
                  onPageChanged: (index) {
                    // 同步回模块级变量，供横竖屏切换重建页面时恢复位置
                    kCoverFlowIndex = index;
                    setState(() => _currentIndex = index);
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

  Widget _buildEmpty() {
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
            '暂无每日推荐',
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
    required this.songs,
    required this.initialIndex,
    required this.onPageChanged,
    required this.onRefresh,
  });

  @override
  State<_CoverFlowView> createState() => _CoverFlowViewState();
}

class _CoverFlowViewState extends State<_CoverFlowView>
    with SingleTickerProviderStateMixin {
  /// 当前滚动位置（页索引，double；整数部分 = 居中的歌曲下标）。
  late double _page = widget.initialIndex.toDouble();
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
      _page = _snapAnim!.value;
      _reportPage();
      if (mounted) setState(() {});
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
    setState(() => _page = clamped);
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
    return Stack(
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
                // 视口内可见卡片：中心偏移 + 卡片半径与视口相交才绘制
                // （完全移出视口才消失，滑出部分由 Stack 按视口边界裁剪）
                final visible = <int>[];
                for (var i = 0; i < n; i++) {
                  if (_cardPos(i - _page).abs() > halfMain + halfCard) {
                    continue;
                  }
                  visible.add(i);
                }
                // z 顺序：按「离中心距离」降序绘制——远处先画（在下层）、
                // 中央最后画（最上层），保证当前专辑不被左右两侧卡片遮挡
                // （横屏时两侧卡片绕 Y 轴旋转，会与中央区域视觉重叠）。
                visible.sort((a, b) {
                  final da = (a - _page).abs();
                  final db = (b - _page).abs();
                  return db.compareTo(da);
                });
                // 卡片定位：交叉轴居中、主轴中心对齐视口中心。
                // 注意横屏时主轴=宽、交叉轴=高，left/top 需按方向取对应轴。
                final left0 = (_isPortrait ? _crossAxis : _mainAxis) / 2 -
                    halfCard;
                final top0 = (_isPortrait ? _mainAxis : _crossAxis) / 2 -
                    halfCard;
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
                      kCoverFlowImmersive.value = !kCoverFlowImmersive.value;
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
                              child:
                                  M3ECircularProgressIndicator(size: 20, strokeWidth: 2),
                            ),
                          ),
                        ),
                    ],
                  ),
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
    );
  }

  /// 单张卡片：定位在视口中心 → 沿主轴平移 [pos] → 绕自身中心透视/旋转/缩放。
  Widget _buildCard(int index, double left0, double top0) {
    final song = widget.songs[index];
    final d = index - _page;
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
    final half = _cardWidth / 2;
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
          child: _buildCoverUnit(
            song,
            _cardWidth,
            intensity,
            onTap: () {
              // 点击：中央专辑播放并进入播放器；两侧专辑自动滚动聚焦到中心
              if (isCenter) {
                context.read<PlayerProvider>().playOnlinePlaylist(
                      widget.songs.map((e) => e.toSong()).toList(),
                      index,
                    );
                Navigator.of(context).push(fullPlayerRoute(context));
              } else {
                _animateTo(index.toDouble());
              }
            },
          ),
        ),
      ),
    );
  }

  /// 底部歌曲信息条：透明度绑定滑动进度（[_page]），
  /// 顺序过渡——上一首先完全淡出，下一首才开始淡入（非同时交叉）。
  /// 竖屏渐变底由外层 Stack 统一绘制（见 build）。
  Widget _buildSongInfoBar() {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final n = widget.songs.length;
    final page = _page;
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

  /// 圆角封面（圆角与播放器内封面一致为 16），整体随 3D 变换旋转联动。
  /// [intensity] 阴影强度（中心卡最强，远处逐层减弱）；[onTap] 点击回调
  /// （中央专辑播放+进入播放器，两侧专辑自动聚焦居中）。
  Widget _buildCoverUnit(
    KugouSongDetail song,
    double cardWidth,
    double intensity, {
    required VoidCallback onTap,
  }) {
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

    return GestureDetector(
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.22 * intensity),
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
    );
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
