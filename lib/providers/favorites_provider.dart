import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/models/song.dart';
import '../data/repositories/favorites_repository.dart';
import '../services/kugou_api/kugou_api_client.dart';
import '../services/kugou_api/kugou_models.dart';
import '../utils/playlist_write_payload.dart';

class FavoritesProvider extends ChangeNotifier {
  final FavoritesRepository _repository = FavoritesRepository();
  List<Song> _favorites = [];
  Set<String> _favoriteIds = {};
  bool _isLoading = false;
  KugouPlaylistBrief? _myFavoritePlaylist;

  List<Song> get favorites => _favorites;
  Set<String> get favoriteIds => _favoriteIds;
  bool get isLoading => _isLoading;

  FavoritesProvider({bool syncOnStart = true}) {
    if (syncOnStart) loadFavorites();
  }

  Future<void> loadFavorites() async {
    _isLoading = true;
    notifyListeners();
    _favorites = await _repository.getFavorites();
    _favoriteIds = _favorites.map((s) => s.id).toSet();
    await _syncFavoritesFromKugou();
    _isLoading = false;
    notifyListeners();
    // MD3Music fork v65b：登录/退出/换账号后云端整表可能仍为空（attach 时未登录的
    // 冷启动场景，loadCloudFavoriteSongs 返回 const [] 且不写缓存）。这里顺带拉一次
    // ——收藏树（原子随身听）与「我喜欢」选择器共用同一份整表缓存，命中即零网络。
    unawaited(loadCloudFavoriteSongs());
  }

  bool isFavorite(String songId) => _favoriteIds.contains(songId);

  /// 同步收藏 ID 集合（用于"我喜欢"歌单加载后同步本地状态）
  void syncFavoriteIds(Set<String> ids) {
    _favoriteIds = ids;
    notifyListeners();
  }

  /// 批量添加收藏 ID（用于"我喜欢"歌单加载时同步）
  void addFavoriteIds(List<String> ids) {
    _favoriteIds.addAll(ids);
    notifyListeners();
  }

  Future<KugouPlaylistBrief?> _getMyFavoritePlaylist() async {
    if (_myFavoritePlaylist != null) return _myFavoritePlaylist;
    try {
      final api = KugouApiClient();
      final result = await api.getUserPlaylist(pagesize: 50);
      if (result != null && result['data'] != null) {
        final data = result['data'];
        final info = data is Map ? data['info'] as List<dynamic>? : null;
        if (info != null) {
          for (final item in info) {
            if (item is Map<String, dynamic>) {
              final name = item['name']?.toString() ?? '';
              final isDef = item['is_def'];
              if (name == '我喜欢' || isDef == 2) {
                final brief = KugouPlaylistBrief.fromJson(item);
                _myFavoritePlaylist = brief;
                return _myFavoritePlaylist;
              }
            }
          }
        }
      }
    } catch (e) {
          }
    return null;
  }

  List<Song>? _cloudFavoriteSongs;

  /// 失效前的一份云端整表快照（MD3Music fork v65）。
  ///
  /// 红心增删会 invalidate 有效缓存并后台重拉；重拉完成前若桥接视图直接回退到
  /// [_favorites]，原子随身听「收藏列表」会瞬间只剩 App 内点过红心的那几首
  /// （v65 前的真机现象：整表只有 1 首）。保留上一份结果直到新数据到达，视图才稳定。
  List<Song>? _lastCloudFavoriteSongs;

  /// 桥接视图（原子随身听收藏树）的云端整表上限。
  ///
  /// 岛每页 50 条、界面深度远小于此值；上限只用于兜住超大收藏单（几千首）一次
  /// 序列化过 MethodChannel 时把主线程拖住，正常收藏量（几十~几百）不受影响。
  static const int _cloudFavoriteCap = 1000;

  /// 云端「我喜欢」歌单的完整歌曲列表（点歌/加歌选择器用）。
  ///
  /// [_syncFavoritesFromKugou] 只同步收藏 **id 集合**，[_favorites] 只含
  /// App 内点红心的歌——直接用它会让「我喜欢」来源只显示本地红心的几首。
  /// 这里按需拉取云端整表（listid 分页接口，与收藏页同口径）并缓存，
  /// 会话内复用；红心增删后下次进入选择器前可置空缓存重新拉取。
  Future<List<Song>> loadCloudFavoriteSongs() {
    final cached = _cloudFavoriteSongs;
    if (cached != null) return Future<List<Song>>.value(cached);
    final inFlight = _cloudLoadInFlight;
    if (inFlight != null) return inFlight;
    final future = _fetchCloudFavoriteSongs();
    _cloudLoadInFlight = future;
    unawaited(future.whenComplete(() {
      if (identical(_cloudLoadInFlight, future)) _cloudLoadInFlight = null;
    }));
    return future;
  }

  /// 正在进行的云端整表请求（连续红心增删只发一次，避免旧结果覆盖新结果）。
  Future<List<Song>>? _cloudLoadInFlight;

  Future<List<Song>> _fetchCloudFavoriteSongs() async {
    if (_cloudFavoriteSongs != null) return _cloudFavoriteSongs!;
    final playlist = await _getMyFavoritePlaylist();
    if (playlist == null) return const [];
    final api = KugouApiClient();
    final songs = <Song>[];
    final listid = playlist.listId;
    if (listid.isNotEmpty) {
      const int pageSize = 200;
      for (int page = 1; page <= 50; page++) {
        final r = await api.getPlaylistSongsByListid(
          listid: listid,
          page: page,
          pagesize: pageSize,
        );
        if (r == null || r.songs.isEmpty) break;
        songs.addAll(r.songs.map((s) => s.toSong()));
        if (r.songs.length < pageSize) break;
      }
    } else {
      // 回退：用 globalCollectionId 接口（与 _syncFavoritesFromKugou 同路径）
      final gid = playlist.globalCollectionId ?? playlist.id;
      if (gid.isNotEmpty) {
        final result = await api.getPlaylistSongs(gid, pagesize: 500);
        songs.addAll(
            (result?.songs ?? const <KugouSongDetail>[]).map((s) => s.toSong()));
      }
    }
    _cloudFavoriteSongs = songs;
    notifyListeners();
    return songs;
  }

  /// 红心变动后使云端整表缓存失效。
  ///
  /// MD3Music fork v65：失效时把旧结果搬进 [_lastCloudFavoriteSongs] 继续供
  /// [favoritesForBridge] 使用，并后台重拉一次——红心增删已经改变云端歌单，
  /// 桥接列表必须跟着刷新，否则取消收藏后岛上还留着那首歌。
  void invalidateCloudFavoriteSongs() {
    final current = _cloudFavoriteSongs;
    if (current != null) _lastCloudFavoriteSongs = current;
    _cloudFavoriteSongs = null;
    unawaited(loadCloudFavoriteSongs().catchError((_) => const <Song>[]));
  }

  /// 取消收藏后立即从云端快照里摘掉该歌（重拉完成前桥上不再残留）。
  void _dropFromCloudSnapshot(String songId) {
    final cur = _cloudFavoriteSongs;
    if (cur != null && cur.any((s) => s.id == songId)) {
      _cloudFavoriteSongs =
          cur.where((s) => s.id != songId).toList(growable: false);
    }
    final last = _lastCloudFavoriteSongs;
    if (last != null && last.any((s) => s.id == songId)) {
      _lastCloudFavoriteSongs =
          last.where((s) => s.id != songId).toList(growable: false);
    }
  }

  /// 原子随身听（vivomusicmix）「收藏列表」树的数据源：云端「我喜欢」整表
  /// + App 内红心歌曲，按 [Song.id] 去重合并。
  ///
  /// [_favorites] 只装 App 内点过红心的歌（云端收藏同步只喂 [_favoriteIds]），
  /// 直接推它就会表现为岛上收藏列表只有很少几首（真机 21 首只显示 1 首）。
  /// 本地新收藏排在最前，刚点红心的歌立刻可见；云端整表按服务端顺序跟在后面。
  List<Song> get favoritesForBridge {
    final cloud = _cloudFavoriteSongs ?? _lastCloudFavoriteSongs;
    final local = _favorites;
    if (cloud == null || cloud.isEmpty) return local;
    final seen = <String>{};
    final out = <Song>[];
    for (final song in local) {
      if (song.id.isEmpty) continue;
      if (seen.add(song.id)) out.add(song);
    }
    var cloudAdded = 0;
    for (final song in cloud) {
      if (cloudAdded >= _cloudFavoriteCap) break;
      if (song.id.isEmpty) continue;
      if (seen.add(song.id)) {
        out.add(song);
        cloudAdded++;
      }
    }
    return out;
  }

  /// 「我喜欢」歌单记录 fileid 映射（歌曲 hash → 歌单记录 fileid）。
  ///
  /// 上游 `/playlist/tracks/del` 只按**歌单记录 fileid** 删除，且该 fileid
  /// 必须取自歌单列表接口（`/playlist/track/all[/new]`）返回的 `fileid` 字段——
  /// 传 hash 或别家歌单的记录 id 都不会真正删除（KuGouMusicApi issue #57 即
  /// 「删除接口返回成功但歌还在」）。搜索/每日推荐/刷歌等来源的 Song 没有
  /// fileid，故同步时顺带记录映射，取消收藏才能用对标识符。
  final Map<String, int> _favoriteRecordFileIds = {};

  Future<void> _syncFavoritesFromKugou() async {
    try {
      final playlist = await _getMyFavoritePlaylist();
      if (playlist == null) return;
      final api = KugouApiClient();

      // 优先用 listid 接口（与 PlaylistPage 一致），确保 hash 匹配。
      // "我喜欢"是用户私有歌单，globalCollectionId 可能为空，
      // 用 getPlaylistSongs(/playlist/track/all) 会拉取失败或返回不一致的数据。
      final listid = playlist.listId;
      if (listid.isNotEmpty) {
        const int pageSize = 200;
        const int maxSongs = 9999;
        // 向上取整，保证能拉到 maxSongs 首（200*50=10000 ≥ 9999）
        const int maxPages = (maxSongs + pageSize - 1) ~/ pageSize;
        for (int page = 1; page <= maxPages; page++) {
          final r = await api.getPlaylistSongsByListid(
            listid: listid,
            page: page,
            pagesize: pageSize,
          );
          if (r == null) break;
          for (final s in r.songs) {
            _favoriteIds.add(s.hash);
            _rememberRecordFileId(s);
          }
          if (_favoriteIds.length >= maxSongs) break;
          if (r.songs.length < pageSize) break;
        }
        notifyListeners();
      } else {
        // 回退：用 globalCollectionId 接口
        final gid = playlist.globalCollectionId ?? playlist.id;
        if (gid.isNotEmpty) {
          final result = await api.getPlaylistSongs(gid, pagesize: 500);
          if (result != null && result.songs.isNotEmpty) {
            for (final s in result.songs) {
              _favoriteIds.add(s.hash);
              _rememberRecordFileId(s);
            }
            notifyListeners();
          }
        }
      }
    } catch (e) {
    }
  }

  /// 记录歌单列表条目携带的记录 fileid（见 [_favoriteRecordFileIds]）。
  void _rememberRecordFileId(KugouSongDetail detail) {
    final fileId = detail.fileId;
    if (fileId != null && fileId > 0) {
      _favoriteRecordFileIds[detail.hash] = fileId;
    }
  }

  /// 取消收藏用：定位该歌曲在「我喜欢」歌单里的记录 fileid。
  ///
  /// 上游删除接口只认歌单记录 fileid（见 [_favoriteRecordFileIds] 说明），
  /// 搜索/每日推荐/刷歌等来源的 Song 没有该字段，这里按 hash 反查。
  Future<String> _resolveFavoriteRecordFileId(String listid, Song song) async {
    // 1) 启动同步缓存的映射（常用路径，零额外请求）
    final cached = _favoriteRecordFileIds[song.id];
    if (cached != null && cached > 0) return cached.toString();

    // 2) 现场反查：同会话内刚收藏的歌，同步时它还没进列表
    final fetched = await _lookupFavoriteRecordFileId(listid, song.id);
    if (fetched != null && fetched > 0) return fetched.toString();

    // 3) 歌曲自带 fileid：从「我喜欢」歌单页进来时即为该歌单的记录 id
    if (song.fileId != null && song.fileId! > 0) return song.fileId.toString();

    // 4) 找不到记录（如服务器上从未收藏成功）：退回 hash，本地状态照常清理
    return song.id;
  }

  /// 分页反查记录 fileid：先探首页、再探末页。
  ///
  /// 云端「我喜欢」列表按收藏时间正序（最新在末页），同会话新增的歌取末页
  /// 即可命中；首页探测兜底顺序假设不成立的情况。**必须 noCache**，否则
  /// 读到收藏前缓存的旧列表，反查必然落空。
  Future<int?> _lookupFavoriteRecordFileId(String listid, String hash) async {
    const int pageSize = 200;
    final api = KugouApiClient();
    final first = await api.getPlaylistSongsByListid(
      listid: listid,
      page: 1,
      pagesize: pageSize,
      noCache: true,
    );
    if (first == null) return null;
    final hit = _matchRecordFileId(first.songs, hash);
    if (hit != null) return hit;
    final lastPage = (first.total + pageSize - 1) ~/ pageSize;
    if (lastPage <= 1) return null;
    final last = await api.getPlaylistSongsByListid(
      listid: listid,
      page: lastPage,
      pagesize: pageSize,
      noCache: true,
    );
    return _matchRecordFileId(last?.songs ?? const [], hash);
  }

  int? _matchRecordFileId(List<KugouSongDetail> songs, String hash) {
    for (final s in songs) {
      if (s.hash == hash && s.fileId != null && s.fileId! > 0) {
        return s.fileId;
      }
    }
    return null;
  }

  Future<void> toggleFavorite(Song song) async {
    final api = KugouApiClient();
    final isLoggedIn = api.isLoggedIn;

    // 动态获取"我喜欢"歌单的 listId
    final playlist = await _getMyFavoritePlaylist();
    final listid = playlist?.listId ?? '2';

    if (_favoriteIds.contains(song.id)) {
      // 先调 API，成功后再更新本地状态
      if (isLoggedIn) {
        try {
          final fileIds = await _resolveFavoriteRecordFileId(listid, song);
          final resp = await api.deletePlaylistTracks(listid, fileIds);
          // 上游按 fileid 匹配，未命中时不报错也不删除；留日志便于对照
          if (resp == null || (resp['status'] != null && resp['status'] != 1)) {
            debugPrint(
              '[Favorites] 取消收藏可能未生效: listid=$listid fileids=$fileIds resp=$resp',
            );
          }
        } catch (e) {
          notifyListeners();
          return;
        }
      }
      _favoriteIds.remove(song.id);
      _favorites.removeWhere((s) => s.id == song.id);
      await _repository.removeFavorite(song.id);
      _favoriteRecordFileIds.remove(song.id);
      invalidateCloudFavoriteSongs();
      _dropFromCloudSnapshot(song.id);
    } else {
      _favoriteIds.add(song.id);
      _favorites.insert(0, song);
      await _repository.addFavorite(song);
      // 重新收藏会生成新的歌单记录，旧记录 fileid 作废（否则下次
      // 取消收藏会拿着已删除的旧 fileid 去删，静默失败）
      _favoriteRecordFileIds.remove(song.id);
      invalidateCloudFavoriteSongs();

      if (isLoggedIn) {
        final data = buildTrackAddData(song);
        // 后台同步，不阻塞 UI；失败时静默记录，下次启动时重试
        api.addPlaylistTracks(listid, data).then((result) {
          if (result == null) {
            // 同步失败：记录日志，可后续扩展为待同步队列
            debugPrint('[Favorites] 同步到服务器失败，song=${song.id}, listid=$listid');
          }
        }).catchError((_) {});
      }
    }
    notifyListeners();
  }

  Future<void> removeFavorite(String songId) async {
    await _repository.removeFavorite(songId);
    _favoriteIds.remove(songId);
    _favorites.removeWhere((s) => s.id == songId);
    invalidateCloudFavoriteSongs();
    notifyListeners();
  }

  Future<Map<String, dynamic>?> createPlaylist(String name) async {
    final api = KugouApiClient();
    final userid = api.userid;
    if (userid == null) return null;
    return await api.createPlaylist(
      name,
      listCreateUserid: userid,
    );
  }

  Future<Map<String, dynamic>?> addTrackToPlaylist(
    String listid,
    Song song,
  ) async {
    final api = KugouApiClient();
    // 与「添加到歌单」共用同一份拼装（四段齐全，两段在部分曲库下会被上游拒）
    return await api.addPlaylistTracks(listid, buildTrackAddData(song));
  }

  Future<Map<String, dynamic>?> removeTrackFromPlaylist(
    String listid,
    String fileid,
  ) async {
    final api = KugouApiClient();
    return await api.deletePlaylistTracks(listid, fileid);
  }

  Future<Map<String, dynamic>?> deletePlaylist(String listid, {int type = 1}) async {
    final api = KugouApiClient();
    return await api.deletePlaylist(listid, type: type);
  }

  Future<Map<String, dynamic>?> getUserPlaylists({
    int page = 1,
    int pagesize = 30,
  }) async {
    final api = KugouApiClient();
    return await api.getUserPlaylist(page: page, pagesize: pagesize);
  }
}
