/// 系统音频 Offload（硬件解码直通）的**设备解码能力快照**模型 + 本地缓存。
///
/// 数据来源是原生侧（fork 的 `AudioOffloadCapabilities`）对 `MediaCodec` 解码器
/// 与 `AudioTrack` 平台参数的探测结果；Dart 侧只做三件事：
/// 1. 把原生 map 解析成强类型模型（[AudioOffloadCapability] /
///    [AudioOffloadCapabilitySnapshot]），供设置页矩阵渲染；
/// 2. 做「源编码 → 解码器」的短名归一与三态判定（[supportsCodec]），供起播前
///    预测「这首能不能硬解」；
/// 3. 把快照写进 `SharedPreferences` 并按设备指纹 / 7 天时效判断是否可信
///    （[AudioOffloadCapabilityStore]），避免每次启动都跑一遍解码器探测。
///
/// **三态语义**（`supportsCodec` 返回值）：`true` 探测到支持、`false` 探测到不支持、
/// `null` 编码不认识或该采样率/声道压根没探测过（「不知道」绝不能谎报为「不支持」）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 单个解码器 / 编码参数组合的能力条目。
///
/// [encoding] 是 Android `AudioFormat.ENCODING_*` 常量（原生可能也给 0）；
/// [encodingName] 是原生侧的可读名（MIME、MediaCodec 组件名或已归一短名均可，
/// 由 [audioCodecShortName] 统一成 UI 用的短名）。
@immutable
class AudioOffloadCapability {
  const AudioOffloadCapability({
    required this.encoding,
    required this.encodingName,
    required this.sampleRate,
    required this.channelCount,
    required this.supported,
    required this.gapless,
    required this.speedChange,
  });

  /// Android `AudioFormat.ENCODING_*`；原生未提供时为 0。
  final int encoding;

  /// 原生给的编码名（MIME / MediaCodec 组件名 / 短名），见 [shortName]。
  final String encodingName;

  /// 采样率（Hz）。
  final int sampleRate;

  /// 声道数。
  final int channelCount;

  /// 该组合能否交给硬件解码器（offload）。
  final bool supported;

  /// 是否支持无缝播放（gapless）。
  final bool gapless;

  /// 是否支持变速播放（不改音高）。
  final bool speedChange;

  /// UI 用的可读短名，如 `MP3` / `AAC-LC` / `HE-AAC v1` / `OPUS` / `FLAC`。
  String get shortName => audioCodecShortName(encodingName, encoding);

  factory AudioOffloadCapability.fromMap(Map<String, dynamic> m) {
    return AudioOffloadCapability(
      encoding: _asInt(m['encoding']),
      encodingName: (m['encodingName'] ?? '').toString(),
      sampleRate: _asInt(m['sampleRate']),
      channelCount: _asInt(m['channelCount']),
      supported: _asBool(m['supported']),
      gapless: _asBool(m['gapless']),
      speedChange: _asBool(m['speedChange']),
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'encoding': encoding,
      'encodingName': encodingName,
      'sampleRate': sampleRate,
      'channelCount': channelCount,
      'supported': supported,
      'gapless': gapless,
      'speedChange': speedChange,
    };
  }

  @override
  String toString() =>
      'AudioOffloadCapability($shortName ${sampleRate}Hz/${channelCount}ch '
      'supported=$supported gapless=$gapless speed=$speedChange)';
}

/// 一台设备一次探测的完整快照。
@immutable
class AudioOffloadCapabilitySnapshot {
  AudioOffloadCapabilitySnapshot({
    required this.deviceKey,
    required this.probedAt,
    required this.sdkInt,
    required this.variableRateSupported,
    required this.outputSampleRate,
    required this.outputFramesPerBuffer,
    required List<AudioOffloadCapability> entries,
    List<String> notes = const <String>[],
    this.probeError,
  }) : entries = List<AudioOffloadCapability>.unmodifiable(entries),
       notes = List<String>.unmodifiable(notes);

  /// 设备指纹（原生给，通常含型号 / 构建指纹 / SDK）；空串表示原生未提供。
  final String deviceKey;

  /// 探测完成时刻。
  final DateTime probedAt;

  /// `Build.VERSION.SDK_INT`。
  final int sdkInt;

  /// 输出通路是否支持可变采样率（免重采样直通）。
  final bool variableRateSupported;

  /// 平台输出采样率（Hz），0 表示未知。
  final int outputSampleRate;

  /// 平台输出每缓冲帧数，0 表示未知。
  final int outputFramesPerBuffer;

  /// 探测失败的描述；null 表示探测正常完成。
  final String? probeError;

  /// 全部探测条目（按原生顺序，UI 自行分组）。
  final List<AudioOffloadCapability> entries;

  /// 未能进入探测矩阵的编码及原因（原生 `notes`）。
  ///
  /// 例如 FLAC / ALAC / VORBIS 在 media3 1.4.1 里没有对应的 offload 编码映射，
  /// 探测阶段就会被跳过。UI 必须如实展示「未探测 + 原因」——静默消失会让用户
  /// 误以为「本机不支持」，实际是「当前播放引擎表达不了」。
  final List<String> notes;

  /// 惰性分组缓存（快照不可变，可安全缓存一份）。
  late final Map<String, List<AudioOffloadCapability>> _byEncoding =
      _groupByEncoding();

  Map<String, List<AudioOffloadCapability>> _groupByEncoding() {
    final grouped = <String, List<AudioOffloadCapability>>{};
    for (final entry in entries) {
      final name = entry.shortName;
      final key = name.isEmpty ? '未知' : name;
      (grouped[key] ??= <AudioOffloadCapability>[]).add(entry);
    }
    return grouped;
  }

  /// 编码短名 → 该编码的所有条目（保持原生顺序）。
  Map<String, List<AudioOffloadCapability>> get byEncoding => _byEncoding;

  /// 三态判定：`true` 支持 / `false` 不支持 / `null` 未探测或编码不认识。
  ///
  /// [codecShortName] 接受 `getSourceFormat().codec` 的返回值
  /// （`FLAC` / `MP3` / `AAC` / `OPUS` / `OGG` / `ALAC` / `APE` / `WAV` / `AC3` /
  /// `AMR` / `DSD` 等），也可传更细的 `AAC-LC` / `HE-AAC v2`。
  bool? supportsCodec(String? codecShortName, int sampleRate, int channelCount) {
    final sourceKey = normalizeSourceCodec(codecShortName);
    if (sourceKey.isEmpty) return null;
    final candidates = kSourceCodecDecoders[sourceKey];
    // 平台没有该编码的硬件解码器（APE / DSD 等）：不适用，返回「不知道」，
    // 由调用方按「无硬解」处理，不能返回 false（那等于宣称探测过且不支持）。
    if (candidates == null || candidates.isEmpty) return null;

    final grouped = byEncoding;
    bool exactFound = false;
    for (final name in candidates) {
      final list = grouped[name];
      if (list == null || list.isEmpty) continue;
      for (final entry in list) {
        if (entry.sampleRate != 0 && entry.sampleRate != sampleRate) continue;
        if (entry.channelCount != 0 && entry.channelCount != channelCount) continue;
        exactFound = true;
        if (entry.supported) return true;
      }
    }
    // 精确命中的条目都不支持
    if (exactFound) return false;
    // 解码器存在但没探测这个采样率 / 声道，或压根没有该解码器：不知道
    return null;
  }

  /// 是否没有任何探测条目。
  bool get isEmpty => entries.isEmpty;

  /// 探测到支持的条目数。
  int get supportedCount => entries.where((e) => e.supported).length;

  /// 探测到的条目总数。
  int get probedCount => entries.length;

  factory AudioOffloadCapabilitySnapshot.fromMap(Map<String, dynamic> m) {
    final rawEntries = m['entries'];
    final entries = <AudioOffloadCapability>[];
    if (rawEntries is List) {
      for (final item in rawEntries) {
        if (item is Map) {
          entries.add(
            AudioOffloadCapability.fromMap(Map<String, dynamic>.from(item)),
          );
        }
      }
    }
    final dynamic rawError = m['probeError'];
    final rawNotes = m['notes'];
    final notes = <String>[];
    if (rawNotes is List) {
      for (final item in rawNotes) {
        final text = item?.toString().trim() ?? '';
        if (text.isNotEmpty) notes.add(text);
      }
    }
    return AudioOffloadCapabilitySnapshot(
      deviceKey: (m['deviceKey'] ?? '').toString(),
      // 原生 `Snapshot.toMap()` 用 `probedAtMs`（epoch 毫秒）；本地缓存用
      // `probedAt`（ISO 字符串）。两个键都必须认，否则原生快照会被当成 1970 年。
      probedAt: _asDateTime(m['probedAt'] ?? m['probedAtMs']),
      sdkInt: _asInt(m['sdkInt']),
      variableRateSupported: _asBool(m['variableRateSupported']),
      outputSampleRate: _asInt(m['outputSampleRate']),
      outputFramesPerBuffer: _asInt(m['outputFramesPerBuffer']),
      probeError: rawError == null || rawError.toString().isEmpty
          ? null
          : rawError.toString(),
      entries: entries,
      notes: notes,
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'deviceKey': deviceKey,
      'probedAt': probedAt.toIso8601String(),
      'sdkInt': sdkInt,
      'variableRateSupported': variableRateSupported,
      'outputSampleRate': outputSampleRate,
      'outputFramesPerBuffer': outputFramesPerBuffer,
      'probeError': probeError,
      'entries': entries.map((e) => e.toMap()).toList(growable: false),
      'notes': notes,
    };
  }

  @override
  String toString() =>
      'AudioOffloadCapabilitySnapshot(device=$deviceKey sdk=$sdkInt '
      'entries=${entries.length} supported=$supportedCount '
      'probedAt=${probedAt.toIso8601String()}'
      '${probeError == null ? '' : ' error=$probeError'})';
}

/// 能力快照的 `SharedPreferences` 缓存。
///
/// 只缓存**序列化文本**与设备指纹两个键：快照结构升级时改 [keyJson] 版本号即可，
/// 不需要写迁移逻辑（旧键成为垃圾数据，随设置重置清掉）。
class AudioOffloadCapabilityStore {
  AudioOffloadCapabilityStore({this.currentDeviceKey});

  /// 快照 JSON 的持久化键（结构变更时升版本号）。
  static const String keyJson = 'audio_offload_caps_v1';

  /// 快照所属设备的指纹键。
  static const String keyDevice = 'audio_offload_caps_device_v1';

  /// 缓存最长可信时间。
  static const Duration maxAge = Duration(days: 7);

  /// 当前设备指纹；为 null 时跳过设备一致性校验（尚未拿到原生状态）。
  String? currentDeviceKey;

  bool _stale = false;

  /// 最近一次 [load] 的结果是否**不可信**（无缓存 / 设备不一致 / 超过 [maxAge]）。
  bool get stale => _stale;

  /// 读取缓存。返回 null 表示没有可用缓存（此时 [stale] 为 true）。
  ///
  /// 设备指纹不一致或超过 [maxAge] 时**仍然返回快照**（便于 UI 先显示旧数据），
  /// 但 [stale] 会置 true，由调用方决定是否重新探测。
  Future<AudioOffloadCapabilitySnapshot?> load() async {
    _stale = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(keyJson);
      if (raw == null || raw.isEmpty) {
        _stale = true;
        return null;
      }
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map) {
        _stale = true;
        return null;
      }
      final snapshot = AudioOffloadCapabilitySnapshot.fromMap(
        Map<String, dynamic>.from(decoded),
      );

      final expected = currentDeviceKey;
      if (expected != null && expected.isNotEmpty) {
        final stored = prefs.getString(keyDevice);
        final cachedKey = (stored != null && stored.isNotEmpty)
            ? stored
            : snapshot.deviceKey;
        if (cachedKey != expected) _stale = true;
      }
      if (DateTime.now().difference(snapshot.probedAt) > maxAge) _stale = true;
      return snapshot;
    } catch (e) {
      debugPrint('[AudioOffloadCap] 读取能力缓存失败: $e');
      _stale = true;
      return null;
    }
  }

  /// 写入缓存（同时记录快照自带的设备指纹）。
  Future<void> save(AudioOffloadCapabilitySnapshot snapshot) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(keyJson, jsonEncode(snapshot.toMap()));
      await prefs.setString(keyDevice, snapshot.deviceKey);
      _stale = false;
    } catch (e) {
      debugPrint('[AudioOffloadCap] 写入能力缓存失败: $e');
    }
  }

  /// 清空缓存（重新探测成功后一般不需要，保留给设置重置 / 排障使用）。
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(keyJson);
      await prefs.remove(keyDevice);
      _stale = true;
    } catch (e) {
      debugPrint('[AudioOffloadCap] 清空能力缓存失败: $e');
    }
  }
}

// ── 编码短名归一 ─────────────────────────────────────────────────────

/// 源编码（`getSourceFormat().codec` 或更细短名）→ 候选解码器短名的映射。
///
/// 值为空表示**平台没有对应的硬件解码器**（APE / DSD 属于这一类），
/// [AudioOffloadCapabilitySnapshot.supportsCodec] 对此返回 null（不适用）。
const Map<String, List<String>> kSourceCodecDecoders = <String, List<String>>{
  'MP3': <String>['MP3'],
  'AAC': <String>['AAC-LC', 'HE-AAC v1', 'HE-AAC v2', 'AAC-xHE', 'AAC-ELD'],
  'FLAC': <String>['FLAC'],
  'OPUS': <String>['OPUS'],
  'OGG': <String>['VORBIS', 'OPUS'],
  'ALAC': <String>['ALAC'],
  'AC3': <String>['AC3'],
  'EAC3': <String>['E-AC3'],
  'AMR': <String>['AMR-WB', 'AMR-NB'],
  'DTS': <String>['DTS'],
  'WAV': <String>['PCM'],
  'APE': <String>[],
  'DSD': <String>[],
};

/// 把源编码名归一成 [kSourceCodecDecoders] 的 key。
///
/// 覆盖 `getSourceFormat().codec` 的现有取值，同时容忍大小写与常见别名
/// （`E-AC3` / `EC3`、`OGG` / `VORBIS`、`MPEG` / `MP3` 等）。
String normalizeSourceCodec(String? codec) {
  final key = (codec ?? '').trim().toUpperCase();
  if (key.isEmpty) return '';
  switch (key) {
    case 'MP3':
    case 'MPEG':
    case 'MPEG-1':
    case 'MPEG-2':
    case 'MPEG-L3':
      return 'MP3';
    case 'AAC':
    case 'AAC-LC':
    case 'AACLC':
    case 'HE-AAC':
    case 'HE-AAC V1':
    case 'HE-AAC V2':
    case 'M4A':
      return 'AAC';
    case 'FLAC':
      return 'FLAC';
    case 'OPUS':
      return 'OPUS';
    case 'OGG':
    case 'OGG-VORBIS':
    case 'VORBIS':
      return 'OGG';
    case 'ALAC':
    case 'APPLE LOSSLESS':
      return 'ALAC';
    case 'APE':
    case 'MONKEY':
      return 'APE';
    case 'WAV':
    case 'WAVE':
    case 'PCM':
      return 'WAV';
    case 'AC3':
    case 'AC-3':
      return 'AC3';
    case 'EAC3':
    case 'E-AC3':
    case 'EC3':
    case 'EC-3':
      return 'EAC3';
    case 'AMR':
    case 'AMR-NB':
    case 'AMR-WB':
      return 'AMR';
    case 'DSD':
    case 'DSF':
    case 'DFF':
      return 'DSD';
    case 'DTS':
      return 'DTS';
    default:
      return key;
  }
}

/// 原生编码名 / MIME / MediaCodec 组件名 → UI 用的可读短名。
///
/// 例：`audio/mpeg` → `MP3`、`mp4a.40.5` → `HE-AAC v1`、
/// `c2.android.flac.decoder` → `FLAC`。识别不了时尽量剥掉组件名装饰
/// （`c2.` / `omx.` / `.decoder`）后大写返回，绝不返回空串之外的猜测。
String audioCodecShortName(String? encodingName, [int encoding = 0]) {
  final raw = (encodingName ?? '').trim();
  if (raw.isEmpty) return _nameFromEncoding(encoding);
  final s = raw.toLowerCase();

  // 带变体的编码必须先判，否则会被下面的宽匹配吞掉（HE-AAC 含 "aac"）。
  if (s.contains('mpegh') || s.contains('mpeg-h')) return 'MPEG-H';
  if (s.contains('xhe') || s.contains('mp4a.40.42')) return 'AAC-xHE';
  if (s.contains('he-aac v2') ||
      s.contains('he_aac_v2') ||
      s.contains('heaacv2') ||
      s.contains('aac he v2') ||
      s.contains('aac-he-v2') ||
      s.contains('mp4a.40.29')) {
    return 'HE-AAC v2';
  }
  if (s.contains('he-aac') ||
      s.contains('he_aac') ||
      s.contains('heaac') ||
      s.contains('aac he') ||
      s.contains('aac-he') ||
      s.contains('mp4a.40.5')) {
    return 'HE-AAC v1';
  }
  if (s.contains('eld') || s.contains('mp4a.40.39')) return 'AAC-ELD';
  if (s.contains('ac-4') || s.contains('ac4')) return 'AC4';
  if (s.contains('eac3') ||
      s.contains('e-ac3') ||
      s.contains('eac-3') ||
      s.contains('ec-3')) {
    return 'E-AC3';
  }
  if (s.contains('ac3') || s.contains('ac-3') || s.contains('dolby.digital')) {
    return 'AC3';
  }
  if (s.contains('truehd')) return 'Dolby TrueHD';
  if (s.contains('dts')) return 'DTS';
  if (s.contains('alac') || s.contains('apple.lossless')) return 'ALAC';
  if (s.contains('flac')) return 'FLAC';
  if (s.contains('opus')) return 'OPUS';
  if (s.contains('vorbis')) return 'VORBIS';
  if (s.contains('amr-wb') || s.contains('amrwb') || s.contains('amr_wb')) {
    return 'AMR-WB';
  }
  if (s.contains('amr')) return 'AMR-NB';
  if (s.contains('aac') || s.contains('mp4a')) return 'AAC-LC';
  if (s.contains('mpeg-l2') || s.contains('layer 2') || s.contains('layer2')) {
    return 'MP2';
  }
  if (s.contains('mp3') || s.contains('mpeg')) return 'MP3';
  if (s.contains('pcm') || s.contains('raw') || s.contains('wav')) return 'PCM';
  if (s.contains('ape') || s.contains('monkey')) return 'APE';
  if (s.contains('dsd') || s.contains('dsf') || s.contains('dff')) return 'DSD';

  final cleaned = _cleanComponentName(raw);
  if (cleaned.isNotEmpty) return cleaned;
  return _nameFromEncoding(encoding);
}

/// `AudioFormat.ENCODING_*` → 可读短名（原生 `encodingName` 缺失时的兜底）。
String _nameFromEncoding(int encoding) {
  switch (encoding) {
    case 1:
      return 'PCM';
    case 2:
      return 'PCM 16-bit';
    case 3:
      return 'PCM 8-bit';
    case 4:
      return 'PCM float';
    case 5:
      return 'AC3';
    case 6:
      return 'E-AC3';
    case 7:
      return 'DTS';
    case 8:
      return 'DTS-HD';
    case 9:
      return 'MP3';
    case 10:
      return 'AAC-LC';
    case 11:
      return 'HE-AAC v1';
    case 12:
      return 'HE-AAC v2';
    case 13:
      return 'IEC61937';
    case 14:
      return 'Dolby TrueHD';
    case 15:
      return 'AAC-ELD';
    case 16:
      return 'AAC-xHE';
    case 17:
      return 'AC4';
    case 18:
      return 'E-AC3 JOC';
    case 19:
      return 'Dolby MAT';
    case 20:
      return 'OPUS';
    case 22:
      return 'MPEG2-TS';
    case 23:
    case 24:
    case 25:
    case 26:
      return 'MPEG-H';
    case 27:
    case 29:
    case 30:
      return 'DTS';
    case 28:
      return 'DRA';
    default:
      return encoding == 0 ? '' : '编码 $encoding';
  }
}

/// 剥掉 MediaCodec 组件名的装饰，剩下的部分大写后当短名。
String _cleanComponentName(String raw) {
  var s = raw;
  final lower = s.toLowerCase();
  if (lower.startsWith('audio/')) s = s.substring(6);
  s = s.replaceAll(RegExp(r'\.decoder$', caseSensitive: false), '');
  s = s.replaceAll(RegExp(r'\.encoder$', caseSensitive: false), '');
  s = s.replaceAll(RegExp(r'^(c2|omx)\.', caseSensitive: false), '');
  return s.trim().toUpperCase();
}

// ── 类型容错解析（原生 map / JSON 都可能给 string / num）───────��───────

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? 0;
  return 0;
}

bool _asBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final s = value.trim().toLowerCase();
    return s == 'true' || s == '1' || s == 'yes';
  }
  return false;
}

/// 解析探测时刻：ISO 字符串（Dart 自己写的）或 epoch（原生 Kotlin 的毫秒）。
DateTime _asDateTime(Object? value) {
  if (value is DateTime) return value;
  if (value is num) return _epochToDateTime(value.toInt());
  if (value is String) {
    final direct = DateTime.tryParse(value.trim());
    if (direct != null) return direct;
    final epoch = int.tryParse(value.trim());
    if (epoch != null) return _epochToDateTime(epoch);
  }
  return DateTime.fromMillisecondsSinceEpoch(0);
}

DateTime _epochToDateTime(int value) {
  // 原生若给秒（< 1e12）则补成毫秒；毫秒原样使用。
  if (value <= 0) return DateTime.fromMillisecondsSinceEpoch(0);
  if (value < 1000000000000) return DateTime.fromMillisecondsSinceEpoch(value * 1000);
  return DateTime.fromMillisecondsSinceEpoch(value);
}
