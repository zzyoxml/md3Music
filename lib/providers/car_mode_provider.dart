import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/repositories/settings_repository.dart';
import '../modules/player/car_mode_layout.dart';

/// 车机模式状态（设置 → 车机模式）。
///
/// 职责：
/// 1. 三个持久化项（开关 / 面板宽度占比 / 停靠位置）的内存缓存 + 通知 + 落盘；
/// 2. **面板显隐抑制计数**：设置页、登录页等全屏流程在自己的生命周期内声明
///    「我在前台时不要显示常驻播放器面板」。
///
/// 为什么抑制用计数而不是布尔：同一时刻可能有多个抑制方同时存活
/// （例如从设置页再 push 登录页，两者都活着、都要抑制），
/// 布尔值会被先释放的一方提前解除。
class CarModeProvider extends ChangeNotifier {
  CarModeProvider() {
    _load();
  }

  bool _enabled = false;
  double _panelRatio = kCarModePanelDefaultRatio;
  CarModePanelSide _panelSide = CarModePanelSide.left;
  int _panelSuppressCount = 0;

  // 用户是否已改过对应项：异步 [_load] 回来时不得覆盖用户的最新选择
  // （冷启动后立刻拖滑条 / 开开关的竞态）。
  bool _enabledTouched = false;
  bool _ratioTouched = false;
  bool _sideTouched = false;

  /// 是否已有一次通知被推迟到微任务队列（见 [_notifySafely]）。
  bool _notifyScheduled = false;

  /// 是否已 dispose（见 [_notifySafely] 里微任务的防重入判断）。
  bool _disposed = false;

  /// 车机模式开关（默认关闭）。
  bool get enabled => _enabled;

  /// 面板宽度占比（0.20~0.50，默认 0.30）。
  double get panelRatio => _panelRatio;

  /// 面板停靠位置（默认左侧）。
  CarModePanelSide get panelSide => _panelSide;

  /// 常驻面板当前是否应当渲染：车机模式开启 **且** 没有页面声明抑制。
  bool get panelVisible => _enabled && _panelSuppressCount == 0;

  /// 仅供测试：当前抑制计数。
  @visibleForTesting
  int get panelSuppressCount => _panelSuppressCount;

  /// 通知监听者。
  ///
  /// 状态变化可能发生在 build / initState / dispose 阶段 —— 页面在 initState 里
  /// 声明抑制、在 dispose 里释放，这两者都处于 widget 树的构建/收尾过程中。
  /// 此时同步 notifyListeners 会命中
  /// "setState() or markNeedsBuild() called during build" 断言
  /// （真机复现：进入设置页必现）。
  /// 统一推迟到当前帧的微任务队列里通知：字段值仍立即生效，只是重绘晚半帧。
  void _notifySafely() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      // 推迟期间可能已被 dispose（页面 dispose 时释放抑制 → 本帧结束时 provider
      // 也可能随之销毁）。ChangeNotifier 在 dispose 后调 notifyListeners 会抛断言。
      if (_disposed) return;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final repo = SettingsRepository();
      final enabled = await repo.getCarModeEnabled();
      final ratio = await repo.getCarModePanelRatio();
      final side = await repo.getCarModePanelSide();
      if (!_enabledTouched) _enabled = enabled;
      if (!_ratioTouched) _panelRatio = ratio;
      if (!_sideTouched) _panelSide = side;
      _notifySafely();
    } catch (_) {
      // 读取失败保持默认（关闭），不影响启动。
    }
  }

  /// 开关车机模式：更新内存 → 通知（主布局据此插入/移除面板）→ 持久化。
  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabledTouched = true;
    _enabled = value;
    _notifySafely();
    try {
      await SettingsRepository().setCarModeEnabled(value);
    } catch (_) {}
  }

  /// 更新面板宽度占比（越界值夹回合法区间）。
  ///
  /// [persist] = false 用于拖动过程中的实时预览：只改内存 + 通知，不落盘，
  /// 避免拖动期间高频写 SharedPreferences；松手时用 [persist] = true 落盘。
  Future<void> setPanelRatio(double ratio, {bool persist = true}) async {
    final next = ratio.clamp(kCarModePanelMinRatio, kCarModePanelMaxRatio);
    final changed = _panelRatio != next;
    if (changed) {
      _ratioTouched = true;
      _panelRatio = next;
      _notifySafely();
    }
    // persist:true 必须无条件落盘（例如拖动 preview 到 0.42 后松手再次
    // setPanelRatio(0.42)：内存里已等于 0.42，changed=false，但松手这一下
    // 仍要把值写进 SharedPreferences，否则面板占比从未被持久化）。
    if (persist) {
      try {
        await SettingsRepository().setCarModePanelRatio(next);
      } catch (_) {}
    }
  }

  /// 更新面板停靠位置（左 / 右）。
  Future<void> setPanelSide(CarModePanelSide side) async {
    if (_panelSide == side) return;
    _sideTouched = true;
    _panelSide = side;
    _notifySafely();
    try {
      await SettingsRepository().setCarModePanelSide(side);
    } catch (_) {}
  }

  /// 页面声明「我在前台时不要显示常驻播放器面板」。
  /// 必须在对应 State 的 initState 里调用一次，并在 dispose 里调用
  /// [releasePanel] 配对释放（见 CarModePanelSuppressor mixin）。
  ///
  /// 注意两个方法都必须走 [_notifySafely]：`initState` 处于 build 阶段、
  /// `dispose` 处于 widget tree 已锁定的收尾阶段，**同步** `notifyListeners()`
  /// 会分别命中 "called during build" / "called when widget tree was locked"
  /// 断言 —— 异常会中断通知，面板既不出现也不消失。
  void suppressPanel() {
    _panelSuppressCount++;
    if (_panelSuppressCount == 1) _notifySafely();
  }

  /// 释放一次抑制声明。计数不会低于 0（防御重复释放）。
  void releasePanel() {
    if (_panelSuppressCount == 0) return;
    _panelSuppressCount--;
    if (_panelSuppressCount == 0) _notifySafely();
  }
}
