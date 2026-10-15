import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'kugou_api/kugou_api_client.dart';
import 'kugou_api/kugou_endpoints.dart';
import 'local_server_lifecycle.dart';

/// libkugou_server.so FFI: int start_server(int port, const char* data_dir)
/// port==0 表示随机选端口；返回实际监听端口（0=失败）。
typedef StartServerNative = Int32 Function(Int32 port, Pointer<Utf8> dataDir);
typedef StartServer = int Function(int port, Pointer<Utf8> dataDir);

/// libkugou_server.so FFI: int is_server_running()
typedef IsRunningNative = Int32 Function();
typedef IsRunning = int Function();

/// libkugou_server.so FFI: void stop_server()
typedef StopServerNative = Void Function();
typedef StopServer = void Function();

/// 在独立 isolate 加载动态库并停止服务器，避免Rust join阻塞Flutter主isolate。
void _stopServerInWorker(String libraryName) {
  final lib = DynamicLibrary.open(libraryName);
  final stopServer = lib.lookupFunction<StopServerNative, StopServer>(
    'stop_server',
  );
  stopServer();
}

/// Android FFI启动工作放入worker isolate，避免dlopen和Rust启动占住UI isolate。
/// 返回值为 [port, dlopen耗时, 符号查找耗时, start_server耗时]，只跨isolate传基础类型。
List<int> _startServerInWorker(String libraryName, String dataDirPath) {
  final loadClock = Stopwatch()..start();
  final lib = DynamicLibrary.open(libraryName);
  final loadMs = loadClock.elapsedMilliseconds;

  final lookupClock = Stopwatch()..start();
  final startServer = lib.lookupFunction<StartServerNative, StartServer>(
    'start_server',
  );
  lookupClock.stop();

  final nativePath = dataDirPath.toNativeUtf8();
  late final int port;
  final startClock = Stopwatch()..start();
  try {
    port = startServer(0, nativePath);
  } finally {
    calloc.free(nativePath);
  }
  final startMs = startClock.elapsedMilliseconds;
  if (port <= 0) throw StateError('start_server failed with code $port');
  return [port, loadMs, lookupClock.elapsedMilliseconds, startMs];
}

bool _isServerRunningInWorker(String libraryName) {
  final lib = DynamicLibrary.open(libraryName);
  final isRunning = lib.lookupFunction<IsRunningNative, IsRunning>(
    'is_server_running',
  );
  return isRunning() == 1;
}

class KugouApiServer {
  static const _channel = MethodChannel('com.md3music.md3music/kugou_api');
  static bool _started = false;

  /// 并发启动、停止与重启分别合并；native启停调用另按提交顺序串行。
  static Future<void>? _startFuture;
  static Future<void>? _stopFuture;
  static Future<bool>? _restartFuture;
  static final AsyncSerialQueue _nativeTransitions = AsyncSerialQueue();
  static DynamicLibrary? _lib;
  static StopServer? _stopServerFn;
  static IsRunning? _isRunningFn;

  static Future<void> start() {
    if (kIsWeb) return Future<void>.value();
    final pending = _startFuture;
    if (pending != null) return pending;
    if (_started) return _confirmRunning();

    final generation = KugouApiClient.markServerStarting();
    final future = _doStart(generation);
    _startFuture = future;
    return future;
  }

  static Future<void> _confirmRunning() async {
    if (await isRunning()) return;
    _started = false;
    _startFuture = null;
    KugouApiClient.markServerStartFailed();
    await start();
  }

  static Future<void> _doStart(int generation) async {
    var succeeded = false;
    try {
      final stopping = _stopFuture;
      if (stopping != null) await stopping;
      final port = await _nativeTransitions.run(_startNativeServer);
      if (generation != KugouApiClient.localServerGeneration) return;
      if (!await _waitForReady(port)) {
        throw TimeoutException('本地 API 服务端口 $port 未就绪');
      }
      if (generation != KugouApiClient.localServerGeneration) return;
      _applyPort(port);
      _started = true;
      succeeded = true;
      KugouApiClient.markServerReady(generation);
    } catch (e) {
      print('KugouApiServer start failed: $e');
    } finally {
      if (generation == KugouApiClient.localServerGeneration) {
        if (!succeeded) {
          _started = false;
          KugouApiClient.markServerStartFailed(generation);
        }
        _startFuture = null;
      }
    }
  }

  static Future<int> _startNativeServer() async {
    // 优先走 dart:ffi（纯 C 函数名不含包名，JNI 符号不匹配时也能用）。
    try {
      return await _startViaFfi();
    } catch (e) {
      if (!Platform.isAndroid) {
        print(
          'dart:ffi start failed and no fallback on this platform '
          '(missing ${_libraryName()}?): $e',
        );
        rethrow;
      }
      print('dart:ffi start failed, falling back to MethodChannel: $e');
    }

    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final port = await _channel.invokeMethod<int>('startServer');
        if (port != null && port > 0) return port;
        throw StateError('MethodChannel returned invalid port: $port');
      } catch (e) {
        print('MethodChannel start failed (attempt ${attempt + 1}): $e');
        if (attempt == 1) rethrow;
        await Future.delayed(const Duration(seconds: 1));
      }
    }
    throw StateError('MethodChannel start failed');
  }

  /// 返回当前平台的原生库文件名（桌面与 Android 命名不同）。
  static String _libraryName() {
    if (Platform.isWindows) return 'kugou_server.dll';
    if (Platform.isLinux) return 'libkugou_server.so';
    if (Platform.isMacOS) return 'libkugou_server.dylib';
    return 'libkugou_server.so'; // Android
  }

  static DynamicLibrary _loadLib() {
    _lib ??= DynamicLibrary.open(_libraryName());
    return _lib!;
  }

  static Future<int> _startViaFfi() async {
    if (Platform.isAndroid) {
      // path_provider依赖PlatformChannel，只能先在主isolate取得可传递的路径。
      final appDir = await getApplicationSupportDirectory();
      final dataDirPath = appDir.path;
      final nativeTimes = await Isolate.run(
        () => _startServerInWorker(_libraryName(), dataDirPath),
      );
      print(
        '[Startup] phase=ffi_start_complete dlopen_ms=${nativeTimes[1]} '
        'lookup_ms=${nativeTimes[2]} start_server_ms=${nativeTimes[3]}',
      );
      return nativeTimes[0];
    }

    final lib = _loadLib();
    final startServer = lib.lookupFunction<StartServerNative, StartServer>(
      'start_server',
    );
    _stopServerFn ??= lib.lookupFunction<StopServerNative, StopServer>(
      'stop_server',
    );
    _isRunningFn ??= lib.lookupFunction<IsRunningNative, IsRunning>(
      'is_server_running',
    );

    final appDir = await getApplicationSupportDirectory();
    final dataDirPath = appDir.path.toNativeUtf8();
    late int port;
    try {
      port = startServer(0, dataDirPath);
      print('kugou_server start_server returned port: $port');
      if (port <= 0) {
        throw StateError('start_server failed with code $port');
      }
    } finally {
      calloc.free(dataDirPath);
    }
    return port;
  }

  /// 把 Rust 返回的实际端口写入 baseUrl（全部请求走本地随机端口）。
  static void _applyPort(int port) {
    final url = 'http://127.0.0.1:$port';
    // 若 KugouApiClient 已构建，同步更新其 Dio baseUrl；未构建时构造函数
    // 会直接读取 KugouEndpoints.baseUrl，onRequest 拦截器也会逐请求覆盖。
    KugouApiClient().updateBaseUrl(url);
    print('Kugou API server ready on $url');
  }

  /// 当前本地 API 服务器端口（start() 成功后有效，未启动/失败时 0）。
  static int get currentPort {
    if (KugouApiClient.localServerState != LocalServerState.ready) return 0;
    final uri = Uri.tryParse(KugouEndpoints.baseUrl);
    return uri?.port ?? 0;
  }

  static Future<bool> _waitForReady(int port) async {
    const timeout = Duration(seconds: 30);
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < timeout) {
      final remaining = timeout - stopwatch.elapsed;
      final probeTimeout = remaining < const Duration(seconds: 1)
          ? remaining
          : const Duration(seconds: 1);
      try {
        final socket = await Socket.connect(
          '127.0.0.1',
          port,
          timeout: probeTimeout,
        );
        await socket.close();
        print('Local API server is ready on port $port');
        return true;
      } catch (_) {
        // P0: 重试间隔 1s → 200ms。start_server 返回端口即已 bind，
        // 就绪通常 <100ms，1s 轮询会在端口/线程调度抖动时白白多等 1s。
        final afterProbe = timeout - stopwatch.elapsed;
        if (afterProbe > Duration.zero) {
          await Future.delayed(
            afterProbe < const Duration(milliseconds: 200)
                ? afterProbe
                : const Duration(milliseconds: 200),
          );
        }
      }
    }
    print('Local API server did not become ready within 30 seconds');
    return false;
  }

  static Future<bool> isRunning() async {
    if (!_started) return false;
    final generation = KugouApiClient.localServerGeneration;
    bool running;
    // 优先用 FFI 查询（不依赖 JNI 符号）
    try {
      if (Platform.isAndroid) {
        running = await Isolate.run(
          () => _isServerRunningInWorker(_libraryName()),
        );
      } else {
        final lib = _loadLib();
        _isRunningFn ??= lib.lookupFunction<IsRunningNative, IsRunning>(
          'is_server_running',
        );
        running = _isRunningFn!() == 1;
      }
    } catch (_) {
      // FFI 不可用再试 MethodChannel
      try {
        running = await _channel.invokeMethod<bool>('isRunning') ?? false;
      } catch (_) {
        running = false;
      }
    }
    if (!running && _started) {
      _started = false;
      KugouApiClient.markServerStartFailed(generation);
      if (generation == KugouApiClient.localServerGeneration) {
        _startFuture = null;
      }
    }
    return running;
  }

  /// 显式停止本地 API 服务器，释放端口，避免下一次冷启动时端口冲突。
  /// Android 直接划掉应用时进程会被系统 kill，线程随之终止；这里保证温和退出
  /// （确认退出 / Activity 销毁）场景能确定性关停。
  static Future<void> stop() {
    if (kIsWeb) return Future<void>.value();
    final pending = _stopFuture;
    if (pending != null) return pending;

    final generation = KugouApiClient.markServerStopping();
    _started = false;
    _startFuture = null;
    final operation = _nativeTransitions.run(_stopNativeServer).then((_) {
      KugouApiClient.markServerStopped(generation);
    });
    late final Future<void> tracked;
    tracked = operation.whenComplete(() {
      if (identical(_stopFuture, tracked)) _stopFuture = null;
    });
    _stopFuture = tracked;
    return tracked;
  }

  static Future<void> _stopNativeServer() async {
    // 优先用 FFI 停止（不依赖 JNI 符号）。
    try {
      if (Platform.isAndroid) {
        // Rust stop() 会 join listener 线程；在主 isolate 同步调用会冻结UI。
        await Isolate.run(() => _stopServerInWorker(_libraryName()));
        print('KugouApiServer stopped via background FFI isolate');
        return;
      }
      final lib = _loadLib();
      _stopServerFn ??= lib.lookupFunction<StopServerNative, StopServer>(
        'stop_server',
      );
      _stopServerFn!();
      print('KugouApiServer stopped via FFI');
      return;
    } catch (e) {
      print('KugouApiServer FFI stop error: $e');
    }

    // MethodChannel 兜底仅 Android 可用
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('stopServer');
    } catch (e) {
      print('KugouApiServer MethodChannel stop error: $e');
    }
  }

  /// 重启本地 API 服务器（设置页「运行中」点击触发）。
  /// 停掉后清空 _started 标记，重新走 start() 分配新随机端口并更新 baseUrl。
  /// Rust 侧 device_info.json 已持久化，重启后 dfid/mid 不变，无需重新注册。
  /// 返回是否成功。
  static Future<bool> restart() {
    final pending = _restartFuture;
    if (pending != null) return pending;
    final future = _doRestart();
    _restartFuture = future;
    return future.whenComplete(() {
      if (identical(_restartFuture, future)) _restartFuture = null;
    });
  }

  static Future<bool> _doRestart() async {
    await stop();
    await start();
    return isRunning();
  }
}
