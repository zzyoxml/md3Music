import 'package:flutter/widgets.dart';

import 'full_player_route.dart';

/// 一份播放页实例在当前帧的身份。
///
/// **为什么需要它**：`FullPlayer` / `AmStyleFullPlayer` 不止挂在路由里，至少有三个地方会挂载它，
/// 而它们对「真机副作用」的责任完全不同：频谱采集与麦克风权限、歌词取词与常驻监听、
/// 歌词 Ticker、触感反馈的「在播放页」标志。原先只用一条
/// `ModalRoute.of(context) == null && playerDragActive.value` 来区分「拖拽覆盖层」，
/// 再多一种身份（常驻预建，见 [PlayerPageRole.dormant]）就不够用，也不该继续往那条布尔式里塞。
enum PlayerPageRole {
  /// 由路由持有的那一份：用户可见，且**负责**全部真机副作用（频谱启动/麦克风、取词、歌词驱动…）。
  /// 也是无 scope 时的兜底身份，车机 dock（`car_mode_panel.dart` 的 `dockMode: true`）走这一路。
  route,

  /// 拖拽期间的跟手覆盖层那一份：用户可见，但**不负责**副作用——采集由即将接管的路由持有，
  /// 覆盖层重复注册会双开频谱、重复申请麦克风权限。
  dragOverlay,

  /// 常驻预建、此刻不在用户眼前：既不可见也不负责副作用。
  /// 取词、歌词 Ticker / eco 驱动、频谱、触感标志都必须为它让路
  /// （`Offstage` 不会触发 `TickerMode` 静音，靠隐藏是压不住常驻动画的，见 AGENTS.md 第 10 节）。
  dormant;

  /// 本上下文被显式标成的身份；没被标过时为 null。
  static PlayerPageRole? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<PlayerPageRoleScope>()
      ?.role;

  /// 当前身份。**显式 scope 优先**；没有 scope 时退回改动前的推导，
  /// 以保证车机 dock 等既有挂载点的行为一字不变。
  static PlayerPageRole of(BuildContext context) {
    final explicit = maybeOf(context);
    if (explicit != null) return explicit;
    final insideRoute = ModalRoute.of(context) != null;
    if (!insideRoute && playerDragActive.value) return PlayerPageRole.dragOverlay;
    return PlayerPageRole.route;
  }
}

/// 把某棵播放页子树的身份写明给下游，替代「靠 ModalRoute 是否存在反推」的隐式判断。
class PlayerPageRoleScope extends InheritedWidget {
  const PlayerPageRoleScope({
    super.key,
    required this.role,
    required super.child,
  });

  final PlayerPageRole role;

  @override
  bool updateShouldNotify(PlayerPageRoleScope oldWidget) =>
      oldWidget.role != role;
}
