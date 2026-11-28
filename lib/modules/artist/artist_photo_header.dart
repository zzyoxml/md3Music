import 'package:flutter/material.dart';

import '../player/artist_photo_service.dart';
import 'artist_photo_banner.dart';

/// 三按钮叠加区高度（写真淡出带延伸进按钮区，保证「按钮压在写真上」）。
const double kArtistHeaderActionsHeight = 96;

/// header 总高：写真 45% 屏高（钳 260~430）+ 按钮叠加区 96。
double artistBannerHeightFor(double screenH) =>
    (screenH * 0.45).clamp(260.0, 430.0) + kArtistHeaderActionsHeight;

/// 歌手详情页顶部写真 banner 区块（A 方案版式）：
/// 全幅写真底缘羽化消融 + 顶部状态栏压暗 + 居中歌手名。
/// 写真拉不到时回落兜底头像（fallbackUrl，单页）；两者都没有时回落
/// primaryContainer→透明渐变底，版式（高度/名字/按钮叠加区）保持不变。
class ArtistPhotoHeader extends StatelessWidget {
  final String? photoHash;
  final String artistName;
  final int intervalSeconds;

  /// header 是否在可视区（驱动 banner 轮播停表）。
  final bool active;

  /// 写真归属过滤用的歌手 id（透传给 banner，见 [ArtistPhotoBanner.artistId]）。
  final String? artistId;

  /// 写真数据源注入（测试用）；null → ArtistPhotoService.instance。
  final ArtistPhotoService? service;

  /// 无写真时的兜底图（歌手头像），透传给 banner 单页渲染。
  final String? fallbackUrl;

  /// 叠加在写真底缘淡出区内的一行操作（三按钮）；null 时不渲染。
  final Widget? actions;

  /// tv: 透传给 [ArtistPhotoBanner] 的翻页 key（见其 `flipKey`）。
  final GlobalKey<ArtistPhotoBannerState>? flipKey;

  const ArtistPhotoHeader({
    super.key,
    required this.photoHash,
    required this.artistName,
    required this.intervalSeconds,
    this.active = true,
    this.fallbackUrl,
    this.artistId,
    this.service,
    this.actions,
    this.flipKey,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final height = artistBannerHeightFor(MediaQuery.sizeOf(context).height);
    return SizedBox(
      height: height,
      width: double.infinity,
      // ClipRect：ImageFiltered 滤镜层会逃出无裁剪祖先（AM 实测）
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 回落底色：无写真时即主体视觉；有写真时是淡出区的承接底
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    colorScheme.primaryContainer,
                    colorScheme.surface.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
            if (photoHash != null)
              ArtistPhotoBanner(
                hash: photoHash!,
                active: active,
                intervalSeconds: intervalSeconds,
                scrimOpacity: 0, // 可读性交由压暗与羽化承担，不用平面遮罩
                feather: true,
                fallbackUrl: fallbackUrl,
                artistId: artistId,
                artistName: artistName,
                service: service,
                flipKey: flipKey,
              ),
            // 顶部压暗：状态栏与返回/操作按钮在照片上的对比度
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.center,
                    colors: [
                      Colors.black.withValues(alpha: 0.30),
                      Colors.black.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
            // 歌手名：居中压在写真下缘（圆点上方）。
            // 无写真参数（回落渐变态）时改用主题前景色，避免白字压浅色
            // primaryContainer 不可读；「有 hash 但拉到空写真」的边界仍为白字
            // （banner 内部异步，头部无从感知，真机验收观察该项观感）。
            Positioned(
              left: 24,
              right: 24,
              bottom: kArtistHeaderActionsHeight + 44,
              child: Text(
                artistName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: photoHash == null
                          ? colorScheme.onSurface
                          : Colors.white,
                      shadows: const [
                        Shadow(
                          blurRadius: 12,
                          color: Color(0x99000000),
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
              ),
            ),
            // 三按钮叠加在写真淡出区（「底部按钮区域也被写真覆盖」的落点）
            if (actions != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 12,
                child: actions!,
              ),
          ],
        ),
      ),
    );
  }
}
