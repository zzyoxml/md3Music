import 'package:flutter/foundation.dart';

import '../../data/models/song.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../utils/app_toast.dart';
import 'media_notification_service.dart';
import 'song_query_matcher.dart';

/// 车机/第三方桥接的「语音点歌」桥。
///
/// 两个标准入口（都由原生侧转进 `com.md3music.md3music/floating_lyric` 通道）：
///
/// 1. `playFromSearch`：framework `TransportControls.playFromSearch(query, extras)`
///    → 本类搜索后**打分择优**起播，整批搜索结果作为队列；
/// 2. `browseSearch`：legacy `MediaBrowserCompat.search(query, extras, cb)`
///    → 返回候选列表，桥接端自绘；选中项经 `playFromMediaId("md3srch:N")` 回播。
///
/// 为什么放在独立服务而不是 PlayerProvider 里：这条链只服务原生桥接，且需要
/// "最新指令覆盖旧指令"的独立代次（PlayerProvider 已有自己的 `_issuePlaybackRequest`
/// 代次，语义不同，混用会让语音指令与用户点击互相作废）。
class VoiceSearchBridge {
  VoiceSearchBridge._();

  static final VoiceSearchBridge instance = VoiceSearchBridge._();

  /// 单次搜索返回的候选上限，与搜索页首屏一致。
  static const int _pageSize = 20;

  PlayerProvider? _player;

  /// 语音指令代次：连续两条指令时只让最后一条落地（否则先发出的慢请求会覆盖后发的）。
  int _seq = 0;

  /// App 首帧后调用（provider 已创建）；重复调用为换绑（引擎重建场景）。
  void attach({required PlayerProvider player}) {
    _player = player;
    MediaNotificationService.onPlayFromSearch = _handlePlayFromSearch;
    MediaNotificationService.onBrowseSearch = browseSearch;
    MediaNotificationService.onSearchResultPlay = (payload) {
      _handleSearchResultPlay(payload);
    };
    MediaNotificationService.onSearchResultExpired = _handleExpired;
    debugPrint('[VoiceSearch] attach: player=${player.hashCode}');
  }

  /// App 退出/引擎重建时解绑（按 identity 摘，避免清掉别人的回调）。
  void dispose() {
    _player = null;
    _seq++;
    if (MediaNotificationService.onPlayFromSearch == _handlePlayFromSearch) {
      MediaNotificationService.onPlayFromSearch = null;
    }
    if (MediaNotificationService.onBrowseSearch == browseSearch) {
      MediaNotificationService.onBrowseSearch = null;
    }
    MediaNotificationService.onSearchResultPlay = null;
    MediaNotificationService.onSearchResultExpired = null;
  }

  void _handlePlayFromSearch(String query) {
    // onPlayFromSearch 是同步 void 签名（原生侧 ack 语义为"已受理"），
    // 这里 fire-and-forget，成败都由 toast 反馈。
    // ignore: discarded_futures
    playFromSearch(query);
  }

  /// 语音点歌主链路：登录校验 → 搜索 → 打分择优 → 整批入队起播。
  ///
  /// 失败一律「提示 + 保持当前播放」：车机上打断正在播放的音乐比不播更糟，
  /// 而且 `playFromSearch` 没有标准失败回调，桥接端也无从重试。
  Future<void> playFromSearch(String query) async {
    final player = _player;
    if (player == null) return;
    final keyword = query.trim();
    if (keyword.isEmpty) {
      showToast('没听清，请再说一次');
      return;
    }
    final seq = ++_seq;

    final apiClient = KugouApiClient();
    if (!await apiClient.isLoggedInWhenReady()) {
      if (seq != _seq) return;
      // 不触发 onLoginRequired：车机场景弹登录页没人操作，只会挡住播放器。
      showToast('请先登录后再语音点歌', long: true);
      return;
    }

    final songs = await _searchSongs(apiClient, keyword);
    if (seq != _seq) return;
    if (songs == null) {
      showToast('语音搜索失败，请稍后再试');
      return;
    }
    if (songs.isEmpty) {
      showToast('未找到「$keyword」');
      return;
    }

    final candidates = <QueryCandidate>[
      for (var i = 0; i < songs.length; i++)
        QueryCandidate(
          title: songs[i].songName,
          artist: songs[i].artistName ?? '',
          index: i,
        ),
    ];
    final bestIndex = pickBestIndex(keyword, candidates);
    if (bestIndex == null) {
      showToast('未找到匹配「$keyword」的歌曲');
      return;
    }

    final playable = <Song>[];
    for (final detail in songs) {
      try {
        playable.add(detail.toSong());
      } catch (e) {
        debugPrint('[VoiceSearch] toSong 失败: $e');
      }
    }
    if (playable.isEmpty) {
      showToast('搜索结果无法播放');
      return;
    }
    // 搜索过滤后下标可能漂移——按 id 重新定位最优曲目。
    final bestSong = songs[bestIndex].hash;
    var startIndex = playable.indexWhere((song) => song.id == bestSong);
    if (startIndex < 0) startIndex = 0;

    debugPrint('[VoiceSearch] playFromSearch "$keyword" → '
        '${playable[startIndex].displayName} / ${playable[startIndex].artist}');
    await player.playOnlinePlaylist(playable, startIndex);
  }

  /// legacy browse 搜索：返回候选列表给桥接端。
  ///
  /// 不做登录校验（搜索本身匿名可用）；返回字段里带 `albumId`/`albumAudioId`，
  /// 原生侧把它们存进 BrowseSearchRegistry，后续回播才能拿到完整音源。
  Future<List<Map<String, Object?>>> browseSearch(String query) async {
    final keyword = query.trim();
    if (keyword.isEmpty) return <Map<String, Object?>>[];
    final songs = await _searchSongs(KugouApiClient(), keyword);
    if (songs == null || songs.isEmpty) return <Map<String, Object?>>[];
    return <Map<String, Object?>>[
      for (final detail in songs)
        <String, Object?>{
          'id': detail.hash,
          'title': detail.songName,
          'artist': detail.artistName ?? '',
          'album': detail.albumName ?? '',
          'albumId': detail.albumId,
          'albumAudioId': detail.albumAudioId,
          'artworkUri': detail.artworkUri,
          'durationMs': detail.duration * 1000,
        },
    ];
  }

  /// 桥接端点回候选条目：按 payload 还原 Song 后起播（单曲队列）。
  void _handleSearchResultPlay(Map<String, Object?> payload) {
    final player = _player;
    if (player == null) return;
    final hash = payload['id'] as String?;
    if (hash == null || hash.isEmpty) {
      _handleExpired();
      return;
    }
    final title = (payload['title'] as String?)?.trim();
    final artist = (payload['artist'] as String?)?.trim();
    final durationMs = payload['durationMs'];
    final song = Song(
      id: hash,
      title: title == null || title.isEmpty ? '未知歌曲' : title,
      artist: artist == null || artist.isEmpty ? '未知歌手' : artist,
      album: payload['album'] as String? ?? '',
      duration: Duration(
        milliseconds: durationMs is num ? durationMs.toInt() : 0,
      ),
      isOnline: true,
      albumId: payload['albumId'] as String?,
      albumAudioId: payload['albumAudioId'] as String?,
      artworkUri: payload['artworkUri'] as String?,
    );
    debugPrint('[VoiceSearch] playSearchResult ${song.displayName}');
    // 单曲入队：桥接端点的是"这一条候选"，不该把整批塞进队列。
    // ignore: discarded_futures
    player.playOnlinePlaylist(<Song>[song], 0);
  }

  void _handleExpired() {
    showToast('搜索结果已失效，请重新搜索', long: true);
  }

  /// 搜索歌曲。返回 `null` 表示请求失败（与「有结果但为空」区分：
  /// 前者提示"搜索失败"，后者提示"未找到该关键词"）。
  Future<List<KugouSongDetail>?> _searchSongs(
    KugouApiClient apiClient,
    String keyword,
  ) async {
    try {
      final result = await apiClient.search(keyword, pagesize: _pageSize);
      return result?.songs ?? const <KugouSongDetail>[];
    } catch (e) {
      debugPrint('[VoiceSearch] 搜索失败: $e');
      return null;
    }
  }
}
