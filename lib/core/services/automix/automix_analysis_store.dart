import 'dart:convert';
import 'dart:io';

import 'automix_analysis.dart';

/// AutoMix 分析结果的持久化缓存。
///
/// 单曲分析要解码 25s 音频（一次网络读 + 一次解码），只做一次并缓存；
/// 键为 `songId|urlHash`（同一首歌换音质/换 cdn 会换键）。
/// 容量按 LRU（[analyzedAtMs] 最旧的先淘汰）封顶，避免长期累积。
class AutomixAnalysisStore {
  AutomixAnalysisStore({required Directory directory})
      : _dir = directory,
        _file = File(
            '${directory.path}${Platform.pathSeparator}automix_analysis.json');

  static const int maxEntries = 500;
  static const int _version = 1;

  final Directory _dir;
  final File _file;
  Map<String, AutomixAnalysis>? _mem;

  Future<Map<String, AutomixAnalysis>> _load() async {
    final cached = _mem;
    if (cached != null) return cached;
    final map = <String, AutomixAnalysis>{};
    try {
      if (await _file.exists()) {
        final decoded = jsonDecode(await _file.readAsString());
        if (decoded is Map<String, dynamic>) {
          final items = decoded['items'];
          if (items is List) {
            for (final raw in items) {
              final a = AutomixAnalysis.fromJson(
                  raw is Map ? raw.cast<String, dynamic>() : null);
              if (a != null) map[a.key] = a;
            }
          }
        }
      }
    } catch (_) {
      // 损坏/半写：降级为空缓存，下次写入会整体覆盖
    }
    _mem = map;
    return map;
  }

  Future<void> _persist(Map<String, AutomixAnalysis> map) async {
    try {
      if (!await _dir.exists()) await _dir.create(recursive: true);
      final items = map.values.map((a) => a.toJson()).toList(growable: false);
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(jsonEncode({'version': _version, 'items': items}));
      await tmp.rename(_file.path);
    } catch (_) {
      // 落盘失败不阻断播放：内存缓存仍然有效
    }
  }

  Future<AutomixAnalysis?> read(String key) async => (await _load())[key];

  Future<void> write(AutomixAnalysis analysis) async {
    final map = await _load();
    map[analysis.key] = analysis;
    if (map.length > maxEntries) {
      final sorted = map.values.toList()
        ..sort((a, b) => a.analyzedAtMs.compareTo(b.analyzedAtMs));
      for (final old in sorted.take(map.length - maxEntries)) {
        map.remove(old.key);
      }
    }
    await _persist(map);
  }

  Future<int> count() async => (await _load()).length;
}
