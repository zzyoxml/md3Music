import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'player_tab_strip.dart';

/// 「顶栏页签圆点」开关（设置 → 播放页样式 → 顶栏与页签），**默认关闭**。
///
/// **竖屏**：关闭时页签条留在底部，并且是改造前的**原 icon + 指示线**形态（图标认得出
/// 页，底部那条带是它自己的水平线）；顶栏中段是一条空的 Spacer。开启后底部那条整体
/// 取消，换成顶栏中央的**一排圆点**（与 ⋯ 同一条水平线，并给尾部让位）。
///
/// 底部那条消失后，控件列最下沿就从「页签条」换成了「传输行」：同一笔设计留白会让
/// 传输行直接贴住屏底（表现为「控件掉下去」）。因此本开关**必须**区分两态的底部设计
/// 留白，见 [playerBottomDesignInset]。
///
/// **宽屏**（手机横屏 / 平板）：页签条恒在右栏底部（那里顶栏没有一条可供挤进中段的
/// 水平线，尾部还要留给音质胶囊与 ⋯），**形态与竖屏底部同源** —— 关闭 = icon +
/// 指示线，开启 = 圆点，见 [playerWideTabStripVariant]。
///
/// 由 app.dart 启动引导从持久化载入；播放页的顶栏宿主、竖屏底部控制列与宽屏右栏底部
/// 各自订阅它，所以在设置页改完回到播放页就生效，不需要重进路由。
///
/// 初值与 `SettingsRepository.getTopBarTabDots()` 的默认值保持一致。
final ValueNotifier<bool> kTopBarTabDotsEnabled = ValueNotifier<bool>(false);

/// 顶栏中段该放什么：宽屏、以及「顶栏页签圆点」关闭时都是空 Spacer。
///
/// 两版宿主此前各写一遍这段判断（`!wide && kTopBarTabDotsEnabled.value`），
/// 收口到这里之后开关只有本文件读，宿主只需声明自己的圆点条。
///
/// [strip] 走懒构造：不显示圆点时连 `PlayerTabStrip` 对象都不必造。
/// 返回值可能是 `Expanded` 或 `Spacer`，两者都必须作为顶栏 `Row` 的**直接子项**
/// 出现（ParentData 组件不能隔着别的 RenderObjectWidget）。
Widget playerTopBarTabMiddle({
  required bool wide,
  required int segmentCount,
  required Widget Function() strip,
}) {
  if (wide || !kTopBarTabDotsEnabled.value) return const Spacer();
  return Expanded(
    child: PlayerTopBarTabDots(segmentCount: segmentCount, strip: strip()),
  );
}

/// 竖屏底部控制列尾部的页签条插槽：开关开启时整段不存在（它升到顶栏）。
///
/// 与 [playerTopBarTabMiddle] 是同一个开关的两半，必须同源判断 —— 只改一处就会出现
/// 「顶栏没有、底部也没有」或「两处各一排」。返回空列表时连同隙一起不留。
List<Widget> playerBottomTabSlot({
  required bool isExpanded,
  required Widget Function() strip,
}) {
  if (kTopBarTabDotsEnabled.value) return const <Widget>[];
  return <Widget>[
    // 页签条与传输键之间的间隙：车机窄面板压缩到 4，竖屏原形态是 10。
    SizedBox(height: isExpanded ? 4 : 10),
    strip(),
  ];
}

/// 竖屏底部控制列的**设计留白**（不含导航栏 inset）—— 本开关两态必须区分。
///
/// 关闭时页签条就在这一列最底部（间隙 10 + 条高 34），它自己把视觉下缘撑开了，传输行
/// 离屏底还有 44dp，留白给 10 即可；开启后页签条升到顶栏，传输行成了最底元素，同一个
/// 10 会让按钮贴住屏底，故抬到 40。
///
/// 车机窄面板（[expanded]）与竖屏同源：开启态同样 40（其历史值本就是 40），关闭态沿用
/// 16，避免白白吃掉本就局促的面板高度。
///
/// 两版宿主此前各自内联 `isExpanded ? 16 : 10` 且**不含本开关**，于是「调大→关闭态页签条
/// 悬空、调小→开启态控件贴底」反复来回（081ad6e5 的 40→10 即此）。收口到这里后，
/// 开关的形态判断与高度判断都在本文件，宿主只管订阅重建、不再各自内联这段高度。
double playerBottomDesignInset({required bool expanded}) {
  if (kTopBarTabDotsEnabled.value) return 40.0;
  return expanded ? 16.0 : 10.0;
}

/// 宽屏（手机横屏 / 平板）右栏底部页签条的形态 —— 与竖屏底部**同源**判断。
///
/// 宽屏的页签条恒留在右栏底部（那里顶栏没有一条可供挤进中段的水平线，见
/// [playerTopBarTabMiddle]），本函数只决定它长什么样子。判据与竖屏底部那条完全一致，
/// 否则同一个开关会在两种朝向下给出相反的结果：关闭（默认）= 原 icon + 指示线形态，
/// 开启 = 圆点。
PlayerTabStripVariant playerWideTabStripVariant() =>
    kTopBarTabDotsEnabled.value
        ? PlayerTabStripVariant.dots
        : PlayerTabStripVariant.icons;

/// 顶栏中段那排页签圆点的让位规则。
///
/// 只有 [kTopBarTabDotsEnabled] 开启时才会被挂进顶栏。
///
/// 用法：放在顶栏 Row 的 `Expanded` 里，于是拿到的宽度天然等于
/// 「返回键右缘 → 尾部胶囊左缘」。基准宽 `segmentCount × 48`（48 是 Android 可触达
/// 基线，视觉点径远小于它），空间富余时按基准宽**居中**。
///
/// **静止位只由「见过的最宽可用段」决定，不跟随尾部当前宽度平移** ——
/// 页签指示器是导航元素，不能被「起了个睡眠定时 / 进了个一起听房间」这类无关状态
/// 带着左右滑动（旧实现是「尾部每变宽 1dp 就整体左移 1dp」，保持与 ⋯ 的间距恒定，
/// 代价就是指示器长期在漂）。基准取「见过的最宽可用段」= 尾部收起态，尾部缩回去后
/// 基准也随之更新，所以一次运行下来静止位是稳定的。
/// 尾部真的压过来（贴到 `endGap` 那条线）时才让位：先靠左移，左移到贴住返回键
/// 还不够才把每段从 48 压下来（压缩发生在**向左**那一侧，右缘仍钉在 `endGap` 上），
/// 最低压到可用宽 —— 宁可段变小也绝不与尾部重叠，因为尾部那些是正在用的功能键，
/// 圆点只是导航。
///
/// 竖屏专用：宽屏的圆点在右栏底部。
class PlayerTopBarTabDots extends StatefulWidget {
  const PlayerTopBarTabDots({
    super.key,
    required this.segmentCount,
    required this.strip,
  });

  /// 圆点数（= 当前 tab 数），决定基准占宽。
  final int segmentCount;

  /// 真正的 `PlayerTabStrip`。分段宽度由它按自身拿到的宽度平摊，所以压缩只需要
  /// 在这里给出更窄的盒子。
  final Widget strip;

  /// 每段基准宽：Android 可触达基线。
  static const double _baseSegmentWidth = 48;

  /// 与尾部之间的最小间距：圆点右缘永远不越过这条线。
  ///
  /// 公开是因为宿主/测试要按它算让位；另两个尺寸只有本文件用得到，故留私有。
  static const double endGap = 8;

  /// 每段的触控地板（Apple 最小控件尺寸）：可用宽还放不下就退到按可用宽压缩。
  static const double _minSegmentWidth = 28;

  @override
  State<PlayerTopBarTabDots> createState() => _PlayerTopBarTabDotsState();
}

class _PlayerTopBarTabDotsState extends State<PlayerTopBarTabDots> {
  /// 见过的最宽可用段 = 尾部收起态的基准。布局期就地更新，不触发 setState
  /// （值只影响下一次布局的偏移，不需要额外一帧）。
  double? _widestBox;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final segments = widget.segmentCount;
        if (!constraints.maxWidth.isFinite) {
          return SizedBox(
            width: segments * PlayerTopBarTabDots._baseSegmentWidth,
            child: widget.strip,
          );
        }
        final box = constraints.maxWidth;
        final widest = _widestBox = math.max(_widestBox ?? 0, box);
        // 可用宽：右侧恒留 endGap，圆点因此绝不与尾部重叠
        final usable = math.max(0.0, box - PlayerTopBarTabDots.endGap);
        final base = segments * PlayerTopBarTabDots._baseSegmentWidth;
        final floor = segments * PlayerTopBarTabDots._minSegmentWidth;
        final width = math.min(
          math.min(base, math.max(floor, usable)),
          usable,
        );
        // 静止位：在「见过的最宽可用段」（= 尾部收起态）里居中。**不再**减去
        // 「尾部这段时间长出来的宽度」——那是旧的「与 ⋯ 间距恒定」口径，代价是
        // 尾部一变形圆点就整体平移（起定时器也会动）。这里只管居中，尾部真的压到
        // 8dp 那条线上时，由下面的 clamp 让它最小幅度地左移 / 压缩。
        final restingCentered = (widest - width) / 2;
        final left = math.min(
          math.max(restingCentered, 0.0),
          math.max(0.0, usable - width),
        );
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: left),
            SizedBox(width: width, child: widget.strip),
          ],
        );
      },
    );
  }
}
