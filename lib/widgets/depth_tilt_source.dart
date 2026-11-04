import 'dart:async';
import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart'
    show debugPrint, visibleForTesting;
import 'package:sensors_plus/sensors_plus.dart';

import '../core/platform_capabilities.dart';

/// 鼠标指针 → 归一化倾斜目标（纯函数，便于单测）。
///
/// **符号约定**（与既有加速度计流的输出语义对齐）：
/// - 矩形中心 → `(0, 0)`；左/上边缘 → `-1`；右/下边缘 → `+1`；越界 clamp 到 ±1。
/// - 光标向右 → `dx` 为正，画面看起来像**从右侧被观察**；向下 → `dy` 为正，
///   像从下方被观察。若真机手感方向相反，只需在本函数内取反（唯一改动点），
///   宿主与 shader 侧都不用动。
///
/// [local] 必须是**封面矩形局部坐标**（宿主 MouseRegion 的 `globalToLocal` 结果），
/// 本函数不做任何 RenderBox 测量。[size] 宽或高 `<= 0`（布局未就绪/退化矩形）
/// 时返回 [Offset.zero]，避免除零产生 NaN 污染下游 shader uniform。
Offset pointerTiltTo(Offset local, Size size) {
  if (size.width <= 0 || size.height <= 0) return Offset.zero;
  final dx = (local.dx - size.width / 2) / (size.width / 2);
  final dy = (local.dy - size.height / 2) / (size.height / 2);
  return Offset(
    dx.clamp(-1.0, 1.0).toDouble(),
    dy.clamp(-1.0, 1.0).toDouble(),
  );
}

/// 3D 封面的倾斜源控制器：按平台选择「鼠标指针」或「重力传感」。
///
/// 输出类型与 [DepthCoverHost] 既有加速度计流**完全同型**
/// （`Stream<(double, double)>`，归一化 -1..1），因此
/// [DepthShaderCover] / [DepthParallaxCover] 的 `tiltStream` 零改动即可接入。
///
/// 为什么必须分平台：`sensors_plus ^7.1.0` **没有 Windows 平台实现**，
/// 在 Windows 上创建/订阅 `accelerometerEventStream` 会抛 `MissingPluginException`
/// → 走到宿主 `_onTiltError`，误报「当前设备无重力传感器，3D 封面无法跟随倾斜」。
/// 所以 Windows 分支**绝不创建传感器流**（见 [stream] 的 onListen 只在非 Windows 分支绑定）。
///
/// 帧率（AGENTS.md：跟手交互才用满帧，非跟手常驻动画必须限帧）：
/// - 本类**不持有常驻 Ticker**。鼠标静止后没有任何存活回调 → 引擎零帧请求。
/// - 写法沿用 [DepthShaderCover] 的「16ms 按需 Timer 泵 + 收敛后停摆」范式：
///   [handleHover] 只写目标值，泵一拍推出「最新值」，目标与上次出值一致即不再排拍。
/// - **不做二次平滑**：shader 侧已有 0.35 EMA（`_pumpStep`），这里再平滑会让跟手变肉。
class DepthTiltController {
  /// 与 [DepthCoverHost] `_defaultTiltStream` 同款增益：重力分量 /9.81 在常见
  /// 握持角度只有 0.1–0.35，直接用视差几乎看不出来，放大后再 clamp 到 -1..1。
  static const double _tiltGain = 2.5;

  /// 泵节拍：16ms ≈ 60fps 上限，跟手又不超出刷新率。
  static const Duration _frameInterval = Duration(milliseconds: 16);

  /// 传感器流错误上报宿主（签名与既有 `void Function(Object)` 一致，如
  /// [DepthCoverHost] 的 `_onTiltError`）。无错误时永不调用；Windows 分支根本
  /// 不产生传感器错误。
  final void Function(Object error)? onTiltError;

  StreamController<(double, double)>? _out;
  StreamSubscription<(double, double)>? _sensorSub;

  /// 鼠标分支的目标值与「上一次已推出的值」。二者相等即视为收敛 → 停摆。
  Offset _target = Offset.zero;
  Offset _emitted = Offset.zero;
  Timer? _pump;
  bool _disposed = false;

  DepthTiltController({this.onTiltError});

  /// 当前平台是否走鼠标指针源（true = Windows 桌面，false = 加速度计）。
  /// 供宿主与测试断言分支口径，与 [isWindowsDesktop] 同源
  /// （`defaultTargetPlatform`，不用 `Platform.isWindows`）。
  bool get usesPointerSource => isWindowsDesktop;

  /// 归一化倾斜流（-1..1）。创建一次复用：宿主只会 listen 一次，重复取用返回同一条流。
  ///
  /// 用 broadcast 而非单订阅：宿主 shader / 多层两条渲染路径可能先后订阅，
  /// 单订阅流在 cancel 后无法再 listen。传感器侧订阅在 onListen（首次有人听）
  /// 才建立、onCancel（最后一个人取消）即释放 —— 平面封面阶段不会白占传感器。
  Stream<(double, double)> get stream {
    if (_disposed) return const Stream<(double, double)>.empty();
    final existing = _out;
    if (existing != null) return existing.stream;
    final controller = isWindowsDesktop
        ? StreamController<(double, double)>.broadcast()
        : StreamController<(double, double)>.broadcast(
            onListen: _subscribeSensor,
            onCancel: _unsubscribeSensor,
          );
    _out = controller;
    return controller.stream;
  }

  /// 原加速度计逻辑（逐字节等价于既有 `_defaultTiltStream`）：
  /// accelerometerEventStream(uiInterval) → /9.81 * 2.5 → clamp(-1, 1)。
  void _subscribeSensor() {
    if (_disposed || _sensorSub != null) return;
    // uiInterval ≈ 60Hz：与屏幕刷新率对齐，避免高于刷新率的无效重绘。
    final mapped = accelerometerEventStream(
          samplingPeriod: SensorInterval.uiInterval,
        )
        .map((e) => (e.x / 9.81 * _tiltGain, e.y / 9.81 * _tiltGain))
        .map((v) => (
              v.$1.clamp(-1.0, 1.0).toDouble(),
              v.$2.clamp(-1.0, 1.0).toDouble(),
            ));
    _sensorSub = mapped.listen(
      (v) {
        if (!_disposed) _out?.add(v);
      },
      // 传感器不可用（NO_SENSOR 等）：转发给下游 onError（保持既有语义），
      // 同时上报宿主回调，避免静默失效。
      onError: (Object e) {
        debugPrint('[DepthCover] 倾斜源传感器错误: $e');
        _sensorSub = null; // mapped 订阅在错误分发后已自动取消
        if (!_disposed) _out?.addError(e);
        onTiltError?.call(e);
      },
    );
  }

  Future<void> _unsubscribeSensor() async {
    final sub = _sensorSub;
    _sensorSub = null;
    await sub?.cancel();
  }

  /// 封面矩形内的一次鼠标悬停采样。只写目标值，不立刻出帧（合帧交给泵）。
  ///
  /// [local] 由宿主 `MouseRegion.onHover` 的 `globalToLocal(event.position)` 得到，
  /// 本类不接受全局坐标、也不自行测量 RenderBox。
  void handleHover(Offset local, Size size) {
    if (_disposed || !isWindowsDesktop) return; // 非 Windows：加速度计是唯一信源
    final next = pointerTiltTo(local, size);
    if (next == _target) return; // 同一目标值：不重复排拍
    _target = next;
    _ensurePump();
  }

  /// 指针离开封面：目标归零。不直接推 0（那会瞬跳），而是交给泵 +
  /// shader 侧 0.35 EMA 平滑回中；回中过程出完最后几拍后自动停摆。
  void handleExit() {
    if (_disposed || !isWindowsDesktop) return;
    if (_target == Offset.zero) return; // 已在中心：零帧请求
    _target = Offset.zero;
    _ensurePump();
  }

  /// 确保有一拍在途（在途则不重复调度）；目标已到位则完全不排拍。
  void _ensurePump() {
    if (_pump != null) return;
    if (_target == _emitted) return; // 收敛：无存活回调 → 零帧请求
    _pump = Timer(_frameInterval, _pumpStep);
  }

  /// 一拍：推出**最新**目标值（不做二次平滑）；若期间目标又变了就再排一拍。
  void _pumpStep() {
    _pump = null;
    if (_disposed || _target == _emitted) return; // 收敛：不再排拍
    _emitted = _target;
    _out?.add((_emitted.dx, _emitted.dy));
    // 出值后 _target == _emitted，_ensurePump 自然停摆；
    // 下一次 handleHover 会重新排拍 —— 鼠标静止时完全不出帧。
  }

  /// 是否有在途的泵拍（供测试断言「收敛后真的停摆」）。
  @visibleForTesting
  bool get hasPendingPumpForTest => _pump != null && _pump!.isActive;

  /// 当前传感器订阅是否活跃（供测试断言 Windows 分支绝不订阅传感器）。
  @visibleForTesting
  bool get sensorSubscribedForTest => _sensorSub != null;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pump?.cancel();
    _pump = null;
    _target = Offset.zero;
    _emitted = Offset.zero;
    _out?.close();
    _out = null;
    // 传感器订阅在 broadcast onCancel 里已随最后的监听者取消，这里兜底
    // （宿主可能在无人监听时就 dispose）。
    unawaited(_unsubscribeSensor());
  }
}
