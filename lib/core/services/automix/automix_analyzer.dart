import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'automix_analysis.dart';
import 'automix_analysis_store.dart';
import 'automix_dsp.dart';

/// 解码窗口（毫秒）。25s 足以稳定测出 BPM，又不会拖慢起播。
const int kAutomixWindowMs = 25000;

/// AutoMix 分析编排：缓存 → 原生解码 → DSP → 写回缓存。
///
/// 三条保护，缺一会在真机上变成性能/流量问题：
/// 1. 缓存命中直接返回（分析只需做一次）；
/// 2. 同一 key 并发只解一次（[_inFlight]）；
/// 3. 解码失败记入 [_failedKeys]，本次会话不再重试（坏链接/不支持的格式
///    不应该每首都白跑一次解码）。
class AutomixAnalyzer {
  AutomixAnalyzer({required AutomixAnalysisStore store})
      : _store = store,
        _channel = const MethodChannel('com.md3music.md3music/automix_analysis'),
        _handler = null;

  /// 测试构造器：用 [handler] 替换 MethodChannel。
  AutomixAnalyzer.forTest({
    required AutomixAnalysisStore store,
    required Future<dynamic> Function(MethodCall call) handler,
  })  : _store = store,
        _channel = null,
        _handler = handler;

  final AutomixAnalysisStore _store;
  final MethodChannel? _channel;
  final Future<dynamic> Function(MethodCall call)? _handler;

  final Map<String, Future<AutomixAnalysis?>> _inFlight = {};
  final Set<String> _failedKeys = {};

  AutomixAnalysisStore get store => _store;

  /// 只读缓存，**不触发**解码分析。供 prepare 阶段（时间窗只有几秒）使用：
  /// 分析一律由起播时提前跑完并落盘，这里必须零网络、零解码。
  Future<AutomixAnalysis?> cached(String key) => _store.read(key);

  Future<AutomixAnalysis?> analyze({
    required String key,
    required String url,
    int windowMs = kAutomixWindowMs,
  }) async {
    // 队列里尚未解析播放地址的歌（url 为空）：这不是「分析失败」，是「还没准备好」，
    // 因此**不记入 _failedKeys**，等地址就绪后的新一次调用再正常走。
    if (url.isEmpty) {
      // ignore: avoid_print
      print('[Automix] 跳过（无播放地址）$key');
      return null;
    }
    final cached = await _store.read(key);
    if (cached != null) {
      // ignore: avoid_print
      print('[Automix] 命中缓存 $key bpm=${cached.bpm.toStringAsFixed(1)} '
          'conf=${cached.confidence.toStringAsFixed(2)}');
      return cached;
    }
    if (_failedKeys.contains(key)) return null;

    final running = _inFlight[key];
    if (running != null) return running;

    final future = _run(key: key, url: url, windowMs: windowMs);
    _inFlight[key] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<AutomixAnalysis?> _run({
    required String key,
    required String url,
    required int windowMs,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final window = await _decodeHead(url: url, windowMs: windowMs);
      if (window == null || window.pcm.isEmpty) {
        _failedKeys.add(key);
        // ignore: avoid_print
        print('[Automix] 解码失败（空 PCM）$key 耗时=${stopwatch.elapsedMilliseconds}ms');
        return null;
      }
      final env = onsetEnvelope(window.pcm, sampleRate: window.sampleRate);
      final frameRate = envFrameRate(sampleRate: window.sampleRate);
      final detected = detectBpm(env, frameRate: frameRate);
      if (detected.bpm <= 0) {
        _failedKeys.add(key);
        // ignore: avoid_print
        print('[Automix] 没测出稳定节拍 $key '
            '样本=${window.pcm.length} sr=${window.sampleRate} '
            '包络帧=${env.length} 耗时=${stopwatch.elapsedMilliseconds}ms');
        return null;
      }
      // onset 峰数 → 节奏密度
      var maxV = 0.0;
      for (final v in env) {
        if (v > maxV) maxV = v;
      }
      var peaks = 0;
      if (maxV > 0) {
        final thr = maxV * 0.3;
        for (var i = 1; i < env.length - 1; i++) {
          if (env[i] > env[i - 1] && env[i] >= env[i + 1] && env[i] > thr) peaks++;
        }
      }
      final seconds = window.pcm.length / window.sampleRate;
      final analysis = AutomixAnalysis(
        key: key,
        bpm: detected.bpm,
        confidence: detected.confidence,
        firstBeatSec: firstOnsetSec(env, frameRate),
        rhythmDensity: rhythmDensity(peaks, seconds),
        loudnessDbfs: loudnessDbfs(window.pcm),
        windowMs: windowMs,
        analyzedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      // ignore: avoid_print
      print('[Automix] 分析完成 $key bpm=${analysis.bpm.toStringAsFixed(1)} '
          'conf=${analysis.confidence.toStringAsFixed(2)} '
          '首拍=${analysis.firstBeatSec.toStringAsFixed(2)}s '
          '密度=${analysis.rhythmDensity.toStringAsFixed(2)} '
          '响度=${analysis.loudnessDbfs.toStringAsFixed(1)}dB '
          '可用=${analysis.usable} '
          '样本=${window.pcm.length} sr=${window.sampleRate} '
          '耗时=${stopwatch.elapsedMilliseconds}ms');
      await _store.write(analysis);
      return analysis;
    } catch (e) {
      _failedKeys.add(key);
      // ignore: avoid_print
      print('[Automix] 分析异常 $key: $e 耗时=${stopwatch.elapsedMilliseconds}ms');
      return null;
    }
  }

  Future<_PcmWindow?> _decodeHead({
    required String url,
    required int windowMs,
  }) async {
    // 平台判断只针对真实 MethodChannel：走 handler 注入时（测试）不该被拦。
    if (_channel != null && !Platform.isAndroid) return null;
    final args = <String, dynamic>{'uri': url, 'windowMs': windowMs};
    final raw = _handler != null
        ? await _handler!(MethodCall('decodeHead', args))
        : await _channel!.invokeMethod<Map<dynamic, dynamic>>('decodeHead', args);
    if (raw is! Map) return null;
    final sr = raw['sampleRate'];
    final pcm = raw['pcm'];
    if (sr is! int || pcm is! Uint8List) return null;
    return _PcmWindow(sampleRate: sr, pcm: _asInt16(pcm));
  }

  /// Uint8List → Int16List。原生按小端写入，ARM/x86 主机也是小端，
  /// 因此可以直接 view（零拷贝）；偏移为奇数时退化为一次拷贝。
  static Int16List _asInt16(Uint8List bytes) {
    if (bytes.offsetInBytes % 2 == 0 && bytes.lengthInBytes % 2 == 0) {
      return Int16List.view(
        bytes.buffer,
        bytes.offsetInBytes,
        bytes.lengthInBytes ~/ 2,
      );
    }
    final copy = Uint8List.fromList(bytes);
    return Int16List.view(copy.buffer, 0, copy.lengthInBytes ~/ 2);
  }
}

class _PcmWindow {
  const _PcmWindow({required this.sampleRate, required this.pcm});
  final int sampleRate;
  final Int16List pcm;
}

/// 缓存键：**只用歌曲 id**。
///
/// 曾经把播放地址也纳入键，那是错的：酷狗 CDN 地址带时效签名，同一首歌每次
/// 解析得到的 url 都不同 → `url.hashCode` 每次都变 → 缓存永远不命中，
/// 每首歌每次播放都要重新联网解码 25s 音频。
/// BPM / 拍点与音源无关；响度在不同音质间只差 1~2dB，而响度仅参与
/// 「差 >6dB 降级为长淡化」这一处判断，不足以支撑把键做细。
String buildAutomixKey({required String songId}) => songId;
