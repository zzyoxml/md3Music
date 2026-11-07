import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';

import '../data/models/song.dart';

/// 歌曲更多菜单头部的信息徽章：时长 / 最高音质 / 文件大小 / VIP 要求。
///
/// 数据获取对齐 EchoMusic：在线歌曲打开菜单时查 `/privilege/lite`
/// （relate_goods 推最高音质、quality_vip 的 size_text 取文件大小、
/// 歌级 privilege+pay_type 判 VIP 要求），30s TTL + LRU 缓存；
/// 本地歌曲不发请求，时长/音质/大小直接来自本地文件信息。
///
/// fetcher 由调用方注入（本组件不依赖 Provider），null 时不发请求，
/// 只显示即时可得的数据——既有 SongMenuHeader 测试 harness 不受影响。

/// 拉取 privilege/lite 原始响应；返回 null/抛异常都按「获取失败」静默处理。
typedef SongMenuInfoFetcher =
    Future<Map<String, dynamic>?> Function(String hash, String? albumId);

/// 从菜单徽章视角看到的歌曲信息摘要。
class SongMenuInfo {
  /// 最高可用音质标签（母带/全景声/超清/Hi-Res/SQ/HQ…）。
  final String? qualityLabel;

  /// 文件大小展示文本（如 "31.2M"，上游 size_text 原样或本地字节换算）。
  final String? sizeText;

  /// VIP 要求标签（VIP/付费/需超级VIP/无版权/不可用），免费歌曲为 null。
  final String? vipLabel;

  /// 时长秒数（song.duration 为 0 时用接口 audio_info.duration 兜底）。
  final int? durationSeconds;

  const SongMenuInfo({
    this.qualityLabel,
    this.sizeText,
    this.vipLabel,
    this.durationSeconds,
  });
}

/// 音质代号 → 徽章标签（顺序即档位高低，取第一个命中即最高档）。
/// 与 EchoMusic utils/song.ts 的 QUALITY_LABEL_MAP 对齐，viper_tape 补在最前。
const List<(String, String)> _kQualityOrder = [
  ('viper_tape', '母带'),
  ('viper_atmos', '全景声'),
  ('viper_clear', '超清'),
  ('high', 'Hi-Res'),
  ('flac', 'SQ'),
  ('320', 'HQ'),
];

/// 本地歌曲音质 → 标签（与 player_provider.currentQualityLabel 本地口径一致）。
String? localQualityLabel(String? quality) {
  switch (quality) {
    case '128':
      return '标准';
    case '320':
      return '高音质';
    case 'flac':
      return '无损';
    case 'high':
      return 'Hi-Res';
    default:
      return null;
  }
}

/// 字节数 → 展示文本；size_text 缺失时对 audio_info.filesize_* 兜底换算。
String formatFileSize(int bytes) {
  if (bytes <= 0) return '';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)}KB';
  if (bytes < 1024 * 1024 * 1024) {
    final mb = bytes / (1024 * 1024);
    return mb >= 100 ? '${mb.toStringAsFixed(0)}MB' : '${mb.toStringAsFixed(1)}MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
}

Map<String, dynamic>? _recordOf(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((k, v) => MapEntry(k.toString(), v));
  }
  return null;
}

int? _intOf(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) {
    final parsed = int.tryParse(value.trim());
    if (parsed != null) return parsed;
    final doubleParsed = double.tryParse(value.trim());
    if (doubleParsed != null) return doubleParsed.toInt();
  }
  return null;
}

bool _flag(dynamic value) => value == true || value == 1 || value == '1';

/// 时长归一化：与 kugou_models._normalizeDuration 同口径，>10000 视为毫秒。
int? _normalizeDurationSeconds(dynamic value) {
  final raw = _intOf(value);
  if (raw == null || raw <= 0) return null;
  return raw > 10000 ? raw ~/ 1000 : raw;
}

/// 解析 /privilege/lite 响应（结构对齐 EchoMusic SongDetail.vue：
/// data[0] 为歌曲记录，relate_goods/privilege/pay_type/audio_info 在其中；
/// quality_vip 是响应顶层、与 data 平级的逐音质权益数组）。
///
/// 失败（status!=1、data 为空、结构不符）返回 null，调用方静默省略徽章。
SongMenuInfo? parsePrivilegeLiteResponse(Map<String, dynamic>? resp, String hash) {
  if (resp == null) return null;
  if (_intOf(resp['status']) != 1) return null;
  final dataList = resp['data'];
  if (dataList is! List || dataList.isEmpty) return null;
  final record = _recordOf(dataList.first);
  if (record == null || record.isEmpty) return null;

  // ---- 最高音质：relate_goods 里按档位顺序取第一个命中的 ----
  String? qualityLabel;
  final relateGoods = record['relate_goods'];
  if (relateGoods is List) {
    final qualities = <String>{};
    for (final item in relateGoods) {
      final goods = _recordOf(item);
      final quality = goods?['quality']?.toString();
      if (quality != null && quality.isNotEmpty) qualities.add(quality);
    }
    for (final (code, label) in _kQualityOrder) {
      if (qualities.contains(code)) {
        qualityLabel = label;
        break;
      }
    }
  }

  // ---- 文件大小 + 逐音质 VIP 细化：quality_vip 在响应顶层（与 data 平级，
  // EchoMusic parseSongQualityAccess 同款），按本歌曲 hash 匹配条目 ----
  Map<String, dynamic>? bestQualityEntry;
  final qualityVip = resp['quality_vip'];
  if (qualityVip is List) {
    final normalizedHash = hash.trim().toLowerCase();
    List<dynamic>? qualities;
    for (final item in qualityVip) {
      final entry = _recordOf(item);
      final entryHash = entry?['hash']?.toString().trim().toLowerCase();
      if (entryHash == normalizedHash) {
        final q = entry?['qualities'];
        if (q is List) qualities = q;
        break;
      }
    }
    if (qualities != null) {
      // 先按档位顺序找「存在且当前账号可获取」的最高档，退而求其次取存在的最高档
      final entries = <(String, Map<String, dynamic>)>[];
      for (final item in qualities) {
        final entry = _recordOf(item);
        final quality = entry?['quality']?.toString();
        if (entry == null || quality == null || !_flag(entry['exists'])) continue;
        entries.add((quality, entry));
      }
      String? bestCode;
      for (final (code, _) in _kQualityOrder) {
        final obtainable = entries.any(
          (e) => e.$1 == code && (_flag(e.$2['obtainable']) || _flag(e.$2['free_listen'])),
        );
        if (obtainable) {
          bestCode = code;
          break;
        }
      }
      bestCode ??= () {
        for (final (code, _) in _kQualityOrder) {
          if (entries.any((e) => e.$1 == code)) return code;
        }
        return null;
      }();
      if (bestCode != null) {
        bestQualityEntry = entries.firstWhere((e) => e.$1 == bestCode).$2;
      }
    }
  }

  var sizeText = bestQualityEntry?['size_text']?.toString().trim() ?? '';
  if (sizeText.isEmpty) {
    // size_text 缺失时按命中档位回退 audio_info.filesize_* 字节换算
    final audioInfo = _recordOf(record['audio_info']);
    if (audioInfo != null) {
      final chosenCode = bestQualityEntry?['quality']?.toString();
      final candidates = [
        if (chosenCode != null) 'filesize_$chosenCode',
        'filesize',
      ];
      for (final key in candidates) {
        final bytes = _intOf(audioInfo[key]);
        if (bytes != null && bytes > 0) {
          sizeText = formatFileSize(bytes);
          break;
        }
      }
    }
  }

  // ---- VIP 要求：歌级 privilege+pay_type 优先（EchoMusic isVipSong 同款）----
  String? vipLabel;
  final privilege = _intOf(record['privilege']);
  final payType = _intOf(record['pay_type'] ?? record['PayType'] ?? record['payType']);
  if (privilege == 10 && payType == 3) {
    vipLabel = 'VIP';
  } else if (privilege == 10 && payType == 2) {
    vipLabel = '付费';
  } else if (privilege == 5) {
    vipLabel = '无版权';
  } else if (privilege == 40) {
    vipLabel = '不可用';
  } else if (bestQualityEntry != null && _flag(bestQualityEntry['need_vip'])) {
    // 歌级没标 VIP 但最高档需要会员：按 require_vip_type 细化等级
    final requireType = bestQualityEntry['require_vip_type']?.toString().trim();
    switch (requireType) {
      case 'concept':
        vipLabel = '需概念版VIP';
      case 'suvip':
        vipLabel = '需超级VIP';
      default:
        vipLabel = '需VIP';
    }
  }

  // ---- 时长兜底（song.duration 已有则由组件直接用，不依赖这里）----
  // 字段优先序对齐 EchoMusic buildSongFromPrivilege：
  // audio_info.duration → audio_info.duration_128 → timelength → duration。
  final audioInfo = _recordOf(record['audio_info']);
  final durationSeconds = _normalizeDurationSeconds(
    audioInfo?['duration'] ??
        audioInfo?['duration_128'] ??
        record['timelength'] ??
        record['duration'],
  );

  if (qualityLabel == null && sizeText.isEmpty && vipLabel == null && durationSeconds == null) {
    return null;
  }
  return SongMenuInfo(
    qualityLabel: qualityLabel,
    sizeText: sizeText.isEmpty ? null : sizeText,
    vipLabel: vipLabel,
    durationSeconds: durationSeconds,
  );
}

/// privilege/lite 结果的进程内缓存：30s TTL + LRU 100 条
/// （对齐 EchoMusic songQualityAccess store 的 CACHE_TTL/CACHE_LIMIT）。
/// 失败结果（null）不缓存，下次打开菜单会重试——与 EchoMusic 一致。
class SongMenuInfoCache {
  static final SongMenuInfoCache instance = SongMenuInfoCache();

  static const int _kTtlMs = 30 * 1000;
  static const int _kLimit = 100;

  final LinkedHashMap<String, (int, SongMenuInfo?)> _entries = LinkedHashMap();

  String staticKey(String hash, String? albumId) =>
      '${hash.trim().toLowerCase()}|${albumId ?? ''}';

  SongMenuInfo? get(String hash, String? albumId) {
    final key = staticKey(hash, albumId);
    final entry = _entries.remove(key);
    if (entry == null) return null;
    final (atMs, info) = entry;
    if (DateTime.now().millisecondsSinceEpoch - atMs > _kTtlMs) return null;
    _entries[key] = entry; // 重插到队尾 = LRU touch
    return info;
  }

  void put(String hash, String? albumId, SongMenuInfo? info) {
    if (info == null) return; // 失败不占缓存位
    final key = staticKey(hash, albumId);
    _entries.remove(key);
    _entries[key] = (DateTime.now().millisecondsSinceEpoch, info);
    while (_entries.length > _kLimit) {
      _entries.remove(_entries.keys.first);
    }
  }
}

/// 菜单头部信息徽章行：时长 / 音质 / 文件大小 / VIP 要求。
class SongMenuInfoBadges extends StatefulWidget {
  final Song song;

  /// privilege/lite 拉取函数；null 时在线歌曲也不发请求（只显示即时数据）。
  final SongMenuInfoFetcher? fetcher;

  /// 默认用全局缓存；测试可注入独立实例。
  final SongMenuInfoCache? cache;

  const SongMenuInfoBadges({
    super.key,
    required this.song,
    this.fetcher,
    this.cache,
  });

  @override
  State<SongMenuInfoBadges> createState() => _SongMenuInfoBadgesState();
}

class _SongMenuInfoBadgesState extends State<SongMenuInfoBadges> {
  SongMenuInfo? _info;
  bool _loading = false;
  bool _localSizeLoaded = false;

  bool get _wantsRemoteInfo =>
      widget.song.isOnline &&
      widget.song.id.trim().isNotEmpty &&
      widget.fetcher != null;

  @override
  void initState() {
    super.initState();
    _loadRemoteInfo();
    _loadLocalSize();
  }

  @override
  void didUpdateWidget(SongMenuInfoBadges oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.song.id != oldWidget.song.id ||
        widget.fetcher != oldWidget.fetcher) {
      _info = null;
      _loading = false;
      _localSizeLoaded = false;
      _loadRemoteInfo();
      _loadLocalSize();
    }
  }

  Future<void> _loadRemoteInfo() async {
    if (!_wantsRemoteInfo) return;
    final hash = widget.song.id.trim();
    final albumId = widget.song.albumId;
    final cache = widget.cache ?? SongMenuInfoCache.instance;
    final cached = cache.get(hash, albumId);
    if (cached != null) {
      setState(() {
        _info = cached;
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final resp = await widget.fetcher!(hash, albumId);
      final info = parsePrivilegeLiteResponse(resp, hash);
      cache.put(hash, albumId, info);
      if (!mounted) return;
      setState(() {
        _info = info;
        _loading = false;
      });
    } catch (_) {
      // 静默失败：徽章省略，不打断菜单。
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  /// 本地歌曲文件大小：异步 stat，完成后并入徽章数据。
  Future<void> _loadLocalSize() async {
    if (widget.song.isOnline || _localSizeLoaded) return;
    final path = widget.song.localPath;
    if (path == null || path.isEmpty) return;
    _localSizeLoaded = true;
    try {
      final stat = await File(path).stat();
      if (!mounted || stat.type != FileSystemEntityType.file) return;
      final text = formatFileSize(stat.size);
      if (text.isEmpty) return;
      setState(() {
        _info = SongMenuInfo(
          qualityLabel: _info?.qualityLabel ?? localQualityLabel(widget.song.quality),
          sizeText: text,
          vipLabel: _info?.vipLabel,
          durationSeconds: _info?.durationSeconds,
        );
      });
    } catch (_) {
      // 文件不可读：省略大小徽章。
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final song = widget.song;

    final chips = <Widget>[];

    // 时长：本地歌曲即时可得；在线歌曲 song.duration 优先，接口值兜底。
    final durationSeconds = song.duration.inSeconds > 0
        ? song.duration.inSeconds
        : _info?.durationSeconds;
    if (durationSeconds != null && durationSeconds > 0) {
      final mm = (durationSeconds ~/ 60).toString().padLeft(2, '0');
      final ss = (durationSeconds % 60).toString().padLeft(2, '0');
      chips.add(
        _buildChip(
          context,
          '$mm:$ss',
          background: colorScheme.surfaceContainerHighest,
          foreground: colorScheme.onSurfaceVariant,
        ),
      );
    }

    // 音质：本地即时推断；在线用接口结果。
    final qualityLabel =
        song.isOnline ? _info?.qualityLabel : localQualityLabel(song.quality);
    if (qualityLabel != null) {
      chips.add(
        _buildChip(
          context,
          qualityLabel,
          background: colorScheme.secondaryContainer,
          foreground: colorScheme.onSecondaryContainer,
          bold: true,
        ),
      );
    }

    // 文件大小：本地歌曲来自 stat，在线来自 size_text / filesize 兜底。
    final sizeText = _info?.sizeText;
    if (sizeText != null) {
      chips.add(
        _buildChip(
          context,
          sizeText,
          background: colorScheme.surfaceContainerHighest,
          foreground: colorScheme.onSurfaceVariant,
        ),
      );
    }

    // VIP 要求：仅在线歌曲。
    final vipLabel = song.isOnline ? _info?.vipLabel : null;
    if (vipLabel != null) {
      final isBad = vipLabel == '付费' || vipLabel == '无版权' || vipLabel == '不可用';
      chips.add(
        _buildChip(
          context,
          vipLabel,
          background: isBad
              ? colorScheme.errorContainer
              : colorScheme.tertiaryContainer,
          foreground: isBad
              ? colorScheme.onErrorContainer
              : colorScheme.onTertiaryContainer,
          bold: true,
        ),
      );
    }

    // 加载中：占位小块保持行高，徽章到达后不跳版；失败/无数据收起。
    // 位于头部文字列内（专辑行下方），无需自带水平内边距。
    if (chips.isEmpty && _loading) {
      return SizedBox(
        height: 18,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _placeholderDot(colorScheme),
              const SizedBox(width: 4),
              _placeholderDot(colorScheme),
            ],
          ),
        ),
      );
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 6, runSpacing: 4, children: chips);
  }

  Widget _placeholderDot(ColorScheme colorScheme) {
    return Container(
      width: 28,
      height: 8,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }

  Widget _buildChip(
    BuildContext context,
    String label, {
    required Color background,
    required Color foreground,
    bool bold = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        maxLines: 1,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: foreground,
              fontWeight: bold ? FontWeight.w600 : null,
            ),
      ),
    );
  }
}
