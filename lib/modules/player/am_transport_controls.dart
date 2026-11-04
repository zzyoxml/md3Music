import 'package:iconic_morph/iconic_morph.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/build_flags.dart';
import '../../core/remote/tv_player_back_focus.dart';
import 'widgets/play_pause_morph_icon.dart';

// AM 传输按钮的矢量图标资源（24x24 描边 SVG，供 iconic_morph 解析）。
//
// 上一曲/下一曲仍是描边 SVG（IconTrimDraw 按压重绘）；中央播放/暂停已改用
// PlayPauseMorphIcon 实心双轨形变（参考小宇宙播放页按钮：三角塌成左竖条 +
// 右竖条从中心长高淡入），旧的 am_play_bold / am_pause_bold 描边资源已删除。
const String _prevAsset = 'assets/icons/am_prev.svg';
const String _nextAsset = 'assets/icons/am_next.svg';

/// AM（Apple Music 风格）播放器的传输控件：上一曲 / 播放暂停 / 下一曲。
///
/// 三个按钮同一种语言：纯白、无容器底色；中央按钮用实心形状成为视觉锚点
/// （上一曲/下一曲是描边 2.0 的线条画）。动画实现：
/// - 中央播放/暂停：[PlayPauseMorphIcon] 双轨实心形变——三角左缘钉住塌成
///   左竖条（左轨），右竖条从垂直中心长高淡入（右轨）。进度由其内部
///   AnimationController 按 [AMTransportControls.isPlaying] 双向驱动，
///   本组件不再持有形变控制器。
/// - 上一曲/下一曲：[IconicAnimatedIcon] + [IconTrimDraw]，静止时完整
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
    this.playIconColor = Colors.white,
    this.skipIconColor = Colors.white,
    this.morphDuration = const Duration(milliseconds: 280),
  });

  /// 当前是否正在播放：true 显示暂停形态，false 显示播放形态。
  final bool isPlaying;

  final VoidCallback? onPrevious;
  final VoidCallback? onPlayPause;
  final VoidCallback? onNext;

  /// 左右两侧按钮图标尺寸。
  final double skipIconSize;

  /// 中央播放按钮图标尺寸。
  final double playIconSize;

  /// 按钮间距。
  final double spacing;

  /// 上一首 / 下一曲的描边宽度（viewBox 单位，24 基准）。
  final double strokeWidth;

  final Color playIconColor;
  final Color skipIconColor;

  /// play↔pause 形变时长。
  final Duration morphDuration;

  @override
  State<AMTransportControls> createState() => _AMTransportControlsState();
}

class _AMTransportControlsState extends State<AMTransportControls> {
  /// prev / next 按压描边动画的触发控制器。
  final IconicAnimatedIconController _prevCtrl = IconicAnimatedIconController();
  final IconicAnimatedIconController _nextCtrl = IconicAnimatedIconController();

  /// tv: 中央播放键的焦点节点——播放页返回键把焦点交回播放键
  /// （见 `tv_player_back_focus.dart` 的 `TvPlayerPlayFocusBridge`）。
  /// 非 TV 构建恒 null：不创建、不登记，`IconButton` 自建节点，触屏路径零变化。
  FocusNode? _tvPlayFocus;

  /// tv: 取播放键节点并登记到移交桥（登记幂等）。
  FocusNode? get _tvPlayFocusNode {
    if (!kTvBuild) return null;
    final FocusNode node = _tvPlayFocus ??= FocusNode(
      debugLabel: 'am_transport_play',
    );
    TvPlayerPlayFocusBridge.instance.register(node);
    return node;
  }

  @override
  void dispose() {
    // tv: 播放键节点随本 State 销毁，先摘登记再释放。
    final FocusNode? tvPlayFocus = _tvPlayFocus;
    if (tvPlayFocus != null) {
      TvPlayerPlayFocusBridge.instance.unregister(tvPlayFocus);
      tvPlayFocus.dispose();
      _tvPlayFocus = null;
    }
    _prevCtrl.dispose();
    _nextCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 整簇自建重绘边界（修「Windows 鼠标点暂停整窗卡一下」）。
    //
    // 三颗按钮的按压水波画在各自 `IconButton` 内层 `Material` 的 ink 层上，
    // `markNeedsPaint` 会一路冒泡到**最近的重绘边界**；本簇外层没有边界时，
    // 一次点击的整段涟漪动画（约 200~600ms、满帧）会把最近边界内的整页重绘
    // ——AM 播放页里那是流光背景 + 歌词 + 写真，Windows 上表现为整窗掉帧。
    // 按空格不产生水波，所以同一条链路不卡，这正是历史反馈里的差异来源。
    // 在本簇自建边界后，涟漪只重绘这三颗按钮的矩形。纯增量：无布局、无焦点、
    // 无动画时长变化，TV / 触屏构建同构。
    return RepaintBoundary(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '上一首',
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
          // 中央按钮：实心双轨形变。PlayPauseMorphIcon 内部自驱动
          // （isPlaying 翻转时前进/倒放），无需外部控制器。
          IconButton(
            tooltip: widget.isPlaying ? '暂停' : '播放',
            iconSize: widget.playIconSize,
            // tv: 播放键用本组件自持的节点（非 TV 构建传 null，IconButton 自建）。
            focusNode: _tvPlayFocusNode,
            onPressed: widget.onPlayPause,
            style: IconButton.styleFrom(
              foregroundColor: widget.playIconColor,
            ),
            icon: PlayPauseMorphIcon(
              isPlaying: widget.isPlaying,
              size: widget.playIconSize,
              color: widget.playIconColor,
              duration: widget.morphDuration,
            ),
          ),
          SizedBox(width: widget.spacing),
          IconButton(
            tooltip: '下一首',
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
      ),
    );
  }
}
