import 'dart:async';

import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_models.dart';

/// 队列剩下的歌不多于这个数就提前补货（与私人 FM 同一条阈值）。
const int kHomeDiscoverPrefetchThreshold = 3;

/// 队列播完那一刻补货的重试次数与退避步长。
///
/// 这里必须重试：[PlayerProvider] 对 `onPlaylistEnd` 只 await、不校验结果，回调
/// 一返回就彻底静止，没有第二次机会。而单次补货失败的路子不少——这批取不到新歌、
/// 页面正在滑动加载更多（provider 的单飞闸门正被占着）、撞上在飞的那次预取。
const int kHomeDiscoverQueueEndRetries = 3;
const Duration kHomeDiscoverQueueEndBackoff = Duration(milliseconds: 600);

/// 刷歌续播器：把「首页刷歌推荐一直往下刷」需要的一切收在这里，不引用任何 UI。
///
/// 结构上与私人 FM 的 [FmRefill] 一一对应（所有权集合 / 提前补货 / 播完补货 /
/// 停摆自愈 / 槽位互斥），唯一的差异是**游标**：刷歌接口没有 page/offset，
/// `today_play_num` 是"已消费总数"这个客户端游标，由 [KugouProvider] 内部持有、
/// 推进并按 seen 去重。所以本类**不存游标**，每轮直接要一批，由 provider 决定
/// 下一批从哪儿接着刷。
///
/// 补货必须比页面活得久——App 的 tab 切换用 AnimatedSwitcher 按 tab id 换子树
/// （app.dart），发现页切走一次就 dispose，而队列还在放。所以这里不碰 `mounted`、
/// 不碰 BuildContext，只依赖两个 provider（生命周期跟着 App）和起播时那次
/// 装填；提前补货也由它自己监听播放器，不再借页面的 listener。
///
/// 所有权的判据是 [_owned]：装填时刷歌列表里的全部 hash。不去问
/// [KugouProvider.homeDiscoverSongs] 此刻的内容，也不问队列里有哪些歌——前者
/// 会被 [KugouProvider.clearMemoryCache] 直接清空（换账号、清缓存时），后者在
/// 别的入口起播后就不再是刷歌队列了；两者都会让"还在放自己的队列"在下一次
/// 通知里被误判成别人的，连播当场断掉。
class HomeDiscoverRefill {
  HomeDiscoverRefill._({required this._kugou, required this._player})
    : // 装填那一刻列表里已有的歌全部认下来：用户可能是从第 7 首起的播，
      // 队列里每一首都是刷歌来的，只认后来补的那几批会把这条队列当成别人的。
      _owned = _kugou.homeDiscoverSongs.map((e) => e.hash).toSet() {
    _player.addListener(_onPlayerChanged);
  }

  /// 正在装填的那个续播器；没有则为 null。外部只用来 [append]（例如起播后立刻
  /// 补一批），不拿它做别的判断——什么时候该补货是本类自己的事。
  static HomeDiscoverRefill? get current => _current;

  static HomeDiscoverRefill? _current;

  final KugouProvider _kugou;
  final PlayerProvider _player;

  /// 本续播器认下的全部 hash：既是所有权判据，也是新歌的记账依据。
  final Set<String> _owned;

  /// 在飞的那次补货。并发调用合流到同一个 Future，而不是让后来者拿到 false——
  /// 队列末尾那次若把"有人正在补"当成"补不到"，就不会推 next()，
  /// 播放器会抱着一条刚补满的队列停死。
  Future<bool>? _inFlight;

  /// 上一次提前补货时的播放下标，避免停在同一首上反复请求。
  int _lastPrefetchIndex = -1;

  /// [onQueueEnd] 的重试全部用尽后置位：那一刻队列已经放到底、播放器 pause 在
  /// 最后一首上，再没有谁会调 [PlayerProvider.next]。之后任何一次补货成功都要
  /// 自己补推一把 next()，否则这条队列永远不会再往前走。
  bool _stalledAtQueueEnd = false;

  bool _retired = false;

  /// 装填：同一条队列已在补货就复用现有实例，否则新建并接管 onPlaylistEnd 槽。
  /// 队列不是刷歌来的（playlist 为空）时返回 null。
  ///
  /// 谁起播的队列谁负责补货，所以判据是刷歌列表有没有东西：刷歌的
  /// [KugouProvider.homeDiscoverSongsAsSongs] 一空就说明这一轮什么都没刷出来，
  /// 建出来的续播器认不出任何一首歌，会在第一次通知里把自己退掉。
  static HomeDiscoverRefill? arm(KugouProvider kugou, PlayerProvider player) {
    if (kugou.homeDiscoverSongs.isEmpty) return null;
    final existing = _current;
    // 复用要连槽位一起看：槽位已经不是它的，说明这条队列被别的续播器（或别人）
    // 接管了，它在下一次通知里就会退场，留着只会让新装填的立刻撞上"槽位不是
    // 自己的"而退场。
    if (existing != null &&
        !existing._retired &&
        identical(existing._kugou, kugou) &&
        identical(existing._player, player) &&
        player.onPlaylistEnd == existing.onQueueEnd) {
      return existing;
    }
    // 上一条队列的续播器先退场：它守的是别人的队列，继续监听只会在下一次通知里
    // 误判并顺手把新装填的槽位也清掉。
    existing?.retire();
    final refill = HomeDiscoverRefill._(kugou: kugou, player: player);
    _current = refill;
    player.onPlaylistEnd = refill.onQueueEnd;
    return refill;
  }

  /// 队列是不是还归本续播器管。
  bool get _ownsQueue {
    final playingId = _player.currentSong?.id;
    return playingId != null && _owned.contains(playingId);
  }

  /// 退场：解绑监听、归还槽位。重复调用安全。
  ///
  /// 必须真的把 `onPlaylistEnd` 置回 null：[PlayerProvider] 只看槽位非空就把
  /// 「播完」整个交给回调，一个不干活的回调会连普通歌单的「播完回到第一首」
  /// 兜底一起遮蔽掉。而这个槽位是单槽独占的（与私人 FM 互斥），所以只能在它
  /// 仍是自己那个时才置空，否则会把后来者的槽位一起清掉。
  void retire() {
    if (_retired) return;
    _retired = true;
    _player.removeListener(_onPlayerChanged);
    if (identical(_current, this)) _current = null;
    if (_player.onPlaylistEnd == onQueueEnd) {
      _player.onPlaylistEnd = null;
    }
  }

  /// 队列快见底时提前补货：[PlayerProvider] 一次只把一首歌灌进 audio_service，
  /// 队列末尾没有预加载。
  void _onPlayerChanged() {
    if (_retired) return;
    // 别人抢了槽位（私人 FM 起了播、或刷歌自己换了队列），本续播器该退场了。
    if (_player.onPlaylistEnd != onQueueEnd) {
      retire();
      return;
    }
    final playingId = _player.currentSong?.id;
    // 起播过程中会有一瞬间没有当前曲目，那不代表队列换主了。
    if (playingId == null) return;
    if (!_owned.contains(playingId)) {
      retire();
      return;
    }
    final index = _player.currentIndex;
    if (index < 0) return;
    if (_player.playlist.length - index > kHomeDiscoverPrefetchThreshold) {
      return;
    }
    if (index == _lastPrefetchIndex) return;
    _lastPrefetchIndex = index;
    unawaited(
      append().then((ok) {
        if (!ok) {
          // 失败不能烧掉这个下标：还停在同一首上时得允许再试一次，否则一次网络
          // 抖动就让这条队列再也不补货。
          if (_lastPrefetchIndex == index) _lastPrefetchIndex = -1;
          return;
        }
        // 停摆过就得自己推一把：那一刻播放器已经 pause 在最后一首上，接上新歌
        // 也没有谁会调 next()。
        if (_stalledAtQueueEnd && !_retired && _ownsQueue) {
          _stalledAtQueueEnd = false;
          unawaited(_player.next());
        }
      }),
    );
  }

  /// 队列播完了：补一批新歌再推一把 [PlayerProvider.next]——播放器 await 完这个
  /// 回调就不再切歌，而它给 audio_service 的永远只有当前这一首。
  ///
  /// 这个方法同时是槽位的身份标识（[PlayerProvider.onPlaylistEnd] 存的就是它的
  /// tear-off），所以必须挂在实例上、每次比较都指向同一个对象。
  Future<void> onQueueEnd() async {
    if (_retired) return;
    if (!_ownsQueue) {
      retire();
      return;
    }
    for (var attempt = 0; attempt < kHomeDiscoverQueueEndRetries; attempt++) {
      if (attempt > 0) {
        await Future.delayed(kHomeDiscoverQueueEndBackoff * attempt);
        if (_retired || !_ownsQueue) return;
      }
      if (await append()) {
        _stalledAtQueueEnd = false;
        await _player.next();
        return;
      }
    }
    // 重试用尽后不能就这么算了：播放器这时停在最后一首（[PlayerProvider.next]
    // 到末尾就 pause），而提前补货那条路还被烧掉的下标挡着——两条路一起断，这
    // 条队列就永久不补货了，用户在发现页怎么点都恢复不过来。放开下标并记下停摆
    // 状态：下一次播放器通知（暂停事件本身就是一次，回前台点播放又是一次）能
    // 重新试，补上了由 [_onPlayerChanged] 推 next()。
    _stalledAtQueueEnd = true;
    _lastPrefetchIndex = -1;
  }

  /// 补一批新歌：进刷歌列表 + 进播放队列。返回是否真的接上了。
  /// 并发调用合流到同一个 Future。
  Future<bool> append() {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    final started = _append();
    _inFlight = started;
    return started.whenComplete(() {
      if (identical(_inFlight, started)) _inFlight = null;
    });
  }

  Future<bool> _append() async {
    if (_retired || !_ownsQueue) return false;
    final lengthBefore = _player.playlist.length;
    try {
      // 要不到新歌就得当成失败返回 null，不能靠 catch 兜：getHomeDiscover 从不抛
      // 异常（_get 吞掉一切返回 null），本页唯一的失败形态就是"空结果"。
      final fresh = await _fetch();
      if (fresh == null || _retired) return false;

      // 记下所有权：换队列、页面清缓存之后，靠的是这批 hash 还认得出自己的歌。
      _owned.addAll(fresh.map((e) => e.hash));
      // 列表那半边不用这里写：[KugouProvider.fetchMoreHomeDiscover] 返回的正是
      // 它已经按 seen 并进 homeDiscoverSongs 的那一批，重复写只会重跑一遍去重。
      await _player.appendPlaylist(fresh.map((e) => e.toSong()).toList());
      return true;
    } catch (_) {
      // 抛出来只会变成没人接的异步异常，还会中断 [onQueueEnd] 的重试循环
      // （播放器 await 这个回调，且不 catch）。降级成"队列到底有没有变长"：
      // [PlayerProvider.appendPlaylist] 先把歌塞进 _playlist，再去动
      // audio_service 队列，后半段抛异常时队列其实已经能继续放了，这时报失败会
      // 让 [onQueueEnd] 白白放弃一条补满了的队列。
      return _player.playlist.length > lengthBefore;
    }
  }

  /// 要一批新歌；要不到返回 null，由调用方决定要不要退一步（重试 / 放弃停摆自愈）。
  ///
  /// 去重不在这里做：[KugouProvider] 的 seen 与游标已经把这一层兜住了（它返回的
  /// 就是新并进列表的那一批），本类再滤一遍只会和它各持一份判据。
  Future<List<KugouSongDetail>?> _fetch() async {
    final result = await _kugou.fetchMoreHomeDiscover();
    // 空结果有两条来路，都不是"再等等就好了"：真的取不动了（服务端翻不出新歌），
    // 或者页面的滑动加载更多正占着 provider 的单飞闸门。两种都得退回去让调用方
    // 重试——那种情况下退避一小会儿再来一次就能要到。
    if (result.isEmpty) return null;
    return result;
  }
}
