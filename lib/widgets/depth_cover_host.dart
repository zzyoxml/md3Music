import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../core/services/depth_cover_feature.dart';
import '../core/services/depth_cover_cache.dart';
import '../data/repositories/settings_repository.dart';
import '../services/depth_cover_service.dart';
import 'depth_parallax_cover.dart';
import 'depth_shader_cover.dart';
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
  static const bool _preferShader = true;
  /// 倾斜增益：重力分量 /9.81 在常见握持角度下只有 0.1–0.35，放大后再 clamp 到 -1..1。
  static const double _tiltGain = 2.5;

  /// 进程级 shader 支持标记：某设备一旦编译失败，本进程内其余封面直接走多层视差，
  /// 不再逐个重试（避免每次进播放页都失败一次）。
  static bool _shaderUnsupported = false;
  /// 进程级提示去重：降级/传感器缺失各只提示一次。
  static bool _shaderToastShown = false;
  static bool _tiltToastShown = false;
  /// 本设备 shader 是否已失败（实例视图，用于选择渲染路径）。
  bool _shaderFailed = false;

  List<String>? _layers;
  /// shader 路径命中：{'depth','depthStd','cover'}；非空即优先渲染逐像素位移封面。
  Map<String, Object?>? _depthInfo;
  /// 默认倾斜源（创建一次复用，避免 build 每次重建传感器流）。
  Stream<(double, double)>? _tiltSource;
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

  /// 是否走 shader 逐像素路径（设备 shader 不受支持时降级为多层视差）。
  bool get _useShaderPath =>
      _preferShader && !_shaderFailed && !_shaderUnsupported;

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
    _tiltSource = _defaultTiltStream();
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
    debugPrint('[DepthCover] host init: enabled=$enabled uri=${widget.artworkUri}');
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
      setState(() => _layers = cached);
      _revealWithRing();
      return;
    }
    _cancel ??= service.cache.addListener(key, _onReady);
    _requesting = true;
    final bool ok;
    if (_useShaderPath) {
      ok = await service.requestDepth(uri);
    } else {
      ok = await service.request(uri); // 多层切割路径（原稳定行为）
    }
    _requesting = false;
    _attempts++;
    debugPrint(
        '[DepthCover] host ${_useShaderPath ? "depth " : "layers "}request → $ok '
        '(attempt $_attempts/$_maxAttempts)');
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

  /// 生成完成回调：同时探测两种缓存，shader 深度优先于多层。
  void _onReady() {
    final key = DepthCoverCache.cacheKey(widget.artworkUri ?? '');
    DepthCoverService.instance.cache.getCachedDepth(key).then((d) {
      if (mounted && d != null) {
        final isNew = _depthInfo == null && _layers == null;
        setState(() => _depthInfo = d);
        if (isNew) _revealWithRing();
      }
    });
    DepthCoverService.instance.cache.getCachedLayers(key).then((ls) {
      if (mounted && ls != null && _depthInfo == null && _layers == null) {
        setState(() => _layers = ls);
        _revealWithRing();
      }
    });
  }

  /// 默认倾斜源：重力向量归一化（与 [DepthParallaxCover] 同款 2.5× 增益）。
  /// [DepthShaderCover] 内部再做 0.35 EMA 平滑。shader widget 的 tiltStream 必填，
  /// 故由宿主提供默认流，等价「传 null 时用传感器默认流」的语义。
  Stream<(double, double)> _defaultTiltStream() {
    // uiInterval ≈ 60Hz：与屏幕刷新率对齐，避免高于刷新率的无效重绘。
    return accelerometerEventStream(
          samplingPeriod: SensorInterval.uiInterval,
        )
        .map((e) => (e.x / 9.81 * _tiltGain, e.y / 9.81 * _tiltGain))
        .map((v) => (
              v.$1.clamp(-1.0, 1.0).toDouble(),
              v.$2.clamp(-1.0, 1.0).toDouble(),
            ));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    DepthCoverService.enabledSignal.removeListener(_onEnabledSignal);
    _cancel?.call();
    _depthInfo = null;
    _ringCtrl?.dispose();
    super.dispose();
  }

  /// 用当前内容（shader/多层/平面）与可选的圆环过渡叠层构建封面。
  Widget _buildCover() {
    Widget cover;
    if (_useShaderPath && _depthInfo != null) {
      cover = DepthShaderCover(
        coverPath: _depthInfo!['cover'] as String,
        depthPath: _depthInfo!['depth'] as String,
        depthStd: _depthInfo!['depthStd'] as double,
        bgFillPath: _depthInfo!['bgFill'] as String?,
        tiltStream: _tiltSource!,
        strengthPx: _strength,
        onFailed: _onShaderFailed,
        onTiltError: _onTiltError,
      );
    } else if (_layers != null) {
      // 回退：多层切割视差。
      cover = DepthParallaxCover(
        layerPaths: _layers!,
        strength: _strength,
        tiltStream: _tiltSource,
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
