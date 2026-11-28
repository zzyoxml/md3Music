import 'dart:math' as math;

/// 频谱 → 流光背景律动强度的**标量包络**（纯 Dart，可单测）。
///
/// 数据源是仓库既有的 [SpectrumService] 频谱流（40 段归一化幅值），本类只做
/// 「低频能量 + 全带能量 + 瞬态」三件事的归约与平滑，输出一个可直接写进
/// 流光 shader `uMotion` 的标量。设计要点：
///
/// - **无声/无数据 = [ambient]（默认 1.0）**：等价于改动前「恒 1.0」的观感，
///   因此没开频谱、系统无采集、或流短暂中断时**不会**出现任何退化；
/// - **有音乐 = [ambient] + gain × 活动度**：顶点上限 [maxMotion]（默认 1.5），
///   让「随乐变强」看得见；adapter 侧不再把 1.0 当作硬顶（见 uniforms 的
///   [FlowingUniforms.maxMotion] 注释）；
/// - **按时间推进**：attack/release 用 `k = 1 - exp(-dt/τ)`，与节拍频率解耦
///   （与 `SpectrumBandEnvelope` 同一口径，避免「按帧衰减」在 30fps 下变快）；
/// - **零分配**：[setBands] 只做归约、只存两个标量；[advance] 只算常数次数学，
///   不会产生任何 List/闭包，适合在 30fps 共享节拍里逐拍调用。
///
/// 帧驱动约定：本类**不持有**任何 Timer/Ticker，由调用方在既有节拍里
/// `advance(dt)`；调用方负责在不可见/暂停时停止喂数据（本仓库的流光已经
/// 按四判据解绑驱动，订阅窗口与之同生命周期）。
class RhythmMotionEnvelope {
  RhythmMotionEnvelope({
    this.ambient = 1.0,
    this.gain = 0.45,
    this.maxMotion = 1.5,
    this.attack = const Duration(milliseconds: 100),
    this.release = const Duration(milliseconds: 460),
    this.staleAfter = const Duration(milliseconds: 500),
    this.slowTau = const Duration(milliseconds: 250),
    this.bassFraction = 0.22,
  })  : assert(ambient >= 0),
        assert(maxMotion >= ambient),
        assert(gain >= 0),
        assert(bassFraction > 0 && bassFraction <= 1),
        _motion = ambient,
        _target = ambient,
        _slowBass = 0;

  /// 无数据 / 静音时的落点（= 改动前的观感）。
  final double ambient;

  /// 活动度 → 增益：motion 峰值 = [ambient] + [gain]。
  final double gain;

  /// 硬上限（同时受 uniforms 侧 `FlowingUniforms.maxMotion` 再钳一次）。
  final double maxMotion;

  /// 上升时间常数（拍点起势）。
  final Duration attack;

  /// 回落时间常数（比上升慢，观感更松弛）。
  final Duration release;

  /// 超过该时长没收到新频谱帧 → 目标回落 [ambient]（流断/切后台/采集停）。
  final Duration staleAfter;

  /// 「慢低音」EMA 的时间常数，用于瞬态 onset 的计算。
  final Duration slowTau;

  /// 低频带占比（与 myune 取最低 22% 频带一致）。
  final double bassFraction;

  // ── 活动度映射权重（集中在此，真机可调）────────────────────────────────
  static const double _bassWeight = 1.2;
  static const double _overallWeight = 0.5;
  static const double _onsetWeight = 1.2;

  /// 判定「包络已收敛」的阈值（motion 无量纲，1e-3 远低于可见差异）。
  static const double _settleEpsilon = 1e-3;

  double _motion;
  double _target;
  double _slowBass;
  double _bass = 0;
  double _overall = 0;
  Duration _sinceData = const Duration(days: 1);

  /// 当前应写入 `uMotion` 的值，恒在 `[ambient, maxMotion]`。
  double get motion => _motion;

  /// 当前目标值（诊断/测试用）。
  double get target => _target;

  /// 是否已收敛（供调用方决定是否还需要保持高频重绘 / 停帧）。
  bool get isSettled => (_motion - _target).abs() <= _settleEpsilon;

  /// 数据到达时调用（频谱流约 20fps）。
  ///
  /// **只登记不插值**：真正的平滑在 [advance] 里按时间推进，避免把回落
  /// 量化成「每秒 20 个台阶」。入参可以是复用缓冲，本方法当场归约、不持有。
  void setBands(List<double> bands) {
    if (bands.isEmpty) {
      _bass = 0;
      _overall = 0;
      _sinceData = Duration.zero;
      return;
    }
    final int bassCount =
        math.max(1, (bands.length * bassFraction).round());
    double bassSum = 0;
    double allSum = 0;
    for (int i = 0; i < bands.length; i++) {
      final double raw = bands[i];
      final double v = raw.isFinite ? raw.clamp(0.0, 1.0) : 0.0;
      allSum += v;
      if (i < bassCount) bassSum += v;
    }
    _bass = bassSum / bassCount;
    _overall = allSum / bands.length;
    _sinceData = Duration.zero;
  }

  /// 每个可见帧调用一次（本仓 30fps 节拍），[dt] 为真实经过时间。
  ///
  /// `dt <= 0` 直接返回（节拍抖动/重复回调不推进）。
  void advance(Duration dt) {
    final int dtUs = dt.inMicroseconds;
    if (dtUs <= 0) return;

    _sinceData += dt;

    // 1) 数据新鲜度 → 目标活动度
    if (_sinceData > staleAfter) {
      _target = ambient;
    } else {
      final double onset = math.max(0.0, _bass - _slowBass);
      final double kSlow =
          _kFor(dtUs, slowTau.inMicroseconds);
      _slowBass += (_bass - _slowBass) * kSlow;
      final double activity = (_bass * _bassWeight +
              _overall * _overallWeight +
              onset * _onsetWeight)
          .clamp(0.0, 1.0)
          .toDouble();
      _target = (ambient + gain * activity).clamp(ambient, maxMotion);
    }

    // 2) 按时间常数逼近目标（上升快、回落慢）
    final bool rising = _target > _motion;
    final int tauUs = (rising ? attack : release).inMicroseconds;
    final double k = _kFor(dtUs, tauUs);
    _motion += (_target - _motion) * k;
    if (_motion.isNaN) {
      _motion = ambient;
    } else {
      _motion = _motion.clamp(ambient, maxMotion);
    }
  }

  /// 复位到「无数据」状态（退订/页面销毁时调用）。
  ///
  /// 直接跳到 [ambient]，避免退订后还残留一个非 1.0 的值（下次进页面的
  /// 第一帧必须与改动前完全一致）。
  void resetToAmbient() {
    _motion = ambient;
    _target = ambient;
    _slowBass = 0;
    _bass = 0;
    _overall = 0;
    _sinceData = const Duration(days: 1);
  }

  /// `k = 1 - exp(-dt/τ)`；τ<=0 视为瞬时到位。
  static double _kFor(int dtUs, int tauUs) {
    if (tauUs <= 0) return 1;
    return 1 - math.exp(-dtUs / tauUs);
  }
}
