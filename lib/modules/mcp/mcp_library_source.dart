import 'package:md3music/modules/mcp/mcp_ports.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

/// [KugouApiClient] 的最小子集，即本文件真正用到的那些方法。
///
/// 为什么需要这层接缝：`KugouApiClient` 是单例（私有构造 + factory），外部既
/// 不能继承也无法低成本实现其全部成员，没有接缝就无法在单元测试里验证截断 /
/// 歌词降级这类纯逻辑，只能联网跑集成测试。
abstract interface class KugouLibraryGateway {
  Future<KugouSearchResult?> search(String keyword, {required int pagesize});

  Future<KugouSongDetail?> songDetail(String hash);

  Future<KugouLyric?> lyric(String hash);

  Future<List<KugouAlbumBrief>?> searchAlbums(String keywords,
      {int pagesize = 20});

  Future<List<KugouArtistBrief>?> searchArtists(String keywords,
      {int pagesize = 20});

  Future<List<KugouPlaylistBrief>?> searchPlaylists(String keywords,
      {int pagesize = 20});

  Future<KugouPlaylistSongs?> getPlaylistSongs(String globalCollectionId,
      {int pagesize = 30});

  Future<List<KugouSongDetail>?> getRecommendDaily();

  Future<List<KugouSongDetail>?> getPersonalFm();

  Future<KugouRankList?> getRankList();

  Future<List<KugouSongDetail>?> getRankAudio(String rankId,
      {int pagesize = 30});

  Future<Map<String, dynamic>?> getUserListen({int type = 0});
}

/// [McpLibrarySource] 的真实实现：全部走既有的 [KugouApiClient]
/// （即本地 Rust 服务器 → 酷狗上游），不新增任何网络通道。
class KugouApiClientLibrarySource implements McpLibrarySource {
  KugouApiClientLibrarySource([KugouLibraryGateway? gateway])
      : _gateway = gateway ?? _KugouApiClientGateway();

  final KugouLibraryGateway _gateway;

  @override
  Future<List<KugouSongDetail>> searchSongs(
    String keyword, {
    int limit = 10,
  }) async {
    final clamped = limit.clamp(1, 30);
    final result = await _gateway.search(keyword, pagesize: clamped);
    final songs = result?.songs ?? const <KugouSongDetail>[];
    return songs.take(clamped).toList(growable: false);
  }

  @override
  Future<KugouSongDetail?> getSongDetail(String hash) async {
    final detail = await _gateway.songDetail(hash);
    if (detail == null) return null;
    // /audio 完全不返回封面字段（项目铁律 17：实测 0 个 img/pic/cover 键），
    // 封面 100% 依赖 /search 命中同 hash 的候选（与一起听富化同构）。
    // 因此封面缺失时用「歌名 歌手」搜一次，按 hash 精确匹配候选回填；
    // 搜不到或网络异常就原样返回（不影响播放本体），不做重试风暴。
    if ((detail.artworkUri ?? '').isNotEmpty) return detail;
    final keyword = <String>[
      if (detail.songName.trim().isNotEmpty) detail.songName,
      if ((detail.artistName ?? '').trim().isNotEmpty) detail.artistName!,
    ].join(' ').trim();
    if (keyword.isEmpty) return detail;
    try {
      final result = await _gateway.search(keyword, pagesize: 30);
      for (final candidate in result?.songs ?? const <KugouSongDetail>[]) {
        if (candidate.hash.toLowerCase() == hash.toLowerCase() &&
            (candidate.artworkUri ?? '').isNotEmpty) {
          return detail.copyWith(artworkUri: candidate.artworkUri);
        }
      }
    } catch (_) {
      // 封面补齐失败不阻断播放
    }
    return detail;
  }

  @override
  Future<String?> getLyric(String hash) async {
    final lyric = await _gateway.lyric(hash);
    final text = lyric?.decodedContent ?? lyric?.content;
    if (text == null || text.trim().isEmpty) return null;
    return text;
  }

  @override
  Future<List<KugouAlbumBrief>?> searchAlbums(String keyword,
      {int limit = 10}) async {
    final clamped = limit.clamp(1, 20);
    final r = await _gateway.searchAlbums(keyword, pagesize: clamped);
    return r?.take(clamped).toList(growable: false);
  }

  @override
  Future<List<KugouArtistBrief>?> searchArtists(String keyword,
      {int limit = 10}) async {
    final clamped = limit.clamp(1, 20);
    final r = await _gateway.searchArtists(keyword, pagesize: clamped);
    return r?.take(clamped).toList(growable: false);
  }

  @override
  Future<List<KugouPlaylistBrief>?> searchPlaylists(String keyword,
      {int limit = 10}) async {
    final clamped = limit.clamp(1, 20);
    final r = await _gateway.searchPlaylists(keyword, pagesize: clamped);
    return r?.take(clamped).toList(growable: false);
  }

  @override
  Future<KugouPlaylistSongs?> getPlaylistSongs(String globalCollectionId,
      {int limit = 30}) async {
    final clamped = limit.clamp(1, 30);
    return _gateway.getPlaylistSongs(globalCollectionId, pagesize: clamped);
  }

  @override
  Future<List<KugouSongDetail>?> getDailyRecommend() =>
      _gateway.getRecommendDaily();

  @override
  Future<List<KugouSongDetail>?> getPersonalFm() => _gateway.getPersonalFm();

  @override
  Future<KugouRankList?> getRankList() => _gateway.getRankList();

  @override
  Future<List<KugouSongDetail>?> getRankAudio(String rankId,
      {int limit = 30}) async {
    final clamped = limit.clamp(1, 30);
    final songs = await _gateway.getRankAudio(rankId, pagesize: clamped);
    return songs?.take(clamped).toList(growable: false);
  }

  @override
  Future<Map<String, dynamic>?> getUserListen({int type = 0}) =>
      _gateway.getUserListen(type: type);
}

class _KugouApiClientGateway implements KugouLibraryGateway {
  KugouApiClient? _client;

  // 懒构造：单测注入假网关时不会碰真实客户端（它会启动 dio / 读本地存储）
  KugouApiClient get client => _client ??= KugouApiClient();

  @override
  Future<KugouSearchResult?> search(String keyword, {required int pagesize}) =>
      client.search(keyword, page: 1, pagesize: pagesize);

  @override
  Future<KugouSongDetail?> songDetail(String hash) => client.getSongDetail(hash);

  @override
  Future<KugouLyric?> lyric(String hash) => client.getLyric(hash);

  @override
  Future<List<KugouAlbumBrief>?> searchAlbums(String keywords,
          {int pagesize = 20}) =>
      client.searchAlbums(keywords, page: 1, pagesize: pagesize);

  @override
  Future<List<KugouArtistBrief>?> searchArtists(String keywords,
          {int pagesize = 20}) =>
      client.searchArtists(keywords, page: 1, pagesize: pagesize);

  @override
  Future<List<KugouPlaylistBrief>?> searchPlaylists(String keywords,
          {int pagesize = 20}) =>
      client.searchPlaylists(keywords, page: 1, pagesize: pagesize);

  @override
  Future<KugouPlaylistSongs?> getPlaylistSongs(String globalCollectionId,
          {int pagesize = 30}) =>
      client.getPlaylistSongs(globalCollectionId, page: 1, pagesize: pagesize);

  @override
  Future<List<KugouSongDetail>?> getRecommendDaily() =>
      client.getRecommendDaily();

  @override
  Future<List<KugouSongDetail>?> getPersonalFm() => client.getPersonalFm();

  @override
  Future<KugouRankList?> getRankList() => client.getRankList();

  @override
  Future<List<KugouSongDetail>?> getRankAudio(String rankId,
          {int pagesize = 30}) =>
      client.getRankAudio(rankId: rankId, page: 1, pagesize: pagesize);

  @override
  Future<Map<String, dynamic>?> getUserListen({int type = 0}) =>
      client.getUserListen(type: type);
}

/// 曲库写操作的客户端接缝（真实实现走 [KugouApiClient] 既有方法，不新增网络通道）。
abstract interface class KugouLibraryWriteGateway {
  /// 按 hash 取歌曲详情（加歌前补齐 `名称|专辑id|mixsongid` 用）。
  Future<KugouSongDetail?> songDetail(String hash);

  /// 歌单加歌：[listid] 为歌单数字 ID，[data] 为 `名称|hash|专辑id|mixsongid`
  /// （多首逗号分隔）。上游 `/playlist/tracks/add` → `/cloudlist.service/v6/add_song`。
  Future<Map<String, dynamic>?> addPlaylistTracks(String listid, String data);

  /// 新建歌单。上游 `/playlist/add` → `/cloudlist.service/v5/add_list`。
  Future<Map<String, dynamic>?> createPlaylist(String name);
}

/// 写网关：懒构造 KugouApiClient（单例），与读源共享同一客户端。
class _KugouApiClientWriteGateway implements KugouLibraryWriteGateway {
  KugouApiClient? _client;

  // 懒构造：单测注入假网关时不会碰真实客户端（它会启动 dio / 读本地存储）
  KugouApiClient get client => _client ??= KugouApiClient();

  @override
  Future<KugouSongDetail?> songDetail(String hash) =>
      client.getSongDetail(hash);

  @override
  Future<Map<String, dynamic>?> addPlaylistTracks(String listid, String data) =>
      client.addPlaylistTracks(listid, data);

  @override
  Future<Map<String, dynamic>?> createPlaylist(String name) =>
      client.createPlaylist(name);
}

/// [McpLibraryWriteSource] 的真实实现：全部走 [KugouApiClient] 既有的
/// 歌单写方法，不新增任何网络通道。
///
/// 响应成败判定对齐既有调用方（favorites_provider / add_to_playlist_dialog /
/// playlist_page）：`null` 即失败；`status` 出现且既非 1 也非 200 视为失败
/// （酷狗 cloudlist 系成功码为 1，兼容 200 防御其它响应形态）。
class KugouApiClientLibraryWriteSource implements McpLibraryWriteSource {
  KugouApiClientLibraryWriteSource([KugouLibraryWriteGateway? gateway])
      : _gateway = gateway ?? _KugouApiClientWriteGateway();

  final KugouLibraryWriteGateway _gateway;

  @override
  Future<void> addSongToPlaylist(String hash, String listid) async {
    // data 契约：`名称|hash|专辑id|mixsongid`（Rust 端 playlist.rs
    // handle_tracks_add 按竖线切分，专辑 id/mixsongid 缺省 0）。
    // 歌名走 toSong() 的清洗结果，与播放/搜索回执口径一致；格式与既有调用方
    // add_to_playlist_dialog / favorites_provider 完全相同。
    final detail = await _gateway.songDetail(hash);
    if (detail == null) {
      throw StateError('未找到 hash 为 $hash 的歌曲，无法加入歌单');
    }
    final song = detail.toSong();
    final data =
        '${song.title}|${song.id}|${song.albumId ?? 0}|${int.tryParse(song.albumAudioId ?? '') ?? 0}';
    final r = await _gateway.addPlaylistTracks(listid, data);
    _ensureSuccess(r, '加入歌单失败');
  }

  @override
  Future<void> createPlaylist(String name) async {
    final r = await _gateway.createPlaylist(name);
    _ensureSuccess(r, '创建歌单失败');
  }

  void _ensureSuccess(Map<String, dynamic>? r, String action) {
    if (r == null) {
      throw StateError('$action（上游无响应，可能未登录）');
    }
    final status = r['status'];
    if (status is num && status != 1 && status != 200) {
      throw StateError('$action（status=$status）');
    }
  }
}
