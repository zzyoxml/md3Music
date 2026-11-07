import 'dart:async';

import 'dart:ui' show ImageFilter, TileMode;
import 'dart:ui' as ui show Image;

import 'package:material_ui/material_ui.dart';

import '../cover_flip_physics.dart';
import '../../../widgets/player_artwork_image.dart'
    show
        PlayerArtworkImage,
        prewarmPlayerArtworkTexture,
        resolvePlayerArtworkImage;
import 'low_res_blur.dart';

/// 就绪等待上限：超过则放弃翻转、直接换图（有界，不无限压旧封面）。
///
/// 参考视频里「封面迟到补齐」那次翻转约等了 1s；取同量级。等待期间旧封面
/// 一直在位（与视频「封面到位才翻」一致），超时只是兜底，不是常态。
const Duration kCoverFlipReadyTimeout = Duration(milliseconds: 1000);

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
///   （与视频「封面后到、到位才翻」一致），[readyTimeout] 内仍未就绪则放弃
///   动画直接换图。不传 probe 时退化为「version 变化即翻」。
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

  @override
  State<CoverFlipCrossfade> createState() => _CoverFlipCrossfadeState();
}

class _CoverFlipCrossfadeState extends State<CoverFlipCrossfade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flip = AnimationController(
    vsync: this,
    duration: widget.duration,
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

  /// 最近一次布局测得的封面逻辑宽 / dpr（就绪探测算同键解码档位用）。
  /// build 内只写不读 notify，与 _photoScheduledHash 同型约束。
  double _settledWidth = 0;
  double _dpr = 1;

  /// 快照构建的代次号（快速连切时旧回调按它作废自己，见 _prepareBlurProbes）。
  int _prepareSeq = 0;

  @override
  void initState() {
    super.initState();
    _flip.addStatusListener(_onFlipStatus);
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
      _cancel();
      return;
    }
    final oldV = oldWidget.version;
    final newV = widget.version;
    // 版本未变的重建（isPlaying 变化、歌词到达、设置读取……播放页的异步
    // setState 都会走到这儿）：**不能打断任何在飞的东西**——取消在飞的翻转
    // 或就绪等待，表现为「切歌后没有旋转动画」（真机复现：歌词 setState
    // 落在过渡窗口内，翻转被掐）。
    if (oldV == newV) return;
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
        // 加载失败：不演过渡，直接换图（child 自行显示占位/错误态）。
        _dropOldLayer();
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
    if (_pendingVersion == null) return;
    final timedOut = _pendingVersion;
    _pendingVersion = null;
    if (!mounted) return;
    debugPrint('[CoverFlip] 探测超时 uri=$timedOut');
    // 超过 readyTimeout 仍未就绪：放弃动画直接换图，不无限压旧封面。
    _dropOldLayer();
  }

  /// 收起旧层、回到 idle（只显示新 child）。带 setState。
  void _dropOldLayer() {
    final had = _oldArtworkUri != null;
    _oldArtworkUri = null;
    _oldArtworkWidget = null;
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

  @override
  void dispose() {
    _clearReadyTimer();
    _dropBlurProbes();
    _flip
      ..removeStatusListener(_onFlipStatus)
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
    // 模糊快照要按封面盒的宽高比 cover-crop。
    return LayoutBuilder(
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

  Widget _buildBody() {
    final oldUri = _oldArtworkUri;
    final radius = BorderRadius.circular(widget.radius);
    // 空闲（含就绪等待被取消/超时/失败）：只有新封面一层。
    if (oldUri == null) {
      return ClipRRect(borderRadius: radius, child: widget.child);
    }
    // 就绪等待中：只显示旧封面（新图到位再翻，不到位就超时直换）。
    if (!_flip.isAnimating) {
      return ClipRRect(borderRadius: radius, child: _oldArtwork());
    }
    return AnimatedBuilder(
      animation: _flip,
      builder: (context, _) {
        final t = _flip.value;
        final oldSigma = coverFlipOldBlur(t);
        final newSigma = coverFlipNewBlur(t);
        // 快照必须归属当前层的 URI 才可用（连切歌时防错图鬼影，见字段注释）。
        final oldProxy =
            (_oldBlurProxy != null && _oldBlurProxyUri == oldUri)
            ? _oldBlurProxy
            : null;
        final newProxy =
            (_newBlurProxy != null && _newBlurProxyUri == widget.version)
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
                  transform: coverFlipMatrix(
                    angle: coverFlipOldAngle(t) * widget.direction,
                  ),
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
            // 后半程翻入并逐渐清晰。
            Positioned.fill(
              child: Transform(
                alignment: Alignment.center,
                transform: coverFlipMatrix(
                  angle: coverFlipNewAngle(t) * widget.direction,
                ),
                child: ClipRRect(
                  borderRadius: radius,
                  child: _blurLayer(
                    content: widget.child,
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
