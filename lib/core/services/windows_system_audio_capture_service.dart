import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'diagnostic_logger.dart';

/// 识曲音源。
enum RecognitionAudioSource {
  /// 麦克风（`record` 采集，Android / Windows 都可用）。
  microphone,

  /// 系统声音内录（仅 Windows：默认渲染端点的 WASAPI 环回）。
  system,
}

/// 一段内录结果：单声道 16bit PCM（未重采样，采样率为原始值）。
class SystemAudioSegment {
  const SystemAudioSegment({required this.pcm, required this.sampleRate});

  final Uint8List pcm;
  final int sampleRate;
}

const String _sourcePreferenceKey = 'recognition_audio_source';

Future<RecognitionAudioSource> loadRecognitionAudioSource() async {
  final raw =
      (await SharedPreferences.getInstance()).getString(_sourcePreferenceKey);
  return raw == 'system'
      ? RecognitionAudioSource.system
      : RecognitionAudioSource.microphone;
}

Future<void> saveRecognitionAudioSource(RecognitionAudioSource source) async {
  final preferences = await SharedPreferences.getInstance();
  if (source == RecognitionAudioSource.system) {
    await preferences.setString(_sourcePreferenceKey, 'system');
  } else {
    await preferences.remove(_sourcePreferenceKey);
  }
}

/// Windows 系统声音采集：runner 的 WASAPI 设备环回（第二个采集实例，
/// 与音乐频谱并存互不干扰）。
///
/// **为什么不做成 record 的一个 source**：`record_windows` 只暴露麦克风
/// （MediaFoundation audcap），没有环回能力；频谱用的进程环回又会漏掉
/// 其他播放器的声音，故走自建通道 + 设备环回。
class WindowsSystemAudioCaptureService {
  WindowsSystemAudioCaptureService._();

  static const MethodChannel channel = MethodChannel(
    'md3music/windows_system_audio',
  );

  /// 默认最多采 12s（页面每轮 8s，留出起采延迟余量）。
  static const int defaultMaxDurationMs = 12000;

  /// 开始内录；false 表示原生侧激活失败（无默认渲染端点 / 无音频服务）。
  static Future<bool> start({int maxDurationMs = defaultMaxDurationMs}) async {
    try {
      final ok = await channel.invokeMethod<bool>('startCapture', {
        'maxDurationMs': maxDurationMs,
      });
      return ok ?? false;
    } on PlatformException catch (error) {
      DiagnosticLogger.instance.warning(
        '[SystemAudio] start failed: ${error.message}',
      );
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 停止内录并取回本段 PCM；空数据返回 null。
  static Future<SystemAudioSegment?> stop() async {
    try {
      final payload =
          await channel.invokeMapMethod<Object?, Object?>('stopCapture');
      final pcm = payload?['pcm'];
      final sampleRate = payload?['sampleRate'];
      if (pcm is! Uint8List || pcm.isEmpty) return null;
      final rate = sampleRate is int ? sampleRate : 0;
      if (rate <= 0) return null;
      return SystemAudioSegment(pcm: pcm, sampleRate: rate);
    } on PlatformException catch (error) {
      DiagnosticLogger.instance.warning(
        '[SystemAudio] stop failed: ${error.message}',
      );
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
