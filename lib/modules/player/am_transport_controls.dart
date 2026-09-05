import 'package:flutter/material.dart';
import 'package:iconic_morph/iconic_morph.dart';

// AM 传输按钮的矢量图标资源（24x24 描边 SVG，供 iconic_morph 解析）
const String _playAsset = 'assets/icons/am_play.svg';
const String _pauseAsset = 'assets/icons/am_pause.svg';
const String _prevAsset = 'assets/icons/am_prev.svg';
const String _nextAsset = 'assets/icons/am_next.svg';

/// AM（Apple Music 风格）播放器的传输控件：上一曲 / 播放暂停 / 下一曲。
///
/// 动画实现（基于第三方矢量形变包 iconic_morph）：
/// - 中央播放/暂停：用 [IconicShapeMorph]（形状形变）做 play↔pause 连续形变。
///   play 与 pause 两个 SVG 共享**完全相同的左竖线轮廓**，形状形变会把这条
///   共享轮廓"钉住不动"，只让右侧的三角斜边折叠成暂停的右竖条——因此左右
///   切换时左竖线不再错位。由 [IconicAnimatedIconController] 双向驱动：
///   play() 正向 morph 到暂停、stop() 反向 animateBack 回播放（均为动画）。
///   保留 AM 标志性的白色圆形按钮 + 黑色描边图标。
/// - 上一曲/下一曲：用 [IconicAnimatedIcon] + [IconTrimDraw]，静止时完整
///   显示（restValue=1），点击时"钢笔描边"重绘一次作为按压动画。
class AMTransportControls extends StatefulWidget {
  const AMTransportControls({
    super.key,
    required this.isPlaying,
    this.onPrevious,
    this.onPlayPause,
    this.onNext,
    this.skipIconSize = 38,
    this.playIconSize = 54,
    this.spacing = 12,
    this.strokeWidth = 2.0,
    this.playIconColor = Colors.black,
    this.playBgColor = Colors.white,
    this.skipIconColor = Colors.white,
    this.morphDuration = const Duration(milliseconds: 460),
  });

  /// 当前是否正在播放：true 显示暂停形态，false 显示播放形态。
  final bool isPlaying;

  final VoidCallback? onPrevious;
  final VoidCallback? onPlayPause;
  final VoidCallback? onNext;

  /// 左右两侧按钮图标尺寸。
  final double skipIconSize;

  /// 中央播放按钮图标尺寸（圆形背景会略大于此值）。
  final double playIconSize;

  /// 按钮间距。
  final double spacing;

  /// 描边宽度（viewBox 单位，24 基准）。越大越接近实心观感。
  final double strokeWidth;

  final Color playIconColor;
  final Color playBgColor;
  final Color skipIconColor;

  /// play↔pause 形变时长。
  final Duration morphDuration;

  @override
  State<AMTransportControls> createState() => _AMTransportControlsState();
}

class _AMTransportControlsState extends State<AMTransportControls> {
  /// play↔pause 形变触发器：play() 正向、stop() 反向（animateBack）。
  final IconicAnimatedIconController _morphCtrl = IconicAnimatedIconController();

  /// prev / next 按压描边动画的触发控制器。
  final IconicAnimatedIconController _prevCtrl = IconicAnimatedIconController();
  final IconicAnimatedIconController _nextCtrl = IconicAnimatedIconController();

  @override
  void dispose() {
    _morphCtrl.dispose();
    _prevCtrl.dispose();
    _nextCtrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(AMTransportControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    // isPlaying 变化时双向驱动形变：开始播放→morph 到暂停，暂停→morph 回播放
    if (oldWidget.isPlaying != widget.isPlaying) {
      if (widget.isPlaying) {
        _morphCtrl.play();
      } else {
        _morphCtrl.stop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          iconSize: widget.skipIconSize,
          onPressed: widget.onPrevious == null
              ? null
              : () {
                  _prevCtrl.play();
                  widget.onPrevious!();
                },
          icon: IconicAnimatedIcon(
            _prevAsset,
            effect: const IconTrimDraw(),
            autoplay: false,
            controller: _prevCtrl,
            size: widget.skipIconSize,
            color: widget.skipIconColor,
            strokeWidth: widget.strokeWidth,
          ),
        ),
        SizedBox(width: widget.spacing),
        // Apple Music 标志性白色圆形播放按钮：内部为 play↔pause 形状形变，
        // 共享的左竖线在两个状态间保持静止，消除错位。
        IconButton.filled(
          iconSize: widget.playIconSize,
          onPressed: widget.onPlayPause,
          style: IconButton.styleFrom(
            backgroundColor: widget.playBgColor,
            foregroundColor: widget.playIconColor,
          ),
          icon: IconicShapeMorph(
            _playAsset,
            _pauseAsset,
            // 首帧：正在播放则自动 morph 到暂停形态，否则静止在播放形态
            autoplay: widget.isPlaying,
            controller: _morphCtrl,
            duration: widget.morphDuration,
            size: widget.playIconSize,
            color: widget.playIconColor,
            strokeWidth: widget.strokeWidth,
          ),
        ),
        SizedBox(width: widget.spacing),
        IconButton(
          iconSize: widget.skipIconSize,
          onPressed: widget.onNext == null
              ? null
              : () {
                  _nextCtrl.play();
                  widget.onNext!();
                },
          icon: IconicAnimatedIcon(
            _nextAsset,
            effect: const IconTrimDraw(),
            autoplay: false,
            controller: _nextCtrl,
            size: widget.skipIconSize,
            color: widget.skipIconColor,
            strokeWidth: widget.strokeWidth,
          ),
        ),
      ],
    );
  }
}
