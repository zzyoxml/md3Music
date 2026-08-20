import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../core/services/pip_service.dart';
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

  @override
  void initState() {
    super.initState();
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
    _loadingMore = true;
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
      _loadingMore = false;
    }
  }

  /// 打开投屏设备选择。
  void _openCast() {
    final url = _currentVideoUrl;
    if (url == null || url.isEmpty) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
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

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    return Scaffold(
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
            ),
          ),
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
        ],
      ),
    );
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

  const _VerticalVideoPage({
    super.key,
    required this.card,
    required this.active,
    this.fullScreen = false,
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

  @override
  void initState() {
    super.initState();
    _inPip = PipService.instance.isPipMode.value;
    PipService.instance.isPipMode.addListener(_onPipChanged);
    _init();
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
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showControls = false);
    });
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
          child: GestureDetector(
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
          ),
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
                        child: SliderTheme(
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