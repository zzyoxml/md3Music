import 'barrage_spread.dart';
import 'danmaku_entry.dart';
import 'danmaku_parser.dart';

/// 把 `/video/barrage` 的原始响应映射为弹幕条目。
///
/// 上游 MV 弹幕池底层是**评论池**，条目没有任何时间字段（详见
/// `docs/2026-09-20-kugou-mv-barrage-endpoint.md` 第三节），因此：
///
/// 1. 先用 [parseDanmakuList] 尝试按原生时间字段解析 —— 若上游将来返回带时间的
///    真弹幕，这条分支自动生效，无需改代码；
/// 2. 未命中时交给 [spreadBarrage] 按「热评优先」居中均匀铺开（与歌曲弹幕共用）。
///
/// 本文件只负责 MV 响应的取数与归一，铺 time 的规则不在这里重复一份。
List<DanmakuEntry> mapVideoBarrage(
  dynamic raw, {
  required Duration videoDuration,
  int maxCount = 200,
}) {
  // 1) 原生时间字段优先（未来兼容）
  final native = parseDanmakuList(raw);
  if (native.isNotEmpty) return native;

  // 2) 无时间字段：归一后居中铺开
  final items = <BarrageItem>[];
  for (final it in extractBarrageItems(raw)) {
    if (it is! Map) continue;
    final map = it.cast<String, dynamic>();
    items.add(BarrageItem(
      text: (map['content'] ?? map['text'] ?? '').toString().trim(),
      id: (map['id'] ?? '').toString(),
      likeCount: barrageLikeCount(map['like']),
    ));
  }
  return spreadBarrage(items, duration: videoDuration, maxCount: maxCount);
}
