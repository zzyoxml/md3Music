import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// 重力驱动 3 层视差封面。
/// 层序固定：layerPaths[0]=背景（位移最大）→ [2]=前景（位移最小、缩放最大）。
class DepthParallaxCover extends StatefulWidget {
  const DepthParallaxCover({
    super.key,
    required this.layerPaths,
    this.tiltStream, // 仅测试注入；生产走 accelerometerEventStream
    this.strength = 9.0, // 最大平移像素（背景层，前景按 _factors 递减）
    this.onTiltError,
  });

  final List<String> layerPaths;
  final Stream<(double, double)>? tiltStream;
  final double strength;

  /// 倾斜传感器流错误回调（设备无加速计等）。
  final void Function(Object error)? onTiltError;

  @override
  State<DepthParallaxCover> createState() => _DepthParallaxCoverState();
}

class _DepthParallaxCoverState extends State<DepthParallaxCover> {
  static const List<double> _factors = [1.0, 0.55, 0.25]; // bg 移得最多
  static const List<double> _scales = [1.0, 1.03, 1.06]; // fg 外扩最大，遮住露边
  static const double _smoothing = 0.25; // 低通系数：越小越平滑、越大越跟手
  /// 倾斜增益：重力分量 /9.81 在常见握持角度下只有 0.1–0.35，
  /// 直接用会让视差几乎看不出来，故放大后再 clamp 到 -1..1。
  static const double _tiltGain = 2.5;

  StreamSubscription<(double, double)>? _sub;
  double _tx = 0, _ty = 0;

  @override
  void initState() {
    super.initState();
    _listen(widget.tiltStream ?? _defaultTiltStream());
  }

  Stream<(double, double)> _defaultTiltStream() {
    // 重力向量 → 归一化倾角 (-1..1)。加速度计静止时即重力方向，绝对倾角无漂移。
    return accelerometerEventStream()
        .map((e) => (e.x / 9.81 * _tiltGain, e.y / 9.81 * _tiltGain))
        .map(
          (v) => (
            v.$1.clamp(-1.0, 1.0).toDouble(),
            v.$2.clamp(-1.0, 1.0).toDouble(),
          ),
        );
  }

  void _listen(Stream<(double, double)> stream) {
    _sub = stream.listen(
      (v) {
        if (!mounted) return;
        setState(() {
          _tx = _tx + (v.$1 - _tx) * _smoothing;
          _ty = _ty + (v.$2 - _ty) * _smoothing;
        });
      },
      // 传感器不可用等错误：上报宿主（避免静默失效）
      onError: (Object e) {
        debugPrint('[DepthCover] 多层视差传感器错误: $e');
        if (mounted) widget.onTiltError?.call(e);
      },
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Stack 首个子项在最底层：必须按 背景(0)→中景(1)→前景(2) 的顺序画，
          // 让前景压在背景之上（此前倒序画导致背景层盖在最上面，层级反了）。
          for (var i = 0; i < widget.layerPaths.length; i++)
            Transform(
              transform: Matrix4.identity()
                ..translateByDouble(
                  _tx * widget.strength * _factors[i],
                  _ty * widget.strength * _factors[i],
                  0,
                  1,
                )
                ..scaleByDouble(_scales[i], _scales[i], 1, 1),
              alignment: Alignment.center,
              child: Image.file(
                File(widget.layerPaths[i]),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
              ),
            ),
        ],
      ),
    );
  }
}
