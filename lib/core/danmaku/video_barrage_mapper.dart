import 'danmaku_entry.dart';
import 'danmaku_parser.dart';

/// 把 `/video/barrage` 的原始响应映射为弹幕条目。
///
/// 上游 MV 弹幕池底层是**评论池**，条目没有任何时间字段（详见
/// `docs/2026-09-20-kugou-mv-barrage-endpoint.md` 第三节），因此：
///
/// 1. 先用 [parseDanmakuList] 尝试按原生时间字段解析 —— 若上游将来返回带时间的
///    真弹幕，这条分支自动生效，无需改代码；
/// 2. 未命中时按「热评优先」排序后在 `[0, videoDuration]` 上**居中均匀铺开**：
///    第 i 条（0-based，共 n 条）的时间为 `duration * (i + 0.5) / n`。
///    用居中而非从 0 开始，是为了让**稀疏弹幕池**（实测某 MV 仅 1 条）出现在
///    视频中段而不是开头一闪而过。
List<DanmakuEntry> mapVideoBarrage(
  dynamic raw, {
  required Duration videoDuration,
  int maxCount = 200,
}) {
  // 1) 原生时间字段优先（未来兼容）
  final native = parseDanmakuList(raw);
  if (native.isNotEmpty) return native;

  if (videoDuration <= Duration.zero) return const [];
  final items = _extractItems(raw);
  if (items.isEmpty) return const [];

  // 2) 取文本非空的条目，按点赞降序、id 升序（确定性排序，避免同赞数抖动）
  final parsed = <_BarrageRaw>[];
  for (final it in items) {
    if (it is! Map) continue;
    final map = it.cast<String, dynamic>();
    final text = (map['content'] ?? map['text'] ?? '').toString().trim();
    if (text.isEmpty) continue;
    parsed.add(_BarrageRaw(
      text: text,
      id: (map['id'] ?? '').toString(),
      likeCount: _likeCount(map['like']),
    ));
  }
  if (parsed.isEmpty) return const [];

  parsed.sort((a, b) {
    final byLike = b.likeCount.compareTo(a.likeCount);
    if (byLike != 0) return byLike;
    return a.id.compareTo(b.id);
  });

  final limited = parsed.length > maxCount ? parsed.sublist(0, maxCount) : parsed;
  final total = limited.length;
  final entries = <DanmakuEntry>[];
  for (var i = 0; i < total; i++) {
    final item = limited[i];
    final ms = (videoDuration.inMilliseconds * (i + 0.5) / total).round();
    entries.add(DanmakuEntry(
      time: Duration(milliseconds: ms),
      text: item.text,
      // 评论池无颜色/类型字段，统一白色滚动弹幕
      colorValue: 0xFFFFFF,
      mode: DanmakuMode.scroll,
      id: item.id.isEmpty ? 'barrage-by-index-$i' : 'barrage-${item.id}',
    ));
  }
  entries.sort((a, b) => a.time.compareTo(b.time));
  return entries;
}

/// 从 `{list: [...]}` / `{data: {list: [...]}}` / 裸数组 中取条目数组。
List<dynamic> _extractItems(dynamic raw) {
  if (raw is List) return raw;
  if (raw is Map) {
    final map = raw.cast<String, dynamic>();
    for (final key in const ['list', 'data', 'result']) {
      final v = map[key];
      if (v is List) return v;
      if (v is Map) {
        final nested = _extractItems(v);
        if (nested.isNotEmpty) return nested;
      }
    }
  }
  return const [];
}

/// `like` 可能是对象（`{likenum, count, haslike}`）或数字。
int _likeCount(dynamic like) {
  if (like is num) return like.toInt();
  if (like is Map) {
    final v = like['likenum'] ?? like['count'];
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
  }
  return 0;
}

class _BarrageRaw {
  final String text;
  final String id;
  final int likeCount;
  const _BarrageRaw({required this.text, required this.id, required this.likeCount});
}
