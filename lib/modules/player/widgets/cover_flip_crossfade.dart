import 'dart:async';

import 'dart:ui' show ImageFilter, TileMode;
import 'dart:ui' as ui show Image;

import 'package:flutter/physics.dart' show SpringSimulation, Tolerance;
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:material_ui/material_ui.dart';

import '../cover_flip_physics.dart';
import '../cover_switch_physics.dart' show CoverSwitchIntent;
import '../cover_swipe_flip_physics.dart';
import '../../../widgets/player_artwork_image.dart'
    show
        PlayerArtworkImage,
        prewarmPlayerArtworkTexture,
        resolvePlayerArtworkImage;
import 'low_res_blur.dart';

/// 就绪等待上限：超过则进入兜底宽限（见 [kCoverFlipFallbackGrace]）。
///
/// 参考视频里「封面迟到补齐」那次翻转约等了 1s；取同量级。等待期间旧封面
/// 一直在位（与视频「封面到位才翻」一致）。
const Duration kCoverFlipReadyTimeout = Duration(milliseconds: 1000);

/// 兜底宽限：翻转等待超时后**继续等**这么久，仍不就绪才降级为交叉淡出。
///
/// 弱网（图床抖动 / 建连超时）下新封面常在 1~2s 才解码完成。原实现超时即
/// 放弃翻转、直接换图，真机观感是「封面瞬间消失、过一会儿又跳出来」——
/// 连切歌时最刺眼的那一下。宽限期内就绪照样演完整翻转（动画不丢），
/// 代价只是旧封面多停一会儿（有界，仍不无限压旧封面）。
const Duration kCoverFlipFallbackGrace = Duration(milliseconds: 1200);

/// 兜底过渡时长：无旋转、无模糊的交叉淡出（旧封面整层渐隐，新层在下显形）。
///
/// 只在「宽限也用尽 / 探测明确失败」时触发。新图没到位就翻 = 翻出一只白板
/// （占位符），比不翻更难看；而硬切是瞬变。淡出把这次瞬变摊到 220ms 里，
/// 观感是「旧封面柔和退场」——即便新层此刻仍是占位，也读作加载而非闪断。
const Duration kCoverFlipFallbackFade = Duration(milliseconds: 220);

/// 切歌封面过渡：旧封面「模糊加剧 + 绕纵轴翻倒」→ 新封面「翻入 + 逐渐清晰」。
///
/// 观感对齐参考视频（HyperOS 媒体通知卡）：封面先整体高斯模糊，再绕纵轴 3D
/// 翻倒（中段压成一条位于封面水平中央的竖线），新封面从竖线翻入并去模糊，
/// 全程约 [kCoverFlipDuration]（300ms）。
///
/// 契约：
/// - **触发键是 [version]（封面图 URI）**，不是歌曲 id：图没变不演过渡
///   （同专辑共用封面的连播不翻），同一首歌封面迟到补齐也演（与视频一致）。
///   旧值为 null（首图）或新值为 null（占位元数据，无可翻之物）不演。
/// - **新封面没就绪不翻**：图片没加载完就翻 = 翻出一只白板（占位符），动画
///   等于消失。由 [readinessProbe] 探测同键解码缓存，未就绪时继续显示旧封面
///   （与视频「封面后到、到位才翻」一致）。不传 probe 时退化为「version
///   变化即翻」。
/// - **兜底不是硬切**：等待超过 [readyTimeout] 后先进入 [fallbackGrace]
///   宽限——弱网下新图常在此窗口内到达，翻转照演（动画不丢）；宽限也用尽、
///   或探测明确失败，才降级为 [fallbackFadeDuration] 的交叉淡出（新层在底下
///   直接显形，旧封面整层渐隐）。早先两种兜底都是「放弃动画直接换图」，
///   弱网连切时表现为封面反复闪断——本条存在理由。
/// - **每层各自先裁圆角、再旋转**（[radius]）：旋转中的封面带透视，近端会
///   略微探出静止边界——若由外层统一裁圆角，探出部分会被切掉，表现为
///   「上下边缘被裁」。整张圆角卡片作为刚体旋转，不被裁。
/// - 旧层用 [PlayerArtworkImage]（平面图，页面已预加载进磁盘缓存、同键解码
///   通常已在内存缓存，翻出首帧即有图）；新层就是 [child] 本身（页面传入，
///   通常是 DepthCoverHost）。
/// - 翻转变换挂在封面子树**最内层**：位于 PlayerCoverSlot 的 CoverGeometryProbe
///   下游，形变探针量的是代理盒自身矩形，不受下游变换影响。
/// - 模糊必须 `TileMode.clamp`：Impeller 下不指定时默认 decal，图层外透明黑
///   会卷进卷积核形成暗晕（同 _buildCrossfadeBlurredBackground 的既有坑）。
/// - **逐帧 sigma 不再逐帧做高斯**：每层在**翻转启动前**构建一张低分辨率
///   模糊快照（[buildLowResBlurProxy]，≤96px 边长，一次卷积；就绪探测命中后
///   的 resolve 是同键缓存命中、同步补发，不额外推迟动画），动画期间
///   「清晰内容 + [coverFlipBlurAlpha](sigma(t)) 的快照叠层」用 alpha 混合
///   近似逐渐变糊/变清——500ms 里约 30 次全尺寸高斯收敛为每层 1 次小图
///   卷积。α 走 √ 曲线而非线性 σ/峰值：线性交叉淡会把清晰残影拖过大半程
///   （真机反馈「模糊度太小、变化不够剧烈」），√ 中段更快吞掉清晰成分。
///   **形态必须整段一致**：曾把快照构建推迟到启动后，动画中途从量化高斯
///   滤镜切换成叠层、两种形态模糊量不等价，真机看到「先变高斯、再被替换」
///   的跳变（本条存在理由）。源解析不了（内嵌封面等）则整段退回全分辨率
///   [ImageFiltered]，但 sigma 先量化进 [kCoverFlipBlurLadder]（唯一滤镜值
///   ~30 → ≤5 档，多帧复用同一份模糊层栅格），避免等级逐帧漂移的重算突发。
class CoverFlipCrossfade extends StatefulWidget {
  const CoverFlipCrossfade({
    super.key,
    required this.version,
    required this.child,
    required this.fallbackFilePath,
    required this.iconSize,
    this.placeholderColor = Colors.white12,
    this.iconColor = Colors.white54,
    this.enabled = true,
    this.duration = kCoverFlipDuration,
    this.radius = 0.0,
    this.direction = 1,
    this.readinessProbe,
    this.readyTimeout = kCoverFlipReadyTimeout,
    this.fallbackGrace = kCoverFlipFallbackGrace,
    this.fallbackFadeDuration = kCoverFlipFallbackFade,
    this.swipeEnabled = false,
    this.canGoPrevious = false,
    this.canGoNext = false,
    this.onSwipeCommit,
    this.swipeTargetBuilder,
    this.flipActive,
  });

  /// 身份键：封面图 URI。变化（且新旧值都非空）即触发一次翻转过渡。
  final String? version;

  /// 新封面构件（由页面构建，通常是 DepthCoverHost，可再叠动态封面）。
  final Widget child;

  /// 旧封面的本地回退路径（切歌瞬间锁存旧值，随旧层一起退场）。
  final String? fallbackFilePath;

  /// 旧封面占位 icon 大小。
  final double iconSize;

  /// 旧封面占位背景 / icon 色（AM 风格白底占位）。
  final Color placeholderColor;
  final Color iconColor;

  /// 关闭时退化为「直接换图」，不做任何动画。
  final bool enabled;

  /// 过渡总时长。
  final Duration duration;

  /// 封面圆角：每层各自「先裁圆角、再旋转」（见类文档）。
  final double radius;

  /// 翻转方向系数：+1 = 下一曲方向，-1 = 上一曲方向（对新旧两层取同一符号，
  /// 整体镜像）。页面按播放列表下标变化判定（coverSlideDirectionForIndexChange）；
  /// 方向未知（随机跳转）时页面沿用上一次的方向。
  final int direction;

  /// 新封面就绪探测（页面注入；null = 不探测，version 变化即翻）。
  ///
  /// 参数依次为新封面 URI、封面逻辑宽、devicePixelRatio——页面据此用
  /// `isPlayerArtworkReady` 做同键判定。返回 false（加载失败）或超过
  /// [readyTimeout] 都走「放弃动画直接换图」。
  final Future<bool> Function(
    String? artworkUri,
    double settledLogicalWidth,
    double devicePixelRatio,
  )? readinessProbe;

  /// 就绪等待上限。
  final Duration readyTimeout;

  /// 兜底宽限：超时后继续等新图的时间；用尽才降级为交叉淡出（见类文档）。
  final Duration fallbackGrace;

  /// 兜底交叉淡出时长（无旋转、无模糊）。
  final Duration fallbackFadeDuration;

  /// 跟手拖拽翻转切歌（AM 播放页注入；默认关闭，MD 页/测试不受影响）。
  ///
  /// 开启后手势走**第二条时钟**（`_motion`），与自动过渡的 `_flip` 由
  /// 五相位状态机互斥：手势路径全程零模糊、不做就绪探测。
  final bool swipeEnabled;

  /// 手势可切换的邻居（页面按播放列表/循环模式算；false 的一侧只出橡皮筋）。
  final bool canGoPrevious;
  final bool canGoNext;

  /// 松手判定要切歌时回调（页面负责触感 + `player.next()/previous()`）。
  /// null = 不接管手势（即使 [swipeEnabled] 为 true）。
  final void Function(CoverSwitchIntent intent)? onSwipeCommit;

  /// 卡背封面的构建器：参数为翻转方向（+1 下一曲 / -1 上一曲）。
  ///
  /// 首次锁定方向时调用**一次**并把结果锁存到手势收敛；null 则退化回旧行为
  /// （翻过 90° 后卡背区不画任何封面，观感是「翻走一张、等新图翻入」）。
  /// 页面应返回目标邻居的静态封面（不建 3D/动态封面：翻面窗口只有几百毫秒，
  /// 多拉一路视频或深度纹理纯属浪费）。
  final Widget Function(int direction)? swipeTargetBuilder;

  /// 翻转是否进行中（拖动/回弹/提交/等换歌都算）。
  ///
  /// 页面用它把封面外层那圈「静止方盒投影」淡出：阴影轮廓不跟着旋转收窄，
  /// 侧立时仍是一整块方形投影 → 穿帮。二值通道即可（页面侧 160ms 补间），
  /// 不逐帧推送数值，避免拖动帧额外重绘 BoxShadow。
  final ValueNotifier<bool>? flipActive;

  @override
  State<CoverFlipCrossfade> createState() => _CoverFlipCrossfadeState();
}

/// 手势路径的五相位。与自动过渡（`_flip`）互斥：
/// idle 之外的任何相位都由 `_motion` 驱动，`_buildBody` 只认其中一条时钟。
enum _CoverFlipSwipePhase { idle, dragging, awaitingCommit, completing, rebounding }

class _CoverFlipCrossfadeState extends State<CoverFlipCrossfade>
    with TickerProviderStateMixin {
  late final AnimationController _flip = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  /// 手势时钟（unbounded）：跟手阶段直接写值（t = p × kCoverFlipSwap），
  /// 回弹 / 提交交给弹簧模拟。unbounded 才能让 t 短暂越过 [0, 1]：
  /// 回弹负向过冲（角度反向轻翻一下）与提交末段过冲都靠它。
  late final AnimationController _motion = AnimationController.unbounded(
    vsync: this,
  );

  /// 正在退场的旧封面（版本切换时锁存）；动画收敛后清空，树回到单层。
  String? _oldArtworkUri;

  /// 旧封面 widget 实例：锁存 URI 时构建一次，翻转期间复用同一实例。
  ///
  /// 不缓存则 AnimatedBuilder 每帧重建都会新建 PlayerArtworkImage，
  /// 其子树（CachedNetworkImage/octo_image）逐帧走 didUpdateWidget +
  /// resolve 链。新层 widget.child 本就是页面传入的同实例，旧层对齐
  /// （fallback 等参数在锁存时一次性定型，见 didUpdateWidget）。
  Widget? _oldArtworkWidget;

  // ── 低分辨率模糊快照（见类文档；替代逐帧全尺寸高斯） ──────────────────
  //
  // 每个代理都带「所属封面 URI」标签：绘制时标签与当前层 URI 不一致就视为
  // 不可用（退回滤镜兜底）。连切歌时旧层锁存为新的 URI 而快照还是上一张的，
  // 没有这层校验会把上一张封面的模糊叠在当前张上（错图鬼影）。

  /// 旧层模糊快照 + 归属 URI（null = 未构建/构建失败，走滤镜兜底）。
  ui.Image? _oldBlurProxy;
  String? _oldBlurProxyUri;

  /// 新层模糊快照 + 归属 URI。新层是活 widget（3D 深度/动态封面），快照
  /// 取其**静态封面源**的等价近似：只在去模糊窗口以 α 权重叠加，α 随
  /// easeOut 快速衰减，视频层/视差层被静态模糊遮盖的时间极短。
  ui.Image? _newBlurProxy;
  String? _newBlurProxyUri;

  /// 最近一次布局测得的封面盒尺寸（构建快照的 cover-crop 目标比例）。
  double _settledHeight = 0;

  /// 就绪等待中的新版本（null = 不在等待）。用于丢弃过期的探测结果：
  /// 等待途中又切歌时，旧探测完成也不能再翻。
  String? _pendingVersion;
  Timer? _readyTimer;

  /// 兜底交叉淡出是否正在进行（宽限用尽 / 探测失败后）。
  ///
  /// 只用一个标志而不是自建时钟：这段过渡是**一次性、无状态**的（进入即从
  /// 1 走到 0，结束就把旧层摘掉），树上的 [TweenAnimationBuilder] 自带时钟，
  /// 分支一变状态自然回收（见 `_buildFallbackFade`）。
  bool _fallbackFading = false;

  /// 最近一次布局测得的封面逻辑宽 / dpr（就绪探测算同键解码档位用）。
  /// build 内只写不读 notify，与 _photoScheduledHash 同型约束。
  double _settledWidth = 0;
  double _dpr = 1;

  /// 快照构建的代次号（快速连切时旧回调按它作废自己，见 _prepareBlurProbes）。
  int _prepareSeq = 0;

  // ── 手势路径（见 [_CoverFlipSwipePhase]；全程零模糊、不做就绪探测） ──────

  _CoverFlipSwipePhase _swipePhase = _CoverFlipSwipePhase.idle;

  /// +1 下一曲（手指左移）/ -1 上一曲（手指右移）；0 = 起手方向未定。
  int _swipeDirection = 0;

  /// 本手势能否真的切歌（无邻居的一侧只做橡皮筋）。
  bool _swipeCanSwitch = false;
  CoverSwipeReboundStrength _swipeStrength = CoverSwipeReboundStrength.gentle;
  double _swipeOvershoot = 1.0;

  /// 松手速度（沿提交方向，px/s），提交时作为翻入弹簧的初速。
  double _swipeCommitVelocity = 0;

  /// 未钳制的页进度：越界（>1）信息必须留住，否则下一帧把 `_motion.value`
  /// 反算回进度会丢掉橡皮筋余量，手指继续拖时画面「吸回去」跳一下。
  double _swipeProgress = 0;

  /// 手指累计横坐标（kinematics 差分的输入）。
  double _dragX = 0;

  /// 卡背封面（目标邻居）：方向首次锁定后构建一次，提交后沿用至收敛。
  ///
  /// 不复用 `widget.child`：在回调发起切歌到新 `version` 到位之间，child 仍是
  /// **当前**歌的封面，翻过去会看到「同一张封面」而不是下一首（真机穿帮）。
  Widget? _swipeTargetWidget;

  /// 换歌已到、但翻面动画还在飞：等弹簧收敛后再清场。
  /// 立即清场会让画面从「翻到一半」直接跳到新封面（观感是啪地换图）。
  bool _finishWhenSettled = false;
  final CoverSwipeKinematics _kinematics = CoverSwipeKinematics();
  final Stopwatch _swipeWatch = Stopwatch();
  Timer? _commitGuard;

  /// 拖满一页所需像素（封面边长 × 比例）。
  double get _swipePitch =>
      _settledWidth > 0 ? _settledWidth * kCoverSwipeDragRatio : 0.0;

  bool get _swipeActive => _swipePhase != _CoverFlipSwipePhase.idle;

  @override
  void initState() {
    super.initState();
    _flip.addStatusListener(_onFlipStatus);
    _motion.addStatusListener(_onMotionStatus);
  }

  /// 翻转启动**前**构建两层的低分辨率模糊快照（每层每次过渡至多一次）。
  ///
  /// 为什么必须在启动前：中途替换会跳变——快照在动画里就绪的那一帧，叠层
  /// 形态（清晰 + α=σ/σmax 的峰值模糊）与刚撤掉的全分辨率量化高斯**不是
  /// 同一个模糊量**（真机反馈「先变成高斯模糊、然后被替换成 alpha，效果
  /// 很差」）。挪到启动前后：第 0 帧起就是叠层形态，整段过渡只有一种形态；
  /// 构建失败（内嵌封面等）则整段都用滤镜兜底，同样不切换。
  ///
  /// 开销可控：`resolvePlayerArtworkImage` 与就绪探测/纹理预热同键，是缓存
  /// 命中的纯 Dart 工作；卷积只在 ≤96px 小图上（每层一次，亚毫秒级），
  /// 与原来「翻转窗口内约 30 帧全尺寸高斯」相比仍是数量级更小的开销，
  /// 且这笔开销落在**动画开始前**的等待帧，不占用任何过渡帧。
  ///
  /// 旧层源就是锁存 URI 的静态封面；新层是活 widget（DepthCoverHost/
  /// 动态视频），取其**静态封面源**做等价近似（见字段注释）。
  Future<void> _prepareBlurProbes(String? oldUri, String? newUri) async {
    // 代次守卫：快速连切时旧 prepare 的 await 回调不得再动快照——否则会把
    // 新一轮刚建好的位图误清（最坏整段退化为滤镜兜底，形态仍一致不跳变,
    // 但没必要白白多算一次）。
    final seq = ++_prepareSeq;
    // 同标签的旧层快照可复用：
    //  - 常规切换：上一轮的旧层快照若恰好就是本轮要退场的那张（极少见）；
    //  - 翻转途中连切：本轮旧层取「此刻正在显示的那张」= 上一轮的新层，
    //    其快照在 _newBlurProxy 上——直接搬过来省一次小卷积与一次 resolve。
    // 复用仅限「内容确为同一封面」：URI 标签相符才搬，不符一律回收。
    if (oldUri != null) {
      if (_oldBlurProxy != null && _oldBlurProxyUri != oldUri) {
        _oldBlurProxy!.dispose();
        _oldBlurProxy = null;
        _oldBlurProxyUri = null;
      }
      if (_oldBlurProxy == null && _newBlurProxy != null) {
        if (_newBlurProxyUri == oldUri) {
          // 搬运所有权：本轮旧层快照沿用上一轮新层的（随后 _newBlurProxy
          // 重建）。必须摘除新层引用，否则下面的统一回收会把同一位图 dispose 两次。
          _oldBlurProxy = _newBlurProxy;
          _oldBlurProxyUri = oldUri;
          _newBlurProxy = null;
          _newBlurProxyUri = null;
        } else {
          _newBlurProxy!.dispose();
        }
      }
    }
    _newBlurProxy?.dispose();
    _newBlurProxy = null;
    _newBlurProxyUri = null;
    final box = Size(_settledWidth, _settledHeight);
    if (!box.isFinite || box.width <= 0 || box.height <= 0) return;
    final dpr = _dpr;
    if (oldUri != null && _oldBlurProxy == null && _oldArtworkUri == oldUri) {
      final src = await resolvePlayerArtworkImage(
        artworkUri: oldUri,
        settledLogicalWidth: box.width,
        devicePixelRatio: dpr,
      );
      // src 是缓存借用（与 prewarmPlayerArtworkTexture 同口径），**不 dispose**。
      if (!mounted || seq != _prepareSeq || _oldArtworkUri != oldUri) return;
      _oldBlurProxy = buildLowResBlurProxy(src, kCoverFlipBlurSigma, box);
      _oldBlurProxyUri = _oldBlurProxy == null ? null : oldUri;
    }
    if (newUri != null && widget.version == newUri) {
      final src = await resolvePlayerArtworkImage(
        artworkUri: newUri,
        settledLogicalWidth: box.width,
        devicePixelRatio: dpr,
      );
      // 又切歌：本轮快照作废（新一轮 prepare 会重建），不启动本轮翻转。
      if (!mounted || seq != _prepareSeq || widget.version != newUri) {
        _oldBlurProxy?.dispose();
        _oldBlurProxy = null;
        _oldBlurProxyUri = null;
        return;
      }
      _newBlurProxy = buildLowResBlurProxy(src, kCoverFlipBlurSigma, box);
      _newBlurProxyUri = _newBlurProxy == null ? null : newUri;
    }
  }

  /// 释放两层快照（过渡结束 / 撤销 / 卸载 / 重建前）。
  void _dropBlurProbes() {
    _oldBlurProxy?.dispose();
    _oldBlurProxy = null;
    _oldBlurProxyUri = null;
    _newBlurProxy?.dispose();
    _newBlurProxy = null;
    _newBlurProxyUri = null;
  }

  @override
  void didUpdateWidget(covariant CoverFlipCrossfade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _flip.duration = widget.duration;
    }
    if (!widget.enabled) {
      // 关闭编排：撤掉在飞的过渡与就绪等待，直接换图。
      if (_swipeActive) _cancelSwipe();
      _cancel();
      return;
    }
    // 手势被关掉（TV/车机门控切换）：撤掉在飞的手势路径，别把它留在半空。
    // 必须带 _swipeActive 守卫：自动过渡在飞时 _oldArtworkUri 是它的旧层，
    // 无条件 _cancelSwipe() 会把自动过渡掐掉。
    if (_swipeActive && oldWidget.swipeEnabled && !widget.swipeEnabled) {
      _cancelSwipe();
    }
    final oldV = oldWidget.version;
    final newV = widget.version;
    // 版本未变的重建（isPlaying 变化、歌词到达、设置读取……播放页的异步
    // setState 都会走到这儿）：**不能打断任何在飞的东西**——取消在飞的翻转
    // 或就绪等待，表现为「切歌后没有旋转动画」（真机复现：歌词 setState
    // 落在过渡窗口内，翻转被掐）。
    if (oldV == newV) return;
    // 手势提交的换歌到了：翻面由卡背封面完成，这里只安排清场——回 idle 后
    // 由 widget.child（新歌封面）接管；不启动 _flip，也不做就绪等待。
    // 若翻面弹簧还在飞，标记到收敛再清（否则半翻状态直接换图，观感跳变）。
    if (_swipePhase == _CoverFlipSwipePhase.awaitingCommit ||
        _swipePhase == _CoverFlipSwipePhase.completing) {
      if (_motion.isAnimating) {
        _finishWhenSettled = true;
      } else {
        setState(_finishSwipe);
      }
      return;
    }
    // 拖动 / 回弹中遇到 version 变化：**不打断**。进页面或刚切歌时当前歌封面
    // 常被富化补齐（歌没换、只是图 URL 变了），若在这里让位自动过渡，用户
    // 第一次滑动会拖到一半被弹回（真机反馈）。锁存的旧层继续演，松手后 idle
    // 自然显示新图；真正的换歌由上面的 awaitingCommit/completing 分支处理。
    if (_swipePhase == _CoverFlipSwipePhase.dragging ||
        _swipePhase == _CoverFlipSwipePhase.rebounding) {
      return;
    }
    if (_swipeActive) _cancelSwipe();
    // 兜底淡出在飞时又切歌：淡出作废，回到「等新图」——否则新一轮锁存的旧层
    // 会沿用上一轮的淡出进度（半透明的旧封面凭空变淡）。
    _fallbackFading = false;
    // 旧值为空（首图）或新值为空（占位元数据，无可翻之物）：不演过渡，
    // 撤掉在飞的过渡/等待直接换（与参考视频「图没变不翻」一致）。
    if (oldV == null || newV == null) {
      _cancel();
      return;
    }
    if (_pendingVersion == null) {
      // 常规切换 / 翻转途中再切：旧层取「上一个 version」——即此刻屏幕上
      // 正在显示的那张，不取上上一次，避免快速连切出现中间那首的残影
      // （TitleSwitchFade 同款口径）。
      _oldArtworkUri = oldV;
      _oldArtworkWidget = PlayerArtworkImage(
        artworkUri: oldV,
        fallbackFilePath: oldWidget.fallbackFilePath,
        fit: BoxFit.cover,
        iconSize: widget.iconSize,
        backgroundColor: widget.placeholderColor,
        iconColor: widget.iconColor,
      );
    }
    // 就绪等待中再切：旧层保持「此刻显示的那张」不动，只改等待目标。

    final probe = widget.readinessProbe;
    if (probe == null) {
      // 退化路径（不探测，version 变化即翻；仅测试这样接线）：保持立即
      // 翻转的语义不变。同键纹理预热在这里只作旁路兜底——它有自身的
      // resolve 链，不该让翻转等一个没有超时兜底的 Future（探测路径才有
      // readyTimeout 门控）。预热失败的日志也能暴露该路径的纹理上传。
      prewarmPlayerArtworkTexture(
        artworkUri: newV,
        settledLogicalWidth: _settledWidth,
        devicePixelRatio: _dpr,
      ).then((status) {
        if (!mounted) return;
        debugPrint('[CoverFlip] 旁路纹理预热 uri=$newV $status');
      });
      // 快照在启动**前**备齐（同键缓存命中，几乎同步完成）；探测不了
      // 内嵌封面（resolve 返回 null），留 null 走滤镜兜底整段一致。
      // ignore: discarded_futures
      _prepareBlurProbes(oldV, newV).then((_) {
        if (mounted && widget.version == newV) _startFlip();
      });
      return;
    }
    // 等新封面就绪再翻：等待期间只显示旧封面。
    _pendingVersion = newV;
    _readyTimer?.cancel();
    _readyTimer = Timer(widget.readyTimeout, _onReadyTimeout);
    probe(newV, _settledWidth, _dpr).then((ok) async {
      // 过期结果丢弃：等待途中又切了歌 / 被取消。
      if (!mounted || _pendingVersion != newV) return;
      _clearReadyTimer();
      debugPrint('[CoverFlip] 探测完成 uri=$newV ready=$ok');
      if (ok) {
        // 翻转启动前先做同键纹理预热（离屏画一次强制上传）：大图首次进
        // display list 的纹理上传实测 12~18ms GPU（mini→full 形变已量化，
        // 见 prewarmPlayerArtworkTexture），不预热则这笔开销落在翻转窗口
        // 内（最坏在 swap 点）。探测已同键命中解码缓存，这里的 resolve
        // 是缓存命中，开销很小。预热期间保持 _pendingVersion 不变：
        // 又切歌时由新一轮等待接管，这里按过期丢弃（与探测同款口径）。
        final status = await prewarmPlayerArtworkTexture(
          artworkUri: newV,
          settledLogicalWidth: _settledWidth,
          devicePixelRatio: _dpr,
        );
        debugPrint('[CoverFlip] 纹理预热 uri=$newV $status');
        if (!mounted || _pendingVersion != newV) return;
        // 快照也在启动**前**备齐（探测命中后 resolve 为同键缓存命中，
        // 同步补发，不引入额外帧延迟）：翻转第 0 帧起就是叠层形态，
        // 全程不出现「滤镜→叠层」中途替换跳变（真机反馈的观感问题）。
        final oldUri = _oldArtworkUri;
        await _prepareBlurProbes(oldUri, newV);
        if (!mounted || _pendingVersion != newV) return;
        _pendingVersion = null;
        _startFlip();
      } else {
        _pendingVersion = null;
        // 加载失败：翻转演不了（翻出占位白板等于动画消失），走交叉淡出兜底，
        // 让「旧封面退场」是连续过渡而不是瞬切（child 自行显示占位/错误态）。
        debugPrint('[CoverFlip] 探测失败，兜底交叉淡出 uri=$newV');
        _startFallbackFade();
      }
    });
  }

  void _startFlip() {
    if (!mounted) return;
    // 快照已由 _prepareBlurProbes 在启动前备齐，这里**不再清理**——
    // 第 0 帧起两层各自整段用同一种形态（叠层，或构建失败的整段滤镜）。
    // 先启动控制器再 setState：ticker 必须在本帧的 transient 回调前注册，
    // 否则首帧 tick 赶不上——setState 闭包里 forward() 会让动画「晚一帧才动」
    // （本帧只完成 build，tick 落到下一帧，测试与真机都表现为换图后停一拍）。
    _flip
      ..reset()
      ..forward();
    setState(() {});
  }

  void _onReadyTimeout() {
    _readyTimer = null;
    final pending = _pendingVersion;
    // 宽限截止时又没有待翻版本（已撤销 / 已被新一轮接管）：什么都不做。
    if (pending == null) return;
    debugPrint(
      '[CoverFlip] 就绪超时 ${widget.readyTimeout.inMilliseconds}ms，'
      '进入兜底宽限 uri=$pending',
    );
    // 不放弃翻转：弱网下新图常在 1~2s 才解码完，宽限期内到位照样演完整
    // 翻转（_pendingVersion 保持不动，探测回调仍然有效）。
    _readyTimer = Timer(widget.fallbackGrace, _onFallbackGraceExpired);
  }

  /// 兜底宽限也用尽：不再等，降级为交叉淡出（**不硬切**，见类文档）。
  void _onFallbackGraceExpired() {
    _readyTimer = null;
    final pending = _pendingVersion;
    if (pending == null) return;
    _pendingVersion = null;
    if (!mounted) return;
    debugPrint('[CoverFlip] 宽限用尽（共等待约 '
        '${widget.readyTimeout.inMilliseconds + widget.fallbackGrace.inMilliseconds}ms），'
        '兜底交叉淡出 uri=$pending');
    _startFallbackFade();
  }

  /// 兜底过渡：旧封面整层渐隐、新层在底下显形。
  ///
  /// 为什么不是「无模糊快速翻转」：新图此时仍没到位，翻过去只有占位白板，
  /// 观感等于动画消失；交叉淡出至少把「瞬切换图」摊成一段连续的亮度过渡。
  void _startFallbackFade() {
    if (!mounted) return;
    if (_oldArtworkUri == null) {
      // 没有可淡出的旧封面（首图 / 已被撤销）：直接换图，无可过渡之物。
      _dropOldLayer();
      return;
    }
    _dropBlurProbes();
    setState(() => _fallbackFading = true);
  }

  /// 收起旧层、回到 idle（只显示新 child）。带 setState。
  void _dropOldLayer() {
    final had = _oldArtworkUri != null || _fallbackFading;
    _oldArtworkUri = null;
    _oldArtworkWidget = null;
    _fallbackFading = false;
    _dropBlurProbes();
    if (had && mounted) setState(() {});
  }

  void _onFlipStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (!mounted) return;
    setState(() {
      _oldArtworkUri = null;
      _oldArtworkWidget = null;
      _dropBlurProbes();
    });
  }

  void _clearReadyTimer() {
    _readyTimer?.cancel();
    _readyTimer = null;
  }

  void _cancel() {
    _clearReadyTimer();
    _pendingVersion = null;
    _flip.stop();
    _dropOldLayer();
  }

  // ── 手势路径：入口（跟手 → 判定 → 提交 / 回弹 → 收尾） ─────────────────

  void _onSwipeStart(DragStartDetails _) {
    if (widget.onSwipeCommit == null || widget.version == null) return;
    // 自动过渡 / 就绪等待在飞时**直接接管**：真机上「动画窗口内就开滑」很常见，
    // 早先在这里 return 会让第一次滑动整段被吞（用户必须滑第二次）。
    // 接管 = 停掉自动过渡、撤掉就绪等待与旧层/快照，手势从正面重新开始。
    if (_flip.isAnimating) _flip.stop();
    _clearReadyTimer();
    _pendingVersion = null;
    _dropOldLayer();
    _motion.stop();
    _motion.value = 0;
    _swipePhase = _CoverFlipSwipePhase.dragging;
    _swipeDirection = 0;
    _swipeCanSwitch = false;
    _swipeStrength = CoverSwipeReboundStrength.gentle;
    _swipeOvershoot = 1.0;
    _swipeCommitVelocity = 0;
    _swipeProgress = 0;
    _dragX = 0;
    _swipeTargetWidget = null;
    _finishWhenSettled = false;
    _setFlipActive(true);
    _swipeWatch
      ..reset()
      ..start();
    _kinematics.reset(Duration.zero, 0);
    // 锁存「此刻屏幕上这张」为旧层；新层在前半程恒零宽，省略出树。
    _oldArtworkUri = widget.version;
    _oldArtworkWidget = PlayerArtworkImage(
      artworkUri: widget.version,
      fallbackFilePath: widget.fallbackFilePath,
      fit: BoxFit.cover,
      iconSize: widget.iconSize,
      backgroundColor: widget.placeholderColor,
      iconColor: widget.iconColor,
    );
    setState(() {});
  }

  void _onSwipeUpdate(DragUpdateDetails details) {
    if (_swipePhase != _CoverFlipSwipePhase.dragging) return;
    final dx = details.delta.dx;
    if (_swipeDirection == 0) {
      if (dx.abs() < 1.0) return;
      _swipeDirection = dx < 0 ? 1 : -1; // 左拖下一曲、右拖上一曲
      _swipeCanSwitch = _swipeDirection > 0
          ? widget.canGoNext
          : widget.canGoPrevious;
      // 卡背封面在这一刻构建：方向确定后才知该拿哪一首。
      _swipeTargetWidget = widget.swipeTargetBuilder?.call(_swipeDirection);
    }
    _dragX += dx;
    _kinematics.addSample(_swipeWatch.elapsed, _dragX);
    _swipeProgress = coverDragProgressForSwipe(
      progress: _swipeProgress,
      dx: dx,
      pitch: _swipePitch,
      direction: _swipeDirection,
      canSwitch: _swipeCanSwitch,
    );
    // 进度直接当时钟：p=0.5 是 90°（侧立），p=1 翻完 180°（卡背朝前）。
    // 越界信息留在 `_swipeProgress` 里供判定，画面只取 [0, 1]。
    _motion.value = _swipeProgress.clamp(0.0, 1.0).toDouble();
  }

  void _onSwipeEnd(DragEndDetails details) {
    if (_swipePhase != _CoverFlipSwipePhase.dragging) return;
    _swipeWatch.stop();
    final dir = _swipeDirection;
    if (dir == 0) {
      _startRebound(0);
      return;
    }
    final vx = -(details.primaryVelocity ?? _kinematics.velocity);
    final along = vx * dir;
    final accelAlong = -_kinematics.acceleration * dir;
    final progress = _swipeProgress;
    _swipeStrength = coverSwipeReboundStrength(
      velocity: along,
      acceleration: accelAlong,
    );
    _swipeOvershoot = coverSwipeOvershoot(_swipeStrength);
    _swipeCommitVelocity = along;
    final commit = coverSwipeShouldCommit(
      progress: progress,
      velocity: along,
      acceleration: accelAlong,
      canSwitch: _swipeCanSwitch,
    );
    if (commit) {
      _awaitCommit(dir);
    } else {
      // 到头了（无邻居侧）也上报一次提交意图：让按钮路径的「已经是最后一首了」
      // Toast 被滑动触发；画面仍按 _startRebound 回弹，不走 _awaitCommit。
      // 不设进度/速度阈值：_onSwipeEnd 触发即已越过 touch slop，是一次有效翻面；
      // 旧判据（progress>=0.08 或 speed>900）把轻滑全吞掉。
      if (!_swipeCanSwitch) {
        widget.onSwipeCommit?.call(
          dir > 0 ? CoverSwitchIntent.next : CoverSwitchIntent.previous,
        );
      }
      _startRebound(along);
    }
  }

  void _onSwipeCancel() {
    if (_swipePhase != _CoverFlipSwipePhase.dragging) return;
    _swipeWatch.stop();
    _startRebound(0);
  }

  void _clearCommitGuard() {
    _commitGuard?.cancel();
    _commitGuard = null;
  }

  /// 写外部阴影通道（翻转中 = 页面把投影淡出）。
  ///
  /// **不能无条件直接写**：`didUpdateWidget`（build 阶段）与收尾路径都可能
  /// 落在 build 里，此时通知订阅者会触发「markNeedsBuild called during
  /// build」——页面把阴影包在 `ValueListenableBuilder` 里（页面级测试实测）。
  /// build/layout/paint 阶段一律排到帧后，并用 `mounted` 防页面已退出。
  void _setFlipActive(bool active) {
    final notifier = widget.flipActive;
    if (notifier == null || notifier.value == active) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted && notifier.value != active) notifier.value = active;
      });
      return;
    }
    notifier.value = active;
  }

  /// 提交：通知页面切歌，同时沿同一时钟把卡背翻到正面（t → 1）。
  ///
  /// 不再「停在 90° 等 version」：卡背已有目标邻居封面，先翻完再等换歌，
  /// 观感不会出现「翻到一半停住、卡背空白」的空窗；version 到位后只清场。
  void _awaitCommit(int dir) {
    _clearCommitGuard();
    widget.onSwipeCommit!(
      dir > 0 ? CoverSwitchIntent.next : CoverSwitchIntent.previous,
    );
    _beginCompleting();
    _commitGuard = Timer(kCoverSwipeCommitGuard, () {
      if (_swipePhase == _CoverFlipSwipePhase.completing) {
        _startRebound(0); // provider 没换歌：把翻过去的画面翻回来
      }
    });
  }

  void _beginCompleting() {
    _clearCommitGuard();
    _swipePhase = _CoverFlipSwipePhase.completing;
    _motion.animateWith(
      SpringSimulation(
        coverSwipeCommitSpring(_swipeStrength),
        _motion.value,
        1.0,
        coverSwipeVelocityInClock(_swipeCommitVelocity, _swipePitch),
        tolerance: const Tolerance(distance: 0.0005, velocity: 0.0005),
      ),
    );
  }

  void _startRebound(double velocityAlong) {
    _clearCommitGuard();
    _swipePhase = _CoverFlipSwipePhase.rebounding;
    _motion.animateWith(
      SpringSimulation(
        coverSwipeReboundSpring(_swipeStrength),
        _motion.value,
        0.0,
        coverSwipeVelocityInClock(velocityAlong, _swipePitch),
        tolerance: const Tolerance(distance: 0.0005, velocity: 0.0005),
      ),
    );
  }

  void _onMotionStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    if (_swipePhase == _CoverFlipSwipePhase.rebounding) {
      // 回弹收敛：画面已回正，直接收尾。
      setState(_finishSwipe);
      return;
    }
    if (_swipePhase != _CoverFlipSwipePhase.completing) return;
    // completing 收敛：换歌已到就清场；没到则停在卡背，等 version 或守卫回弹。
    if (_finishWhenSettled) setState(_finishSwipe);
  }

  void _finishSwipe() {
    _clearCommitGuard();
    _swipePhase = _CoverFlipSwipePhase.idle;
    _swipeDirection = 0;
    _swipeOvershoot = 1.0;
    _swipeCommitVelocity = 0;
    _swipeProgress = 0;
    _motion.value = 0;
    _oldArtworkUri = null;
    _oldArtworkWidget = null;
    _swipeTargetWidget = null;
    _finishWhenSettled = false;
    _setFlipActive(false);
    // 不碰 _flip / _pendingVersion / 快照：自动过渡路径保持原状。
  }

  void _cancelSwipe() {
    _clearCommitGuard();
    _swipeWatch.stop();
    _motion.stop();
    _motion.value = 0;
    _swipePhase = _CoverFlipSwipePhase.idle;
    _swipeDirection = 0;
    _swipeProgress = 0;
    _oldArtworkUri = null;
    _oldArtworkWidget = null;
    _swipeTargetWidget = null;
    _finishWhenSettled = false;
    _setFlipActive(false);
  }

  @override
  void dispose() {
    _clearReadyTimer();
    _clearCommitGuard();
    _swipeWatch.stop();
    // 退出播放页时手势可能在飞：把外部阴影通道复位，避免下次换布局后阴影
    // 一直停在「翻转中」的透明态（子 State 先于页面 State dispose，安全）。
    if (_swipeActive) _setFlipActive(false);
    _dropBlurProbes();
    _flip
      ..removeStatusListener(_onFlipStatus)
      ..dispose();
    _motion
      ..removeStatusListener(_onMotionStatus)
      ..dispose();
    super.dispose();
  }

  Widget _oldArtwork() => _oldArtworkWidget!;

  /// 每层内容的 RepaintBoundary 包装（新旧两层共用）。
  ///
  /// 翻转期间每帧只有外层 Transform/ClipRRect 与模糊叠层重录；
  /// boundary 内的封面 picture（含 DepthCoverHost、动态封面视频层）
  /// 已栅格化的部分被直接引用，markNeedsPaint 不再沿祖先链上溯把
  /// 播放页其余部分（背景、歌词）连坐重绘。结构与 player_cover_morph_layer
  /// 的 _artworkFor 同款：boundary 只圈内容本体，逐帧变化的模糊与
  /// 旋转变换留在边界之外。
  Widget _artworkWithBoundary(Widget child) => RepaintBoundary(child: child);

  @override
  Widget build(BuildContext context) {
    // 量一次布局：就绪探测要用与渲染同键的解码档位（逻辑宽 × dpr → 档位），
    // 模糊快照要按封面盒的宽高比 cover-crop。手势路径用 maxWidth 算拖动页距。
    final body = LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth.isFinite && constraints.maxWidth > 0) {
          _settledWidth = constraints.maxWidth;
        }
        if (constraints.maxHeight.isFinite && constraints.maxHeight > 0) {
          _settledHeight = constraints.maxHeight;
        }
        _dpr = MediaQuery.devicePixelRatioOf(context);
        return _buildBody();
      },
    );
    if (!widget.swipeEnabled) return body;
    // 手势挂在最外层：与祖先 onTap / onVerticalDrag* / PageView 的横向识别器
    // 同时入竞技场，内层先认领（与 CoverSwitchPager 接线一致）。横滑会顺带
    // 取消 tap 与 Zen 长按；Windows 右键走 onSecondaryTap，不进主键识别器。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: _onSwipeStart,
      onHorizontalDragUpdate: _onSwipeUpdate,
      onHorizontalDragEnd: _onSwipeEnd,
      onHorizontalDragCancel: _onSwipeCancel,
      child: body,
    );
  }

  /// 一层的模糊包装：优先「清晰内容 + 低分辨率快照 α 叠层」，
  /// 快照不可用（源解析不了 / 内嵌封面 / 构建失败）退回阶梯滤镜——
  /// 形态在**启动前**定死，整段过渡只用一种（见类文档「逐帧 sigma」条）。
  ///
  /// α = [coverFlipBlurAlpha](sigma(t))（√ 曲线）：清晰与全模糊的交叉淡
  /// 近似「逐渐变糊 / 逐渐变清」的拉焦观感，动画期间零逐帧卷积（快照只在
  /// 构建时卷积一次）；√ 而非线性，避免清晰残影拖满全程（见类文档）。
  /// 叠层走 [LowResBlurPainter] 的 `colorAlpha`，不用 Opacity 合成层。
  Widget _blurLayer({
    required Widget content,
    required double sigma,
    required ui.Image? proxy,
  }) {
    if (proxy == null) {
      final quantized = coverFlipQuantizeSigma(sigma);
      return quantized > 0
          ? ImageFiltered(
              imageFilter: ImageFilter.blur(
                sigmaX: quantized,
                sigmaY: quantized,
                // clamp 防 Impeller decal 边缘暗晕
                tileMode: TileMode.clamp,
              ),
              child: _artworkWithBoundary(content),
            )
          : _artworkWithBoundary(content);
    }
    final alpha = coverFlipBlurAlpha(sigma);
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        _artworkWithBoundary(content),
        if (alpha > 0.01)
          Positioned.fill(
            child: CustomPaint(painter: LowResBlurPainter(proxy, alpha)),
          ),
      ],
    );
  }

  /// 兜底过渡：旧封面整层渐隐，[widget.child] 在下层直接显形。
  ///
  /// 用 [TweenAnimationBuilder] 而不是再开一个 `AnimationController`：这段
  /// 过渡一次性且无状态（进入即 1 → 0，结束就把旧层摘掉），完成时分支离开
  /// 树、状态自然回收；自建控制器还要额外处理「build 阶段把值归零会踩
  /// markNeedsBuild during build」（本类 `_setFlipActive` 就为此刻意排到帧后）。
  ///
  /// 旧层压在上层——它才是「用户此刻认为在听的那首」；新层（占位 / 正在解码
  /// 的图）在底下渐显，合起来就是一次干净的两层交叉淡出。
  Widget _buildFallbackFade(BorderRadius radius, Widget oldArtwork) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(borderRadius: radius, child: widget.child),
        Positioned.fill(
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 1, end: 0),
            duration: widget.fallbackFadeDuration,
            curve: Curves.easeOutCubic,
            onEnd: _onFallbackFadeEnd,
            builder: (context, opacity, child) =>
                Opacity(opacity: opacity, child: child),
            child: ClipRRect(
              borderRadius: radius,
              child: RepaintBoundary(child: oldArtwork),
            ),
          ),
        ),
      ],
    );
  }

  void _onFallbackFadeEnd() {
    if (!mounted) return;
    // 淡出收敛：旧层摘掉，树回到单层（与翻转完成同一收尾口径）。
    _dropOldLayer();
  }

  Widget _buildBody() {
    // 手势路径（dragging/awaitingCommit/completing/rebounding）与自动过渡由
    // 相位互斥：swipe 为真时只认 _motion，_flip 的值一概不读。
    final swipe = _swipeActive;
    final oldUri = _oldArtworkUri;
    final radius = BorderRadius.circular(widget.radius);
    // 空闲（含等待被撤销 / 底层为空）：只有新封面一层。
    if (oldUri == null && !swipe) {
      return ClipRRect(borderRadius: radius, child: widget.child);
    }
    // 手势与自动过渡都不在飞（就绪等待中 / 兜底淡出中）：只认旧层。
    if (!swipe && !_flip.isAnimating) {
      // 兜底：旧封面整层渐隐，widget.child 在底下直接显形（交叉淡出）。
      if (_fallbackFading) {
        return _buildFallbackFade(radius, _oldArtwork());
      }
      // 就绪等待中：旧封面原地不动（新图到位再翻）。
      return ClipRRect(borderRadius: radius, child: _oldArtwork());
    }
    return AnimatedBuilder(
      // 两条时钟都挂上：手势相位下 _flip 静止、自动过渡相位下 _motion 静止，
      // 谁在动就谁触发重建（另一个静止时不产帧）。
      animation: Listenable.merge([_flip, _motion]),
      builder: (context, _) {
        // 手势路径允许 t 短暂越界：回弹负向过冲（角度反向轻翻）与提交
        // 末段过冲都靠它。下限取「页」上限换算回时钟（单一来源，避免把
        // 0.12 页误当 0.12 t 用）；上限 1 = 后半程走完。
        final double t = swipe
            ? _motion.value
                  .clamp(-kCoverSwipeMaxOvershootPages * kCoverFlipSwap, 1.0)
                  .toDouble()
            : _flip.value;
        // 手势路径的方向由起手方向锁定（+1 下一曲 / -1 上一曲）。
        final direction = swipe ? _swipeDirection : widget.direction;
        final oldAngle = swipe
            ? coverSwipeOldAngle(t)
            : coverFlipOldAngle(t);
        final newAngle = swipe
            ? coverFlipNewAngle(t, overshoot: _swipeOvershoot)
            : coverFlipNewAngle(t);
        // 手势路径全程零模糊：不挂 ImageFiltered、不构建低分辨率快照。
        final oldSigma = swipe ? 0.0 : coverFlipOldBlur(t);
        final newSigma = swipe ? 0.0 : coverFlipNewBlur(t);
        // 快照必须归属当前层的 URI 才可用（连切歌时防错图鬼影，见字段注释）。
        final oldProxy = swipe
            ? null
            : (_oldBlurProxy != null && _oldBlurProxyUri == oldUri)
                  ? _oldBlurProxy
                  : null;
        final newProxy = swipe
            ? null
            : (_newBlurProxy != null && _newBlurProxyUri == widget.version)
                  ? _newBlurProxy
                  : null;
        return Stack(
          // 不裁到布局盒：旋转中的封面（透视近端放大）要能探出静止边界，
          // 否则上下边缘被裁（本类的存在理由之一）。
          clipBehavior: Clip.none,
          fit: StackFit.expand,
          children: [
            // 旧封面：模糊加剧 + 绕纵轴翻倒。到 90° 那一刻投影宽度归零，
            // 即刻退场——不留在树上白烧一层模糊。
            if (t < kCoverFlipSwap)
              Positioned.fill(
                // 先裁圆角再旋转：整张圆角卡片作为刚体翻，探出边界也不被裁。
                child: Transform(
                  alignment: Alignment.center,
                  transform: coverFlipMatrix(angle: oldAngle * direction),
                  child: ClipRRect(
                    borderRadius: radius,
                    child: _blurLayer(
                      content: _oldArtwork(),
                      sigma: oldSigma,
                      proxy: oldProxy,
                    ),
                  ),
                ),
              ),
            // 新封面：全程在场，前半程侧立在 90°（零宽不可见），
            // 后半程翻入并逐渐清晰。手势路径前半程新层恒零宽 → 直接
            // 不放进树，省一层栅格（与自动过渡的「留在树里」不同）。
            if (!swipe || t >= kCoverFlipSwap)
              Positioned.fill(
                child: Transform(
                  alignment: Alignment.center,
                  transform: coverFlipMatrix(angle: newAngle * direction),
                  child: ClipRRect(
                    borderRadius: radius,
                    child: _blurLayer(
                      // 手势路径用锁存的目标邻居封面：发起切歌到新 version
                      // 到位之间 child 仍是当前歌，直接用它翻过去会看到同一张。
                      content: swipe
                          ? (_swipeTargetWidget ?? widget.child)
                          : widget.child,
                      sigma: newSigma,
                      proxy: newProxy,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
