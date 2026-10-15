import 'dart:convert';
import 'dart:io';

import 'danmaku_entry.dart';

/// 本地弹幕持久化：一个 key（MV）对应根目录下的一个 JSON 文件。
///
/// 根目录由外部注入，生产代码传 `getApplicationSupportDirectory()/danmaku`，
/// 测试传临时目录。**不使用缓存目录** —— 用户自己发送的弹幕不应被系统清理。
class LocalDanmakuStore {
  final Directory root;

  LocalDanmakuStore({required this.root});

  Future<List<DanmakuEntry>> load(String key) async {
    final file = _fileFor(key);
    if (!await file.exists()) return const [];
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return const [];
      final items = decoded['items'];
      if (items is! List) return const [];
      final entries = <DanmakuEntry>[];
      for (final item in items) {
        if (item is! Map) continue;
        final entry = DanmakuEntry.fromJson(item.cast<String, dynamic>());
        if (entry.text.trim().isEmpty) continue;
        entries.add(entry);
      }
      entries.sort((a, b) => a.time.compareTo(b.time));
      return entries;
    } catch (_) {
      // 文件损坏（半写入 / 外部改动）视为「无弹幕」，绝不向上抛。
      return const [];
    }
  }

  /// 追加一条并落盘（读改写；本地弹幕量级为个位数到几十条，无需增量格式）。
  ///
  /// append 本质是「load → replaceAll」读改写，连续快速发送两条弹幕时
  /// 两次并发 append 会互相覆盖（后写覆盖前写，静默丢一条），
  /// 因此用 Future 链把写操作串行化，保证先发先落盘。
  Future<void> append(String key, DanmakuEntry entry) {
    final task = _writeQueue.then((_) async {
      final existing = await load(key);
      await replaceAll(key, [...existing, entry]);
    });
    // 单次写入失败不得阻断后续写入（失败已由 replaceAll 的目录创建兜底外暴露）
    _writeQueue = task.catchError((_) {});
    return task;
  }

  /// 写入串行化队列。注意：`replaceAll` 不经过队列（供初始化/测试直接覆盖），
  /// 页面路径只允许通过 [append] 写入。
  Future<void> _writeQueue = Future.value();

  Future<void> replaceAll(String key, List<DanmakuEntry> entries) async {
    final sorted = [...entries]..sort((a, b) => a.time.compareTo(b.time));
    await root.create(recursive: true);
    final payload = jsonEncode({
      'version': 1,
      'items': sorted.map((e) => e.toJson()).toList(),
    });
    // 先写临时文件再 rename，避免写入中途被杀导致文件半截损坏。
    final tmp = File('${_fileFor(key).path}.tmp');
    await tmp.writeAsString(payload, flush: true);
    await tmp.rename(_fileFor(key).path);
  }

  File _fileFor(String key) => File('${root.path}/${_sanitize(key)}.json');

  /// 只保留 `[A-Za-z0-9_-]`，其余替换为 `_`，确保不会逃出根目录。
  static String _sanitize(String key) {
    final cleaned = key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return cleaned.isEmpty ? '_' : cleaned;
  }
}
