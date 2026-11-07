import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../providers/theme_provider.dart';
import 'artist_photo_service.dart';

/// MD3 风格播放页背景：歌手写真轮播。
///
/// 通过 `/images` 接口获取歌手写真图片列表，用 [AnimatedSwitcher] 淡入淡出
/// 自动切换，叠加半透明 [ColorScheme.surface] 遮罩保证上层文字可读。
/// 切换间隔由 [ThemeProvider.artistPhotoInterval] 控制。
class ArtistPhotoBackground extends StatefulWidget {
  final String hash;

  /// 写真图片可用性回调：true 表示当前有图片可显示，false 表示加载中或无图。
  /// 上层据此决定是否隐藏左侧专辑封面，避免写真无图时封面一起消失。
  final ValueChanged<bool>? onHasImages;

  /// 写真数据源；null 时取 [ArtistPhotoService.instance]（测试可注入）。
  final ArtistPhotoService? service;

  const ArtistPhotoBackground({
    super.key,
    required this.hash,
    this.onHasImages,
    this.service,
  });

  @override
  State<ArtistPhotoBackground> createState() => _ArtistPhotoBackgroundState();
}

class _ArtistPhotoBackgroundState extends State<ArtistPhotoBackground> {
  List<String> _imageUrls = [];
  int _currentIndex = 0;
  Timer? _timer;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadImages();
  }

  @override
  void didUpdateWidget(covariant ArtistPhotoBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hash != widget.hash) {
      _loadImages();
    }
  }

  Future<void> _loadImages() async {
    setState(() {
      _loading = true;
      _imageUrls = [];
      _currentIndex = 0;
    });
    // 加载开始：通知上层当前无可用图片
    widget.onHasImages?.call(false);
    _stopTimer();

    if (widget.hash.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    // 走 ArtistPhotoService（与 AM 播放页共用）：本地服务器未就绪 / 请求失败 /
    // 响应非法时返回空列表，不抛异常。
    final urls = await (widget.service ?? ArtistPhotoService.instance)
        .load(hash: widget.hash);

    if (!mounted) return;
    setState(() {
      _imageUrls = urls;
      _loading = false;
    });
    // 加载完成：通知上层是否实际有图片可显示
    widget.onHasImages?.call(urls.isNotEmpty);
    if (urls.length > 1) _startTimer();
  }

  void _startTimer() {
    _stopTimer();
    final interval = context.read<ThemeProvider>().artistPhotoInterval;
    _timer = Timer.periodic(Duration(seconds: interval), (_) {
      if (!mounted || _imageUrls.length <= 1) return;
      setState(() {
        _currentIndex = (_currentIndex + 1) % _imageUrls.length;
      });
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _stopTimer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _imageUrls.isEmpty) return const SizedBox.shrink();
    final opacity = context.watch<ThemeProvider>().artistPhotoOpacity;
    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 800),
          child: CachedNetworkImage(
            key: ValueKey(_currentIndex),
            imageUrl: _imageUrls[_currentIndex],
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            placeholder: (_, __) => const SizedBox.shrink(),
            errorWidget: (_, __, ___) => const SizedBox.shrink(),
          ),
        ),
        // 半透明遮罩，透明度由设置页控制（值越大遮罩越浓，写真越淡）
        Container(
          color: Theme.of(context).colorScheme.surface.withValues(alpha: opacity),
        ),
      ],
    );
  }
}
