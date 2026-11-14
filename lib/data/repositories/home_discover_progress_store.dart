// 「首页刷歌推荐」（/home/discover）断点状态的持久化。
//
// 本文件只管一件事：把「已经刷到第几首、已经推过哪些歌」这一个小小的游标
// 存到 SharedPreferences 并原样取回。刷歌的请求编排、去重与 UI 都不在这里，
// 调用方拿 [HomeDiscoverProgress] 自己接着往下走。
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 一份刷歌断点。
///
/// 之所以要有这个类：上游 discover 接口没有 page/offset，它唯一认的翻页依据是
/// `today_play_num`（今日已播歌曲数，服务端拿它排除已推过的歌）。于是"刷到第几"
/// 这个游标只能由客户端自己数——不落盘的话进程一被系统回收，冷启动就得从 0
/// 重新刷，用户反复撞见同一批歌。
class HomeDiscoverProgress {
  const HomeDiscoverProgress({required this.cursor, required this.seen});

  /// 已消费歌曲总数，即下次请求要带的 `today_play_num`。
  final int cursor;

  /// 已消费过的歌曲 hash。
  ///
  /// 游标只是"整体不往回走"的保证，客户端仍留一份集合做去重兜底：它同时也是
  /// 截断窗口，被 [HomeDiscoverProgressStore.seenLimit] 从最旧的一端削。
  final Set<String> seen;
}

/// 刷歌断点的读写仓库。
///
/// 存储格式是一整条 JSON 字符串：`{"cursor": 57, "seen": ["hash1","hash2"]}`。
/// 塞在一个键里而不是拆成两个键，是为了让读回来的两份状态天然同源——不会出现
/// 游标写成功、集合写失败这种撕裂的中间态。
class HomeDiscoverProgressStore {
  const HomeDiscoverProgressStore();

  static const String prefKey = 'home_discover_progress';

  /// seen 集合上限，超过时丢弃最旧的（实现用 List 保序，截尾）。
  static const int seenLimit = 500;

  /// 正在进行的读盘 Future，让并发的 [load] 合流成同一次 SharedPreferences 读。
  ///
  /// 首页各订阅方可能同时要断点，合流后整页首屏只付一次平台通道的代价。
  ///
  /// 之所以是 static 而不是实例字段：本类的构造函数是 const，而 const 构造函数
  /// 不允许类内存在非 final 实例字段；何况 const 构造本身就只产出一个规范化实例，
  /// "每实例一份缓存"与"全局一份缓存"在这里本来就是同一件事。
  ///
  /// [save] 刻意不重置它：一次进程内只读一次就够了，调用方自己持有内存态并整体
  /// 存回，不需要仓库再回读一遍自己刚写的东西。
  static Future<HomeDiscoverProgress>? _inFlight;

  /// 读回断点；首次读失败或数据损坏时回落到"从头刷"。
  ///
  /// 这是冷启动路径，绝不能抛：一次异常就会让整个 App 起不来，而它承载的不过
  /// 是"少刷过的几首"这种可丢信息。
  Future<HomeDiscoverProgress> load() {
    return _inFlight ??= _readFromPrefs();
  }

  /// 整体覆盖写入断点（游标与 seen 一起）。
  ///
  /// 只做覆盖不做增量合并：调用方持有的是完整内存态，手上这份已经是最终结果。
  /// 写盘前把 seen 收到 [seenLimit] 以内，免得这个键随使用无限膨胀。
  Future<void> save(HomeDiscoverProgress progress) async {
    final seen = _truncateSeen(progress.seen);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        prefKey,
        jsonEncode(<String, Object?>{
          'cursor': progress.cursor,
          'seen': seen.toList(growable: false),
        }),
      );
    } catch (_) {
      // 写失败只是丢一次断点（下次从头刷），不值得让调用方——多半正挂在刷歌的
      // 播放链路上——为一个可丢的缓存崩掉。
    }
  }

  /// 丢弃断点，例如用户退出登录：换账号后不该接着上一个账号的游标继续刷。
  ///
  /// 同时清掉内存态 [_inFlight]：数据已经没了，若还把旧 Future 发给后来者，登出
  /// 之后拿到的仍是上一个账号的游标。
  Future<void> clear() async {
    _inFlight = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(prefKey);
    } catch (_) {
      // 同 [save]：清不掉的后果也只是多刷一遍。
    }
  }

  static Future<HomeDiscoverProgress> _readFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefKey);
      if (raw == null || raw.isEmpty) return _emptyProgress();
      return _decode(raw);
    } catch (_) {
      return _emptyProgress();
    }
  }

  /// 解析断点 JSON，任何一处不合预期都回落到空断点。
  ///
  /// 校验刻意偏严（字段类型不对就整份丢弃，而不是只丢那一个字段）：半份断点比
  /// 没有断点更糟——游标归零而 seen 还在（或反过来）会让去重与翻页互相打架，
  /// 从头刷一遍反而是确定的正确行为。
  static HomeDiscoverProgress _decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return _emptyProgress();

      final cursorRaw = decoded['cursor'];
      if (cursorRaw != null && cursorRaw is! num) return _emptyProgress();

      // 键缺失或显式为 null 视作"这一项没写过"，不算类型错误。
      final seen = <String>[];
      final seenRaw = decoded['seen'];
      if (seenRaw != null) {
        if (seenRaw is! List) return _emptyProgress();
        for (final item in seenRaw) {
          if (item is! String) return _emptyProgress();
          seen.add(item);
        }
      }

      return HomeDiscoverProgress(
        cursor: (cursorRaw as num?)?.toInt() ?? 0,
        // 再截一次：防御历史脏数据（例如上限调小之前写下的超长集合）。
        seen: _truncateSeen(seen.toSet()),
      );
    } catch (_) {
      return _emptyProgress();
    }
  }

  /// seen 截尾：超长时只保留最新的 [seenLimit] 条。
  ///
  /// Set 的迭代顺序即插入顺序（调用方按消费先后 add），所以最旧的排在前面，
  /// 丢头部即可。于是去重窗口是一个平滑滑动的窗口，而不是"攒够 500 条后突然
  /// 清空全部历史"。
  static Set<String> _truncateSeen(Set<String> seen) {
    if (seen.length <= seenLimit) return seen;
    return Set<String>.of(seen.skip(seen.length - seenLimit));
  }

  /// 每次都造一个新实例，而不是共用一个 const 空断点。
  ///
  /// 调用方会把读回来的 seen 直接当内存态往里 add；const 集合是不可变的，
  /// 共用同一个实例会在运行时炸。
  static HomeDiscoverProgress _emptyProgress() {
    return HomeDiscoverProgress(cursor: 0, seen: <String>{});
  }
}
