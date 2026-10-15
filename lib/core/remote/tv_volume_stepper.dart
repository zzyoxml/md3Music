import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// tv: 音量方向键调节的**状态机**（步进 / 夹取 / debounce 合并落盘）。
///
/// ## 为什么不复用 [TvSeekStepper]（`tv_seek_stepper.dart`）
///
/// 同一条纪律（判断逻辑必须落在普通构建同样编译的类里才能被单测钉住，理由见那个
/// 类的注释），但两处语义对不上，硬套会把控件关注点漏进状态机：
/// - **单位**：进度条是「int 秒 + 时长」，音量是 0..1 的比例。`stepSeconds` 内部按
///   `*1000` 换算成毫秒，最小步长就是时长的整量级，塞不进 5% 这种小数步长。
/// - **步进是否下发**：进度条 `onStep` **绝不** seek（连续 seek 会把音频层打满），
///   音量 `onStep` **必须**实时下发（不调用户就听不出按键生效）。
/// - **落定的取值**：进度条落定是「用最后一次比例 seek」，`onCommit` 无参；音量的
///   落盘出口 `_onDragEnd(v)` 需要最终值，所以 `onCommit` 带值。
///
/// ## 交互口径
///
/// - 左 / 右 = ∓[step]（默认 5%）；dpad 的 `DpadFocusable.onDirection` 会把
///   KeyDownEvent 与 KeyRepeatEvent **都**投递过来，所以「按住不放」天然连发。
/// - 上 / 下一律**放行**（返回 false）：焦点必须出得去，否则遥控用户被困在音量条上
///   （与进度条、`remote_slider.dart` 同一口径，AGENTS §12.4）。
/// - 每次按键只推进画面与实时音量（[onStep]，`persist:false`），静默 [commitDelay]
///   后才写盘一次（[onCommit]）。debounce 挡的是 SharedPreferences 写盘，不是下发。
/// - 到达 0% / 100% 边界仍算「已消费」：走出这一行靠**上/下键**，不靠边界放行左右键
///   （否则静音键与轨道同处一行时，按左要先撞到底才能跳过去，反直觉）。
class TvVolumeStepper {
  TvVolumeStepper({
    required this.onBegin,
    required this.onStep,
    required this.onCommit,
    required this.onAbort,
    this.step = defaultStep,
    this.commitDelay = defaultCommitDelay,
  });

  /// 默认单次步进（音量比例）：全程 20 次，按住连发约两秒走满。
  static const double defaultStep = 0.05;

  /// 默认 debounce：连按期间只算「一次调节」，静默这么久才写盘。
  /// 比进度条的 600ms 短——音量实时下发很便宜，这里只合并写盘，
  /// 窗口越短，「用户已停手却还没落定就被 dispose」的丢写机会越小。
  static const Duration defaultCommitDelay = Duration(milliseconds: 400);

  /// 会话第一次有效步进。控件侧在此进入「调节中」（暂停外部回写 + 触觉）。
  final VoidCallback onBegin;

  /// 每步的新音量（0..1）。控件侧更新画面并**实时下发**，但不写盘。
  final ValueChanged<double> onStep;

  /// 落定：控件侧走触屏松手的同一个出口（写盘到最后一次 [onStep] 的值）。
  final ValueChanged<double> onCommit;

  /// 放弃会话（切独占 / 被设为只读）：收态但**不写盘**。
  final VoidCallback onAbort;

  /// 单次步进的音量比例。
  final double step;

  /// 静默多久后落定（连按期间不断顺延）。
  final Duration commitDelay;

  /// 会话是否进行中（已步进、尚未落定或放弃）。
  bool _open = false;

  /// 会话内的目标音量（0..1）。
  ///
  /// 必须是**会话内累加**的基准而不是每次都从 `current` 起算：调节期间控件展示的
  /// 值会跟着 [onStep] 变，但真机上报（`PlayerProvider.volume`）在写盘前不认这次
  /// 调节，用它当基准会让连按 N 次只偏移一步的量。
  double _target = 0;

  Timer? _debounce;

  /// 会话是否进行中（未落定）。
  bool get isAdjusting => _open;

  /// 处理一次方向键。返回 true＝已消费（焦点不动）；false＝放行给焦点遍历。
  bool handleDirection(TraversalDirection direction, {required double current}) {
    // 上/下永远放行：音量条只吃左右，不吃上下（否则焦点出不去）。
    if (direction != TraversalDirection.left &&
        direction != TraversalDirection.right) {
      return false;
    }

    final double base = _open ? _target : current.clamp(0.0, 1.0);
    final double delta = direction == TraversalDirection.right ? step : -step;
    // 夹取用 math.max/min：double.clamp 的静态类型是 num，赋回 double 还要额外转换。
    _target = math.max(0.0, math.min(1.0, base + delta));

    if (!_open) {
      _open = true;
      onBegin();
    }
    onStep(_target);
    // 每次按键都顺延落定：连按（含按住连发）合并成一次写盘。
    // 到边界时目标虽不再变化，本段照常执行 → 边界仍算「已消费」，且 debounce 生效。
    _debounce?.cancel();
    _debounce = Timer(commitDelay, flush);
    return true;
  }

  /// 立即落定（OK 键 / 焦点移出）。无挂起会话时零副作用。
  void flush() {
    _debounce?.cancel();
    _debounce = null;
    if (!_open) return;
    _open = false;
    onCommit(_target);
  }

  /// 放弃会话：收态但**不写盘**。无挂起会话时零副作用。
  void cancel() {
    _debounce?.cancel();
    _debounce = null;
    if (!_open) return;
    _open = false;
    onAbort();
  }

  /// 只取消 Timer（控件 dispose 时调用，AGENTS §10.4 第 7 条）。
  void dispose() {
    _debounce?.cancel();
    _debounce = null;
    _open = false;
  }
}
