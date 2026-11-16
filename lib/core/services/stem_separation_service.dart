import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../build_flags.dart';

/// 端侧人声/伴奏分离服务（MethodChannel 封装）。
///
/// 对应原生插件 `StemSeparationPlugin`（源集 `android/app/src/stemsep/`），
/// 通道 `com.md3music.md3music/stem_separation`。
///
/// **两道闸门**：
/// - 编译期 [`kStemSeparationAvailable`]：lite 包（默认/对外公开）整块不编入，
///   连通道都不建，相关 UI 也随之树摇剔除；
/// - 运行时 [`available`]：full 包里模型是否真的随包（公开树导出时资产被剔除、
///   tv flavor 不编该源集），为 false 时原生侧自报不可用，入口置灰而非报错。
///
/// **多平台**：本期只 Android。Windows 的播放层是 WinRT MediaPlayer，没有可注入
/// 的 PCM 出口（要接管得先自建 WASAPI 播放器），Web 连双路播放器都不支持，
/// 因此非 Android 一律 [available] = false。
class StemSeparationService {
  StemSeparationService._();

  static final StemSeparationService instance = StemSeparationService._();

  static const MethodChannel _channel =
      MethodChannel('com.md3music.md3music/stem_separation');

  static const String _tag = 'StemSeparation';

  /// 分离的固定算法延迟（毫秒）。
  ///
  /// 由模型前端决定，不可调：产出一块覆盖 `[B, B+4096)` 的音频，模型必须已经
  /// 喂到 `B+4608`（8 帧 STFT 从 -1024 起、最远看 4608），因此「渲染第 j 帧」
  /// 那一刻分离所需的输入还没到齐 —— 零延迟 + 帧对齐在数学上不可能。
  ///
  /// 固定算法延迟（毫秒）= 2 × WIN / SR。
  ///
  /// 为什么是 2×WIN 而不是 1×WIN：引擎内部 `inQ` 要攒满 `2*WIN` 才推理一块，
  /// 推理后丢掉 `2*CHUNK`。块 k 覆盖 `[k*CHUNK, (k+1)*CHUNK)`，真正算得出来
  /// 需要已喂到 `2*WIN + k*2*CHUNK`。若按 1×WIN 放出，帧 `[0,4096)` 在
  /// `consumed=4608` 时就被要求输出，而块 0 到 9216 才算得出来 → 前 5120 帧
  /// 必然全是原音，听感就是「开了分离却几乎都是原音」。
  ///
  /// 取 `D = 2*WIN` 时块 k 恰在需要它的那一刻算完，预热期只有起播/seek 后
  /// 约 209ms，之后全程都有分离结果。**音画恒定偏差这么多、永不累积漂移**，
  /// UI 侧把进度读数减去该常量即可让歌词对上。
  static const int kStemSeparateLatencyMs = 209;

  bool _inited = false;
  bool _available = false;
  bool _enabled = false;

  /// 原生侧模型是否随包可用（仅 Android 且资产存在时为 true）。
  bool get available => _available;

  /// 是否已开启分离。
  bool get enabled => _enabled;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 最近一次统计快照。
  Map<String, dynamic> _stats = const <String, dynamic>{};

  Map<String, dynamic> get stats => _stats;

  /// 统计里的实时因子（0.5 = 只用一半实时预算，> 1 表示跟不上）。
  double get rtf => (_stats['rtf'] as num?)?.toDouble() ?? 0;

  /// 是否已被判定算力不足（原生连续多块超预算）。
  bool get overloaded => _stats['overloaded'] == true;

  /// 因单批限速被跳过的帧数。
  ///
  /// 只在「某批迟到导致欠账超过 2×frames」时增长。**持续增长说明音频线程
  /// 被反复拖住**——这是卡音的量化信号，排查时优先看它和 [droppedBlocks]。
  int get skippedFrames => (_stats['skippedFrames'] as num?)?.toInt() ?? 0;

  /// 被丢弃的分离块数（过期未播出的块）。持续增长同样指向欠载。
  int get droppedBlocks => (_stats['droppedBlocks'] as num?)?.toInt() ?? 0;

  /// 引擎被重置次数：seek 后应递增，否则说明 flush 没传到模型。
  int get resetCount => (_stats['resetCount'] as num?)?.toInt() ?? 0;

  /// 进度读数应减去的延迟（毫秒）；未启用时为 0。
  int get latencyCompensationMs => _enabled ? kStemSeparateLatencyMs : 0;

  /// 初始化：探测模型可用性并预热解释器。
  ///
  /// 幂等；lite 构建或非 Android 直接返回 false 不建通道调用。
  Future<bool> init() async {
    if (!kStemSeparationAvailable || !_isAndroid) {
      _available = false;
      _inited = true;
      return false;
    }
    if (_inited) return _available;
    _inited = true;
    try {
      final present = await _channel.invokeMethod<bool>('isAvailable') ?? false;
      if (!present) {
        debugPrint('[$_tag] 模型不可用（公开树不带资产或 flavor 不含）');
        _available = false;
        return false;
      }
      final res = await _channel.invokeMapMethod<String, dynamic>('init');
      _available = (res?['available'] as bool?) ?? false;
      if (_available) {
        debugPrint('[$_tag] 就绪 latency=${res?['latencyMs']}ms');
      }
    } catch (e) {
      debugPrint('[$_tag] 初始化失败: $e');
      _available = false;
    }
    return _available;
  }

  /// 开关分离。返回是否有任何变化（未就绪时返回 false，调用方据此提示）。
  Future<bool> setEnabled(bool value) async {
    if (!_isAndroid || !_available) return false;
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'setEnabled',
        <String, dynamic>{'enabled': value},
      );
      if (res != null && res.isNotEmpty) {
        _stats = Map<String, dynamic>.from(res);
      }
      if (value && res?['enabled'] == false) {
        debugPrint('[$_tag] 原生拒绝开启: ${res?['reason']}');
        return false;
      }
      _enabled = value;
      return true;
    } catch (e) {
      debugPrint('[$_tag] setEnabled($value) 失败: $e');
      return false;
    }
  }

  /// 设置伴奏占比（0 = 纯原曲，1 = 纯伴奏）。
  Future<void> setMix(double mix) async {
    if (!_isAndroid || !_available) return;
    try {
      await _channel.invokeMethod<void>('setMix', <String, dynamic>{
        'mix': mix.clamp(0.0, 1.0),
      });
    } catch (e) {
      debugPrint('[$_tag] setMix 失败: $e');
    }
  }

  /// 拉取最新统计（设置页状态行用）。
  Future<Map<String, dynamic>> refreshStats() async {
    if (!_isAndroid || !_available) return _stats;
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('getStats');
      if (res != null && res.isNotEmpty) {
        _stats = Map<String, dynamic>.from(res);
        _logIfDegraded();
      }
    } catch (e) {
      debugPrint('[$_tag] getStats 失败: $e');
    }
    return _stats;
  }

  /// 只在指标**恶化**时打日志，稳态不刷屏。
  ///
  /// 卡音的直接观测量是 [skippedFrames] / [droppedBlocks] 的增长：前者表示
  /// 单批迟到到需要限速丢弃，后者表示块没赶上播出。两者的增量都在这里
  /// 折算成「每多少帧丢多少」，便于判断严重程度。
  void _logIfDegraded() {
    final skipped = skippedFrames;
    final dropped = droppedBlocks;
    final dSkipped = skipped - _lastSkippedFrames;
    final dDropped = dropped - _lastDroppedBlocks;
    _lastSkippedFrames = skipped;
    _lastDroppedBlocks = dropped;
    if (dSkipped <= 0 && dDropped <= 0) return;
    debugPrint(
      '[$_tag] 欠载 skipped+$dSkipped dropped+$dDropped '
      'rtf=${rtf.toStringAsFixed(2)} '
      '累计 skipped=$skipped dropped=$dropped',
    );
  }

  int _lastSkippedFrames = 0;
  int _lastDroppedBlocks = 0;

  /// 清流式状态（seek / 换曲 / 重新开启）。
  Future<void> reset() async {
    if (!_isAndroid || !_available) return;
    try {
      await _channel.invokeMethod<void>('reset');
    } catch (e) {
      debugPrint('[$_tag] reset 失败: $e');
    }
  }

  /// 关闭并清理（退出伴唱 / 应用退出）。
  Future<void> dispose() async {
    if (_enabled) await setEnabled(false);
    _enabled = false;
  }

  /// 仅测试用：把单例的内部状态复位，让每个用例从干净态开始。
  ///
  /// 生产代码不得调用 —— 它会把「已就绪 / 已启用」的缓存清掉，
  /// 导致下一次操作误以为模型不可用。
  @visibleForTesting
  void resetForTest() {
    _inited = false;
    _available = false;
    _enabled = false;
    _stats = const <String, dynamic>{};
  }
}
