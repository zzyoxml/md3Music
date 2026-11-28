import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/widgets/app_background.dart';
import '../../providers/theme_provider.dart';
import 'player_cover_morph.dart';

/// 展开面板在屏幕上的几何（**设计像素**，与 `MediaQuery` 屏高、
/// [PlayerCoverMorphBus.pageOffset] 同处一个坐标系）。
typedef PlayerPanelGeometry = ({double top, double height});

/// 展开面板的**外轮廓**：矩形 + 四角圆角。
///
/// 这是「悬浮条外轮廓 → 覆盖全屏」形变的唯一几何真值：矩形决定窗口位置与大小，
/// 圆角决定窗口的四个角。两者都从源形态（胶囊 / 圆盘 / 常驻条）逐帧插值到
/// 目标形态（整屏 + 屏幕 r 角）。
typedef PlayerPanelContour = ({Rect rect, BorderRadius radius});

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

/// 过渡态**底色**从透明到不透明的行程占比。
///
/// **为什么底色也要渐显**：`p=0` 时面板窗口恰好压在悬浮条真身上，若底色一上来
/// 就不透明，真身自带的装饰（3dp 包边进度环、播放/切歌按钮）会在起手第一帧整块
/// 消失 —— 手指还没动，界面先变了一下。让底色在前 4% 行程内淡入，这段时间里
/// 真身的 chrome 仍在（`capsuleChromeOpacity` 在 p∈[0,0.15] 内淡出），两者是
/// **同色交叉淡变**，视觉上等于「胶囊自己变得不透明」。
///
/// 取值刻意很短：底色的职责是「挡住背后的主页面」，一旦手指真的带起面板就必须
/// 已经生效，否则中间态会透出背后列表（见 [PlayerPanelBaseLayer] 的说明）。
const double kPlayerPanelBaseFadeSpanRatio = 0.04;

/// 外轮廓圆角**尾段收敛**的起点进度。
///
/// 真机反馈两条（2026-10-18）：①设备上报的 r 角与实际物理圆角对不齐，窗口贴到
/// 屏边后弧形缺口把**底下的主页面**露了出来——「宁可 r 角小一些也不要露底」；
/// ②完全展开后 r 角裁剪一直保留、不会消失。
///
/// 因此圆角映射改为两段：`[0, s]` 从源形态圆角**长到**屏幕 r 角（连贯形变的主段），
/// `[s, 1]` 再从屏幕 r 角**收回 0**（终态 = 方角满铺，和任何其他页面一样由物理
/// 屏幕自己负责圆角，面板不再另裁一层）。需求原话是「覆盖屏幕 r 角」——**覆盖**
/// 而不是「被它裁掉」：收回 0 才是字面正确，也一劳永逸地杜绝了露底。
///
/// 取值 0.999（用户复测后定的节奏）：圆角几乎整段行程都在向屏幕 r 角生长，
/// 只在最后 0.1% 行程收回放平（≈ 落位的那一两帧）。中段观感即「圆角一路跟到
/// 满铺、落位瞬间四角自然放平」，全程看不出独立的「变方」一拍。
/// **上限就是 1.0，但 1.0 等于关掉收回**：`p` 永远进不了尾段，终态保留屏幕 r 角
/// 裁剪 —— 正是真机报障的「r 角不消失、上报值对不齐时四角露底」，不可取。
const double kPlayerPanelRadiusRetractStart = 0.999;

/// 迷你条 → 全屏的**双向展开**几何（纵向部分，保留给既有消费方与测试）。
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

/// 把圆角逐角钳进「盒子能容纳的最大半径」并清掉非法值。
///
/// `BorderRadius` 允许写任意大（框架内部按盒子尺寸夹取），但**本文件的窗口在
/// 逐帧变化**：p 很小时窗口只有几十 dp 高，若直接吃插值出来的 32，四个角会互相
/// 吃掉、轮廓读起来像椭圆。显式钳到 `min(w,h)/2` 后，胶囊端（32 高 64）仍然是
/// 正圆，而中间帧的轮廓始终是合法的圆角矩形。
BorderRadius _clampRadii(BorderRadius radii, Size size) {
  final double maxR = math.min(size.width, size.height) / 2;
  double one(double v) {
    if (!v.isFinite || v <= 0) return 0.0;
    return v > maxR ? maxR : v;
  }

  return BorderRadius.only(
    topLeft: Radius.circular(one(radii.topLeft.x)),
    topRight: Radius.circular(one(radii.topRight.x)),
    bottomLeft: Radius.circular(one(radii.bottomLeft.x)),
    bottomRight: Radius.circular(one(radii.bottomRight.x)),
  );
}

/// 设备上报的屏幕 r 角（`MediaQuery.displayCornerRadii`）在当前窗口下是否可信。
///
/// **为什么需要这道判定**：Android 端是**逐角**读取显示屏圆角的 —— 引擎在
/// `FlutterView.onApplyWindowInsets` 里对四个角分别调
/// `WindowInsets.getRoundedCorner(position)`，取不到就把该角写成 0。只有窗口
/// **实际贴住**的显示屏圆角才有值：全屏时四角同时贴边（四个值同量级）；小窗
/// （HyperOS Freeform）/ 分屏 / 画中画下窗口只覆盖显示屏的一部分，于是常出现
/// 「右边两角有值、左边是 0」。若把这种值直接当轮廓终点，过渡动画就会插值出
/// **左方右圆**的非对称轮廓（2026-10-21 小窗真机报障）。
///
/// 判据：**有角有值、有角无值 ⇒ 窗口没铺满显示屏 ⇒ 一律方角**（小窗的窗口
/// 圆角由系统窗口自己负责，面板内不再另裁一层）。四角全无值（未上报 / 方角屏，
/// 终点本来就是方角）与四角全有值（全屏，含物理屏上下圆角不相等的机型）都
/// **原样透传**，保证正常状态下的圆角逐像素不变。
///
/// 只做数值层面的「窗口是否覆盖显示屏四角」判定，不关心窗口位置；非有限值 /
/// 负值按「该角无值」处理，与 [_clampRadii] 清非法值的口径一致。
BorderRadius? resolvePanelScreenRadii(BorderRadius? reported) {
  if (reported == null) return null;
  // 每角取 x/y 里更大的分量：任一方向有弧即视为该角有值。
  double corner(Radius radius) => math.max(radius.x, radius.y);
  final List<double> corners = <double>[
    corner(reported.topLeft),
    corner(reported.topRight),
    corner(reported.bottomRight),
    corner(reported.bottomLeft),
  ];
  // `!(v > 0)` 同时覆盖 0、负数与 NaN（全部读作「该角没上报」）。
  final bool anyMissing = corners.any((v) => !(v > 0));
  final bool anyReported = corners.any((v) => v > 0);
  return anyMissing && anyReported ? BorderRadius.zero : reported;
}

/// 展开面板的**外轮廓**（矩形 + 圆角），悬浮条/常驻条共用。
///
/// 纵向映射与 [playerPanelGeometry] **完全同源**（`top == dy` 不变量原样保留），
/// 只是把入参从「origin + miniHeight」换成「源形态的实测矩形」；横向是新增的
/// 第二条轴：
/// - `left = originRect.left * (1-p)`、`right = originRect.right + (屏宽 - right) * p`
///   —— 胶囊（左右各 16dp 内缩 / Pad 下靠右限宽 400）在展开过程中**横向铺开**到
///   全屏，而不是一上来就按全屏宽铺一块比真身宽的窗口；
/// - 圆角从 [originRadius]（胶囊/圆盘 32、常驻条 0）插值到 [screenRadii]
///   （设备上报的屏幕 r 角；未上报 = 方角，与引入圆角之前逐像素一致）。
///
/// [originRect] 四边都钳进屏内：转屏 / 分屏 / 小窗 resize 发生在手势途中时，
/// 锚点是手势开始那一刻的**旧视口快照**，不钳会让窗口（和它吃掉的命中区）
/// 跑到屏幕之外。
PlayerPanelContour playerPanelContour({
  required double progress,
  required Rect originRect,
  required Size screenSize,
  required double originRadius,
  BorderRadius? screenRadii,
}) {
  final double w = screenSize.width.isFinite && screenSize.width > 0
      ? screenSize.width
      : 0.0;
  final double h = screenSize.height.isFinite && screenSize.height > 0
      ? screenSize.height
      : 0.0;
  final double p = progress.isFinite ? progress.clamp(0.0, 1.0) : 0.0;

  final double top0 = originRect.top.isFinite
      ? originRect.top.clamp(0.0, h)
      : h;
  final double bottom0 = originRect.bottom.isFinite
      ? originRect.bottom.clamp(top0, h)
      : h;
  final double left0 = originRect.left.isFinite
      ? originRect.left.clamp(0.0, w)
      : 0.0;
  final double right0 = originRect.right.isFinite
      ? originRect.right.clamp(left0, w)
      : w;

  final double top = top0 * (1 - p);
  final double bottom = math.min(
    h,
    bottom0 + (h - bottom0) * kPlayerPanelBottomBoost * p,
  );
  final double left = left0 * (1 - p);
  final double right = right0 + (w - right0) * p;
  final rect = Rect.fromLTRB(left, top, right, bottom);

  final BorderRadius start = BorderRadius.all(
    Radius.circular(
      originRadius.isFinite && originRadius > 0 ? originRadius : 0.0,
    ),
  );
  final BorderRadius end = screenRadii ?? BorderRadius.zero;
  // 两段映射（见 [kPlayerPanelRadiusRetractStart]）：前段长到屏幕 r 角，尾段
  // 收回 0。终态方角 = 面板**覆盖**到屏边，物理圆角由屏幕自己裁，不再露底、
  // 也不留永久 r 角裁剪。
  final BorderRadius radius;
  if (p <= kPlayerPanelRadiusRetractStart) {
    radius =
        BorderRadius.lerp(
          start,
          end,
          kPlayerPanelRadiusRetractStart <= 0
              ? 1.0
              : p / kPlayerPanelRadiusRetractStart,
        ) ??
        start;
  } else {
    final q =
        (p - kPlayerPanelRadiusRetractStart) /
        (1.0 - kPlayerPanelRadiusRetractStart);
    radius = BorderRadius.lerp(end, BorderRadius.zero, q) ?? end;
  }
  return (rect: rect, radius: _clampRadii(radius, rect.size));
}

/// 面板内容的不透明度：手指行程满 [kPlayerPanelFadeSpanRatio] 屏高后完全不透明。
///
/// 起点为 0 是刻意的：p=0 时面板恰好压在迷你条上，完全透明 = 画面与手势前逐像素
/// 相同，用户看到的是迷你条「原地开始膨胀」而不是被另一个东西盖住。
///
/// **[origin] 必须是本次转场的起点锚（迷你条/胶囊顶端 Y），不是面板本帧的窗口
/// 上沿**。两者只差一个 `(1-p)` 因子，写错的后果很具体：`o` 随 p 收缩，一旦
/// `窗口上沿 < span` 就落进下面那条「行程不足 span」分支返回 `p×o/o = p`，
/// 透明度于是**先冲到 1.0、后 1/4 行程又掉回 ~0.8**，末端再硬弹回 1.0 —— 而非
/// 单调饱和。页面是深色（AM 播放页 `Colors.black`），底下那层底色在 4% 行程就
/// 已经全不透明且是浅色（`surface` / 壁纸洗白），alpha 一掉浅色就
/// 透出来，观感正是「拖到后面先变白，落位才正常」。
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
  // 语义 = 「页面起走过 span 这段行程即全不透明」。底部迷你条（origin ≈ 屏高
  // > span）时行程上限就是 span，与旧公式 p*o/span 逐像素一致；tv: 顶栏迷你条
  // origin 只有几十 dp，永远走不满 20% 屏高 —— 旧公式在全行程终点 p=1 时
  // 只能到 ~0.33，播放页变成幽灵、主页整个透出来（2026-10-16 真机实锤）。
  // 改为行程封顶：总行程 o 不足 span 时按整段行程线性走完；o ≤ 0 即页面
  // 无位移，无淡入可言，恒不透明。
  if (o <= 0) return 1.0;
  final travel = o < span ? o : span;
  return (p * o / travel).clamp(0.0, 1.0);
}

/// 过渡态**底色层**的不透明度（纯函数，端点可直接断言）。
///
/// `p == 0` → 0（真身完整可见，含包边进度环与播放按钮）；`p >= 4%` → 1
/// （此后底色必须完全挡住背后的主页面）。见 [kPlayerPanelBaseFadeSpanRatio]。
double playerPanelBaseOpacity(double progress) {
  final p = progress.isFinite ? progress.clamp(0.0, 1.0) : 0.0;
  if (kPlayerPanelBaseFadeSpanRatio <= 0) return 1.0;
  return (p / kPlayerPanelBaseFadeSpanRatio).clamp(0.0, 1.0);
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

/// 面板内页面的平移量（页面本地像素），**按外轮廓**取窗口上沿。
///
/// 与 [playerPanelPageOffset] 的关系：后者是「origin + 进度」的旧式推导（保留给
/// 既有消费方与单测），本函数直接吃 [playerPanelContour] 已经算好的矩形，避免
/// 在窗口上沿已经钳制过一次之后再按 origin 钳第二次 —— 那会把 `top` 乘两遍
/// `(1-p)`，页面与窗口上沿立刻错开半个身位。
///
/// 与旧式一样**写进形变登记簿**，且必须发生在 layout 阶段（严格早于本帧 paint），
/// 见 [playerPanelPageOffset] 的同帧契约说明。
Offset playerPanelContourPageOffset(PlayerPanelContour contour) {
  final double dy = contour.rect.top;
  PlayerCoverMorphBus.instance.pageOffset = Offset(0, dy);
  return Offset(0, dy);
}

/// 迷你条本体的底色。
Color resolveMiniPlayerBackground(
  ColorScheme cs, {
  required bool useBackgroundImage,
}) => useBackgroundImage
    ? cs.surface.withValues(alpha: 0.2)
    : cs.surface;

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
    if (!useBackgroundImage) return ColoredBox(color: cs.surface);
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
/// [playerPanelContour] 算出的窗口（矩形 + 四角圆角）内。
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
/// 1. 外层 `ClipRRect(borderRadius: 窗口圆角)` —— 「悬浮条外轮廓 → 屏幕 r 角」
///    这段形变就落在这里。圆角为 0 时退化成方角硬裁剪（与引入圆角之前逐像素
///    一致）；非 0 时用抗锯齿，否则弧边上会留下台阶。
/// 2. `PlayerPanelBaseLayer` —— 过渡态底色，垫在最底；和下面那行页面同样
///    **按屏幕坐标**锚定（`Positioned(left: -left, top: -top, width: 屏宽,
///    height: 屏高)`）而不是 `Positioned.fill` 铺窗口：壁纸档下底色层里含整屏
///    壁纸，按窗口铺的话窗口里看到的是壁纸的**另一段**，与身后的迷你条错位
///    （穿帮）。整屏盒子多出来的部分正好被外层圆角裁剪掉。
///    它自己再套一层 `Opacity(playerPanelBaseOpacity)`：p=0 时完全透明，让悬浮条
///    真身（含包边进度环）在起手第一帧保持可见。
/// 3. `Positioned(...)` + `Transform.translate(0, dy)` —— 整屏页面放回屏幕顶端
///    再按跟手量下移（**与改动前逐帧一致**）；
/// 4. `Opacity` 只裹页面 —— 内容在底色上淡入，底色本身按 (2) 的独立曲线渐显。
class PlayerPanelFrame extends StatelessWidget {
  const PlayerPanelFrame({
    super.key,
    required this.progress,
    required this.originRect,
    this.originRadius = 0.0,
    this.screenRadii,
    required this.child,
  });

  /// 展开进度，0 = 源形态矩形，1 = 全屏。
  final double progress;

  /// 源形态（悬浮胶囊 / 圆盘 / 常驻条）的**实测矩形**（设计像素、屏幕坐标）。
  ///
  /// 口径 = 可见本体，不是宿主外框：胶囊是 64 高、左右 16dp 内缩（Pad 下限宽
  /// 400 且靠停靠侧），常驻条是通栏含底部净空。`p=0` 时窗口与它逐值相等。
  final Rect originRect;

  /// 源形态的外轮廓圆角（dp）：胶囊 / 圆盘 32，常驻条 0。
  final double originRadius;

  /// 目标圆角 = 设备**原始上报**的屏幕 r 角（`MediaQuery.displayCornerRadii`）。
  ///
  /// 调用点原样传入上报值即可：小窗 / 分屏（窗口没铺满显示屏、只有部分角有值）
  /// 的可信度判定收口在本 widget 内，见 [resolvePanelScreenRadii]。
  /// null（Android < 12 / 厂商未上报）时终点为方角 —— 与引入圆角之前逐像素一致。
  final BorderRadius? screenRadii;

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
        // 屏尺寸取**实际约束**而不是 MediaQuery：裁剪窗口必须与页面盒子同处一个
        // 坐标系，两者一旦不等，窗口底部会出现一段没画东西的透明带。
        final Size screen = constraints.hasBoundedWidth &&
                constraints.hasBoundedHeight
            ? constraints.biggest
            : MediaQuery.sizeOf(context);
        // 上报值先过可信度判定：小窗 / 分屏下只有部分角有值，直接采信会让
        // 轮廓终点非对称（真机报障「左方右圆」），见 [resolvePanelScreenRadii]。
        // 收口在本 widget 内而不是调用点：生产侧两个入口（播放页路由 / 拖拽
        // 覆盖层）都经由这里，将来新增入口也不会漏判。
        final BorderRadius? trustedScreenRadii =
            resolvePanelScreenRadii(screenRadii);
        final g = playerPanelContour(
          progress: progress,
          originRect: originRect,
          screenSize: screen,
          originRadius: originRadius,
          screenRadii: trustedScreenRadii,
        );
        final Rect rect = g.rect;
        // dy 与窗口上沿必须同源：这里**直接取轮廓的 top**，不能再按 origin 推一遍
        // （那样会乘两次 `(1-p)`，页面与窗口上沿立刻错开半个身位）。
        final dy = playerPanelContourPageOffset(g).dy;
        // 圆角阈值：小于 0.25dp 的圆弧在屏幕上不可辨，走硬裁剪既省一次
        // saveLayer 也不会在深色背景上留出抗锯齿的半透明缝（旧实现的注释
        // 记录过这条：方角时 AA 会在弧边留下肉眼可见的缝）。
        final bool rounded = g.radius != BorderRadius.zero;
        return Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: EdgeInsets.only(left: rect.left, top: rect.top),
            child: SizedBox(
              width: rect.width,
              height: rect.height,
              child: ClipRRect(
                borderRadius: g.radius,
                clipBehavior: rounded ? Clip.antiAlias : Clip.hardEdge,
                child: Stack(
                  children: [
                    // 底色层：**不参与页面淡入**，是面板不透的唯一保证。
                    // 只在窗口小于整屏时绘制：p=1 时页面已完全盖住它。
                    //
                    // 定位与紧邻的页面那一行**完全一致**（按屏幕坐标铺满整屏），
                    // 刻意不用 `Positioned.fill` 铺窗口：壁纸档下底色层含整屏壁纸，
                    // 必须按屏幕坐标铺开再由外层圆角裁剪裁出窗口那一段。
                    // 若按窗口铺，窗口里显示的是壁纸的另一段，与身后的迷你条错位。
                    //
                    // 透明度独立于页面淡入：p=0 完全透明（露出真身含包边进度环），
                    // 4% 行程内变不透明（此后必须挡住背后主页面）。
                    if (rect.height < screen.height)
                      Positioned(
                        left: -rect.left,
                        top: -rect.top,
                        width: screen.width,
                        height: screen.height,
                        child: Opacity(
                          opacity: playerPanelBaseOpacity(progress),
                          child: PlayerPanelBaseLayer(
                            useBackgroundImage: useBgImage,
                          ),
                        ),
                      ),
                    Positioned(
                      left: -rect.left,
                      top: -rect.top,
                      width: screen.width,
                      height: screen.height,
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
                            //
                            // 入参必须是**起点锚** `originRect.top`（同一份钳制），
                            // 不是本帧窗口上沿 `rect.top`：后者 = 锚点×(1-p)，会让
                            // 透明度在后 1/4 行程从 1.0 掉回 ~0.8，把 4% 行程起就
                            // 已全不透明的**浅色**底色层透出来 = 真机报障「拖到后半段
                            // 先变白、落位才正常」。理由见 [playerPanelOpacity] 文档。
                            opacity: playerPanelOpacity(
                              progress: progress,
                              origin: resolvePlayerPanelOrigin(
                                originRect.top,
                                screen.height,
                              ),
                              screenHeight: screen.height,
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
          ),
        );
      },
    );
  }
}
