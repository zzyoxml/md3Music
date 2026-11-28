/// 设备解码器能力（`MediaCodec` 枚举结果）的**强类型模型 + 本地缓存**。
///
/// 数据来源：原生通道 `com.md3music.md3music/audio_offload` 的两个方法 ——
/// `probeDecoderCapabilities`（触发一次后台探测后返回快照）与
/// `getCachedDecoderCapabilities`（只读原生存量缓存，可能为 null）。
///
/// 与 `audio_offload_capabilities.dart` 是**两个独立数据源**：
/// - 那边回答「当前输出通路能不能把整段音频交给系统直通（offload）」；
/// - 这边回答「这台设备上装了哪些解码器、各自支持什么采样率 / 声道 / 位深」。
///
/// 本文件只做三件事：原生 map ↔ 强类型模型、按编码聚合成设置页矩阵、按设备指纹
/// / 7 天时效判断缓存是否可信。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 位深支持的三态。
///
/// **三态是硬约定**：`unknown`（没探测 / 该解码器没给出信息）绝不能塌成
/// `unsupported`，否则设置页会把「没测」显示成「不支持」，用户会误以为设备不行。
enum DecoderBitDepthSupport {
  /// 探测确认支持。
  supported,

  /// 探测确认不支持。
  unsupported,

  /// 没探测到 / 探测失败 / 原生未给出该维度信息。
  unknown,
}

/// 位深维度（对应原生 `bitDepths` 的键）。
enum DecoderBitDepth {
  /// 16 bit 整型。
  bit16,

  /// 24 bit 整型。
  bit24,

  /// 32 bit 整型。
  bit32,

  /// 32 bit 浮点。
  float,
}

/// 原生 `bitDepths` 的键 → 枚举（键名是固定契约，不要改名）。
const Map<String, DecoderBitDepth> _kBitDepthKeys =
    <String, DecoderBitDepth>{
      '16': DecoderBitDepth.bit16,
      '24': DecoderBitDepth.bit24,
      '32': DecoderBitDepth.bit32,
      'float': DecoderBitDepth.float,
    };

/// 枚举 → 原生 `bitDepths` 的键（[AudioDecoderCapability.toMap] 用）。
String _bitDepthKey(DecoderBitDepth depth) {
  switch (depth) {
    case DecoderBitDepth.bit16:
      return '16';
    case DecoderBitDepth.bit24:
      return '24';
    case DecoderBitDepth.bit32:
      return '32';
    case DecoderBitDepth.float:
      return 'float';
  }
}

/// 三态字符串解析：`supported` / `unsupported` / `unknown`。
///
/// 缺失键、未知取值（原生版本新增档位）一律按 `unknown` 处理 —— 宁可不显示，
/// 也不谎报。
DecoderBitDepthSupport _parseBitDepthSupport(Object? value) {
  switch ((value ?? '').toString().trim().toLowerCase()) {
    case 'supported':
      return DecoderBitDepthSupport.supported;
    case 'unsupported':
      return DecoderBitDepthSupport.unsupported;
    default:
      return DecoderBitDepthSupport.unknown;
  }
}

/// 三态枚举 → 原生字符串（[AudioDecoderCapability.toMap] 用）。
String _bitDepthSupportName(DecoderBitDepthSupport support) {
  switch (support) {
    case DecoderBitDepthSupport.supported:
      return 'supported';
    case DecoderBitDepthSupport.unsupported:
      return 'unsupported';
    case DecoderBitDepthSupport.unknown:
      return 'unknown';
  }
}

/// 单个解码器的能力条目（一台设备上通常有 10~30 条）。
@immutable
class AudioDecoderCapability {
  AudioDecoderCapability({
    required this.codecName,
    required this.mime,
    required this.formatLabel,
    required this.hardware,
    required this.softwareOnly,
    required List<int> sampleRates,
    this.maxChannels = 0,
    required Map<DecoderBitDepth, DecoderBitDepthSupport> bitDepths,
    this.bitDepthProbed = false,
  }) : sampleRates = List<int>.unmodifiable(_normalizeSampleRates(sampleRates)),
       bitDepths =
           Map<DecoderBitDepth, DecoderBitDepthSupport>.unmodifiable(bitDepths);

  /// MediaCodec 组件名，如 `c2.qti.mp3.decoder`。
  final String codecName;

  /// MIME 类型，如 `audio/mpeg`。
  final String mime;

  /// UI 用的可读格式名，如 `MP3` / `AAC` / `HE-AAC`（聚合键就是它）。
  final String formatLabel;

  /// 是否是硬件解码器（原生按 `isHardwareAccelerated` 判定）。
  final bool hardware;

  /// 是否仅软件实现（`softwareOnly`）。
  final bool softwareOnly;

  /// 支持的采样率（升序、去重；非法值已剔除）。
  final List<int> sampleRates;

  /// 最大声道数；`0` 表示未知。
  final int maxChannels;

  /// 各维度位深的三态支持情况（缺项按 [DecoderBitDepthSupport.unknown]）。
  final Map<DecoderBitDepth, DecoderBitDepthSupport> bitDepths;

  /// 位深是否真的做过探测（false 表示 [bitDepths] 基本是 unknown）。
  final bool bitDepthProbed;

  /// 取某位深的三态结果；表里没有该项时按 `unknown`。
  DecoderBitDepthSupport bitDepth(DecoderBitDepth depth) =>
      bitDepths[depth] ?? DecoderBitDepthSupport.unknown;

  /// 是否可作为硬件解码器使用：标了硬件 **且** 不是纯软实现。
  ///
  /// 原生个别编码（例如某些厂商的 "hw" 组件）会同时给 `hardware=true` 与
  /// `softwareOnly=true`，这种组合按软解处理。
  bool get isHardware => hardware && !softwareOnly;

  factory AudioDecoderCapability.fromMap(Map<String, dynamic> m) {
    final rawRates = m['sampleRates'];
    final rates = <int>[];
    if (rawRates is List) {
      for (final item in rawRates) {
        rates.add(_asInt(item));
      }
    }
    final rawDepths = m['bitDepths'];
    final depths = <DecoderBitDepth, DecoderBitDepthSupport>{};
    if (rawDepths is Map) {
      rawDepths.forEach((dynamic key, dynamic value) {
        final String name = (key ?? '').toString().trim().toLowerCase();
        final DecoderBitDepth? depth = _kBitDepthKeys[name];
        // 未知键忽略：向前兼容原生将来新增的位深档位，不污染现有矩阵。
        if (depth == null) return;
        depths[depth] = _parseBitDepthSupport(value);
      });
    }
    final int channels = _asInt(m['maxChannels']);
    return AudioDecoderCapability(
      codecName: (m['codecName'] ?? '').toString(),
      mime: (m['mime'] ?? '').toString(),
      formatLabel: (m['formatLabel'] ?? '').toString(),
      hardware: _asBool(m['hardware']),
      softwareOnly: _asBool(m['softwareOnly']),
      sampleRates: rates,
      maxChannels: channels < 0 ? 0 : channels,
      bitDepths: depths,
      bitDepthProbed: _asBool(m['bitDepthProbed']),
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'codecName': codecName,
      'mime': mime,
      'formatLabel': formatLabel,
      'hardware': hardware,
      'softwareOnly': softwareOnly,
      'sampleRates': sampleRates,
      'maxChannels': maxChannels,
      // 四个档位全部写回（缺项补 unknown），保证「缓存 → 复读」后三态不丢语义。
      'bitDepths': <String, String>{
        for (final DecoderBitDepth depth in DecoderBitDepth.values)
          _bitDepthKey(depth): _bitDepthSupportName(bitDepth(depth)),
      },
      'bitDepthProbed': bitDepthProbed,
    };
  }

  @override
  String toString() =>
      'AudioDecoderCapability($codecName $formatLabel hardware=$hardware '
      'softwareOnly=$softwareOnly rates=$sampleRates ch=$maxChannels '
      'bitDepthProbed=$bitDepthProbed)';
}

/// 按格式聚合后的能力（设置页一行 / 预测用的并集）。
@immutable
class AudioDecoderFormatCapability {
  AudioDecoderFormatCapability({
    required this.formatLabel,
    required this.mime,
    required this.hasHardware,
    required List<String> codecNames,
    required List<int> sampleRates,
    this.maxChannels = 0,
    required Map<DecoderBitDepth, DecoderBitDepthSupport> bitDepths,
  }) : codecNames = List<String>.unmodifiable(codecNames),
       sampleRates = List<int>.unmodifiable(sampleRates),
       bitDepths =
           Map<DecoderBitDepth, DecoderBitDepthSupport>.unmodifiable(bitDepths);

  /// 聚合键（原生 `formatLabel`，空白归到「未知」）。
  final String formatLabel;

  /// 该格式的代表 MIME（取并集中的第一个非空值）。
  final String mime;

  /// 该格式是否存在硬件解码器。
  final bool hasHardware;

  /// 参与聚合的解码器组件名（去重，保持原生顺序）。
  final List<String> codecNames;

  /// 参与聚合的解码器采样率并集（升序、去重）。
  final List<int> sampleRates;

  /// 参与聚合的解码器最大声道数；`0` 表示未知。
  final int maxChannels;

  /// 逐位深取优后的三态结果（`supported` > `unknown` > `unsupported`）。
  final Map<DecoderBitDepth, DecoderBitDepthSupport> bitDepths;

  @override
  String toString() =>
      'AudioDecoderFormatCapability($formatLabel hardware=$hasHardware '
      'codecs=${codecNames.length} rates=$sampleRates ch=$maxChannels)';
}

/// 一台设备一次探测的完整快照。
@immutable
class AudioDecoderCapabilitySnapshot {
  AudioDecoderCapabilitySnapshot({
    required this.deviceKey,
    required this.probedAt,
    required this.sdkInt,
    this.probeCostMs = 0,
    this.probeError,
    required List<AudioDecoderCapability> entries,
    List<String> notes = const <String>[],
  }) : entries = List<AudioDecoderCapability>.unmodifiable(entries),
       notes = List<String>.unmodifiable(notes);

  /// 设备指纹（原生给，形如 `xiaomi|23127PN0CC|fuxi|android-34`）。
  final String deviceKey;

  /// 探测完成时刻。
  final DateTime probedAt;

  /// `Build.VERSION.SDK_INT`。
  final int sdkInt;

  /// 一次探测的耗时（毫秒），用于诊断「探测是不是拖慢了启动」。
  final int probeCostMs;

  /// 整体不可用时的中文原因；null 表示探测正常完成。
  final String? probeError;

  /// 全部解码器条目（按原生顺序，UI 自行分组）。
  final List<AudioDecoderCapability> entries;

  /// 原生备注（例如「APE 无系统解码器，只能软解」），UI 原样展示。
  final List<String> notes;

  /// 惰性聚合缓存（快照不可变，可安全缓存一份）。
  late final Map<String, AudioDecoderFormatCapability> _byFormat =
      _buildByFormat();

  /// 按 `formatLabel` 聚合：编码 → 硬件优先的并集。
  ///
  /// 聚合规则（与设置页矩阵、[AudioDecoderCapabilitySnapshot.formatFor] 共用）：
  /// - 采样率 / 声道 / 位深取「硬件解码器的并集」——只有硬件解码器的能力才回答
  ///   「这台设备能不能硬解这个格式」；
  /// - 该格式**一个硬件解码器都没有**时退回全部条目，并置 `hasHardware=false`，
  ///   UI 据此显示「仅软解」，而不是让这一行凭空消失；
  /// - 声道取参与聚合条目的最大值，`0`（未知）不参与比较；
  /// - 位深逐档取优：`supported` > `unknown` > `unsupported`。
  Map<String, AudioDecoderFormatCapability> get byFormat => _byFormat;

  Map<String, AudioDecoderFormatCapability> _buildByFormat() {
    final Map<String, List<AudioDecoderCapability>> grouped =
        <String, List<AudioDecoderCapability>>{};
    for (final entry in entries) {
      final String label = entry.formatLabel.trim().isEmpty
          ? '未知'
          : entry.formatLabel.trim();
      (grouped[label] ??= <AudioDecoderCapability>[]).add(entry);
    }
    final List<String> labels = grouped.keys.toList()
      ..sort((String a, String b) {
        final int byRank = _formatRank(a).compareTo(_formatRank(b));
        // 同一档（多个「其它」格式）用字母序兜底，保证每次重建顺序稳定。
        return byRank != 0 ? byRank : a.compareTo(b);
      });
    final Map<String, AudioDecoderFormatCapability> result =
        <String, AudioDecoderFormatCapability>{};
    for (final label in labels) {
      result[label] = _aggregateFormat(label, grouped[label]!);
    }
    return Map<String, AudioDecoderFormatCapability>.unmodifiable(result);
  }

  AudioDecoderFormatCapability _aggregateFormat(
    String label,
    List<AudioDecoderCapability> all,
  ) {
    final List<AudioDecoderCapability> hardwareEntries = all
        .where((AudioDecoderCapability e) => e.isHardware)
        .toList(growable: false);
    final List<AudioDecoderCapability> pool =
        hardwareEntries.isNotEmpty ? hardwareEntries : all;

    final List<String> codecNames = <String>[];
    final Set<int> rates = <int>{};
    int maxChannels = 0;
    String mime = '';
    // 初始 unsupported 只是取优的零元：unknown(1) / supported(2) 都会覆盖它；
    // pool 至少一条，逐条取优后一定得到真实结果。
    final Map<DecoderBitDepth, DecoderBitDepthSupport> depths =
        <DecoderBitDepth, DecoderBitDepthSupport>{
          for (final DecoderBitDepth depth in DecoderBitDepth.values)
            depth: DecoderBitDepthSupport.unsupported,
        };
    for (final entry in pool) {
      if (entry.codecName.isNotEmpty && !codecNames.contains(entry.codecName)) {
        codecNames.add(entry.codecName);
      }
      rates.addAll(entry.sampleRates);
      if (entry.maxChannels > maxChannels) maxChannels = entry.maxChannels;
      if (mime.isEmpty && entry.mime.isNotEmpty) mime = entry.mime;
      for (final DecoderBitDepth depth in DecoderBitDepth.values) {
        depths[depth] = _betterBitDepth(depths[depth]!, entry.bitDepth(depth));
      }
    }
    final List<int> sortedRates = rates.where((int r) => r > 0).toList()
      ..sort();

    return AudioDecoderFormatCapability(
      formatLabel: label,
      mime: mime,
      hasHardware: hardwareEntries.isNotEmpty,
      codecNames: codecNames,
      sampleRates: sortedRates,
      maxChannels: maxChannels,
      bitDepths: depths,
    );
  }

  /// 按编码短名命中聚合结果。
  ///
  /// 归一后比较**编码家族**（见 [_decoderFormatFamily]），因此 `AAC-LC`、
  /// `mp4a.40.5` 之类的细分写法也能命中 `AAC` 行；`OGG` 容器同时尝试
  /// `VORBIS` / `OPUS`。
  ///
  /// 返回 null 表示这台设备上没探测到这个格式 —— 调用方必须按「不知道」处理，
  /// 不能当成「不支持」。
  AudioDecoderFormatCapability? formatFor(String? codec) {
    final List<String> candidates = _decoderFormatCandidates(codec);
    if (candidates.isEmpty) return null;
    for (final candidate in candidates) {
      for (final entry in byFormat.entries) {
        if (_formatFamilySet(entry.key).contains(candidate)) return entry.value;
      }
    }
    return null;
  }

  factory AudioDecoderCapabilitySnapshot.fromMap(Map<String, dynamic> m) {
    final rawEntries = m['entries'];
    final List<AudioDecoderCapability> entries = <AudioDecoderCapability>[];
    if (rawEntries is List) {
      for (final item in rawEntries) {
        if (item is Map) {
          entries.add(
            AudioDecoderCapability.fromMap(Map<String, dynamic>.from(item)),
          );
        }
      }
    }
    final rawNotes = m['notes'];
    final List<String> notes = <String>[];
    if (rawNotes is List) {
      for (final item in rawNotes) {
        final String text = item?.toString().trim() ?? '';
        if (text.isNotEmpty) notes.add(text);
      }
    }
    final dynamic rawError = m['probeError'];
    return AudioDecoderCapabilitySnapshot(
      deviceKey: (m['deviceKey'] ?? '').toString(),
      // 原生快照用 `probedAtMs`（epoch 毫秒），本地缓存用 `probedAt`（ISO 8601）。
      // 两个键都必须认，否则缓存复读时探测时间会退回 1970 年、被判成过期。
      probedAt: _asDateTime(m['probedAt'] ?? m['probedAtMs']),
      sdkInt: _asInt(m['sdkInt']),
      probeCostMs: _asInt(m['probeCostMs']),
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
      // 契约：缓存里 probedAt 写 ISO 8601（本地可读、跨时区不歧义）。
      'probedAt': probedAt.toIso8601String(),
      'sdkInt': sdkInt,
      'probeCostMs': probeCostMs,
      'probeError': probeError,
      'entries': entries
          .map((AudioDecoderCapability e) => e.toMap())
          .toList(growable: false),
      'notes': notes,
    };
  }

  /// 是否没有任何解码器条目（= 不可用，UI 应显示空态而不是空表格）。
  bool get isEmpty => entries.isEmpty;

  /// 硬件解码器条目数。
  int get hardwareCodecCount =>
      entries.where((AudioDecoderCapability e) => e.isHardware).length;

  /// 有硬件解码器的格式数（设置页「N 个格式可硬解」）。
  int get supportedFormatCount => byFormat.values
      .where((AudioDecoderFormatCapability f) => f.hasHardware)
      .length;

  /// 探测到的格式总数（含仅软解的格式）。
  ///
  /// 移动平台音频解码普遍不经 MediaCodec 硬件路径（走 DSP/offload），
  /// 大量设备 `supportedFormatCount == 0` 属正常；摘要同时展示本值，
  /// 避免用户把「0 种」误读成「设备什么都放不了」。
  int get formatCount => byFormat.length;

  @override
  String toString() =>
      'AudioDecoderCapabilitySnapshot(device=$deviceKey sdk=$sdkInt '
      'entries=${entries.length} hardware=$hardwareCodecCount '
      'formats=${byFormat.length} cost=${probeCostMs}ms '
      'probedAt=${probedAt.toIso8601String()}'
      '${probeError == null ? '' : ' error=$probeError'})';
}

/// 解码器能力快照的 `SharedPreferences` 缓存。
///
/// 与 `AudioOffloadCapabilityStore` 同构：只缓存序列化文本 + 设备指纹两个键，
/// 快照结构升级时改 [keyJson] 版本号即可，不需要写迁移逻辑。
class AudioDecoderCapabilityStore {
  AudioDecoderCapabilityStore({this.currentDeviceKey});

  /// 快照 JSON 的持久化键（结构变更时升版本号）。
  static const String keyJson = 'audio_decoder_caps_v1';

  /// 快照所属设备的指纹键。
  static const String keyDevice = 'audio_decoder_caps_device_v1';

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
  /// 但 [stale] 会置 true，由调用方决定是否后台重新探测。
  Future<AudioDecoderCapabilitySnapshot?> load() async {
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
      final snapshot = AudioDecoderCapabilitySnapshot.fromMap(
        Map<String, dynamic>.from(decoded),
      );

      final String? expected = currentDeviceKey;
      if (expected != null && expected.isNotEmpty) {
        final stored = prefs.getString(keyDevice);
        final String cachedKey = (stored != null && stored.isNotEmpty)
            ? stored
            : snapshot.deviceKey;
        if (cachedKey != expected) _stale = true;
      }
      if (DateTime.now().difference(snapshot.probedAt) > maxAge) _stale = true;
      return snapshot;
    } catch (e) {
      debugPrint('[AudioDecoderCap] 读取解码器能力缓存失败: $e');
      _stale = true;
      return null;
    }
  }

  /// 写入缓存（同时记录快照自带的设备指纹）。
  Future<void> save(AudioDecoderCapabilitySnapshot snapshot) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(keyJson, jsonEncode(snapshot.toMap()));
      await prefs.setString(keyDevice, snapshot.deviceKey);
      _stale = false;
    } catch (e) {
      debugPrint('[AudioDecoderCap] 写入解码器能力缓存失败: $e');
    }
  }

  /// 清空缓存（设置重置 / 排障用；正常探测成功后不需要）。
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(keyJson);
      await prefs.remove(keyDevice);
      _stale = true;
    } catch (e) {
      debugPrint('[AudioDecoderCap] 清空解码器能力缓存失败: $e');
    }
  }
}

// ── 编码家族归一 ─────────────────────────────────────────────────────

/// `byFormat` 的固定展示顺序：MP3 → AAC → HE-AAC → FLAC → ALAC → OPUS →
/// VORBIS → AC3 → E-AC3 → 其它（按字母）。
///
/// 与既有「硬件解码播放」能力页的编码顺序保持一致（那边在
/// `audio_offload_capability_view.dart` 的 `_encodingRank` 里实现；此处把顺序
/// 落在模型层，供 UI 直接按 [AudioDecoderCapabilitySnapshot.byFormat] 的插入顺序
/// 渲染，不必重复排序）。
const List<String> _kFormatOrder = <String>[
  'MP3',
  'AAC',
  'HE-AAC',
  'FLAC',
  'ALAC',
  'OPUS',
  'VORBIS',
  'AC3',
  'E-AC3',
];

/// 排序档位：已列出的编码按 [_kFormatOrder] 顺序，其它一律排最后。
int _formatRank(String label) {
  final String family = _decoderFormatFamily(label);
  // OGG 是 VORBIS 的常见容器标签（原生按 mime 打标）：与 VORBIS 同档，
  // 档内再按字母序，避免它掉到「其它」里。
  if (family == 'OGG') return _kFormatOrder.indexOf('VORBIS');
  final int index = _kFormatOrder.indexOf(family);
  return index < 0 ? 100 : index;
}

/// 编码名 → 编码家族（`MP3` / `AAC` / `HE-AAC` / `FLAC` / …）。
///
/// 归一化（去掉空格 / 下划线 / 连字符 / 点 / 斜杠后大写）再做包含匹配，
/// 兼容 `AAC-LC`、`HE-AAC v1`、`c2.qti.mp3.decoder`、`audio/mpeg` 等写法。
/// 识别不了的原样返回归一化文本（调用方按字符串相等兜底比较）。
String _decoderFormatFamily(String? label) {
  final String t = (label ?? '')
      .trim()
      .toUpperCase()
      .replaceAll(RegExp(r'[\s_\-/.]'), '');
  if (t.isEmpty) return '';
  // E-AC3 必须先于 AC3 判断（名字里包含 AC3）。
  if (t.contains('EAC3') || t.contains('EC3')) return 'E-AC3';
  if (t.contains('AC3')) return 'AC3';
  // HE-AAC / xHE-AAC 必须先于 AAC 判断（变体名里同样含 AAC）。
  if (t.contains('HEAAC') || t.contains('AACHE') || t.contains('XHE')) {
    return 'HE-AAC';
  }
  if (t.contains('AAC')) return 'AAC';
  if (t.contains('MP3')) return 'MP3';
  if (t.contains('FLAC')) return 'FLAC';
  if (t.contains('ALAC')) return 'ALAC';
  if (t.contains('OPUS')) return 'OPUS';
  if (t.contains('VORBIS')) return 'VORBIS';
  if (t.contains('DTS')) return 'DTS';
  if (t.contains('AMR')) return 'AMR';
  if (t.contains('PCM') || t.contains('WAV')) return 'PCM';
  if (t.contains('APE') || t.contains('MONKEY')) return 'APE';
  if (t.contains('DSD')) return 'DSD';
  return t;
}

/// 源编码短名 → 候选编码家族（按优先级）。
///
/// `OGG` 是容器：里面既可能是 VORBIS 也可能是 OPUS，两个都算候选。
List<String> _decoderFormatCandidates(String? codec) {
  final Set<String> families = _formatFamilySet(codec);
  if (families.isEmpty) return const <String>[];
  return families.toList(growable: false);
}

/// 编码名 → 家族集合。
///
/// `OGG` 展开成 VORBIS / OPUS 两个家族，这样「编码是 OGG、聚合行是 VORBIS」
/// 与反过来的组合都能互相命中。
Set<String> _formatFamilySet(String? label) {
  final String family = _decoderFormatFamily(label);
  if (family.isEmpty) return const <String>{};
  if (family == 'OGG') return const <String>{'VORBIS', 'OPUS'};
  return <String>{family};
}

/// 位深取优：`supported` > `unknown` > `unsupported`。
DecoderBitDepthSupport _betterBitDepth(
  DecoderBitDepthSupport a,
  DecoderBitDepthSupport b,
) => _bitDepthRank(b) > _bitDepthRank(a) ? b : a;

int _bitDepthRank(DecoderBitDepthSupport support) {
  switch (support) {
    case DecoderBitDepthSupport.supported:
      return 2;
    case DecoderBitDepthSupport.unknown:
      return 1;
    case DecoderBitDepthSupport.unsupported:
      return 0;
  }
}

// ── 类型容错解析（原生 map / JSON 都可能给 string / num）─────────

List<int> _normalizeSampleRates(Iterable<int> raw) {
  final Set<int> set = <int>{};
  for (final int rate in raw) {
    if (rate > 0) set.add(rate);
  }
  return set.toList()..sort();
}

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
  if (value < 1000000000000) {
    return DateTime.fromMillisecondsSinceEpoch(value * 1000);
  }
  return DateTime.fromMillisecondsSinceEpoch(value);
}
