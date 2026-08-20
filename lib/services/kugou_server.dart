import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'kugou_api/kugou_api_client.dart';
import 'kugou_api/kugou_endpoints.dart';

/// libkugou_server FFI: int start_server(int port, const char* data_dir)
/// port==0 表示随机选端口；返回实际监听端口（0=失败）。
typedef StartServerNative = Int32 Function(Int32 port, Pointer<Utf8> dataDir);
typedef StartServer = int Function(int port, Pointer<Utf8> dataDir);

/// libkugou_server FFI: int is_server_running()
typedef IsRunningNative = Int32 Function();
typedef IsRunning = int Function();

/// libkugou_server FFI: void stop_server()
typedef StopServerNative = Void Function();
typedef StopServer = void Function();

class KugouApiServer {
  static const _channel = MethodChannel('com.md3music.md3music/kugou_api');
  static bool _started = false;
  static DynamicLibrary? _nativeLib;

  /// 本地 Rust API 服务器支持的平台（进程内 HTTP + dart:ffi / JNI）。
  static bool get isSupported {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isWindows;
  }

  static Future<void> start() async {
    if (_started || !isSupported) return;

    // Android：先尝试 MethodChannel（JNI，Kotlin 加载 libkugou_server.so）
    if (Platform.isAndroid) {
      for (int attempt = 0; attempt < 3; attempt++) {
        try {
          final port = await _channel.invokeMethod<int>('startServer');
          if (port != null && port > 0) {
            if (await _waitForReady(port)) {
              _applyPort(port);
              _started = true;
              return;
            }
            print('MethodChannel server did not become ready on port $port');
          }
          print('MethodChannel start returned invalid port: $port');
        } catch (e) {
          print('MethodChannel start failed (attempt ${attempt + 1}): $e');
          await Future.delayed(const Duration(seconds: 1));
        }
      }
      print('Falling back to dart:ffi approach...');
    }

    try {
      await _startViaFfi();
    } catch (e) {
      print('dart:ffi start failed: $e');
      rethrow;
    }
  }

  static Future<void> _startViaFfi() async {
    final lib = _openNativeLibrary();
    final startServer = lib.lookupFunction<StartServerNative, StartServer>(
      'start_server',
    );

    // Windows release 包中，后端启动不能依赖插件注册顺序；直接使用
    // Windows 约定的 APPDATA 目录，Android 仍沿用 path_provider 的沙箱目录。
    final dataPath = Platform.isWindows
        ? _windowsApplicationSupportPath()
        : (await getApplicationSupportDirectory()).path;
    final dataDirectory = Directory(dataPath);
    await dataDirectory.create(recursive: true);
    final dataDir = dataPath.toNativeUtf8();
    late int port;
    try {
      port = startServer(0, dataDir);
      print('kugou_server start_server returned port: $port');
      if (port <= 0) {
        throw StateError('start_server failed with code $port');
      }
    } finally {
      calloc.free(dataDir);
    }
    final ready = await _waitForReady(port);
    if (!ready) {
      throw StateError('local API server did not become ready on port $port');
    }
    _applyPort(port);
    _started = true;
  }

  static String _windowsApplicationSupportPath() {
    final appData = Platform.environment['APPDATA'];
    if (appData != null && appData.isNotEmpty) {
      return '$appData${Platform.pathSeparator}com.md3music';
    }
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      return '$localAppData${Platform.pathSeparator}com.md3music';
    }
    return '${Directory.current.path}${Platform.pathSeparator}.md3music';
  }

  static DynamicLibrary _openNativeLibrary() {
    if (_nativeLib != null) return _nativeLib!;
    if (Platform.isWindows) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final nextToExe = '$exeDir${Platform.pathSeparator}kugou_server.dll';
      _nativeLib = File(nextToExe).existsSync()
          ? DynamicLibrary.open(nextToExe)
          : DynamicLibrary.open('kugou_server.dll');
    } else {
      _nativeLib = DynamicLibrary.open('libkugou_server.so');
    }
    return _nativeLib!;
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
    final uri = Uri.tryParse(KugouEndpoints.baseUrl);
    return uri?.port ?? 0;
  }

  static Future<bool> _waitForReady(int port) async {
    for (int i = 0; i < 30; i++) {
      try {
        final socket = await Socket.connect(
          '127.0.0.1',
          port,
          timeout: const Duration(milliseconds: 500),
        );
        await socket.close();
        print('Local API server is ready on port $port');
        return true;
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 150));
      }
    }
    print('Local API server did not become ready within 30 seconds');
    return false;
  }

  static Future<bool> isRunning() async {
    if (Platform.isAndroid) {
      try {
        return await _channel.invokeMethod('isRunning') ?? false;
      } catch (_) {}
    }
    try {
      final lib = _openNativeLibrary();
      final isRunning = lib.lookupFunction<IsRunningNative, IsRunning>(
        'is_server_running',
      );
      return isRunning() != 0;
    } catch (_) {
      return false;
    }
  }

  /// 显式停止本地 API 服务器，释放端口，避免下一次冷启动时端口冲突。
  /// Android 直接划掉应用时进程会被系统 kill，线程随之终止；这里保证温和退出
  /// （确认退出 / Activity 销毁）场景能确定性关停。
  static Future<void> stop() async {
    if (!isSupported) return;
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod('stopServer');
        _started = false;
        return;
      } catch (e) {
        print('KugouApiServer MethodChannel stop error: $e');
      }
    }
    try {
      final lib = _openNativeLibrary();
      final stopServer = lib.lookupFunction<StopServerNative, StopServer>(
        'stop_server',
      );
      stopServer();
    } catch (e) {
      print('KugouApiServer FFI stop error: $e');
    }
    _started = false;
  }

  /// 重启本地 API 服务器（设置页「运行中」点击触发）。
  /// 停掉后清空 _started 标记，重新走 start() 分配新随机端口并更新 baseUrl。
  /// Rust 侧 device_info.json 已持久化，重启后 dfid/mid 不变，无需重新注册。
  /// 返回是否成功（以 JNI 侧 nativeIsNodeRunning 为准）。
  static Future<bool> restart() async {
    await stop();
    await Future.delayed(const Duration(milliseconds: 300));
    _started = false;
    await start();
    return await isRunning();
  }
}
