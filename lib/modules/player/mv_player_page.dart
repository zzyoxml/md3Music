import 'dart:async';
import 'dart:io' show Directory;

import 'package:chewie/chewie.dart';
// chewie 未公开导出 PlayerNotifier（只在内部子树提供）。页面按钮组要与进度条
// 同步显隐，必须拿到这个 notifier —— 详见 _buildControlsBridge 的注释。
// 刻意引用内部路径：公开 API 拿不到该状态，重复实现计时器会与进度条漂移。
// ignore: implementation_imports
import 'package:chewie/src/notifiers/player_notifier.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../../core/services/wakelock_service.dart';
import '../../core/utils/app_toast.dart';
import '../../core/services/pip_service.dart';
import '../../core/services/usb_audio_service.dart';
import '../../data/models/mv_models.dart';
import '../../data/models/song.dart';
import '../../data/repositories/settings_repository.dart';
import '../../providers/player_provider.dart';
import '../../providers/dlna_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../utils/landscape_immersive.dart';
import 'dlna_cast_sheet.dart';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/danmaku/danmaku_entry.dart';
import '../../core/danmaku/danmaku_render_mapping.dart';
import '../../core/danmaku/danmaku_source.dart';
import '../../core/danmaku/local_danmaku_store.dart';
import '../../core/danmaku/video_barrage_mapper.dart';
import '../../widgets/danmaku/mv_danmaku_layer.dart';
import 'widgets/mv_danmaku_input_bar.dart';

/// MV 播放页：展示歌曲 MV 视频，支持清晰度切换。
///
/// 进入时暂停背景音频播放，退出时恢复（仅当进入前正在播放）。
/// 加载链：/kmr/audio/mv(album_audio_id) → /video/detail(mvId) → /video/url(hash)。
enum _MvLoadState { loading, ready, noMv, error }

class MvPlayerPage extends StatefulWidget {
  final Song song;

  /// 直接播放地址模式：场景音乐视频等已有播放地址的场景使用。
  /// 非空时跳过 /kmr/audio/mv → /video/detail → /video/url 查询链，直接播放。
  final String? directVideoUrl;

  const MvPlayerPage({super.key, required this.song, this.directVideoUrl});

  @override
  State<MvPlayerPage> createState() => _MvPlayerPageState();
}

class _MvPlayerPageState extends State<MvPlayerPage> {
  _MvLoadState _loadState = _MvLoadState.loading;
  String _errorMessage = '';

  VideoPlayerController? _controller;
  ChewieController? _chewieController;

  MvDetail? _detail;
  List<MvQuality> _qualities = [];
  int _currentQualityIndex = 0;
  bool _isSwitching = false;

  /// 当前播放的 MV 视频 URL，用于投屏。
  String? _currentVideoUrl;

  /// 进入页面前背景音频是否正在播放，用于退出时决定是否恢复。
  bool _wasPlayingBefore = false;

  /// 标记 dispose 已执行，避免异步回调操作已释放的控制器。
  bool _disposed = false;

  /// 当前设备是否支持画中画（Android 8.0+），决定是否显示画中画按钮。
  /// 设备是否支持画中画（浮层按钮需响应式，故用 ValueNotifier）。
  final ValueNotifier<bool> _pipSupported = ValueNotifier<bool>(false);

  /// 设置开关：是否按 Home 自动进入画中画（默认关闭，手动按钮不受影响）。
  bool _autoPipEnabled = false;

  /// 当前 MV 的弹幕列表。**只在加载完成时赋值一次** ——
  /// 用户新发送的弹幕直接投给渲染器，不回写此列表，避免时间轴重建导致炸屏。
  List<DanmakuEntry> _danmakuEntries = const [];

  /// 弹幕开关（读取自设置，默认关闭）。
  /// 弹幕开关（浮层按钮需响应式，故用 ValueNotifier）。
  final ValueNotifier<bool> _danmakuEnabled = ValueNotifier<bool>(false);

  /// 弹幕总透明度（读取自设置，默认 1.0）。
  double _danmakuOpacity = 1.0;

  /// 本地弹幕仓储，用于持久化用户发送的弹幕。
  LocalDanmakuStore? _danmakuStore;

  /// 弹幕渲染器，页面直接投递「自己刚发送」的弹幕。
  DanmakuController<String>? _danmakuController;

  /// 当前视频的弹幕 key，用于本地弹幕分区（优先 videoId，回退 hash / songId）。
  String? _danmakuKey;

  /// 本地弹幕 id 自增序号：同毫秒内连续发送两条弹幕时保证 id 唯一。
  int _danmakuSeq = 0;

  /// 页面级全屏状态。
  ///
  /// 不用 Chewie 内置全屏：它把播放器 push 进独立路由，弹幕层不会跟进去，
  /// 真机表现为「全屏看不到弹幕」。自建全屏让视频与弹幕层始终同子树。
  /// 页面级全屏状态（浮层按钮需响应式，故用 ValueNotifier）。
  final ValueNotifier<bool> _isFullscreen = ValueNotifier<bool>(false);

  /// 浮层按钮组「已挂载」一次性日志标记（见 [_buildControlsBridge]）。
  bool _overlayMountedLogged = false;

  /// Chewie 控件是否已隐藏（由 [_buildControlsBridge] 从 Chewie 内部桥接出来）。
  /// 页面按钮组据此与进度条同步显隐。
  final ValueNotifier<bool> _controlsHidden = ValueNotifier<bool>(false);

  /// 弹幕远端发送在途中：用于禁用发送按钮防连点。
  bool _danmakuSending = false;

  @override
  void initState() {
    super.initState();
    // 记录并暂停背景音频
    final player = context.read<PlayerProvider>();
    _wasPlayingBefore = player.isPlaying;
    if (_wasPlayingBefore) {
      player.pause();
    }
    // 监听投屏状态：投屏 MV 时暂停本地视频，停止投屏时恢复
    final dlna = context.read<DlnaProvider>();
    dlna.addListener(_onDlnaStateChanged);
    // 监听画中画模式切换：进入后切到纯视频布局
    PipService.instance.isPipMode.addListener(_onPipModeChanged);
    PipService.instance.isSupported().then((supported) {
      if (!mounted) return;
      setState(() => _pipSupported.value = supported);
    });
    // 读取「自动画中画」开关：决定按 Home 是否自动进入（默认关闭）
    SettingsRepository().getAutoPipEnabled().then((enabled) {
      if (!mounted) return;
      setState(() => _autoPipEnabled = enabled);
      _syncPipActive();
    });
    // USB 独占开启时 MV 无系统音频：若开启「播放 MV 时自动关闭独占」则进入即关闭
    _maybeAutoDisableUsbExclusive();
    // 读取弹幕开关与透明度：默认关闭 / 1.0（与官方 App 一致）
    SettingsRepository().getMvDanmakuEnabled().then((enabled) {
      if (!mounted) return;
      setState(() => _danmakuEnabled.value = enabled);
    });
    SettingsRepository().getMvDanmakuOpacity().then((opacity) {
      if (!mounted) return;
      setState(() => _danmakuOpacity = opacity);
    });
    _loadMv();
  }

  /// 进入 MV 播放时自动关闭 USB 独占（绕过 AudioFlinger，MV 无声），并 Toast 提示。
  Future<void> _maybeAutoDisableUsbExclusive() async {
    try {
      if (!await UsbAudioService.instance.getAutoDisableForMv()) return;
      if (!await UsbAudioService.instance.isEnabled()) return;
      await UsbAudioService.instance.disableExclusive();
      if (!mounted) return;
      showToast('已自动关闭 USB 独占输出，恢复系统音频');
    } catch (_) {
      // 关闭失败不阻塞 MV 播放
    }
  }

  @override
  void dispose() {
    _disposed = true;
    // 移除投屏状态监听
    try {
      context.read<DlnaProvider>().removeListener(_onDlnaStateChanged);
    } catch (_) {}
    // 移除画中画模式监听并取消「按 Home 自动进入画中画」标记
    PipService.instance.isPipMode.removeListener(_onPipModeChanged);
    PipService.instance.setVideoActive(false);
    WakelockService.instance.setVideoPlaying(false);
    // 全屏状态下直接退出页面：必须清沉浸标志、恢复旋转与系统栏，否则会残留
    if (_isFullscreen.value) {
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      kPlayerLandscapeImmersiveActive.value = false;
      restoreSystemUi();
    }
    _danmakuEnabled.dispose();
    _isFullscreen.dispose();
    _pipSupported.dispose();
    _controlsHidden.dispose();
    _chewieController?.dispose();
    _controller?.dispose();
    // 恢复背景音频（仅当进入前正在播放）
    if (_wasPlayingBefore) {
      // context 在 dispose 时仍可读 provider（StatelessElement 已 detach 但 provider 可通过容器访问）
      // 这里用 read 安全：PlayerProvider 是全局注册的
      try {
        context.read<PlayerProvider>().resume();
      } catch (_) {
        // 容器已销毁则忽略
      }
    }
    super.dispose();
  }

  /// 投屏状态变化回调：投屏时暂停本地视频，停止投屏时恢复。
  void _onDlnaStateChanged() {
    final dlna = context.read<DlnaProvider>();
    if (!mounted || _disposed) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    if (dlna.isCasting && controller.value.isPlaying) {
      // 投屏开始 → 暂停本地视频
      controller.pause();
    } else if (!dlna.isCasting && !controller.value.isPlaying) {
      // 停止投屏 → 恢复本地视频播放
      controller.play();
    }
  }

  /// 视频控制器状态变化回调：同步播放状态到屏幕常亮服务 + 画中画自动进入标记。
  void _onVideoStateChanged() {
    WakelockService.instance.setVideoPlaying(
      _controller?.value.isPlaying ?? false,
    );
    _syncPipActive();
  }

  /// 按「自动画中画」开关与播放状态同步原生标记。
  /// 开关关闭时恒传 false，保证按 Home 不会自动进入画中画。
  void _syncPipActive() {
    final controller = _controller;
    final playing = controller?.value.isPlaying ?? false;
    final aspectRatio = controller?.value.aspectRatio;
    PipService.instance.setVideoActive(
      _autoPipEnabled && playing,
      aspectRatio: (aspectRatio != null && aspectRatio > 0) ? aspectRatio : null,
    );
  }

  /// 画中画模式切换回调：进入后切到纯视频布局，并关闭屏幕常亮（允许息屏）。
  void _onPipModeChanged() {
    if (!mounted || _disposed) return;
    final inPip = PipService.instance.isPipMode.value;
    setState(() {});
    if (inPip) {
      // 画中画时关闭屏幕常亮，避免一直亮屏；退出画中画时按播放状态恢复
      WakelockService.instance.setVideoPlaying(false);
    } else {
      WakelockService.instance.setVideoPlaying(
        _controller?.value.isPlaying ?? false,
      );
    }
  }

  /// 手动进入画中画（仅支持设备显示按钮）。
  void _enterPip() {
    PipService.instance.enterPip();
    // 手动进入与开关无关，但标记须遵循开关：关闭时退出画中画后按 Home 不会再次自动进入
    _syncPipActive();
  }

  Future<void> _loadMv() async {
    // 直接播放模式：已有播放地址（场景音乐视频等），无需 MV 查询链
    final direct = widget.directVideoUrl;
    if (direct != null && direct.isNotEmpty) {
      // 直链场景没有 mvId，用歌曲身份做 key（Song.id 非空，见 data/models/song.dart:28）。
      // 不能用 URL 做 key：酷狗视频 URL 带时效签名参数，每次请求都不同，
      // 即使 hash 稳定也永远无法跨会话命中。
      await _loadDanmaku('song:${widget.song.id}');
      await _initVideoController(direct, autoPlay: true);
      return;
    }

    final song = widget.song;
    final albumAudioId = song.albumAudioId;
    if (albumAudioId == null || albumAudioId.isEmpty) {
      if (!_disposed) setState(() => _loadState = _MvLoadState.noMv);
      return;
    }

    final api = KugouApiClient();
    // 1. 查询是否有 MV
    final mvInfo = await api.getMvByAlbumAudioId(albumAudioId);
    if (_disposed) return;
    if (mvInfo == null || !mvInfo.hasMv) {
      if (!_disposed) setState(() => _loadState = _MvLoadState.noMv);
      return;
    }

    // 2. 取 mvId 查详情（含多清晰度）
    String? mvId = mvInfo.mvId;
    String? firstHash = mvInfo.hash;
    if (mvId != null && mvId.isNotEmpty) {
      final detail = await api.getVideoDetail(mvId);
      if (_disposed) return;
      if (detail != null) {
        _detail = detail;
        _qualities = detail.qualities;
        if (_qualities.isNotEmpty) {
          // 默认选择最高画质（列表按 ld/sd/hd/qhd/fhd 从低到高）
          firstHash = _qualities.last.hash;
          _currentQualityIndex = _qualities.length - 1;
        }
      }
    }

    // 3. 用 hash 取播放地址
    if (firstHash == null || firstHash.isEmpty) {
      if (!_disposed) {
        setState(() {
          _loadState = _MvLoadState.error;
          _errorMessage = '无法获取视频信息';
        });
      }
      return;
    }
    final url = await api.getVideoUrl(firstHash);
    if (_disposed) return;
    if (url == null || url.isEmpty) {
      if (!_disposed) {
        setState(() {
          _loadState = _MvLoadState.error;
          _errorMessage = '无法获取视频播放地址';
        });
      }
      return;
    }

    // 4. 加载本地弹幕（优先用 videoId 分区，无 videoId 时回退视频 hash），
    //    再初始化视频控制器
    await _loadDanmaku(
      (mvId != null && mvId.isNotEmpty) ? 'mv:$mvId' : 'hash:$firstHash',
    );
    await _initVideoController(url, autoPlay: true);
  }

  /// 加载当前 MV 的本地弹幕。弹幕加载失败不得影响播放。
  ///
  /// [key] 必须是**内容身份**（`mv:<videoId>` / `hash:<hash>` / `song:<songId>`），
  /// 不能用播放 URL —— 酷狗视频 URL 带时效签名参数，每次请求都不同。
  Future<void> _loadDanmaku(String key) async {
    _danmakuKey = key;
    try {
      final supportDir = await getApplicationSupportDirectory();
      final store = LocalDanmakuStore(
        root: Directory('${supportDir.path}/danmaku'),
      );
      _danmakuStore = store;
      final entries = await LocalDanmakuSource(store: store, key: key).load();
      if (_disposed) return;
      setState(() => _danmakuEntries = entries);
    } catch (e) {
      debugPrint('[MvDanmaku] 加载本地弹幕失败：$e');
    }
  }

  /// 发送一条弹幕：立即投给渲染器（不等时间轴），并异步落盘。
  Future<void> _sendDanmaku(String text) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final position = controller.value.position;
    _danmakuSeq++;
    final entry = DanmakuEntry(
      time: position,
      text: text,
      colorValue: 0xFFFFFF,
      mode: DanmakuMode.scroll,
      // 毫秒时间戳在同毫秒内会重复，叠加自增序号保证唯一
      id: 'local-${DateTime.now().microsecondsSinceEpoch}-$_danmakuSeq',
      selfSend: true,
    );

    // ① 立即显示：直接投递，绕开时间轴（本次播放立即可见）。
    //    **不要调用 resume()**：暂停时发送的弹幕应冻结在原地，
    //    播放/暂停统一由 MvDanmakuLayer._onFrame 按视频状态管理。
    _danmakuController?.addDanmaku(toContentItem(entry));

    // ② 落盘：下次进入该视频时由 MvDanmakuLayer 内的 DanmakuBuckets 正常回放
    final store = _danmakuStore;
    final key = _danmakuKey;
    if (store != null && key != null) {
      try {
        await store.append(key, entry);
      } catch (e) {
        debugPrint('[MvDanmaku] 保存弹幕失败：$e');
      }
    }

    // ③ 远端：登录态下同步发布到 MV 弹幕池（失败不回滚本地）
    await _sendRemoteDanmaku(text);
  }

  /// 把弹幕同步发布到远端 MV 弹幕池。
  ///
  /// - 仅 `mv:` / `hash:` 两种 key 可发布（直链场景没有 video_id/hash）；
  /// - 未登录直接提示返回，不发请求；
  /// - **不自动重试**；在途时禁用发送按钮（`_danmakuSending`）；
  /// - 失败只提示 + 打日志，本地已上屏的弹幕保持不变。
  Future<void> _sendRemoteDanmaku(String text) async {
    if (_danmakuSending) return;

    final key = _danmakuKey;
    String? videoId;
    String? hash;
    if (key != null && key.startsWith('mv:')) {
      videoId = key.substring(3);
    } else if (key != null && key.startsWith('hash:')) {
      hash = key.substring(5);
    } else {
      // 直链场景（song:）没有 video_id/hash，仅本地可见
      return;
    }

    final api = KugouApiClient();
    if (!api.isLoggedIn) {
      if (mounted) showToast('发送弹幕需要先登录');
      return;
    }

    if (mounted) setState(() => _danmakuSending = true);
    try {
      final res = await api.sendVideoBarrage(
        content: text,
        videoId: videoId,
        hash: hash,
        name: widget.song.displayName,
      );
      // 判据未经真实发布验证：上游业务错误会以 502 + 保留 JSON 返回，
      // 因此必须看 status / err_code，而不是只看 null。
      final ok = res != null && (res['status'] == 1 || res['err_code'] == 0);
      debugPrint(
        '[MvDanmaku] 远端发送${ok ? '成功' : '失败'} '
        'status=${res?['status']} err_code=${res?['err_code'] ?? res?['error_code']}',
      );
      if (!ok && mounted) {
        showToast('弹幕发送失败（已在本地显示）', long: true);
      }
    } catch (e) {
      // 不重试：写操作重试可能重复发布
      debugPrint('[MvDanmaku] 远端发送异常：$e');
      if (mounted) showToast('弹幕发送失败（已在本地显示）', long: true);
    } finally {
      if (mounted) setState(() => _danmakuSending = false);
    }
  }

  /// 页内切换弹幕开关：即时生效 + 持久化到设置页同一开关。
  ///
  /// 官方 App 的 MV 弹幕默认关闭，若只依赖设置页入口，用户在播放页会
  /// 「找不到开启方式」（真实反馈）。因此播放页必须自带开关。
  Future<void> _toggleDanmaku() async {
    final next = !_danmakuEnabled.value;
    setState(() => _danmakuEnabled.value = next);
    try {
      await SettingsRepository().setMvDanmakuEnabled(next);
    } catch (e) {
      debugPrint('[MvDanmaku] 保存弹幕开关失败：$e');
    }
    // 首次加载时弹幕若处于关闭态，远端弹幕会被跳过；此处开启后补拉一次
    // （合并按文本去重，重复调用安全）。
    if (next) unawaited(_loadRemoteDanmaku());
  }

  /// 加载远端官方 MV 弹幕（酷狗 MV 弹幕池）。**失败一律静默**，不影响播放。
  ///
  /// 上游弹幕池底层是评论池、条目没有时间字段，因此需要视频时长来合成时间轴：
  /// 优先用 `/video/detail` 的时长，直链场景回退到视频控制器上报的时长。
  /// 弹幕开关关闭时不发请求（省流量）。
  Future<void> _loadRemoteDanmaku() async {
    final key = _danmakuKey;
    final controller = _controller;
    if (key == null || controller == null) return;

    try {
      if (!await SettingsRepository().getMvDanmakuEnabled()) return;
    } catch (_) {
      return;
    }

    // 只有 mv:（videoId）与 hash: 两种 key 能查远端；直链场景（song:）没有 video_id/hash
    String? videoId;
    String? hash;
    if (key.startsWith('mv:')) {
      videoId = key.substring(3);
    } else if (key.startsWith('hash:')) {
      hash = key.substring(5);
    } else {
      return;
    }
    if ((videoId == null || videoId.isEmpty) && (hash == null || hash.isEmpty)) return;

    final duration = _detail?.duration ?? controller.value.duration;
    if (duration <= Duration.zero) {
      debugPrint('[MvDanmaku] 远端弹幕跳过：无法确定视频时长');
      return;
    }

    List<DanmakuEntry> remote = const [];
    try {
      remote = await KugouDanmakuSource(
        idOrHash: videoId ?? hash!,
        duration: duration,
        fetch: (idOrHash, dur) async {
          final raw = await KugouApiClient().getVideoBarrage(
            videoId: videoId,
            hash: hash,
            pagesize: 100,
          );
          if (raw == null) return null;
          return mapVideoBarrage(raw, videoDuration: dur);
        },
      ).load();
    } catch (e) {
      debugPrint('[MvDanmaku] 远端弹幕获取失败：$e');
      return;
    }
    if (_disposed || remote.isEmpty) {
      debugPrint('[MvDanmaku] 远端弹幕为空（${videoId ?? hash}）');
      return;
    }

    // 合并本地 + 远端：按文本去重（同一文本保留自己发送的那条），按时间升序
    final byText = <String, DanmakuEntry>{};
    for (final entry in [...remote, ..._danmakuEntries]) {
      final existing = byText[entry.text];
      if (existing == null) {
        byText[entry.text] = entry;
      } else if (entry.selfSend && !existing.selfSend) {
        byText[entry.text] = entry;
      }
    }
    final merged = byText.values.toList()
      ..sort((a, b) => a.time.compareTo(b.time));
    debugPrint('[MvDanmaku] 远端弹幕 ${remote.length} 条，合并后 ${merged.length} 条');
    setState(() => _danmakuEntries = merged);
  }

  Future<void> _initVideoController(String url, {required bool autoPlay}) async {
    _currentVideoUrl = url;
    try {
      final controller = VideoPlayerController.networkUrl(Uri.parse(url));
      await controller.initialize();
      if (_disposed) {
        controller.dispose();
        return;
      }
      final chewieController = ChewieController(
        videoPlayerController: controller,
        autoPlay: autoPlay,
        looping: false,
        showControls: true,
        showOptions: false,
        // 关闭 Chewie 内置全屏：它会把播放器 push 进**独立路由**，
        // 而弹幕层是页面 Stack 的兄弟节点、不会跟进去 → 全屏看不到弹幕。
        // 改用页面级自建全屏（见 _buildFullscreenBody）。
        allowFullScreen: false,
        // 显隐桥接：把 Chewie 内部 hideStuff 传出给页面按钮组（见 _buildControlsBridge）
        overlay: _buildControlsBridge(),
      );
      setState(() {
        _controller = controller;
        _chewieController = chewieController;
        _loadState = _MvLoadState.ready;
      });
      controller.addListener(_onVideoStateChanged);
      _onVideoStateChanged();
      // 远端官方弹幕：控制器就绪后拉一次（失败静默，不影响播放）
      unawaited(_loadRemoteDanmaku());
    } catch (e) {
      if (_disposed) return;
      setState(() {
        _loadState = _MvLoadState.error;
        _errorMessage = '视频加载失败：$e';
      });
    }
  }

  /// 切换清晰度：保留当前播放位置，重建控制器。
  Future<void> _switchQuality(int newIndex) async {
    if (newIndex == _currentQualityIndex || _isSwitching) return;
    if (newIndex < 0 || newIndex >= _qualities.length) return;

    final newHash = _qualities[newIndex].hash;
    final oldPosition = _controller?.value.position ?? Duration.zero;
    final wasPlaying = _controller?.value.isPlaying ?? true;

    setState(() => _isSwitching = true);
    final api = KugouApiClient();
    final url = await api.getVideoUrl(newHash);
    if (_disposed) return;
    if (url == null || url.isEmpty) {
      if (mounted) {
        showToast('切换清晰度失败', long: true);
      }
      setState(() => _isSwitching = false);
      return;
    }

    // 释放旧控制器
    _controller?.removeListener(_onVideoStateChanged);
    _chewieController?.dispose();
    await _controller?.dispose();
    _chewieController = null;
    _controller = null;

    try {
      final controller = VideoPlayerController.networkUrl(Uri.parse(url));
      await controller.initialize();
      if (_disposed) {
        controller.dispose();
        return;
      }
      if (oldPosition > Duration.zero) {
        await controller.seekTo(oldPosition);
      }
      final chewieController = ChewieController(
        videoPlayerController: controller,
        autoPlay: wasPlaying,
        looping: false,
        showControls: true,
        showOptions: false,
        // 同 _initVideoController：全屏改由页面自建（弹幕层需在同一棵子树内）
        allowFullScreen: false,
        // 切清晰度会重建控制器，桥接与按钮组行为与初次加载一致
        overlay: _buildControlsBridge(),
      );
      if (_disposed) {
        controller.dispose();
        chewieController.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _chewieController = chewieController;
        _currentQualityIndex = newIndex;
        _isSwitching = false;
      });
      controller.addListener(_onVideoStateChanged);
      _onVideoStateChanged();
    } catch (e) {
      if (_disposed) return;
      setState(() => _isSwitching = false);
      if (mounted) {
        showToast('切换清晰度失败：$e', long: true);
      }
    }
  }

  void _showQualitySheet() {
    if (_qualities.isEmpty) return;
    showModalBottomSheet(
      context: context,
      // 横屏可用高度很小：默认的半屏上限装不下「标题 + 多档清晰度」，
      // Column 会报 bottom overflowed。因此放开高度限制 + 内容可滚动 + 限高。
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.8,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '清晰度',
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                ),
              ),
              const Divider(height: 1),
              ...List.generate(_qualities.length, (i) {
                final q = _qualities[i];
                final selected = i == _currentQualityIndex;
                return ListTile(
                  leading: Icon(
                    selected ? Icons.check_circle : Icons.movie_outlined,
                    color: selected
                        ? Theme.of(ctx).colorScheme.primary
                        : Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                  title: Text(q.quality),
                  subtitle: Text(q.resolutionLabel),
                  selected: selected,
                  onTap: () {
                    Navigator.pop(ctx);
                    _switchQuality(i);
                  },
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 画中画模式：只渲染纯视频（隐藏 AppBar 与其余 UI），窗口比例即视频比例
    if (PipService.instance.isPipMode.value) {
      return _buildPipBody();
    }
    // 页面级全屏：只渲染视频 + 弹幕层（弹幕在同一棵子树内，全屏可见）
    if (_isFullscreen.value) {
      // 全屏时系统返回键**先退出全屏**，而不是直接 pop 掉整个 MV 播放页
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _exitFullscreen(fromBack: true);
        },
        child: _buildFullscreenBody(),
      );
    }
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.song.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: switch (_loadState) {
        _MvLoadState.loading => _buildLoading(colorScheme),
        _MvLoadState.noMv => _buildNoMv(colorScheme, textTheme),
        _MvLoadState.error => _buildError(colorScheme, textTheme),
        _MvLoadState.ready => _buildReady(colorScheme, textTheme),
      },
    );
  }

  Widget _buildLoading(ColorScheme colorScheme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const M3ELoadingIndicator(),
          const SizedBox(height: 16),
          Text('正在加载 MV...', style: TextStyle(color: colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _buildNoMv(ColorScheme colorScheme, TextTheme textTheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.music_off_outlined, size: 64, color: colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('该歌曲暂无 MV', style: textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '没有找到这首歌的 MV 资源',
              style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError(ColorScheme colorScheme, TextTheme textTheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 64, color: colorScheme.error),
            const SizedBox(height: 16),
            Text('加载失败', style: textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              _errorMessage,
              textAlign: TextAlign.center,
              style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: _retry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  void _retry() {
    setState(() {
      _loadState = _MvLoadState.loading;
      _errorMessage = '';
      _detail = null;
      _qualities = [];
      _currentQualityIndex = 0;
    });
    _loadMv();
  }

  Widget _buildReady(ColorScheme colorScheme, TextTheme textTheme) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    final videoPlayer = _buildVideoStack();

    // 横屏：左 70% 视频 + 右 30% 清晰度&信息
    if (isLandscape) {
      return Row(
        children: [
          Expanded(flex: 7, child: videoPlayer),
          Expanded(
            flex: 3,
            child: ListView(
              children: [
                MvDanmakuInputBar(
                  enabled: _danmakuEnabled.value,
                  sending: _danmakuSending,
                  onSubmit: _sendDanmaku,
                  onEnable: _toggleDanmaku,
                ),
                _buildQualityBar(colorScheme, textTheme),
                _buildCastButton(colorScheme, textTheme),
                const Divider(height: 1),
                _buildInfoSection(colorScheme, textTheme),
              ],
            ),
          ),
        ],
      );
    }

    // 竖屏：视频(16:9) + 清晰度条 + 信息
    return ListView(
      children: [
        AspectRatio(aspectRatio: 16 / 9, child: videoPlayer),
        MvDanmakuInputBar(
          enabled: _danmakuEnabled.value,
          sending: _danmakuSending,
          onSubmit: _sendDanmaku,
          onEnable: _toggleDanmaku,
        ),
        _buildQualityBar(colorScheme, textTheme),
        _buildCastButton(colorScheme, textTheme),
        const Divider(height: 1),
        _buildInfoSection(colorScheme, textTheme),
      ],
    );
  }

  /// 视频区：Chewie（内含控件）+ 弹幕层 + 右上角按钮组。
  ///
  /// 按钮组留在**页面 Stack 的最上层**（而不是 Chewie 的 `overlay` 槽位）：
  /// Chewie 的 Stack 次序是 `video → overlay → 黑色浮层 → 控件层`，
  /// 而 `MaterialControls` 顶层是全区域 `GestureDetector(onTap:)` ——
  /// 放在 overlay 里的按钮会被控件层赢走手势，表现为「按钮点不到」。
  /// 显隐则通过 [_buildControlsBridge] 把 Chewie 内部状态桥接出来驱动。
  Widget _buildVideoStack() {
    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _chewieController != null
              ? Chewie(controller: _chewieController!)
              : const Center(child: M3ECircularProgressIndicator(color: Colors.white)),
          // 弹幕层：位于 Chewie 之上、手势透传（IgnorePointer 在层内）。
          // key 绑定 controller 实例 —— 切换清晰度会重建控制器，必须随之重建，
          // 否则 Ticker 会继续读已 dispose 的控制器。
          if (_controller != null && _chewieController != null)
            MvDanmakuLayer(
              key: ObjectKey(_controller),
              controller: _controller!,
              entries: _danmakuEntries,
              enabled: _danmakuEnabled.value,
              opacity: _danmakuOpacity,
              onControllerCreated: (c) => _danmakuController = c,
            ),
          // 右上角按钮组：弹幕开关 / 全屏 / （非全屏时）画中画
          if (_chewieController != null)
            ListenableBuilder(
              listenable: Listenable.merge([
                _danmakuEnabled,
                _isFullscreen,
                _pipSupported,
                _controlsHidden,
              ]),
              builder: (context, _) {
                if (!_overlayMountedLogged) {
                  _overlayMountedLogged = true;
                  // 一次性取证日志：确认按钮组已挂载（与控件显隐桥接联动）
                  debugPrint('[MvDanmaku] 浮层按钮组已挂载（与进度条同步显隐）');
                }
                final hidden = _controlsHidden.value;
                return Positioned(
                  top: 12,
                  right: 12,
                  child: IgnorePointer(
                    // 控件隐藏时同步放行手势，避免按钮区域挡住视频的播放/暂停点击
                    ignoring: hidden,
                    child: AnimatedOpacity(
                      opacity: hidden ? 0 : 1,
                      duration: const Duration(milliseconds: 250),
                      child: Row(
                        children: [
                          _buildDanmakuToggleButton(),
                          const SizedBox(width: 8),
                          _buildFullscreenButton(fullscreen: _isFullscreen.value),
                          // 画中画与全屏互斥，全屏时收起点
                          if (!_isFullscreen.value && _pipSupported.value) ...[
                            const SizedBox(width: 8),
                            _buildPipButton(),
                          ],
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  /// 把 Chewie 内部的控件显隐状态桥接到 [_controlsHidden]。
  ///
  /// 为什么需要桥接：显隐由 Chewie 内部的 `PlayerNotifier.hideStuff` 驱动，该
  /// provider 只在 **Chewie 子树内**提供 —— 页面读不到；而按钮又必须留在页面
  /// Stack 才能被点击（见 [_buildVideoStack]）。因此用一个零尺寸的桥接 widget
  /// 挂在 Chewie 的 `overlay` 槽位里，把状态传出。
  ///
  /// 依赖说明：`PlayerNotifier` 未被 chewie 公开导出，这里按 1.13.1 的内部路径
  /// 引用。升级 chewie 后若此 import 报错，说明上游改了内部结构 —— 届时需改为
  /// 「`customControls` + 自建计时器」方案，或等上游导出该 notifier。
  Widget _buildControlsBridge() {
    return Consumer<PlayerNotifier>(
      builder: (context, notifier, _) {
        final hidden = notifier.hideStuff;
        if (hidden != _controlsHidden.value) {
          // 必须延到帧末：build 期间直接改 ValueNotifier 会让依赖者在本帧
          // 已构建的情况下被标记重建，触发 markNeedsBuild during build 异常。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _controlsHidden.value = hidden;
          });
        }
        return const SizedBox.shrink();
      },
    );
  }

  /// 全屏按钮：进入 / 退出页面级自建全屏。
  Widget _buildFullscreenButton({required bool fullscreen}) {
    return Material(
      color: Colors.black.withValues(alpha: 0.6),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: IconButton(
        icon: Icon(
          fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
          color: Colors.white,
          size: 20,
        ),
        tooltip: fullscreen ? '退出全屏' : '全屏',
        onPressed: _toggleFullscreen,
      ),
    );
  }

  /// 进入 / 退出页面级全屏。
  ///
  /// **不使用 Chewie 内置全屏**：它会把播放器 `Navigator.push` 进一个独立路由
  /// （chewie 1.13.1 `chewie_player.dart` 的 `onEnterFullScreen`），而弹幕层是
  /// 页面 Stack 的兄弟节点、不会跟进去 → 真机表现为「全屏看不到弹幕」。
  /// 系统栏处理对齐 Chewie 的原行为：进入隐藏、退出恢复。
  /// 进入 / 退出页面级全屏（全屏按钮入口）。
  void _toggleFullscreen() {
    if (_isFullscreen.value) {
      _exitFullscreen(fromBack: false);
    } else {
      _enterFullscreen();
    }
  }

  /// 进入全屏：按视频比例自动横屏 + 隐藏系统栏。
  void _enterFullscreen() {
    setState(() => _isFullscreen.value = true);
    // 视频为**横屏比例**时自动切横屏（对齐 Chewie onEnterFullScreen 的默认行为：
    // 宽 > 高则强制 landscape）。竖屏比例视频不强转，避免把竖版 MV 拉成横屏。
    final size = _controller?.value.size;
    if (size != null && size.width > size.height) {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      debugPrint(
        '[MvDanmaku] 全屏：视频为横屏比例 '
        '(${size.width.toInt()}x${size.height.toInt()})，自动横屏',
      );
    }
    // 必须同时置「播放器沉浸生效中」标志：app.dart 的 _SystemUiUpdater 会在
    // 每次 rebuild 时把系统栏设回 edgeToEdge（除非该标志为真）—— 只调
    // setEnabledSystemUIMode 会被立刻覆盖，真机症状正是「全屏状态栏没隐藏」。
    // 该标志语义为「播放器沉浸生效中」（Zen 与横屏沉浸共用），此处借用同一契约。
    kPlayerLandscapeImmersiveActive.value = true;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    debugPrint('[MvDanmaku] 全屏=true');
  }

  /// 退出全屏：恢复旋转、沉浸标志与系统栏。
  ///
  /// [fromBack] 仅用于日志区分入口（系统返回键 / 全屏按钮）。
  void _exitFullscreen({required bool fromBack}) {
    if (!_isFullscreen.value) return;
    setState(() => _isFullscreen.value = false);
    // 恢复自由旋转：项目全局未锁定方向（全仓无其它 setPreferredOrientations），
    // 因此恢复为「全部方向」即回到进入前的状态
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    kPlayerLandscapeImmersiveActive.value = false;
    // 项目统一的退出恢复：先 manual 显式 show 再交给 _SystemUiUpdater 设 edgeToEdge
    restoreSystemUi();
    debugPrint('[MvDanmaku] 全屏=false${fromBack ? '（返回键）' : ''}');
  }

  /// 页面级全屏布局：黑底 + 居中视频（含弹幕层），系统栏已隐藏。
  Widget _buildFullscreenBody() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const ColoredBox(color: Colors.black);
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: AspectRatio(
          aspectRatio: controller.value.aspectRatio,
          child: _buildVideoStack(),
        ),
      ),
    );
  }

  /// 画中画模式布局：纯视频铺满（无控件），点击画中画窗口即返回完整页面。
  Widget _buildPipBody() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const ColoredBox(color: Colors.black);
    }
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: AspectRatio(
          aspectRatio: controller.value.aspectRatio,
          child: VideoPlayer(controller),
        ),
      ),
    );
  }

  /// 弹幕开关按钮：播放页内即时切换（与设置页「显示 MV 弹幕」同源）。
  ///
  /// 与画中画按钮同样式（半透明圆底、白色图标），位于视频右上角。
  Widget _buildDanmakuToggleButton() {
    final on = _danmakuEnabled.value;
    return Material(
      color: Colors.black.withValues(alpha: 0.6),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: IconButton(
        icon: Icon(
          on ? Icons.subtitles : Icons.subtitles_off_outlined,
          color: Colors.white,
          size: 20,
        ),
        tooltip: on ? '关闭弹幕' : '开启弹幕',
        onPressed: _toggleDanmaku,
      ),
    );
  }

  /// 画中画按钮：半透明圆形图标，点击进入画中画。
  Widget _buildPipButton() {
    return Material(
      color: Colors.black.withValues(alpha: 0.6),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: IconButton(
        icon: const Icon(
          Icons.picture_in_picture_alt,
          color: Colors.white,
          size: 20,
        ),
        tooltip: '画中画',
        onPressed: _enterPip,
      ),
    );
  }

  /// MV 投屏按钮：点击弹出设备选择 BottomSheet。
  Widget _buildCastButton(ColorScheme colorScheme, TextTheme textTheme) {
    return ListenableBuilder(
      listenable: context.read<DlnaProvider>(),
      builder: (context, _) {
        final dlna = context.read<DlnaProvider>();
        final isCasting = dlna.isCasting;
        return ListTile(
          leading: Icon(
            isCasting ? Icons.cast_connected : Icons.cast,
            color: isCasting ? colorScheme.primary : null,
          ),
          title: Text(isCasting ? '正在投屏：${dlna.deviceName ?? ''}' : '投屏到电视'),
          onTap: () {
            if (isCasting) {
              dlna.stop();
            } else if (_currentVideoUrl != null) {
              showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                builder: (_) => DlnaCastSheet(
                  mvUrl: _currentVideoUrl,
                  mvTitle: widget.song.displayName,
                ),
              );
            }
          },
        );
      },
    );
  }

  Widget _buildQualityBar(ColorScheme colorScheme, TextTheme textTheme) {
    if (_qualities.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.high_quality_outlined, size: 20, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Text('清晰度', style: textTheme.labelLarge),
          const Spacer(),
          if (_isSwitching)
            SizedBox(
              width: 16,
              height: 16,
              child: M3ECircularProgressIndicator(
                size: 16,
                strokeWidth: 2,
                color: colorScheme.primary,
              ),
            )
          else
            TextButton.icon(
              onPressed: _showQualitySheet,
              icon: const Icon(Icons.tune, size: 18),
              label: Text(_qualities[_currentQualityIndex].quality),
            ),
        ],
      ),
    );
  }

  Widget _buildInfoSection(ColorScheme colorScheme, TextTheme textTheme) {
    final song = widget.song;
    final detail = _detail;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            detail?.title ?? song.displayName,
            style: textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            detail?.artists ?? song.artist,
            style: textTheme.bodyMedium?.copyWith(color: colorScheme.primary),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              if (detail?.duration != null)
                _infoChip(Icons.timer_outlined, _formatDuration(detail!.duration!)),
              if (detail?.playCountLabel.isNotEmpty == true)
                _infoChip(Icons.play_circle_outline, '播放 ${detail!.playCountLabel}'),
              if (song.album.isNotEmpty)
                _infoChip(Icons.album_outlined, song.album),
            ],
          ),
          if (detail?.desc != null && detail!.desc!.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('简介', style: textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              detail.desc!,
              style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }

  Widget _infoChip(IconData icon, String label) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
