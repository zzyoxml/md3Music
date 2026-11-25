import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dpad/dpad.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../core/build_flags.dart';
import '../../core/remote/remote_slider.dart';
import '../../core/remote/tv_media_key_shortcuts.dart';
import '../../core/remote/tv_menu_key_shortcuts.dart';
import '../../core/remote/tv_seek_math.dart';
import '../../core/services/pip_service.dart';
import '../../core/utils/app_toast.dart';
import '../player/dlna_cast_sheet.dart';
import 'brush_page.dart';

/// 竖屏视频流（抖音式）：全屏竖屏滑动播放刷刷 feed 的视频。
///
/// 上下滑动切换视频，当前页自动播放，切走自动暂停；滑到末尾自动加载更多。
/// 横竖屏切换时（configChanges 已声明，State 保留）：
/// - 竖屏：PageView 竖滑，当前视频 cover 填满；
/// - 横屏：当前视频**全屏 contain**（不裁切画面），隐藏顶栏，进入沉浸式全屏。
class BrushVerticalPage extends StatefulWidget {
  final List<BrushCard> cards;

  /// 滑到末尾时加载更多卡片的回调（由 BrushPage 提供，内部推进 page 游标）。
  final Future<List<BrushCard>> Function()? fetchMore;

  const BrushVerticalPage({super.key, required this.cards, this.fetchMore});

  @override
  State<BrushVerticalPage> createState() => _BrushVerticalPageState();
}

class _BrushVerticalPageState extends State<BrushVerticalPage> {
  late List<BrushCard> _cards;
  int _currentIndex = 0;
  bool _loadingMore = false;
  final PageController _pageController = PageController();

  /// 当前播放视频的 URL 与标题，用于投屏。
  String? _currentVideoUrl;
  String _currentTitle = '';

  // ─── tv: 遥控状态（仅 kTvBuild 使用，非 TV 构建不分配） ───

  /// 当前活动格的播放器与焦点节点：本路的视频**不走 PlayerProvider**
  /// （每格一个 VideoPlayerController），所以 app.dart 的根部媒体键兜底
  /// 帮不上，必须由本页接管媒体键。
  VideoPlayerController? _tvActiveController;
  FocusNode? _tvActiveTileNode;

  /// 遥控顶栏（返回 / 投屏）可见性。TV 恒横屏，原顶栏的
  /// `!isLandscape && !_inPip` 条件永远不成立，改由菜单键唤出
  /// （与 MV 页全屏按钮组 `_tvButtonsVisible` 同一套闭合语义）。
  bool _tvChromeVisible = false;
  FocusNode? _tvBackNode;
  FocusNode? _tvCastNode;

  @override
  void initState() {
    super.initState();
    if (kTvBuild) {
      _tvBackNode = FocusNode(debugLabel: 'brush-tv-back');
      _tvCastNode = FocusNode(debugLabel: 'brush-tv-cast');
    }
    _cards = List.of(widget.cards);
    _syncCurrent(_currentIndex);
    // 重置自动进入标记：本页只允许通过菜单按钮手动进入画中画，
    // 退出 app（按 Home）时不得自动进入画中画。
    PipService.instance.setVideoActive(false);
    // 监听画中画：进入后只显示视频本身
    PipService.instance.isPipMode.addListener(_onPipModeChanged);
  }

  /// MediaQuery 方向变化会触发 didChangeDependencies：横屏进沉浸式全屏，退出竖屏恢复。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    if (isLandscape) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  @override
  void dispose() {
    // 恢复系统 UI（避免影响其他页面）
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // 关闭自动进入标记，避免残留影响其他页面
    PipService.instance.setVideoActive(false);
    PipService.instance.isPipMode.removeListener(_onPipModeChanged);
    _pageController.dispose();
    _tvBackNode?.dispose();
    _tvCastNode?.dispose();
    super.dispose();
  }

  void _onPipModeChanged() {
    if (mounted) setState(() {});
  }

  bool get _inPip => PipService.instance.isPipMode.value;

  void _syncCurrent(int index) {
    if (index < 0 || index >= _cards.length) return;
    _currentVideoUrl = _cards[index].videoUrl;
    _currentTitle = _cards[index].title;
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentIndex = index;
      _syncCurrent(index);
    });
    // 接近末尾时预加载更多
    if (widget.fetchMore != null &&
        index >= _cards.length - 2 &&
        !_loadingMore) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final more = await widget.fetchMore!();
      if (!mounted) return;
      setState(() {
        final seen = _cards.map((c) => c.title).toSet();
        for (final c in more) {
          if (seen.add(c.title)) _cards.add(c);
        }
      });
    } catch (_) {
      // 加载更多失败静默忽略，下次滑动再试
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// 打开投屏设备选择。
  void _openCast() {
    final url = _currentVideoUrl;
    if (url == null || url.isEmpty) return;
    showM3EModalBottomSheet(
      context: context,
      isScrollControlled: true,
      // 实色背景：与播放页投屏弹层保持一致（全局 M3E 主题默认 0.97 alpha
      // 会让歌词/画面透出，压在内容上不易辨认）。
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      builder: (_) => DlnaCastSheet(mvUrl: url, mvTitle: _currentTitle),
    );
  }

  /// 进入画中画（仅手动按钮触发）。
  void _enterPip() {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    // active 恒为 false：只设置宽高比（覆盖可能被 MV 页横屏污染的值），
    // 但退出 app（按 Home）不会自动进入画中画。
    PipService.instance
        .setVideoActive(false, aspectRatio: isLandscape ? 16 / 9 : 9 / 16);
    PipService.instance.enterPip();
  }

  // ---------------------------------------------------------------------
  // tv: 遥控键位（仅 kTvBuild 生效）
  // ---------------------------------------------------------------------

  /// tv: 活动格登记：controller 为 null 表示「注销」（只在格子销毁时发生）。
  /// 注销要比对节点身份——切页时新格先登记、旧格后销毁，无条件清空会把
  /// 刚登记的可用控制器抹掉。
  void _tvOnTileActive(VideoPlayerController? controller, FocusNode? node) {
    if (controller == null) {
      if (identical(_tvActiveTileNode, node)) {
        _tvActiveController = null;
        _tvActiveTileNode = null;
      }
      return;
    }
    _tvActiveController = controller;
    _tvActiveTileNode = node;
  }

  /// tv: OK / 媒体播放暂停键 = 当前视频播放或暂停。
  void _tvTogglePlay() {
    final c = _tvActiveController;
    if (c == null || !c.value.isInitialized) {
      debugPrint('[BrushTvKey] toggle 忽略（控制器未就绪）');
      return;
    }
    debugPrint('[BrushTvKey] toggle isPlaying=${c.value.isPlaying}');
    if (c.value.isPlaying) {
      c.pause();
    } else {
      c.play();
    }
  }

  /// tv: 上下键切视频。首页 clamp 到 0；到底时先尝试加载更多，
  /// 无可加载再给反馈（不静默吞键）。
  void _tvPageDelta(int delta) {
    final target = tvPageTarget(_currentIndex, _cards.length, delta);
    debugPrint('[BrushTvKey] page $delta → $target/${_cards.length}');
    if (target == _currentIndex) {
      if (delta > 0 && widget.fetchMore != null && !_loadingMore) {
        // ignore: discarded_futures
        _loadMore();
        return;
      }
      if (delta > 0) showToast('没有更多视频了');
      return;
    }
    // ignore: discarded_futures
    _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  /// tv: 菜单键唤出/收起顶栏（返回 / 投屏），并把焦点移过去或移回视频面。
  /// 顶栏可见性必须闭合：焦点离开后不能残留一组可点按钮（同 MV 页）。
  void _tvOnMenuKey() {
    if (_inPip) return;
    final next = !_tvChromeVisible;
    debugPrint('[BrushTvKey] menu → 顶栏${next ? '唤出' : '收起'}');
    setState(() => _tvChromeVisible = next);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (next) {
        _tvCastNode?.requestFocus();
      } else {
        _tvActiveTileNode?.requestFocus();
      }
    });
  }

  /// tv: 焦点逸出顶栏两个按钮时收起顶栏并把焦点交还视频面。
  void _tvOnChromeFocusChange(bool focused) {
    if (focused || !_tvChromeVisible) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_tvChromeVisible) return;
      final primary = FocusManager.instance.primaryFocus;
      if (primary == _tvBackNode || primary == _tvCastNode) return;
      setState(() => _tvChromeVisible = false);
      _tvActiveTileNode?.requestFocus();
    });
  }

  /// tv: 顶栏按钮 = 一个停点（Material 按钮只作视觉，子级焦点被排除）。
  Widget _tvChromeButton({
    required String debugLabel,
    required FocusNode? focusNode,
    required VoidCallback onSelect,
    required Widget child,
  }) {
    if (!kTvBuild) return child;
    return DpadFocusable(
      debugLabel: debugLabel,
      focusNode: focusNode,
      onSelect: onSelect,
      onFocusChange: _tvOnChromeFocusChange,
      child: child,
    );
  }

  /// tv: 遥控顶栏（返回 / 投屏）。非 TV 构建永不渲染。
  /// 刻意不含「画中画」：那是手机窗口能力，TV 包按 AGENTS §0.5 不编入，
  /// 留在顶栏里也只会多出一个点不动的死停点。
  Widget _tvChrome() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              _tvChromeButton(
                debugLabel: 'brush-tv-back',
                focusNode: _tvBackNode,
                onSelect: () => Navigator.of(context).maybePop(),
                child: IconButton(
                  // 与 MV 页 `_tvOverlayButton` 同口径：按钮保持 enabled
                  // （onPressed:null 会画成禁用灰），动作同时接在 onSelect 上。
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  tooltip: '返回',
                ),
              ),
              const Spacer(),
              _tvChromeButton(
                debugLabel: 'brush-tv-cast',
                focusNode: _tvCastNode,
                onSelect: _openCast,
                child: IconButton(
                  onPressed: _openCast,
                  icon: const Icon(Icons.cast, color: Colors.white),
                  tooltip: '投屏',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// tv: 页级媒体键 + 菜单键。放在最外层，保证焦点落在页面任何位置都收得到。
  Widget _tvWrapRemote(Widget body) {
    if (!kTvBuild) return body;
    return TvMediaKeyShortcuts(
      onPlayPause: _tvTogglePlay,
      onPlay: _tvTogglePlay,
      onPause: _tvTogglePlay,
      onNext: () => _tvPageDelta(1),
      onPrevious: () => _tvPageDelta(-1),
      child: TvMenuKeyShortcuts(onMenu: _tvOnMenuKey, child: body),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final scaffold = Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          PageView.builder(
            controller: _pageController,
            scrollDirection: Axis.vertical,
            itemCount: _cards.length,
            onPageChanged: _onPageChanged,
            itemBuilder: (context, i) => _VerticalVideoPage(
              // 用稳定 key 保证横竖屏切换时 State 保留，播放进度不重置
              key: ValueKey(_cards[i].title),
              card: _cards[i],
              active: i == _currentIndex,
              fullScreen: isLandscape && i == _currentIndex,
              // tv: 活动格把它的播放器与焦点节点登记上来，媒体键据此操作
              onActiveReport: kTvBuild ? _tvOnTileActive : null,
              // tv: 上下键 = 上一个 / 下一个视频
              onPageDelta: kTvBuild ? _tvPageDelta : null,
            ),
          ),
          // tv: 菜单键唤出的可聚焦顶栏（TV 恒横屏，走不到下面那条竖屏顶栏分支）
          if (kTvBuild && _tvChromeVisible) _tvChrome(),
          // 顶栏：竖屏或画中画时不显示（横屏全屏/画中画只保留视频本身）
          if (!isLandscape && !_inPip)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        tooltip: '返回',
                      ),
                      const Spacer(),
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert, color: Colors.white),
                        tooltip: '更多',
                        onSelected: (v) {
                          if (v == 'cast') _openCast();
                          if (v == 'pip') _enterPip();
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                            value: 'cast',
                            child: _MenuRow(
                              icon: Icons.cast,
                              label: '投屏',
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'pip',
                            child: _MenuRow(
                              icon: Icons.picture_in_picture_alt,
                              label: '画中画',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          // 上划加载更多指示器：与下拉刷新同款 M3E contained 指示器。
          // 黑底视频上用半透明白容器 + 白色指示色保证可见；
          // 画中画只保留视频本身，横屏全屏与竖屏都要显示（滑动加载在两种方向都存在）。
          if (_loadingMore && !_inPip)
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.paddingOf(context).bottom + 24,
              child: const Center(
                child: IgnorePointer(
                  child: M3EContainedLoadingIndicator(
                    width: 48,
                    height: 48,
                    containerColor: Colors.white24,
                    indicatorColor: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    // tv: 页级遥控键层（媒体键 + 菜单键）。非 TV 构建原样返回。
    return _tvWrapRemote(scaffold);
  }
}

/// 菜单项：图标 + 文字。
class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MenuRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface;
    return Row(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 12),
        Text(label),
      ],
    );
  }
}

/// 单条竖屏视频页：播放 / 暂停由 [active] 控制。
class _VerticalVideoPage extends StatefulWidget {
  final BrushCard card;
  final bool active;

  /// 横屏全屏时 true：视频 contain 完整显示（不裁切），隐藏底部信息。
  final bool fullScreen;

  /// tv: 本格成为/失去活动格时向页面登记自己的播放器与焦点节点
  /// （controller 传 null 表示注销）。媒体键要操作的是**当前这一格**的
  /// 视频，而每格各有一个 VideoPlayerController，页面自己拿不到。
  final void Function(VideoPlayerController? controller, FocusNode? node)?
      onActiveReport;

  /// tv: 上下键的切页动作（±1），由页面（PageController 的持有者）实现。
  final ValueChanged<int>? onPageDelta;

  const _VerticalVideoPage({
    super.key,
    required this.card,
    required this.active,
    this.fullScreen = false,
    this.onActiveReport,
    this.onPageDelta,
  });

  @override
  State<_VerticalVideoPage> createState() => _VerticalVideoPageState();
}

class _VerticalVideoPageState extends State<_VerticalVideoPage> {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _showControls = false;
  Timer? _hideTimer;

  /// 当前是否处于画中画：进入后只显示视频本身，隐藏其他 UI。
  bool _inPip = false;

  /// tv: 本格的焦点节点（视频面作为唯一停点）。仅 TV 构建分配。
  FocusNode? _tvFocus;

  @override
  void initState() {
    super.initState();
    _inPip = PipService.instance.isPipMode.value;
    PipService.instance.isPipMode.addListener(_onPipChanged);
    _init();
    if (kTvBuild) {
      _tvFocus = FocusNode(debugLabel: 'brush-tv-tile');
      // 首帧就是活动格（进页第一屏）：登记自己，autofocus 由 _tvWrapSurface 承担。
      if (widget.active) _tvReportActive();
    }
  }

  /// tv: 把本格登记为「当前活动格」。controller 尚未创建（无 videoUrl 的卡片）
  /// 时不登记，页面侧读到 null 会让媒体键安静穿透而不是报错。
  void _tvReportActive() {
    widget.onActiveReport?.call(_controller, _tvFocus);
  }

  void _onPipChanged() {
    final v = PipService.instance.isPipMode.value;
    if (v != _inPip && mounted) {
      setState(() => _inPip = v);
    }
    _inPip = v;
  }

  Future<void> _init() async {
    final url = widget.card.videoUrl;
    if (url == null || url.isEmpty) return;
    final c = VideoPlayerController.networkUrl(Uri.parse(url));
    _controller = c;
    c.setLooping(true);
    try {
      await c.initialize();
      if (!mounted) return;
      setState(() => _initialized = true);
      if (widget.active) c.play();
    } catch (_) {
      // 视频加载失败：保持占位封面
    }
  }

  @override
  void didUpdateWidget(covariant _VerticalVideoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active == widget.active) return;
    // tv: 成为活动格时先登记自己并把焦点交还本格的视频面——上下键切页后
    // 焦点不能悬空（刻意不依赖异步数据到达来抢焦，这里由 active 翻转驱动）。
    if (kTvBuild && widget.active) {
      _tvReportActive();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _tvFocus?.requestFocus();
      });
    }
    final c = _controller;
    if (c == null || !_initialized) return;
    if (widget.active) {
      c.play();
    } else {
      c.pause();
      if (mounted) setState(() => _showControls = false);
      _hideTimer?.cancel();
    }
  }

  @override
  void dispose() {
    PipService.instance.isPipMode.removeListener(_onPipChanged);
    _hideTimer?.cancel();
    // tv: 注销登记（页面按节点身份比对，不会抹掉新活动格刚登记的值），
    // 必须在 dispose 控制器之前做，否则媒体键可能操作到已销毁的播放器。
    widget.onActiveReport?.call(null, _tvFocus);
    _tvFocus?.dispose();
    _controller?.dispose();
    super.dispose();
  }

  /// 点击视频：切换播放/暂停，并显示控制条（3 秒后自动隐藏）。
  void _onTapVideo() {
    if (!_initialized || _controller == null || _inPip) return;
    final c = _controller!;
    if (c.value.isPlaying) {
      c.pause();
    } else {
      c.play();
    }
    setState(() => _showControls = true);
    _scheduleHide();
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null || !_initialized || _inPip) return;
    if (c.value.isPlaying) {
      c.pause();
    } else {
      c.play();
    }
    setState(() {});
    _scheduleHide();
  }

  void _seekTo(double seconds) {
    final c = _controller;
    if (c == null || !_initialized || _inPip) return;
    c.seekTo(Duration(seconds: seconds.round()));
    _scheduleHide();
  }

  void _scheduleHide() {
    // tv: 控制条不自动隐藏——遥控下它是「按 OK 后给用户的反馈」，
    // 3 秒后消失会让进度条连同 RemoteSlider 一起下线。
    if (kTvBuild) return;
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  // ---------------------------------------------------------------------
  // tv: 本格遥控键位（仅 kTvBuild 生效）
  // ---------------------------------------------------------------------

  /// tv: 视频面 = 本格唯一停点。OK 播放/暂停（与触屏点按同一条
  /// [_onTapVideo] 链路），左右 ±10s，上下交给页面切视频。
  Widget _tvWrapSurface(Widget surface) {
    if (!kTvBuild) return surface;
    return DpadFocusable(
      debugLabel: 'brush-tv-video-surface',
      focusNode: _tvFocus,
      autofocus: widget.active,
      onSelect: _onTapVideo,
      onDirection: _tvDirection,
      child: surface,
    );
  }

  /// tv: 四个方向键全部由视频面消费（返回 true）——竖屏流里上下就是切视频，
  /// 顶栏改由遥控菜单键唤出（与 MV 页全屏按钮组同一口径）。
  bool _tvDirection(TraversalDirection direction) {
    switch (direction) {
      case TraversalDirection.left:
        _tvSeekBy(-10);
        return true;
      case TraversalDirection.right:
        _tvSeekBy(10);
        return true;
      case TraversalDirection.up:
        debugPrint('[BrushTvKey] tile 上 → 上一个');
        widget.onPageDelta?.call(-1);
        return true;
      case TraversalDirection.down:
        debugPrint('[BrushTvKey] tile 下 → 下一个');
        widget.onPageDelta?.call(1);
        return true;
    }
  }

  /// tv: 左右键 ±N 秒（档位与 MV 页/Chewie 中央按钮一致）。
  void _tvSeekBy(int seconds) {
    final c = _controller;
    if (c == null || !_initialized || _inPip) return;
    final value = c.value;
    final target = tvSeekTarget(value.position, value.duration, seconds);
    c.seekTo(target);
    debugPrint(
      '[BrushTvKey] seek ${seconds > 0 ? '+' : ''}$seconds → ${target.inSeconds}s',
    );
    setState(() => _showControls = true);
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    // 画中画只显示视频本身；横屏全屏显示 contain 不裁切
    final videoFit =
        (_inPip || widget.fullScreen) ? BoxFit.contain : BoxFit.cover;
    return Stack(
      fit: StackFit.expand,
      children: [
        // 视频画面，点击切换播放/暂停
        Positioned.fill(
          child: _tvWrapSurface(GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _onTapVideo,
            child: _initialized && _controller != null
                ? FittedBox(
                    fit: videoFit,
                    child: SizedBox(
                      width: _controller!.value.size.width > 0
                          ? _controller!.value.size.width
                          : 1080,
                      height: _controller!.value.size.height > 0
                          ? _controller!.value.size.height
                          : 1920,
                      child: VideoPlayer(_controller!),
                    ),
                  )
                : _buildPlaceholder(card),
          )),
        ),
        // 底部信息 + 渐变遮罩（画中画/横屏全屏时隐藏）
        if (!_inPip && !widget.fullScreen)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 40, 16, 28),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black87],
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    card.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (card.subtitle != null && card.subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      card.subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                  ],
                ],
              ),
            ),
          ),
        // 播放控制条：播放/暂停 + 可拖动进度条 + 时间（画中画时隐藏）
        if (_initialized && _controller != null && _showControls && !_inPip)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              color: Colors.black54,
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
              child: ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: _controller!,
                builder: (context, v, _) {
                  final durationMs = v.duration.inMilliseconds;
                  final posMs = v.position.inMilliseconds;
                  final max =
                      durationMs > 0 ? (durationMs / 1000).toDouble() : 0.0;
                  final value = posMs >= 0 && max > 0
                      ? (posMs / 1000).toDouble().clamp(0.0, max)
                      : 0.0;
                  return Row(
                    children: [
                      IconButton(
                        onPressed: _togglePlay,
                        icon: Icon(
                          v.isPlaying
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled,
                          color: Colors.white,
                          size: 36,
                        ),
                      ),
                      Expanded(
                        // tv: TV 构建换 RemoteSlider——原生 Slider 吞四方向键
                        //（P-C；SliderTheme 装饰参数无法透传，TV 分支走默认样式）
                        child: kTvBuild
                            ? RemoteSlider(
                                value: max > 0 ? value : 0,
                                max: max > 0 ? max : 1,
                                onChangeStart: (_) => _hideTimer?.cancel(),
                                onChanged: (v) => _seekTo(v),
                              )
                            : SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 2,
                                  thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 6,
                                  ),
                                ),
                                child: Slider(
                                  value: max > 0 ? value : 0,
                                  max: max > 0 ? max : 1,
                                  onChangeStart: (_) => _hideTimer?.cancel(),
                                  onChanged: (v) => _seekTo(v),
                                ),
                              ),
                      ),
                      Text(
                        '${_fmt(v.position)} / ${_fmt(v.duration)}',
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                      const SizedBox(width: 4),
                    ],
                  );
                },
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPlaceholder(BrushCard card) {
    Color bg = Colors.black;
    Widget inner;
    if (card.coverUrl != null && card.coverUrl!.isNotEmpty) {
      bg = Colors.black87;
      inner = CachedNetworkImage(
        imageUrl: card.coverUrl!,
        fit: BoxFit.cover,
        errorWidget: (_, _, _) => const Icon(
          Icons.music_note,
          color: Colors.white38,
          size: 64,
        ),
      );
    } else {
      inner = const Icon(Icons.music_note, color: Colors.white38, size: 64);
    }
    return Container(
      color: bg,
      alignment: Alignment.center,
      child: inner,
    );
  }
}