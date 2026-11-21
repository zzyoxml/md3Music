import 'package:dpad/dpad.dart';
import 'package:flutter/gestures.dart' show GestureBinding, PointerEvent;
import 'package:material_ui/material_ui.dart';

import '../core/build_flags.dart';
import '../core/theme/app_dimens.dart';
import '../core/utils/reveal_label.dart' show labelCharAlpha;

/// 文案擦出时长：**进入 240ms、收回 160ms**（退出短于进入，手感更利落）。
///
/// 刻意与发现页的问候胶囊（720ms）**脱钩**：那枚一次 App 运行只播一遍，慢得优雅；
/// 顶栏这颗每次点击都要播，720ms 的 easeOutCubic 尾段 220ms 只推进 10%，
/// 实测就是「点下去卡了一下」。
const Duration _kMorphIn = Duration(milliseconds: 240);
const Duration _kMorphOut = Duration(milliseconds: 160);

/// 收起态胶囊的**视觉**高度：与展开态同高，展开只变宽不变高，顶栏因此不跳行。
///
/// 32 而不是 40：顶栏行高由 IconButton 的 48 决定，胶囊 40 时上下各只剩 4dp，
/// 看着就是贴边、很挤；压到 32 后上下各 8dp，与发现页问候胶囊一个量级。
const double _kPillHeight = AppCapsule.cellHeight;

/// 每一格的**触控**高度（比视觉高出 [_kPillTouchPad] 上下各一圈）。
///
/// 视觉缩了不顺手把热区也缩掉：40×32 离 Material 的 48 地板更远。横向没法扩
/// （相邻格零间距，热区互扩会互相抢点击），纵向可以，于是视觉 32、热区 40。
const double _kPillTouchHeight = AppCapsule.cellTouchHeight;
const double _kPillTouchPad = AppCapsule.cellTouchPad;

/// 单个图标格的宽度（40；比胶囊视觉高度宽，收起态一格是横向小胶囊而非正圆）。
const double _kIconBox = AppCapsule.cellIconBox;

/// 文案段完全展开时右端的内边距。与发现页问候胶囊同值 —— 两枚胶囊的图标尺寸
/// 已归到同一刻度体系，右端内边距再各取一个值就没有理由。
const double _kLabelRightPad = AppCapsule.labelRightPad;

/// 格子进出场的时长（宿主 segments 增删时那一格的淡入/淡出 + 占宽推让）。
///
/// 只有 220ms：它由**真实状态变化**触发（定时起了、进房了、换了本地/在线歌），
/// 不是常驻循环动画，跑完就停，符合 AGENTS §10「不动手就不许持续产帧」。
const Duration _kPresence = Duration(milliseconds: 220);

/// 「这一格已经在眼前」的判定阈值：擦出进度只要**开始**（> 0）就算。
///
/// 旧版要求 `>= 1.0`（动画跑完才算展开到位），于是从第一帧到最后一帧的整段擦出里
/// 落下的点击全被当成「又一次展开」而无声吞掉 —— 用户明明看见文案正在擦出来，
/// 点了却没反应。收起态（reveal 恰为 0）那一格仍只负责展开，两步点击的语义不变。
const double _kOpenEnough = 0.0;

/// 「胶囊按钮收缩」开关（设置 → 播放页样式 → 顶栏与页签），默认开启。
///
/// 开启时竖屏把顶栏尾部的音质、睡眠定时、一起听与 ⋯ 合成一颗只露图标的胶囊，
/// 点一下先展开、擦出一开始再点就执行动作；关闭时文案常显、点一下就直接进房间 /
/// 开定时面板，但背景仍是同一颗连体胶囊（几格共用一个底，不各自分颗）。
///
/// 由 app.dart 启动引导从持久化载入、设置页即时同步；本组件直接订阅它，所以在
/// 播放器里改完设置回到顶栏就生效，不需要重进路由。宽屏恒为常显形态（顶栏有整行
/// 宽度可给，收缩只是省地方的手段），因此这个开关只影响是否「先展开再执行」。
///
/// 初值与 `SettingsRepository.getTopBarPillCollapse()` 的默认值保持一致。
final ValueNotifier<bool> kTopBarPillCollapseEnabled = ValueNotifier<bool>(true);

/// 顶栏尾部「音质 / 睡眠定时 / 一起听 / 更多」这一组的唯一实现。
///
/// **竖屏且「胶囊按钮收缩」开启（默认）**：合成一颗胶囊，只露图标 —— 顶栏由此不再
/// 挂几枚悬空元素，⋯ 也有了同色背景可依。带动作的格子点击是**两步**的：第一下只把
/// 被点的格子展开（擦出自己的文案），擦出一开始（不必等动画跑完）同一格的第二次
/// 点击就执行动作（选音质 / 进房间 / 开定时面板）。
///
/// **⋯ 与长按都是一步**：菜单入口和音量面板没有「先看清再按」的需求，两步只会让人
/// 以为按不动。没有动作的格子（本地歌曲的音质）点一下**只展开**，文案仍可读到。
///
/// **展开后不再定时自动收回**，改由按到胶囊以外时才收回：定一条 3 秒的倒计时，
/// 等于让慢用户在「第一下又只是展开」里循环，而这条倒计时本身也是顶栏上一处
/// 无人值守的持续产帧点（AGENTS §10）。
///
/// 格子的**进出场**同样带动画：宿主的 [segments] 会变（睡眠定时起停、加入/退出房间、
/// 本地与在线歌曲），增删那一格淡入/淡出并把占宽同步推让，整颗胶囊的宽度因此是
/// 滑过去的，不会在顶栏上蹦一下。格子按 [TopBarTrailingSegment.semanticsLabel]
/// 认身份而不是按下标 —— 下标在「中间那一格没了」时会整体串位，把展开状态留给
/// 错误的邻居。
///
/// 格子自己决定要不要参与这套收起：[TopBarTrailingSegment.collapseOnlyWithPeers]
/// 为真者（音质）只在还有别的胶囊在场时才缩成图标，单独一颗时文案照旧常显。
///
/// **宽屏或开关关闭**：同一颗连体胶囊，只是文案常显、点一下就直接执行。
///
/// 背景盖到 ⋯ **之前**为止（右端让开固定的一格宽）：⋯ 是裸图标，不属于胶囊本体。
/// 让开的是固定宽度而非「最右展开格」，而顶栏尾部整体右对齐、⋯ 恒在最右，所以
/// 文案擦出/收回时 ⋯ 的左缘不动，早期那种背景边缘跳动不会重现。胶囊（除 ⋯ 那格）
/// 的宽度只由内容决定：文案擦出时自然变宽，两端因此始终是半圆（从外面平裁会把右端
/// 切成一条平边）。
///
/// 展开动效照搬发现页的问候胶囊（`discover_page.dart` 的 `_buildGreetingPill`）：
/// 文案段自左向右擦出并逐字渐入，收窄作用在胶囊**内部**的文字段（ClipRect +
/// Align.widthFactor）。收回是同一条时间轴的镜像。
///
/// 顶栏中段那排页签圆点会为本组件的宽度让位，见 [PlayerTopBarTabDots]。
class TopBarTrailingCapsule extends StatefulWidget {
  const TopBarTrailingCapsule({
    super.key,
    required this.segments,
    required this.onMore,
    required this.background,
    required this.foreground,
    required this.dotColor,
    this.collapsible = true,
    this.moreIconColor,
    this.showBackground = true,
  });

  /// 尾部可展开项（睡眠定时、一起听……），按从左到右的顺序排。
  ///
  /// 增删这一列表就是格子的进/出场动画的触发源。格子身份按 `semanticsLabel` 认
  /// （不是下标，见 `_keyOf`），所以宿主每次重建列表都可以、也应该沿用同一个标签。
  final List<TopBarTrailingSegment> segments;

  /// 「更多」菜单动作。
  final VoidCallback onMore;

  /// 胶囊底色与前景色。两项在顶栏里本就同色（primaryContainer / AM 半透明白），
  /// 合并成一颗之后共用一个背景才没有分缝。
  final Color background;
  final Color foreground;

  /// 红点填充色（主题 error）。
  final Color dotColor;

  /// 本版形态是否允许「先展开、再执行」的两步点击 + 文案擦出动画：宿主传 `!wide`。
  ///
  /// 名字讲的是**行为**而不是「与 ⋯ 合并」—— 两种形态共用同一颗连体背景（⋯ 恒在
  /// 背景之外的裸图标），真正的区别只剩文案是擦出还是常显、点击是一次还是两步。
  /// 实际是否生效还要再看全局开关 [kTopBarPillCollapseEnabled]（设置 → 胶囊按钮收缩），
  /// 但那条开关**只管普通格**：音质的 `collapseOnlyWithPeers` 格按「有没有邻居」自己
  /// 决定收不收，开关关掉也照旧收。
  final bool collapsible;

  /// ⋯ 的图标色。⋯ 恒在胶囊底色**之外**（背景右端让开那一格），所以它要的是
  /// 「贴在页面背景上的裸图标」配色：AM 深色顶栏给白色，MD3 给 onSurfaceVariant。
  /// null 时退回 [foreground] 兜底。
  final Color? moreIconColor;

  /// 是否画那层连体底色（`StadiumBorder`）。宿主在**宽屏/横屏**传 false。
  ///
  /// 宽屏顶栏有整行宽度、文案又恒显，那块底色会把「一串各自独立的操作」框成
  /// 一块面板，压在封面/壁纸上尤其显脏；关掉之后每一格与 ⋯ 一样是裸图标 + 文案，
  /// 靠对齐与间距成组，而不是靠容器成组。
  ///
  /// 竖屏收缩态、以及「关掉胶囊按钮收缩开关」的常显态**仍然保留**连体底色：
  /// 那两态要么只露图标（需要底色才看得出是一组），要么本来就在实底页面上。
  final bool showBackground;

  @override
  State<TopBarTrailingCapsule> createState() => _TopBarTrailingCapsuleState();
}

class _TopBarTrailingCapsuleState extends State<TopBarTrailingCapsule>
    with TickerProviderStateMixin {
  late final AnimationController _morph = AnimationController(
    vsync: this,
    duration: _kMorphIn,
    reverseDuration: _kMorphOut,
  );

  /// 进出场动画：只在 segments 的键集合真的变了时跑一次（见 [_syncPresence]）。
  late final AnimationController _presence = AnimationController(
    vsync: this,
    duration: _kPresence,
    value: 1,
  );

  /// 两个控制器合用一条 AnimatedBuilder：擦出与进出场的帧都要在这里读值。
  late final Listenable _animations = Listenable.merge(<Listenable>[
    _morph,
    _presence,
  ]);

  /// 文案擦出：擦除宽度与逐字渐入共用这一个值（问候胶囊的节拍）。
  /// 背景不再分相位，所以整段时间轴都在擦文字，点下去不会先空半拍。
  late final CurvedAnimation _reveal = CurvedAnimation(
    parent: _morph,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  /// 已经**满宽**展开的格子。再点另一格时它们不跟随新一轮动画 ——
  /// 早期版本用单个 `_openIndex`，切换格子时前一格会在同一帧从满宽跳到 0，
  /// 这就是「先后按两个胶囊时的闪现」。
  ///
  /// 键是 `semanticsLabel` 而不是下标：中间那一格被移除时后面的下标会整体左移，
  /// 展开状态就会跑到邻居身上（音质展开着，邻居消失后定时那格凭空「已展开」，
  /// 点它一下直接执行）。见 [_keyOf]。
  final Set<String> _settled = <String>{};

  /// 本轮正在擦出的格子（收回时与 [_settled] 一起走镜像时间轴）。
  final Set<String> _fresh = <String>{};

  /// 当前**渲染**的格子：与 [TopBarTrailingCapsule.segments] 同源，但离场那几格在
  /// 淡出期间仍留在里面（按原位插回，越界则夹到新列表末尾）。
  late List<TopBarTrailingSegment> _rendered = List<TopBarTrailingSegment>.of(
    widget.segments,
  );

  /// 正在淡入 / 淡出的键。两者都空 = 没有进出场在飞（见 [_presenceAnimating]）。
  final Set<String> _entering = <String>{};
  final Set<String> _exiting = <String>{};

  /// 正在收回。**不用 AnimationStatus 推断**：`forward(from: 0)` 重置时间轴时状态
  /// 会途经 reverse/dismissed，那种瞬间把已展开的格子当成「正在收回」就等于把
  /// 闪现换了个触发路径。
  bool _retracting = false;

  /// `forward(from: 0)` 会先把值写成 0，那一次同步回调里状态是 dismissed，
  /// 而下面的状态监听把 dismissed 当作「收回落底」来清空展开集合 —— 重置时必须
  /// 绕开它，否则刚登记的格子当场又被清掉。
  bool _resetting = false;

  /// 「点到胶囊以外就收回」的全局指针路由是否已挂上（见 [_installDismissRoute]）。
  bool _dismissRouteInstalled = false;

  /// 胶囊本体（含 ⋯ 那一格）的全局定位用键，供 [_onGlobalPointer] 算命中矩形。
  final GlobalKey _hitKey = GlobalKey();

  /// 「钉住项自动展开」的排帧回调只挂一次的闸门（见 build 里的说明）。
  bool _autoOpenScheduled = false;

  /// 展开状态认身份用的键。两个宿主（MD3 / AM）用的标签各自唯一（音质 / 定时关闭 /
  /// 一起听），读屏也要求同屏不重名，所以拿它当稳定 id。
  /// **新增宿主时必须给唯一 semanticsLabel**，否则两格会被认成同一格。
  static String _keyOf(TopBarTrailingSegment s) => s.semanticsLabel;

  @override
  void initState() {
    super.initState();
    // 收回结束后才清掉展开状态：中途清掉会让镜像动画的最后一段跳回「盖满」
    _morph.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && !_resetting && mounted) {
        _uninstallDismissRoute();
        setState(() {
          _settled.clear();
          _fresh.clear();
          _retracting = false;
        });
      }
    });
    // 淡出到位才真的卸载离场格：中途卸载等于没有淡出
    _presence.addStatusListener((status) {
      if (status != AnimationStatus.completed || !mounted) return;
      setState(() {
        _entering.clear();
        _exiting.clear();
        _rendered = List<TopBarTrailingSegment>.of(widget.segments);
      });
    });
  }

  @override
  void dispose() {
    _uninstallDismissRoute();
    _reveal.dispose();
    _morph.dispose();
    _presence.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(TopBarTrailingCapsule oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPresence();
    // 格子全没了（切进车机形态等）：展开状态无处安放，顺手摘掉旁听路由，
    // 免得一颗已经不在树上的胶囊还在收全局指针事件。
    if (widget.segments.isEmpty) _uninstallDismissRoute();
  }

  /// 展开期间旁听全局指针事件：**按到胶囊以外就收回**。
  ///
  /// 为什么走 `pointerRouter` 而不是在树上罩一层透明 `Listener`：顶栏的祖先横跨
  /// 整页，为一颗胶囊去改页面根布局不划算；全局路由只是旁听，不会截走事件，
  /// 落在别的按钮上的那一下照样照常生效。收回时先摘路由再动画，避免收回途中
  /// 再点外面又触发一次。
  void _installDismissRoute() {
    if (_dismissRouteInstalled) return;
    _dismissRouteInstalled = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onGlobalPointer);
  }

  void _uninstallDismissRoute() {
    if (!_dismissRouteInstalled) return;
    _dismissRouteInstalled = false;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onGlobalPointer);
  }

  void _onGlobalPointer(PointerEvent event) {
    if (event is! PointerDownEvent) return;
    // 钉住项（一起听「已脱离」引导）不参与收回，与旧版「不自动收回」一致。
    if (_pinned) return;
    final box = _hitKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    if ((box.localToGlobal(Offset.zero) & box.size).contains(event.position)) {
      return;
    }
    _uninstallDismissRoute();
    _collapse();
  }

  /// 宿主的 segments 增删 → 登记进/出场并跑一次 [_presence]。
  ///
  /// 键集合没变时**不起任何动画**，只把 [_rendered] 跟上：睡眠定时的倒计时文案
  /// 每秒都换一个新对象，那是常态，不能每次都当成一次进出场（AGENTS §10）。
  void _syncPresence() {
    final next = widget.segments;
    final nextKeys = next.map(_keyOf).toSet();
    final previousKeys = _rendered.map(_keyOf).toSet();
    final entering = nextKeys.difference(previousKeys);
    final exiting = previousKeys.difference(nextKeys);
    if (entering.isEmpty && exiting.isEmpty) {
      _rendered = List<TopBarTrailingSegment>.of(next);
      return;
    }
    _exiting.addAll(exiting);
    _entering.addAll(entering);
    // 动画途中又改回来：键回来了就不该继续淡出；没淡完就被删就改走淡出
    _exiting.removeAll(nextKeys);
    _entering.removeAll(exiting);
    final merged = List<TopBarTrailingSegment>.of(next);
    for (var i = 0; i < _rendered.length; i++) {
      final s = _rendered[i];
      if (!_exiting.contains(_keyOf(s))) continue;
      // 插回它原先占的位置（越界就夹到新列表末尾），邻居不会瞬移
      merged.insert(i.clamp(0, merged.length), s);
    }
    _rendered = merged;
    if (_entering.isEmpty && _exiting.isEmpty) return;
    _presence.forward(from: 0);
  }

  /// 有进出场在飞：AnimatedSize 只在这期间才挂上去滑行（见 build 里的说明）。
  bool get _presenceAnimating => _entering.isNotEmpty || _exiting.isNotEmpty;

  /// 这一格现在擦出多少：0 = 收起，1 = 文案满宽。
  double _revealFor(String key) {
    if (_fresh.contains(key)) return _reveal.value;
    if (_settled.contains(key)) return _retracting ? _reveal.value : 1.0;
    return 0.0;
  }

  /// 钉住的那一项（一起听「已脱离」）是一条必须被看到的引导，不参与收回。
  bool get _pinned {
    if (_settled.isEmpty && _fresh.isEmpty) return false;
    bool open(TopBarTrailingSegment s) =>
        s.pinnedOpen &&
        (_settled.contains(_keyOf(s)) || _fresh.contains(_keyOf(s)));
    return widget.segments.any(open);
  }

  /// 让 [keys] 擦出文案。**只增不减**：已经在场的格子留在满宽，只有这次新增的
  /// 那几格走动画，所以先后点两格等于「多长出一段文字」，而不是两格宽度互换。
  void _expand(Iterable<String> keys) {
    final fresh = [
      for (final key in keys)
        if (!_settled.contains(key) && !_fresh.contains(key)) key,
    ];
    if (fresh.isEmpty) {
      // 全是已展开的格子：不重播（重播会把满宽的文案打回 0 再擦一遍）。
      // 但此刻若正在收回，必须把它拽回来 —— 否则这一被收回动画吞掉，
      // 点上去像是没反应。
      if (_retracting) {
        _retracting = false;
        _morph.forward();
      }
      _installDismissRoute();
      return;
    }
    setState(() {
      _retracting = false;
      // 上一轮正在擦出的格子升为「已满宽」：下一次重置不再把它们打回 0
      _settled.addAll(_fresh);
      _fresh
        ..clear()
        ..addAll(fresh);
    });
    _installDismissRoute();
    // 已经展开到位时把时间轴重置，让新格子自己擦一遍；还在途中则继续跑
    if (_morph.value >= 1.0) {
      _resetting = true;
      _morph.forward(from: 0);
      _resetting = false;
    } else {
      _morph.forward();
    }
  }

  void _collapse() {
    if (_morph.status == AnimationStatus.dismissed) return;
    _retracting = true;
    _morph.reverse();
  }

  /// 这一格现在是否「算已经展开」：**擦出一开始**就算（[_kOpenEnough]），
  /// 擦出途中与收回途中都算；只有落底的收起态才按「先展开」处理。
  bool _isOpen(String key) => _revealFor(key) > _kOpenEnough;

  /// 点一格：**先展开；擦出一开始之后的再次点击就执行动作，不必等动画跑完**。
  ///
  /// 收起态那一格只剩一个图标，第一下就「进房间 / 打开定时面板」等于让用户在
  /// 还没看清它是什么的时候就被导航走。所以第一下只负责把它打开；文案已经在擦了
  /// 就已经看得清，这一就必须落地，否则动画在飞的那段里的点击全被吞成「又展开了一次」。
  /// `pinnedOpen` 的格子本就是展开态，一次即触发。
  ///
  /// 只有**带动作**的格走这套两步；⋯ 与长按都是一步直达（见 `_buildBody`），
  /// 没有动作的格点一下只把文案擦出来，不存在「第二下」。
  void _tapCell({required String key, required VoidCallback action}) {
    if (!_isOpen(key)) {
      _expand([key]);
      return;
    }
    _installDismissRoute();
    action();
  }

  /// 展开状态按键存：segments 变短（关掉定时、退房）后残留的键若不清掉，就会指到
  /// 换了位置的邻居格上。
  ///
  /// 离场键**例外**：淡出期间保持它原来的擦出程度，否则那一格的文案会在第一帧突然
  /// 消失、整行宽度跟着白跳一下（AnimatedSize 对连续变化的子尺寸只会放弃平滑）。
  void _prune(Set<String> liveKeys) {
    final keep = liveKeys.union(_exiting);
    _settled.retainAll(keep);
    _fresh.retainAll(keep);
  }

  @override
  Widget build(BuildContext context) {
    // 「胶囊按钮收缩」开关在设置页改完就要生效，这里直接订阅它，不靠宿主重建。
    return ListenableBuilder(
      listenable: kTopBarPillCollapseEnabled,
      builder: (context, _) => _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    // 渲染读的是 [_rendered]：离场那一格在淡出期间必须还挂在树上，否则「消失」
    // 就没有动画可谈。segments 变空（如 dockMode 顶栏）时仍退化成那颗裸 ⋯。
    final cells = _rendered;
    if (cells.isEmpty) {
      return IconButton(
        icon: Icon(Icons.more_horiz, color: widget.moreIconColor),
        onPressed: widget.onMore,
      );
    }
    _prune(widget.segments.map(_keyOf).toSet());

    // 「收缩」只作用于竖屏：宽屏顶栏有整行宽度可给，文案常显更好读；设置里关掉
    // 开关同理。两种形态共用同一颗连体背景，区别只在文案是擦出还是常显、
    // 点击是「先展开再执行」还是「一次即执行」。
    //
    // **TV 恒为常显一步**：遥控器只有一个 OK 键，「第一下只展开、第二下才执行」
    // 在 10-foot 下就是「按了没反应」（AGENTS §12.4）。焦点格靠 TvFocusHighlight
    // 已经知道自己在哪，展开这一步纯属多余。
    //
    // 一格能不能收起要看两件事：有文案可藏；再看它是哪一类 ——
    //   · 音质这类 `collapseOnlyWithPeers` 格：**只**看旁边还有没有别的格
    //     （孤零零缩成一颗音符反而更难认），设置页的「胶囊按钮收缩」管不到它；
    //   · 其余格（睡眠定时 / 一起听…）：仍由那个开关决定。
    // 于是两种形态能并存：关掉开关后睡眠/一起听文案常显，音质在邻居在场时照旧缩成
    // 音符。全树都没有可收的格子时整颗胶囊回到常显形态，避免出现「只有图标、点开也
    // 没别的」的空壳。
    // 邻居按 [_rendered] 数：离场格还占着位置，此时把音质就地放开会当场跳宽。
    final mayCollapse = widget.collapsible && !kTvBuild;
    bool hasPeer(TopBarTrailingSegment s) => cells.any((o) => !identical(o, s));
    bool canCollapse(TopBarTrailingSegment s) =>
        mayCollapse &&
        s.label.isNotEmpty &&
        (s.collapseOnlyWithPeers
            ? hasPeer(s)
            : kTopBarPillCollapseEnabled.value);
    final collapsible = cells.any(canCollapse);

    if (collapsible) {
      // 钉住项（已脱离引导）不等点击就展开。起播推迟到下一帧：build 期间启动
      // Ticker 会撞上「布局中排帧」的断言。
      if (_settled.isEmpty &&
          _fresh.isEmpty &&
          !_autoOpenScheduled &&
          cells.any((s) => s.pinnedOpen)) {
        _autoOpenScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _autoOpenScheduled = false;
          if (!mounted) return;
          final pinned = widget.segments.indexWhere((s) => s.pinnedOpen);
          if (pinned < 0) return;
          final key = _keyOf(widget.segments[pinned]);
          if (_revealFor(key) == 0.0) _expand([key]);
        });
      }
    }

    return Padding(
      // 全局定位键：[_onGlobalPointer] 用它算「这一下是不是按在胶囊以外」。
      key: _hitKey,
      padding: const EdgeInsets.only(right: 2),
      child: AnimatedBuilder(
        animation: _animations,
        builder: (context, _) {
          // 必须在 builder 里读：build 每帧只跑一次，动画帧靠的是这里。
          // 逐格判定：音质格能不能收由它自己的邻居决定，其余格看开关。
          Widget cell(TopBarTrailingSegment s) {
            final key = _keyOf(s);
            final entering = _entering.contains(key);
            final exiting = _exiting.contains(key);
            // 进场从 0 推到 1、离场从 1 收到 0；稳定的格子恒为 1（不套 ClipRect，
            // 否则左上角那两枚红点会被裁掉）。
            final presence = entering
                ? _presence.value
                : exiting
                ? 1.0 - _presence.value
                : 1.0;
            final reveal = canCollapse(s) ? _revealFor(key) : 1.0;
            // 淡出中的那一格不可点：它代表的动作已经不在当前顶栏里了，还能点就
            // 等于让用户按到一个正在消失、马上不存在的入口。
            final action = exiting ? null : s.onTap;
            final longAction = exiting ? null : s.onLongPress;
            final stop = _IconCell(
              icon: s.icon,
              semanticsLabel: s.semanticsLabel,
              foreground: widget.foreground,
              // 没擦出内容的格子不带文案层，否则收起态也会占住一段宽度
              label: reveal > 0.0 ? s.label : '',
              detail: s.label,
              labelReveal: reveal,
              unreadDot: s.unreadDot,
              pendingDot: s.pendingDot,
              dotColor: widget.dotColor,
              capsuleColor: widget.showBackground ? widget.background : null,
              // 点击分三种：
              //   · 带动作、且这一格能收缩 → 两步（第一下只展开，见 [_tapCell]）；
              //   · 带动作、常显 → 一次即执行；
              //   · **没有动作**（本地歌曲的音质）但文案可藏 → 点一下只把文案擦出来。
              // ⋯ 现在一步就开菜单、不再负责「展开全部格」，所以对本地歌曲来说，
              // 这一格自己就是读到码率推断音质的唯一途径 —— 让它整格 inert 会把
              // 信息一起锁死。展开是它唯一的用途，因此不存在「第二下」。
              // 淡出中的格子仍然点不动：它代表的入口已经不在当前顶栏里了。
              // 长按**恒为一步**：音量面板没有「先看清再按」的需求，套上两步只会
              // 让人以为长按失灵。
              onTap: exiting
                  ? null
                  : action != null
                  ? (canCollapse(s)
                        ? () => _tapCell(key: key, action: action)
                        : action)
                  : (canCollapse(s) ? () => _expand(<String>[key]) : null),
              onLongPress: longAction,
            );
            return KeyedSubtree(
              key: ValueKey<String>(key),
              child: FadeTransition(
                opacity: AlwaysStoppedAnimation<double>(presence),
                // 进出场连自己占的宽度一起推让：邻居（尤其恒在最右的 ⋯）因此是
                // 连续滑动，而不是等淡出跑完、卸载那一格时才猛地补上 40dp。
                child: entering || exiting
                    ? ClipRect(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          widthFactor: presence,
                          child: stop,
                        ),
                      )
                    : stop,
              ),
            );
          }

          final row = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final s in cells) cell(s),
              _IconCell(
                icon: Icons.more_horiz,
                semanticsLabel: '更多',
                // ⋯ 现在恒在底色之外，取色走「裸图标」那套：宿主没传
                // moreIconColor 时退回 foreground 兜底。
                foreground: widget.moreIconColor ?? widget.foreground,
                label: '',
                detail: '',
                labelReveal: 0.0,
                unreadDot: false,
                pendingDot: false,
                dotColor: widget.dotColor,
                capsuleColor: widget.showBackground ? widget.background : null,
                iconSize: 24,
                // ⋯ **恒为一步**：菜单入口没有「先看清再按」的需求，两步会让用户
                // 以为菜单失灵。它也不再承担「展开全部格」（那是它自己的副业，
                // 现在由各格点开展现），因此这里直接给 onMore。
                // ⋯ 不属于进出场集合，恒常渲染。
                onTap: widget.onMore,
              ),
            ],
          );

          return Stack(
            clipBehavior: Clip.none,
            children: [
              // 背景只盖**有内容的那几格**：右端让出 ⋯ 那一格（固定 _kIconBox 宽），
              // ⋯ 因此是裸图标，不压在胶囊底色里。
              //
              // 这不是早期那版「背景右缘随最右展开格滑动」的形态：这里让开的是
              // **固定**的一格宽度，而顶栏尾部整体右对齐、⋯ 又恒在最右，所以 ⋯ 的
              // 左缘位置不随文案擦出而变，当年那点边缘跳动不会回来。
              //
              // 它是 Stack 里的 Positioned，宽度跟着 Stack 走，所以进出场时整颗
              // 胶囊滑行时背景自动同步，不需要另外驱动。
              //
              // 宽屏/横屏（[TopBarTrailingCapsule.showBackground] = false）整层不画：
              // 那一版顶栏有整行宽度、文案又恒显，底色会把「一串各自独立的操作」
              // 框成一块面板，压在封面/壁纸上尤其显脏；去掉后每格与 ⋯ 一样裸着，
              // 靠对齐与间距成组，而不是靠容器成组。
              if (widget.showBackground)
                Positioned(
                  left: 0,
                  // 上下各缩进触控余量：Stack 的高度是热区（40），底色只画视觉高度
                  // （32）那一条，多出来的 4+4 留给触点。
                  top: _kPillTouchPad,
                  bottom: _kPillTouchPad,
                  right: _kIconBox,
                  child: Material(
                    color: widget.background,
                    shape: const StadiumBorder(),
                    child: const SizedBox.expand(),
                  ),
                ),
              // 涟漪画在这层透明 Material 上，于是它始终位于背景之上
              Material(
                color: Colors.transparent,
                // 整行宽度只在**进出场**那一程才套 AnimatedSize 滑行，两个原因：
                //   · 文案擦出那一程绝不能过它 —— 逐字推进已由格子里的
                //     Align.widthFactor 自己平滑，再套一层滑行就是二次滤波，慢半拍；
                //   · 「不平滑」也不能写成 duration: Duration.zero。零时长的
                //     AnimatedSize 会在自己的 performLayout 里同步 notifyListeners
                //     （`_animateToInternal` 的 Duration.zero 分支是直接赋值 + 通知），
                //     而它自己的 listener 接着 markNeedsLayout —— 框架当场断言
                //     「RenderObject 不得在自己的 performLayout 中重新弄脏自己」。
                // 动画一落定就把它摘掉，行本身回到直挂。
                child: _presenceAnimating
                    ? AnimatedSize(
                        alignment: Alignment.centerLeft,
                        duration: _kPresence,
                        curve: Curves.easeOutCubic,
                        child: row,
                      )
                    : row,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 顶栏尾部的一项。由宿主从各自的状态里造（见 `sleepTimerTopBarSegment` 与
/// `listenTogetherTopBarSegment`），本组件因此不碰 provider —— 合并胶囊的几何与
/// 动能脱离「真实房间会话 + 轮询定时器」单独验证。
class TopBarTrailingSegment {
  const TopBarTrailingSegment({
    required this.icon,
    required this.label,
    required this.semanticsLabel,
    this.onTap,
    this.onLongPress,
    this.unreadDot = false,
    this.pendingDot = false,
    this.pinnedOpen = false,
    this.collapseOnlyWithPeers = false,
  });

  final IconData icon;

  /// 展开时才擦出的文案（倒计时 mm:ss / 房间人数 / 当前音质）。
  final String label;

  /// 无障碍标签：收起态只剩图标，读屏全靠它。
  ///
  /// 同时**是本组件认格子身份的稳定键**（展开状态、进出场都按它存），所以同一个
  /// 顶栏里的每一格标签必须互不相同，且这一格在时就要沿用同一个值。
  final String semanticsLabel;

  /// 点击动作。**null = 这一格没有可执行动作**（本地歌曲屏蔽音质选择），
  /// 于是它不响应点击、也不出涟漪，与旧的独立徽章行为一致；
  /// 想看清它的文案仍可点 ⋯ 把全部格子一起展开。
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 右上角红点（一起听：聊天未读）。
  final bool unreadDot;

  /// 左上角红点（一起听：房主有待处理点歌）。分列两角是因为合并成一个点
  /// 会丢掉「两件事各自是否待处理」的信息。
  final bool pendingDot;

  /// true = 展开后不自动收回（一起听「已脱离」的引导必须一直在）。
  final bool pinnedOpen;

  /// true = **只有旁边还有别的胶囊时**才收起。
  ///
  /// 给音质徽章用：孤零零一颗「♪」比直接写「无损音质」难认，而那时顶栏也确实有
  /// 地方；一旦睡眠定时 / 一起听也在场，就让位收成一个音符，点开再擦出文案。
  /// 这类格的判定**不看**「胶囊按钮收缩」开关（见 `TopBarTrailingCapsule` 的
  /// `canCollapse`）：邻居在就收，邻居没在就常显。
  final bool collapseOnlyWithPeers;
}

/// 合并胶囊里的一格：图标常驻，[label] 非空时按 [labelReveal] 擦出。
class _IconCell extends StatelessWidget {
  const _IconCell({
    required this.icon,
    required this.semanticsLabel,
    required this.foreground,
    required this.label,
    required this.detail,
    required this.labelReveal,
    required this.unreadDot,
    required this.pendingDot,
    required this.dotColor,
    required this.capsuleColor,
    this.onTap,
    this.onLongPress,
    this.iconSize = AppCapsule.cellIcon,
  });

  final IconData icon;
  final String semanticsLabel;
  final Color foreground;

  /// 空串 = 这一格不带文案（收起态、以及 ⋯ 那一格）。
  final String label;

  /// 这一格的**真实**文案，与 [label] 的区别是它不受擦出进度门控：
  /// 收起态屏幕上不画字，但读屏仍要能念出「音质：无损音质」，否则视障用户
  /// 必须先把格子点开才拿得到信息（[label] 在那一刻是空串）。
  final String detail;
  final double labelReveal;
  final bool unreadDot;
  final bool pendingDot;
  final Color dotColor;

  /// 红点描边色（= 胶囊底色，让红点像是从胶囊里长出来的）。
  /// null = 裸形态（横屏无底色）：没有可「融进去」的容器色，硬描一圈反而像个环。
  final Color? capsuleColor;
  /// 点击动作；null = 这一格不响应点击（本地歌曲的音质徽章）。
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double iconSize;

  /// 读屏用的完整描述：身份 + 真实文案 + 两枚红点各自含义。
  String _semanticsText() {
    final parts = <String>[
      if (detail.isEmpty) semanticsLabel else '$semanticsLabel：$detail',
      if (pendingDot) '有待处理点歌',
      if (unreadDot) '有未读消息',
    ];
    return parts.join('，');
  }

  @override
  Widget build(BuildContext context) {
    final chars = label.characters.toList();
    final stop = Semantics(
      button: true,
      // 收起态只剩图标，读屏全靠这一串；把**当前文案**和两枚红点各自代表什么
      // 一起念出来，读屏用户不必先「点开」才知道音质是什么、有没有待办
      // （红点是纯色小圆点，光靠位置和颜色对读屏与色盲都不成立）。
      label: _semanticsText(),
      child: InkWell(
        // 涟漪轮廓按**视觉**胶囊那一条带裁剪，不是整格盒子。
        //
        // 这一格的盒子是触控高度（40），比底色胶囊（32）上下各出 [_kPillTouchPad]；
        // 直接给 StadiumBorder 就会让波纹高出胶囊一圈。热区绝不能跟着缩（AGENTS
        // §11 的触控地板），所以缩的是 ink 的裁剪轮廓：material_ui 的 InkWell 是
        // containedInkWell + 矩形高亮，涟漪与按压高亮都只按 customBorder 在这**整盒**
        // 上取的路径来裁，于是这一层 border 同时压住两者，几何与热区一律不动。
        // 文案擦出后格子变宽，路径同步长成药丸形，不会溢出右端。
        customBorder: _kPillBandBorder,
        onTap: onTap,
        onLongPress: onLongPress,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // 触控 40 / 视觉 32：外层撑到热区高度，里层那条 Row 才是胶囊本体的高。
            // 这里用 Column(mainAxisSize: min) 而不是 Center：Center 会按
            // constraints.biggest 取值，而外层 Row(mainAxisSize: min) 给的是无界宽，
            // 那要炸。
            SizedBox(
              height: _kPillTouchHeight,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    height: _kPillHeight,
                    child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: _kIconBox,
                    child: Center(
                      child: Icon(icon, size: iconSize, color: foreground),
                    ),
                  ),
                  // 收窄只作用在文字段自身：胶囊本体的右缘由外面那层背景负责，
                  // 于是两端始终是半圆，不会被裁出一条平边。
                  if (chars.isNotEmpty)
                    // 微调：文字相对图标整体往左、往上各挪一点，视觉上更贴合
                    // 图标中心（避免文字紧贴胶囊/图标显得偏右偏下）。
                    // 注意 Transform 必须包在 ClipRect 外层：放在内层会把文字
                    // 左移出裁剪区，导致「文字左边显示不全」。
                    Transform.translate(
                      offset: const Offset(-2, -1),
                      child: ClipRect(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          widthFactor: labelReveal,
                          child: Padding(
                            padding: const EdgeInsets.only(
                              left: AppCapsule.labelLeftPad,
                              right: _kLabelRightPad,
                            ),
                            child: Text.rich(
                            TextSpan(
                              children: [
                                for (var i = 0; i < chars.length; i++)
                                  TextSpan(
                                    text: chars[i],
                                    style: TextStyle(
                                      color: foreground.withValues(
                                        alpha: labelCharAlpha(
                                          labelReveal,
                                          i,
                                          chars.length,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            maxLines: 1,
                            style:
                                Theme.of(
                                  context,
                                ).textTheme.labelMedium?.copyWith(
                                  // 行高收成 1.0：labelMedium 默认自带 ~1.33 行高，
                                  // 在 32dp 高的胶囊里会把文字基线往下推，视觉偏下、
                                  // 与图标中心不对齐。这里收掉多余行高让文字真正垂直居中。
                                  height: 1.0,
                                  fontWeight: FontWeight.w600,
                                  // 等宽数字：定时关闭的 mm:ss 每秒换字，比例字体下
                                  // 「11:59 → 12:00」这类跳变会让整颗胶囊逐秒改宽度，
                                  // 邻居（含恒在最右的 ⋯）跟着左右抖。
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
                    ),
                  ),
                ],
              ),
            ),
            // 红点贴在**视觉**胶囊的上沿（热区比它高出 _kPillTouchPad 上下各一圈，
            // 所以出血量要从余量起算，否则点会落在胶囊外面）。
            if (pendingDot)
              Positioned(
                top: _kPillTouchPad - 3,
                left: 6,
                child: _badgeDot(dotColor, capsuleColor),
              ),
            if (unreadDot)
              Positioned(
                top: _kPillTouchPad - 3,
                right: -2,
                child: _badgeDot(dotColor, capsuleColor),
              ),
          ],
        ),
      ),
    );

    // tv: 顶栏尾部每一格都是 D-pad 单停点（铁律 1）：OK = 原 onTap、
    // OK 长按 = 原 onLongPress（选音质 / 进房间 / 开聊天 / 开定时面板 / 打开更多菜单）。
    // TV 恒为常显一步（见 _buildBody 的 mayCollapse），文案本来就在屏幕上，
    // 所以本地歌曲那格在 TV 上确实是 inert，靠长按开音量面板。
    // 触屏构建原样返回，零变化。
    if (!kTvBuild) return stop;
    return DpadFocusable(
      debugLabel: 'player_top_bar_$semanticsLabel',
      enabled: onTap != null || onLongPress != null,
      onSelect: onTap,
      onLongSelect: onLongPress,
      child: stop,
    );
  }
}

/// 顶栏每一格 ink（涟漪 + 按压高亮）的裁剪轮廓：只在**视觉**胶囊那一条带上画。
///
/// 格子盒子按触控高度取值（40），比底色胶囊（32）上下各多出 [_kPillTouchPad]。
/// material_ui 的 InkWell 是 `containedInkWell` 且高亮为矩形，涟漪与高亮**都只**按
/// `customBorder.getOuterPath(整盒)` 裁剪，所以把路径从整盒收到那一条带，就能同时
/// 压住两者；`radius` 办不到——矩形高亮不读 radius，涟漪终态还是 `targetRadius + 5`。
/// 触控热区不受影响（热区由盒子决定，与 ink 无关）。
class _PillBandStadiumBorder extends ShapeBorder {
  const _PillBandStadiumBorder();

  /// 上下各内缩一个触控余量，左右不动（文案擦出后格子本来就在变宽）。
  static Rect _band(Rect rect) => Rect.fromLTRB(
    rect.left,
    rect.top + _kPillTouchPad,
    rect.right,
    rect.bottom - _kPillTouchPad,
  );

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      const StadiumBorder().getOuterPath(_band(rect));

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      const StadiumBorder().getOuterPath(_band(rect));

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) => this;
}

const ShapeBorder _kPillBandBorder = _PillBandStadiumBorder();

/// 胶囊上的小红点：8px 实心圆。带底色形态下加一圈与胶囊同色的描边（微出血，
/// 避免被圆角吃掉）；裸形态（[borderColor] 为 null）不描边。
Widget _badgeDot(Color color, Color? borderColor) => Container(
  width: 8,
  height: 8,
  decoration: BoxDecoration(
    color: color,
    shape: BoxShape.circle,
    border: borderColor == null
        ? null
        : Border.all(color: borderColor, width: 1.5),
  ),
);
