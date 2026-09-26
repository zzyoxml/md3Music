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
  bool _autoScreenEnabled = false;
  double _panelRatio = kCarModePanelDefaultRatio;
  CarModePanelSide _panelSide = CarModePanelSide.left;
  double _dockClearanceDp = kCarModeBottomDockClearance;
  int _panelSuppressCount = 0;

  /// 当前屏幕是否判定为「车机屏」（短边/长边 ≥ 0.55，见 [isCarLikeScreen]）。
  ///
  /// 由 UI 层在 build 阶段按 MediaQuery 尺寸计算并注入（见
  /// [updateScreenMetrics]）。非持久化：每次冷启动先按 false 走，等首帧
  /// 拿到真实屏幕尺寸后再校正，不影响既有逻辑。
  bool _screenIsCar = false;

  /// 当前屏幕是否「竖屏或接近方屏」（见 [isPortraitOrSquareScreen]）。
  /// 命中则面板置于底部。同样由 UI 层注入，非持久化。
  bool _screenPortraitOrSquare = false;

  // 用户是否已改过对应项：异步 [_load] 回来时不得覆盖用户的最新选择
  // （冷启动后立刻拖滑条 / 开开关的竞态）。
  bool _enabledTouched = false;
  bool _autoScreenTouched = false;
  bool _ratioTouched = false;
  bool _sideTouched = false;

  /// 是否已有一次通知被推迟到微任务队列（见 [_notifySafely]）。
  bool _notifyScheduled = false;

  /// 是否已 dispose（见 [_notifySafely] 里微任务的防重入判断）。
  bool _disposed = false;

  /// 车机模式**强制开关**（默认关闭）。开启则无论屏幕类型都启动。
  bool get enabled => _enabled;

  /// 「检测到车机屏幕时自动开启」开关（默认关闭）。独立于 [enabled]。
  bool get autoScreenEnabled => _autoScreenEnabled;

  /// 面板宽度占比（0.20~0.50，默认 0.30）。
  double get panelRatio => _panelRatio;

  /// 面板停靠位置（默认左侧）。
  CarModePanelSide get panelSide => _panelSide;

  /// 底部面板的 dock 避让高度（dp）。见
  /// [SettingsRepository.getCarModeDockClearance]。
  double get dockClearanceDp => _dockClearanceDp;

  Future<void> setDockClearance(double value, {bool persist = true}) async {
    final clamped = value.isFinite
        ? value.clamp(0.0, kCarModeDockClearanceMax)
        : kCarModeBottomDockClearance;
    if (clamped == _dockClearanceDp) return;
    _dockClearanceDp = clamped;
    _notifySafely();
    // persist:false 用于拖动过程实时预览（与 setPanelRatio 同一模式），
    // 避免拖动期间高频写 SharedPreferences；松手时 persist:true 落盘。
    if (persist) {
      await SettingsRepository().setCarModeDockClearance(clamped);
    }
  }

  /// 当前是否判定为车机屏（由 UI 注入，见 [updateScreenMetrics]）。
  bool get screenIsCar => _screenIsCar;

  /// 当前是否「竖屏或接近方屏」（由 UI 注入）。
  bool get screenPortraitOrSquare => _screenPortraitOrSquare;

  /// 车机模式当前是否**有效**：强制开关开启，**或**（自动检测开启且屏幕
  /// 命中车机屏）。两者相互独立，任一命中即生效。
  bool get active => _enabled || (_autoScreenEnabled && _screenIsCar);

  /// 常驻面板当前是否应当渲染：车机模式有效 **且** 没有页面声明抑制。
  bool get panelVisible => active && _panelSuppressCount == 0;

  /// 当前面板是否应**置于底部**（横贯全宽、高度占比可调，忽略 [panelSide]）。
  ///
  /// 三条件同时成立才走底部：车机模式有效、屏幕命中车机屏、且为竖屏/近方屏。
  /// 逐项原因：
  ///   * 车机模式未启用（`active` 为 false）时面板不渲染，不应误判底部；
  ///   * `screenIsCar` 排除普通竖屏手机（长比 ≈0.46，未达 0.55 阈值）——
  ///     否则竖屏手机强制开启车机模式也会被错误放到底部；
  ///   * `screenPortraitOrSquare` 排除横屏 16:9 车机（长比 0.5625 满足车机
  ///     判定但非竖屏非方屏）——这类屏幕仍保持左右停靠。
  /// 命中示例：方屏 880×860、竖屏车机（如 1080×1920）。
  bool get useBottomLayout =>
      active && screenIsCar && screenPortraitOrSquare;

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
      final autoScreen = await repo.getCarModeAutoScreenEnabled();
      final ratio = await repo.getCarModePanelRatio();
      final side = await repo.getCarModePanelSide();
      final clearance = await repo.getCarModeDockClearance();
      if (!_enabledTouched) _enabled = enabled;
      if (!_autoScreenTouched) _autoScreenEnabled = autoScreen;
      if (!_ratioTouched) _panelRatio = ratio;
      if (!_sideTouched) _panelSide = side;
      _dockClearanceDp = clearance;
      _notifySafely();
    } catch (_) {
      // 读取失败保持默认（关闭），不影响启动。
    }
  }

  /// UI 层在 build 阶段按 MediaQuery 尺寸计算并注入两个屏幕判定：
  /// 是否车机屏（[isCarLikeScreen]）、是否竖屏/近方屏（[isPortraitOrSquareScreen]）。
  /// 纯运行时状态，不落盘；只在实际变化时通知，避免尺寸抖动引起无效重建。
  void updateScreenMetrics({
    required bool isCar,
    required bool portraitOrSquare,
  }) {
    if (_screenIsCar == isCar && _screenPortraitOrSquare == portraitOrSquare) {
      return;
    }
    _screenIsCar = isCar;
    _screenPortraitOrSquare = portraitOrSquare;
    _notifySafely();
  }

  /// 开关车机模式（强制）：更新内存 → 通知（主布局据此插入/移除面板）→ 持久化。
  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabledTouched = true;
    _enabled = value;
    _notifySafely();
    try {
      await SettingsRepository().setCarModeEnabled(value);
    } catch (_) {}
  }

  /// 开关「检测到车机屏幕时自动开启」。
  Future<void> setAutoScreenEnabled(bool value) async {
    if (_autoScreenEnabled == value) return;
    _autoScreenTouched = true;
    _autoScreenEnabled = value;
    _notifySafely();
    try {
      await SettingsRepository().setCarModeAutoScreenEnabled(value);
    } catch (_) {}
  }

  /// 更新面板宽度占比（越界值夹回合法区间）。
  ///
  /// 下限按当前布局动态决定：底部布局（竖屏/近方屏车机，[useBottomLayout]）
  /// 用 [kCarModePanelMinRatioBottom]（10%），侧边布局用
  /// [kCarModePanelMinRatio]（20%）。
  ///
  /// [persist] = false 用于拖动过程中的实时预览：只改内存 + 通知，不落盘，
  /// 避免拖动期间高频写 SharedPreferences；松手时用 [persist] = true 落盘。
  Future<void> setPanelRatio(double ratio, {bool persist = true}) async {
    final minRatio = useBottomLayout
        ? kCarModePanelMinRatioBottom
        : kCarModePanelMinRatio;
    final next = ratio.clamp(minRatio, kCarModePanelMaxRatio);
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
