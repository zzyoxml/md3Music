import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../main.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import 'recognition_utils.dart';

/// 悬浮窗识曲启动结果
enum FloatingStartResult {
  /// 已启动悬浮窗服务
  started,

  /// 已在运行
  alreadyActive,

  /// Android < 10，不支持系统音频捕获
  unsupported,

  /// 权限被拒（麦克风/悬浮窗）
  permissionDenied,

  /// 其他失败
  failed,
}

/// 悬浮窗识曲服务（Dart 侧控制类）。
///
/// 职责：
/// 1. 启动/停止原生悬浮窗服务（`FloatingRecognitionService`，含悬浮窗权限检查）
/// 2. 处理原生回传的 8s PCM 段：静音检测 → 增益归一化 → 酷狗 audioMatch
/// 3. 控制识别循环（最多 7 段）：命中回传结果并停止；未命中继续；超时提示失败
/// 4. 悬浮窗按钮动作：请求 MediaProjection 授权、播放最近识别结果
class FloatingRecognitionService {
  static final FloatingRecognitionService instance = FloatingRecognitionService._();
  FloatingRecognitionService._();

  static const MethodChannel _channel = MethodChannel(
    'com.md3music.md3music/floating_recognition',
  );
  static const MethodChannel _sdkChannel = MethodChannel(
    'com.md3music.md3music/media_store',
  );

  /// 每段录制时长（秒，与原生侧 SEGMENT_BYTES 一致：8000Hz×2字节×8s）
  static const int _segmentDuration = 8;
  /// 最大总录制时长（秒），56s = 7 轮
  static const int _maxTotalDuration = 56;

  bool _isActive = false;
  bool get isActive => _isActive;

  int _attemptCount = 0;
  Map<String, dynamic>? _lastResult;

  // 状态变化监听（识曲页按钮刷新）
  final List<VoidCallback> _listeners = [];
  void addListener(VoidCallback cb) => _listeners.add(cb);
  void removeListener(VoidCallback cb) => _listeners.remove(cb);
  void _notify() {
    for (final cb in List.of(_listeners)) {
      cb();
    }
  }

  /// 在 app 启动时（main 中）调用：注册原生回调
  void registerNativeCallbacks() {
    print('[FloatingRecognition] registerNativeCallbacks called');
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onProjectionResult':
          final granted = call.arguments as bool? ?? false;
          print('[FloatingRecognition] onProjectionResult granted=$granted');
          if (!granted) {
            _setStatus('未授权，无法捕获系统音频');
          }
          break;
        case 'onSegmentCaptured':
          final pcm = call.arguments is Uint8List
              ? call.arguments as Uint8List
              : Uint8List(0);
          print('[FloatingRecognition] onSegmentCaptured len=${pcm.length}');
          await _handleSegment(pcm);
          break;
        case 'onFloatingAction':
          _handleFloatingAction(call.arguments as String? ?? '');
          break;
        case 'onServiceStopped':
          _isActive = false;
          _attemptCount = 0;
          _lastResult = null;
          _notify();
          break;
      }
    });
  }

  /// 启动悬浮窗识曲：SDK 版本检查 → 麦克风权限 → 原生启动（悬浮窗权限 native 检查）
  Future<FloatingStartResult> start() async {
    if (_isActive) return FloatingStartResult.alreadyActive;

    // Android < 10 不支持 AudioPlaybackCapture
    int sdk = 0;
    try {
      sdk = await _sdkChannel.invokeMethod<int>('getSdkVersion') ?? 0;
    } catch (_) {}
    if (sdk < 29) return FloatingStartResult.unsupported;

    // AudioPlaybackCapture 前提：录音权限
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) return FloatingStartResult.permissionDenied;

    try {
      await _channel.invokeMethod('start');
      _isActive = true;
      _notify();
      return FloatingStartResult.started;
    } on PlatformException catch (e) {
      if (e.code == 'PERMISSION_DENIED') return FloatingStartResult.permissionDenied;
      if (e.code == 'UNSUPPORTED') return FloatingStartResult.unsupported;
      return FloatingStartResult.failed;
    } catch (_) {
      return FloatingStartResult.failed;
    }
  }

  /// 停止悬浮窗识曲服务
  Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
    _isActive = false;
    _attemptCount = 0;
    _lastResult = null;
    _notify();
  }

  /// 推送当前主题色到原生悬浮窗（跟随设置页莫奈/动态取色）。
  /// 服务运行时调用，原生侧刷新悬浮窗配色。
  Future<void> pushThemeColors(ColorScheme cs) async {
    final colors = <String, int>{
      'surfaceContainerHighest': cs.surfaceContainerHighest.toARGB32(),
      'onSurface': cs.onSurface.toARGB32(),
      'onSurfaceVariant': cs.onSurfaceVariant.toARGB32(),
      'primary': cs.primary.toARGB32(),
      'onPrimary': cs.onPrimary.toARGB32(),
      'tertiary': cs.tertiary.toARGB32(),
      'onTertiary': cs.onTertiary.toARGB32(),
      'primaryContainer': cs.primaryContainer.toARGB32(),
      'onPrimaryContainer': cs.onPrimaryContainer.toARGB32(),
      'surfaceContainer': cs.surfaceContainer.toARGB32(),
      'outlineVariant': cs.outlineVariant.toARGB32(),
    };
    try {
      await _channel.invokeMethod('setThemeColors', {'colors': colors});
    } catch (_) {}
  }

  // ===================== 原生回调处理 =====================

  Future<void> _handleSegment(Uint8List pcm) async {
    _attemptCount++;
    if (pcm.isEmpty) {
      _continueOrFail();
      return;
    }

    // 优先用本地 Rust 服务器做静音检测 + 增益归一化（原生已按 8000Hz 输出，免降采样），
    // 全程网络 IO + Rust 计算，不占用 UI isolate；服务器不可用时降级回 Dart 实现。
    final rustResult = await processPcmWithRust(
      input: pcm,
      fromHz: 8000,
      toHz: 8000,
    );
    Uint8List normalizedPcm;
    int maxAmplitude;
    if (rustResult != null) {
      normalizedPcm = rustResult.pcm;
      maxAmplitude = rustResult.maxAmplitude;
      print('[FloatingRecognition] 第 $_attemptCount 段 rust maxAmplitude=$maxAmplitude');
    } else {
      // 降级：Dart 实现（原逻辑）
      maxAmplitude = computeMaxAmplitude(pcm);
      print('[FloatingRecognition] 第 $_attemptCount 段 maxAmplitude=$maxAmplitude');
      normalizedPcm = maxAmplitude >= kSilenceAmplitudeThreshold
          ? normalizeGain(pcm, maxAmplitude)
          : pcm;
    }

    // 静音检测
    if (maxAmplitude < kSilenceAmplitudeThreshold) {
      print('[FloatingRecognition] 本段为静音，跳过');
      _continueOrFail();
      return;
    }

    // 增益归一化后调用酷狗指纹识别
    try {
      final api = KugouApiClient();
      final response = await api.audioMatch(normalizedPcm);
      if (response != null && hasSongData(response)) {
        print('[FloatingRecognition] 识别命中');
        _lastResult = response;
        await _setResult(response);
        await _stopCapture();
      } else {
        _continueOrFail();
      }
    } catch (e) {
      print('[FloatingRecognition] 识别出错: $e');
      _continueOrFail();
    }
  }

  void _handleFloatingAction(String action) {
    switch (action) {
      case 'start':
        // 悬浮窗按钮点击「识别」：重置本轮计数并发起 MediaProjection 授权
        _attemptCount = 0;
        _lastResult = null;
        _requestProjection();
        break;
      case 'play':
        _playLastResult();
        break;
    }
  }

  Future<void> _requestProjection() async {
    try {
      await _channel.invokeMethod('requestProjection');
    } catch (_) {}
  }

  Future<void> _continueOrFail() async {
    if (_attemptCount >= _maxTotalDuration ~/ _segmentDuration) {
      _setStatus('未识别到歌曲');
      await _stopCapture();
    } else {
      try {
        await _channel.invokeMethod('continueCapture');
      } catch (_) {}
    }
  }

  Future<void> _stopCapture() async {
    try {
      await _channel.invokeMethod('stopCapture');
    } catch (_) {}
  }

  /// 把识别结果回传原生悬浮窗显示（歌名/歌手 + 播放按钮）
  Future<void> _setResult(Map<String, dynamic> response) async {
    final audioInfo = _extractAudioInfo(response);
    final info = {
      'songName': extractField(audioInfo, ['songname', 'song_name', 'name', 'SongName']) ?? '未知歌曲',
      'artist': extractField(audioInfo, ['singername', 'singer_name', 'SingerName', 'author_name']) ?? '',
      'hash': audioInfo?['hash']?.toString() ?? audioInfo?['FileHash']?.toString() ?? '',
      'imgurl': extractCoverUrl(audioInfo) ?? '',
    };
    try {
      await _channel.invokeMethod('setResult', {'result': jsonEncode(info)});
    } catch (_) {}
  }

  /// 从 audioMatch response 解析出歌曲信息 map（data 第一项）。
  /// 与识曲页 _buildResult 的解析逻辑一致。
  Map<String, dynamic>? _extractAudioInfo(Map<String, dynamic> response) {
    final responseData = response['data'];
    if (responseData is List && responseData.isNotEmpty) {
      final first = responseData.first;
      if (first is Map) {
        return Map<String, dynamic>.from(first);
      }
    }
    if (responseData is Map) {
      return Map<String, dynamic>.from(responseData);
    }
    return null;
  }

  /// 状态提示（未识别/失败等），原生 Toast 展示
  Future<void> _setStatus(String status) async {
    try {
      await _channel.invokeMethod('setStatus', {'status': status});
    } catch (_) {}
  }

  /// 悬浮窗「播放」按钮：播放最近一次识别结果（不跳转全屏页）
  void _playLastResult() {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null || _lastResult == null) {
      print('[FloatingRecognition] play ignored: ctx=$ctx lastResult=${_lastResult != null}');
      return;
    }
    // _lastResult 是完整 audioMatch response，需先解析出歌曲信息
    final audioInfo = _extractAudioInfo(_lastResult!);
    print('[FloatingRecognition] play with audioInfo=$audioInfo');
    if (audioInfo == null) return;
    playRecognizedSong(ctx, audioInfo);
  }
}
