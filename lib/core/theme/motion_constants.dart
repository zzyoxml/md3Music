import 'package:flutter/animation.dart';
import 'package:flutter/physics.dart';
// m3e_core 亦导出形变用的 Cubic 类，与 flutter 的 Cubic 缓动同名；本文件只用 M3EMotion。
import 'package:m3e_core/m3e_core.dart' hide Cubic;

/// M3 Expressive Motion 常量
///
/// 参考：https://m3.material.io/styles/motion/easing-and-duration
/// M3 Expressive 强调"直觉性物理动效"——弹簧物理优先于固定 cubic 曲线，
/// 让动画带有自然的过冲和回弹感。
///
/// 使用方式：
/// - `AnimatedSwitcher` 的 `switchInCurve` / `switchOutCurve` 用 `expressiveEasing`
/// - 需要弹簧物理时用 `defaultSpring` 构造 `SpringSimulation`
/// - 强调动画（引导页 / 对话框）用 `emphasizedEasing` + `emphasisDuration`；
///   播放页展开/收起走 `panelExpandEasing`（进）+ `panelCollapseEasing`（出）
class M3ExpressiveMotion {
  M3ExpressiveMotion._();

  /// 默认弹簧描述：现等价于 [kMorphSpring]（同一实例）。
  ///
  /// 数值来源已收口到 [kMorphSpring]（形变弹簧）——本名保留仅为兼容旧引用与
  /// 文档链接，物理参数不变。新代码请直接用 [kMorphSpring]。
  static SpringDescription get defaultSpring => kMorphSpring;

  /// 默认动画时长 400ms（M3 标准时长，对应 medium duration）
  static const Duration defaultDuration = Duration(milliseconds: 400);

  /// 强调动画时长 600ms（对应 long duration，用于 FullPlayer 入场等）
  static const Duration emphasisDuration = Duration(milliseconds: 600);

  /// Expressive easing：略带过冲的减速曲线
  /// 用于 tab 切换、卡片入场
  static const Curve expressiveEasing = Cubic(0.05, 0.7, 0.1, 1.0);

  /// Emphasized accelerate easing：M3 的离场曲线（起步迟、加速冲走）。
  /// 本 SDK 的 `Curves` 没有 `emphasized*` 系列，只能自建；`easeInCubic`
  /// 起步过软，收尾又撞到底，抽屉类转场用它收会有"黏在最后一段"的感觉。
  static const Curve emphasizedAccelerateEasing = Cubic(0.3, 0.0, 0.8, 0.15);

  /// Emphasized easing：M3 标准 emphasized 缓动
  /// 用于大型状态转换（FullPlayer 展开、对话框入场）
  static const Curve emphasizedEasing = Cubic(0.2, 0.0, 0, 1.0);

  /// 面板展开（落位）缓动：**对称 S 型**——起步慢、中段最快、末端慢着陆。
  ///
  /// 取代 [expressiveEasing] 用于 FullPlayer 展开：expressive（即
  /// `Curves.emphasizedDecelerate`）起步斜率约 14 倍均速，半程已完成 ~94%
  /// 位移，剩余时间是几乎静止的长尾——叠加封面/文字形变后观感为
  /// 「冲完定格、像掉帧」。
  ///
  /// **为什么上一版 `(0.35, 0.1, 0.2, 1)` 还不够**：它仍是前置冲刺型 ease-out
  /// ——t=0 斜率 0.29 倍均速、头 10% 时间就走掉 6% 位移（「慢起步」短到几乎不
  /// 存在），峰值速度在 **t≈0.26**（前三分之一就冲完），半程 0.81、3⁄4 程 0.96、
  /// 后 25% 时间只剩 3.6% 位移、末 10% 只剩 0.5%（基本贴墙静止）。用户报的
  /// 「非线性不明显」正是这个形状：慢的那两头一个都不成立，只有「冲完—静止」。
  ///
  /// 本值把这三段都做实：**强 S 型**。
  /// - 起步 t=0 斜率 0.15 倍均速，头 10% 时间只走 2.9% 位移（旧值 6.1%）；
  /// - 中段峰值 ≈2.5 倍均速落在 t≈0.41，45–55% 这段平均 1.93 倍均速
  ///   （旧值同段只有 1.07 倍——中段其实是匀速，读不出「快」）；
  /// - 末端 0.03 倍均速收尾，3⁄4 程 0.94（旧值 0.96，更早贴墙）。
  /// 半程 0.67、3⁄4 程 0.94 同时满足既有两条钉子（「半程 ∈[0.6,0.9]」「3⁄4 程
  /// ≤0.985」，见 `draggable_player_route_test.dart`），形变层的端点交接判据
  /// （严格 0/1）也不受影响。
  ///
  /// **只给「从静止起」的展开用**（点击进入播放页）。拖拽松手的续展、以及顶栏
  /// 下拉后弹回全屏，都走 [panelSettleEasing]——那两条起点是手指，慢起步会让
  /// 「跟手 → 自动」的交接出现一次明显的速度塌陷（顿挫）。
  static const Curve panelExpandEasing = Cubic(0.52, 0.08, 0.3, 0.98);

  /// 拖拽松手后的**续展 / 弹回**缓动：取值 = 上一版 [panelExpandEasing]
  /// （`Cubic(0.35, 0.1, 0.2, 1)`，前置冲刺型 ease-out），**逐值不变**。
  ///
  /// 与 [panelExpandEasing] 的分工只有一条：**本次动画的起点是不是手指**。起点
  /// 是手指（上拉未到底就松手、顶栏下拉后又弹回全屏）时，位移已由手完成了一部分，
  /// 此刻换成慢起步的 S 型等于「手指停下的那一刻画面先刹一停」——顿挫。本曲线
  /// t=0 斜率 ≈0.29 倍均速，正好落在正常甩动的松手速率量级上，交接看不出换驱动。
  ///
  /// 独立命名而不是复用 [panelExpandEasing]：两者的适用前提相反（一个从静止起、
  /// 一个从手指起），合并成一条迟早要再拆，且这里改动会牵动点击进入的观感。
  static const Curve panelSettleEasing = Cubic(0.35, 0.1, 0.2, 1.0);

  /// 面板收起缓动：轻推起步、全程平滑、末端速度趋零。
  ///
  /// 取代 [emphasizedAccelerateEasing] 用于 FullPlayer 收起：后者的适用前提是
  /// 「内容加速冲离屏幕」，但本转场收起是**封面落回迷你条槽位**的交接过程
  /// （p=0 时形变层让位给 MiniPlayer 真实封面），末端约 4.25 倍均速的冲刺
  /// 会让交接瞬间像跳帧。轻推起步（斜率 ~0.67）同时更贴合下拉手势的初速。
  static const Curve panelCollapseEasing = Cubic(0.3, 0.2, 0.3, 1.0);

  // ————————————————— 底栏动效角色语汇（批次 4b，零参数变更）—————————————————
  //
  // 收纳两套弹簧 + 两条缓动到唯一来源，赋予「反馈 vs 形变」的角色分工。
  // 硬约束：本批**只统一来源与命名，所有 stiffness / damping / tolerance /
  // 曲线值一律保持现值**（计划 §1.1 / §10）——正确性判据是「行为零变化」。
  // 角色语义一句话：反馈=轻弹确认；形变=沉稳连续。

  /// 反馈弹簧：轻、快、带可感知过冲，用于「用户点了一下」的即时确认
  /// （导航选中胶囊 `_CapsuleBounce` 的回弹）。
  ///
  /// 角色语义：**反馈=轻弹确认**。取 m3e_core 官方预设 [M3EMotion.standardPopup]
  /// （stiffness 1000 / damping 0.6，过冲 ≈9.5%）——弹得干脆、回弹幅度小，
  /// 一眼即懂「已按下」。
  ///
  /// 为何不落成同参数的 [SpringDescription]：`standardPopup` 的**真实类型是
  /// [M3EMotion]**（m3e 的弹簧规格描述符，非 SpringDescription），其
  /// `.toMotion()` 走 motor 库的 `SpringMotion`，mass / 收敛容差 / 判定由该库
  /// 内部给定。手搓 `SpringDescription.withDampingRatio(stiffness:1000,
  /// ratio:0.6)` 再自配 SpringSimulation 会改写这些未记录的默认参数 → 属行为
  /// 变更。故本出口直接收口「预设对象本身」，调用点仍写 `.toMotion()`，与改前
  /// 逐字节等价（且保持 `static const`，无额外分配）。
  static const M3EMotion kFeedbackSpring = M3EMotion.standardPopup;

  /// 形变弹簧：稳、沉、收敛干净的连续运动弹簧，用于「界面自身在变形」的连续
  /// 位移（悬浮条胶囊↔圆盘的 `_morph`）。
  ///
  /// 角色语义：**形变=沉稳连续**。采用临界阻尼（stiffness 500 / 阻尼比 1.0 /
  /// mass 1.0），避免欠阻尼过冲后被几何 clamp 反向折返，导致整条 bar 轻微抖动。
  /// 收敛判据见 [kMorphSpringTolerance]，
  /// 末端由调用方的 `snapToEnd` 精确落位。
  static final SpringDescription kMorphSpring =
      SpringDescription.withDampingRatio(
    mass: 1.0,
    stiffness: 500,
    ratio: 1.0,
  );

  /// 形变弹簧专用收敛判据（配合 [kMorphSpring] 用于悬浮条 `_morph`）。
  ///
  /// distance 0.006 对应宽度残差 ≤1.8dp（@3x 约 5px，且被调用方 `snapToEnd`
  /// 抹平），velocity 0.06 保证越过目标的瞬间（速度仍有 0.49/s）不误判为已收敛。
  ///
  /// **为何不取框架默认值 / 禁止顺手归一回默认值**：默认 1e-3/1e-3 会让控制器在
  /// 「画面早已到位」之后再空跑约 460ms（实测越过目标 340ms、停机 800ms），期间
  /// 每帧重建整条 bar 而几何零变化。放宽到 0.006/0.06 是**为省帧实测调出来的**，
  /// 停机约落在 500ms。归一回默认值 = 白增约 460ms 的帧提交。
  static const Tolerance kMorphSpringTolerance = Tolerance(
    distance: 0.006,
    velocity: 0.06,
  );

  // ————————————————— 底栏形态交叉过渡：可见形变前置完成（K1）—————————————————
  //
  // 一级常驻条 ↔ 二级悬浮胶囊的**交棒窗口**（= 转场 + 底栏收起 260ms + 2 帧容差，
  // Android 默认转场 450ms 下 ≈740ms；见 `bottom_bar_morph_overlay.dart` 的
  // `resolveMorphFlightDuration`）**不缩短** —— 它同时承担「浮层独占渲染 /
  // 覆盖整段路由转场 / 覆盖底栏收起落定」三个职责，窗口一短，胶囊真身就会在
  // 转场未结束时接管那根条、条跟着页面继续滑（前几轮修掉的"严重跳变"）。
  // 提速改的是**曲线**：窗口进度 → 可见形态进度 的映射在窗口开头的
  // `kBarFormVisibleMorphDuration`（260ms）内走完全程、之后停在端点
  // （见 `resolveVisibleBarFormProgress` 的推导）。

  /// 底栏形态交叉过渡的可见形变缓动：强 ease-out。
  ///
  /// 起步与末端速度趋零（交棒两端不与真身抢速度 —— 与
  /// `resolveProgressSpanWeight` 的选型同一前提），中段远陡于 smoothstep：
  /// 半程即完成 ≈88% 位移（smoothstep 半程才 50%），用户读到的是"一抽到位"
  /// 而不是"整段拖着变形"（用户报「底栏形态交叉过渡变形太慢」）。
  ///
  /// 取值与 [emphasizedEasing] 相同（`Cubic(0.2, 0, 0, 1)`）但**独立命名**：
  /// 形态交棒的观感后续若还要微调，不应牵动 FullPlayer 展开 / 对话框入场。
  static const Curve barFormMorphEasing = Cubic(0.2, 0.0, 0.0, 1.0);

  // ———————————————— 底栏收展（沉底/回升）：角色化曲线 —————————————————
  //
  // 底栏/常驻 MiniPlayer 的收展原先复用 FullPlayer 面板的 `panelExpandEasing` /
  // `panelCollapseEasing`。强 S 型展开曲线对一条小高度的底栏起步过于迟滞
  // （t=0 斜率 0.15 倍均速，「慢起步」在 260ms 里读起来像先顿一下再弹）。
  // 本组常量给底栏场景独立语汇：回升更柔。**时长必须维持
  // `kBottomChromeToggleDuration`（260ms）不变** —— 交棒飞行窗口的顺延预算
  // （`resolveMorphFlightDuration` = 260ms + 32ms 容差）按它校准，放宽会让
  // 真身在窗口关闭时未落定而跳变。

  /// 底栏回升（展开/浮出）缓动：平滑 ease-out，起步自然、长软着陆。
  ///
  /// 与 [panelExpandEasing]（强 S 型，为 FullPlayer 大位移从静止起调的）分工：
  /// 底栏位移小，慢起步会读成「顿一下」。本曲线 t=0 斜率 0.3 倍均速（前者的
  /// 两倍），中段平滑加速、末端长尾趋零，读作「柔和浮出落定」。
  static const Curve chromeRiseEasing = Cubic(0.3, 0.0, 0.18, 1.0);

  /// 底栏沉底（收起/让位）缓动：取值与 [panelCollapseEasing] 逐值相同。
  ///
  /// 独立命名只为收口来源：沉底（进二级页让位）与播放页面板收起虽共用过
  /// 同一条曲线，但两者观感诉求后续可能分叉（沉底要更利落），合并引用迟早再拆。
  /// 本批零参数变更。
  static const Curve chromeSinkEasing = Cubic(0.3, 0.2, 0.3, 1.0);

  /// 工具条显隐缓动：桌面全宽播放栏 `NowPlayingBar` 的 `AnimatedSize`（240ms）
  /// 收合所用的减速曲线 [Curves.easeOutCubic]。
  ///
  /// 收口原因：本曲线原先只以裸 `Curves.easeOutCubic` 散落在调用点、无 scheme
  /// 常量（探查报告 §4 标注「仓内无此 scheme 常量」）。**本批只命名，取值/曲线
  /// 保持现值**；它属通用减速曲线、非 M3 expressive 语汇，换曲线属行为变更，另议。
  static const Curve barVisibilityCurve = Curves.easeOutCubic;

  /// 切歌 `AnimatedSwitcher` 出场缓动：常驻条 `MiniPlayer` 旧内容退出所用的
  /// [Curves.easeIn]（加速冲离）。
  ///
  /// ⚠️ **已知偏离 M3 语汇**：入场所用的 [expressiveEasing] 属 M3 减速语汇，
  /// 出场这里却用通用 `easeIn`，两者不同源。本批**只命名不换值**（计划 §10 明令）；
  /// 换曲线属行为变更，另开一轮评估。
  static const Curve switcherExitCurve = Curves.easeIn;
}
