import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../core/services/dynamic_cover_service.dart';
import '../data/models/song.dart';
import '../providers/player_provider.dart';

/// 全屏播放器专辑封面上的「动态封面」叠加层。
///
/// ## 契约
/// - **只叠加，不替换**：静态封面仍由父级渲染；本层在视频就绪后 400ms 淡入覆盖。
///   未就绪 / 无动态封面 / 开关或网络不满足 / 任何失败 → 返回 `SizedBox.shrink()`，
///   父级渲染与交互（长按 Zen、下拉收起）完全不受影响。
/// - **静音 + 不抢音频焦点**：`setVolume(0)` + `VideoPlayerOptions(mixWithOthers: true)`，
///   绝不打断 just_audio 的音乐播放（USB 独占路径同样不受影响）。
/// - **字节来源二选一**：
///   - 私有构建：命中本地缓存 → `VideoPlayerController.file`（零网络）；
///     未命中 → `networkUrl`（回环代理，边下边播）并通知私有层后台落盘。
///   - 公开构建：始终 `networkUrl`（回环代理，每次流式、不落盘）。
///   两条路径都不直连 CDN 明文域名。
/// - **自订阅播放状态**：用 `context.select` 只在本层响应 play/pause，
///   不让父级 Selector 因 isPlaying 而重建整块封面。
/// 该生命周期状态是否要求**释放**视频层。
///
/// 为什么必须释放：ExoPlayer 的渲染表面在 Activity 停止（息屏、切后台）后失效，
/// 而**暂停中的视频不会再渲染新帧** —— 解锁回前台后那块纹理依旧是黑的，会盖住
/// 下方的静态封面（表现为「黑屏、没有兜底」）。释放后本层返回空、静态封面自然
/// 可见，回前台再重建（新控制器会渲染首帧，暂停态也有画面）。
///
/// `inactive` 刻意**不**释放：下拉通知栏、弹权限框等都会进 `inactive`，但 Activity
/// 并未 stop、渲染表面仍然有效，此时释放只会造成反复重建与闪烁。
bool shouldReleaseVideoOnLifecycle(AppLifecycleState state) {
  switch (state) {
    case AppLifecycleState.resumed:
    case AppLifecycleState.inactive:
      return false;
    case AppLifecycleState.paused:
    case AppLifecycleState.hidden:
    case AppLifecycleState.detached:
      return true;
  }
}

class DynamicCoverView extends StatefulWidget {
  final Song song;

  /// 是否允许显示动态封面（由设置开关驱动）。
  ///
  /// 由 false 变 true 或反之都会触发重新解析：关闭时立即销毁播放器并清空，
  /// 打开时重新探测/加载，因此播放页「界面设置」里的开关能即时生效。
  final bool enabled;

  const DynamicCoverView({
    super.key,
    required this.song,
    this.enabled = true,
  });

  /// —— 私有接线层扩展点（公开构建恒为 null）——
  ///
  /// 命中本地缓存返回绝对文件路径；未命中返回 null。
  static Future<String?> Function(String albumAudioId)? resolveLocalPath;

  /// 流式播放已开始（未命中缓存时调用），私有层据此后台落盘。
  /// [streamUrl] 是本地回环代理地址，私有层无需感知 CDN 细节。
  static void Function(String albumAudioId, String streamUrl)? onStreamStarted;

  /// 离开该曲（切歌 / 销毁）时调用，私有层据此取消未完成的落盘。
  static void Function(String albumAudioId)? onStreamStopped;

  @override
  State<DynamicCoverView> createState() => _DynamicCoverViewState();
}

class _DynamicCoverViewState extends State<DynamicCoverView>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
  );

  VideoPlayerController? _controller;
  bool _ready = false;

  /// 已通知上层的 albumAudioId（用于切歌/销毁时回调 onStreamStopped）
  String? _notifiedId;

  /// 异步竞态守卫：切歌后旧请求的返回值必须丢弃
  int _loadVersion = 0;

  /// 是否有解析正在进行（避免 resumed 与 song 变化叠加触发重复初始化）
  bool _resolving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resolve();
  }

  /// 息屏 / 切后台 / 回前台。
  ///
  /// 非 resumed（真正的后台）时释放视频层，回前台重新解析：详见
  /// [shouldReleaseVideoOnLifecycle] 的说明（暂停态解锁黑屏的根因）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (shouldReleaseVideoOnLifecycle(state)) {
      // ignore: discarded_futures
      _suspendVideo();
    } else if (state == AppLifecycleState.resumed) {
      _resolve();
    }
  }

  /// 释放视频层并恢复静态封面兜底（不清 `_notifiedId`：后台下载继续跑，
  /// 回前台若已落盘会直接命中本地文件、瞬间可见）。
  Future<void> _suspendVideo() async {
    _loadVersion++; // 作废在途解析
    if (_ready && mounted) setState(() => _ready = false);
    _fade.value = 0;
    await _disposeController();
  }

  @override
  void didUpdateWidget(DynamicCoverView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.id != widget.song.id ||
        oldWidget.song.albumAudioId != widget.song.albumAudioId ||
        oldWidget.enabled != widget.enabled) {
      _resolve();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _loadVersion++;
    _notifyStopped();
    _fade.dispose();
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }

  void _notifyStopped() {
    final id = _notifiedId;
    _notifiedId = null;
    if (id != null && id.isNotEmpty) {
      try {
        DynamicCoverView.onStreamStopped?.call(id);
      } catch (_) {}
    }
  }

  /// 解析入口（带并发去重）：切歌 / 开关变化 / 回前台都走这里。
  Future<void> _resolve() async {
    if (_resolving) return;
    _resolving = true;
    try {
      await _resolveNow();
    } finally {
      _resolving = false;
    }
  }

  Future<void> _resolveNow() async {
    final version = ++_loadVersion;
    _notifyStopped();
    if (_ready) setState(() => _ready = false);
    _fade.value = 0;
    await _disposeController();
    if (!mounted || version != _loadVersion) return;

    final song = widget.song;
    final albumAudioId = song.albumAudioId ?? '';
    if (!song.isOnline || albumAudioId.isEmpty) return;
    // 开关关闭：不读缓存、不探针、不起播放器（父级已销毁旧实例）
    if (!widget.enabled) return;

    // 1) 私有构建：命中本地缓存 → 播本地文件（零网络，跳过元数据预检）
    try {
      final localPath = await DynamicCoverView.resolveLocalPath?.call(
        albumAudioId,
      );
      if (!mounted || version != _loadVersion) return;
      if (localPath != null && localPath.isNotEmpty) {
        if (await _initFromFile(localPath, version)) {
          if (!mounted || version != _loadVersion) return;
          setState(() => _ready = true);
          _fade.forward();
        }
        return;
      }
    } catch (_) {
      // 私有缓存层异常不得影响播放，继续走流式分支
    }

    // 2) 门控 + 元数据预检：无动态封面则永不请求视频字节
    final service = DynamicCoverService.instance;
    if (!await service.shouldLoad(song)) return;
    if (!mounted || version != _loadVersion) return;
    if (!await service.hasDynamicCover(albumAudioId)) return;
    if (!mounted || version != _loadVersion) return;

    // 3) 流式播放（边下边播）+ 通知私有层后台落盘
    final streamUrl = service.streamUrlFor(albumAudioId);
    if (await _initFromNetwork(streamUrl, version)) {
      if (!mounted || version != _loadVersion) return;
      _notifiedId = albumAudioId;
      try {
        DynamicCoverView.onStreamStarted?.call(albumAudioId, streamUrl);
      } catch (_) {}
      setState(() => _ready = true);
      _fade.forward();
    }
  }

  Future<bool> _initFromFile(String path, int version) {
    return _init(
      () => VideoPlayerController.file(
        File(path),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      ),
      version,
    );
  }

  Future<bool> _initFromNetwork(String url, int version) {
    return _init(
      () => VideoPlayerController.networkUrl(
        Uri.parse(url),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      ),
      version,
    );
  }

  Future<bool> _init(VideoPlayerController Function() create, int version) async {
    try {
      final controller = create();
      await controller.initialize();
      // 静音：动态封面只做视觉，绝不出声、不申请音频焦点
      await controller.setVolume(0);
      await controller.setLooping(true);
      if (!mounted || version != _loadVersion) {
        await controller.dispose();
        return false;
      }
      _controller = controller;
      controller.addListener(_onControllerChanged);
      _syncPlayback();
      return true;
    } catch (e) {
      debugPrint('[DynamicCover] init failed: $e');
      return false;
    }
  }

  Future<void> _disposeController() async {
    final c = _controller;
    _controller = null;
    if (c != null) {
      c.removeListener(_onControllerChanged);
      try {
        await c.dispose();
      } catch (_) {}
    }
  }

  /// 视频层兜底：控制器一旦报错（解码器被抢占、数据损坏、表面彻底失效等），
  /// 立刻撤下本层露出静态封面 —— 不能把错误状态继续渲染成一块黑屏。
  void _onControllerChanged() {
    final c = _controller;
    if (c == null) return;
    if (c.value.hasError && _ready && mounted) {
      debugPrint('[DynamicCover] controller error: ${c.value.errorDescription}');
      // ignore: discarded_futures
      _suspendVideo();
    }
  }

  void _syncPlayback() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    try {
      if (context.read<PlayerProvider>().isPlaying) {
        if (!c.value.isPlaying) c.play();
      } else {
        if (c.value.isPlaying) c.pause();
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    // 只在本层响应播放/暂停，缩小重建范围
    final isPlaying = context.select<PlayerProvider, bool>((p) => p.isPlaying);
    final c = _controller;
    // 出错（表面失效/解码器被抢占）时绝不渲染，直接露出下方静态封面
    if (!_ready || c == null || !c.value.isInitialized || c.value.hasError) {
      return const SizedBox.shrink();
    }
    if (c.value.isPlaying != isPlaying) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncPlayback();
      });
    }
    return IgnorePointer(
      child: FadeTransition(
        opacity: _fade,
        child: SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: c.value.size.width,
              height: c.value.size.height,
              child: VideoPlayer(c),
            ),
          ),
        ),
      ),
    );
  }
}
