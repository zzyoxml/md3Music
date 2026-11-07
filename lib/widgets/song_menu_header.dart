import 'dart:ui' show lerpDouble;

import 'package:material_ui/material_ui.dart';

import '../data/models/song.dart';
import '../modules/player/player_cover_morph.dart' show CoverGeometryProbe;
import 'smart_artwork_image.dart';
import 'song_menu_info_badges.dart';

/// 菜单头封面视觉常量：收缩动画的起止尺寸由这两个值推导
/// （圆角保持 [_kCoverRadius] 不变，尺寸缩到 `2 * _kCoverRadius` 即成正圆）。
const double _kCoverSize = 84;
const double _kCoverRadius = 16;

/// 「下一首播放」菜单内收缩阶段的控制器（每次打开菜单新建一个）。
///
/// 歌曲行菜单的「下一首播放」条目经 [shrinkToCircle] 触发收缩，并把收缩后
/// 圆形封面的屏幕矩形（设计像素，与 PlayerCoverMorphBus.miniRect 同空间）
/// 交给飞行层作为起点。收缩是纯装饰：菜单被意外关闭（barrier 点击）时返回
/// null，调用方静默退回普通路径。
class SongMenuHeaderShrinkController {
  _SongMenuHeaderState? _state;
  Future<Rect?>? _pending;

  /// 收缩到圆形（默认 220ms）并返回圆形封面的屏幕矩形。
  ///
  /// 重复调用复用同一次收缩的 Future（收缩期间菜单仍开着，防双击重复起飞）。
  Future<Rect?> shrinkToCircle({
    Duration duration = const Duration(milliseconds: 220),
  }) {
    final pending = _pending;
    if (pending != null) return pending;
    final state = _state;
    if (state == null || !state.mounted) return Future<Rect?>.value(null);
    return _pending = state._shrinkToCircle(duration);
  }
}

/// 歌曲更多菜单的头部：左侧圆角矩形封面（约头部高度的 70%），
/// 右侧文字列：歌名 / 歌手 / 专辑 + 信息徽章行（时长/音质/大小/VIP）。
class SongMenuHeader extends StatefulWidget {
  final Song song;

  /// 由调用方持有的收缩控制器；null 时头部无收缩能力（不传即可）。
  final SongMenuHeaderShrinkController? shrinkController;

  /// privilege/lite 拉取函数；null 时信息徽章只显示即时数据、不发请求。
  final SongMenuInfoFetcher? infoFetcher;

  const SongMenuHeader({
    super.key,
    required this.song,
    this.shrinkController,
    this.infoFetcher,
  });

  @override
  State<SongMenuHeader> createState() => _SongMenuHeaderState();
}

class _SongMenuHeaderState extends State<SongMenuHeader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shrinkCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  late final CurvedAnimation _shrinkAnim =
      CurvedAnimation(parent: _shrinkCtrl, curve: Curves.easeOutCubic);

  /// 收缩探针 paint 上报的最新矩形（设计像素）；收缩完成后即为圆的位置。
  Rect? _ballScreenRect;

  /// 缓存的封面子树：逐帧只动外层窗口尺寸，不重建 SmartArtworkImage
  /// （image provider / 解码宽度恒定，命中同一份 ImageCache，不闪不重载）。
  late Widget _ballChild = _buildBallChild();

  Widget _buildBallChild() {
    return SmartArtworkImage(
      artworkUri: widget.song.artworkUri,
      fallbackFilePath: widget.song.localPath,
      songId: widget.song.id,
      size: _kCoverSize,
      // 圆角由外层收缩窗口统一裁（ClipRRect 半径恒定），内层不自带圆角，
      // 否则两层圆角不同步会让角落露底。
      borderRadius: 0,
    );
  }

  @override
  void initState() {
    super.initState();
    widget.shrinkController?._state = this;
  }

  @override
  void didUpdateWidget(SongMenuHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.shrinkController != widget.shrinkController) {
      oldWidget.shrinkController?._state = null;
      widget.shrinkController?._state = this;
    }
    if (widget.song.id != oldWidget.song.id) {
      setState(() {
        _ballChild = _buildBallChild();
      });
    }
  }

  Future<Rect?> _shrinkToCircle(Duration duration) async {
    _shrinkCtrl.duration = duration;
    try {
      await _shrinkCtrl.forward().orCancel;
    } on TickerCanceled {
      // 菜单在收缩期间被关闭（barrier 点击等）：静默放弃，调用方走普通路径。
      return null;
    }
    // 等最后一帧 paint 完成，探针上报的已是最终圆形矩形。
    await WidgetsBinding.instance.endOfFrame;
    return _ballScreenRect;
  }

  @override
  void dispose() {
    if (widget.shrinkController?._state == this) {
      widget.shrinkController!._state = null;
    }
    _shrinkAnim.dispose();
    _shrinkCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
      child: Row(
        children: [
          // 左侧封面槽位：外层 84×84 固定，收缩时右侧文字不回流跳动；
          // 内层封面在槽位中心收缩（84 → 2×16=32，圆角恒 16，32 即正圆）。
          SizedBox(
            width: _kCoverSize,
            height: _kCoverSize,
            child: Center(
              // 探针包在 AnimatedBuilder 外层：子树尺寸每帧变化时探针
              // paint 自然逐帧上报，无需随动画重建探针本身。
              child: CoverGeometryProbe(
                onRect: (rect, _) => _ballScreenRect = rect,
                child: AnimatedBuilder(
                  animation: _shrinkAnim,
                  builder: (context, _) {
                    final size = lerpDouble(
                      _kCoverSize,
                      _kCoverRadius * 2,
                      _shrinkAnim.value,
                    )!;
                    return ClipRRect(
                      borderRadius:
                          BorderRadius.circular(_kCoverRadius),
                      child: SizedBox(
                        width: size,
                        height: size,
                        child: FittedBox(child: _ballChild),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          // 右侧文字信息：歌名 / 歌手 / 专辑（与改动前逐行一致）
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.song.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  widget.song.album.isEmpty ? '未知专辑' : widget.song.album,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                // 信息徽章：时长 / 最高音质 / 文件大小 / VIP 要求。
                // 在文字列内自然左对齐（与歌名/歌手/专辑同列），也填掉
                // 封面下方的空档；行高随内容增高，封面在槽位内垂直居中。
                const SizedBox(height: 4),
                SongMenuInfoBadges(
                  song: widget.song,
                  fetcher: widget.infoFetcher,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
