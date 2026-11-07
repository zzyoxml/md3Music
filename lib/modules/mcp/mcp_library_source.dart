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

  /// 当前账号的歌单列表原始响应（`/user/playlist`；条目含可写的 `listid`）。
  Future<Map<String, dynamic>?> userPlaylist(int pagesize);

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
    var detail = await _gateway.songDetail(hash);
    if (detail == null) return null;
    // /audio 完全不返回封面字段（项目铁律 17：实测 0 个 img/pic/cover 键），
    // 封面 100% 依赖 /search 命中同 hash 的候选（与一起听富化同构）。
    // 同时 /audio（kmr）响应里的 audio_id 与 MixSongID 是不同 ID 域，
    // fromJson 已不再把它误当 albumAudioId（issue #216：错 ID 传给
    // /song/url 会解析到无关音源），正确的 albumAudioId/albumId 同样
    // 依赖搜索候选补齐。
    // 因此封面、albumAudioId、专辑名任一缺失时用「歌名 歌手」搜一次，
    // 按 hash 精确匹配候选回填；搜不到或网络异常就原样返回（不影响播放本体），
    // 不做重试风暴。专辑名同为 /audio 缺失字段（实测 md3_get_song_detail 的
    // album 为空），一并列入补齐项。
    bool missing(String? v) => v == null || v.isEmpty || v == '0';
    final needAlbumName = (detail.albumName ?? '').trim().isEmpty;
    if (!missing(detail.artworkUri) &&
        !missing(detail.albumAudioId) &&
        !needAlbumName) {
      return detail;
    }
    final keyword = <String>[
      if (detail.songName.trim().isNotEmpty) detail.songName,
      if ((detail.artistName ?? '').trim().isNotEmpty) detail.artistName!,
    ].join(' ').trim();
    if (keyword.isEmpty) return detail;
    try {
      final result = await _gateway.search(keyword, pagesize: 30);
      String? cover;
      String? albumAudioId;
      String? albumId;
      String? albumName;
      for (final candidate in result?.songs ?? const <KugouSongDetail>[]) {
        if (candidate.hash.toLowerCase() != hash.toLowerCase()) continue;
        cover ??= (candidate.artworkUri ?? '').isEmpty
            ? null
            : candidate.artworkUri;
        albumAudioId ??= missing(candidate.albumAudioId)
            ? null
            : candidate.albumAudioId;
        albumId ??= missing(candidate.albumId) ? null : candidate.albumId;
        if (needAlbumName) {
          albumName ??= (candidate.albumName ?? '').trim().isEmpty
              ? null
              : candidate.albumName;
        }
        // 需要的字段全部拿到首个候选值后停止扫描；任一字段此前落空时
        // 继续查找后续同 hash 候选，避免遗漏封面或关联 ID（issue #216 本地修复第 3 条）。
        if (cover != null &&
            albumAudioId != null &&
            albumId != null &&
            (!needAlbumName || albumName != null)) {
          break;
        }
      }
      detail = detail.copyWith(
        artworkUri: cover,
        albumAudioId: albumAudioId,
        albumId: albumId,
        albumName: albumName,
      );
    } catch (_) {
      // 补齐失败不阻断播放
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
  Future<List<KugouPlaylistBrief>> getUserPlaylists({int limit = 30}) async {
    // /user/playlist 原始结构（信封 data 下 info/list/special_list 三候选）
    // 与「添加到歌单」对话框 loadUserPlaylistsSorted 同一口径解析。
    final raw = await _gateway.userPlaylist(limit.clamp(1, 50));
    if (raw == null) return const <KugouPlaylistBrief>[];
    final data = raw['data'];
    List<dynamic> rows = const [];
    if (data is List) {
      rows = data;
    } else if (data is Map) {
      rows = data['info'] ?? data['list'] ?? data['special_list'] ?? const [];
    }
    final out = <KugouPlaylistBrief>[];
    for (final item in rows) {
      if (item is! Map) continue;
      final brief =
          KugouPlaylistBrief.fromJson(Map<String, dynamic>.from(item));
      // 只暴露当前账号自己创建的歌单：收藏页里 type=1 的订阅歌单不可写，
      // 拿它的 id 去 add_song 必然失败（实测「上游无响应」就是这种 id）。
      if (brief.type != 0) continue;
      // 系统「我喜欢」歌单走红心机制而非歌单加歌（与对话框同判定）。
      if (brief.name == '我喜欢' || item['is_def'] == 2) continue;
      if (out.length < limit) out.add(brief);
    }
    return out;
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
  Future<Map<String, dynamic>?> userPlaylist(int pagesize) =>
      client.getUserPlaylist(page: 1, pagesize: pagesize);

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
  Future<void> addSongToPlaylist(String hash, String listid,
      {KugouSongDetail? enriched}) async {
    // data 契约：`名称|hash|专辑id|mixsongid`（Rust 端 playlist.rs
    // handle_tracks_add 按竖线切分，专辑 id/mixsongid 缺省 0）。
    // 歌名走 toSong() 的清洗结果，与播放/搜索回执口径一致；格式与既有调用方
    // add_to_playlist_dialog / favorites_provider 完全相同。
    // 优先复用工具层传入的补齐详情（含正确 mixsongid）；未传时再裸取一次，
    // 缺 albumAudioId 就按 0 入库（上游可容），不再依赖 /audio 的 audio_id。
    final detail = enriched ?? await _gateway.songDetail(hash);
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
  Future<String?> createPlaylist(String name) async {
    final r = await _gateway.createPlaylist(name);
    _ensureSuccess(r, '创建歌单失败');
    // 上游 /cloudlist.service/v5/add_list 成功响应在 data 里回新 listid
    // （favorites_page 建档后同样从响应取）。取不到只说明回执缺 ID，
    // 不代表创建失败，故返回 null 而不是报错。
    final data = r?['data'];
    if (data is Map) {
      final listid = data['listid'] ?? data['list_id'] ?? data['listId'];
      final s = listid?.toString() ?? '';
      if (s.isNotEmpty && s != '0') return s;
    }
    return null;
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
