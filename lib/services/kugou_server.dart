import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// libkugou_server.so FFI: int start_server(int port, const char* data_dir)
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
        await _channel.invokeMethod('startServer');
        _started = true;
        await _waitForReady();
        return;
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
    try {
      final result = startServer(8080, dataDir);
      print('kugou_server start_server returned: $result');
      if (result != 1) {
        throw StateError('start_server failed with code $result');
      }
    } finally {
      calloc.free(dataDir);
    }
    await _waitForReady();
  }

  static Future<void> _waitForReady() async {
    for (int i = 0; i < 30; i++) {
      try {
        final socket = await Socket.connect('127.0.0.1', 8080,
            timeout: const Duration(seconds: 1));
        await socket.close();
        print('Local API server is ready');
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

  /// 显式停止本地 API 服务器，释放 8080 端口，避免下一次冷启动时端口冲突。
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
}
