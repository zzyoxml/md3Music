import 'package:material_ui/material_ui.dart';

/// 控制带皮肤：MD 主题色与 AM 白色系之间的全部差异。
///
/// 两版播放页此前在各自的 `_buildProgressBar` 里把同一套配色各写一遍，
/// 上一版改造已因这种双写漏改过一次（AM 缺 unity 分支）。控制带收敛成一份
/// 实现后，皮肤是唯一需要按版分叉的输入，故集中到这里。
class DockSkin {
  const DockSkin._({required this.amStyle});

  /// MD3 主题色皮肤（`full_player.dart`）。
  static const DockSkin md3 = DockSkin._(amStyle: false);

  /// AM 深色白色系皮肤（`full_player_am.dart`）。
  static const DockSkin am = DockSkin._(amStyle: true);

  /// 传给各组件的 `amStyle` 口径（与仓库既有参数名一致）。
  final bool amStyle;

  /// [PlayerSeekBar] 的皮肤开关：MD 为 3px 轨道 + 末端 stop indicator。
  bool get md3Style => !amStyle;

  Color seekActive(ColorScheme cs) => amStyle ? Colors.white : cs.primary;

  Color seekInactive(ColorScheme cs) => amStyle
      ? Colors.white24
      : cs.onSurfaceVariant.withValues(alpha: 0.24);

  Color seekLabel(ColorScheme cs) => amStyle ? Colors.white70 : cs.onSurfaceVariant;
}
