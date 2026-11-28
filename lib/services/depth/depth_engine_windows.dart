import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../../core/utils/app_toast.dart' as app_toast;
import '../../data/repositories/settings_repository.dart';
import 'depth_engine.dart';
import 'depth_worker.dart';

/// Windows 端 3D 封面后端：纯 Dart ONNX Runtime FFI + 常驻后台 isolate。
///
/// 与 Android 的 `ChannelDepthEngine` 分工：本类**没有任何 MethodChannel 依赖**，
/// 因此不要求 runner 注册 `depth_cover` 通道（Windows 侧确实没有），也不再像
/// 原先那样每次调用抛 MissingPluginException 后永远停在平面封面。
///
/// 产物布局（便携包 app-local，全在 exe 同目录；由 scripts/tasks/windows.ps1 与
/// windows/CMakeLists.txt 准备）：
/// - `onnxruntime.dll` + `onnxruntime_providers_shared.dll`（CPU EP 必需的配套 dll）
/// - `depth_model/depth_anything_v2_vits_q4f16.onnx`（19,126,267 B）
/// - `depth_model/migan512_pipeline_int8.onnx`（10,885,440 B）
///
/// 缺失时的口径与「模型提取失败」一致：一次性提示 + 返回 false，交给
/// `DepthCoverHost` 的 `_maxAttempts` / `_maxFailedCycles` 兜底 —— 不无限刷日志、
/// 不崩溃。开发者本机没跑过打包脚本时走的就是这条分支。
class WindowsDartDepthEngine implements DepthEngine {
  static const String _depthModelFile = 'depth_anything_v2_vits_q4f16.onnx';
  static const String _inpaintModelFile = 'migan512_pipeline_int8.onnx';
  static const String _runtimeDll = 'onnxruntime.dll';
  static const String _modelDirName = 'depth_model';

  /// 测试/探针注入点（与 `DepthCoverCache.baseDirOverride` 同款模式）：
  /// flutter test 的 `Platform.resolvedExecutable` 是 flutter_tester，不是 App 目录，
  /// 实机链路验证时把 dll/模型指到 vendor 目录。
  @visibleForTesting
  static String? dllPathOverride;
  @visibleForTesting
  static String? depthModelPathOverride;
  @visibleForTesting
  static String? inpaintModelPathOverride;

  /// exe 目录：用 `Platform.resolvedExecutable`，**不用** cwd —— 双击启动时
  /// 工作目录可能是别处，裸名打开 dll 会失败。
  static String get _exeDir => File(Platform.resolvedExecutable).parent.path;

  static String get _dllPath =>
      dllPathOverride ?? _join(_exeDir, _runtimeDll);
  static String get _modelPath =>
      depthModelPathOverride ?? _join(_join(_exeDir, _modelDirName), _depthModelFile);
  static String get _inpaintPath =>
      inpaintModelPathOverride ?? _join(_join(_exeDir, _modelDirName), _inpaintModelFile);

  static String _join(String a, String b) => '$a${Platform.pathSeparator}$b';

  /// 诊断面包屑用的进程级时钟：每条 `[DepthCover]` 日志带 `+Nms`，出问题时能一眼
  /// 判断「卡在哪个阶段、UI 线程有没有被阻塞」（`FrameTiming` 看不到事件循环阻塞，
  /// 见 docs/agents/windows-desktop.md W5.8）。
  static final Stopwatch _clock = Stopwatch()..start();
  static int get _ms => _clock.elapsedMilliseconds;

  bool _modelLoaded = false;
  bool _inpaintLoaded = false;

  /// 运行时/模型缺失这类**不可自愈**的失败：置位后不再重复 spawn 与提示。
  bool _fatalInitFailure = false;

  static bool _loadFailureToastShown = false;

  Isolate? _worker;
  SendPort? _workerPort;

  /// worker 回信端口：必须在 spawn 之前 create 并**全程保持订阅**，
  /// 否则单订阅端口被 `first` 取走一次就关闭，后续应答全部丢失。
  ReceivePort? _replyPort;

  /// 串行化：worker 一次只处理一个请求（ORT 会话非线程安全，且推理本身吃满
  /// 4 个 intra-op 线程）。`_pending` 非空表示有请求在途，后来的进 `_waiting`。
  Completer<DepthReply>? _pending;
  final List<DepthRequest> _waiting = [];

  @override
  Future<void> showToast(String message) async {
    // Windows 的原生提示走 app_toast（内部按平台路由到 md3music/desktop_message
    // 的独立提示窗）。本类的 `showToast` 是接口方法，必须加前缀调用顶层函数，
    // 否则就是无限递归。
    app_toast.showToast(message, long: true);
  }

  void _notifyLoadFailureOnce(String reason) {
    debugPrint('[DepthCover] Windows 引擎初始化失败: $reason');
    if (_loadFailureToastShown) return;
    _loadFailureToastShown = true;
    // ignore: discarded_futures
    showToast('3D 封面运行时或深度模型缺失（$reason）');
  }

  @override
  Future<bool> ensureModelLoaded() async {
    if (_modelLoaded) return true;
    if (_fatalInitFailure) return false;
    if (!File(_dllPath).existsSync()) {
      _notifyLoadFailureOnce('缺少 $_runtimeDll');
      _fatalInitFailure = true;
      return false;
    }
    if (!File(_modelPath).existsSync()) {
      _notifyLoadFailureOnce('缺少 $_depthModelFile');
      _fatalInitFailure = true;
      return false;
    }
    try {
      await _ensureWorker();
      final reply = await _send(DepthRequest(
        command: DepthCommand.loadDepth,
        dllPath: _dllPath,
        modelPath: _modelPath,
      ));
      if (reply.ok) {
        _modelLoaded = true;
        debugPrint('[DepthCover] +${_ms}ms Windows 深度会话已就绪');
        return true;
      }
      _notifyLoadFailureOnce(reply.error ?? 'unknown');
      // 会话创建/模型加载失败属不可自愈：置位避免每首歌重试刷日志。
      _fatalInitFailure = true;
    } on TimeoutException catch (e) {
      // 握手/推理超时是可重试的（isolate 冷启动偶发慢），**不能**置 fatal ——
      // 否则一次抖动就会让 3D 封面在本进程内永久不可用（要重启 App）。
      debugPrint('[DepthCover] Windows 引擎超时（可重试）: $e');
      _resetWorker();
    } catch (e) {
      debugPrint('[DepthCover] Windows 引擎异常: $e');
      _resetWorker();
    }
    return false;
  }

  @override
  Future<void> ensureInpaintSession() async {
    if (_inpaintLoaded || !_modelLoaded) return;
    final enabled = await SettingsRepository().getDepthCoverNeuralInpaint();
    if (!enabled) return;
    if (!File(_inpaintPath).existsSync()) {
      debugPrint('[DepthCover] 未找到修补模型，退回 push-pull');
      return;
    }
    try {
      final reply = await _send(DepthRequest(
        command: DepthCommand.loadInpaint,
        inpaintModelPath: _inpaintPath,
      ));
      _inpaintLoaded = reply.ok;
      debugPrint('[DepthCover] +${_ms}ms loadInpaintModel → ${reply.ok} ${reply.error ?? ''}');
    } catch (e) {
      debugPrint('[DepthCover] loadInpaintModel failed: $e');
    }
  }

  @override
  Future<Map<String, Object?>?> generateDepth(
    String sourcePath,
    String outDir,
    String key,
  ) async {
    if (!_modelLoaded) return null;
    debugPrint('[DepthCover] +${_ms}ms generateDepth 开始（$key）');
    try {
      final reply = await _send(DepthRequest(
        command: DepthCommand.generateDepth,
        sourcePath: sourcePath,
        outDir: outDir,
      ));
      if (!reply.ok) {
        debugPrint('[DepthCover] Windows generateDepth 失败: ${reply.error}');
        return null;
      }
      debugPrint('[DepthCover] +${_ms}ms generateDepth 完成（inpaint=${reply.inpaintSource}）');
      final depth = reply.depthPath;
      final std = reply.depthStd;
      if (depth == null || std == null) return null;
      return {
        'depth': depth,
        'depthStd': std,
        if (reply.bgFillPath != null) 'bgFill': reply.bgFillPath,
        if (reply.inpaintSource != null) 'inpaint': reply.inpaintSource,
      };
    } catch (e) {
      debugPrint('[DepthCover] Windows generateDepth 异常: $e');
      return null;
    }
  }

  @override
  Future<List<String>?> generateLayers(
    String sourcePath,
    String outDir,
    String key,
  ) async {
    if (!_modelLoaded) return null;
    debugPrint('[DepthCover] +${_ms}ms generateLayers 开始（$key）');
    try {
      final reply = await _send(DepthRequest(
        command: DepthCommand.generateLayers,
        sourcePath: sourcePath,
        outDir: outDir,
      ));
      if (!reply.ok) {
        debugPrint('[DepthCover] Windows generate 失败: ${reply.error}');
        return null;
      }
      final layers = reply.layers;
      if (layers == null || layers.length != 3) return null;
      debugPrint('[DepthCover] +${_ms}ms generateLayers 完成 → 3 层');
      return layers;
    } catch (e) {
      debugPrint('[DepthCover] Windows generate 异常: $e');
      return null;
    }
  }

  /// spawn worker（进程内一次）并完成握手。
  ///
  /// **幂等**：并发首次调用（`initState` 与 `enabledSignal` 监听重叠时真实出现过）
  /// 必须复用同一个 in-flight future。旧实现只判 `_workerPort != null`，会让第二个
  /// 调用再 spawn 一个 isolate、并把 `_replyPort` 顶掉 —— 第一个 isolate 的握手
  /// 永远完不成 → 10s 超时 → 误报「运行时/模型缺失」且（旧代码）永久禁用 3D 封面。
  Future<void> _ensureWorker() {
    if (_workerPort != null) return Future<void>.value();
    final inflight = _workerSpawn;
    if (inflight != null) return inflight;
    final spawn = _spawnWorker();
    _workerSpawn = spawn;
    return spawn;
  }

  /// 正在进行的 spawn（幂等锚点）；成功后保留，失败时清空以允许重试。
  Future<void>? _workerSpawn;
  ReceivePort? _workerErrorPort;
  ReceivePort? _workerExitPort;

  Future<void> _spawnWorker() async {
    debugPrint('[DepthCover] +${_ms}ms worker spawn 开始');
    final replyPort = ReceivePort();
    _replyPort = replyPort;
    final handshake = Completer<SendPort>();
    // **单订阅**监听：ReceivePort 是单流，第二次 listen 会抛「already listened」。
    // 握手（SendPort）与后续应答（DepthReply）共用这一条订阅，按类型分发。
    replyPort.listen((message) {
      if (message is SendPort) {
        if (!handshake.isCompleted) handshake.complete(message);
        return;
      }
      if (message is DepthReply) _onReply(message);
    });
    final Isolate worker;
    try {
      worker = await Isolate.spawn(
        runDepthWorker,
        // worker 把「它的收信 SendPort」和后续所有 DepthReply 都发回这个端口。
        replyPort.sendPort,
        debugName: 'DepthCoverWorker',
      );
    } catch (e) {
      _workerSpawn = null;
      _resetWorker(closeReplyPort: true);
      rethrow;
    }
    _worker = worker;
    // worker 异常退出/崩溃：必须把在途与排队请求快速失败，否则
    // `DepthCoverHost._requesting` 会永远为 true（表现为「点了没反应」）。
    // `addErrorListener` 收的是 SendPort（不是回调），所以自建一个错误端口。
    final errorPort = ReceivePort();
    _workerErrorPort = errorPort;
    errorPort.listen((message) {
      debugPrint('[DepthCover] worker 异常: $message');
      _failAllPending('worker 异常: $message');
      _resetWorker();
    });
    worker.addErrorListener(errorPort.sendPort);
    final exitPort = ReceivePort();
    _workerExitPort = exitPort;
    exitPort.listen((message) {
      debugPrint('[DepthCover] worker 退出: $message');
      _failAllPending('worker 意外退出');
      _resetWorker();
    });
    worker.addOnExitListener(exitPort.sendPort);
    try {
      _workerPort = await handshake.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('深度推理 worker 握手超时'),
      );
    debugPrint('[DepthCover] +${_ms}ms worker 握手完成');
    } catch (_) {
      _workerSpawn = null;
      _failAllPending('worker 握手失败');
      _resetWorker();
      rethrow;
    }
  }

  /// 把所有在途/排队请求以失败收尾（worker 崩了或握手失败时，避免 await 永挂）。
  void _failAllPending(String reason) {
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.complete(DepthReply.fail(reason));
    }
    for (final c in _queuedCompleters) {
      if (!c.isCompleted) c.complete(DepthReply.fail(reason));
    }
    _waiting.clear();
    _queuedCompleters.clear();
  }

  /// 丢弃 worker 状态（不 kill 已退出/已损坏的 isolate，只清引用与端口）。
  void _resetWorker({bool closeReplyPort = false}) {
    _workerPort = null;
    _workerSpawn = null;
    _workerErrorPort?.close();
    _workerErrorPort = null;
    _workerExitPort?.close();
    _workerExitPort = null;
    if (closeReplyPort) {
      _replyPort?.close();
      _replyPort = null;
    }
  }

  Future<DepthReply> _send(DepthRequest request) {
    final port = _workerPort;
    if (port == null) return Future.value(DepthReply.fail('worker 未就绪'));
    if (_pending == null) {
      final completer = Completer<DepthReply>();
      _pending = completer;
      port.send(request);
      return completer.future;
    }
    // 已有请求在途：排队，等前一个完成后由 _onReply 依次下发。
    final completer = Completer<DepthReply>();
    _waiting.add(request);
    _queuedCompleters.add(completer);
    return completer.future;
  }

  final List<Completer<DepthReply>> _queuedCompleters = [];

  void _onReply(DepthReply reply) {
    final pending = _pending;
    if (pending == null || pending.isCompleted) return;
    pending.complete(reply);
    _pending = null;
    if (_waiting.isEmpty) return;
    final port = _workerPort;
    if (port == null) return;
    final next = _waiting.removeAt(0);
    final nextCompleter = _queuedCompleters.removeAt(0);
    _pending = nextCompleter;
    port.send(next);
  }

  /// 退出清理（正常进程退出会自动回收；播放页 dispose 不需要调用）。
  void disposeWorker() {
    _failAllPending('engine disposed');
    _resetWorker(closeReplyPort: true);
    _worker?.kill(priority: Isolate.beforeNextEvent);
    _worker = null;
  }
}
