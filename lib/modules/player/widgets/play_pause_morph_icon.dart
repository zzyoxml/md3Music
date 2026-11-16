import 'dart:math' as math;

import 'package:flutter/material.dart';

/// play↔pause 双轨实心形变图标（AM 播放器中央按钮）。
///
/// 画法为自绘 [CustomPainter]（24×24 视箱实心填充 + 圆角多边形），不依赖
/// SVG 资源与 iconic_morph（prev/next 仍走 iconic_morph 描边重绘）。
/// 形变进度由内部 [AnimationController] 双向驱动：[PlayPauseMorphIcon.isPlaying]
/// 翻转时 forward（播放→暂停）/ reverse（暂停→播放），初值直接取目标形态
/// 静止帧（无入场动画）。点击触发的过渡属于"必须跟手的交互"，按项目帧率
/// 约定满帧驱动，动画到位即停（无循环产帧）。
class PlayPauseMorphIcon extends StatefulWidget {
  const PlayPauseMorphIcon({
    super.key,
    required this.isPlaying,
    this.size = 54,
    this.color = Colors.white,
    this.duration = const Duration(milliseconds: 280),
  });

  /// 当前是否正在播放：true 显示暂停形态（t=1），false 显示播放形态（t=0）。
  final bool isPlaying;

  /// 图标边长（正方形）。
  final double size;

  final Color color;

  /// play↔pause 形变时长（参考视频实测约 350ms，取更快的手感）。
  final Duration duration;

  @override
  State<PlayPauseMorphIcon> createState() => PlayPauseMorphIconState();
}

/// 公开 State 以便测试读取 [progress]。
class PlayPauseMorphIconState extends State<PlayPauseMorphIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: widget.isPlaying ? 1.0 : 0.0,
  );

  /// 形变进度：0 = 播放形态，1 = 暂停形态。
  double get progress => _controller.value;

  @override
  void didUpdateWidget(PlayPauseMorphIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _controller.duration = widget.duration;
    }
    if (oldWidget.isPlaying != widget.isPlaying) {
      if (widget.isPlaying) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        return CustomPaint(
          size: Size.square(widget.size),
          painter: _PlayPauseMorphPainter(
            progress: _controller.value,
            color: widget.color,
          ),
        );
      },
    );
  }
}

// ---- 双轨形变几何（24×24 视箱）----
//
// 形变编排参考小宇宙播放页按钮（实心形状、两条轨道并行）：
// - 左轨（master t ∈ [0, 0.55]，easeInOutCubic）：实心三角左边缘钉住不动，
//   右尖回缩、上下斜边折叠成左竖条——三角"塌"成暂停的左半边；
// - 右轨（master t ∈ [0.30, 1.00]，easeInOut）：右竖条从垂直中心 (y=12)
//   向上下对称长高，同时淡入（同一进度驱动高度与不透明度）。
// t=0 为播放形态（三角），t=1 为暂停形态（双竖条）；反向（暂停→播放）由
// AnimationController.reverse 对称回放。
//
// 坐标与旧 am_play_bold / am_pause_bold 的描边外缘对齐：
// 左竖条 x 6.5..9.5（旧 SVG 左线 x=8、描边 3）、右竖条 x 14.5..17.5
// （旧右线 x=16）、三角右尖 x=20.5（旧描边 join 外缘）。
// 竖条高 15（y 4.5..19.5），宽高比 1:5，贴近参考视频的条形比例。

// 左竖条（也是三角的左边缘）x 范围
const double _leftBarLeft = 6.5;
const double _leftBarRight = 9.5;
// 右竖条 x 范围
const double _rightBarLeft = 14.5;
const double _rightBarRight = 17.5;
// 竖条 y 范围
const double _barTop = 4.5;
const double _barBottom = 19.5;
// 三角右尖 x
const double _apexX = 20.5;
// 三角尖端保留一条微小竖直切面（半高 0.65），让尖角也能参与圆角钳制
const double _tipFacetHalf = 0.65;
const double _cornerRadius = 1.5;

/// 左轨：t 时刻"三角→左竖条"的 4 个角点（顺时针 TL/TR/BR/BL）。
/// 左边缘恒在 x=6.5；t=0 时 TR/BR 收拢成右尖（微小切面），t=1 为左竖条右缘。
List<Offset> playPauseLeftCorners(double t) {
  final double tc = t.clamp(0.0, 1.0).toDouble();
  final double k = Curves.easeInOutCubic.transform(
    const Interval(0.0, 0.55).transform(tc),
  );
  const Offset apexTop = Offset(_apexX, 12 - _tipFacetHalf);
  const Offset apexBottom = Offset(_apexX, 12 + _tipFacetHalf);
  return <Offset>[
    const Offset(_leftBarLeft, _barTop),
    Offset.lerp(apexTop, const Offset(_leftBarRight, _barTop), k)!,
    Offset.lerp(apexBottom, const Offset(_leftBarRight, _barBottom), k)!,
    const Offset(_leftBarLeft, _barBottom),
  ];
}

/// 右轨进度：右竖条的长高与淡入共用同一条进度（0 = 不可见，1 = 全高全不透明）。
double playPauseRightBarProgress(double t) {
  final double tc = t.clamp(0.0, 1.0).toDouble();
  return Curves.easeInOut.transform(const Interval(0.30, 1.0).transform(tc));
}

/// t 时刻右侧竖条：从垂直中心 (y=12) 向上下长高的圆角矩形；不可见时返回 null。
RRect? playPauseRightBar(double t) {
  final double q = playPauseRightBarProgress(t);
  if (q <= 0.0) {
    return null;
  }
  final double halfHeight = (_barBottom - _barTop) / 2 * q;
  return RRect.fromRectAndRadius(
    Rect.fromLTRB(
      _rightBarLeft,
      12 - halfHeight,
      _rightBarRight,
      12 + halfHeight,
    ),
    Radius.circular(math.min(_cornerRadius, halfHeight)),
  );
}

/// 把顺时针多边形角点转成带圆角的填充路径（二次贝塞尔切角）。
/// 每个角的半径按相邻边长的一半钳制；零长边（重合角点）直接跳过该角。
Path roundedPolygonPath(List<Offset> points, double radius) {
  final int n = points.length;
  final Path path = Path();
  bool started = false;
  for (int i = 0; i < n; i++) {
    final Offset prev = points[(i - 1 + n) % n];
    final Offset curr = points[i];
    final Offset next = points[(i + 1) % n];
    final double prevLen = (curr - prev).distance;
    final double nextLen = (next - curr).distance;
    if (prevLen == 0 || nextLen == 0) {
      continue;
    }
    final double r = math.min(radius, math.min(prevLen / 2, nextLen / 2));
    final Offset start = curr + (prev - curr) / prevLen * r;
    final Offset end = curr + (next - curr) / nextLen * r;
    if (started) {
      path.lineTo(start.dx, start.dy);
    } else {
      path.moveTo(start.dx, start.dy);
      started = true;
    }
    path.quadraticBezierTo(curr.dx, curr.dy, end.dx, end.dy);
  }
  path.close();
  return path;
}

class _PlayPauseMorphPainter extends CustomPainter {
  const _PlayPauseMorphPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double scale = size.width / 24;
    canvas.save();
    canvas.scale(scale);

    final Paint fill = Paint()..style = PaintingStyle.fill;
    canvas.drawPath(
      roundedPolygonPath(playPauseLeftCorners(progress), _cornerRadius),
      fill..color = color,
    );

    final RRect? right = playPauseRightBar(progress);
    if (right != null) {
      canvas.drawRRect(
        right,
        fill..color = color.withValues(alpha: playPauseRightBarProgress(progress)),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PlayPauseMorphPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}
