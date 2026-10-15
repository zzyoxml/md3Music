import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/widgets/app_background.dart';
import '../../providers/theme_provider.dart';
import 'player_cover_morph.dart';

/// 展开面板在屏幕上的几何（**设计像素**，与 `MediaQuery` 屏高、
/// [PlayerCoverMorphBus.pageOffset] 同处一个坐标系）。
typedef PlayerPanelGeometry = ({double top, double height});

/// 下沿行程的放大系数。
///
/// `1.0` = 精确双向：下沿从迷你条底端线性走到屏幕底，导航栏在手势末段才被盖完。
/// 调到 `1.5` 则下沿提前扫完导航栏、之后等价于纯上移的 sheet（观感上导航栏
/// "赖着不走"时调它）。只影响下沿，不影响上沿的 1:1 跟手。
const double kPlayerPanelBottomBoost = 1.0;

/// 面板内容淡入所对应的行程占比：手指走过屏高的这个比例后，内容完全不透明。
///
/// 与 `full_player_route.dart` 的 [kPlayerExpandDistanceRatio] 必须保持相等
/// （松手展开判定用的是后者），`player_panel_geometry_test.dart` 有一致性断言。
const double kPlayerPanelFadeSpanRatio = 0.2;

/// 迷你条 → 全屏的**双向展开**几何。
///
/// - [progress]：0 = 迷你条，1 = 全屏（就是全局 `playerExpansion`）；
/// - [origin]：迷你条顶端 Y（设计像素）；
/// - [miniHeight]：迷你条高度（设计像素）；
/// - [screenHeight]：屏幕高（设计像素）。
///
/// 映射：
/// - `top = origin*(1-p)` —— **与手指 1:1 跟手**（`p` 由上滑距离 / origin 驱动），
///   且与整屏下移时代（`playerPageOffset` 的拖拽分支）逐帧一致；
/// - `bottom = origin + miniHeight + (屏高 - origin - miniHeight) * boost * p`
///   —— 向下匀速拓展，p=1 时到屏幕底；
/// - `height = bottom - top`。
///
/// 两个不变量：
/// - `p=0` → `[origin, origin+miniHeight]`，**恰好等于迷你条矩形**（导航栏完整可见）；
/// - `p=1` → `[0, screenHeight]`，铺满全屏。
///
/// 退化情形（二级路由里迷你条自身贴屏幕底，即 `origin+miniHeight == 屏高`）
/// 无需特判：`bottom` 恒等于屏高，面板只向上长。
///
/// **实现陷阱**：`height` 只能由 `bottom - top` 得到，或写成
/// `miniHeight + (screenHeight - miniHeight) * p`。若误写成
/// `miniHeight + (screenHeight - origin - miniHeight) * p`，退化情形下
/// p=1 时面板只剩迷你条那么高（整页只剩顶部一条），是完全不可见的错法。
/// 把面板锚点（迷你条顶端）钳进合法区间 `[0, screenHeight]`。
///
/// **几何的 top、页面的 dy、淡入跨度三处必须共用这一个钳制。**
/// 只要有一处用未钳制的 origin，`top == dy` 这条「窗口上沿 == 页面上沿」的
/// 不变量就会断 —— 典型触发是转屏 / 分屏 / HyperOS 小窗 resize 发生在手势
/// 途中：锚点是**手势开始时捕获的快照**（转屏前的竖屏值，可能远大于当下
/// 屏高），而屏高已是新的。此时页面被整体推到窗口之外，面板整块透明，
/// 且那块透明窗口仍会吃掉命中。
double resolvePlayerPanelOrigin(double origin, double screenHeight) {
  final h = screenHeight.isFinite && screenHeight > 0 ? screenHeight : 0.0;
  if (!origin.isFinite) return 0.0;
  return origin.clamp(0.0, h);
}

/// 双向展开面板的几何（`screenHeight` 已被上游归一到实际约束高度）。
PlayerPanelGeometry playerPanelGeometry({
  required double progress,
  required double origin,
  required double miniHeight,
  required double screenHeight,
}) {
  final h = screenHeight.isFinite && screenHeight > 0 ? screenHeight : 0.0;
  final p = progress.isFinite ? progress.clamp(0.0, 1.0) : 0.0;
  // 先把锚点钳进屏内（origin + miniHeight ≤ 屏高），后续推导才恒不越界。
  final o = resolvePlayerPanelOrigin(origin, h);
  final m = miniHeight.isFinite ? miniHeight.clamp(0.0, h - o) : 0.0;
  final top = o * (1 - p);
  final bottom = math.min(
    h,
    o + m + (h - o - m) * kPlayerPanelBottomBoost * p,
  );
  return (top: top, height: bottom - top);
}

/// 面板内容的不透明度：手指行程满 [kPlayerPanelFadeSpanRatio] 屏高后完全不透明。
///
/// 起点为 0 是刻意的：p=0 时面板恰好压在迷你条上，完全透明 = 画面与手势前逐像素
/// 相同，用户看到的是迷你条「原地开始膨胀」而不是被另一个东西盖住。
double playerPanelOpacity({
  required double progress,
  required double origin,
  required double screenHeight,
}) {
  final h = screenHeight.isFinite && screenHeight > 0 ? screenHeight : 0.0;
  final span = kPlayerPanelFadeSpanRatio * h;
  if (span <= 0) return 1.0;
  final p = progress.isFinite ? progress.clamp(0.0, 1.0) : 0.0;
  final o = resolvePlayerPanelOrigin(origin, h);
  return (p * o / span).clamp(0.0, 1.0);
}

/// 面板内页面的平移量（页面本地像素），并把结果写进形变登记簿。
///
/// **与 `full_player_route.dart` 的 `playerPageOffset` 拖拽分支必须同式** ——
/// 封面形变层靠 `pageOffset` 把 paint 期实测矩形换算成「页面归位」矩形，两处
/// 漂移会让飞行中的封面与页面错位半个身位。
/// `player_panel_geometry_test.dart` 对两者做逐点一致性断言。
///
/// **origin 必须与几何同源钳制**（[resolvePlayerPanelOrigin]）：dy 与
/// `playerPanelGeometry` 的 top 用不同的 origin 值，上面那条不变量就断了。
///
/// 写入发生在调用方的 **layout 阶段**（`PlayerPanelFrame` 的 LayoutBuilder 内），
/// 严格早于本帧 paint，因此形变层探针在 paint 里读到的仍是同帧值 —— 这条
/// 同帧契约不要打破，别把调用点挪到 paint 之后。
Offset playerPanelPageOffset({
  required double progress,
  required double origin,
  required double screenHeight,
}) {
  final p = progress.isFinite ? progress.clamp(0.0, 1.0) : 0.0;
  final o = resolvePlayerPanelOrigin(origin, screenHeight);
  final dy = o * (1 - p);
  PlayerCoverMorphBus.instance.pageOffset = Offset(0, dy);
  return Offset(0, dy);
}

/// 迷你条本体的底色。
Color resolveMiniPlayerBackground(
  ColorScheme cs, {
  required bool useBackgroundImage,
}) => useBackgroundImage
    ? cs.surface.withValues(alpha: 0.2)
    : cs.surfaceContainerHigh;

/// 展开面板的过渡态底色层。**始终不透明**，且**不参与淡入**
/// （淡入只作用于面板里的页面内容，见 [PlayerPanelFrame] 的结构说明）。
///
/// ## 为什么不能直接复用 [resolveMiniPlayerBackground]
///
/// 面板的裁剪窗口从迷你条矩形长到整屏，这期间窗口会盖住主页面列表和导航栏。
/// 底色一旦带透明度，背后的信息就会穿过半透明的页面内容一起显影 —— 中间态
/// 看着杂乱就是这个原因，且**把底色塞进 Opacity 里也堵不住**：那样整个面板
/// （底色 + 页面）一起被乘上透明度，背后照样透过来。
///
/// - 非壁纸档：一块与迷你条本体逐像素同值的实色（[resolveMiniPlayerBackground]
///   的不透明分支）。p=0 时面板恰好压住迷你条，颜色一致 → 起点没有色差。
/// - 壁纸档：复刻迷你条背后的**整条图层栈**（壁纸 + 底栏面 + 迷你条面），
///   而不是一块实色。壁纸档下迷你条本体是半透明的（`surface@0.2`），
///   若面板改用实色，手指刚离开那一帧会「半透明条 → 实色块」突变成突兀色块。
///
/// ## 为什么要两层 tint
///
/// 壁纸模式下底栏本身也是 `surface@0.2`（`app.dart` 的
/// `_applyBackgroundOverrides` 对 navigationBar / navigationRail 都这么设），
/// 而迷你条就压在底栏之上。所以迷你条实际呈现 = 壁纸 + **两层** 20% surface。
/// 只画一层偏暗、画三层偏亮，两种都是穿帮。
class PlayerPanelBaseLayer extends StatelessWidget {
  const PlayerPanelBaseLayer({super.key, required this.useBackgroundImage});

  final bool useBackgroundImage;

  /// 壁纸模式下底栏 / 迷你条各自的 20% surface 面。
  static Color _tint(ColorScheme cs) => cs.surface.withValues(alpha: 0.2);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (!useBackgroundImage) return ColoredBox(color: cs.surfaceContainerHigh);
    return Stack(
      fit: StackFit.expand,
      children: [
        const AppBackground(),
        ColoredBox(color: _tint(cs)), // 底栏面（NavigationBar / NavigationRail）
        ColoredBox(color: _tint(cs)), // 迷你条面
      ],
    );
  }
}

/// 展开面板外框：把**整屏尺寸、只做纵向平移**的播放页裁剪到
/// [playerPanelGeometry] 算出的窗口内。
///
/// ## 为什么是「裁剪」而不是「压扁」
///
/// 若改用 `SizedBox(height: 面板高)` 去包播放页，播放页会**逐帧重新布局**
/// （歌词 / 封面 / 控件全部 reflow，120Hz 屏必然掉帧，`AspectRatio` 封面还会被
/// 挤变形）。裁剪方案下播放页的测量结果与整屏时代完全一致：
/// - 封面形变层的 `coverMorphSettledRect` 只抵消**平移**，裁剪不影响它量到的
///   `measured`，所以那一整套登记簿一个字都不用改；
/// - `PlayerCoverSlot` / `PlayerTitleSlot` 的让位条件（`expansion ∈ (0,1)`）不变。
///
/// ## 结构
///
/// 1. `PlayerPanelBaseLayer` —— **不透明**的过渡态底色，垫在最底；和下面那行
///    页面同样用 `Positioned(top: -g.top, height: h)` **按屏幕坐标**锚定而不是
///    `Positioned.fill` 铺窗口：壁纸档下底色层里含整屏壁纸，按窗口铺的话窗口里
///    看到的是壁纸的**另一段**，与身后的迷你条错位（穿帮）。整屏盒子多出来的那段
///    正好被外层 `Stack` 裁掉；
/// 2. `Positioned(top: -top)` + `Transform.translate(0, dy)` —— 整屏页面放回
///    屏幕顶端再按跟手量下移（**与改动前逐帧一致**）；
/// 3. `Opacity` 只裹页面 —— 内容在底色上淡入，底色本身始终不透明；
/// 4. 外层 `Stack(clipBehavior: Clip.hardEdge)` —— 只露出窗口内的部分。
class PlayerPanelFrame extends StatelessWidget {
  const PlayerPanelFrame({
    super.key,
    required this.progress,
    required this.origin,
    required this.miniHeight,
    required this.child,
  });

  /// 展开进度，0 = 迷你条矩形，1 = 全屏。
  final double progress;

  /// 迷你条顶端 Y（设计像素）。
  final double origin;

  /// 迷你条高度（设计像素）。
  final double miniHeight;

  /// 整屏尺寸的播放页。
  final Widget child;

  /// 计时壳：面板本帧的 widget 构造计入 `panel` 热点。
  ///
  /// **读数的口径**：这里只量到 build 阶段的构造。真正的裁剪成本发生在
  /// layout / paint（`LayoutBuilder` 的 builder 要到布局期才跑），它会落在日志的
  /// `resid`（残差）里而不是这个热点。所以对 `panel` 而言，**`n=` 次数才是它回答的
  /// 问题**——面板每帧被重建几次；µs 只说明构造本身便不等于整帧的布局开销。
  @override
  Widget build(BuildContext context) {
    // 判据关闭时直接 `_buildFrame`：面板在转场期每帧 build，
    // 热点包装要的闭包（以及 tear-off）本身就是每帧一次分配，不该留给 release。
    if (coverMorphPerfLogEnabled) {
      return coverMorphHot<Widget>('panel', () => _buildFrame(context));
    }
    return _buildFrame(context);
  }

  Widget _buildFrame(BuildContext context) {
    // 过渡态底色：壁纸档要不要铺、铺什么配方，全部由组件内部解析 ——
    // 调用点无从漏传。
    final useBgImage = context.watch<ThemeProvider>().useBackgroundImage;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 屏高取**实际约束**而不是 MediaQuery：裁剪窗口必须与页面盒子同处一个
        // 坐标系，两者一旦不等，窗口底部会出现一段没画东西的透明带。
        final h = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : MediaQuery.sizeOf(context).height;
        final g = playerPanelGeometry(
          progress: progress,
          origin: origin,
          miniHeight: miniHeight,
          screenHeight: h,
        );
        // dy 与 g.top 必须同源：两处各自钳一次会漏，转屏途中 origin 是旧屏的
        // 快照而 h 已是新屏，漏钳就会把页面整体推到窗口之外（面板整块透明、
        // 且那块透明窗口仍会吃掉命中）。
        final dy = playerPanelPageOffset(
          progress: progress,
          origin: origin,
          screenHeight: h,
        ).dy;
        return Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: EdgeInsets.only(top: g.top),
            child: SizedBox(
              width: double.infinity,
              height: g.height,
              child: Stack(
                // hardEdge 而非抗锯齿：抗锯齿裁剪边会留下一条半透明的缝，
                // 深色背景下肉眼可见；迷你条与全屏两端也都是方角，无需圆角。
                clipBehavior: Clip.hardEdge,
                children: [
                  // 底色层：**不参与淡入**，是整个面板不透的唯一保证。
                  // 只在窗口小于整屏时绘制：p=1 时页面已完全盖住它。
                  //
                  // 定位与紧邻的页面那一行**完全一致**（top: -g.top / height: h），
                  // 刻意不用 `Positioned.fill` 铺窗口：壁纸档下底色层含整屏壁纸，
                  // 必须按**屏幕坐标**铺开再由外层 `Clip.hardEdge` 裁出窗口那一段。
                  // 若按窗口铺，窗口里显示的是壁纸的另一段，与身后的迷你条错位。
                  if (g.height < h)
                    Positioned(
                      top: -g.top,
                      left: 0,
                      right: 0,
                      height: h,
                      child: PlayerPanelBaseLayer(useBackgroundImage: useBgImage),
                    ),
                  Positioned(
                    top: -g.top,
                    left: 0,
                    right: 0,
                    height: h,
                    // 阶段归因（仪表 v3）：整页在 layout / paint 阶段的真实耗时。
                    // `panel` 热点只量到本帧的 widget 构造，页面每帧到底花多少时间在
                    // 布局与录制上，只有在这里圈一棵才量得到（约束原样透传、几何不变）。
                    child: CoverMorphPhaseProbe(
                      layoutKey: 'pageLayout',
                      paintKey: 'pagePaint',
                      child: Transform.translate(
                        offset: Offset(0, dy),
                        child: Opacity(
                          // 淡入只作用于**页面内容**。若把 Opacity 提到整个面板
                          // 外面，底色会被一起乘上透明度，背后照样透出来。
                          opacity: playerPanelOpacity(
                            progress: progress,
                            origin: origin,
                            screenHeight: h,
                          ),
                          child: child,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
