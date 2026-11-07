import 'package:flutter/widgets.dart';

import '../../core/layout/bottom_chrome_dimens.dart';

/// 底部播放区域的形态。
///
/// **为什么要显式区分形态**：展开起点几何原先只从一条全局可变量
/// （`PlayerPanelSignal.anchorTop/Bottom`）反推，而那份状态只有常驻条
/// （`MiniPlayer`）会写、悬浮胶囊端从不登记 —— 结果是胶囊点开时起点要么
/// 沿用上一次常驻条留下的陈旧矩形，要么落到"按桌面播放栏高合成"的兜底上，
/// 面板起点与用户实际点的那个控件对不上。把"这是哪一种形态、此刻的矩形是多少"
/// 随路由一起快照进来，起点几何才有唯一真值。
enum PlayerBarForm {
  /// 常驻迷你条（`MiniPlayer`）：含底部净空、底端到屏底。
  residentBar,

  /// 二级悬浮条的展开态（圆角胶囊）。
  floatingCapsule,

  /// 二级悬浮条的收起态（正圆盘）。
  floatingDisc,

  /// 形态未知：仅用于兼容没有场景来源的旧入口，消费端应退化为几何兜底。
  unknown,
}

/// 一次展开转场要用的**形态快照**（在点击 / 拖拽那一刻采集）。
///
/// **为什么是快照而不是实时查询**：展开途中页面会转屏 / 分屏 / 被系统小窗
/// resize，实时查询会把起点几何换成新视口下的值，而飞行中的封面与文字仍按旧
/// 视口插值 —— 两者一错位，转场看起来就是"控件脱开自己的槽位在飞"。快照把
/// 采集时刻的 [screenHeight] 一并记下，消费端可以据此判断视口是否已变。
///
/// [panelRect] 的口径：**可见本体**（悬浮胶囊是 64 高、左右 16dp 内缩、底端
/// 距屏底 12dp；常驻条是通栏、含底部净空、底端到屏底）。两形态必须同口径，
/// 否则「面板起点 == 用户点的那个控件」不成立。
@immutable
class PlayerMorphScene {
  const PlayerMorphScene({
    required this.panelRect,
    required this.screenHeight,
    required this.form,
    this.cornerRadius,
  });

  /// 展开起点矩形（设计像素）：顶端 = 面板上沿，底端 = 屏底。
  final Rect panelRect;

  /// 采集时刻的屏高（设计像素），用于消费端判断视口是否已变化。
  final double screenHeight;

  /// 采集时的形态。
  final PlayerBarForm form;

  /// 源形态的**外轮廓圆角**（dp）。null = 按 [form] 推导（见 [panelRadius]）。
  ///
  /// 显式可传是为了让采集端把「胶囊当前实际半径」写死进来：胶囊的半径由
  /// `BottomChromeDimens.discDiameter / 2` 推导，而圆盘态**就是**一个正圆
  /// （半径 = 直径/2，恰好等价于高度一半的圆角矩形），两者同值但语义不同，
  /// 由采集端写明比消费端猜更可靠。
  final double? cornerRadius;

  /// 面板上沿 Y（设计像素）。
  double get panelTop => panelRect.top;

  /// 面板高度（设计像素）= 屏底 − 上沿。
  double get panelHeight => panelRect.height;

  /// 本次转场的起点圆角（dp）。
  ///
  /// 缺省按形态推导：胶囊 / 圆盘 = 直径的一半（32，圆盘态即正圆），常驻条 /
  /// 未知 = 0（方角，与引入圆角之前逐像素一致）。
  double get panelRadius {
    final r = cornerRadius;
    if (r != null && r.isFinite && r >= 0) return r;
    return switch (form) {
      PlayerBarForm.floatingCapsule || PlayerBarForm.floatingDisc =>
        BottomChromeDimens.discDiameter / 2,
      PlayerBarForm.residentBar || PlayerBarForm.unknown => 0.0,
    };
  }
}
