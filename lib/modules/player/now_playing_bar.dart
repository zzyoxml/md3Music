import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/build_flags.dart';
import '../../core/layout/bottom_chrome_dimens.dart';
import '../../core/remote/remote_slider.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/motion_constants.dart';
import '../../core/utils/app_haptics.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/player_provider.dart';
import '../../widgets/smart_artwork_image.dart';
import 'full_player_route.dart';

/// 全宽底部播放栏（桌面音乐软件式，见横屏平板重设计计划 4.6）。
///
/// 横跨侧栏 + 内容区，复用 [PlayerProvider]。布局：
/// - 左：封面 + 标题/歌手（点击进完整播放页）；
/// - 中：上一首 / 播放暂停 / 下一首 + 进度条（可拖动 seek）；
/// - 右：收藏 / 播放模式（循环·随机）。
///
/// 桌面布局下由 [DesktopShell] 渲染，同时抑制底部全局 [MiniPlayer] 与二级
/// 悬浮播放器，避免三套播放器并存割裂。无正在播放歌曲时整栏收起。
class NowPlayingBar extends StatelessWidget {
  const NowPlayingBar({super.key});

  /// 栏高：跨文件底栏几何常量（与 `PlayerPanelSignal.fallbackBarHeight` 同源）。
  static const double _kHeight = BottomChromeDimens.nowPlayingBarHeight;

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final song = player.currentSong;
    final cs = Theme.of(context).colorScheme;
    // 系统「移除动画」：整栏收合瞬时完成（不播 240ms 尺寸补间，见计划 §1.3 矩阵）。
    // 本组件是 StatelessWidget，没有 didChangeDependencies 可缓存，故 build 内直读：
    // 直读建立的 MediaQuery 依赖正是「设置翻转即重建」所需。
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);

    // 完整播放页展开时整栏淡出（与 MiniPlayer 同一 playerExpansion 规则）。
    return ValueListenableBuilder<double>(
      valueListenable: playerExpansion,
      builder: (context, exp, child) {
        final opacity = (1.0 - exp).clamp(0.0, 1.0);
        return IgnorePointer(ignoring: exp > 0.5, child: Opacity(opacity: opacity, child: child));
      },
      child: AnimatedSize(
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 240),
        curve: M3ExpressiveMotion.barVisibilityCurve,
        alignment: Alignment.bottomCenter,
        child: song == null
            ? const SizedBox(width: double.infinity)
            : _buildBar(context, player, song, cs),
      ),
    );
  }

  Widget _buildBar(
    BuildContext context,
    PlayerProvider player,
    dynamic song,
    ColorScheme cs,
  ) {
    return Material(
      color: cs.surfaceContainerHigh,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Divider(height: 1, thickness: 1, color: cs.outlineVariant),
          SizedBox(
            height: _kHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  // 左：封面 + 标题/歌手（点击进完整播放页）
                  Expanded(
                    child: _NowPlayingInfo(song: song),
                  ),
                  // 中：传输控制 + 进度条
                  Expanded(
                    flex: 2,
                    child: _NowPlayingControls(player: player),
                  ),
                  // 右：收藏 + 播放模式
                  Expanded(
                    child: _NowPlayingExtras(player: player, song: song),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NowPlayingInfo extends StatelessWidget {
  const _NowPlayingInfo({required this.song});
  final dynamic song;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: AppRadius.smAll,
      onTap: () {
        AppHaptics.click(HapticCategory.navigation);
        openFullPlayer(context);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: AppRadius.coverAll,
              child: SizedBox(
                width: 48,
                height: 48,
                child: SmartArtworkImage(
                  artworkUri: song.artworkUri,
                  fallbackFilePath: song.localPath,
                  songId: song.id,
                  size: 48,
                  borderRadius: AppRadius.cover,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NowPlayingControls extends StatelessWidget {
  const _NowPlayingControls({required this.player});
  final PlayerProvider player;

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(Icons.skip_previous),
              tooltip: '上一首',
              onPressed: () {
                AppHaptics.click(HapticCategory.transport);
                player.previous();
              },
            ),
            const SizedBox(width: 4),
            // 批次 4c（计划 §6.3）：主播放钮换 M3EFilledButton。
            // 取色/阴影走组件默认 token（filled = primary/onPrimary、静置 elevation 0，
            // 见 button_tokens_adapter），与 IconButton.filled 同量级；40x40 保持替换前
            // 视觉尺寸（传输行仍是裸 IconButton 的 48dp，72dp 栏高内不溢出）；
            // 按压圆→方形变属「跟手」例外档，按钮系源码零 AnimationController/repeat
            //（帧源审计见计划 §7.5 第 17 项）。参考既有写法：artist_detail_page 写真 header。
            M3EFilledButton(
              tooltip: player.isPlaying ? '暂停' : '播放',
              shape: M3EButtonShape.round,
              decoration: const M3EButtonDecoration(
                fixedSize: Size(40, 40),
                padding: EdgeInsets.zero,
              ),
              onPressed: () {
                AppHaptics.click(HapticCategory.transport);
                if (player.isPlaying) {
                  player.pause();
                } else {
                  player.resume();
                }
              },
              child: Icon(player.isPlaying ? Icons.pause : Icons.play_arrow),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.skip_next),
              tooltip: '下一首',
              onPressed: () {
                AppHaptics.click(HapticCategory.transport);
                player.next();
              },
            ),
          ],
        ),
        // 进度条：只订阅 positionNotifier，避免整栏随进度高频重建。
        ValueListenableBuilder<Duration>(
          valueListenable: player.positionNotifier,
          builder: (context, pos, _) {
            final dur = player.duration ?? Duration.zero;
            final maxMs = dur.inMilliseconds.toDouble();
            final value = maxMs > 0
                ? pos.inMilliseconds.clamp(0, dur.inMilliseconds).toDouble()
                : 0.0;
            return Row(
              children: [
                SizedBox(
                  width: 44,
                  child: Text(
                    _fmt(pos),
                    textAlign: TextAlign.end,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
                Expanded(
                  // tv: TV 构建换 RemoteSlider——原生 Slider 吞四方向键（P-C；
                  // SliderTheme 装饰参数无法透传，TV 分支走 Material 默认样式）
                  // 批次 4c 评估：非 TV 分支不换 M3ESlider——组件 LayoutBuilder 硬编码
                  // 最小行高 48dp（m3e_slider.dart:492-497，thumbRippleRadius*2，
                  // M3ESliderDecoration 无字段可调），本栏 72dp 减去传输行 48dp 仅剩
                  // 24dp 槽位，替换必现 RenderFlex 溢出；保持 SliderTheme+Slider，需人决策。
                  child: kTvBuild
                      ? RemoteSlider(
                          value: maxMs > 0 ? value : 0.0,
                          max: maxMs > 0 ? maxMs : 1.0,
                          onChanged: maxMs > 0
                              ? (v) => player.seek(
                                  Duration(milliseconds: v.round()),
                                  forceNotify: true)
                              : null,
                        )
                      : SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3,
                            thumbShape:
                                const RoundSliderThumbShape(enabledThumbRadius: 6),
                            overlayShape:
                                const RoundSliderOverlayShape(overlayRadius: 12),
                          ),
                          child: Slider(
                            value: maxMs > 0 ? value : 0.0,
                            max: maxMs > 0 ? maxMs : 1.0,
                            onChanged: maxMs > 0
                                ? (v) => player
                                    .seek(Duration(milliseconds: v.round()), forceNotify: true)
                                : null,
                          ),
                        ),
                ),
                SizedBox(
                  width: 44,
                  child: Text(
                    _fmt(dur),
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _NowPlayingExtras extends StatelessWidget {
  const _NowPlayingExtras({required this.player, required this.song});
  final PlayerProvider player;
  final dynamic song;

  IconData _loopIcon() {
    if (player.shuffleEnabled) return Icons.shuffle;
    switch (player.loopMode) {
      case AppLoopMode.one:
        return Icons.repeat_one;
      case AppLoopMode.all:
        return Icons.repeat_on;
      case AppLoopMode.off:
        return Icons.repeat;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final favorites = context.watch<FavoritesProvider>();
    final isFav = favorites.isFavorite(song.id);
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        IconButton(
          tooltip: isFav ? '取消收藏' : '收藏',
          icon: Icon(
            isFav ? Icons.favorite : Icons.favorite_border,
            color: isFav ? cs.primary : null,
          ),
          onPressed: () {
            AppHaptics.click(HapticCategory.transport);
            favorites.toggleFavorite(song);
          },
        ),
        IconButton(
          tooltip: '播放模式',
          icon: Icon(
            _loopIcon(),
            color: player.shuffleEnabled || player.loopMode != AppLoopMode.off
                ? cs.primary
                : null,
          ),
          onPressed: () {
            AppHaptics.click(HapticCategory.transport);
            player.cyclePlayMode();
          },
        ),
      ],
    );
  }
}
