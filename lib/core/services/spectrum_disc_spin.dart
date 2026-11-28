import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'player_frame_driver.dart';

/// 频谱圆盘封面（style 0/1）的**共享旋转相位**。
///
/// ## 为什么要有它
///
/// 圆盘封面在改动前由每个 [SpectrumArtwork] **各持一个** `AnimationController`
/// 步进（见 `widgets/spectrum_artwork.dart`）。这在「封面形变要落到圆盘上」之后
/// 立刻变成缺陷：
///
/// 1. **落位帧角度对不上**：MiniPlayer → FullPlayer 的飞行封面要在 `p=1` 那一帧
///    与真身圆盘逐角度重合，否则封面（唱片）会在交接瞬间"跳一格"。而真身自己在
///    飞行期间被 `PlayerCoverSlot` 的 `Opacity(0)` 让位隐藏 —— `RenderOpacity`
///    在 alpha=0 时整棵子树不 paint，**没有可靠的逐帧绘画时机**把角度上报给
///    形变层（这正是 `PlayerCoverMorphBus` 要用「重测闭包」绕开 paint 的原因）；
/// 2. **多实例相位互不相同**：上滑跟手展开时，拖拽覆盖层里是**另一个**
///    `FullPlayer` 实例，它与被压在下面的路由实例各自持一个控制器、相位不同。
///    谁上报都会抖动，而交接时换人又会跳一格。
///
/// 唱片"在转"是**播放状态的事实**，不是某个 widget 实例的私有状态。把它收进
/// 进程级单例后：所有圆盘实例天然同相（形变层直接读相位即可），交接帧零残差，
/// 且多实例**共用同一个** 60fps 节拍（不再各自步进控制器）。
///
/// ## 生命周期与省电
///
/// - 消费者（[SpectrumArtwork]）在「播放中 **且** 未被 `TickerMode` / 后台挂起」
///   时 [attach]，其余情况（含暂停、退后台、被不透明路由盖住）立刻 [detach] ——
///   与改动前"只在播放时绑定旋转驱动"的口径完全一致；
/// - 相位只在**有消费者**且播放时推进：最后一个消费者 detach 后相位冻结（暂停
///   的圆盘必须静止，否则恢复播放会看到唱片瞬移）；
/// - 节拍挂在 [PlayerFrameDriver] 上：全部圆盘实例（含形变重叠实例）共用同一个
///   `Timer.periodic(16ms)`，不新增任何帧生产（AGENTS §10.4 第 5 条）；
/// - 用**实测 dt** 推进（AGENTS §10.4 第 8 条），后台回来后的一次大 dt 被
///   [maxStep] 钳制，不会让唱片一次性转过一大截。
///
/// ## 与 MiniPlayer 的关系
///
/// 悬浮胶囊 / 悬浮圆盘那两套底部形态有自己的自转角（`secondary_mini_player.dart`
/// 的 `_discAngle`，转速随收缩进度调制），**不接**本相位：它们由
/// `PlayerCoverMorphBus.publishMini` 的 `rotation` 上报给形变层作**起点**，形变层
/// 从这里取**终点**，两者按进度连续插值（见 `player_cover_morph_layer.dart`）。
class SpectrumDiscSpin {
  SpectrumDiscSpin._();

  static final SpectrumDiscSpin instance = SpectrumDiscSpin._();

  /// 转一圈的时长（默认 8s，慢速防眩晕）。
  ///
  /// 与改动前 `SpectrumArtwork.rotationDuration` 的缺省值一致。刻意做成常量而
  /// 不是构造参数：相位是进程级共享的，两个实例给出不同圈速时没有正确解。
  static const Duration turn = Duration(seconds: 8);

  /// 单次推进允许的最大 dt。
  ///
  /// 后台/长停后 `Stopwatch` 会累积出几百毫秒甚至更多；不钳制的话，回前台第一
  /// 个 tick 会让唱片一次性转过几十度（观感是"跳一下"）。圆盘是装饰性旋转，
  /// 丢掉这几百毫秒的相位没有可感知代价。
  static const Duration maxStep = Duration(milliseconds: 64);

  static const double _tau = 2 * math.pi;

  /// 当前相位（弧度，恒在 `[0, 2π)`）。
  ///
  /// 圆盘封面与形变层都读它。推进时**只在值真的变化时**赋值，避免监听方空转。
  final ValueNotifier<double> angle = ValueNotifier<double>(0.0);

  /// 已登记的消费者（[SpectrumArtwork] 的 State 实例）。
  ///
  /// 用 `Set` 而不是计数：同一实例重复 attach/detach 必须幂等（`didChangeDependencies`
  /// 会反复走 `_syncFrameDriverBindings`），计数会一路涨到失控。
  final Set<Object> _consumers = <Object>{};

  bool _driverBound = false;

  /// 推进基线与累计弧度。`Stopwatch` 在每次"开始转"时重置，累计弧度**不清**
  /// —— 暂停恢复要接着上一圈的角度转，而不是回到 0。
  final Stopwatch _clock = Stopwatch();
  int _lastTickUs = 0;
  double _radians = 0.0;

  /// 是否正在产帧（有消费者且未被挂起）。诊断与测试用。
  bool get isSpinning => _driverBound;

  /// 已登记消费者数量（诊断与测试用）。
  int get consumerCount => _consumers.length;

  /// 登记一个消费者；从「无人消费」转为「有人消费」时才开始步进。
  void attach(Object consumer) {
    if (!_consumers.add(consumer)) return;
    if (_consumers.length != 1) return;
    _startClock();
  }

  /// 摘掉一个消费者；最后一个走掉时停表并冻结相位。
  void detach(Object consumer) {
    if (!_consumers.remove(consumer)) return;
    if (_consumers.isNotEmpty) return;
    _stopClock();
  }

  /// 开始步进：重置时间基线（否则第一次 dt 是"到现在为止的全部时间"）。
  void _startClock() {
    _clock
      ..reset()
      ..start();
    _lastTickUs = 0;
    if (_driverBound) return;
    PlayerFrameDriver.instance.addListener(_onTick);
    _driverBound = true;
  }

  /// 停表并摘掉节拍（不留空转订阅）。
  void _stopClock() {
    _clock.stop();
    if (!_driverBound) return;
    PlayerFrameDriver.instance.removeListener(_onTick);
    _driverBound = false;
  }

  void _onTick() {
    final int nowUs = _clock.elapsedMicroseconds;
    final int dtUs = nowUs - _lastTickUs;
    _lastTickUs = nowUs;
    if (dtUs <= 0) return;
    _advance(Duration(microseconds: dtUs));
  }

  /// 按真实 dt 推进相位并通知监听方。
  void _advance(Duration dt) {
    final int us = dt.inMicroseconds;
    if (us <= 0) return;
    final int stepUs = us > maxStep.inMicroseconds ? maxStep.inMicroseconds : us;
    _radians += _tau * stepUs / turn.inMicroseconds;
    final double wrapped = _radians % _tau;
    if (wrapped == angle.value) return;
    angle.value = wrapped;
  }

  /// 测试专用：直接推进相位，不依赖真实 [Timer]。
  @visibleForTesting
  void debugAdvance(Duration dt) => _advance(dt);

  /// 测试专用：把相位钉到指定值（形变层的落位角度断言用）。
  @visibleForTesting
  void debugSetAngle(double radians) {
    if (!radians.isFinite) return;
    final double wrapped = radians % _tau;
    _radians = wrapped;
    if (angle.value != wrapped) angle.value = wrapped;
  }

  /// 测试专用：清空消费者与相位（连同节拍订阅），避免用例间互相污染。
  @visibleForTesting
  void reset() {
    _consumers.clear();
    _stopClock();
    _lastTickUs = 0;
    _radians = 0.0;
    angle.value = 0.0;
  }
}
