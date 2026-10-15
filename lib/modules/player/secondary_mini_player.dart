import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/physics.dart';

import '../../core/theme/motion_constants.dart';
import '../../core/layout/bottom_chrome_dimens.dart';
import '../../core/layout/ime_collapse.dart';
import '../../core/layout/page_title_alignment.dart';
import '../../core/layout/responsive_layout.dart';
import '../../core/layout/ui_density.dart';
import '../../core/services/player_frame_driver.dart';
import '../../core/utils/app_haptics.dart';
import '../../data/repositories/settings_repository.dart';
import '../../providers/car_mode_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/theme_provider.dart';
import '../../widgets/smart_artwork_image.dart';
import 'full_player_route.dart';
import 'bottom_bar_morph_overlay.dart';
import 'mini_player.dart';
import 'player_cover_morph.dart';
import 'player_morph_scene.dart';
import 'player_panel_frame.dart';

/// 二级页面悬浮播放器宿主（改版计划五；现已扩展到一级页面，见下）。
///
/// 包裹页面可滚动内容，监听滚动通知：向下滚动超过阈值收起为底部圆形
/// 唱片，向上滚动展开为圆角悬浮条。收起/展开状态用 [ValueNotifier] 驱动，
/// 只让悬浮播放器自身重建，不触发整页高频刷新。
/// **自动收缩只在二级页面生效**，一级页面常驻展开态（见 [_buildHost]）。
/// 一/二级按**标题左对齐**判据（[isPrimaryNavPage]）划分，需由宿主传入 [tabId]；
/// 未传 tabId 或标题居中的页面一律按二级处理。
///
/// **形态判定**：页面可无条件把 `Scaffold.body`（或整页）包进本组件，宿主
/// 自行决定是否渲染悬浮播放器——
/// - **一级页面**（路由栈底主布局内的 tab 页）与**二级页面**（push 出来的
///   路由）：渲染悬浮条，并给内容底部预留其高度。一级页面由 `_MainLayout`
///   统一包裹，且悬浮条接管后底部常驻 [MiniPlayer] 隐藏（避免两套播放器并存）；
///   一级页面可用设置项退回底部常驻条（见 [kSecondaryPlayerOnPrimaryPages]）；
/// - **桌面布局**：底部已有全宽 [NowPlayingBar]，直接透传内容；
/// - **沉浸态**（[SecondaryMiniPlayerHost.immersive]，封面流全屏浏览）：透传内容；
/// - **嵌套**：若上层已有一个正在承载悬浮条的宿主，则本层透传内容（幂等，
///   避免路由包裹 + 页面自包裹时出现双份悬浮条）。
///
/// 播放控制与「打开完整播放页」逻辑复用现有实现（[PlayerProvider] +
/// [openFullPlayer]）；悬浮条本身仅在有正在播放/暂停的歌曲时显示。
class SecondaryMiniPlayerHost extends StatefulWidget {
  const SecondaryMiniPlayerHost({
    super.key,
    required this.child,
    this.tabId,
    this.collapseThreshold = 24.0,
    this.immersive = false,
    this.ownsBottomBar = false,
  });

  /// 页面内容（通常是可滚动列表 / CustomScrollView）。
  final Widget child;

  /// 本页对应的 tab id（取值见 [kAllAvailableTabs]），用于按**标题对齐**识别一级
  /// 页面 —— 判据是 [isPrimaryNavPage]：该 tab 在导航栏可见 **且** 其
  /// [TabItem.pinnedTitle] 为真（标题左对齐）。
  ///
  /// 因此标题居中的 tab 页（排行榜 / 搜索 / 本地音乐…）即使传了 tabId 也算二级，
  /// 照常随滚动收缩；不传 tabId 的宿主一律按二级处理。
  final String? tabId;

  /// 触发收起/展开的累计滚动阈值（dp），避免轻微抖动误触发。
  ///
  /// 仅二级页面参与收缩，一级页面不受本阈值影响（见 [_buildHost]）。
  final double collapseThreshold;

  /// 是否处于沉浸态（封面流横屏全屏浏览）。为 true 时不渲染悬浮条，
  /// 与底部常驻条在同一场景下隐藏的行为保持一致（见 `_MainLayout._buildBody`）。
  final bool immersive;

  /// 外壳已承载常驻播放条，嵌套路由无需重复添加。
  final bool ownsBottomBar;

  @override
  State<SecondaryMiniPlayerHost> createState() =>
      _SecondaryMiniPlayerHostState();
}

class _SecondaryMiniPlayerHostState extends State<SecondaryMiniPlayerHost> {
  final ValueNotifier<bool> _collapsed = ValueNotifier<bool>(false);
  // 同向滚动累计位移；反向时清零，实现阈值滞回，防抖动。
  double _accum = 0.0;
  int _accumSign = 0;

  @override
  void dispose() {
    _collapsed.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification n) {
    if (n is ScrollUpdateNotification) {
      final d = n.scrollDelta ?? 0.0;
      if (d == 0) return false;
      final sign = d > 0 ? 1 : -1;
      if (sign != _accumSign) {
        _accum = 0.0;
        _accumSign = sign;
      }
      _accum += d;
      if (_accum > widget.collapseThreshold && !_collapsed.value) {
        _collapsed.value = true; // 向下浏览 → 收起
      } else if (_accum < -widget.collapseThreshold && _collapsed.value) {
        _collapsed.value = false; // 向上浏览 → 展开
      }
    }
    return false;
  }

  /// 点击圆盘手动展开。
  ///
  /// 必须同时清掉累计位移：`_accum` 若仍停在越过阈值的旧值，展开后**第一次**
  /// 向下滚动的头一个 delta 就会立刻再收起，24dp 阈值形同虚设。
  void _expandManually() {
    _accum = 0.0;
    _accumSign = 0;
    _collapsed.value = false;
  }

  @override
  Widget build(BuildContext context) {
    // 播放器形态的两个开关（设置页可关）：关闭时直渲染内容、不预留底部空间。
    // 用 ListenableBuilder 订阅全局开关，切换后各页宿主即时生效，不依赖上层重建。
    return ListenableBuilder(
      listenable: Listenable.merge([
        kSecondaryPlayerEnabled,
        kSecondaryPlayerOnPrimaryPages,
      ]),
      builder: (context, child) {
        // 沉浸态（封面流横屏全屏浏览）：不渲染任何播放器，保持全屏无遮挡
        // （此时 shell 也隐藏底部常驻条，见 _MainLayout._buildBody）。
        if (widget.immersive) return child!;
        // 开关是**播放器形态**选择，全局一致：
        // - 开：悬浮播放器（一级页面是否参与由 [kSecondaryPlayerOnPrimaryPages]
        //   决定，二级页面恒用悬浮条，见 [_buildHost]）；
        // - 关：底部常驻播放条（主页由 shell 承载，二级页面由本宿主补上同一条），
        //   保证任何页面都有播放器、且两种形态下不出现两套并存。
        if (kSecondaryPlayerEnabled.value) return _buildHost(context, child!);
        return _buildBottomBarFallback(context, child!);
      },
      child: widget.child,
    );
  }

  /// 开关关闭时的回落形态：底部常驻播放条（与主页 shell 同一条 [MiniPlayer]）。
  ///
  /// 只在二级页面补上 —— 主页由 `_MainLayout` 的 shell 直接承载同一条，若此处
  /// 再渲染会出现两条，故按 `isSecondaryRoutePage` 区分。
  ///
  /// 放进 `Column`（真实布局空间）而非悬浮 `Stack`：MiniPlayer 占据的高度由
  /// 内容自动让位，无需再注入底部预留 padding，也与 shell 的承载方式同构。
  Widget _buildBottomBarFallback(BuildContext context, Widget child) {
    // 桌面布局：底部已有全宽 NowPlayingBar，透传即可。
    if (isDesktopLayout(context)) return child;
    // 外壳（`_MainLayout`）自己带着常驻条：打标记，抑制双栏详情面板等嵌套层重复补一条。
    if (widget.ownsBottomBar) return _SecondaryPlayerHostScope(child: child);
    // 幂等：上层宿主已承载时透传。
    if (_SecondaryPlayerHostScope.of(context)) return child;
    // 主页（一级页面）：shell 已渲染同一条，本宿主透传，避免双条。
    if (!isSecondaryRoutePage(context)) return child;

    return _SecondaryPlayerHostScope(
      child: Column(
        children: [
          Expanded(child: child),
          const ImeCollapse(child: MiniPlayer()),
        ],
      ),
    );
  }

  /// 真正决定是否渲染悬浮条与是否预留底部的分支（[build] 的承载层）。
  Widget _buildHost(BuildContext context, Widget child) {
    // 桌面布局：底部已有全宽 NowPlayingBar（见横屏平板重设计计划 4.6），
    // 二级悬浮播放器走空分支——直接渲染内容，不加悬浮唱片、不预留底部空间，
    // 避免三套播放器并存割裂。
    if (isDesktopLayout(context)) return child;

    // 幂等：上层已有正在承载悬浮条的宿主（如路由包裹 + 页面自包裹并存）时，
    // 本层退化为透传，避免嵌套出现双份悬浮条。
    if (_SecondaryPlayerHostScope.of(context)) return child;

    // 【一级页面退回底部常驻条】设置里关掉「一级页面使用悬浮底栏」后，**一级页面**
    // 不用悬浮条，改由该 tab 根内容底部的 [PrimaryPagePersistentBar] 槽承载常驻
    // MiniPlayer（它挂在二级路由下方，会被 push 出来的页面整块盖住）。
    //
    // 判据与"不回缩"同源：[isPrimaryNavPage]（标题左对齐）。所以标题居中的 tab 页
    // （排行榜 / 搜索 / 本地音乐）即使设置关着也照常用悬浮条 —— 它们本就归为二级。
    // 若沿用 `isSecondaryRoutePage`（只看栈底路由）会把它们当成一级，于是 shell 补
    // 一条常驻条、页面自己又画一条悬浮条，同屏两条。
    //
    // 这里**故意不打 `_SecondaryPlayerHostScope` 标记**：scope 是 InheritedWidget，
    // 而双栏详情面板在元素树上也是本宿主的后代（ResponsiveShell → 每 tab 的内层
    // Navigator → DesktopTwoPane → 详情 Navigator）。一旦打标，右栏那些
    // `isFirst == false` 的真·二级页面会被连带抑制，「左栏常驻条 + 右栏悬浮条」的
    // 共存形态就没了。tab 页里自包裹的宿主（DiscoverPage / ChartsPage...）同属
    // 栈底路由，会各自做出同样判定而同样透传，不依赖本标记。
    if (!kSecondaryPlayerOnPrimaryPages.value &&
        isPrimaryNavPage(context, widget.tabId)) {
      return child;
    }

    // 一级页面（路由栈底主布局内的 tab 页）现在同样走悬浮播放器：由 `_MainLayout`
    // 把页面主体包进本宿主，并同步隐藏底部常驻 MiniPlayer（app.dart `_buildBody`），
    // 避免出现两个播放器。故这里不再按 isSecondaryRoutePage 区分一/二级。

    // 【一级页面不自动收缩】滚动收起是为「二级页面内容优先」设计的（详情页列表长，
    // 播放器该给正文让位）。主页下方本就有常驻导航栏，再把悬浮条收成一枚圆盘等于
    // 让播放信息长期不可见、还与导航栏抢注意力，因此一级页面常驻展开态胶囊。
    //
    // 一级页面的判据 = **标题左对齐**（[isPrimaryNavPage]，与 `centerPageTitle` 同源，
    // 只认 `TabItem.pinnedTitle`）。不用 `isSecondaryRoutePage`（只看栈底路由）：
    // 那样排行榜 / 搜索 / 本地音乐这些标题居中的 tab 页也会被当成一级页面，
    // 而用户看到的明明是"带返回键、标题居中"的详情式页面，该照常收缩。
    // 实现上只是**不给这一层接 NotificationListener**：[_collapsed] 唯一的写入口是
    // [_onScroll]，不接线即恒为 false（= 展开），无需再在 build 期间改写通知器。
    final bool autoCollapse = !isPrimaryNavPage(context, widget.tabId);

    // 悬浮播放器覆盖在内容之上（Stack），需给内容底部预留其高度，
    // 否则列表最后几项会被悬浮栏遮挡（见改版计划补充四）。
    // 通过注入 MediaQuery 底部 padding 让子树里按 MediaQuery.padding.bottom
    // 计算内边距的列表/ SafeArea 自动预留空间，无需逐页改。
    // 仅在有正在播放的歌曲时预留（无歌曲时悬浮栏不显示）。
    final hasSong = context.select<PlayerProvider, bool>(
      (p) => p.currentSong != null,
    );
    final carMode = context.select<CarModeProvider, bool>((p) => p.enabled);
    // 键盘弹出期间悬浮条被 ImeCollapse 收没，预留高度同步归零，否则列表底部
    // 白留一段 76dp 空带。
    //
    // 判据的主信号是焦点态（kTextInputFocused，见 ime_collapse.dart 的真机说明），
    // 它不走 MediaQuery，所以**必须在宿主这一层订阅**：只让 ImeCollapse 自己收展，
    // 这段预留会一直停在 76dp。
    //
    // **悬浮条本体提到 builder 之外**（O1 省帧）：下面 `ListenableBuilder` 的
    // builder 里读的是**全量** `MediaQuery.of(context)`（预留必须跟手底栏收起/
    // 恢复时逐帧变化的 `padding.bottom`）→ 这段 builder 在整个底栏收起动画期间
    // 逐帧重跑。若把 `SecondaryMiniPlayer` 留在里面，宿主每帧都会造一个新的
    // widget 实例 → 胶囊 State 每帧 build（O1 实测：飞行窗口后段 ≈17 帧全中，
    // 即使条体已走 `child:` 也救不回）。提到 builder 外后，逐帧只重挂**同一
    // widget 实例**，其 Element 见实例相同即短路（AGENTS §10）。
    final Widget capsule = Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: ImeCollapse(
        child: SecondaryMiniPlayer(
          collapsed: _collapsed,
          onRequestExpand: _expandManually,
        ),
      ),
    );
    return _SecondaryPlayerHostScope(
      child: ListenableBuilder(
        listenable: kTextInputFocused,
        builder: (BuildContext context, Widget? _) {
          final reserve =
              (hasSong && !carMode && !isImeVisible(context))
              ? _kReservedBottom
              : 0.0;
          final mq = MediaQuery.of(context);
          final content = Stack(
            children: [
              Positioned.fill(
                child: MediaQuery(
                  data: mq.copyWith(
                    padding: mq.padding.copyWith(
                      bottom: mq.padding.bottom + reserve,
                    ),
                  ),
                  child: child,
                ),
              ),
              capsule,
            ],
          );
          // 标记本宿主正在承载悬浮条，供子树内的嵌套宿主检测后退化透传。
          return autoCollapse
              ? NotificationListener<ScrollNotification>(
                  onNotification: _onScroll,
                  child: content,
                )
              : content;
        },
      ),
    );
  }
}

/// 标记「上层已有一个正在承载悬浮条的 [SecondaryMiniPlayerHost]」的作用域。
///
/// 只在宿主真的渲染悬浮条时提供（桌面布局 / 沉浸态 / 一级页面退回常驻条都是
/// "本层不承载"的透传，不打标记——一二级归属由路由判定，下层宿主自会得出同样结论）。
/// 子树内的嵌套宿主一旦检测到本作用域即可安全退化为透传，避免路由包裹 + 页面
/// 自包裹时出现双份悬浮条。
class _SecondaryPlayerHostScope extends InheritedWidget {
  const _SecondaryPlayerHostScope({required super.child});

  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_SecondaryPlayerHostScope>() !=
      null;

  @override
  bool updateShouldNotify(_SecondaryPlayerHostScope oldWidget) => false;
}

/// 包在「不保留播放栏」的二级路由页外层：挂载期间置位
/// [kSuppressResidentMiniPlayer]，让 `_MainLayout` 底部常驻 MiniPlayer 隐藏。
///
/// 适用对象是**二级路由形态**的纯界面页（当前只有设置页，见 `lib/app.dart`
/// `_pageForTabAsRoute`）：这类页没有悬浮播放器宿主（「设置页除外：不挂播放栏」），
/// 而常驻条挂在壳层之外、中央栈的路由盖不住它 —— 不置位就会在页底露出一条
/// 播放栏。tab 一级形态不经过此包装，常驻条照常显示。
///
/// 生命周期用挂载/卸载表达：push 时路由构建即置位，pop 动画结束路由销毁时复位；
/// 被同 tab 更深的路由盖住或被 IndexedStack 切到别的 tab 后台时仍保持置位，
/// 由消费方与「当前 tab 停在二级页面」合取兜住（见 [kSuppressResidentMiniPlayer]）。
/// 多实例（两个 tab 各停着一个该页）按引用计数，最后一个卸载才复位。
class ResidentBarSuppressor extends StatefulWidget {
  const ResidentBarSuppressor({super.key, required this.child});

  final Widget child;

  @override
  State<ResidentBarSuppressor> createState() => _ResidentBarSuppressorState();
}

class _ResidentBarSuppressorState extends State<ResidentBarSuppressor> {
  static int _activeCount = 0;

  @override
  void initState() {
    super.initState();
    _activeCount++;
    _sync();
  }

  @override
  void dispose() {
    _activeCount--;
    _sync();
    super.dispose();
  }

  static void _sync() {
    kSuppressResidentMiniPlayer.value = _activeCount > 0;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 「一级页面使用悬浮底栏」关闭时，由**每个 tab 根内容的底部**承载的常驻播放条。
///
/// 位置是关键：它必须挂在 tab 根路由**内部**，而不是 `_MainLayout` 的 Column 底部。
/// 壳层位于每 tab 的内层 Navigator 之外，感知不到内层 push —— 从「发现」打开搜索页 /
/// 每日推荐详情时，壳层那条常驻条依然挂在底部，而二级页面按 [isPrimaryNavPage] 判为
/// 二级、自画一条悬浮条 → 同屏两条音乐栏（本次修复的 Bug）。挂在根内容里之后，
/// 不透明的二级路由会整块盖住它，返回时原样露出，无需监听路由栈。
///
/// 自身订阅形态开关与 [isPrimaryNavPage]，因此可以被壳层**无条件**挂给每个 tab：
/// 槽位随路由一次性建好，判定在 build 里现算，设置页切换即时生效（不存在把
/// 「算好的控件」传进子树导致切换设置后不更新的问题）。
class PrimaryPagePersistentBar extends StatelessWidget {
  const PrimaryPagePersistentBar({super.key, required this.tabId});

  /// 本槽所属 tab 的 id，用于一级页面判定（详见 [isPrimaryNavPage]）。
  final String tabId;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        kSecondaryPlayerEnabled,
        kSecondaryPlayerOnPrimaryPages,
      ]),
      builder: (context, child) {
        // 总开关关闭：全部页面（含二级）统一由 `_MainLayout` 最外层那一条常驻条
        // 承载，此处再挂一份就是每 tab 一条。
        if (!kSecondaryPlayerEnabled.value) return const SizedBox.shrink();
        // 一级页面也用悬浮条：由外层 SecondaryMiniPlayerHost 承载。
        if (kSecondaryPlayerOnPrimaryPages.value) {
          return const SizedBox.shrink();
        }
        // 标题居中的 tab 页归二级，由它自己的悬浮条承载。
        if (!isPrimaryNavPage(context, tabId)) return const SizedBox.shrink();
        return const ImeCollapse(child: MiniPlayer());
      },
    );
  }
}

/// 悬浮播放器高度（唱片/圆角条 64 + 底部内边距 12）：内容底部据此预留。
const double _kReservedBottom = BottomChromeDimens.discReservedBottom;

double _lerp(double a, double b, double t) => a + (b - a) * t;

// —— 展开交接（取代原「整条按 playerExpansion 淡出」）——
//
// 悬浮胶囊点开完整播放页时，胶囊不再是整体淡出，而是分两组交棒：
// - **底色 + 文字**：在 [kCapsuleChromeFadeProgress] 这段短区间内快速淡出，
//   把视觉主导权交给从同一矩形长出来的展开面板（[DraggablePlayerRoute]）；
// - **封面**：二进制让位给形变层（`PlayerCoverMorphBus.coverLayerWillDraw`），
//   与常驻条封面 / 播放页 `PlayerCoverSlot` 的判据同源 —— 形变层一旦接管就
//   立即让位、不再叠一条淡出曲线（叠起来就是"封面刚起跳就变淡"）。
//
// 端点：`playerExpansion == 0` 时两组都回到 1（与改动前逐像素等价）；
// `playerExpansion == 1` 时底色/文字为 0、封面也收干净（整条不可见，现状不变）。

/// 底色/文字让位于展开面板的淡出区间：`playerExpansion ∈ [0, 0.15]`。
const double kCapsuleChromeFadeProgress = 0.15;

/// 胶囊展开到此进度时整条已完全不可见（与 [_SecondaryMiniPlayerState]
/// 的 [_kInvisibleExpansion] 同源，收口的旋转/进度采样也读它）。
const double kCapsuleInvisibleExpansion = 0.99;

/// 底色与文字的交接透明度（纯函数，端点/中点可直接断言）。
///
/// `playerExpansion == 0` → 1（逐像素等价）；`>= kCapsuleChromeFadeProgress` → 0。
double capsuleChromeOpacity(double expansion) =>
    (1.0 - expansion.clamp(0.0, 1.0) / kCapsuleChromeFadeProgress).clamp(
      0.0,
      1.0,
    );

/// 封面的交接透明度（**不**套用 [capsuleChromeOpacity] 那条短曲线）。
///
/// 判据与常驻条封面（`mini_player.dart` 的 `coverLayerWillDraw`）及播放页
/// `PlayerCoverSlot` 同源：`expansion > 0` 且形变层真的在画时二进制让位
/// （`Opacity 0`），形变层不接管（频谱圆盘 / 写真 / 系统减弱动画）时保持可见。
/// 额外的 [invisibleAt] 项保证**远端端点**（`playerExpansion == 1`）整条不可见：
/// 该进度下展开面板已铺满、胶囊在其之下，但裸露的封面仍要收干净。
double capsuleCoverOpacity(
  double expansion, {
  required bool layerWillDraw,
  double invisibleAt = kCapsuleInvisibleExpansion,
}) =>
    (expansion > 0.0 && (layerWillDraw || expansion >= invisibleAt)) ? 0.0 : 1.0;

/// 由「胶囊自身 render box 在锚点空间下的矩形」构造形态快照（纯函数）。
///
/// [panelRect] 的口径与常驻条**完全一致**：含底部净空、底端到屏底 —— 即胶囊
/// 宿主 box（SafeArea 底部安全区 + 12dp 底距 + 64dp 胶囊）在锚点空间下的矩形。
/// [collapsed] 为真时是圆盘形态，否则为展开胶囊。
PlayerMorphScene capsuleMorphScene({
  required Rect panelRect,
  required double screenHeight,
  required bool collapsed,
}) => PlayerMorphScene(
  panelRect: panelRect,
  screenHeight: screenHeight,
  form: collapsed ? PlayerBarForm.floatingDisc : PlayerBarForm.floatingCapsule,
);

// —— 悬浮播放器进度指示的几何（State 与 [_SecondaryProgressPainter] 共用）——

/// 进度采样周期：AGENTS §10.2 的「进度条档」。包边周长在展开态约 470dp，
/// 一首 4 分钟的歌每 500ms 只走约 2dp，再高的帧率视觉等价、只是多产帧。
const Duration _kProgressInterval = Duration(milliseconds: 500);

/// 包边描边宽度（dp）。
///
/// 封面半径 29（展开态直径 58）、胶囊边缘半径 32 → 中间正好是一圈 3dp 的 bezel。
/// 描边取 3dp 且中心线内缩一半（[_kProgressInset]），于是描边恰好铺满 29–32 环带：
/// 既不会被封面圆盖住，也不会被 Material 的圆角裁掉；收起成圆盘时封面缩到 56
/// （半径 28），环带留 1dp 余量，同一条描边正好落在圆盘 bezel 上。
const double _kProgressStroke = 3.0;
const double _kProgressInset = _kProgressStroke / 2;

/// Pad 下悬浮播放器的**轨道最大宽度**（展开态胶囊宽）。
///
/// 手机上的可用宽度（视口 - 左右各 16）约 368dp，胶囊内 4 个元素（封面 /
/// 标题·艺人 / 播放暂停 / 切歌）的排布以此为基准，故 Pad 上取同量级的 400dp，
/// 既避免"横贯全屏的长条"，也不改变内部排布。
/// 取值住在 [BottomChromeDimens.discTrackMaxWidth]（跨文件底栏几何收口）。
const double kSecondaryPlayerPadMaxWidth = BottomChromeDimens.discTrackMaxWidth;

/// 悬浮播放器拖拽会话的来源。
///
/// 同一根手指只会有一条识别器路径存活：越过 slop 归拖动识别器，原地按住满 500ms
/// 归长按识别器。两条路径共用一套偏移/吸附/浮起逻辑，靠这个来源标记区分谁能收尾。
enum _DiscDragSource {
  pointerDrag,
  longPress,
}

/// 二级页面悬浮播放器本体（[MiniPlayer] 的二级悬浮模式）。
///
/// 展开态：扁平圆角悬浮条（封面 + 歌曲信息 + 播放控制 + 切歌，点击进
/// 完整播放页）。收起态：底部居中圆形唱片，封面随播放旋转，点击仅展开
/// 播放器。两态之间用圆角/尺寸/透明度连续过渡。
class SecondaryMiniPlayer extends StatefulWidget {
  const SecondaryMiniPlayer({
    super.key,
    required this.collapsed,
    required this.onRequestExpand,
  });

  final ValueListenable<bool> collapsed;
  final VoidCallback onRequestExpand;

  @override
  State<SecondaryMiniPlayer> createState() => _SecondaryMiniPlayerState();
}

class _SecondaryMiniPlayerState extends State<SecondaryMiniPlayer>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  // 形变进度：0=展开圆角条，1=收起圆盘（弹簧一次性过渡，保留 vsync）
  late final AnimationController _morph;
  // 唱片旋转：播放中且可见且处于圆盘态（_morph>0，展开态不转）时由共享节拍
  // 折半到 30fps 步进，暂停/不可见时停住保留角度
  late final AnimationController _spin;
  // 圆盘累计角度（弧度，只增不减）：形变进度只调制转速，不参与角度本身，
  // 因此收起→展开不会把封面倒回原位。见 [_onSpinTick]。
  double _discAngle = 0;

  // 圆盘直径 / 胶囊高度（跨文件底栏几何收口，见 BottomChromeDimens.discDiameter）
  static const double _disc = BottomChromeDimens.discDiameter;

  /// 长按浮起的幅度：上移 6dp + 放大 3.5%。
  ///
  /// 都刻意压小：展开态胶囊宽约 368dp，3.5% 已是 13dp 的宽度变化，再大就顶到左右
  /// 16dp 内边距，读起来像「变形」而不是「被捏起来」。
  static const double _kLiftRise = 6.0;
  static const double _kLiftScale = 1.035;

  /// 浮起投影的浓度与模糊半径（dp）：贴合时不画，随浮起进度线性建立。
  static const double _kLiftShadowAlpha = 0.28;
  static const double _kLiftShadowBlur = 24.0;

  /// 全屏播放器展开到此进度时本卡片 opacity 已为 0（不可见）。
  static const double _kInvisibleExpansion = kCapsuleInvisibleExpansion;

  /// 设计像素锚点（`DisplayScaleReference` 暴露的 RenderObject）。
  ///
  /// 与常驻条同一口径：点击那一刻量胶囊自身 box 的矩形必须落在**锚点空间**
  /// （设计像素），非 1.0 显示档下量窗口像素会偏 s 倍。锚点在第 2 帧才挂上，
  /// 故在 [didChangeDependencies] 缓存（挂载会再次触发回填）。不在
  /// `DisplayScaleScope` 内时为 null → 回退根空间，与常驻条一致。
  RenderObject? _scaleAnchor;

  /// 本胶囊所属的页面路由（挂载期登记进 [BottomBarMorphRegistry]，卸载时移除）。
  Route<dynamic>? _capsuleRoute;

  /// 是否已挂在共享 60fps 帧驱动上。
  bool _boundToDriver = false;

  /// 由 build 计算出的「播放中 + 卡片可见」（含无歌 / 车机模式 / 全屏已展开）。
  bool _shouldSpin = false;

  /// 最近一次收口的输入（expansion / isPlaying）：供形变收敛回调
  /// [_onMorphStatusChanged] 用**同一组输入**重算。build 的两条早退也会写进来
  /// (0, false)，收敛回调因此不可能把已被早退收口掉的旋转复活。
  double _lastSpinExpansion = 0.0;
  bool _lastSpinPlaying = false;

  /// 共享节拍计帧奇偶：奇数帧整帧丢弃、偶数帧步进（圆盘 30fps 折半，
  /// 见 [_onSpinTick]）。归属 State 实例，解绑/重绑不归零。
  int _spinTickCount = 0;

  /// TickerMode 是否被关闭（被不透明路由覆盖 / TabBarView 切走）。
  bool _tickerModeMuted = false;

  /// App 是否退到后台。
  bool _appSuspended = false;

  /// 系统「移除动画」（reduced-motion）：在 [didChangeDependencies] 缓存
  /// `MediaQuery.disableAnimationsOf`（该值经 dependencies 传播），各动画**驱动前**
  /// 判一次，不在每帧读 MediaQuery。命中时形变/吸附/浮起瞬时落位、圆盘停转
  /// （计划 §1.3 矩阵；跟手交互本身不受影响，只是去掉补间）。
  bool _reduceMotion = false;

  // —— 折叠态拖拽 + 吸附（浮起就是这个状态的视觉标记）——
  /// 拖拽/吸附过程中的水平偏移（相对当前停靠位）。用 ValueNotifier 驱动
  /// Transform.translate，避免每帧 setState（铁律 40.2）。
  final ValueNotifier<double> _dragOffset = ValueNotifier<double>(0);
  /// 吸附动画（一次性 forward，禁 repeat —— 铁律 40.1）。
  late final AnimationController _snap;
  /// 吸附动画起点（松手时的残余偏移，动画中按曲线归零）。
  double _snapStartOffset = 0;
  /// 当前拖拽会话的来源；null = 未被拾起。
  ///
  /// 只有一个会话，因为同一根手指只有一条识别器路径能活下来：移动越过 slop 由拖动
  /// 识别器接手，原地按住满 500ms 由长按识别器接手（此时拖动识别器已被淘汰）。
  /// 所以「拾起后继续拖」必须由长按自己的 move 事件驱动，见 [_onLongPressMoveUpdate]。
  _DiscDragSource? _dragSource;
  /// 长按拾起路径上，上一次手指上报的本机 x，用于差分出移动增量
  /// （见 [_onLongPressMoveUpdate]）。
  double? _longPressLastLocalX;

  /// 浮起进度：0=贴合原位，1=已拾起（可拖拽态）。一次性过渡（拾起 forward、
  /// 松手 reverse），不常驻；按压反馈必须跟手，故保持满帧而非挂共享 60fps 节拍
  /// （AGENTS §10.2）。震动走设置页「震动反馈 → 悬浮播放器拖拽」。
  late final AnimationController _lift;
  /// 浮起整形：上升用 easeOut（拾起即到位），回落用 easeIn（松手自然落下）。
  late final Animation<double> _liftCurve;
  /// 拖拽偏移 + 浮起进度的合并驱动源：两者都要重排同一组 Transform 层，
  /// 合用一个 AnimatedBuilder 才能少一层嵌套、也让浮起复用拖动那层的短路复用。
  late final Listenable _offsetAndLift;

  /// 形变进度（[_morph]）与展开进度（[playerExpansion]）的合并驱动源：
  /// 交接语义（底色/文字淡出、封面让位）随展开进度逐帧变化，形态几何随形变
  /// 进度变化，两者共用一个 AnimatedBuilder —— 只重挂稳定子树、不重建内容。
  late final Listenable _morphAndExpansion;

  // 收起为圆盘时，环形进度/封面需要跟随唱片旋转。
  // 若把 _spin 直接驱动在动画链上：展开态旋转为 0（_spin.value*0），
  // 但 kAnimationListener 仍会被 controller 通知；而 FadeTransition 只是
  // 视觉 alpha=0，底座仍在布局，整个环每秒 12 次重建而无谓开销。

  /// 封面的基准尺寸：既是解码名义尺寸，也是封面圆内层布局盒的边长。
  /// 取两态封面可见尺寸的最大值（展开 58），保证放大清晰；实际可见尺寸由 raster
  /// 上的 Transform.scale 承担，解码尺寸与布局盒恒定不重解码，
  /// 消除形变逐帧改尺寸导致的封面闪烁（旧实现的隐形 bug 源之一）。
  static const double _kCoverDecode = 58.0;

  // —— 进度指示（设置页可关，见 [kSecondaryPlayerProgressEnabled]）——
  // 几何常量见文件作用域（State 与 [_SecondaryProgressPainter] 共用）。

  /// 播放进度（0..1）。只驱动 [CustomPaint] 重绘，不走 setState（§10.4.2）。
  final ValueNotifier<double> _progress = ValueNotifier<double>(0);
  Timer? _progressTimer;
  /// build 算出的「该不该采样」，与挂起态一起决定定时器是否运行。
  bool _progressWanted = false;
  /// 是否绘制进度指示（开关开 + 时长已知）。与采样门分开：暂停时仍要显示当前进度。
  bool _progressPaintOn = false;
  PlayerProvider? _progressPlayer;

  @override
  void initState() {
    super.initState();
    _morph = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
      value: widget.collapsed.value ? 1.0 : 0.0,
    );
    // 弹簧终态重算收口：形变收敛不保证伴随末帧 build，漏掉会让展开态的
    // 共享节拍订阅残留（见 [_onMorphStatusChanged]）。dispose 成对解绑。
    _morph.addStatusListener(_onMorphStatusChanged);
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    );
    widget.collapsed.addListener(_onCollapsedChanged);
    // 进度指示开关是设置页的离散操作，切换时整条 bar 重建一次即可（不参与动效帧）。
    kSecondaryPlayerProgressEnabled.addListener(_onProgressSwitchChanged);
    WidgetsBinding.instance.addObserver(this);
    _snap = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    // 吸附动画推进：残余偏移按 easeOutCubic 归零（Align 已切到新槽位，
    // 两者叠加的净效果即"圆盘滑向槽位"）。
    _snap.addListener(() {
      final t = Curves.easeOutCubic.transform(_snap.value);
      _dragOffset.value = _snapStartOffset * (1 - t);
    });
    _lift = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 140),
      reverseDuration: const Duration(milliseconds: 220),
    );
    // CurvedAnimation 只在这里建一次：放进 builder 里会每帧给 _lift 多挂一个监听。
    _liftCurve = CurvedAnimation(
      parent: _lift,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    // 拖动偏移与浮起共用一层驱动（见 [_buildMorph]），合并监听器同样只建一次。
    _offsetAndLift = Listenable.merge([_dragOffset, _liftCurve]);
    // 展开交接与形态几何合用一个驱动源（同上，只建一次）。
    _morphAndExpansion = Listenable.merge([_morph, playerExpansion]);
  }

  /// 共享 `Timer` 不受 `TickerMode` 约束（§10.3），必须自行同步挂起。
  ///
  /// 用 `TickerMode.valuesOf(context).enabled` 而非已弃用的 `TickerMode.of`
  /// （后者自 v3.35 起 deprecated）；`.enabled` 与旧 `of` 语义等价。
  ///
  /// 同时在此缓存 `MediaQuery.disableAnimationsOf`（[_reduceMotion]）：该值经
  /// dependencies 传播，缓存后各处动画只在**驱动前**读一次，不在每帧读 MediaQuery。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 登记「本胶囊所属的页面路由」，供形态交棒核对「被 push/pop 的那一页挂不挂
    // 播放条」（挂不成胶囊的页面 —— 设置子页等 —— 要撤销交棒，见
    // BottomBarMorphRegistry.hasCapsuleForRoute）。必须在 dependencies 时机取：
    // ModalRoute.of 是 InheritedWidget 依赖，initState 里不能用。
    final route = ModalRoute.of(context);
    if (!identical(route, _capsuleRoute)) {
      BottomBarMorphRegistry.instance.detachCapsuleRoute(_capsuleRoute);
      _capsuleRoute = route;
      BottomBarMorphRegistry.instance.attachCapsuleRoute(route);
    }
    // 设计像素锚点每帧都可能被回填（DisplayScaleAnchor 第 2 帧才挂上），
    // 必须在早退之前无条件刷新（与常驻条一致）。
    _scaleAnchor = DisplayScaleReference.anchorOf(context);
    final bool muted = !TickerMode.valuesOf(context).enabled;
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (muted == _tickerModeMuted && reduceMotion == _reduceMotion) return;
    // reduced-motion 翻转必须重算一次收口：圆盘旋转（_syncSpin）把它当作收口
    // 条件，开关在页面停留期间被系统切换时不能等下一次 build 才停转/复转。
    _tickerModeMuted = muted;
    _reduceMotion = reduceMotion;
    _syncSpin();
    _syncProgress();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool suspended = state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached;
    if (suspended == _appSuspended) return;
    _appSuspended = suspended;
    _syncSpin();
    _syncProgress();
  }

  void _onCollapsedChanged() {
    // 用弹簧物理驱动形变：弹簧取 [M3ExpressiveMotion.kMorphSpring]，收敛判据取
    // [M3ExpressiveMotion.kMorphSpringTolerance]（非框架默认值——默认 1e-3 会在
    // 画面到位后空跑约 460ms，实测口径与禁止归一回默认的说明见该常量的注释）。
    // snapToEnd 保证结束瞬间精确落到目标，不留残差。
    final target = widget.collapsed.value ? 1.0 : 0.0;
    if (_reduceMotion) {
      // 系统「移除动画」：形变换成瞬时落位（jump，不播仿真）。
      // AnimationController 的 `value=` 会 stop 仿真、按端点更新状态并
      // `_checkStatusChanged()`，故 [_onMorphStatusChanged] 仍收到
      // completed/dismissed → [_setShouldSpin] 照常重算，收口不漏。
      _morph.value = target;
      return;
    }
    _morph.animateWith(
      SpringSimulation(
        M3ExpressiveMotion.kMorphSpring,
        _morph.value,
        target,
        _morph.velocity,
        tolerance: M3ExpressiveMotion.kMorphSpringTolerance,
        snapToEnd: true,
      ),
    );
  }

  /// 由 build / 展开进度回调整理出的"应当旋转"条件，收口到唯一入口。
  void _setShouldSpin(double expansion, bool isPlaying) {
    _lastSpinExpansion = expansion;
    _lastSpinPlaying = isPlaying;
    // 全屏播放器展开时本卡片 opacity=(1-exp)→0；[DraggablePlayerRoute] 是
    // `opaque => false`（full_player_route.dart:600），被它覆盖**不会**触发
    // TickerMode 关闭，故必须在此显式判定，否则「打开全屏播放器后悬浮唱片
    // 仍在不可见地旋转」——§10.4.3 最典型的漏电点。
    // 形变维度：展开态 `_morph.value == 0` 时圆盘角度步进被它乘成 0（见
    // [_onSpinTick]），圆盘实际不转，但 `_spin` 作为 AnimatedBuilder 的唯一
    // 通知源仍每 16ms 推进 → 画面静止也在每 16ms 提交一帧。真在转才挂节拍。
    _shouldSpin =
        isPlaying &&
        expansion < _kInvisibleExpansion &&
        _morph.value > 0;
    _syncSpin();
  }

  /// 形变弹簧收敛到端点时以**同一组输入**重算一次收口（此刻 [_setShouldSpin]
  /// 只会重新读 `_morph.value`）：展开态收敛到 0 后若没有末帧 build，这一步
  /// 是唯一的解绑时机，漏掉即共享节拍绑定残留（§10.4.3）。
  void _onMorphStatusChanged(AnimationStatus status) {
    if (status != AnimationStatus.completed &&
        status != AnimationStatus.dismissed) {
      return;
    }
    _setShouldSpin(_lastSpinExpansion, _lastSpinPlaying);
  }

  /// 唯一收口：仅在「播放中 + 可见 + 前台 + 圆盘真在转（形变 > 0）+ 系统未要求
  /// 移除动画」时挂共享节拍（幂等）。
  ///
  /// reduced-motion 作为此处的收口条件而不是另起一条判定：装饰性循环在
  /// 「移除动画」下不应存在，且不需要第二条 Timer/驱动路径——不订阅即
  /// [_onSpinTick] 不再被调用，圆盘停在当前角度、零帧提交。
  void _syncSpin() {
    final bool shouldRun =
        _shouldSpin &&
        !_tickerModeMuted &&
        !_appSuspended &&
        !_reduceMotion;
    if (shouldRun == _boundToDriver) return;
    if (shouldRun) {
      PlayerFrameDriver.instance.addListener(_onSpinTick);
    } else {
      PlayerFrameDriver.instance.removeListener(_onSpinTick);
    }
    _boundToDriver = shouldRun;
  }

  /// 共享节拍回调：按转一圈时长步进旋转值（0→1 循环），折半到 30fps。
  ///
  /// 用步进 `.value` 而不是 `repeat()`：controller 的 Ticker 不会被启动，
  /// 帧生产由 16ms 共享定时器限制到 60fps（`repeat()` 会让 120Hz 屏整页
  /// 保持 120fps，见 AGENTS.md §10.1.1 / §10.4.1）。在此基础再折半：圆盘
  /// 12s/圈，60fps 下单帧角度差 0.6° 远小于视觉分辨力（§10.2 降档判据），
  /// 于是奇数 tick 整帧丢弃、偶数 tick 用 `2×stepRatio` 同时步进 `_spin.value`
  /// 与 `_discAngle`——**角速度守恒**（每帧约 1.2°），只是帧提交减半。
  /// 仍订阅共享节拍、不自建 Timer（§10.3 防多路 Timer 相位错开顶高整页帧率）。
  void _onSpinTick() {
    final int ms = _spin.duration?.inMilliseconds ?? 0;
    if (ms <= 0) return;
    final bool stepFrame = _spinTickCount.isEven;
    // 计数器不归零：解绑/重绑只让首个步进最多错开一帧的相位，角速度不变。
    _spinTickCount++;
    if (!stepFrame) return;
    final double stepRatio = 2 * PlayerFrameDriver.step.inMilliseconds / ms;
    // [_spin] 如今只充当"该重绘了"的通知源（AnimatedBuilder 监听它），
    // 封面角度另存于 [_discAngle]。
    _spin.value = (_spin.value + stepRatio) % 1.0;
    // 转速随形变进度渐入（展开态不转、圆盘全速），但**角度是累加的**：
    // 旧写法 `angle = _spin.value * 2π * t` 把播放相位乘上形变进度，收起瞬间会把
    // 封面强行扫到"当时的播放相位"角度（同一配置实测 0°→280.8°，上限 360°、
    // 取值取决于手势时刻），展开时又原路倒回 0°。
    _discAngle =
        (_discAngle + stepRatio * 2 * math.pi * _morph.value) %
        (2 * math.pi);
  }

  /// 进度采样的唯一收口：只在「开关开 + 播放中 + 时长已知 + 卡片可见 + 前台」时
  /// 跑 2fps 定时器，其余状态立即停表（§10.4.3 的"不可见仍在产帧"漏电点）。
  ///
  /// 采样值直接读 [PlayerProvider.position]（~200ms 上报一次 + 音频层真值），
  /// 不订阅 `positionNotifier`：那条通道是 5fps，比进度指示需要的 2fps 更密，
  /// 挂上去等于凭空多一个高频帧源（§10.4.4 只要求高频数据**不要**走全量
  /// notifyListeners，这里连订阅都不需要）。
  void _syncProgress() {
    final player = _progressPlayer;
    if (player != null) _progress.value = _computeProgress(player);
    final shouldRun =
        _progressWanted &&
        !_tickerModeMuted &&
        !_appSuspended &&
        playerExpansion.value < _kInvisibleExpansion;
    if (shouldRun && _progressTimer == null) {
      _progressTimer = Timer.periodic(
        _kProgressInterval,
        (_) => _sampleProgress(),
      );
    } else if (!shouldRun && _progressTimer != null) {
      _progressTimer!.cancel();
      _progressTimer = null;
    }
  }

  /// 早退路径（无歌曲 / 车机模式）必须同时收口进度采样，否则不可见时定时器仍在产帧
  /// （§10.4.3）。
  void _haltProgress() {
    _progressWanted = false;
    _progressPaintOn = false;
    _syncProgress();
  }

  /// 卡片两条装饰驱动（圆盘旋转 / 进度采样）的**收口实现**：按当前播放态重算
  /// 「应当旋转 / 应当采样」，交由 [_syncSpin] / [_syncProgress] 幂等落到挂/解绑。
  ///
  /// 调用点（非让位期）：
  /// ① 卡体自身 build（[PlayerProvider] / [ThemeProvider] / [CarModeProvider] 等
  ///    依赖变化 → 播放/暂停、切歌、车机翻转）；
  /// ② 外层窗口收敛到端点那一帧（见 [build] 的 `!standDown` 分支）—— 卡体作为
  ///    外层 `ValueListenableBuilder` 的 `child` 不会因 `standDown` 翻转重建，
  ///    让位期解绑的驱动少了这一步就不会重挂（§10.4.3 反向漏电）。
  ///
  /// 进度指示：绘制门只看「开关 + 时长已知」（暂停时仍要显示当前进度），采样门
  /// 再加播放态 —— 暂停/无时长时不该跑定时器（§10.4.3）。
  void _armDrivers(PlayerProvider player) {
    _setShouldSpin(playerExpansion.value, player.isPlaying);
    _progressPlayer = player;
    _progressPaintOn =
        kSecondaryPlayerProgressEnabled.value && player.duration != null;
    _progressWanted = _progressPaintOn && player.isPlaying;
    _syncProgress();
  }

  /// [build] 的收敛端点兜底：`!standDown` 时按**当前**播放态收口驱动。
  ///
  /// 只做命令式收口、不建立依赖（依赖仍由卡体自身的 build 持有，此处不需要：
  /// 播放态变化会经卡体重建走 [_armDrivers]，本方法只补「让位收敛」这一个触发）。
  /// 无歌 / 车机模式与卡体早退同款：解绑。幂等。
  void _armDriversAtSettle(BuildContext context) {
    final player = context.read<PlayerProvider>();
    if (player.currentSong == null ||
        context.read<CarModeProvider>().enabled) {
      _setShouldSpin(0.0, false);
      _haltProgress();
      return;
    }
    _armDrivers(player);
  }

  void _onProgressSwitchChanged() {
    if (mounted) setState(() {});
  }

  void _sampleProgress() {
    final player = _progressPlayer;
    if (player == null) return;
    _progress.value = _computeProgress(player);
  }

  double _computeProgress(PlayerProvider player) {
    final total = player.duration?.inMilliseconds ?? 0;
    if (total <= 0) return 0.0;
    return player.position.inMilliseconds.clamp(0, total) / total;
  }

  /// 封面+环子树的绘制隔离层。
  /// 形变/旋转的中间帧只有本层外的 Transform 在动，内部封面/环不被逐帧
  /// 重绘（避免解码尺寸逐帧变化导致的封面闪烁）。
  final GlobalKey _coverRepaintKey = GlobalKey();

  @override
  void dispose() {
    BottomBarMorphRegistry.instance.detachCapsuleRoute(_capsuleRoute);
    _capsuleRoute = null;
    WidgetsBinding.instance.removeObserver(this);
    widget.collapsed.removeListener(_onCollapsedChanged);
    kSecondaryPlayerProgressEnabled.removeListener(_onProgressSwitchChanged);
    _morph.removeStatusListener(_onMorphStatusChanged);
    if (_boundToDriver) {
      PlayerFrameDriver.instance.removeListener(_onSpinTick);
      _boundToDriver = false;
    }
    _snap.dispose();
    _lift.dispose();
    _dragOffset.dispose();
    _morph.dispose();
    _spin.dispose();
    _progressTimer?.cancel();
    _progressTimer = null;
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 形态交叉过渡期间让位（详见 `kBottomBarFormProgress`）：过渡由
    // [BottomBarMorphOverlay] 独占那一根条，胶囊真身不画自己（否则同屏两条 /
    // 中段双影）。订阅进度而非一次性读值 —— 进出窗口时本条才重建。
    // 让位期间两条装饰驱动（圆盘旋转 / 进度采样）必须一并收口，否则不可见仍在
    // 产帧（AGENTS §10.4.3），与下面两条早退同款处理。
    //
    // **让位 = 保挂载、不绘制**（`Offstage`），不是卸载子树（旧写法
    // `SizedBox.shrink()`）：卸载会让封面 State 在交棒首帧重建，本地音乐的封面
    // 走本地字节路径 → 重新异步读字节 → 「交棒瞬间封面闪烁」。`Offstage` 只跳过
    // paint/hit-test（layout 照跑），State 与 `ImageProvider` 实例跨飞行窗口
    // 存活。**树形必须跨帧稳定**（`Offstage` 恒在、只翻 `offstage` 标志），否则
    // 槽位类型变化仍会整棵卸载重建。
    //
    // **卡体作为 `child` 传入**（见 [_SecondaryPlayerCardBody]）：窗口内每帧只翻
    // `Offstage` 标志，卡体实例恒定 → `Element.updateChild` 短路，不再逐帧重建
    // 整棵卡片（AGENTS §10）。卡体自己持有全部 `watch` 依赖；
    // 随 `standDown` 变化的**副作用**留在本 builder 内（不能进 `child` —— `child`
    // 只在**外层 State 重建**时才换新实例，`standDown` 翻转不会让外层重建）。
    return ListenableBuilder(
      // 让位判据读窗口开关 + 源端标记（见 [bottomBarFormFlightListenable]）。
      listenable: bottomBarFormFlightListenable,
      child: _SecondaryPlayerCardBody(this),
      builder: (context, child) {
        // 胶囊端：窗口内**只有目的形态是常驻条时**让位（源形态留在画上，由浮层盖住）。
        final bool standDown = barFormRealBarStandsDown(true);
        if (standDown) {
          // 让位期收口：让位被覆盖、几何随转场抖动，两条装饰驱动必须按下
          // （§10.4.3）。卡体此刻不重建（`child` 实例恒定），故这一步只能在此。
          _setShouldSpin(0.0, false);
          _haltProgress();
        } else {
          // 窗口收敛到端点那一帧（`standDown` 真→假）：卡体**不会**因标志翻转而
          // 重建，故让位期解绑的旋转/进度驱动必须在这里补挂一次，否则收敛后圆盘
          // 停止旋转、进度停表（§10.4.3 的反向漏电）。与卡体 build 内的收口
          // 同源、均幂等（[_syncSpin]/[_syncProgress] 内部比对目标态）。
          _armDriversAtSettle(context);
        }
        return Offstage(
          offstage: standDown,
          child: TickerMode(
            enabled: !standDown,
            child: child!,
          ),
        );
      },
    );
  }

  Widget _buildPlayerCard(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final song = player.currentSong;
    // 注意：两条早退都必须先收口驱动，否则 `_shouldSpin` 会残留上一次的 true，
    // 表现为「已经不可见却仍在产帧」（§10.4.3）。
    if (song == null) {
      _setShouldSpin(0.0, false);
      _haltProgress();
      return const SizedBox.shrink();
    }
    // 车机模式：播放器常驻侧边面板，任何界面都不显示悬浮播放器（沿用现有规则）。
    if (context.watch<CarModeProvider>().enabled) {
      _setShouldSpin(0.0, false);
      _haltProgress();
      return const SizedBox.shrink();
    }
    // 持续登记胶囊宿主矩形（设计像素、锚点空间、底端到屏底），供形态交叉过渡
    // 浮层取胶囊端点。与 `_captureMorphScene` 同一个 box、同一量法。
    // 飞行期不登记（与常驻条同款门控）：此刻的登记值带转场平移量或让位期抖动，
    // 写进去只会污染端点快照。
    // 判据读**实时的** [inBottomBarFormFlight]（而非外层传入的快照）：卡体是稳定
    // 实例、不随 `standDown` 翻转重建，实时读值才能始终与当前窗口状态一致。
    if (!inBottomBarFormFlight()) _scheduleRegisterCapsuleRect();
    // 飞行期只挂载不绘制：不重挂旋转/进度驱动，否则「保挂载」会变成「恢复产帧」
    // —— 形状还是那个形状，只是驱动收口继续按下（§10.4.3）。让位期解绑 → 收敛
    // 后由外层 builder 的 [_armDriversAtSettle] 补挂（卡体自身不重建）。
    if (!inBottomBarFormFlight()) {
      _armDrivers(player);
    }
    final cs = Theme.of(context).colorScheme;
    final useBackgroundImage = context.watch<ThemeProvider>().useBackgroundImage;

    // 完整播放页展开时的交接（取代原「整条按 playerExpansion 淡出」）：
    // 底色/文字在 p∈[0,0.15] 内快速淡出、封面二进制让位给飞行层，
    // 具体曲线见 [capsuleChromeOpacity] / [capsuleCoverOpacity] 与 [_buildMorph]。
    // 本层只负责展开进度的收口（驱动解绑 / 进度采样）与展开期间的指针屏蔽。
    return ValueListenableBuilder<double>(
      valueListenable: playerExpansion,
      builder: (context, exp, child) {
        // 展开/收起过程中重新收口：exp 变化不会触发本 widget 的 build。
        // 飞行期跳过（同上：形状保挂载，驱动不重挂）—— 判据读实时的
        // [inBottomBarFormFlight]（卡体是稳定实例，不能依赖外层传入的快照）。
        if (!inBottomBarFormFlight()) {
          _setShouldSpin(exp, player.isPlaying);
          _syncProgress();
        }
        return IgnorePointer(ignoring: exp > 0.5, child: child);
      },
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Pad（最短边 ≥600dp，`isPadLayout` 口径把横屏手机排除在外）：
              // 悬浮条不再横贯全屏 —— 轨道限宽到 [kSecondaryPlayerPadMaxWidth]
              // 并右下停靠。形变全程只在轨道内发生，收起/展开时封面不会横扫整屏。
              // 手机（含横屏）走原路径：轨道 = 可用宽度、底部居中，零变化。
              final bool pad = isPadLayout(context);
              final double trackW = pad
                  ? math.min(constraints.maxWidth, kSecondaryPlayerPadMaxWidth)
                  : constraints.maxWidth;
              // 停靠位驱动对齐：默认（启动装载后）手机=center、Pad=right；
              // 拖拽吸附后切换。展开态胶囊与折叠态圆盘共用同一停靠侧，
              // 形变过程中盒子始终朝停靠侧收拢，视觉连续。
              return ValueListenableBuilder<SecondaryPlayerDockSide>(
                valueListenable: kSecondaryPlayerDock,
                builder: (context, dock, _) {
                  // 与形变进度无关的重子树：每次外层构建只造一次实例，逐帧靠
                  // 「同一 Widget 实例」让 Element.updateChild 直接短路跳过整棵
                  // 子树重建（实测旧写法每帧都在重建文字行 + 封面 + 两个按钮）。
                  final Widget coverCore = _coverCore(song);
                  final Widget row = _expandedRow(context, player, song, cs);
                  return AnimatedBuilder(
                    // 形变几何（_morph）与展开交接（playerExpansion）共用一层：
                    // 交接透明度随展开进度逐帧变化，稳定子树仍按实例短路复用。
                    animation: _morphAndExpansion,
                    builder: (context, _) => _buildMorph(
                      context,
                      cs,
                      trackW,
                      coverCore: coverCore,
                      row: row,
                      alignment: _dockAlignment(dock),
                      trackW: trackW,
                      useBackgroundImage: useBackgroundImage,
                      expansion: playerExpansion.value,
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  /// 停靠位 → Align 对齐（折叠态圆盘与展开态胶囊共用同一停靠侧）。
  Alignment _dockAlignment(SecondaryPlayerDockSide side) {
    switch (side) {
      case SecondaryPlayerDockSide.left:
        return Alignment.bottomLeft;
      case SecondaryPlayerDockSide.center:
        return Alignment.bottomCenter;
      case SecondaryPlayerDockSide.right:
        return Alignment.bottomRight;
    }
  }

  /// 当前停靠位在轨道内的圆盘左缘基准（轨道内坐标，`0 .. trackW - _disc`）。
  double _dockBase(SecondaryPlayerDockSide side, double maxDx) {
    switch (side) {
      case SecondaryPlayerDockSide.left:
        return 0.0;
      case SecondaryPlayerDockSide.center:
        return maxDx / 2;
      case SecondaryPlayerDockSide.right:
        return maxDx;
    }
  }

  /// 圆盘形态是否可拖拽（形变过半 = 折叠态）。
  ///
  /// 拾起反馈与拖动共用同一判据：展开态胶囊本来就不能拖，就不该给出「可拖拽」的
  /// 浮起提示，否则浮起在说谎。
  bool get _discDraggable => _morph.value >= 0.5;

  /// 拾起：浮起（= 进入可拖拽态）+ 震动。两个入口都走这里——直接拖动圆盘、
  /// 以及原地长按 —— 这样「浮起」始终等价于「现在能拖」，不再各说各话。
  ///
  /// [source] 记下会话归属，只有同一来源才能结束它（见 [_endDiscDrag]）。
  void _beginDiscDrag(_DiscDragSource source) {
    if (!_discDraggable) return;
    _dragSource = source;
    _snap.stop();
    // 震动可在设置页「震动反馈 → 悬浮播放器拖拽」关；浮起不受该开关影响，
    // 关掉震动也该看得出已经拾起来了。
    AppHaptics.longPress(HapticCategory.floatingPlayer);
    // 系统「移除动画」：浮起瞬时到位（跟手反馈在 reduced-motion 下让位，
    // 拾起态本身仍由 _lift 的值表达，圆盘照常可拖）。
    if (_reduceMotion) {
      _lift.value = 1.0;
    } else {
      _lift.forward();
    }
  }

  /// 拖动中的位移：钳制在轨道内（左缘 `0 .. trackW - _disc`）。
  void _moveDiscDrag(double dx, double trackW) {
    if (_dragSource == null) return;
    final double maxDx = trackW - _disc;
    final double base = _dockBase(kSecondaryPlayerDock.value, maxDx);
    _dragOffset.value = (_dragOffset.value + dx).clamp(-base, maxDx - base);
  }

  /// 结束会话：落回（退出可拖拽态）+ 吸附到最近槽位。
  ///
  /// 只认同一来源的结束事件：长按被识别后拖动识别器会收到一次 cancel，
  /// 反过来越过 slop 后长按也会 cancel —— 若不加这层判据，先到的那条会把
  /// 刚建立的会话直接结束掉，圆盘就变成"一动就吸附，拖不动"。
  void _endDiscDrag(_DiscDragSource source, double trackW) {
    if (_dragSource != source) return;
    _dragSource = null;
    // 系统「移除动画」：回落瞬时到位（同 _beginDiscDrag，落位仍由值表达）。
    if (_reduceMotion) {
      _lift.value = 0.0;
    } else {
      _lift.reverse();
    }
    _snapToNearestSlot(trackW);
  }

  /// 水平拖拽 + 松手吸附。仅折叠态（[_discDraggable]）生效；垂直滚动事件
  /// 不被抢占（用水平手势识别器），手指在圆盘上上下滑仍可滚动页面。
  void _onDiscHorizontalDragStart(DragStartDetails details) =>
      _beginDiscDrag(_DiscDragSource.pointerDrag);

  void _onDiscHorizontalDragUpdate(DragUpdateDetails details, double trackW) =>
      _moveDiscDrag(details.delta.dx, trackW);

  void _onDiscHorizontalDragEnd(DragEndDetails details, double trackW) =>
      _endDiscDrag(_DiscDragSource.pointerDrag, trackW);

  void _onDiscHorizontalDragCancel(double trackW) =>
      _endDiscDrag(_DiscDragSource.pointerDrag, trackW);

  /// 长按识别成功（按住满 500ms 且未越过 slop）= 原地拾起圆盘。
  ///
  /// 这一步同时把拖拽的主导权交给长按识别器（拖动识别器已被 arena 淘汰），
  /// 所以后续位移必须由 [_onLongPressMoveUpdate] 上报，否则长按会锁死拖拽 ——
  /// 这正是「浮起表示可拖拽、实际却拖不动」的冲突根源。
  void _onLongPressStart(LongPressStartDetails details) {
    // 用按下点作差分基准：否则拾起后的第一次移动会被当成"建立基准"而吃掉，
    // 手指先动的那一段没有响应（跟手性缺陷）。
    _longPressLastLocalX = details.localPosition.dx;
    _beginDiscDrag(_DiscDragSource.longPress);
  }

  /// 长按拾起后的手指移动 → 圆盘位移。
  ///
  /// 本 SDK 的 [LongPressMoveUpdateDetails] 只有 `localPosition` / `offsetFromOrigin`
  /// 系列、没有 `delta`，而 [_moveDiscDrag] 按增量累加，所以在这里自己差分上一次的
  /// 本机 x（首帧没有基准，位移按 0 处理）。
  void _onLongPressMoveUpdate(
    LongPressMoveUpdateDetails details,
    double trackW,
  ) {
    final double x = details.localPosition.dx;
    final double? last = _longPressLastLocalX;
    _longPressLastLocalX = x;
    if (last == null) return;
    _moveDiscDrag(x - last, trackW);
  }

  void _onLongPressEnd(double trackW) {
    _longPressLastLocalX = null;
    _endDiscDrag(_DiscDragSource.longPress, trackW);
  }

  /// 松手吸附：取圆盘左缘与三槽位（左/中/右）的最近者，切换停靠位并把
  /// 残余偏移动画归零（Align 瞬移到新槽位 + 反相补偿 = "圆盘滑向槽位"）。
  void _snapToNearestSlot(double trackW) {
    final double maxDx = trackW - _disc;
    final slots = <double>[0.0, maxDx / 2, maxDx];
    final double x =
        _dockBase(kSecondaryPlayerDock.value, maxDx) + _dragOffset.value;

    var best = 0;
    var bestDist = double.infinity;
    for (var i = 0; i < slots.length; i++) {
      final dist = (slots[i] - x).abs();
      if (dist < bestDist) {
        bestDist = dist;
        best = i;
      }
    }
    final target = SecondaryPlayerDockSide.values[best];
    _snapStartOffset = x - slots[best];
    if (kSecondaryPlayerDock.value != target) {
      kSecondaryPlayerDock.value = target;
      unawaited(
        SettingsRepository().setSecondaryPlayerDockRaw(target.name),
      );
    }
    if (_reduceMotion) {
      // 系统「移除动画」：瞬时落位——不播 220ms 吸附，残余偏移直接归零。
      // 写 _dragOffset 而不是 _snap.value=1.0：吸附的补间由 _snap 监听器换算，
      // 而 _snap.value 可能已停在端点（监听器是否重放不作依赖），落位结果只此一处真值。
      _snap.stop();
      _dragOffset.value = 0;
      return;
    }
    _snap
      ..stop()
      ..forward(from: 0);
  }

  /// [fullW] 是**轨道宽度**（Pad 下已按 [kSecondaryPlayerPadMaxWidth] 限宽）；
  /// [alignment] 由 [kSecondaryPlayerDock] 停靠位驱动（默认手机中下 / Pad 右下，
  /// 拖拽吸附后跟随切换），折叠态圆盘与展开态胶囊共用同一停靠侧。
  ///
  /// [coverCore] 与 [row] 是外层每次构建时造好、**与形变进度无关**的稳定子树：
  /// 逐帧只重新挂载同一实例，`Element.updateChild` 见实例相同即短路，整棵文字行 /
  /// 封面子树不再跟着 morph 重建。
  Widget _buildMorph(
    BuildContext context,
    ColorScheme cs,
    double fullW, {
    required Widget coverCore,
    required Widget row,
    Alignment alignment = Alignment.bottomCenter,
    double trackW = 0,
    bool useBackgroundImage = false,
    double expansion = 0.0,
  }) {
    // 弹簧可能过冲到 [0,1] 之外（实测 1.02% = 宽度 3.1dp）；框架已按 controller 的
    // 0.0/1.0 界 clamp 过一次，这里再取一次保证几何安全 —— 代价是回弹在画面上
    // 不可见，只剩尾段 ≤0.05dp 的微振。
    final t = _morph.value.clamp(0.0, 1.0);
    final w = _lerp(fullW, _disc, t);
    // 圆角 == 高度一半 → 两侧呈半圆（胶囊形）；左半圆与封面圆逐帧同心（见下方
    // 封面容器 left 恒 0），两者半径差即封面四周等宽的背景留白。
    final radius = _disc / 2;
    // 文字/按钮在前 60% 行程内淡出，收起后完全让位给圆盘。
    final textOpacity = (1.0 - t / 0.6).clamp(0.0, 1.0);
    // —— 展开交接（取代原「整条按 playerExpansion 淡出」）——
    // 底色/文字在 p∈[0,0.15] 内淡出；封面二进制让位给飞行层、不叠这条曲线。
    // 端点：p=0 两组都为 1（逐像素等价）；p=1 两组都为 0（整条不可见）。
    final chrome = capsuleChromeOpacity(expansion);
    final coverOpacity = capsuleCoverOpacity(
      expansion,
      layerWillDraw: PlayerCoverMorphBus.instance.coverLayerWillDraw,
    );
    final background = resolveMiniPlayerBackground(
      cs,
      useBackgroundImage: useBackgroundImage,
    );
    // 底色随交接淡出：alpha 按 chrome 缩放（p=0 时 chrome=1 → 与原值逐位相等）。
    final chromeBackground = chrome >= 1.0
        ? background
        : background.withValues(alpha: background.a * chrome);
    // —— 贯穿两态的封面（唯一贯穿两态的元素）——
    // 封面容器恒为 _disc(64)×_disc，封面圆按 [_kCoverDecode] 的实际尺寸画在容器
    // **正中**（见 [_cover]），故容器中心即封面圆心；容器左缘钉死在 0，于是封面圆
    // 在**每一帧**都与胶囊左半圆同心：
    //   圆角半径 32（= 高度一半）、封面半径 29 → 封面四周与背景之间恒为 3dp 等宽
    //     留白，收起过程中封面随左半圆一起平移到圆盘中心。
    //   旧写法 left = t·(w-64)/2 只在两端同心，中段封面会浮在胶囊内部、偏离左半圆
    //     圆心最大实测 38dp（两侧同时出现背景，视觉焦点散开）。
    //   圆盘态 w=64 → 左半圆圆心即圆盘中心，无需额外居中项。
    // 封面是唯一视觉焦点；进度指示要么走底边、要么走封面之外的 bezel，
    // 不压在封面上（见 [_SecondaryProgressPainter]）。

    return Align(
      alignment: alignment,
      child: AnimatedBuilder(
        // 拖动偏移与长按浮起合用这一层：浮起时只重建这几层 Transform，
        // GestureDetector 整棵子树作为稳定 child 被短路复用（同 coverCore / row）。
        animation: _offsetAndLift,
        builder: (context, child) {
          final k = _liftCurve.value;
          // 浮起三层**始终同形**（k=0 时都是单位变换）：若在 k=0 时直接返回内层子树，
          // 按住浮起的那一刻 widget 类型会变，GestureDetector 被换掉 Element，
          // 长按的 up 事件派发不到 onLongPressEnd —— 卡片会一直浮着不放（真机同样复现）。
          return Transform.translate(
            // 层级顺序有意义：拖动位移必须在**最外层**。若把拖动夹在浮起缩放里面，
            // 缩放会绕"未平移的盒中心"放大已偏移的圆盘，实测把圆盘再推 5dp（150dp
            // 拖拽 → 落点 155.25），拾起状态下就不跟手了。
            offset: Offset(_dragOffset.value, 0),
            child: Transform.translate(
              offset: Offset(0, -_kLiftRise * k),
              child: Transform.scale(
                scale: 1.0 + (_kLiftScale - 1.0) * k,
                // 投影画在 child 布局边界之外，Material 那层不透明表面盖住重叠部分，
                // 视觉上即"卡片离开了底面"。贴合时不给 boxShadow（同类型换装饰，
                // Element 不重建），避免静止态白画一层全透明阴影。
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(radius),
                    boxShadow: k <= 0
                        ? null
                        : <BoxShadow>[
                            BoxShadow(
                              color: cs.shadow.withValues(
                                alpha: _kLiftShadowAlpha * k,
                              ),
                              blurRadius: _kLiftShadowBlur * k,
                              offset: Offset(0, _kLiftRise * k),
                            ),
                          ],
                  ),
                  child: child,
                ),
              ),
            ),
          );
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: _onDiscHorizontalDragStart,
          onHorizontalDragUpdate: (d) => _onDiscHorizontalDragUpdate(d, trackW),
          onHorizontalDragEnd: (d) => _onDiscHorizontalDragEnd(d, trackW),
          onHorizontalDragCancel: () => _onDiscHorizontalDragCancel(trackW),
          // 长按只在该形态真能拖时才注册：一是「浮起=可拖拽」不该对展开态胶囊说谎，
          // 二是长按识别器一旦进场就会吞掉随后的 tap（按住满 500ms 再松手就连播放页
          // 都打不开了）。回调全为 null 时它根本不加入 arena，tap 照常派发。
          // tv: 拖拽圆盘调进度（横向拖 / 长按拾起拖）不适用——纯指针手势无按键
          // 等价，TV 上经完整播放页（遥控 TabBar/进度条）seek；点击展开/进播放页
          // 的 onTap 走下方 tap 路径不受影响。
          onLongPressStart: _discDraggable ? _onLongPressStart : null,
          onLongPressMoveUpdate: _discDraggable
              ? (d) => _onLongPressMoveUpdate(d, trackW)
              : null,
          onLongPressEnd: _discDraggable ? (_) => _onLongPressEnd(trackW) : null,
          onLongPressCancel: _discDraggable
              ? () => _onLongPressEnd(trackW)
              : null,
          onTap: () {
            AppHaptics.click(HapticCategory.navigation);
            if (_morph.value > 0.5) {
              widget.onRequestExpand(); // 收起态：点击只展开
            } else {
              // 展开态：点击进完整播放页 —— 采集此刻的真实几何作为展开起点。
              // 悬浮胶囊**从不写**全局锚点（只有常驻条写），不传场景的话
              // panelAnchorFor 只能读到常驻条留下的陈旧矩形或合成兜底，
              // 面板起点就会与用户点的这个控件对不上。
              openFullPlayer(context, scene: _captureMorphScene());
            }
          },
          child: Material(
            elevation: 0,
            // 底色与常驻条同源取色（复用 resolveMiniPlayerBackground），两形态切换零色差；
            // 壁纸档 0.2 是 2026-10-10 确认的决定，辨识度由胶囊既有投影（下方 shadow）承担。
            // 展开交接时 alpha 按 [chrome] 缩放（见上方 chromeBackground）。
            color: chromeBackground,
            borderRadius: BorderRadius.circular(radius),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: w,
              height: _disc,
              child: Stack(
                children: [
                // 文字信息 + 播放控制：随宽度收缩淡出，用 OverflowBox 保持
                // 全宽布局，收缩过程只裁剪不重排，避免文字挤压跳动。
                // 展开交接时另乘 chrome（与底色同一条曲线）。
                if (textOpacity > 0.01)
                  Positioned.fill(
                    child: IgnorePointer(
                      ignoring: t > 0.4,
                      child: Opacity(
                        opacity: textOpacity * chrome,
                        child: OverflowBox(
                          minWidth: 0,
                          maxWidth: fullW,
                          alignment: Alignment.centerLeft,
                          child: SizedBox(width: fullW, child: row),
                        ),
                      ),
                    ),
                  ),
                // 贯穿两态的封面：随左半圆平移到圆盘中心（left 恒 0，见上）。
                // 展开交接时**不整体淡出**，只在飞行层接管时二进制让位
                // （判据与常驻条封面、播放页 PlayerCoverSlot 同源）。
                Positioned(
                  left: 0,
                  top: 0,
                  width: _disc,
                  height: _disc,
                  child: Opacity(
                    key: const ValueKey('secondary-player-cover-handoff'),
                    opacity: coverOpacity,
                    child: _cover(t, coverCore),
                  ),
                ),
                // 进度指示：沿胶囊内缘包边一圈（展开态 = 跑道形，收起态 = 正圆，
                // 同一条轮廓连续变形）。描边落在封面与背景之间的 3dp bezel 上，
                // 既不压封面也不被圆角裁掉。
                // 属胶囊装饰性 chrome：随底色一起交接淡出（否则底色已透明、包边
                // 还留一圈线在屏底）。
                if (_progressPaintOn)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Opacity(
                        opacity: chrome,
                        child: CustomPaint(
                          key: const ValueKey('secondary-player-progress'),
                          painter: _SecondaryProgressPainter(
                            progress: _progress,
                            // 轨道压到 0.16：整圈闭合时它必须读作"待走的轨"，
                            // 再重就把胶囊读成"描边卡片"了（渲染对比后定值）。
                            trackColor: cs.onSurfaceVariant.withValues(
                              alpha: 0.16,
                            ),
                            activeColor: cs.primary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 展开态的文字信息 + 播放控制（封面已抽为贯穿两态的独立元素，故此处
  /// 左侧留出封面空位）。点击整体进完整播放页（由外层 GestureDetector 处理）。
  ///
  /// 左侧让位宽度取封面容器右缘：封面容器恒 64、展开 left=0 → 右缘 64
  /// （可视封面右缘 61），文字从 66 起笔，与封面留 5dp 间隙。
  ///
  /// **不接收形变进度**：这个子树要在 morph 逐帧之间保持同一实例才能被短路复用
  /// （见 [_buildMorph]），所以让位宽度取定值 66 —— 旧写法按 66→64 内插的 2dp
  /// 位移在文字淡出（前 60% 行程）过程中根本看不见，不值得为此逐帧重建。
  Widget _expandedRow(
    BuildContext context,
    PlayerProvider player,
    dynamic song,
    ColorScheme cs,
  ) {
    // 文字样式与常驻条、交叉过渡浮层同源（[playerBarTextStyles]）：两形态本就
    // 用同一份 bodyMedium / bodySmall(onSurfaceVariant)，槽位才能让飞行文字从
    // **完全一致**的起点样式起飞。
    final styles = playerBarTextStyles(context);
    return Padding(
      // 左侧让位给封面（容器右缘 64），右侧常规内边距。
      padding: const EdgeInsets.fromLTRB(66, 0, 10, 0),
      child: Row(
        children: [
          Expanded(
            // 歌名 + 歌手随展开一起形变：探针上报本块的屏幕矩形作为飞行起点，
            // 形变层接管后立即让位（判据与封面同源，同一时刻一起交棒）——
            // 这正是此前悬浮胶囊点开后"文字另起一拍"的直接原因。
            // 文字块与常驻条、交叉过渡浮层共用 [PlayerBarText]。
            child: PlayerBarText(
              song: song,
              titleStyle: styles.title,
              subtitleStyle: styles.subtitle,
              crossAxisAlignment: CrossAxisAlignment.center,
              textAlign: TextAlign.center,
            ),
          ),
          // 播放控制与常驻条、交叉过渡浮层共用 [PlayerBarTransport]。
          PlayerBarTransport(player: player),
        ],
      ),
    );
  }

  /// 采集本次展开的形态快照（点击那一刻）。
  ///
  /// [PlayerMorphScene.panelRect] 的口径与常驻条**完全一致**（含底部净空、
  /// 底端到屏底）：常驻条量的是"自身 render box 在锚点空间下的矩形"
  /// （`mini_player.dart` 的 `_onRawDown`），本胶囊量的是同一个 box —— 它把
  /// `SafeArea`（底部安全区）+ 12dp 底距 + 64dp 胶囊一起包住，底端即屏底。
  /// 量法照抄常驻条：`localToGlobal(ancestor: _scaleAnchor)` 取左上角，
  /// 尺寸取同一 box 的布局尺寸（同空间、同坐标系）。
  ///
  /// box 尚未布局（理论不可达：点击必然发生在已绘制之后）时退化为胶囊几何的
  /// 贴底条，绝不回落到桌面播放栏高那套（那是移动端根本不存在的形态）。
  PlayerMorphScene _captureMorphScene() {
    final MediaQueryData mq = MediaQuery.of(context);
    final double screenHeight = mq.size.height;
    final bool collapsed = _morph.value > 0.5;
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) {
      return capsuleMorphScene(
        panelRect: Rect.fromLTWH(
          0,
          math.max(0, screenHeight - BottomChromeDimens.discReservedBottom),
          mq.size.width,
          BottomChromeDimens.discReservedBottom,
        ),
        screenHeight: screenHeight,
        collapsed: collapsed,
      );
    }
    final Offset origin = box.localToGlobal(Offset.zero, ancestor: _scaleAnchor);
    return capsuleMorphScene(
      panelRect: origin & box.size,
      screenHeight: screenHeight,
      collapsed: collapsed,
    );
  }

  /// 持续登记胶囊宿主矩形（设计像素、锚点空间），供 `BottomBarMorphOverlay`
  /// 取形态交叉过渡的胶囊端点。
  ///
  /// 与 [_captureMorphScene] **同一个 box、同一量法**（含底部安全区 + 12dp 底距 +
  /// 64 胶囊，底端到屏底）。用 post-frame 排到本帧绘制之后，避免在 build/layout
  /// 里写登记簿触发 "setState during build"。
  ///
  /// **飞行窗口内不写**（[inBottomBarFormFlight]）：让位改成 `Offstage` 之后
  /// build/layout 仍在跑，这条回调也照旧会跑；此刻的几何带着转场平移量/让位期
  /// 抖动，写进去只会污染端点快照（调用点已用 `inBottomBarFormFlight()` 挡一层，
  /// 这里再自守一道，防止将来别处直接调它）。
  void _scheduleRegisterCapsuleRect() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (inBottomBarFormFlight()) return;
      final box = context.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final origin = box.localToGlobal(Offset.zero, ancestor: _scaleAnchor);
      BottomBarMorphRegistry.instance.capsuleRect = origin & box.size;
    });
  }

  /// 封面的稳定内核：只随歌曲变化，形变与旋转逐帧都不重建它（见 [_buildMorph]
  /// 的实例短路）。裁剪盒即封面圆的实际边界，尺寸恒为 [_kCoverDecode]。
  Widget _coverCore(dynamic song) {
    return ClipOval(
      child: SmartArtworkImage(
        artworkUri: song.artworkUri,
        fallbackFilePath: song.localPath,
        songId: song.id,
        size: _kCoverDecode,
        borderRadius: _kCoverDecode / 2,
      ),
    );
  }

  /// 贯穿两态的封面。容器恒为 [_disc]×[_disc]，封面圆以 `coverVisible` 为
  /// **实际直径**并居中于容器（容器中心 = 圆心）。
  ///
  /// **抗闪烁**：`SmartArtworkImage` 的 `size`/`borderRadius`/decode 恒为
  /// [_kCoverDecode]，ImageCache key 不随形变变化；封面可见尺寸的变化只由
  /// raster 上的 `Transform.scale` 承担，不触发重解码。
  ///
  /// **旋转与形变解耦**：角度取累加的 [_discAngle]，形变进度只出现在
  /// [_onSpinTick] 的转速调制里，所以收起→展开不会把封面倒回原位。
  Widget _cover(double t, Widget coverCore) {
    final coverVisible = _lerp(_kCoverDecode, 56.0, t);
    final coverScale = coverVisible / _kCoverDecode;

    return RepaintBoundary(
      key: _coverRepaintKey,
      child: SizedBox(
        width: _disc,
        height: _disc,
        // 内层必须显式按 [_kCoverDecode] 定尺寸：外层 SizedBox 下发的是 64×64 的
        // **紧**约束，而 Transform 不改约束（RenderTransform 把 constraints 原样
        // 交给子节点）。少了 Center + SizedBox 这层，ClipOval 就按 64×64 裁圆 ——
        // 封面与胶囊等高、上下边缘相切并顶穿背景圆角，coverScale 声称的
        // 「可见尺寸 58/56」也只是名义值。
        child: Center(
          child: SizedBox(
            width: _kCoverDecode,
            height: _kCoverDecode,
            // 封面形变的起点探针（与常驻条同款）：把封面圆的外接方框（解码 58，
            // 展开态可见尺寸）在锚点空间下的矩形上报给 [PlayerCoverMorphBus]，
            // 飞行封面才会从**胶囊的位置**起飞 —— 此前本文件完全没有这项上报，
            // 是"起点错位"的直接原因。
            //
            // 刻意包在 `Transform.scale` **外面**（仍在 58 的布局盒内）：
            // 量到的是稳定的 58×58 外接方框，不随形变/旋转逐帧抖动（放进
            // `Transform.scale` 里会让矩形每帧变化、每次都 `_bump` 形变层）。
            child: CoverGeometryProbe(
              onRect: (rect, _) =>
                  PlayerCoverMorphBus.instance.publishMini(rect),
              child: Transform.scale(
                scale: coverScale,
                child: AnimatedBuilder(
                  animation: _spin,
                  builder: (context, child) =>
                      Transform.rotate(angle: _discAngle, child: child),
                  child: coverCore,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 悬浮播放器的进度指示（设置页 [kSecondaryPlayerProgressEnabled] 可关）：**包边式**。
///
/// 进度沿胶囊**内缘**走一圈（底边 → 右半圆 → 顶边 → 左半圆），起点在封面正下方的
/// 切点、顺时针按周长比例推进。选包边而不是"底边一条线"的三个理由：
/// 1. 与胶囊同形状，不出现两端都不接边界的悬空线段；
/// 2. 收起成圆盘时中心线轮廓**自动退化为正圆**（直边长度归零、半径吃掉高宽差）→
///    两态是同一个元素的连续变形，不需要交叉淡入，形变中进度不跳位；
/// 3. 3dp 描边恰好铺满封面与背景之间那圈 3dp bezel（见 [_kProgressStroke]），
///    不压封面、不被圆角裁切。
///
/// 进度值**从 [progress] 现取**而非快照，配合 `CustomPaint(repaint:)`：2fps 的采样
/// 只重绘这一层，不重建任何 widget（AGENTS §10.4.2）。
class _SecondaryProgressPainter extends CustomPainter {
  _SecondaryProgressPainter({
    required this.progress,
    required this.trackColor,
    required this.activeColor,
  }) : super(repaint: progress);

  final ValueListenable<double> progress;
  final Color trackColor;
  final Color activeColor;

  /// 中心线轮廓与周长。只在尺寸变化时重建（同一实例被 `repaint:` 反复触发时命中缓存）。
  Size _rimSize = Size.zero;
  Path _rimPath = Path();
  PathMetric? _rimMetric;

  /// 构造中心线轮廓：从底边左切点出发顺时针绕一圈。
  ///
  /// 自己拼 line/arc 而不用 `Path.addRRect`，是为了**确定**起点与绕行方向 ——
  /// addRRect 的起点位置和绕向属实现细节，跨引擎版本不保证，而包边的"起点在封面
  /// 下方"是设计的一部分。
  void _buildRim(Size size) {
    if (size == _rimSize && _rimMetric != null) return;
    _rimSize = size;
    final double radius = (size.height - _kProgressStroke) / 2;
    final double cy = size.height / 2;
    // 直边端点：左/右半圆圆心 x，中心线上下边界
    final double xLeft = _kProgressInset + radius;
    final double xRight = size.width - _kProgressInset - radius;
    final double yBottom = size.height - _kProgressInset;
    final double yTop = _kProgressInset;
    final path = Path()
      ..moveTo(xLeft, yBottom)
      ..lineTo(xRight, yBottom)
      // 右半圆：底(π/2) → 右(0) → 顶(-π/2)。画布 y 轴向下，负绕向即视觉顺时针。
      ..arcTo(
        Rect.fromCircle(center: Offset(xRight, cy), radius: radius),
        math.pi / 2,
        -math.pi,
        false,
      )
      ..lineTo(xLeft, yTop)
      // 左半圆：顶(-π/2) → 左(π) → 底(π/2)，回到起点
      ..arcTo(
        Rect.fromCircle(center: Offset(xLeft, cy), radius: radius),
        -math.pi / 2,
        -math.pi,
        false,
      )
      ..close();
    _rimPath = path;
    for (final metric in path.computeMetrics()) {
      _rimMetric = metric;
      break;
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    // 宽度不足一个描边直径时没有"环"可言（形变极短帧 / 异常约束）
    if (size.width < size.height) return;
    _buildRim(size);
    final metric = _rimMetric;
    if (metric == null) return;

    canvas.drawPath(_rimPath, _stroke(trackColor));
    final p = progress.value.clamp(0.0, 1.0);
    if (p <= 0) return;
    canvas.drawPath(
      metric.extractPath(0, metric.length * p),
      _stroke(activeColor),
    );
  }

  Paint _stroke(Color color) => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = _kProgressStroke
    ..strokeCap = StrokeCap.round;

  @override
  bool shouldRepaint(_SecondaryProgressPainter oldDelegate) =>
      oldDelegate.trackColor != trackColor ||
      oldDelegate.activeColor != activeColor;
}

/// 悬浮胶囊的**卡体**：可复用、自带订阅的子树。
///
/// 作为 [SecondaryMiniPlayer] 的 [ValueListenableBuilder] 的 `child:` 传入 ——
/// 形态交叉过渡窗口（`0 < kBottomBarFormProgress < 1`）内，外层每帧只翻
/// `Offstage` 标志，本 widget 实例不变，`Element.updateChild` 短路跳过整棵卡片的
/// 重建（AGENTS §10：窗口帧不再逐帧重建约 50~80 节点）。
///
/// **订阅归属**（本次提取最容易做错的地方）：卡体的全部数据依赖
/// （`context.watch<PlayerProvider>` / `context.watch<CarModeProvider>` /
/// `context.watch<ThemeProvider>` / `Theme.of` …）都在
/// [_SecondaryMiniPlayerState._buildPlayerCard] 里、且以**本 widget 的 `context`**
/// 调用 —— 依赖因此挂在本 widget 的 Element 上，播放态 / 主题 / 车机模式变化仍会
/// 触发本子树重建，不会退化成「提取之后不再刷新」。
///
/// **随 `standDown` 变化的部分不进本 widget**（`child` 只在**外层 State 重建**时
/// 才换新实例，`standDown` 翻转不会让外层重建，放进来会失效）：让位期的驱动收口、
/// 以及「飞行期不重挂驱动」的判据，均由外层 builder 与
/// [_SecondaryMiniPlayerState._armDriversAtSettle] 承担；本 widget 内改读**实时的**
/// [inBottomBarFormFlight]，随其自身重建（播放态等）自然取到当前窗口态。
class _SecondaryPlayerCardBody extends StatelessWidget {
  const _SecondaryPlayerCardBody(this._state);

  final _SecondaryMiniPlayerState _state;

  @override
  Widget build(BuildContext context) => _state._buildPlayerCard(context);
}
