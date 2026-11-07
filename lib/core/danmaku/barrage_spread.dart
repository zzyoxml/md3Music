import 'danmaku_entry.dart';

/// 铺时间轴之前的弹幕条目：文本 / id / 点赞数，由各自的取数逻辑归一而来。
class BarrageItem {
  final String text;
  final String id;
  final int likeCount;

  const BarrageItem({
    required this.text,
    required this.id,
    required this.likeCount,
  });
}

/// 把「没有播放位置字段」的弹幕池条目铺成时间轴 —— MV 池与歌曲池共用。
///
/// 两个池底层都是评论池，条目只有 `addtime`（发表墙上时间），误用它会让弹幕
/// 全部堆在视频开头，因此统一按「热评优先 + 居中均匀铺开」合成时间轴：
///
/// 1. 丢弃空文本；
/// 2. 按点赞降序、id 升序（id 作次级键，同赞数时排序才确定，不会每次刷新抖动）；
/// 3. 截断到 [maxCount]；
/// 4. 第 i 条（0-based，共 n 条）落在 `duration * (i + 0.5) / n`。
///    用居中而非从 0 开始，是为了让**稀疏弹幕池**（实测某 MV 仅 1 条）出现在
///    中段而不是开头一闪而过；
/// 5. 按时间升序返回，渲染层可直接顺序消费。
///
/// [duration] 非正数时返回空 —— 时长未知就没法合成时间轴。
List<DanmakuEntry> spreadBarrage(
  List<BarrageItem> items, {
  required Duration duration,
  int maxCount = 200,
}) {
  if (duration <= Duration.zero) return const [];

  final parsed = items.where((e) => e.text.trim().isNotEmpty).toList();
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
    final ms = (duration.inMilliseconds * (i + 0.5) / total).round();
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
///
/// `list` 优先：实测 `/video/barrage` 与 `/song/barrage` 的条目数组都在顶层 `list`。
List<dynamic> extractBarrageItems(dynamic raw) {
  if (raw is List) return raw;
  if (raw is Map) {
    final map = raw.cast<String, dynamic>();
    for (final key in const ['list', 'data', 'result']) {
      final v = map[key];
      if (v is List) return v;
      if (v is Map) {
        final nested = extractBarrageItems(v);
        if (nested.isNotEmpty) return nested;
      }
    }
  }
  return const [];
}

/// `like` 可能是对象（`{likenum, count, haslike}`）或数字。
int barrageLikeCount(dynamic like) {
  if (like is num) return like.toInt();
  if (like is Map) {
    final v = like['likenum'] ?? like['count'];
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
  }
  return 0;
}
