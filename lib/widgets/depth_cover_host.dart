import 'dart:async';

import 'package:flutter/material.dart';

import '../core/platform_capabilities.dart';
import '../core/services/depth_cover_feature.dart';
import '../core/services/depth_cover_cache.dart';
import '../data/repositories/settings_repository.dart';
import '../services/depth_cover_service.dart';
import 'depth_parallax_cover.dart';
import 'depth_shader_cover.dart';
import 'depth_tilt_source.dart';
import 'player_artwork_image.dart';

/// 3D 深度封面宿主：挂载在播放页"新封面"淡入位置（保留外层淡入 [Opacity]）。
///
/// MD3 风格（full_player）与 AM 风格（full_player_am）两个播放页共用本组件：
/// - 开关关闭或生成未完成时回退为平面 [PlayerArtworkImage]（保留原 fallback/
///   background/icon 语义与淡入效果）。
/// - 命中缓存即时显示 3D；未命中挂缓存监听，等原生生成完成后切换。
/// - 触发加固：生命周期 resume 重试 + 模型就绪监听 + 有界重试（冷启动/
///   模型未就绪/网络抖动都不会永久卡在平面封面）。
/// - 动态封面（cover.mp4）优先级更高时由调用方自行短路；本组件只负责静态封面。
class DepthCoverHost extends StatefulWidget {
  const DepthCoverHost({
    super.key,
    required this.artworkUri,
    this.fallbackFilePath,
    required this.fit,
    required this.iconSize,
    required this.backgroundColor,
    required this.iconColor,
  });

  final String? artworkUri;
  final String? fallbackFilePath;
  final BoxFit fit;
  final double iconSize;
  final Color backgroundColor;
  final Color iconColor;

  @override
  State<DepthCoverHost> createState() => _DepthCoverHostState();
}

class _DepthCoverHostState extends State<DepthCoverHost>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  /// 未拿到分层前的最大重试次数（冷启动/模型未就绪/网络抖动都会走重试）。
  static const int _maxAttempts = 4;
  /// 连续失败轮数上限：每轮消耗 [_maxAttempts] 次。达到上限即停止自动重试
  /// （避免根因不可自愈时——如模型提取失败——每 3 秒无限重试耗电、刷日志）。
  /// 用户重新操作开关（enabledSignal 变化）会重置。
  static const int _maxFailedCycles = 5;
  static const Duration _retryDelay = Duration(seconds: 3);

  /// shader（逐像素位移）路径开关：位移单位 bug（uv 与像素混用，49a0738）与
  /// DPR bug（6057b1b）均已修复，待真机复验；确认真机渲染正常后保持 true。
  ///
  /// **Android / TV 专用**：Windows 走多层视差，见 [_useShaderPath] 的平台门控。
  static const bool _preferShader = true;

  /// 进程级 shader 支持标记：某设备一旦编译失败，本进程内其余封面直接走多层视差，
  /// 不再逐个重试（避免每次进播放页都失败一次）。
  static bool _shaderUnsupported = false;
  /// 进程级提示去重：降级/传感器缺失各只提示一次。
  static bool _shaderToastShown = false;
  static bool _tiltToastShown = false;
  /// 本设备 shader 是否已失败（实例视图，用于选择渲染路径）。
  bool _shaderFailed = false;

  List<String>? _layers;
  /// 多层路径的修补底板（`bg_fill.png`，主体已填补）：垫在三层之下，前景移开处
  /// 才能露出修补后的背景。缺失（旧缓存 / Android）为 null —— 渲染与旧版一致。
  String? _layerBackground;
  /// shader 路径命中：{'depth','depthStd','cover'}；非空即优先渲染逐像素位移封面。
  Map<String, Object?>? _depthInfo;
  /// 倾斜源控制器：Windows = 鼠标指针（仅封面矩形内），Android/TV = 重力传感器。
  /// 创建一次复用，避免 build 每次重建流；输出类型与原传感器流同型，
  /// 故 DepthShaderCover / DepthParallaxCover 零改动。
  DepthTiltController? _tilt;
  bool _depthEnabled = false;
  double _strength = 9.0;
  VoidCallback? _cancel;
  bool _requesting = false;
  int _attempts = 0;
  int _failedCycles = 0;

  /// 上一次已上报的 3D 活动态（null = 还没上报过），避免每次 build 都回调。
  /// 首次从平面封面切换到 3D 时的中心扩散圆环过渡（一次性）。
  AnimationController? _ringCtrl;
  bool _ringVisible = false;

  /// 诊断面包屑：`[DepthCover] +Nms` 相对时间，出问题时能一眼看出卡在哪个阶段
  /// （`FrameTiming` 看不到事件循环阻塞，见 windows-desktop.md W5.8）。
  static final Stopwatch _clock = Stopwatch()..start();
  static int get _ms => _clock.elapsedMilliseconds;

  /// 是否走 shader 逐像素路径（设备 shader 不受支持时降级为多层视差）。
  ///
  /// **Windows 桌面端强制走多层视差（[DepthParallaxCover]）**，不使用 runtime
  /// fragment shader —— 这是「打开 3D 封面后整窗无响应」的修复点：
  ///
  /// - `shaders/depth_parallax.frag` 每像素做 `kLayers = 16` 次深度纹理采样 + 分支/
  ///   混合；鼠标移动时满帧重绘，在 Impeller-on-Windows 上会把 UI/光栅线程压死。
  /// - 更关键的是**它以前从未在 Windows 上跑过**：改动前 Windows 构建不传
  ///   `ENABLE_DEPTH_3D`，`kDepthCoverAvailable` 恒 false、本组件 initState 直接
  ///   return，整条渲染路径在桌面端是死代码，直到本次适配才第一次真跑。
  /// - 仓内已有同款先例：`docs/agents/windows-desktop.md` W5.7 —— m3e 的
  ///   `InkSparkle` 也是 runtime fragment shader，「首次按下要等着色器编译/管线创建，
  ///   表现就是点一下暂停整窗卡一下」，桌面端已回退 `InkRipple`
  ///   （`now_playing_bar.dart`）。连一个简单的 sparkle shader 都要退，这个 16 采样
  ///   的 shader 更没有理由在桌面端留下。
  /// - 降级判据只有「抛异常」，**渲染极慢不触发任何降级**（[_onShaderFailed] 只在
  ///   加载失败时调用），所以桌面端只能靠这道平台门控兜住。
  ///
  /// 逐像素质量若要在 Windows 恢复，需要单独做一次 shader 预热基准
  /// （启动期离屏编译 + 帧时实测）通过后再切回，不随本修复打开。
  bool get _useShaderPath =>
      _preferShader &&
      !isWindowsDesktop &&
      !_shaderFailed &&
      !_shaderUnsupported;

  /// shader 编译/加载失败：降级多层视差 + 原生 toast 提示（每次进程一次）。
  void _onShaderFailed() {
    _shaderUnsupported = true;
    if (!mounted) return;
    debugPrint('[DepthCover] 设备不支持该 shader，降级多层视差');
    setState(() {
      _shaderFailed = true;
      _depthInfo = null;
    });
    if (!_shaderToastShown) {
      _shaderToastShown = true;
      unawaited(
        DepthCoverService.instance.showNativeToast(
          '当前设备不支持 3D 封面渲染，已降级为分层视差',
        ),
      );
    }
    _attempts = 0;
    _request(); // 改走多层路径（层缓存未命中则触发生成）
  }

  /// 倾斜传感器不可用（无加速计 / 被系统限制）：提示一次，其余按静态封面处理。
  void _onTiltError(Object error) {
    if (_tiltToastShown) return;
    _tiltToastShown = true;
    unawaited(
      DepthCoverService.instance.showNativeToast(
        '当前设备无重力传感器，3D 封面无法跟随倾斜',
      ),
    );
  }

  /// 由 null→非 null 的状态跃迁时调用：启动圆环过渡。
  void _revealWithRing() {
    if (!mounted) return;
    _ringCtrl ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed && mounted) {
          setState(() => _ringVisible = false);
        }
      });
    setState(() => _ringVisible = true);
    _ringCtrl!.forward(from: 0);
  }

  @override
  void initState() {
    super.initState();
    if (!kDepthCoverAvailable) return; // standard 包：整体不启用
    WidgetsBinding.instance.addObserver(this);
    // 开关状态信号（设置页/播放页界面设置弹层）变化 → 重走初始化，即时生效。
    DepthCoverService.enabledSignal.addListener(_onEnabledSignal);
    _tilt = DepthTiltController(onTiltError: _onTiltError);
    _init();
  }

  void _onEnabledSignal() {
    if (!mounted) return;
    debugPrint('[DepthCover] 开关信号变化 → 重走初始化');
    _cancel?.call();
    _cancel = null;
    _attempts = 0;
    _failedCycles = 0;
    if (mounted) {
      setState(() {
        _layers = null;
        _layerBackground = null;
        _depthInfo = null;
      });
    }
    _init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 冷启动/从后台回来时封面可能还没生成（或上一轮失败），回到前台补一次。
    if (state != AppLifecycleState.resumed) return;
    if (!_depthEnabled || _layers != null || _requesting) return;
    if (_failedCycles >= _maxFailedCycles) return; // 已达上限：不再自动重试
    debugPrint('[DepthCover] 回到前台，补一次生成');
    _attempts = 0;
    _request();
  }

  Future<void> _init() async {
    final enabled =
        kDepthCoverAvailable && await SettingsRepository().getDepthCoverEnabled();
    final strength = await SettingsRepository().getDepthCoverStrength();
    debugPrint('[DepthCover] +${_ms}ms host init: enabled=$enabled '
        'shaderPath=$_useShaderPath uri=${widget.artworkUri}');
    if (!mounted) return;
    setState(() {
      _depthEnabled = enabled;
      _strength = strength;
    });
    if (!enabled) return; // 关闭开关：始终平面封面
    _attempts = 0;
    _request();
  }

  @override
  void didUpdateWidget(covariant DepthCoverHost old) {
    super.didUpdateWidget(old);
    if (old.artworkUri != widget.artworkUri) {
      _cancel?.call();
      _cancel = null;
      if (mounted) {
        setState(() {
          _layers = null;
          _depthInfo = null;
        });
      }
      _init(); // 切歌：重新走缓存/生成流程
    }
  }

  Future<void> _request() async {
    if (_requesting || !mounted) return;
    final service = DepthCoverService.instance;
    final uri = widget.artworkUri;
    if (uri == null || uri.isEmpty) return;
    final key = DepthCoverCache.cacheKey(uri);
    if (_useShaderPath) {
      // 优先 shader 深度图命中；其次多层命中；都未命中再发起生成。
      final depth = await service.cache.getCachedDepth(key);
      debugPrint('[DepthCover] host depth hit=${depth != null} key=$key');
      if (!mounted) return;
      if (depth != null) {
        setState(() => _depthInfo = depth);
        _revealWithRing();
        return;
      }
    }
    final cached = await service.cache.getCachedLayers(key);
    debugPrint('[DepthCover] host layers hit=${cached != null} key=$key');
    if (!mounted) return;
    if (cached != null) {
      final plate = await service.cache.getLayerBackground(key);
      if (!mounted) return;
      setState(() {
        _layers = cached;
        _layerBackground = plate;
      });
      _revealWithRing();
      return;
    }
    _cancel ??= service.cache.addListener(key, _onReady);
    _requesting = true;
    final sw = Stopwatch()..start();
    debugPrint('[DepthCover] +${_ms}ms 发起生成 → ${_useShaderPath ? "shader(深度图)" : "layers(三层)"}');
    var ok = false;
    try {
      ok = _useShaderPath
          ? await service.requestDepth(uri)
          : await service.request(uri); // 多层切割路径（原稳定行为）
    } catch (e, s) {
      // 后端任何异常都不许冒泡成未处理异步异常（那会刷错误日志、并让
      // `_requesting` 停在 true 使后续重试全被早退挡住）。按失败处理即可。
      debugPrint('[DepthCover] 生成请求异常: $e ${s.toString().split('\n').take(2).join(' << ')}');
    } finally {
      _requesting = false;
    }
    _attempts++;
    debugPrint(
        '[DepthCover] +${_ms}ms host ${_useShaderPath ? "depth " : "layers "}request → $ok '
        '(${sw.elapsedMilliseconds}ms, attempt $_attempts/$_maxAttempts)');
    if (ok || !mounted || _depthInfo != null || _layers != null) return;
    if (_attempts < _maxAttempts) {
      await Future<void>.delayed(_retryDelay);
      if (mounted && _depthInfo == null && _layers == null) _request();
    } else {
      _failedCycles++;
      if (_failedCycles >= _maxFailedCycles) {
        debugPrint('[DepthCover] 连续失败 $_failedCycles 轮，停止自动重试');
      }
    }
  }

  /// 生成完成回调：探测缓存并切到对应的渲染路径。
  ///
  /// **两条分支必须各管各的**（2026-10-28 修）：Windows 走多层（`_useShaderPath`
  /// false）时不得再去认深度缓存 —— 旧版本在 Windows 上生成过 `depth.png`
  /// 却没有 `layer*.png`，若这里先命中 `_depthInfo` 就会把 layers 分支的
  /// `_depthInfo == null` 守卫永久堵死，表现为「3D 开关打开但永远是平面封面」。
  void _onReady() {
    final key = DepthCoverCache.cacheKey(widget.artworkUri ?? '');
    if (_useShaderPath) {
      DepthCoverService.instance.cache.getCachedDepth(key).then((d) {
        if (mounted && d != null && _depthInfo == null && _layers == null) {
          setState(() => _depthInfo = d);
          _revealWithRing();
        }
      });
    }
    DepthCoverService.instance.cache.getCachedLayers(key).then((ls) {
      // 多层路径下只看 layers；shader 路径下仍保持「深度优先」的旧语义。
      final blocked = _useShaderPath ? _depthInfo != null : false;
      if (mounted && ls != null && !blocked && _layers == null) {
        // 底板与 layers 同批取：它是「主体已被填补的背景」，缺了就看到错位重影。
        DepthCoverService.instance.cache.getLayerBackground(key).then((plate) {
          if (!mounted) return;
          setState(() => _layerBackground = plate);
        });
        setState(() => _layers = ls);
        _revealWithRing();
      }
    });
  }

  /// 倾斜源已由 [DepthTiltController] 接管（Windows = 鼠标指针；Android/TV = 重力
  /// 传感器）。此处不再直接持有传感器流：sensors_plus 无 Windows 实现，在桌面端
  /// 创建它会 MissingPluginException 并误报「无重力传感器」。

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    DepthCoverService.enabledSignal.removeListener(_onEnabledSignal);
    _cancel?.call();
    _tilt?.dispose();
    _tilt = null;
    _layerBackground = null;
    _depthInfo = null;
    _ringCtrl?.dispose();
    super.dispose();
  }

  /// 用当前内容（shader/多层/平面）与可选的圆环过渡叠层构建封面。
  Widget _buildCover() {
    Widget cover;
    if (_useShaderPath && _depthInfo != null) {
      debugPrint('[DepthCover] +${_ms}ms 挂载 DepthShaderCover（runtime shader）');
      cover = DepthShaderCover(
        coverPath: _depthInfo!['cover'] as String,
        depthPath: _depthInfo!['depth'] as String,
        depthStd: _depthInfo!['depthStd'] as double,
        bgFillPath: _depthInfo!['bgFill'] as String?,
        tiltStream: _tilt!.stream,
        strengthPx: _strength,
        onFailed: _onShaderFailed,
        onTiltError: _onTiltError,
      );
    } else if (_layers != null) {
      debugPrint('[DepthCover] +${_ms}ms 挂载 DepthParallaxCover（三层视差，无 runtime shader）');
      // 回退：多层切割视差。
      cover = DepthParallaxCover(
        layerPaths: _layers!,
        backgroundPath: _layerBackground,
        strength: _strength,
        tiltStream: _tilt!.stream,
        onTiltError: _onTiltError,
      );
    } else {
      cover = PlayerArtworkImage(
        artworkUri: widget.artworkUri,
        fallbackFilePath: widget.fallbackFilePath,
        fit: widget.fit,
        iconSize: widget.iconSize,
        backgroundColor: widget.backgroundColor,
        iconColor: widget.iconColor,
      );
    }
    // 鼠标跟随：只在 Windows 桌面且确实走了 3D 渲染路径时包 MouseRegion。
    // - behavior 用 translucent：既收 onHover，又不吞掉既有的点击/长按手势
    //   （播放页封面有「长按 2s 进 Zen」「单击 peek」等手势，不能挡）。
    // - 尺寸即封面矩形（外层 Positioned.fill / Opacity 已给满），因此 local
    //   坐标天然就是「封面矩形内坐标」，符合 DepthTiltController 的契约。
    //
    // **不要用 LayoutBuilder 取尺寸**（2026-10-28 实测踩坑）：播放页会同时挂
    // 前后两张封面做淡入淡出、封面形变层还会离屏取用封面子树，此时 LayoutBuilder
    // 会出现「没有 layout 就被 paint」——日志是每帧刷
    // `RenderBox was not laid out: _RenderLayoutBuilder ... NEEDS-PAINT`，
    // 框架反复重试导致整窗卡死。改为在 hover 回调里用本 State 自己的
    // `context.findRenderObject()` 读当前尺寸：它就是这个封面槽位的盒子，
    // 布局已完成（回调都在 layout 之后），零额外 RenderObject、无布局依赖。
    if (_tilt != null && _tilt!.usesPointerSource && _hasDepthContent) {
      cover = MouseRegion(
        // MouseRegion 的参数是 hitTestBehavior（不是 Listener 的 behavior）；
        // translucent + opaque:false 才能既收 onHover、又不让本区域吞掉
        // 身后其它 MouseRegion/手势的命中（播放页封面还要接长按进 Zen、
        // 单击 peek 等手势，见 docs/agents/windows-desktop.md W8 同类坑）。
        hitTestBehavior: HitTestBehavior.translucent,
        opaque: false,
        // 用 localPosition（= position 按本 RenderMouseRegion 的
        // entry.transform 变换后的坐标，见 gestures/binding.dart:508
        // `entry.target.handleEvent(event.transformed(entry.transform), entry)`），
        // 它已经是「封面矩形内坐标」，符合 DepthTiltController 的契约。
        // 不要用 event.position：那是全局坐标，直接喂进去会让中心偏移到
        // 整个窗口原点，视差的方向与幅度全错。
        onHover: (event) {
          final box = context.findRenderObject();
          if (box is! RenderBox || !box.hasSize) return;
          _tilt!.handleHover(event.localPosition, box.size);
        },
        onExit: (_) => _tilt!.handleExit(),
        child: cover,
      );
    }
    if (!_ringVisible || _ringCtrl == null) return cover;
    return Stack(
      fit: StackFit.expand,
      children: [
        cover,
        // 首次平面→3D 切换的中心扩散圆环（浅灰半透明，内外渐变）。
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _ringCtrl!,
              builder: (context, _) => CustomPaint(
                painter: _DepthRingPainter(t: _ringCtrl!.value),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 是否已有 3D 内容（shader 深度图或多层）——只有这时挂 MouseRegion 才有意义，
  /// 平面封面阶段挂上去等于给一张不动的图加一层无用的命中测试。
  bool get _hasDepthContent => _depthInfo != null || _layers != null;

  @override
  Widget build(BuildContext context) {
    if (!_depthEnabled) {
      return PlayerArtworkImage(
        artworkUri: widget.artworkUri,
        fallbackFilePath: widget.fallbackFilePath,
        fit: widget.fit,
        iconSize: widget.iconSize,
        backgroundColor: widget.backgroundColor,
        iconColor: widget.iconColor,
      );
    }
    return _buildCover();
  }
}

/// 中心向外扩散的浅灰圆环过渡：半径从 0 长到对角线，环带内外缘半透明渐变，
/// 整体随动画淡出。t∈[0,1]。
class _DepthRingPainter extends CustomPainter {
  _DepthRingPainter({required this.t});

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final maxR = size.longestSide * 0.75;
    final r = maxR * Curves.easeOutCubic.transform(t);
    final fade = 1.0 - t;
    final band = maxR * 0.30; // 环带厚度
    final inner = (r - band).clamp(0.0, maxR);
    final outer = (r + band * 0.5).clamp(0.0, maxR + band);
    final alpha = 0.35 * fade;

    final shader = RadialGradient(
      center: Alignment.center,
      radius: (outer == 0 ? 1 : outer) / (size.longestSide / 2),
      colors: [
        const Color(0x00000000),
        Colors.grey.withValues(alpha: 0.0),
        Colors.grey.withValues(alpha: alpha),
        Colors.grey.withValues(alpha: alpha * 0.7),
        const Color(0x00000000),
      ],
      stops: [
        0.0,
        (inner / outer).clamp(0.0, 1.0) * 0.9,
        inner / outer,
        1.0 - (1 - (r / outer)).clamp(0.0, 1.0) * 0.5,
        1.0,
      ],
    ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_DepthRingPainter old) => old.t != t;
}
