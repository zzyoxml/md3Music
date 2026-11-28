import 'dart:math' as math;

/// 频谱幅值包络：**瞬时上升 + 时基指数回落**。
///
/// ## 为什么需要它
///
/// 原实现把「上升快、回落慢」的插值写在 `spectrumStream.listen` 回调里，于是
/// 插值**只在原生帧到达时前进一次**（~20fps），回落被量化成每秒 20 个台阶，肉眼可见。
/// 同一屏的封面旋转走 [PlayerFrameDriver] 是 60fps，反差让台阶感更刺眼。
///
/// ## 为什么衰减必须按时间算
///
/// 旧系数是「每次到达」的比例，与时间无关：
///   `×0.65` 在 50ms 到达间隔下等效 τ = -50 / ln(0.65) ≈ 116ms。
/// 若原样搬到 16ms 节拍，回落会**快约 3 倍**（τ ≈ 37ms）。
/// 因此这里用 `k = 1 - exp(-dt / τ)`，使衰减速度与节拍频率完全解耦。
///
/// 本类不依赖 Flutter，可直接单测。
class SpectrumBandEnvelope {
  SpectrumBandEnvelope({
    required this.bandCount,
    this.releaseTau = defaultReleaseTau,
  })  : assert(bandCount > 0, 'bandCount must be positive'),
        _values = List<double>.filled(bandCount, 0.0),
        _target = List<double>.filled(bandCount, 0.0);

  /// 回落到 1/e 所需时间。
  ///
  /// 默认 120ms：与旧实现「50ms 间隔衰减到 65%」的等效时间常数（≈116ms）对齐，
  /// 保住既有手感，只是从台阶变成连续曲线。
  static const Duration defaultReleaseTau = Duration(milliseconds: 120);

  /// 判定「视觉上已静止」的阈值。柱子高度域为 0..1，柱最大长约 30~40 逻辑像素，
  /// 1e-3 × 40 = 0.04px，远低于一个像素的可见差异。
  static const double _settleEpsilon = 1e-3;

  /// 柱数量（= [values] 的长度）。
  final int bandCount;

  /// 回落时间常数。
  final Duration releaseTau;

  final List<double> _values;
  final List<double> _target;

  /// 当前显示值。**复用缓冲**，调用方只读，勿改动内容。
  ///
  /// 注意：因为返回的是同一个 List 实例，直接把它赋给
  /// `ValueNotifier<List<double>>` **不会**触发通知（List 的 `==` 是同一性比较）。
  /// 调用方必须自行 `List.from(...)` 出新实例。
  List<double> get values => _values;

  /// 数据到达时调用（~20fps）：只登记目标，**不动**显示值。
  ///
  /// [bands] 长度可与 [bandCount] 不同：短则补 0、长则截断。
  void setTarget(List<double> bands) {
    final n = bandCount;
    final m = bands.length;
    for (var i = 0; i < n; i++) {
      _target[i] = i < m ? bands[i].clamp(0.0, 1.0) : 0.0;
    }
  }

  /// 每个显示帧调用一次（60fps），[dt] 为本拍的真实经过时间。
  void advance(Duration dt) {
    final dtUs = dt.inMicroseconds;
    if (dtUs <= 0) return;
    final tauUs = releaseTau.inMicroseconds;
    // k 每拍只算一次（不是每根柱一次）
    final k = tauUs <= 0 ? 1.0 : 1.0 - math.exp(-dtUs / tauUs);
    for (var i = 0; i < bandCount; i++) {
      final t = _target[i];
      final c = _values[i];
      // 上升瞬时到位；回落按时间常数指数逼近目标
      _values[i] = t > c ? t : c + (t - c) * k;
    }
  }

  /// 是否已收敛（各柱 |value - target| 均不超过 [_settleEpsilon]）。
  /// 供调用方「收敛停帧」用 —— 不要留一个空转的 60fps 订阅。
  bool get isSettled {
    for (var i = 0; i < bandCount; i++) {
      if ((_values[i] - _target[i]).abs() > _settleEpsilon) return false;
    }
    return true;
  }

  /// 全部归零并立即收敛（柱数变化 / 页面重建时调用）。
  void reset() {
    for (var i = 0; i < bandCount; i++) {
      _values[i] = 0.0;
      _target[i] = 0.0;
    }
  }
}
