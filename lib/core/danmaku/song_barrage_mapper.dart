import 'barrage_spread.dart';
import 'danmaku_entry.dart';
import 'danmaku_parser.dart';

/// 把 `/song/barrage` 的原始响应映射为弹幕条目。
///
/// 与 MV 弹幕同病同源：歌曲弹幕池底层也是评论池，实测条目**没有任何播放位置
/// 字段**（`timeline`/`time`/`timepoint`/`position`/`progress`/`offset`/`duration`
/// 全部不存在），`addtime` 是发表墙上时间，用它会让弹幕堆在开头。因此：
///
/// 1. 先用 [parseDanmakuList] 尝试原生时间字段 —— 上游将来带时间即自动生效；
/// 2. 未命中时交给 [spreadBarrage] 按热评优先居中铺开。
///
/// 实测条目数组就在**顶层 `list`**（不在 data 里），但取数仍走
/// [extractBarrageItems] 的多形态兼容，免得上游包装层一变就整池丢弹幕。
/// [songDuration] 非正数返回空 —— 时长未知就没法合成时间轴。
List<DanmakuEntry> mapSongBarrage(
  dynamic raw, {
  required Duration songDuration,
  int maxCount = 200,
}) {
  final native = parseDanmakuList(raw);
  if (native.isNotEmpty) return native;

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
  return spreadBarrage(items, duration: songDuration, maxCount: maxCount);
}

/// 取 `/song/barrage` 响应里的 `childrenid`（弹幕池资源 id，发送时要回传）。
///
/// 实测它是 **JSON 数字**（如 `100285259`）而不是字符串，空池时是空字符串，
/// 故数字/字符串/空三种形态都要安全转成 String，取不到就返回空串。
String songBarrageSpecialId(dynamic raw) {
  if (raw is! Map) return '';
  final v = raw.cast<String, dynamic>()['childrenid'];
  if (v == null) return '';
  return v.toString().trim();
}

/// 本地弹幕（LocalDanmakuStore）用的 key。
///
/// 一 key 一文件：`mv:` / `hash:` 前缀是 MV 弹幕的；前缀刻意用 `songbarrage:`
/// 而**不是** `song:` —— `mv_player_page.dart:279` 的 MV 直链场景已经在用
/// `song:${Song.id}`，而在线歌曲的 `Song.id` 就是酷狗 hash，两者会落成同一个
/// 文件、互相串数据。
String songDanmakuKey(String hash) => 'songbarrage:$hash';

/// 上游 `pagesize` 实测硬上限 50（请求 100 只回 50 条），要多只能翻页。
const int _songBarragePagesize = 50;

/// 串行翻 3 页 = 最多 150 条；实测热歌池 `count=180`，取前 150 条密度已够铺满
/// 整首歌，再多只是给长尾零赞评论排队。
const int _songBarrageMaxPages = 3;

/// 缓存过期时长：转屏/切布局会重建 widget，同一首歌几分钟内不该重拉 3 页。
const Duration _songBarrageCacheTtl = Duration(minutes: 10);

final Map<String, _CachedSongBarrage> _songBarrageCache = {};

/// 串行拉取歌曲弹幕并聚合成一条时间轴。
///
/// [fetchPage] 由调用方注入（生产代码传 `KugouApiClient().getSongBarrage` 的包装，
/// 其约定是失败返回 null、不抛异常），便于无网单测。
///
/// 降级策略：某页返回 null 或空 list 就停止翻页，**用已聚到的数据继续铺**，
/// 不抛异常 —— 第 1 页到手就有弹幕可看，比整池放弃好。
/// 跨页按弹幕 id 去重（上游翻页会重复回同一条）。
Future<List<DanmakuEntry>> fetchSongBarragePages({
  required String hash,
  required Duration songDuration,
  required Future<Map<String, dynamic>?> Function(int page, int pagesize) fetchPage,
  int maxCount = 200,
}) async {
  if (hash.isEmpty || songDuration <= Duration.zero) return const [];

  final cached = _songBarrageCache[hash];
  if (cached != null) {
    if (!cached.expired) return cached.entries;
    _songBarrageCache.remove(hash);
  }

  final seenIds = <String>{};
  final items = <dynamic>[];
  for (var page = 1; page <= _songBarrageMaxPages; page++) {
    final raw = await fetchPage(page, _songBarragePagesize);
    if (raw == null) break;
    final pageItems = extractBarrageItems(raw);
    if (pageItems.isEmpty) break;
    for (final it in pageItems) {
      final id = (it is Map ? (it['id'] ?? '').toString() : '');
      // 无 id 的条目不去重（无法判定是否同一条，宁可重复也不能漏）
      if (id.isNotEmpty && !seenIds.add(id)) continue;
      items.add(it);
    }
  }
  if (items.isEmpty) return const [];

  // 聚合后一次性铺时间轴：逐页铺会让每页各自占满整条时间轴、互相叠字。
  final entries = mapSongBarrage(
    {'list': items},
    songDuration: songDuration,
    maxCount: maxCount,
  );
  // 只缓存非空结果：空池可能是登录态/网络抖动造成的，不该钉住 10 分钟。
  if (entries.isNotEmpty) {
    _songBarrageCache[hash] = _CachedSongBarrage(
      entries,
      DateTime.now().add(_songBarrageCacheTtl),
    );
  }
  return entries;
}

/// 清空进程内歌曲弹幕缓存（供测试与「手动刷新」使用）。
void clearSongBarrageCache() => _songBarrageCache.clear();

class _CachedSongBarrage {
  final List<DanmakuEntry> entries;
  final DateTime expireAt;

  const _CachedSongBarrage(this.entries, this.expireAt);

  bool get expired => DateTime.now().isAfter(expireAt);
}
