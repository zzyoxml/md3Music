import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// tv: 进度条方向键调节的**状态机**（步进 / 夹取 / debounce 合并落定）。
///
/// ## 为什么单独成一个类
///
/// `kTvBuild` 在普通构建里是 `const false`，`if (kTvBuild)` 内的接线会被 AOT
/// 树摇剔除，`flutter test` 根本执行不到那段代码（仓内先例：
/// `test/core/remote/tv_scroll_region_test.dart` 就是在断言这件事）。把「步进、
/// 夹取、debounce 合并成一次 seek」这些**与 widget 无关的判断**放在普通构建同样
/// 编译的类里，才能被单测钉住（`test/core/remote/tv_seek_stepper_test.dart`）；
/// 控件侧（`lib/widgets/player_seek_bar.dart`）只留按键接线，不写第二套判断。
///
/// ## 交互口径
///
/// - 左 / 右 = ∓[stepSeconds] 秒；dpad 的 `DpadFocusable.onDirection` 会把
///   KeyDownEvent 与 KeyRepeatEvent **都**投递过来，所以「按住不放」天然连发。
/// - 上 / 下一律**放行**（返回 false）：焦点必须出得去，否则遥控用户被困在进度条
///   上（与 `lib/core/remote/remote_slider.dart` 同一口径，AGENTS §12.4）。
/// - 每次按键只推进**画面**（[onStep]），静默 [commitDelay] 后才落定一次
///   （[onCommit]）。连续 seek 会把音频层打满，与触屏「拖动中不 seek、松手才
///   seek」是同一条纪律（见 player_seek_bar.dart 的类注释）。
/// - 时长未知（[handleDirection] 的 `durationMs <= 0`）完全不进会话：一条看不出
///   进度的轨道不该吃掉按键。
class TvSeekStepper {
  TvSeekStepper({
    required this.onBegin,
    required this.onStep,
    required this.onCommit,
    required this.onAbort,
    this.stepSeconds = defaultStepSeconds,
    this.commitDelay = defaultCommitDelay,
    this.escalation,
  });

  /// 默认单次步进（秒）：遥控调进度条的常规手感。
  static const int defaultStepSeconds = 5;

  /// 默认 debounce：连按期间只算「一次调节」，静默这么久才 seek。
  static const Duration defaultCommitDelay = Duration(milliseconds: 600);

  /// 会话第一次有效步进。控件侧在此进调节态（轨道膨胀 + 暂停/onSeekStart）。
  final VoidCallback onBegin;

  /// 每步的新目标比例（0~1）。控件侧只更新画面，**不下发 seek**。
  final ValueChanged<double> onStep;

  /// 落定：控件侧走触屏松手的同一个出口（seek 到最后一次 [onStep] 的比例）。
  final VoidCallback onCommit;

  /// 放弃会话（切歌 / chrome 淡出 / 被设为只读）：控件侧收视觉但**不 seek**。
  final VoidCallback onAbort;

  /// 单次步进的秒数。
  final int stepSeconds;

  /// 静默多久后落定（连按期间不断顺延）。
  final Duration commitDelay;

  /// 连按升级的步长序列（秒）。null = 恒用 [stepSeconds]（旧行为，默认）。
  ///
  /// 语义：会话内第 1 次有效步进取 `escalation[0]`，之后每按一次前进一档、
  /// 到末档保持；**静默超过 [commitDelay] 落定或新会话开始时回到第 0 档**。
  /// 这样「单击 = 精调 5s」「连按 = 粗调 30s」，按住连发不会被 5s 拖慢。
  final List<int>? escalation;

  /// 会话是否进行中（已步进、尚未落定或放弃）。
  bool _open = false;

  /// 会话内的目标位置（毫秒）。
  ///
  /// 必须是**会话内累加**的基准而不是每次都从 `currentMs` 起算：拖动期间控件
  /// 上报的展示位置不随按键变化，用它当基准会让连按 N 次只偏移一步的量。
  int _targetMs = 0;

  /// 连按升级的当前档位下标（仅在配置了 [escalation] 时有意义）。
  ///
  /// 每次有效步进后自增；[flush] / [cancel] / [dispose] 收摊时复位到 0，
  /// 于是「落定或新会话」都从最低档重新开始（见 [escalation] 的语义说明）。
  int _tier = 0;

  Timer? _debounce;

  /// 会话是否进行中（未落定）。
  bool get isAdjusting => _open;

  /// 处理一次方向键。返回 true＝已消费（焦点不动）；false＝放行给焦点遍历。
  bool handleDirection(
    TraversalDirection direction, {
    required int currentMs,
    required int durationMs,
  }) {
    // 上/下永远放行：进度条只吃左右，不吃上下（否则焦点出不去）。
    if (direction != TraversalDirection.left &&
        direction != TraversalDirection.right) {
      return false;
    }
    // 时长未知：不消费、不进会话，按键交回遍历。
    if (durationMs <= 0) return false;

    // 本次步进秒数：配置了 escalation（且非空）时按档位取，否则恒用 stepSeconds。
    final int seconds;
    if (escalation == null || escalation!.isEmpty) {
      seconds = stepSeconds;
    } else {
      final int tier = _open ? _tier.clamp(0, escalation!.length - 1) : 0;
      seconds = escalation![tier];
      // 本次用当前档，下一击进档；到末位保持。
      _tier = tier + 1;
    }
    final int stepMs =
        (direction == TraversalDirection.right ? seconds : -seconds) * 1000;
    // 会话内用上次的目标连加（连按不重复偏移），新会话才以当前展示位置为基准。
    final int base = _open ? _targetMs : currentMs;
    // 夹取用 math.max/min：int.clamp 的静态类型是 num，赋回 int 还要额外转换。
    _targetMs = math.max(0, math.min(durationMs, base + stepMs));

    if (!_open) {
      _open = true;
      onBegin();
    }
    onStep(_targetMs / durationMs);
    // 每次按键都顺延落定：连按（含按住连发）合并成一次 seek。
    // 到边界时目标虽不再变化，本段照常执行 → 边界仍算「已消费」，且 debounce 生效。
    _debounce?.cancel();
    _debounce = Timer(commitDelay, flush);
    return true;
  }

  /// 立即落定（OK 键 / 焦点移出）。无挂起会话时零副作用。
  void flush() {
    _debounce?.cancel();
    _debounce = null;
    _tier = 0;
    if (!_open) return;
    _open = false;
    onCommit();
  }

  /// 放弃会话：收视觉但**不 seek**。无挂起会话时零副作用。
  void cancel() {
    _debounce?.cancel();
    _debounce = null;
    _tier = 0;
    if (!_open) return;
    _open = false;
    onAbort();
  }

  /// 只取消 Timer（控件 dispose 时调用，AGENTS §10.4 第 7 条）。
  void dispose() {
    _debounce?.cancel();
    _debounce = null;
    _open = false;
    _tier = 0;
  }
}
