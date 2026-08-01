import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../../core/services/wakelock_service.dart';
import '../../data/models/mv_models.dart';
import '../../data/models/song.dart';
import '../../providers/player_provider.dart';
import '../../providers/dlna_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import 'dlna_cast_sheet.dart';

/// MV 播放页：展示歌曲 MV 视频，支持清晰度切换。
///
/// 进入时暂停背景音频播放，退出时恢复（仅当进入前正在播放）。
/// 加载链：/kmr/audio/mv(album_audio_id) → /video/detail(mvId) → /video/url(hash)。
enum _MvLoadState { loading, ready, noMv, error }

class MvPlayerPage extends StatefulWidget {
  final Song song;

  const MvPlayerPage({super.key, required this.song});

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
    _loadMv();
  }

  @override
  void dispose() {
    _disposed = true;
    // 移除投屏状态监听
    try {
      context.read<DlnaProvider>().removeListener(_onDlnaStateChanged);
    } catch (_) {}
    WakelockService.instance.setVideoPlaying(false);
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

  /// 视频控制器状态变化回调：同步播放状态到屏幕常亮服务。
  void _onVideoStateChanged() {
    WakelockService.instance.setVideoPlaying(_controller?.value.isPlaying ?? false);
  }

  Future<void> _loadMv() async {
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

    // 4. 初始化视频控制器
    await _initVideoController(url, autoPlay: true);
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
      );
      setState(() {
        _controller = controller;
        _chewieController = chewieController;
        _loadState = _MvLoadState.ready;
      });
      controller.addListener(_onVideoStateChanged);
      _onVideoStateChanged();
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('切换清晰度失败'),
            behavior: SnackBarBehavior.floating,
          ),
        );
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('切换清晰度失败：$e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _showQualitySheet() {
    if (_qualities.isEmpty) return;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
    );
  }

  @override
  Widget build(BuildContext context) {
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
          CircularProgressIndicator(color: colorScheme.primary),
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

    final videoPlayer = Container(
      color: Colors.black,
      child: _chewieController != null
          ? Chewie(controller: _chewieController!)
          : const Center(child: CircularProgressIndicator(color: Colors.white)),
    );

    // 横屏：左 70% 视频 + 右 30% 清晰度&信息
    if (isLandscape) {
      return Row(
        children: [
          Expanded(flex: 7, child: videoPlayer),
          Expanded(
            flex: 3,
            child: ListView(
              children: [
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
        _buildQualityBar(colorScheme, textTheme),
        _buildCastButton(colorScheme, textTheme),
        const Divider(height: 1),
        _buildInfoSection(colorScheme, textTheme),
      ],
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
              child: CircularProgressIndicator(
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
