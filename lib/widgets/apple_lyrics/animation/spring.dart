import 'dart:math';

/// 弹簧物理动画引擎
///
/// 参照 AMLL 项目 packages/core/src/utils/spring.ts 实现，
/// 提供临界阻尼、欠阻尼、过阻尼三种模式的解析求解器。
///
/// 物理方程: m * x'' + c * x' + k * (x - target) = 0
/// 其中 m=mass, c=damping, k=stiffness。
class Spring {
  /// 弹簧质量
  double _mass;

  /// 阻尼系数
  double _damping;

  /// 刚度
  double _stiffness;

  /// 当前位移
  double _position;

  /// 当前速度（一阶导数）
  double _velocity;

  /// 目标位移
  double _target;

  /// 求解器起点位移（上次 setTarget/setParams 时的位置）
  double _fromPosition;

  /// 求解器起点速度
  double _fromVelocity;

  /// 自上次 setTarget/setParams 起累积的时间（秒）
  double _elapsedTime;

  /// 内部稳定标志：为 true 时 tick 直接跳过计算
  bool _settled;

  /// 稳定阈值：位移、速度、加速度均小于此值时认为已稳定
  static const double _settleThreshold = 0.01;

  /// 子步长上限（秒），dt 过大时按此步长子步进
  static const double _maxStepTime = 0.016;

  Spring({
    double mass = 1,
    double damping = 20,
    double stiffness = 100,
    double initialPosition = 0,
  })  : _mass = mass,
        _damping = damping,
        _stiffness = stiffness,
        _position = initialPosition,
        _target = initialPosition,
        _velocity = 0,
        _fromPosition = initialPosition,
        _fromVelocity = 0,
        _elapsedTime = 0,
        _settled = true;

  /// 当前位移
  double get position => _position;

  /// 当前速度
  double get velocity => _velocity;

  /// 当前目标位移
  double get target => _target;

  /// 当前加速度（二阶导数），由弹簧方程直接给出: a = (-k*x - c*v) / m
  double get acceleration {
    final double displacement = _position - _target;
    return (-_stiffness * displacement - _damping * _velocity) / _mass;
  }

  /// 是否已稳定：位移、速度、加速度均 < 0.01
  bool get isSettled {
    if (!_settled) return false;
    return (_position - _target).abs() < _settleThreshold &&
        _velocity.abs() < _settleThreshold &&
        acceleration.abs() < _settleThreshold;
  }

  /// 设置当前位移与速度（瞬移到指定状态，目标=当前位置）
  void setPosition(double position, double velocity) {
    _position = position;
    _velocity = velocity;
    _target = position;
    _fromPosition = position;
    _fromVelocity = velocity;
    _elapsedTime = 0;
    // 若有初速度，弹簧需运动以耗散速度；否则视为已稳定
    _settled = velocity.abs() < 1e-9;
  }

  /// 设置目标位移，从当前状态继续弹簧运动
  void setTarget(double target) {
    // 目标未变且已稳定，无需重新求解
    if ((target - _target).abs() < 1e-9 && _settled) return;
    _target = target;
    _resetSolver();
  }

  /// 动态调整弹簧参数，从当前状态重新求解
  void setParams({double? mass, double? damping, double? stiffness}) {
    if (mass != null) _mass = mass;
    if (damping != null) _damping = damping;
    if (stiffness != null) _stiffness = stiffness;
    // 运动中改变参数需要重新初始化求解器
    if (!_settled) {
      _resetSolver();
    }
  }

  /// 重置到 0 位移、0 速度、0 目标
  void reset() {
    _position = 0;
    _velocity = 0;
    _target = 0;
    _fromPosition = 0;
    _fromVelocity = 0;
    _elapsedTime = 0;
    _settled = true;
  }

  /// 推进 dt 秒，更新位置与速度
  void tick(double dt) {
    if (_settled) return;
    if (dt <= 0) return;

    // 子步进：dt 过大时按固定步长分步求解，避免数值发散
    // 并在每步后检查稳定条件，提前停止
    double remaining = dt;
    while (remaining > 0 && !_settled) {
      final double step = remaining > _maxStepTime ? _maxStepTime : remaining;
      _elapsedTime += step;
      _solveAt(_elapsedTime);
      remaining -= step;

      // 到达阈值：位移、速度、加速度均 < 0.01 时认为已稳定，吸附到目标
      if ((_position - _target).abs() < _settleThreshold &&
          _velocity.abs() < _settleThreshold &&
          acceleration.abs() < _settleThreshold) {
        _position = _target;
        _velocity = 0;
        _settled = true;
      }
    }
  }

  /// 重置求解器：以当前状态作为新的起点
  void _resetSolver() {
    _fromPosition = _position;
    _fromVelocity = _velocity;
    _elapsedTime = 0;
    _settled = false;
  }

  /// 在累积时间 t 处解析求解位置与速度
  void _solveAt(double t) {
    final double from = _fromPosition;
    final double vel = _fromVelocity;
    final double to = _target;
    final double m = _mass;
    final double c = _damping;
    final double k = _stiffness;

    final double delta = to - from;
    // 判别式: 4*m*k - c²
    final double discriminant = 4 * m * k - c * c;

    // 已在目标位置且无初速度，直接吸附
    if (delta.abs() < 1e-12 && vel.abs() < 1e-12) {
      _position = to;
      _velocity = 0;
      return;
    }

    if (discriminant.abs() < 1e-9) {
      // 临界阻尼：damping == 2*sqrt(stiffness*mass)
      // x(t) = to - (delta + t*leftover) * e^(t*angular_frequency)
      // angular_frequency = -sqrt(k/m), leftover = -af*delta - vel
      final double af = sqrt(k / m);
      final double dm = -af; // 即 angular_frequency
      final double leftover = -dm * delta - vel;
      final double e = exp(dm * t);
      _position = to - (delta + t * leftover) * e;
      // 速度解析求导: x'(t) = -e * (leftover + (delta + t*leftover) * dm)
      _velocity = -e * (leftover + (delta + t * leftover) * dm);
    } else if (discriminant > 0) {
      // 欠阻尼：damping < 2*sqrt(stiffness*mass)
      // x(t) = to - e^(dm*t) * (delta*cos(dfm*t) + leftover*sin(dfm*t))
      // damping_frequency = sqrt(4*m*k - c²)
      // dfm = 0.5 * damping_frequency / mass （阻尼自然角频率）
      // dm = -0.5 * damping / mass （衰减率）
      // leftover = (c*delta - 2*m*vel) / damping_frequency
      final double dampingFrequency = sqrt(discriminant);
      final double dfm = 0.5 * dampingFrequency / m;
      final double dm = -0.5 * c / m;
      final double leftover = (c * delta - 2 * m * vel) / dampingFrequency;
      final double e = exp(dm * t);
      final double cosT = cos(dfm * t);
      final double sinT = sin(dfm * t);
      _position = to - e * (delta * cosT + leftover * sinT);
      // 速度解析求导
      _velocity = -e *
          (dm * (delta * cosT + leftover * sinT) +
              dfm * (-delta * sinT + leftover * cosT));
    } else {
      // 过阻尼：damping > 2*sqrt(stiffness*mass)
      // 使用指数形式避免 cosh/sinh 在大 t 下溢出
      // 两根: r1 = dm + dfm, r2 = dm - dfm（均小于 0）
      // 通解: u(t) = A*e^(r1*t) + B*e^(r2*t)，其中 u = x - to
      // 初始条件: A + B = -delta, r1*A + r2*B = vel
      final double dampingFrequency = sqrt(-discriminant); // sqrt(c² - 4*m*k)
      final double dfm = 0.5 * dampingFrequency / m;
      final double dm = -0.5 * c / m;
      final double r1 = dm + dfm; // 较小的负根（绝对值小，衰减慢）
      final double r2 = dm - dfm; // 较大的负根（绝对值大，衰减快）
      // 由初始条件解线性方程组
      final double a = (vel + r2 * delta) / (2 * dfm);
      final double b = -delta - a;
      final double er1 = exp(r1 * t);
      final double er2 = exp(r2 * t);
      _position = to + a * er1 + b * er2;
      _velocity = a * r1 * er1 + b * r2 * er2;
    }
  }
}
