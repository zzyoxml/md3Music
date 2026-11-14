import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:dpad/dpad.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/build_flags.dart';
import '../../core/layout/bottom_chrome_dimens.dart';
import '../../core/layout/bottom_chrome_scope.dart';
import '../../core/layout/display_space.dart';
import '../../core/layout/responsive_layout.dart';
import '../../core/layout/tv_player_bar_focus_bridge.dart';
import '../../core/layout/ui_density.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/motion_constants.dart';
import '../../core/utils/app_haptics.dart';
import '../../data/repositories/settings_repository.dart';
import '../../providers/player_provider.dart';
import '../../providers/theme_provider.dart';
import '../../providers/car_mode_provider.dart';
import '../../widgets/smart_artwork_image.dart';
import '../../widgets/player_artwork_image.dart';
import '../../widgets/playback_status_feedback.dart';
import 'full_player_route.dart';
import 'bottom_bar_morph_overlay.dart';
import 'player_bar_progress_painter.dart';
import 'player_cover_morph.dart';
import 'player_panel_frame.dart';

/// 全局开关：MiniPlayer 是否支持水平滑动切歌（设置页可切换，默认开启）。
/// 用全局 ValueNotifier 而非 State 局部状态，保证各页面 MiniPlayer 实例
/// 在设置变更后实时响应。
/// MiniPlayer 内容行的基础左右内边距（dp）。
///
/// 有底部导航栏、无需圆角防护时使用；也作为圆角反解值的下限。
const double kMiniPlayerBaseSideInset = 4.0;

/// 底部净空下限（dp）。
///
/// 冷启动 / 配置变更期间系统 inset 存在瞬时归零窗口（真机实测观测到
/// `padding.bottom=0` 而 `systemGestureInsets.bottom=20`），只靠 inset 会让
/// 迷你条在过渡帧抖动，故钉一个不依赖 inset 的下限。
const double kMiniPlayerMinBottomClearance = 12.0;

/// 圆角反解出的左右内边距上限（dp），防止异常大的上报值把内容挤成一条。
const double kMiniPlayerMaxHorizontalClearance = 24.0;

/// `MediaQueryData.displayCornerRadii` 不可用时（Android < 12 或厂商未上报）
/// 采用的保守下屏角半径（dp）。
const double kMiniPlayerFallbackCornerRadius = 28.0;

/// MiniPlayer 在「自身即屏幕最底部」时的圆角防护留白。
///
/// - [bottom]：底部净空（dp），`max(系统底部 inset, 下限)`；
/// - [horizontal]：内容行左右内边距（dp），使该高度处圆角吃掉的水平宽度
///   不侵入内容，下限为基础值 [kMiniPlayerBaseSideInset]。
typedef MiniPlayerCornerClearance = ({double bottom, double horizontal});

/// 计算 MiniPlayer **自身就是屏幕最底部元素** 时所需的圆角防护留白。
///
/// 几何：半径 [radius] 的屏幕圆角，在距屏底 `height` 处吃掉的水平宽度为
/// `radius - √(radius² - (radius - height)²)`（圆心在距屏边 radius 处，屏幕
/// 区域在该圆内）。把该宽度作为左右内边距，内容就完全落在圆角之外。
///
/// 底部净空只取 `max(viewPadding.bottom, 下限)`、**不**再由圆角反解：本机实测
/// 圆角 58dp，若把防护全部压在底部需 36.8dp，迷你条会从 50dp 涨到 87dp 过厚。
/// 改为「底部托底 + 左右反解」后本机为 底 20 / 左右 15，条高 70dp。
///
/// 注：`DisplayScaleScope` 不缩放 `displayCornerRadii`（见 `ui_density.dart:59-61`
/// 的说明，属刻意接受），非 1.0 显示档下半径相对偏大 → 略微多留，属保守侧。
MiniPlayerCornerClearance resolveMiniPlayerCornerClearance(MediaQueryData mq) =>
    resolveMiniPlayerCornerClearanceFrom(
      viewPaddingBottom: mq.viewPadding.bottom,
      cornerRadii: mq.displayCornerRadii,
    );

/// [resolveMiniPlayerCornerClearance] 的按 aspect 读数变体（同一份几何）。
///
/// **为什么要有这层**：底栏收起/展开期间 `ResponsiveScaffold._withAnimatedBottomInset`
/// 每帧都在改 `MediaQuery.padding.bottom`。消费方若走全量 `MediaQuery.of` 取这两个
/// 值，会被那段 padding 的逐帧变化拖去整棵重建；按 aspect 读数
/// （`viewPaddingOf` / `displayCornerRadiiOf`）只登记这两个 aspect，转场就不会
/// 再顺带重建消费方（MiniPlayer 留白层重写的一半动机就在这）。
MiniPlayerCornerClearance resolveMiniPlayerCornerClearanceFrom({
  required double viewPaddingBottom,
  required BorderRadius? cornerRadii,
}) {
  final bottom = math.max(viewPaddingBottom, kMiniPlayerMinBottomClearance);
  final radius = _bottomCornerRadius(cornerRadii);
  final eaten =
      radius <= 0 ? 0.0 : _cornerEatenWidth(radius: radius, height: bottom);
  final horizontal = math.min(
    math.max(kMiniPlayerBaseSideInset, eaten.ceilToDouble()),
    kMiniPlayerMaxHorizontalClearance,
  );
  return (bottom: bottom, horizontal: horizontal);
}

/// 在「底栏完整在场」（底 0 / 左右基础值）与「自身即屏幕最底部」（[alone]）两套
/// 口径之间，按底栏收起进度 [t] **线性插值**。
///
/// 为什么是线性而不是几何反解：两段位移（底栏槽位收缩、净空补回）都由同一个 `t`
/// 驱动，内容绝对位移 = 槽位高 − 净空，线性插值与底栏运动逐帧同源，读起来是一个
/// 动作。旧实现按 bool 二选一，转场末帧会突然多出十几到几十 dp 的净空，看起来
/// 就是内容跳一下。
///
/// [t] 的取值口径（含坞位不存在 / 横屏侧栏时的兜底）见
/// `_MiniPlayerState._collapseT`。
MiniPlayerCornerClearance lerpMiniPlayerClearance({
  required MiniPlayerCornerClearance alone,
  required double t,
}) {
  if (t >= 1.0) return alone;
  if (t <= 0.0) {
    return (bottom: 0.0, horizontal: kMiniPlayerBaseSideInset);
  }
  return (
    bottom: alone.bottom * t,
    horizontal:
        kMiniPlayerBaseSideInset +
        (alone.horizontal - kMiniPlayerBaseSideInset) * t,
  );
}

/// 取左右下角中更大的圆角半径；未上报时用 [kMiniPlayerFallbackCornerRadius]。
double _bottomCornerRadius(BorderRadius? radii) {
  if (radii == null) return kMiniPlayerFallbackCornerRadius;
  return math.max(
    math.max(radii.bottomLeft.x, radii.bottomLeft.y),
    math.max(radii.bottomRight.x, radii.bottomRight.y),
  );
}

/// 圆角在距屏底 [height] 处吃掉的水平宽度（推导见
/// [resolveMiniPlayerCornerClearance]）。
double _cornerEatenWidth({required double radius, required double height}) {
  final inner = radius - height;
  // 内容底边已在圆角弧之上，圆角吃不到
  if (inner <= 0) return 0.0;
  return radius - math.sqrt(radius * radius - inner * inner);
}

final ValueNotifier<bool> miniPlayerSwipeSwitchEnabled =
    ValueNotifier<bool>(true);

/// 底部常驻迷你播放条。
///
/// 点击调用 [fullPlayerRoute] push 路由，由路由自带 400ms 入场动画。
///
/// 自身 opacity = `1 - playerExpansion`，由全局 [playerExpansion] Notifier 驱动，
/// FullPlayer 淡入时 mini bar 同步淡出，避免视觉打架。
///
/// 支持水平滑动切歌：封面+歌曲信息跟随手指实时平移，松手达阈值触发切歌并
/// AnimatedSwitcher 滑入滑出过渡，未达阈值回弹归位。右侧按钮不参与滑动。
class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key});

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer>
    with TickerProviderStateMixin {
  // 拖动期间内容水平偏移（px），实时跟随手指
  double _dragOffset = 0.0;
  // 切歌方向：1=下一首(向左滑)，-1=上一首(向右滑)；驱动 AnimatedSwitcher 进出场方向
  int _switchDirection = 1;
  // 回弹归位动画控制器
  late final AnimationController _snapController;
  Animation<double>? _snapAnim;

  // MiniPlayer「从无到有」入场动画控制器（底部弹出 + 背景色遮罩 morph 到本体）
  late final AnimationController _entranceController;
  late final CurvedAnimation _entranceAnim;
  // 上拉未达阈值时的回弹驱动（与悬浮胶囊共用，见 DragReleaseAnimator）。
  late final DragReleaseAnimator _dragRelease;
  // 记录本实例是否已处于「有歌」状态：只在 null→有歌 的转变时播放一次入场动画，
  // 页面切换重建（进来即有歌）不触发
  late bool _hadSong;
  // 内容（封面/标题/歌手）是否已首次显示：首次不播放 AnimatedSwitcher 淡入，
  // 避免启动期 ticker 不稳使淡入卡在半透明导致内容发灰
  bool _contentShownOnce = false;
  // 系统「移除动画」（reduced-motion）：在 `didChangeDependencies` 缓存
  // `MediaQuery.disableAnimationsOf`（该值经 dependencies 传播），驱动动画前判一次。
  // 命中时切歌 AnimatedSwitcher 走 0ms 瞬时切换（计划 §1.3 矩阵）。
  bool _reduceMotion = false;
  // 当前构建中封面对应的歌曲 id：用于封面探针的回调里识别「正在滑出的旧封面」。
  //
  // 切歌过渡期 AnimatedSwitcher 里新旧两份封面同时存在、各带一个探针，而
  // 「后画的赢」—— 正在滑出的旧封面盖在当前封面之上，会最后绘制并上报一个
  // 横向偏出去的矩形。探针闭包捕获的是**构建当时**的 `currentSong.id`，与本
  // 字段一比即可区分，无需任何「切歌进行中」标志（也就无需动切歌状态机）。
  String? _coverSongId;

  // 拖动触发阈值
  static const double _velocityThreshold = 400.0; // px/s
  static const double _distanceRatio = 0.25; // 屏宽比例

  /// tv: 滑动区焦点节点。登记到 [TvPlayerBarFocusBridge]，供内容区下边缘
  /// 显式移交（播放条在各 tab 的 Navigator scope 之外，dpad 自己找不到它）。
  ///
  /// 只在 TV 构建创建：非 TV 构建 [_tvSwipeAreaFocus] 原样返回 child，
  /// 建了节点也不挂树。
  late final FocusNode? _tvSwipeFocusNode =
      kTvBuild ? FocusNode(debugLabel: 'mini_player_swipe_area') : null;

  @override
  void initState() {
    super.initState();
    final swipeNode = _tvSwipeFocusNode;
    if (swipeNode != null) {
      TvPlayerBarFocusBridge.instance.register(swipeNode);
    }
    _snapController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _entranceAnim = CurvedAnimation(
      parent: _entranceController,
      curve: M3ExpressiveMotion.expressiveEasing,
    );
    // 上拉未达阈值时的回弹（与悬浮胶囊共用同一个驱动）。
    _dragRelease = DragReleaseAnimator(this);
    // 进来即有歌（如页面切换重建）→ 直接满显示、不弹；进来无歌 → 归零待触发
    _hadSong = context.read<PlayerProvider>().currentSong != null;
    _entranceController.value = _hadSong ? 1.0 : 0.0;
    // 已有歌直接满显示，消费掉冷启动恢复标记，避免残留误伤后续点歌
    if (_hadSong) kMiniPlayerSkipNextEntrance = false;
    // 从本地持久化读取「滑动切歌」开关，覆盖默认值（默认开启）
    _loadSwipeSwitchSetting();
  }

  /// 读取本地「MiniPlayer 滑动切歌」设置并同步到全局开关
  Future<void> _loadSwipeSwitchSetting() async {
    final enabled = await SettingsRepository().getMiniPlayerSwipeSwitchEnabled();
    miniPlayerSwipeSwitchEnabled.value = enabled;
  }

  @override
  void dispose() {
    final swipeNode = _tvSwipeFocusNode;
    if (swipeNode != null) {
      TvPlayerBarFocusBridge.instance.unregister(swipeNode);
      swipeNode.dispose();
    }
    _snapController.dispose();
    _entranceController.dispose();
    _dragRelease.dispose();
    super.dispose();
  }

  /// 设计像素锚点（`DisplayScaleReference` 暴露的 RenderObject）。
  ///
  /// `_onRawDown` 是指针回调，不能在那里调 `anchorOf` 建立 InheritedWidget
  /// 依赖，故在 `didChangeDependencies` 缓存（该处建立依赖合规；
  /// `DisplayScaleReference` 第 2 帧才挂上，挂载会再次触发本回调回填）。
  /// 不在 `DisplayScaleScope` 内时为 null → 回退根空间，与修复前逐位一致。
  RenderObject? _scaleAnchor;

  /// 本条所在页面路由（登记常驻条结算矩形的核对条件之一，见
  /// [_scheduleRegisterResidentRect]）。
  Route<dynamic>? _residentRoute;

  /// 本条所属 tab 是否在前台（`TickerMode` 由 `ResponsiveShell` 的
  /// IndexedStack 逐 tab 门控）。后台 tab 的常驻条仍挂在树上（保活），
  /// 不能把它的几何写进登记簿。
  bool _tickerModeEnabled = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scaleAnchor = DisplayScaleReference.anchorOf(context);
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    // 登记核对条件必须在 dependencies 时机取：ModalRoute.of / TickerMode.valuesOf
    // 都是 InheritedWidget 依赖。
    _residentRoute = ModalRoute.of(context);
    _tickerModeEnabled = TickerMode.valuesOf(context).enabled;
  }

  /// 已经预热过 GPU 纹理的那首歌封面（每首只付一次，切歌才重付）。
  String? _coverTexturePrewarmedUri;

  /// 把**当前这首歌**的飞行封面档纹理在转场之外先离屏画一次。
  ///
  /// **要治的是什么**：真机仪表 v3 定案，`worst` 的 GPU 位有 12~18ms 花在「大图第一次
  /// 进 display list 时上传纹理」（切歌后第一次展开必付）。纹理按 `ui.Image` 对象上传，
  /// 只解码不画不够，所以走 [prewarmPlayerArtworkTexture]。
  ///
  /// **为什么条件是「已经展开过一次」**：`settled` 档解码一张封面约 4MB 驻留，
  /// 从不进播放页的用户不该背这个负担；而登记簿里的 `settledRect` 只有在播放页
  /// 首次 build 之后才有值——它同时把「用户确实展开过」和「飞行层那一档的精确宽度」
  /// 一起给出来了（宽度只能估的话就会解出另一档的图，等于白预热）。
  ///
  /// **不抢帧**：真正的离屏绘制排在 post-frame，并且只在该帧 `playerExpansion` 落在
  /// 端点、且没有拖拽在跟手时才做；否则把标记清掉，留给下一次 build 重触发
  /// （本组件的重建都是低频的：切歌 / 播放态变化）。
  void _maybePrewarmCoverTexture(BuildContext context, String? artworkUri) {
    final bus = PlayerCoverMorphBus.instance;
    if (!shouldPrewarmCoverTexture(
      artworkUri: artworkUri,
      alreadyPrewarmedUri: _coverTexturePrewarmedUri,
      settledRect: bus.settledRect,
    )) {
      return;
    }
    _coverTexturePrewarmedUri = artworkUri;
    // 闸门已经保证转场终点矩形在场（没有它就谈不上「本会话展开过」）。
    final layout = bus.settledRect!;
    // 与飞行层 `_buildFlightFrame` 同一份终点矩形：布局矩形 × 暂停缩放 × 锚点。
    final settled = coverSettledVisualRect(
      layout: layout,
      scale: bus.settledArtworkScale,
      anchor: bus.settledArtworkAnchor,
    );
    // dpr 必须在 build 期读（post-frame 里再建立 InheritedWidget 依赖不可靠）。
    final dpr = MediaQuery.devicePixelRatioOf(context);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final expansion = playerExpansion.value;
      if (playerDragActive.value || (expansion > 0.0 && expansion < 1.0)) {
        // 正在转场：这一帧不做，让下一首歌或下一次重建重新触发。
        _coverTexturePrewarmedUri = null;
        return;
      }
      final status = await prewarmPlayerArtworkTexture(
        artworkUri: artworkUri,
        settledLogicalWidth: settled.width,
        devicePixelRatio: dpr,
      );
      if (coverMorphPerfLogEnabled) {
        // ignore: avoid_print
        print('[CoverMorphPerf] prewarm $status');
      }
    });
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    // 上滑展开已识别时屏蔽水平切歌，避免斜向滑动同时触发两种手势
    if (_dragActivated) return;
    // 取消正在进行的回弹动画，接管为手动拖动
    _snapController.stop();
    _dragOffset = 0.0;
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (_dragActivated) return;
    setState(() {
      _dragOffset += details.delta.dx;
    });
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (_dragActivated) return;
    final velocity = details.primaryVelocity ?? 0;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final distanceThreshold = screenWidth * _distanceRatio;

    final playerProvider = context.read<PlayerProvider>();

    if (_dragOffset < -distanceThreshold || velocity < -_velocityThreshold) {
      // 向左滑 → 下一首
      _switchDirection = 1;
      _dragOffset = 0.0;
      AppHaptics.click(HapticCategory.gesture);
      playerProvider.next();
      setState(() {});
    } else if (_dragOffset > distanceThreshold ||
        velocity > _velocityThreshold) {
      // 向右滑 → 上一首
      _switchDirection = -1;
      _dragOffset = 0.0;
      AppHaptics.click(HapticCategory.gesture);
      playerProvider.previous();
      setState(() {});
    } else {
      // 未达阈值，回弹归位
      _animateSnapBack();
    }
  }

  /// 把 [_dragOffset] 从当前值动画回 0，实现松手回弹。
  void _animateSnapBack() {
    final start = _dragOffset;
    _snapAnim = Tween<double>(begin: start, end: 0.0).animate(
      CurvedAnimation(parent: _snapController, curve: Curves.easeOut),
    )..addListener(() {
        if (mounted) {
          setState(() {
            _dragOffset = _snapAnim!.value;
          });
        }
      });
    _snapController.forward(from: 0.0);
  }

  // ── 上滑展开 FullPlayer ──
  // 关键约束：手势期间绝不 push 路由（实测 push 会立即切断整个事件流，
  // 跟手失效）。跟手显示由 Navigator 之上的覆盖层（playerExpansion 驱动）
  // 承担；松手后手势已结束，再 push 路由并让路由从当前进度继续展开。

  /// 当前跟踪的 pointer（nil = 无拖拽）
  int? _activePointer;
  // 起点位置（用于判定垂直上滑与累计距离）
  double _downY = 0.0;
  double _downX = 0.0;
  // 上滑累计距离 / 是否已确认展开手势 / 完整展开距离（MiniPlayer 顶端 Y）
  double _dragDistance = 0.0;
  bool _dragActivated = false;
  double _miniTopY = 0.0;
  // 迷你条底端 Y：与 [_miniTopY] 同一次测量（同为锚点空间），
  // 供双向展开面板反解条高 —— p=0 时面板必须恰好等于迷你条矩形。
  double _miniBottomY = 0.0;
  // 速度/加速度估计：按事件时间戳差分（向上为正）
  double? _lastVelocity;
  double? _lastY;
  Duration? _lastSampleTime;
  double _lastAcceleration = 0.0;

  void _onRawDown(PointerDownEvent e) {
    if (_activePointer != null) return; // 已在跟踪其他手指
    _activePointer = e.pointer;
    // 用户重新按住 = 接管上一次回弹（回弹动画若不停，会继续逐帧覆写
    // playerExpansion，与新手势的跟手值打架）。
    _dragRelease.stop();
    // 原始指针事件是**窗口坐标**，而 `_miniTopY` / 路由位移是设计像素：
    // 不换算会让跟手进度偏 s²（1.1 档快 21%）。统一按设计像素累计。
    final down = toDisplaySpace(context, e.position);
    _downY = down.dy;
    _downX = down.dx;
    _dragDistance = 0.0;
    _dragActivated = false; // 新手势开始，重置上滑守卫
    _lastVelocity = null;
    _lastY = down.dy;
    _lastSampleTime = e.timeStamp;
    _lastAcceleration = 0.0;
    // 预测量 MiniPlayer 顶端全局 Y（= FullPlayer 展开起点）。
    // 拖拽起点必须是**设计像素**（路由的 Transform.translate 与 MediaQuery
    // 屏高同在 DisplayScaleScope 内）；localToGlobal 默认量到根空间（窗口
    // 像素），非 1.0 档会偏 s 倍——改按锚点（设计像素）空间量取，
    // 无锚点（_scaleAnchor 为 null）回退根空间，与修复前行为一致。
    final box = context.findRenderObject() as RenderBox?;
    _miniTopY =
        box?.localToGlobal(Offset.zero, ancestor: _scaleAnchor).dy ?? 0.0;
    // 底端用同一个 box 的布局高度（与 localToGlobal 同处锚点空间，坐标系一致）。
    _miniBottomY = box == null ? 0.0 : _miniTopY + box.size.height;
  }

  void _onRawMove(PointerMoveEvent e) {
    if (e.pointer != _activePointer) return;
    final p = toDisplaySpace(context, e.position);
    final deltaY = _downY - p.dy; // 向上为正（设计像素）
    final deltaX = (p.dx - _downX).abs();
    if (!_dragActivated) {
      // 确认是垂直上滑：位移超过 touch slop 且垂直占主导（否则交给点击/水平切歌）
      // touchSlop 是 dp 语义（与显示缩放同源），可直接与设计像素位移比较
      if (deltaY < kTouchSlop || deltaY <= deltaX) return;
      _dragActivated = true;
      publishPlayerDragOrigin(top: _miniTopY, bottom: _miniBottomY);
      playerDragActive.value = true; // 显示跟手覆盖层
    }
    _dragDistance = deltaY.clamp(0.0, double.infinity);
    // 速度/加速度估计：按事件时间戳差分
    final ts = e.timeStamp;
    if (_lastSampleTime != null && _lastY != null) {
      final dt = (ts - _lastSampleTime!).inMicroseconds / 1e6;
      if (dt > 0) {
        final v = (_lastY! - p.dy) / dt; // dp/s，向上为正
        if (_lastVelocity != null) {
          _lastAcceleration = (v - _lastVelocity!) / dt;
        }
        _lastVelocity = v;
      }
    }
    _lastY = p.dy;
    _lastSampleTime = ts;
    // 驱动跟手覆盖层：位置进度 = 上滑距离 / 完整展开距离
    if (_miniTopY > 0.0) {
      playerExpansion.value = (_dragDistance / _miniTopY).clamp(0.0, 1.0);
    }
  }

  void _onRawUp(PointerUpEvent e) {
    if (e.pointer != _activePointer) return;
    _activePointer = null;
    // 注意：不在此重置 _dragActivated——up 之后竞技场 sweep 仍会触发
    // onHorizontalDragEnd，必须保持上滑守卫，直到下一次手势开始（_onRawDown）
    if (!_dragActivated) return;
    // 上滑流程已接管手势，水平切歌的 onHorizontalDragEnd 被守卫跳过，
    // 此处归零 _dragOffset，避免进入 FullPlayer 后返回时封面/标题错位残留
    if (_dragOffset != 0.0) setState(() => _dragOffset = 0.0);
    final expand = shouldExpandPlayer(
      dragDistance: _dragDistance,
      screenHeight: MediaQuery.sizeOf(context).height,
      velocity: _lastVelocity ?? 0.0,
      acceleration: _lastAcceleration,
    );
    if (expand) {
      _expandPlayerFromDrag();
    } else {
      // 未达阈值：面板**动画回弹**到迷你条（旧实现单帧硬归零，观感是
      // 「拉到一半啪一下没了」）。与悬浮胶囊共用同一个回弹驱动。
      _dragRelease.settleBack(
        reduceMotion: MediaQuery.disableAnimationsOf(context),
        onDone: () {
          if (!mounted) return;
          playerDragActive.value = false;
        },
      );
    }
  }

  void _onRawCancel(PointerCancelEvent e) {
    if (e.pointer != _activePointer) return;
    _activePointer = null;
    // 手势被系统打断：收起覆盖层（同样保持守卫到下一次 down）。
    // 系统打断时用户没有期待动画，瞬时归零。
    if (_dragActivated) {
      // 同 _onRawUp：上滑接管后归零水平偏移，防止错位残留
      if (_dragOffset != 0.0) setState(() => _dragOffset = 0.0);
      _dragRelease.stop();
      playerDragActive.value = false;
      playerExpansion.value = 0.0;
    }
  }

  /// 松手判定展开：push 拖拽路由并让路由从当前进度继续展开。
  /// 此时手势已结束（up 已处理），push 不再影响事件流。
  ///
  /// 交接要点（避免松手闪烁）：
  /// - 覆盖层在 Navigator 之上，路由渲染需要一帧；先 push 路由并停在当前
  ///   进度（不立即动画），等路由渲染完成后再隐藏覆盖层并启动展开动画，
  ///   保证「覆盖层 → 路由」无缝衔接
  /// - 不重置 playerExpansion（覆盖层销毁后由路由 build 同步接管进度），
  ///   避免 MiniPlayer 瞬间恢复全亮造成闪烁
  void _expandPlayerFromDrag() {
    final progress = playerExpansion.value;
    // 防重复入栈：路由栈里已有播放页时不再 push，否则会出现多个
    // AmStyleFullPlayer 实例、各自驱动歌词等动画，整页帧率翻倍（实测
    // 120Hz 屏 ~120fps 且明显发热）。与 openFullPlayer 同一语义。
    if (activePlayerRoute != null) {
      playerDragActive.value = false;
      return;
    }
    if (_miniTopY <= 0.0 || progress <= 0.0) {
      playerDragActive.value = false;
      playerExpansion.value = 0.0;
      return;
    }
    AppHaptics.lightImpact(HapticCategory.gesture);
    final route = fullPlayerRoute(
      context,
      dragOriginTop: _miniTopY,
      screenHeight: MediaQuery.sizeOf(context).height,
      dragOriginBottom: _miniBottomY,
    );
    // 交接实现收口到 full_player_route.dart（与悬浮胶囊共用）：
    // push → 停在当前进度 → 两帧后覆盖层让位 + 路由续播。
    // 常驻条不写横向范围/圆角（默认值 = 通栏 + 方角），所以这里不用传。
    handOffDragToRoute(
      navigator: Navigator.of(context),
      route: route,
      progress: progress,
      onOverlayRelease: () {
        if (!mounted) return;
        playerDragActive.value = false;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // 形态交叉过渡期间让位：过渡由 [BottomBarMorphOverlay] 独占那一根条，两端
    // 真身各自不画自己（否则同屏两条 / 中段双影）。订阅进度而非一次性读值 ——
    // 进度进出窗口时本条才重建，静止期零重建（AGENTS §10）。
    //
    // **让位 = 保挂载、不绘制**（`Offstage`），不是卸载子树（旧写法
    // `SizedBox.shrink()`）：被卸载的封面 State 会在交棒首帧重建，本地音乐的
    // 封面走本地字节路径（`LocalArtworkImage` 的 `_bytes` / `SmartArtworkImage`
    // 的 `_localArtworkBytes`），重建即重新异步读字节 → 首帧占位符 = 用户看到的
    // 「交棒瞬间封面闪烁」。`Offstage` 只跳过 paint/hit-test（layout 照跑），
    // 真身的 State 与 `ImageProvider` 实例跨飞行窗口存活，交棒那一帧直接复用
    // 已解码的位图。
    //
    // **树形必须跨帧稳定**：`Offstage` 恒在，只有 `offstage` 标志翻转 ——
    // 若按窗口在两个不同 widget（`Offstage(...)` ↔ 条本体）之间切换，元素树的
    // 槽位类型变了，子树照样整棵卸载重建，等于没修。
    //
    // **不额外产帧**：`TickerMode(enabled: false)` 停掉子树内的 Ticker（本条
    // 自身的 `_entranceController` 只在 null→有歌 时跑，飞行期本就不动）；
    // 挂载期唯一的持续成本是 layout，与浮层逐帧动画同帧，不新增帧提交。
    // **条体作为 `child` 传入**（见 [_MiniPlayerBarBody]）：窗口内每帧只翻
    // `Offstage` 标志，条体实例恒定 → `Element.updateChild` 见实例相同即短路，
    // 不再逐帧重建整棵条（AGENTS §10）。条体自己持有全部 `watch` 依赖。
    return ListenableBuilder(
      // 让位判据读窗口开关 + 源端标记（见 [bottomBarFormFlightListenable]）——只订阅
      // 进度会在开窗当帧不重建、不让位。
      listenable: bottomBarFormFlightListenable,
      child: _MiniPlayerBarBody(this),
      builder: (context, child) {
        // 常驻条端：窗口内**只有目的形态是胶囊时**让位（源形态留在画上，由浮层盖住）。
        final bool standDown = barFormRealBarStandsDown(false);
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

  Widget _buildPlayerBar(BuildContext context) {
    final playerProvider = context.watch<PlayerProvider>();
    final currentSong = playerProvider.currentSong;

    if (currentSong == null) {
      _hadSong = false; // 清空后再次播放可重弹
      return const SizedBox.shrink();
    }

    // 车机模式：播放器常驻在侧边面板里，任何界面都不再显示 MiniPlayer。
    // 判定用 active 而不是 panelVisible —— 设置页 / 登录页虽然不显示面板，
    // 但同样不该出现迷你条，否则「开了车机模式还有迷你条」前后不一致。
    // active 含自动检测：命中车机屏也静音 MiniPlayer。
    if (context.watch<CarModeProvider>().active) {
      return const SizedBox.shrink();
    }

    // 持续登记本条矩形（设计像素、锚点空间），供形态交叉过渡浮层取起点。
    _scheduleRegisterResidentRect();

    // 飞行封面纹理预热（笔 A）：只在「本会话已展开过播放页」之后预付，见方法注释。
    _maybePrewarmCoverTexture(context, currentSong.artworkUri);

    final colorScheme = Theme.of(context).colorScheme;
    // 公开版偏好：启用自定义背景时，MiniPlayer 用半透明背景透出背景图
    final useBackgroundImage = context.watch<ThemeProvider>().useBackgroundImage;

    // 仅在本实例观察到 null→有歌 的转变时播放入场动画；
    // 页面切换重建（_hadSong 初始 true）不触发
    if (!_hadSong) {
      _hadSong = true;
      if (kMiniPlayerSkipNextEntrance) {
        // 冷启动恢复播放：直接满显示、不弹，避免启动期遮罩偶发残留导致内容偏灰
        kMiniPlayerSkipNextEntrance = false;
        _entranceController.value = 1.0;
      } else if (MediaQuery.disableAnimationsOf(context)) {
        // 系统「减弱动态效果」：不播 morph，直接满显示
        _entranceController.value = 1.0;
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _entranceController.forward(from: 0.0);
        });
      }
    }

    // ── 圆角避让净空：逐帧只重建「留白层」 ──
    //
    // 底栏收起/展开（进/出二级页面，260ms）期间，本条从「压在导航栏上」过渡到
    // 「自身即屏幕最底部」：底部净空 0→inset、内容行左右内边距 4→圆角反解值，
    // 内容随之收缩。这两段几何按底栏收起进度逐帧插值，因此**只有留白层**需要
    // 逐帧重建 —— 内容本体（封面图 / 两行文字 / 三个按钮 / 进度条 / 探针）作为
    // `AnimatedBuilder.child` 跨帧缓存，逐帧只被重新挂载，不重建、不重算样式、
    // 不重造闭包。
    //
    // 两个「不进 build」的前提（少一个整棵子树就会被拖去逐帧重建，那正是
    // 「收缩动画不流畅」的主要来源）：
    // - 进度源走 `collapseStateOf` 的**一次性读数**（`getElementFor…`）：坞位
    //   存在性变化时 build 会重跑，但收起进度本身每帧都变，一旦用
    //   `chromeCollapseOf`（`dependOn…`）进 build，转场全程 build 逐帧跑；
    // - 终态净空按 aspect 读 MediaQuery（`viewPaddingOf` + `displayCornerRadiiOf`）：
    //   同期 `_withAnimatedBottomInset` 每帧都在改 `padding.bottom`，全量
    //   `MediaQuery.of` 依赖等于第二个逐帧重建源。
    final collapse = BottomChromeScope.collapseStateOf(context).animation ??
        const AlwaysStoppedAnimation<double>(1.0);
    final alone = resolveMiniPlayerCornerClearanceFrom(
      viewPaddingBottom: MediaQuery.viewPaddingOf(context).bottom,
      cornerRadii: MediaQuery.displayCornerRadiiOf(context),
    );
    // 底色在 build 里算一次、由 builder 闭包捕获：主题/壁纸开关变化才重算，
    // 逐帧零分配。
    final background = resolveMiniPlayerBackground(
      colorScheme,
      useBackgroundImage: useBackgroundImage,
    );

    // 可交互本体：滑动切歌开关 + 上滑展开手势 + 点击展开 + 内容。
    // 留白层（背景 + 底部净空）放在 Listener/GestureDetector **之内**，命中区域
    // 才与改动前一致 —— 底部净空带照旧属于本条，点它照样展开播放页。
    final interactable = ValueListenableBuilder<bool>(
      // 滑动切歌开关关闭时，不注册水平拖动回调，仅保留点击展开
      valueListenable: miniPlayerSwipeSwitchEnabled,
      builder: (context, swipeEnabled, _) => Listener(
        // 上滑展开：手势期间不 push（push 会切断事件流），
        // 由 Navigator 之上的覆盖层跟手显示，松手后再 push 路由
        behavior: HitTestBehavior.opaque,
        onPointerDown: _onRawDown,
        onPointerMove: _onRawMove,
        onPointerUp: _onRawUp,
        onPointerCancel: _onRawCancel,
        child: GestureDetector(
          // 点击展开 FullPlayer（栈顶已有播放器路由时不重复 push）
          onTap: () {
            // 上滑展开识别后（含 up 后 sweep 阶段）不响应点击
            if (_dragActivated) return;
            // 点击进入也登记收起基准，让播放页下拉收起对齐迷你条真实位置
            if (_miniTopY > 0) {
              publishPlayerDragOrigin(top: _miniTopY, bottom: _miniBottomY);
            }
            openFullPlayer(context);
          },
          // 水平滑动切歌（受设置开关控制）
          onHorizontalDragStart: swipeEnabled ? _onHorizontalDragStart : null,
          onHorizontalDragUpdate: swipeEnabled ? _onHorizontalDragUpdate : null,
          onHorizontalDragEnd: swipeEnabled ? _onHorizontalDragEnd : null,
          behavior: HitTestBehavior.opaque,
          // P0: 进度条在 _buildContent 内部用 ValueListenableBuilder 仅订阅
          // positionNotifier（高频 200ms），本层静态构建，避免封面/标题/按钮
          // 随每次进度刷新重建。
          child: AnimatedBuilder(
            // 逐帧只重建这一层：底色（铺满含净空的整块）+ 底部净空（条高随之
            // 变化）。内容子树作为 child 跨帧复用。
            animation: collapse,
            child: _buildContent(
              context,
              playerProvider,
              currentSong,
              colorScheme,
              collapse,
              alone,
            ),
            builder: (context, child) {
              final clearance = lerpMiniPlayerClearance(
                alone: alone,
                t: _collapseT(context, collapse),
              );
              return DecoratedBox(
                // 底色画在这一层（含底部净空区）：净空带与条体同色，不露白边。
                // 取值与展开面板的过渡态底色同源（resolveMiniPlayerBackground），
                // p=0 时面板窗口恰好压在本条上，颜色一致才看不出「起点色差」。
                decoration: BoxDecoration(color: background),
                child: Padding(
                  // 底部净空：自身即屏幕最底部时（二级路由 / 横屏侧栏 /
                  // 导航栏隐藏），同时防住屏幕圆角裁切与系统手势条；下方还压着
                  // NavigationBar 时沿用原 SafeArea(bottom: true) 口径
                  // （Scaffold 已移除 body 的 bottom padding，实测为 0，两者等价）。
                  padding: EdgeInsets.only(bottom: clearance.bottom),
                  child: child,
                ),
              );
            },
          ),
        ),
      ),
    );

    return ValueListenableBuilder<double>(
      valueListenable: playerExpansion,
      builder: (context, expansion, child) {
        // opacity 与展开进度线性绑定：expansion=0 时完全可见，expansion=1 时完全隐藏
        // IgnorePointer 防止淡出过程中拦截下层手势
        final opacity = (1.0 - expansion).clamp(0.0, 1.0);
        return IgnorePointer(
          ignoring: expansion > 0.5,
          child: Opacity(opacity: opacity, child: child),
        );
      },
      // 入场动画层：外层 expansion-opacity 不变，内层叠加「底部弹出 + 背景色遮罩 morph」
      child: AnimatedBuilder(
        animation: _entranceAnim,
        child: interactable,
        builder: (context, child) {
          final t = _entranceAnim.value; // 0→1
          return SizeTransition(
            // 底部对齐、向上展开：消除主布局 Column 里 MiniPlayer 占位 0→H 的内容瞬间压缩
            axis: Axis.vertical,
            alignment: Alignment.bottomCenter,
            sizeFactor: _entranceAnim,
            child: SlideTransition(
              // 从屏幕下方一个自身高度处滑入到位
              position: Tween<Offset>(
                begin: const Offset(0.0, 1.0),
                end: Offset.zero,
              ).animate(_entranceAnim),
              child: Stack(
                children: [
                  // 本体撑满宽度（Stack 对非定位子给 loose 约束，需显式撑满）
                  SizedBox(width: double.infinity, child: child),
                  // 背景色遮罩：t=0 完全盖住本体（只见纯色块），t=1 淡出露出本体
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Opacity(
                        opacity: (1.0 - t).clamp(0.0, 1.0),
                        child: ColoredBox(
                          color: background,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 生效的底栏收起进度：0 = 底栏完整在场，1 = 自身即屏幕最底部。
  ///
  /// 口径与 `BottomChromeScope.chromeCollapseOf` 一致（坞位不存在 —— 横屏侧栏 /
  /// 已收起 / 无 scope 祖先 —— 时恒为 1），但走**一次性读数**，不为 InheritedWidget
  /// 建立依赖（理由见 build 里「圆角避让净空」那段注释）。
  ///
  /// 在留白层的 builder 里逐次调用（而不是 build 里取一次快照）：builder 每个动画
  /// 帧都会跑，`hasBottomChrome` 因此每帧都是新鲜的。坞位存在性的翻转要么伴随
  /// 动画帧（collapse 过 1.0 的起止帧），要么伴随本条重建（横竖屏切换会改
  /// viewPadding）—— 两者任一发生就读到新值；两者都不发生时 scope 本身也没被重算，
  /// 与改动前同源，不引入新的陈旧窗口。
  double _collapseT(BuildContext context, Animation<double> animation) {
    final state = BottomChromeScope.collapseStateOf(context);
    if (!state.hasBottomChrome) return 1.0;
    return (state.animation ?? animation).value.clamp(0.0, 1.0);
  }

  /// 持续登记本条矩形（设计像素、锚点空间），供 `BottomBarMorphOverlay` 取形态
  /// 交叉过渡的常驻条端点。
  ///
  /// 量的是**自身 render box**（与 [_onRawDown] 同一个 box、同一空间），口径 =
  /// 含底部净空、底端到自身 box 底端。用 post-frame 排到本帧绘制之后，避免在
  /// build/layout 里写登记簿触发 "setState during build"（同
  /// `player_panel_frame.dart` 在 layout 阶段写 `pageOffset` 的做法）。
  ///
  /// **只登记结算态几何**：本条不在栈顶（被 push 出来的页面盖住，转场里还带
  /// 平移量）或所属 tab 被切到后台时不登记 —— 覆盖期/后台的任何重登都会把
  /// 「导航前最后一次干净登记」冲掉，下一次 pop 交棒的常驻条端点就跟着错
  /// （会诊 D2/D4：端点必须取导航前最后一次结算值，飞行期间还要冻结）。
  ///
  /// **飞行窗口内不写**（[inBottomBarFormFlight]）：让位改成 `Offstage` 之后
  /// build/layout 仍在跑，这条 post-frame 回调也照旧会跑，但此刻本条既被浮层
  /// 覆盖、几何又随底栏收起/转场逐帧抖动 —— 写进去就会把 F1 冻结的端点冲掉
  /// （浮层读 `frozenResidentRect ?? residentRect`）。所以门开在**写入点**，
  /// 而不是靠「让位时子树不存在」这个已不成立的旧前提。
  void _scheduleRegisterResidentRect() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (inBottomBarFormFlight()) return;
      if (_residentRoute?.isCurrent != true || !_tickerModeEnabled) return;
      final box = context.findRenderObject() as RenderBox?;
      // attached：post-frame 回调执行前本条可能已被卸载（tab 切换/转场），
      // 挂着的 box 引用拿去做 localToGlobal 会触发
      // 「RenderObject.getTransformTo: attached」断言（2026-10-16 TV 真机刷屏）。
      if (box == null || !box.attached || !box.hasSize) return;
      final origin = box.localToGlobal(Offset.zero, ancestor: _scaleAnchor);
      BottomBarMorphRegistry.instance.residentRect = origin & box.size;
    });
  }

  /// tv: 遥控下滑动区提供单一焦点入口（OK=展开播放页），右侧 IconButton
  /// 保持原生焦点，互不干扰（与 TV 参考实现一致）。onSelect 与触屏 onTap
  /// 是同一套守卫与收起基准登记逻辑；非 TV 构建原样返回，触屏路径零变化。
  Widget _tvSwipeAreaFocus(Widget child) {
    if (!kTvBuild) return child;
    return DpadFocusable(
      debugLabel: 'mini_player_swipe_area',
      focusNode: _tvSwipeFocusNode,
      onSelect: () {
        // 上滑展开识别后（含 up 后 sweep 阶段）不响应点击
        if (_dragActivated) return;
        // 点击进入也登记收起基准，让播放页下拉收起对齐迷你条真实位置
        if (_miniTopY > 0) {
          publishPlayerDragOrigin(top: _miniTopY, bottom: _miniBottomY);
        }
        openFullPlayer(context);
      },
      child: child,
    );
  }

  /// 条体内容（不含底色与底部净空 —— 两者在 build 的留白层里逐帧插值）。
  ///
  /// [collapse] / [alone] 供行级左右内边距的逐帧层使用：那一层同样只重建
  /// Padding 本身，整行内容作为 `AnimatedBuilder.child` 跨帧复用。
  Widget _buildContent(
    BuildContext context,
    PlayerProvider playerProvider,
    dynamic currentSong,
    ColorScheme colorScheme,
    Animation<double> collapse,
    MiniPlayerCornerClearance alone,
  ) {
    // 记录本次构建的封面归属：封面探针的 paint 回调据此丢弃「正在滑出的旧封面」
    // 上报的矩形。build 阶段写普通字段（非 setState），安全。
    _coverSongId = currentSong.id as String;
    // 文字样式在此算一次，真实文本与形变槽位共用同一份实例：
    // 两处若各算一次，`TextStyle` 的 `==` 仍成立，但共享实例更省事、也不会漂移。
    final textTheme = Theme.of(context).textTheme;
    final miniTitleStyle = textTheme.bodyMedium;
    final miniSubtitleStyle = textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );
    // tv: 进度条加粗 2→4dp 并移到内容行下方（非 TV 保持顶置 2dp 原样）。
    final double progressStroke = kTvBuild ? 4.0 : kPlayerBarProgressLineStroke;
    // 进度只对变化敏感：用 ValueListenableBuilder 只订阅 position 通道，
    // 封面/标题/按钮等静态内容不再随 200ms 进度刷新重建。
    Widget buildProgressLine() => ValueListenableBuilder<Duration>(
          valueListenable: playerProvider.positionNotifier,
          builder: (context, position, _) {
            final duration = playerProvider.duration ?? Duration.zero;
            final progress = duration.inMilliseconds > 0
                ? position.inMilliseconds / duration.inMilliseconds
                : 0.0;
            // 常驻条走同一 painter 的 formT=0 端点（顶置直线），与悬浮胶囊的
            // 内缘包边共用一套几何，交叉过渡期间只变形、不换画法。
            // 盒子高取直线描边宽 → 中心线落在盒中线、描边带正好铺满。
            // formT=0 逐项复刻旧的 M3ELinearProgressIndicator(value:, minHeight: 2,
            // backgroundColor: surfaceContainerHighest, color: primary)：轨道色取
            // **surfaceContainerHighest**（不是胶囊那套 onSurfaceVariant@0.16），
            // 端帽 StrokeCap.round、gapSize 4dp、轨道末端 4dp stop 点都照 M3E 默认值
            // （后者在描边宽 2 时与轨道的圆端帽重合，只把轨道最右 2dp 画成进度色）。
            return SizedBox(
              width: double.infinity,
              height: progressStroke,
              child: CustomPaint(
                key: const ValueKey('mini-player-progress'),
                painter: PlayerBarProgressPainter(
                  progress: progress.clamp(0.0, 1.0),
                  formT: 0.0,
                  trackColor: colorScheme.surfaceContainerHighest,
                  activeColor: colorScheme.primary,
                  cornerRadius: 0.0,
                  gapSize: kPlayerBarProgressLineGap,
                  strokeCap: StrokeCap.round,
                  stopIndicatorSize: kPlayerBarProgressLineStopSize,
                  lineStroke: progressStroke,
                ),
              ),
            );
          },
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // tv: 进度条移到 miniplayer 下方 —— 内容行在前、进度在后；非 TV 顺序
        // 与改动前逐像素一致（进度顶置）。
        if (!kTvBuild) buildProgressLine(),
        const PlaybackStatusFeedback(),
        // 左右内边距在「自身即屏幕最底部」时按圆角反解值加宽（本机 R=58 /
        // 底部 20dp → 15dp），有导航栏时为 4dp。
        //
        // 垂直 2 恒定、只有左右随收起进度变，故拆成两层：外层静态 Padding 管
        // vertical，内层 AnimatedBuilder 逐帧只改左右 —— 整行内容（封面 / 文字 /
        // 三个按钮 / 探针）作为 child 跨帧复用，转场期间一个都不重建。放在**行**
        // 上而不是整条上，进度条保持满宽（与改动前逐像素一致）。
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: AnimatedBuilder(
            animation: collapse,
            child: Row(
              children: [
                // —— 滑动区：封面 + 歌曲信息，跟随手指平移 + 切歌过渡 ——
                Expanded(
                  // tv: 遥控下滑动区是单一焦点入口（OK=展开播放页），
                  // 右侧 IconButton 保持原生焦点，互不干扰。
                  child: _tvSwipeAreaFocus(
                    ClipRect(
                    // 裁剪溢出，防止滑动时侵入右侧按钮区
                    child: AnimatedSwitcher(
                      // 系统「移除动画」：切歌换 0ms 瞬时切换（不播 300ms 进出场
                      // 补间；AnimatedSwitcher 仍有一次布局切换，可接受）。
                      duration: _reduceMotion
                          ? Duration.zero
                          : const Duration(milliseconds: 300),
                      switchInCurve: M3ExpressiveMotion.expressiveEasing,
                      switchOutCurve: M3ExpressiveMotion.switcherExitCurve,
                      transitionBuilder: (child, animation) {
                        // 初次出现不播放淡入：内容直接显示（显现交给入场 morph），
                        // 避免启动期 ticker 不稳使淡入卡在半透明导致封面/标题/歌手发灰。
                        // 本 SDK 的 AnimatedSwitcher 无 animateFirstChild 参数，用实例标志实现。
                        if (!_contentShownOnce) {
                          _contentShownOnce = true;
                          return child;
                        }
                        // isEntering 判定：新 child 的 key == 当前歌曲 id
                        final isEntering =
                            child.key == ValueKey(currentSong.id);
                        // 进入：沿切歌方向滑入（向左滑切下一首 → 新内容从右边进入）
                        // 离场：朝切歌方向的反方向滑出（旧内容向左边退出）
                        final dir = isEntering
                            ? _switchDirection
                            : -_switchDirection;
                        return SlideTransition(
                          position: Tween<Offset>(
                            begin: Offset(dir * 0.5, 0),
                            end: Offset.zero,
                          ).animate(animation),
                          child: FadeTransition(
                            opacity: animation,
                            child: child,
                          ),
                        );
                      },
                      child: KeyedSubtree(
                        key: ValueKey(currentSong.id),
                        child: Transform.translate(
                          // 拖动期间跟随手指；切歌触发后立即归 0 由 AnimatedSwitcher 接管
                          offset: Offset(_dragOffset, 0),
                          child: Row(
                            children: [
                              // 封面形变的起点探针：把 44×44 封面在屏幕上的
                              // 矩形上报给 PlayerCoverMorphBus，供形变层从迷你条
                              // 位置起飞。
                              //
                              // 为什么紧贴封面、放在 AnimatedSwitcher **里面**：
                              // 探针量的是自己那个盒子。只有贴住封面才量得到真正的
                              // 44×44；放到 AnimatedSwitcher 外面（那层 Expanded）
                              // 量到的是整条滑动区（宽约 60% 屏宽），起点会持续
                              // 偏到屏幕中央去，是 100% 复现的错。
                              // 里面会有「新旧两份并存」的问题（见下方回调），
                              // 那是可解的瞬时问题；外面是不可解的常态错误。
                              CoverGeometryProbe(
                                // 迷你端探针：注册「不经 paint 重测」的入口（见
                                // [CoverGeometryProbe.isMiniSource] 的成因说明）。
                                isMiniSource: true,
                                onRect: (rect, _) {
                                  // 切歌过渡期 AnimatedSwitcher 里新旧两份封面同时
                                  // 存在、两份都带探针，而「后画的赢」——正在滑出的
                                  // 旧封面会盖在当前封面之上最后绘制，若直接上报，
                                  // 形变起点会横向偏出去最多半个滑动区。
                                  // 闭包里的 currentSong 是**构建当时**的快照，与
                                  // `_coverSongId`（当前构建的封面）不同即为正在
                                  // 离场的那份，直接丢弃。只认当前封面，形变起点
                                  // 在切歌的 300ms 内也保持准确。
                                  if (currentSong.id != _coverSongId) return;
                                  PlayerCoverMorphBus.instance
                                      .publishMini(rect);
                                },
                                child: ValueListenableBuilder<double>(
                                  // 形变层一接管就**立即**让位，不再做淡出。
                                  // 判据与形变层、播放页槽位三方同源
                                  // （PlayerCoverMorphBus.layerWillDraw）：
                                  // 一旦形变层真的在画，就说明它已经画在了
                                  // 本封面此刻的位置上（p≈0 时两者重合），
                                  // 淡出只会拖成一个看得见的残影。
                                  // 若形变层没接管（例如车机面板 / 减弱动画），
                                  // 本封面保持显示，行为与改动前一致。
                                  // 必须自己订阅：外层 _buildContent 只构建一次
                                  // （被 build 里的 ValueListenableBuilder 当
                                  // child 复用），不随 playerExpansion 重建。
                                  // child 形式保证 ClipRRect 子树只构造一次、
                                  // 逐帧只被重新挂载，不重建 SmartArtworkImage。
                                  valueListenable: playerExpansion,
                                  builder: (context, expansion, cover) => Opacity(
                                    opacity: expansion > 0.0 &&
                                            PlayerCoverMorphBus
                                                .instance.coverLayerWillDraw
                                        ? 0.0
                                        : 1.0,
                                    child: cover,
                                  ),
                                  child: ClipRRect(
                                    borderRadius: AppRadius.coverAll,
                                    child: SizedBox(
                                      width: BottomChromeDimens
                                          .miniPlayerCoverSize,
                                      height: BottomChromeDimens
                                          .miniPlayerCoverSize,
                                      child: SmartArtworkImage(
                                        artworkUri: currentSong.artworkUri,
                                        fallbackFilePath:
                                            currentSong.localPath,
                                        songId: currentSong.id,
                                        size: BottomChromeDimens
                                            .miniPlayerCoverSize,
                                        borderRadius: AppRadius.cover,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                // 歌曲名 + 歌手也参与连贯形变：探针上报本块的
                                // 屏幕矩形作为飞行起点，形变层接管后立即让位
                                // （判据与封面同源，两者同一时刻一起交棒）。
                                // 文字块与悬浮胶囊、交叉过渡浮层共用
                                // [PlayerBarText]（同一文案只留一个实现）。
                                child: PlayerBarText(
                                  song: currentSong,
                                  titleStyle: miniTitleStyle,
                                  subtitleStyle: miniSubtitleStyle,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    ),
                  ),
                ),
                // —— 固定区：右侧按钮不参与滑动 ——
                // 桌面歌词按钮 + 播放控制：与交叉过渡浮层共用（内容只留一个实现）。
                // 常驻条侧两者都满显（opacity/widthFactor = 1），逐像素与改动前一致。
                // tv: 顶栏迷你条只保留播放/暂停——下一首与桌面歌词按钮按需求移除
                // （完整播放页 / 通知栏 / 遥控媒体键均有等价入口）。
                if (!kTvBuild)
                  const PlayerBarLyricButton(opacity: 1.0, widthFactor: 1.0),
                PlayerBarTransport(player: playerProvider, showNext: !kTvBuild),
              ],
            ),
            builder: (context, child) => Padding(
              padding: EdgeInsets.only(
                left: lerpMiniPlayerClearance(
                  alone: alone,
                  t: _collapseT(context, collapse),
                ).horizontal,
                right: lerpMiniPlayerClearance(
                  alone: alone,
                  t: _collapseT(context, collapse),
                ).horizontal,
              ),
              child: child,
            ),
          ),
        ),
        // tv: 进度条移到 miniplayer 下方（内容行之后），加粗 4dp。
        if (kTvBuild) buildProgressLine(),
      ],
    );
  }
}

/// 常驻迷你条的**条体**：可复用、自带订阅的子树。
///
/// 作为 [MiniPlayer] 的 [ValueListenableBuilder] 的 `child:` 传入 —— 形态交叉
/// 过渡窗口（`0 < kBottomBarFormProgress < 1`）内，外层每帧只翻 `Offstage` 标志，
/// 本 widget 实例不变，`Element.updateChild` 短路跳过整棵条的重建（AGENTS §10：
/// 窗口帧不再逐帧重建约 40~70 节点）。
///
/// **订阅归属**（本次提取最容易做错的地方）：条体的全部数据依赖
/// （`context.watch<PlayerProvider>` / `context.watch<CarModeProvider>` /
/// `context.watch<ThemeProvider>` / `Theme.of` / `MediaQuery.disableAnimationsOf`
/// …）都在 [_MiniPlayerState._buildPlayerBar] 里、且以**本 widget 的 `context`**
/// 调用 —— 依赖因此挂在本 widget 的 Element 上，播放态 / 主题 / 车机模式变化仍会
/// 触发本子树重建，不会退化成「提取之后不再刷新」。
///
/// 不随 `standDown` 变化的理由：常驻条条体本身没有任何让位相关行为（让位只是
/// 外层 `Offstage` 开关），故整体进 `child` 即可，无需保留部分逻辑在 builder 内。
class _MiniPlayerBarBody extends StatelessWidget {
  const _MiniPlayerBarBody(this._state);

  final _MiniPlayerState _state;

  @override
  Widget build(BuildContext context) => _state._buildPlayerBar(context);
}

/// 飞行封面纹理预热的**触发闸门**（[MiniPlayer] 每次 build 后判一次）。
///
/// 单独抽成纯函数是为了能在测试里直接钉住那条安全前提：
/// **本会话没展开过播放页就不预付**（判据 = 登记簿里还没有 `settledRect`）。
/// settled 档解码一张封面约 4MB 驻留，从不进播放页的用户不该为一次用不上的
/// 转场付这个代价；而没有 `settledRect` 时也根本算不出飞行层那一档的精确宽度，
/// 按屏幕估出来的档位与飞行层不同键，预热了也是白预热。
///
/// 「每首只付一次」由 [alreadyPrewarmedUri] 承担：同一首歌反复 build 不重复调度。
@visibleForTesting
bool shouldPrewarmCoverTexture({
  required String? artworkUri,
  required String? alreadyPrewarmedUri,
  required Rect? settledRect,
}) {
  if (artworkUri == null || artworkUri.isEmpty) return false;
  if (artworkUri == alreadyPrewarmedUri) return false;
  final settled = settledRect;
  if (settled == null || settled.width <= 0) return false;
  return true;
}
