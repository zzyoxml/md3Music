import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';

/// tv: 播放页传输行两端次要动作（播放模式 / 收藏）的遥控单停点包装。
///
/// ## 为什么要有它
///
/// 原实现是裸 `InkWell`（`full_player.dart` 的 `_buildEdgeAction`）。按
/// `TvCardFocus` 类注释记录的真机结论：裸 `InkWell` 无聚焦反馈、dpad 的
/// `onSelect` 链路也不归它管，TV 上表现为「焦点落不下去」——播放模式与
/// 收藏这两个高频入口因此在 TV 上不可用（2026-10-18 逐行审计发现）。
///
/// 本组件把「48dp 圆形触达区 + 图标」与单停点合成一处，**不带** kTvBuild
/// 门控（AGENTS §12 惯例：可测组件不依赖编译期旗标），由调用方在 TV 分支使用；
/// 非 TV 分支继续走原 `InkWell`，触屏行为零变化。
///
/// `onSelect == null` 时不包 `DpadFocusable`（不制造死停点，同
/// `tv_card_focus.dart:57` 口径），只返回 48×48 命中盒本体。
class TvPlayerEdgeAction extends StatelessWidget {
  const TvPlayerEdgeAction({
    super.key,
    required this.icon,
    required this.color,
    this.onSelect,
    this.onLongSelect,
    this.autofocus = false,
    this.debugLabel,
  });

  /// 图标（与父级 `_buildEdgeAction` 传入的一致）。
  final IconData icon;
  final Color color;

  final VoidCallback? onSelect;
  final VoidCallback? onLongSelect;
  final bool autofocus;
  final String? debugLabel;

  @override
  Widget build(BuildContext context) {
    // 48dp 圆形触达区（口径同父级原实现，AGENTS §12.5 命中区下限）。
    final body = SizedBox(
      width: 48,
      height: 48,
      child: Center(child: Icon(icon, size: 24, color: color)),
    );
    if (onSelect == null && onLongSelect == null) return body;
    return DpadFocusable(
      autofocus: autofocus,
      debugLabel: debugLabel,
      onSelect: onSelect,
      onLongSelect: onLongSelect,
      child: body,
    );
  }
}
