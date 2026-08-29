import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'kugou_api/kugou_api_client.dart';
import 'kugou_api/kugou_endpoints.dart';

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

class KugouApiServer {
  static const _channel = MethodChannel('com.md3music.md3music/kugou_api');
  static bool _started = false;
  /// P0: 启动中/已完成 Future，供并发调用去重（main() 与播放前兜底）。
  static Future<void>? _startFuture;
  static DynamicLibrary? _lib;
  static StopServer? _stopServerFn;
  static IsRunning? _isRunningFn;

  static Future<void> start() async {
    if (_started || kIsWeb) return;

    // P0: 并发调用去重。main() 后台启动与 player_provider 播放前兜底
    // 可能同时触发 start()；此前 await getApplicationSupportDirectory()
    // 期间 _started 仍为 false，二次进入会重复 dlopen libkugou_server.so
    // + startServer（实测日志出现两次 start_server 调用），浪费启动时间。
    return _startFuture ??= _doStart();
  }

  static Future<void> _doStart() async {
    // 最外层兜底：启动失败时允许下次调用重试，且不向调用方抛未处理异常
    // （main() 与播放兜底都依赖 start() 不抛）
    try {
      // 优先走 dart:ffi（纯 C 函数名不含包名，JNI 符号不匹配时也能用）
      try {
        await _startViaFfi();
        _started = true;
        return;
      } catch (e) {
        if (Platform.isAndroid) {
          print('dart:ffi start failed, falling back to MethodChannel: $e');
        } else {
          // 桌面没有 MethodChannel 兜底，FFI 失败即彻底失败。最常见原因是
          // 原生库没有跟 exe 放在一起（需先跑
          // kugou_api_server/rust/build_desktop.ps1 产出 dll）。
          print('dart:ffi start failed and no fallback on this platform '
              '(missing ${_libraryName()}?): $e');
        }
      }

      // MethodChannel（JNI 方式）仅 Android 有该通道，桌面直接走下方失败处理
      if (Platform.isAndroid) {
        for (int attempt = 0; attempt < 2; attempt++) {
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
      }
    } catch (e) {
      print('KugouApiServer start failed: $e');
    }
    // 启动失败：重置去重 Future，允许后续调用重试（如播放前兜底）。
    // 之前桌面分支在此之前直接 return，既跳过了这行（start() 再也不会重试），
    // 也从不置错误态，导致 KugouApiClient 每个请求都白等满 8s 就绪超时。
    _startFuture = null;
    KugouApiClient.markServerStartFailed();
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

  static Future<void> _startViaFfi() async {
    final lib = _loadLib();
    final startServer = lib
        .lookupFunction<StartServerNative, StartServer>('start_server');
    _stopServerFn ??=
        lib.lookupFunction<StopServerNative, StopServer>('stop_server');
    _isRunningFn ??=
        lib.lookupFunction<IsRunningNative, IsRunning>('is_server_running');

    // 用 path_provider 获取 filesDir，避免硬编码包名路径
    final appDir = await getApplicationSupportDirectory();
    final dataDirPath = appDir.path.toNativeUtf8();
    late int port;
    try {
      port = startServer(0, dataDirPath);
      print('kugou_server start_server returned port: $port');
      if (port <= 0) {
        throw StateError('start_server failed with code $port');
      }
      _applyPort(port);
    } finally {
      calloc.free(dataDirPath);
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
        // P0: 通知 KugouApiClient 服务器已就绪（runApp 不等待服务器启动，
        // 首屏请求依赖此信号放行）
        KugouApiClient.markServerReady();
        return;
      } catch (_) {
        // P0: 重试间隔 1s → 200ms。start_server 返回端口即已 bind，
        // 就绪通常 <100ms，1s 轮询会在端口/线程调度抖动时白白多等 1s。
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
    print('Local API server did not become ready within 30 seconds');
    // 同上：就绪信号永远不会来，若不置错误态，后续每个请求都要白等满 8s。
    KugouApiClient.markServerStartFailed();
  }

  static Future<bool> isRunning() async {
    // 优先用 FFI 查询（不依赖 JNI 符号）
    try {
      final lib = _loadLib();
      _isRunningFn ??=
          lib.lookupFunction<IsRunningNative, IsRunning>('is_server_running');
      return _isRunningFn!() == 1;
    } catch (_) {
      // FFI 不可用再试 MethodChannel
      try {
        return await _channel.invokeMethod('isRunning') ?? false;
      } catch (_) {
        return false;
      }
    }
  }

  /// 显式停止本地 API 服务器，释放端口，避免下一次冷启动时端口冲突。
  /// Android 直接划掉应用时进程会被系统 kill，线程随之终止；这里保证温和退出
  /// （确认退出 / Activity 销毁）场景能确定性关停。
  static Future<void> stop() async {
    if (kIsWeb) return;

    // 优先用 FFI 停止（不依赖 JNI 符号）
    try {
      final lib = _loadLib();
      _stopServerFn ??=
          lib.lookupFunction<StopServerNative, StopServer>('stop_server');
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
  static Future<bool> restart() async {
    await stop();
    await Future.delayed(const Duration(milliseconds: 300));
    _started = false;
    // P0: 清空启动去重 Future，否则 start() 直接返回已完成旧 Future 不重启
    _startFuture = null;
    await start();
    return await isRunning();
  }
}
