import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';

/// 定时关闭的小时上限。
const int kSleepTimerMaxHours = 24;

/// 中央形状的一种规格：外凸尖角 + 内凹谷底（齿轮感）。
///
/// 走 `RoundedPolygon.star`——也就是 m3e 自家 cookie 系列的写法
/// （`Shapes.c7SidedCookie` / `c9SidedCookie` / `c12SidedCookie` 都是这么造的）。
/// 正多边形（`fromVerticesNum`）**没有内凹**，看着不像 M3E shape，所以不用。
class SleepTimerShapeSpec {
  const SleepTimerShapeSpec({
    required this.vertices,
    required this.innerRadius,
    this.rounding = 0.3,
    this.innerRounding = 0.3,
    this.smoothing = 0,
  });

  /// 尖角数（同时也是谷底数）。
  final int vertices;

  /// 谷底半径，相对外接半径 1。越小内凹越深。
  ///
  /// 下限 0.66 是给中央文字留的安全区：文字块半对角线约 30（表盘 300dp 时），
  /// 谷底半径低于 0.66 文字会捅进凹槽里。
  final double innerRadius;

  /// 尖角圆角半径。
  final double rounding;

  /// 谷底圆角半径——与尖角分开给，谷底更圆才有 cookie 的手感。
  final double innerRounding;

  /// 0–1，越大切角越舒展。
  final double smoothing;
}

/// 形状池。小时数变化时从中切换一种。
const List<SleepTimerShapeSpec> kSleepTimerShapes = [
  SleepTimerShapeSpec(
    vertices: 5,
    innerRadius: 0.70,
    rounding: 0.30,
    innerRounding: 0.55,
    smoothing: 0.4,
  ),
  SleepTimerShapeSpec(vertices: 6, innerRadius: 0.72, rounding: 0.34, innerRounding: 0.50),
  SleepTimerShapeSpec(
    vertices: 6,
    innerRadius: 0.66,
    rounding: 0.42,
    innerRounding: 0.70,
    smoothing: 0.8,
  ),
  SleepTimerShapeSpec(vertices: 7, innerRadius: 0.75, rounding: 0.50, innerRounding: 0.50),
  SleepTimerShapeSpec(vertices: 8, innerRadius: 0.70, rounding: 0.24, innerRounding: 0.40),
  SleepTimerShapeSpec(vertices: 8, innerRadius: 0.66, rounding: 0.14, innerRounding: 0.30),
  SleepTimerShapeSpec(vertices: 9, innerRadius: 0.80, rounding: 0.50, innerRounding: 0.50),
  SleepTimerShapeSpec(
    vertices: 10,
    innerRadius: 0.72,
    rounding: 0.32,
    innerRounding: 0.55,
    smoothing: 0.6,
  ),
  SleepTimerShapeSpec(
    vertices: 11,
    innerRadius: 0.78,
    rounding: 0.44,
    innerRounding: 0.60,
    smoothing: 0.3,
  ),
  SleepTimerShapeSpec(vertices: 12, innerRadius: 0.80, rounding: 0.50, innerRounding: 0.50),
];

/// 小时数 → 形状池下标。
///
/// 用小时数做种子的**确定性**散列，而不是每次取随机数：否则表盘每帧重建都会
/// 换形状，看起来像闪烁。相邻小时若撞到同一种就顺延一格，保证小时数一变
/// 形状就变。
int sleepTimerShapeIndexForHour(int hours) {
  final n = kSleepTimerShapes.length;
  // Knuth 乘法散列取高位：让相邻小时尽量散开，看不出规律
  final hash = (hours * 2654435761) & 0x7fffffff;
  final index = (hash >> 13) % n;
  if (hours > 0 && index == sleepTimerShapeIndexForHour(hours - 1)) {
    return (index + 1) % n;
  }
  return index;
}

/// 中央形状的额外缩放。
///
/// 0 小时是圆：同样外接半径下圆的面积比多边形大（圆 πr²，六边形 2.598r²，
/// 差约 21%），不补偿会显得更大、也更容易误触「开始计时」。
double sleepTimerShapeScale(int hours) => hours <= 0 ? 0.86 : 1.0;

final Map<int, RoundedPolygon> _polygonCache = {};
final Map<int, Path> _pathCache = {};

/// 小时数对应的 M3E 形状，位于归一化空间（外接圆半径 1、中心 (0,0)）。
///
/// [hours] <= 0 时返回圆（「还没套圈」）；否则从 [kSleepTimerShapes] 里按
/// [sleepTimerShapeIndexForHour] 取一种齿轮形。
RoundedPolygon sleepTimerPolygon(int hours) {
  return _polygonCache.putIfAbsent(hours, () {
    if (hours <= 0) return RoundedPolygon.circle(numVertices: 64);
    final s = kSleepTimerShapes[sleepTimerShapeIndexForHour(hours)];
    return RoundedPolygon.star(
      numVerticesPerRadius: s.vertices,
      innerRadius: s.innerRadius,
      rounding: CornerRounding(radius: s.rounding, smoothing: s.smoothing),
      innerRounding: CornerRounding(radius: s.innerRounding),
    );
  });
}

/// [sleepTimerPolygon] 的 Path 形式（归一化空间），按小时缓存。
///
/// 拖动表盘时每帧都要重绘，缓存掉 `toPath()` 的 cubic 展开。
Path sleepTimerPolygonPath(int hours) =>
    _pathCache.putIfAbsent(hours, () => sleepTimerPolygon(hours).toPath());

/// 绘制前的归一化变换：把外接框缩放到 2×2 并把中心挪到原点。
///
/// **不能省**：`RoundedPolygon.star` 的包围盒并不关于原点对称——奇数角星的
/// 谷底只落在一侧（5 角星的外接框是 x∈[-0.7, 1] 而不是 [-1, 1]），直接按
/// 半径 1 画会偏心，而且不同角数的视觉大小也不一致。圆（0 小时）是恒等变换。
({double scale, double dx, double dy}) sleepTimerShapeTransform(int hours) {
  final b = sleepTimerPolygonPath(hours).getBounds();
  return (
    scale: 2 / math.max(b.width, b.height),
    dx: -b.center.dx,
    dy: -b.center.dy,
  );
}

/// 把小时对应的 M3E 形状铺进给定方框。
///
/// 形状自带 `star` 的首个顶点在 +x 方向，绘制前先把画布转到顶点朝上。
class SleepTimerPolygonPainter extends CustomPainter {
  const SleepTimerPolygonPainter({
    required this.hours,
    required this.color,
  });

  /// 小时数（0 画圆）。
  final int hours;

  /// 填充色。
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.min(size.width, size.height) / 2 * sleepTimerShapeScale(hours);
    final t = sleepTimerShapeTransform(hours);
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(-math.pi / 2);
    canvas.scale(r * t.scale);
    canvas.translate(t.dx, t.dy);
    canvas.drawPath(sleepTimerPolygonPath(hours), Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(SleepTimerPolygonPainter oldDelegate) =>
      oldDelegate.hours != hours || oldDelegate.color != color;
}
