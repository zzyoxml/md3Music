import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'kugou_api/kugou_api_client.dart';
import 'kugou_api/kugou_endpoints.dart';

/// libkugou_server.so FFI: int start_server(int port, const char* data_dir)
/// port==0 表示随机选端口；返回实际监听端口（0=失败）。
typedef StartServerNative = Int32 Function(Int32 port, Pointer<Utf8> dataDir);
typedef StartServer = int Function(int port, Pointer<Utf8> dataDir);

/// libkugou_server.so FFI: int is_server_running()
typedef IsRunningNative = Int32 Function();
typedef IsRunning = int Function();

class KugouApiServer {
  static const _channel = MethodChannel('com.md3music.md3music/kugou_api');
  static bool _started = false;

  static Future<void> start() async {
    if (_started || kIsWeb || !Platform.isAndroid) return;

    // 先尝试通过 MethodChannel（JNI 方式，Kotlin 加载 libkugou_server.so）
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        final port = await _channel.invokeMethod<int>('startServer');
        if (port != null && port > 0) {
          _applyPort(port);
          _started = true;
          await _waitForReady(port);
          return;
        }
        print('MethodChannel start returned invalid port: $port');
      } catch (e) {
        print('MethodChannel start failed (attempt ${attempt + 1}): $e');
        await Future.delayed(const Duration(seconds: 1));
      }
    }

    // MethodChannel 失败，尝试 dart:ffi 直接调用 start_server
    print('Falling back to dart:ffi approach...');
    try {
      await _startViaFfi();
    } catch (e) {
      print('dart:ffi start also failed: $e');
    }
  }

  static Future<void> _startViaFfi() async {
    final lib = DynamicLibrary.open('libkugou_server.so');
    final startServer = lib
        .lookupFunction<StartServerNative, StartServer>('start_server');

    final dataDir =
        '/data/user/0/com.md3music.md3music/files'.toNativeUtf8();
    late int port;
    try {
      port = startServer(0, dataDir);
      print('kugou_server start_server returned port: $port');
      if (port <= 0) {
        throw StateError('start_server failed with code $port');
      }
      _applyPort(port);
    } finally {
      calloc.free(dataDir);
    }
    await _waitForReady(port);
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

  static Future<void> _waitForReady(int port) async {
    for (int i = 0; i < 30; i++) {
      try {
        final socket = await Socket.connect('127.0.0.1', port,
            timeout: const Duration(seconds: 1));
        await socket.close();
        print('Local API server is ready on port $port');
        return;
      } catch (_) {
        await Future.delayed(const Duration(seconds: 1));
      }
    }
    print('Local API server did not become ready within 30 seconds');
  }

  static Future<bool> isRunning() async {
    try {
      return await _channel.invokeMethod('isRunning') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 显式停止本地 API 服务器，释放端口，避免下一次冷启动时端口冲突。
  /// Android 直接划掉应用时进程会被系统 kill，线程随之终止；这里保证温和退出
  /// （确认退出 / Activity 销毁）场景能确定性关停。
  static Future<void> stop() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('stopServer');
    } catch (e) {
      print('KugouApiServer stop error: $e');
    }
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
