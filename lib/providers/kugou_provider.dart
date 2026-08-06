import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../data/models/album.dart';
import '../data/models/artist.dart';
import '../data/models/playlist.dart';
import '../data/models/song.dart';
import '../data/repositories/settings_repository.dart';
import '../services/stream_cache_manager.dart';
import '../services/kugou_api/kugou_api_client.dart';
import '../services/kugou_api/kugou_models.dart';

/// 待处理的二次安全验证请求（签到/登录遇 error_code=20028 时产生）。
/// UI 层监听 [KugouProvider.pendingVerifyCaptcha]，弹出腾讯滑块验证码，
/// 验证通过后调用 [KugouProvider.completeVerifyCaptcha] 回填结果。
class VerifyCaptchaRequest {
  final String eventid;
  final int vType;
  final String txappid;
  final Completer<String?> completer;

  VerifyCaptchaRequest({
    required this.eventid,
    required this.vType,
    required this.txappid,
    required this.completer,
  });
}

class KugouProvider extends ChangeNotifier {
  final KugouApiClient _apiClient = KugouApiClient();

  KugouProvider() {
    _loadLocalSignedDays();
    _autoConnect();
  }

  Future<void> _loadLocalSignedDays() async {
    try {
      final days = await SettingsRepository().getSignedDays();
      if (days.isNotEmpty) {
        _localSignedDays.addAll(days);
        notifyListeners();
      }
    } catch (_) {}
  }

  /// 打卡成功后标记今天已签（本地兜底，保证日历立即打勾并持久化）
  Future<void> _markSignedToday() async {
    final now = DateTime.now();
    final key =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    if (_localSignedDays.add(key)) {
      notifyListeners();
      try {
        await SettingsRepository().setSignedDays(_localSignedDays);
      } catch (_) {}
    }
  }

  Future<void> _autoConnect() async {
    try {
      await _apiClient.registerDevice();

      if (_apiClient.isLoggedIn) {
        _isLoggedIn = true;
        await _fetchUserInfo();
        await autoReceiveVipIfNeeded();
      }
    } catch (_) {}
  }

  KugouApiClient get apiClient => _apiClient;

  KugouSearchResult? _searchResults;
  List<String> _hotSearchKeywords = [];
  KugouRankList? _rankList;
  List<KugouSongDetail> _recommendSongs = [];
  KugouPlaylist? _playlistDetail;
  KugouArtistDetail? _artistDetail;
  KugouAlbumDetail? _albumDetail;
  List<String> _searchSuggest = [];
  KugouPlayUrl? _songUrl;
  KugouLyric? _lyric;
  String? _lyricSongId;
  KugouCommentList? _comments;
  KugouPlaylistSongs? _playlistSongs;
  List<KugouSongDetail> _personalFmSongs = [];
  KugouPlaylistCategory? _playlistCategory;
  List<KugouPlaylistBrief> _playlistList = [];
  bool _isLoading = false;
  String? _error;
  KugouQrKey? _qrKey;
  KugouQrCreate? _qrData;
  bool _isLoggedIn = false;
  KugouUserDetail? _userInfo;
  List<KugouSongDetail> _rankSongs = [];
  List<KugouSongDetail> _currentPlaylistSongs = [];

  Map<String, dynamic>? _yuekuData;
  Map<String, dynamic>? _yuekuBanner;
  Map<String, dynamic>? _sceneData;
  Map<String, dynamic>? _themeMusicData;
  Map<String, dynamic>? _ipHomeData;
  Map<String, dynamic>? _ipZoneData;
  Map<String, dynamic>? _fmData;
  Map<String, dynamic>? _sheetData;
  Map<String, dynamic>? _everydayHistory;
  Map<String, dynamic>? _topAlbumData;
  Map<String, dynamic>? _topSongData;
  KugouUserVipDetail? _vipInfo;
  Map<String, dynamic>? _vipMonthRecord;
  // 本地打卡兜底：服务端 /youth/month/vip/record 有时不及时返回当天记录，
  // 用本地集合保证“今天签到后日历立即打勾”，并持久化跨重启。
  final Set<String> _localSignedDays = {};
  Map<String, dynamic>? _userHistoryData;
  Map<String, dynamic>? _brushData;
  List<KugouSongDetail> _aiRecommendSongs = [];
  Map<String, dynamic>? _youthData;
  Map<String, dynamic>? _longAudioData;
  Map<String, dynamic>? _fmRecommendData;
  List<KugouFmInfo> _fmClassList = [];
  List<KugouThemeInfo> _themePlaylistData = [];
  List<KugouSheetInfo> _sheetExploreList = [];
  List<KugouYouthChannel> _youthChannels = [];
  List<KugouLongAudioAlbum> _longAudioAlbums = [];
  List<KugouLongAudioAlbum> _longAudioVipAlbums = [];
  List<KugouLongAudioAlbum> _longAudioWeekAlbums = [];
  List<KugouLongAudioAudio> _longAudioAudios = [];
  Map<String, dynamic>? _longAudioAlbumDetail;
  Map<String, dynamic>? _serverNow;

  // ==================== Loading counter ====================
  int _loadingCount = 0;

  void _beginLoading() {
    final wasLoading = _isLoading;
    _loadingCount++;
    _isLoading = true;
    if (!wasLoading) notifyListeners();
  }

  void _endLoading() {
    final wasLoading = _isLoading;
    if (_loadingCount > 0) _loadingCount--;
    if (_loadingCount == 0) {
      _isLoading = false;
      if (wasLoading) notifyListeners();
    }
  }

  void _setLoading(bool v) {
    if (v) {
      _beginLoading();
    } else {
      _endLoading();
    }
  }

  // ==================== Data freshness tracking ====================
  static const Duration _freshTtl = Duration(minutes: 5);
  final Map<String, DateTime> _dataTimestamps = {};

  bool _isDataFresh(String key) {
    final ts = _dataTimestamps[key];
    if (ts == null) return false;
    return DateTime.now().difference(ts) < _freshTtl;
  }

  /// 发现页所有关键数据是否都处于新鲜期内
  bool get isDiscoverDataFresh =>
      _isDataFresh('rankList') &&
      _isDataFresh('recommendDaily') &&
      _isDataFresh('playlist') &&
      _isDataFresh('yuekuBanner') &&
      _isDataFresh('sceneMusic') &&
      _isDataFresh('themeMusic') &&
      _isDataFresh('themePlaylist') &&
      _isDataFresh('ipHome') &&
      _isDataFresh('personalFm');

  // ==================== Search result caching ====================
  final Map<String, _SearchCacheEntry> _searchCache = {};
  final Map<String, KugouSearchResult> _searchResultsByType = {};
  String? _lastSearchKeyword;

  /// 是否有指定关键词 + 类型的有效缓存
  bool hasSearchResultForType(String keyword, String type) {
    if (keyword.isEmpty) return false;
    final key = '$keyword:$type';
    final entry = _searchCache[key];
    if (entry != null && !entry.isExpired) return true;
    return _lastSearchKeyword == keyword &&
        _searchResultsByType.containsKey(type);
  }

  /// 获取缓存中的搜索结果（可能为 null）
  KugouSearchResult? getCachedSearchResult(String keyword, String type) {
    final key = '$keyword:$type';
    final entry = _searchCache[key];
    if (entry != null && !entry.isExpired) return entry.result;
    if (_lastSearchKeyword == keyword) {
      return _searchResultsByType[type];
    }
    return null;
  }

  /// 从缓存恢复搜索结果到 [_searchResults]，不触发网络请求
  void restoreSearchResultFromCache(String keyword, String type) {
    final key = '$keyword:$type';
    final entry = _searchCache[key];
    if (entry != null && !entry.isExpired) {
      _searchResults = entry.result;
      _searchResultsByType[type] = entry.result;
      _lastSearchKeyword = keyword;
      _error = null;
      notifyListeners();
      return;
    }
    if (_lastSearchKeyword == keyword &&
        _searchResultsByType.containsKey(type)) {
      _searchResults = _searchResultsByType[type];
      _error = null;
      notifyListeners();
    }
  }

  KugouSearchResult? get searchResults => _searchResults;
  List<String> get hotSearchKeywords => _hotSearchKeywords;
  KugouRankList? get rankList => _rankList;
  List<KugouSongDetail> get recommendSongs => _recommendSongs;
  KugouPlaylist? get playlistDetail => _playlistDetail;
  KugouArtistDetail? get artistDetail => _artistDetail;
  KugouAlbumDetail? get albumDetail => _albumDetail;
  List<String> get searchSuggest => _searchSuggest;
  KugouPlayUrl? get songUrl => _songUrl;

  /// 当前歌词（Task 15 双请求合并后的对象，同时携带 KRC 与 LRC 明文）。
  /// 旧调用方继续使用此 getter，通过 [KugouLyric.displayLyric] 自动取
  /// KRC 优先、降级 LRC 的文本——等价于 `krcLyric ?? lrcLyric`，
  /// 因为 Task 15 返回的是同一个 `KugouLyric` 对象。
  KugouLyric? get lyric => krcLyric ?? lrcLyric;

  /// 携带 KRC 明文（逐字）的 `KugouLyric`（如有）。
  /// 调用方应使用 `krcLyric?.displayKrcLyric` 取 KRC 明文文本。
  /// Task 15 双请求返回的同一对象，KRC 部分可能为 null（仅 LRC 可用）。
  KugouLyric? get krcLyric => _lyric;

  /// 携带 LRC 明文（行级）的 `KugouLyric`（如有）。
  /// 调用方应使用 `lrcLyric?.displayLrcLyric` 取 LRC 明文文本。
  /// 与 [krcLyric] 引用同一对象，Task 15 合并后两者共享存储，
  /// 由模型层 `displayKrcLyric` / `displayLrcLyric` 区分。
  KugouLyric? get lrcLyric => _lyric;

  KugouCommentList? get comments => _comments;
  KugouPlaylistSongs? get playlistSongs => _playlistSongs;
  List<KugouSongDetail> get personalFmSongs => _personalFmSongs;
  KugouPlaylistCategory? get playlistCategory => _playlistCategory;
  List<KugouPlaylistBrief> get playlistList => _playlistList;
  bool get isLoading => _isLoading;
  String? get error => _error;
  KugouQrKey? get qrKey => _qrKey;
  KugouQrCreate? get qrData => _qrData;
  bool get isLoggedIn => _isLoggedIn;
  String? get userid => _apiClient.userid;
  KugouUserDetail? get userInfo => _userInfo;
  List<KugouSongDetail> get rankSongs => _rankSongs;
  List<KugouSongDetail> get currentPlaylistSongs => _currentPlaylistSongs;
  Map<String, dynamic>? get yuekuData => _yuekuData;
  Map<String, dynamic>? get yuekuBanner => _yuekuBanner;
  Map<String, dynamic>? get sceneData => _sceneData;
  Map<String, dynamic>? get themeMusicData => _themeMusicData;
  Map<String, dynamic>? get ipHomeData => _ipHomeData;
  Map<String, dynamic>? get ipZoneData => _ipZoneData;
  Map<String, dynamic>? get fmData => _fmData;
  Map<String, dynamic>? get sheetData => _sheetData;
  Map<String, dynamic>? get everydayHistory => _everydayHistory;
  Map<String, dynamic>? get topAlbumData => _topAlbumData;
  Map<String, dynamic>? get topSongData => _topSongData;
  KugouUserVipDetail? get vipInfo => _vipInfo;
  Map<String, dynamic>? get vipMonthRecord => _vipMonthRecord;
  Set<String> get localSignedDays => _localSignedDays;
  Map<String, dynamic>? get userHistoryData => _userHistoryData;
  Map<String, dynamic>? get brushData => _brushData;
  List<KugouSongDetail> get aiRecommendSongs => _aiRecommendSongs;
  Map<String, dynamic>? get youthData => _youthData;
  Map<String, dynamic>? get longAudioData => _longAudioData;
  Map<String, dynamic>? get fmRecommendData => _fmRecommendData;
  List<KugouFmInfo> get fmClassList => _fmClassList;
  List<KugouThemeInfo> get themePlaylistData => _themePlaylistData;
  List<KugouSheetInfo> get sheetExploreList => _sheetExploreList;
  List<KugouYouthChannel> get youthChannels => _youthChannels;
  List<KugouLongAudioAlbum> get longAudioAlbums => _longAudioAlbums;
  List<KugouLongAudioAlbum> get longAudioVipAlbums => _longAudioVipAlbums;
  List<KugouLongAudioAlbum> get longAudioWeekAlbums => _longAudioWeekAlbums;
  List<KugouLongAudioAudio> get longAudioAudios => _longAudioAudios;
  Map<String, dynamic>? get longAudioAlbumDetail => _longAudioAlbumDetail;
  Map<String, dynamic>? get serverNow => _serverNow;

  List<Song> get recommendSongsAsSongs =>
      _recommendSongs.map((e) => e.toSong()).toList();
  List<Album> get rankListAsAlbums =>
      _rankList?.ranks.map((e) => e.toAlbum()).toList() ?? [];
  Artist? get artistDetailAsArtist => _artistDetail?.toArtist();
  Album? get albumDetailAsAlbum => _albumDetail?.toAlbum();
  Playlist? get playlistDetailAsPlaylist => _playlistDetail?.toPlaylist();
  List<Song> get playlistSongsAsSongs =>
      _playlistSongs?.songs.map((e) => e.toSong()).toList() ?? [];
  List<Song> get personalFmAsSongs =>
      _personalFmSongs.map((e) => e.toSong()).toList();

  /// 发现页数据是否已加载过（用于避免每次进入都请求）
  bool _hasLoadedDiscoverData = false;
  bool get hasLoadedDiscoverData => _hasLoadedDiscoverData;

  void markDiscoverLoaded() {
    _hasLoadedDiscoverData = true;
  }

  void resetDiscoverLoadedFlag() {
    _hasLoadedDiscoverData = false;
  }

  /// 清除发现页相关内存缓存（保留登录态、当前播放、用户主动进入过的详情）
  void clearMemoryCache() {
    _rankList = null;
    _recommendSongs = [];
    _yuekuBanner = null;
    _themeMusicData = null;
    _sceneData = null;
    _themePlaylistData = [];
    _ipHomeData = null;
    _ipZoneData = null;
    _personalFmSongs = [];
    _hasLoadedDiscoverData = false;
    _dataTimestamps.clear();
    _searchCache.clear();
    _searchResultsByType.clear();
    _lastSearchKeyword = null;
    notifyListeners();
  }

  Future<void> search(String keywords, {String type = 'song'}) async {
    final cacheKey = '$keywords:$type';
    final cached = _searchCache[cacheKey];
    if (cached != null && !cached.isExpired) {
      _searchResults = cached.result;
      _searchResultsByType[type] = cached.result;
      _lastSearchKeyword = keywords;
      _error = null;
      notifyListeners();
      return;
    }

    // 新关键词时清除旧的按类型缓存，避免混淆
    if (_lastSearchKeyword != keywords) {
      _searchResultsByType.clear();
    }

    _beginLoading();
    _error = null;
    try {
      // 只加载第一页，后续由搜索页按需加载更多
      if (type == 'album') {
        final albums = await _apiClient.searchAlbums(
          keywords,
          page: 1,
          pagesize: 20,
        );
        if (albums != null) {
          _searchResults = KugouSearchResult(
            albums: albums,
            total: albums.length,
          );
        } else {
          _error = '搜索失败';
          _searchResults = KugouSearchResult(albums: const [], total: 0);
        }
      } else if (type == 'special') {
        final playlists = await _apiClient.searchPlaylists(
          keywords,
          page: 1,
          pagesize: 20,
        );
        if (playlists != null) {
          _searchResults = KugouSearchResult(
            playlists: playlists,
            total: playlists.length,
          );
        } else {
          _error = '搜索失败';
          _searchResults = KugouSearchResult(playlists: const [], total: 0);
        }
      } else if (type == 'artist') {
        final artists = await _apiClient.searchArtists(
          keywords,
          page: 1,
          pagesize: 30,
        );
        if (artists != null && artists.isNotEmpty) {
          final keyword = keywords.toLowerCase();
          // 只保留名字包含搜索关键词的歌手，按名字去重
          final seen = <String>{};
          final unique = artists
              .where(
                (a) =>
                    a.name.isNotEmpty &&
                    a.name.toLowerCase().contains(keyword) &&
                    seen.add(a.name),
              )
              .toList();
          _searchResults = KugouSearchResult(
            artists: unique,
            total: unique.length,
          );
        } else {
          _error = '搜索失败';
          _searchResults = KugouSearchResult(artists: const [], total: 0);
        }
      } else {
        final result = await _apiClient.search(
          keywords,
          type: type,
          page: 1,
          pagesize: 30,
        );
        if (result != null) {
          _searchResults = result;
        } else {
          _error = '搜索失败';
          _searchResults = KugouSearchResult(songs: const [], total: 0);
        }
      }
      if (_searchResults != null) {
        _searchResultsByType[type] = _searchResults!;
        _lastSearchKeyword = keywords;
        _searchCache[cacheKey] = _SearchCacheEntry(
          result: _searchResults!,
          timestamp: DateTime.now(),
        );
      }
    } catch (e) {
      _error = e.toString();
    }
    _endLoading();
  }

  /// 加载搜索结果的下一页
  Future<void> loadMoreSearchResults({required String type}) async {
    if (_isLoading || _lastSearchKeyword == null) return;
    _isLoading = true;
    notifyListeners();
    try {
      if (type == 'album') {
        final current = _searchResultsByType[type];
        final currentCount = current?.albums.length ?? 0;
        final nextPage = (currentCount ~/ 20) + 1;
        final albums = await _apiClient.searchAlbums(
          _lastSearchKeyword!,
          page: nextPage,
          pagesize: 20,
        );
        if (albums != null && albums.isNotEmpty) {
          final existing = current?.albums ?? [];
          final existingIds = existing.map((a) => a.id).toSet();
          final newAlbums = albums.where((a) => !existingIds.contains(a.id)).toList();
          final merged = [...existing, ...newAlbums];
          _searchResults = KugouSearchResult(
            albums: merged,
            total: merged.length,
          );
          _searchResultsByType[type] = _searchResults!;
        }
      } else if (type == 'special') {
        final current = _searchResultsByType[type];
        final currentCount = current?.playlists.length ?? 0;
        final nextPage = (currentCount ~/ 20) + 1;
        final playlists = await _apiClient.searchPlaylists(
          _lastSearchKeyword!,
          page: nextPage,
          pagesize: 20,
        );
        if (playlists != null && playlists.isNotEmpty) {
          final existing = current?.playlists ?? [];
          final existingIds = existing.map((p) => p.id).toSet();
          final newPlaylists = playlists.where((p) => !existingIds.contains(p.id)).toList();
          final merged = [...existing, ...newPlaylists];
          _searchResults = KugouSearchResult(
            playlists: merged,
            total: merged.length,
          );
          _searchResultsByType[type] = _searchResults!;
        }
      } else if (type == 'artist') {
        // 综合搜索不分页，歌手结果一次性返回
        // 不做加载更多
      } else {
        final current = _searchResultsByType[type];
        final currentCount = current?.songs.length ?? 0;
        final nextPage = (currentCount ~/ 30) + 1;
        final result = await _apiClient.search(
          _lastSearchKeyword!,
          type: type,
          page: nextPage,
          pagesize: 30,
        );
        if (result != null && result.songs.isNotEmpty) {
          final existing = current?.songs ?? [];
          final existingHashes = existing.map((s) => s.hash).toSet();
          final newSongs = result.songs.where((s) => !existingHashes.contains(s.hash)).toList();
          final merged = [...existing, ...newSongs];
          _searchResults = KugouSearchResult(
            songs: merged,
            total: merged.length,
          );
          _searchResultsByType[type] = _searchResults!;
        }
      }
    } catch (e) {
      _error = e.toString();
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> getHotSearch() async {
    _beginLoading();
    _error = null;
    try {
      final result = await _apiClient.getHotSearch();
      if (result != null) {
        _hotSearchKeywords = result;
      } else {
        _error = '获取热搜失败';
      }
    } catch (e) {
      _error = e.toString();
    }
    _endLoading();
  }

  Future<void> getRankList({bool forceRefresh = false}) async {
    if (!forceRefresh && _isDataFresh('rankList')) return;
    _beginLoading();
    _error = null;
    try {
      final result = await _apiClient.getRankList();
      if (result != null) {
        _rankList = result;
        _dataTimestamps['rankList'] = DateTime.now();
      } else {
        _error = '获取排行榜失败';
      }
    } catch (e) {
      _error = e.toString();
    }
    _endLoading();
  }

  Future<void> getRecommendDaily({bool forceRefresh = false}) async {
    if (!forceRefresh && _isDataFresh('recommendDaily')) return;
    _beginLoading();
    _error = null;
    try {
      final result = await _apiClient.getRecommendDaily();
      if (result != null) {
        _recommendSongs = result;
        _dataTimestamps['recommendDaily'] = DateTime.now();
      } else {
        _error = '获取每日推荐失败';
      }
    } catch (e) {
      _error = e.toString();
    }
    _endLoading();
  }

  Future<void> getSongUrl(String hash, {String quality = '128'}) async {
    _beginLoading();
    _error = null;
    try {
      final result = await _apiClient.getSongUrl(hash, quality: quality);
      if (result != null) {
        _songUrl = result;
      } else {
        _error = '获取播放链接失败';
      }
    } catch (e) {
      _error = e.toString();
    }
    _endLoading();
  }

  Future<void> getLyric(
    String hash, {
    String? songName,
    String fmt = 'lrc',
  }) async {
    // 本地歌曲 hash 为空时，用 songName 作为追踪键，避免多首本地歌曲
    // 共享空 hash 导致竞态检查失效（旧请求覆盖新请求结果）
    final trackKey = hash.isEmpty ? 'local_${songName ?? ''}' : hash;

    // 边听边存：检查歌词本地缓存
    final cacheEnabled = await SettingsRepository().getStreamCacheEnabled();
    if (cacheEnabled) {
      await StreamCacheManager.instance.ensureInitialized();
      final cachedLyric = await StreamCacheManager.instance.getCachedLyric(
        hash,
      );
      if (cachedLyric != null) {
        // 缓存命中，直接返回
        _lyric = cachedLyric;
        _lyricSongId = trackKey; // 更新歌词歌曲 ID（用于竞态控制）
        _error = null;
        notifyListeners();
        return;
      }
    }

    _beginLoading();
    _error = null;
    // 先清空旧歌词，避免切换歌曲时残留上首歌的歌词
    _lyric = null;
    _lyricSongId = trackKey;
    notifyListeners();
    try {
      // Task 15：默认 fmt='lrc' 时，API 客户端会并发发起 LRC + KRC 两个请求，
      // 返回的 KugouLyric 同时携带 decodedContent（LRC 明文）与
      // decodedKrcContent（KRC 明文）。任一请求失败不影响另一个。
      // 这里只调用一次，结果统一存入 _lyric，由 [krcLyric] / [lrcLyric]
      // getter 暴露，调用方通过 KugouLyric.displayKrcLyric / displayLrcLyric
      // 显式分别取两种文本。
      final result = await _apiClient.getLyric(
        hash,
        songName: songName,
        fmt: fmt,
      );
      if (_lyricSongId != trackKey) {
        // 期间切换了歌曲，丢弃旧结果
        return;
      }
      if (result != null) {
        _lyric = result;
        // 边听边存：异步缓存歌词（fire-and-forget，不阻塞歌词显示）
        if (cacheEnabled) {
          StreamCacheManager.instance.cacheLyric(hash, result);
        }
      } else {
        _error = '获取歌词失败';
      }
    } catch (e) {
      if (_lyricSongId == trackKey) {
        _error = e.toString();
      }
    }
    _endLoading();
  }

  Future<void> getPlaylistDetail(String ids) async {
    _beginLoading();
    _error = null;
    try {
      final result = await _apiClient.getPlaylistDetail(ids);
      if (result != null && result.isNotEmpty) {
        _playlistDetail = KugouPlaylist(
          id: result.first.id,
          name: result.first.name,
          coverUrl: result.first.coverUrl,
          songCount: result.first.songCount,
        );
      } else {
        _error = '获取歌单详情失败';
      }
    } catch (e) {
      _error = e.toString();
    }
    _endLoading();
  }

  Future<KugouCommentList?> getComments(
    String hash, {
    String? albumAudioId,
    int page = 1,
  }) async {
    _error = null;
    try {
      final result = await _apiClient.getComments(
        hash,
        albumAudioId: albumAudioId,
        page: page,
      );
      if (result != null) {
        _comments = result;
      } else if (page == 1) {
        _error = '获取评论失败';
      }
      return result;
    } catch (e) {
      _error = e.toString();
      return null;
    }
  }

  Future<KugouCommentList?> getPlaylistComments(
    String specialId, {
    int page = 1,
  }) async {
    _error = null;
    try {
      return await _apiClient.getPlaylistComments(specialId, page: page);
    } catch (e) {
      _error = e.toString();
      return null;
    }
  }

  Future<KugouCommentList?> getAlbumComments(
    String albumId, {
    int page = 1,
  }) async {
    _error = null;
    try {
      return await _apiClient.getAlbumComments(albumId, page: page);
    } catch (e) {
      _error = e.toString();
      return null;
    }
  }

  Future<void> getSongDetail(String hash) async {
    _beginLoading();
    _error = null;
    try {
      await _apiClient.getSongDetail(hash);
    } catch (e) {
      _error = e.toString();
    }
    _endLoading();
  }

  Future<void> getArtistDetail(String artistId) async {
    _beginLoading();
    _error = null;
    try {
      final result = await _apiClient.getArtistDetail(artistId);
      if (result != null) {
        _artistDetail = result;
      } else {
        _error = '获取歌手详情失败';
      }
    } catch (e) {
      _error = e.toString();
    }
    _endLoading();
  }

  Future<void> getAlbumDetail(String albumId) async {
    _beginLoading();
    _error = null;
    try {
      final result = await _apiClient.getAlbumDetail(albumId);
      if (result != null) {
        _albumDetail = result;
      } else {
        _error = '获取专辑详情失败';
      }
    } catch (e) {
      _error = e.toString();
    }
    _endLoading();
  }

  Future<void> getSearchSuggest(String keywords) async {
    try {
      final result = await _apiClient.getSearchSuggest(keywords);
      if (result != null) {
        _searchSuggest = result;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> getPlaylistSongs(String globalCollectionId) async {
    _beginLoading();
    _error = null;
    try {
      final result = await _apiClient.getPlaylistSongs(globalCollectionId);
      if (result != null) {
        _playlistSongs = result;
      } else {
        _error = '获取歌单歌曲失败';
      }
    } catch (e) {
      _error = e.toString();
    }
    _endLoading();
  }

  Future<void> getPersonalFm({
    String? mode,
    int? songPoolId,
    String? hash,
    String? songId,
    String? action,
    bool forceRefresh = false,
  }) async {
    final isInteractive = mode != null || action != null || hash != null;
    if (!isInteractive && !forceRefresh && _isDataFresh('personalFm')) return;
    _beginLoading();
    _error = null;
    try {
      final result = await _apiClient.getPersonalFm(
        mode: mode,
        songPoolId: songPoolId,
        hash: hash,
        songId: songId,
        action: action,
      );
      if (result != null) {
        _personalFmSongs = result;
        // 补全 albumName：红心 radio 接口不返回 album_name，但返回了 album_id，
        // 用 album_id 调 getAlbumDetail 批量补全
        await _fillPersonalFmAlbumNames();
        if (!isInteractive) {
          _dataTimestamps['personalFm'] = DateTime.now();
        }
      } else {
        _error = '获取猜你喜欢失败';
      }
    } catch (e) {
      _error = e.toString();
    }
    _endLoading();
  }

  /// 补全 PersonalFm 歌曲缺失的 albumName。
  /// 红心 radio 接口只返回 album_id 不返回 album_name，
  /// 需要用 album_id 调 getAlbumDetail 获取专辑名后回填。
  Future<void> _fillPersonalFmAlbumNames() async {
    // 收集需要补全的去重 albumId（albumName 为空 且 albumId 非空）
    final albumIdsToFetch = <String>{};
    for (final song in _personalFmSongs) {
      if (song.albumName == null &&
          song.albumId != null &&
          song.albumId!.isNotEmpty) {
        albumIdsToFetch.add(song.albumId!);
      }
    }
    if (albumIdsToFetch.isEmpty) return;

    // 并发获取专辑信息（限制并发数避免请求过多）
    final albumNameCache = <String, String>{};
    final futures = albumIdsToFetch.map((albumId) async {
      try {
        final detail = await _apiClient.getAlbumDetail(albumId);
        if (detail != null && detail.name.isNotEmpty) {
          albumNameCache[albumId] = detail.name;
        }
      } catch (_) {
        // 获取失败不影响其他歌曲
      }
    });
    await Future.wait(futures);

    if (albumNameCache.isEmpty) return;

    // 回填 albumName
    _personalFmSongs = _personalFmSongs.map((song) {
      if (song.albumName == null &&
          song.albumId != null &&
          albumNameCache.containsKey(song.albumId)) {
        return song.copyWith(albumName: albumNameCache[song.albumId]);
      }
      return song;
    }).toList();
  }

  void moveToFirst(KugouSongDetail song) {
    final index = _personalFmSongs.indexWhere((s) => s.hash == song.hash);
    if (index > 0) {
      final found = _personalFmSongs.removeAt(index);
      _personalFmSongs.insert(0, found);
      notifyListeners();
    }
  }

  void appendFmSongs(List<KugouSongDetail> songs) {
    for (final song in songs) {
      if (!_personalFmSongs.any((s) => s.hash == song.hash)) {
        _personalFmSongs.add(song);
      }
    }
    notifyListeners();
  }

  Future<void> getPlaylist({
    String? categoryId,
    int page = 1,
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _isDataFresh('playlist')) return;
    try {
      final result = await _apiClient.getPlaylist(
        categoryId: categoryId,
        page: page,
      );
      if (result != null) {
        _playlistCategory = result;
        _playlistList = result.playlistList;
        _dataTimestamps['playlist'] = DateTime.now();
        notifyListeners();
      }
    } catch (_) {}
  }

  void setBaseUrl(String url) {
    _apiClient.setBaseUrl(url);
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  void clearSearchResults() {
    _searchResults = null;
    _searchSuggest = [];
    notifyListeners();
  }

  Future<void> generateQrCode() async {
    try {
      final qrKey = await _apiClient.getLoginQrKey();
      if (qrKey == null || qrKey.qrcode == null) {
        print('[LOGIN] getLoginQrKey returned null');
        return;
      }
      _qrKey = qrKey;
      notifyListeners();
      final qrData = await _apiClient.createLoginQr(qrKey.qrcode!);
      if (qrData != null) {
        _qrData = qrData;
        notifyListeners();
      } else {
        print('[LOGIN] createLoginQr returned null');
      }
    } catch (e) {
      print('[LOGIN] generateQrCode error: $e');
    }
  }

  Future<int?> checkQrCode() async {
    if (_qrKey == null || _qrKey?.qrcode == null) return null;
    try {
      final result = await _apiClient.checkLoginQr(_qrKey!.qrcode!);
      if (result == null) return null;
      if (result.status == 4 && result.token != null && result.userid != null) {
        // 登录新用户前，清除旧用户的头像缓存
        await _clearAvatarCacheIfUserChanged(result.userid!);
        _isLoggedIn = true;
        await _apiClient.setLoginCookies(
          result.token!,
          result.userid!,
          vipToken: result.vipToken,
        );
        await _fetchUserInfo();
        notifyListeners();
      }
      return result.status;
    } catch (_) {
      return null;
    }
  }

  // 发送手机验证码
  Future<bool> sendLoginCaptcha(String mobile) async {
    if (mobile.length != 11) {
      _error = '请输入11位手机号';
      notifyListeners();
      return false;
    }
    try {
      final res = await _apiClient.sendLoginCaptcha(mobile);
      // 成功: status=1
      if (res?['status'] == 1) return true;
      _error = res?['error_msg']?.toString() ?? '发送验证码失败';
      notifyListeners();
      return false;
    } catch (e) {
      _error = '发送失败: ${e.toString()}';
      notifyListeners();
      return false;
    }
  }

  // 手机号+验证码登录
  Future<bool> loginByPhone(String mobile, String code) async {
    try {
      final res = await _apiClient.loginByCellphone(mobile, code);
      if (res?['status'] == 1) {
        final data = res?['data'] as Map?;
        final token = data?['token']?.toString();
        final userid = data?['userid']?.toString();
        final vipToken = data?['vip_token']?.toString();
        if (token != null && userid != null) {
          // 登录新用户前，清除旧用户的头像缓存
          await _clearAvatarCacheIfUserChanged(userid);
          await _apiClient.setLoginCookies(token, userid, vipToken: vipToken);
          _isLoggedIn = true;
          await _fetchUserInfo();
          notifyListeners();
          return true;
        }
      }
      _error = res?['error_msg']?.toString() ?? '登录失败';
      notifyListeners();
      return false;
    } catch (e) {
      _error = '登录失败: ${e.toString()}';
      notifyListeners();
      return false;
    }
  }

  Future<void> refreshUserInfo() async {
    try {
      final userInfo = await _apiClient.getUserDetail();
      if (userInfo != null) {
        _userInfo = userInfo;
        notifyListeners();
      }
    } catch (_) {}
  }

  // 内部调用, 保留为下划线形式仅在类内使用
  Future<void> _fetchUserInfo() => refreshUserInfo();

  void logout() {
    _isLoggedIn = false;
    _userInfo = null;
    _qrKey = null;
    _qrData = null;
    _vipInfo = null;
    _vipMonthRecord = null;
    _userHistoryData = null;
    _everydayHistory = null;

    // 清除所有用户相关的内存缓存
    clearMemoryCache();

    // 清除API客户端的认证信息
    _apiClient.clearCookies();

    // 清除头像缓存
    _clearAvatarCache();

    print('✅ [Logout] 用户已退出登录，所有用户数据已清除');
    notifyListeners();
  }

  void _clearAvatarCache() {
    try {
      DefaultCacheManager().emptyCache();
    } catch (_) {}
  }

  Future<void> _clearAvatarCacheIfUserChanged(String newUserId) async {
    final currentUserId = _userInfo?.userid;
    if (currentUserId != null && currentUserId != newUserId) {
      _clearAvatarCache();
    }
  }

  /// 识别后端 "已升级 / 已领取概念版" 类提示，避免误报为失败
  bool _containsUpgradeDoneHint(String msg) {
    return msg.contains('已升级') ||
        msg.contains('已领取') ||
        msg.contains('已签到') ||
        msg.contains('升级过') ||
        msg.contains('已领取过') ||
        msg.contains('已是') ||
        msg.toLowerCase().contains('already');
  }

  /// 自动签到（含概念版双签到）。
  /// 登录后自动调用，若今天已签到则跳过。
  Future<void> autoReceiveVipIfNeeded() async {
    if (!_isLoggedIn) return;

    final settingsRepo = SettingsRepository();
    final autoReceive = await settingsRepo.getAutoReceiveVip();
    if (!autoReceive) {
      return;
    }

    try {
      int timestamp;
      try {
        final serverNow = await _apiClient.getServerNow();
        final ts =
            (serverNow?['data'] as Map?)?['timestamp'] as int? ??
            serverNow?['timestamp'] as int?;
        if (ts != null && ts > 0) {
          timestamp = ts;
        } else {
          timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        }
      } catch (_) {
        timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      }

      final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
      final receiveDay =
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

      // 1. 领取畅听VIP
      try {
        final autoClaim = await _apiClient.claimDayVip(receiveDay);
        final claimOk =
            autoClaim != null &&
            (autoClaim['status'] == 1 || autoClaim['error_code'] == 0);
        // 131001 = 今日已领取，也视为成功
        final alreadyClaimed = autoClaim?['error_code'] == 131001;
        if (!claimOk && !alreadyClaimed) return;
      } catch (_) {
        return;
      }

      // 2. 升级概念版VIP
      try {
        final upgrade = await _apiClient.upgradeDayVip();
        if (upgrade != null &&
            (upgrade['status'] == 1 ||
                upgrade['error_code'] == 0 ||
                upgrade['error_code'] == 20030 ||
                upgrade['error_code'] == 131001)) {
          _todayUpgradedToConcept = true;
        }
      } catch (_) {}

      await _markSignedToday();

      try {
        await _fetchUserInfo();
      } catch (_) {}

      try {
        await getVipMonthRecord();
      } catch (_) {}
    } catch (_) {}
  }

  bool _manualSignInRunning = false;
  bool get manualSignInRunning => _manualSignInRunning;

  /// 今天是否已成功签到并升级概念版（用于 UI 显示"概念版会员"徽章）。
  /// 概念版双签到第二步（upgradeDayVip）成功后置 true，
  /// 跨天/重启后由 `_localSignedDays` 重新判定（见 `isTodayYouthVip`）。
  bool _todayUpgradedToConcept = false;
  bool get isTodayYouthVip {
    if (_todayUpgradedToConcept) return true;
    // 跨重启兜底：只要今天在本地已签列表里，就认为概念版已激活
    final now = DateTime.now();
    final key =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    return _localSignedDays.contains(key);
  }

  /// 手动签到/领取: 不依赖 autoReceive 开关，强制调 claim + upgrade
  /// 返回 (success, message)
  ///
  /// 全面对齐 EchoMusic (hoowhoami/EchoMusic) 的双签到实现：
  ///   1. claimDayVip(day)   → POST /youth/day/vip          (领取畅听VIP)
  ///   2. upgradeDayVip()    → POST /youth/day/vip/upgrade  (升级为概念版SVIP)
  ///
  /// 重要：只有当两次 API 都明确返回成功（status=1 或 error_code=0）时，
  /// 才认为真正签到成功并返回 "概念版会员"；否则如实报错给用户。
  /// 之前的实现把 upgrade 失败静默吞掉，导致软件显示 "签到成功（概念版会员）"
  /// 但官方仍只显示 "畅听VIP+1天"。
  Future<(bool, String)> manualSignIn() async {
    if (_manualSignInRunning) return (false, '请求进行中');
    if (!_isLoggedIn) return (false, '请先登录');
    _manualSignInRunning = true;
    notifyListeners();
    try {
      // 获取服务器时间，失败则降级用本地时间
      int ts;
      try {
        final serverNow = await _apiClient.getServerNow();
        final serverTs =
            (serverNow?['data'] as Map?)?['timestamp'] as int? ??
            serverNow?['timestamp'] as int?;
        if (serverTs != null && serverTs > 0) {
          ts = serverTs;
        } else {
          ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          print('[SIGN_IN] getServerNow 返回无效，降级使用本地时间');
        }
      } catch (e) {
        ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        print('[SIGN_IN] getServerNow 异常，降级使用本地时间: $e');
      }

      final date = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
      final receiveDay =
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      print('[SIGN_IN] receiveDay: $receiveDay');

      // 手动签到：始终发送请求，不做本地已签拦截
      // （服务端会正确返回"今日已领取"，由前端统一提示）
      //
      // 20028（需二次安全验证）处理：响应携带 ssaCode 时，先弹验证码，
      // 验证通过后重试一次签到（claim 可能已成功，重试会命中 131001 已领取，不阻断）。
      var verifyAttempted = false;
      while (true) {
        final (ok, msg, ssaCode) = await _signInOnce(receiveDay);
        if (ok) return (true, msg);
        if (ssaCode != null && !verifyAttempted) {
          verifyAttempted = true;
          final verified = await _handleVerifyCaptcha(ssaCode);
          if (!verified) return (false, '签到需要安全验证，验证未完成');
          continue; // 验证通过，重试签到
        }
        return (false, msg);
      }
    } catch (e) {
      print('[SIGN_IN] 异常: $e');
      return (false, _friendlyNetworkError(e));
    } finally {
      _manualSignInRunning = false;
      notifyListeners();
    }
  }

  /// 单次签到流程：领取畅听VIP（claim）→ 升级概念版（upgrade）。
  /// 返回 (success, message, ssaCode)；遇 20028 且响应带 ssaCode 时，
  /// message 为空、由外层走验证码后重试。
  Future<(bool, String, String?)> _signInOnce(String receiveDay) async {
    // 1. 领取畅听VIP（基础签到）
    //    与 EchoMusic 一致：必传 receive_day，否则后端可能判定为无效签到。
    final claim = await _apiClient.claimDayVip(receiveDay);
    print('[SIGN_IN] claim 完整响应: $claim');

    if (claim == null) {
      return (false, '签到请求无响应，请稍后重试', null);
    }

    final claimStatus = claim['status'];
    final claimErrorCode = claim['error_code'];
    final claimErrorMsg =
        claim['error_msg']?.toString() ?? claim['msg']?.toString() ?? '';
    final claimSsaCode = claim['ssaCode']?.toString() ?? '';

    // status=1 成功，或 error_code=0 也视为成功
    final claimOk = (claimStatus == 1 || claimErrorCode == 0);
    // 131001 = 今日已领取畅听VIP（之前已签过），不阻断 upgrade
    final claimAlreadyDone = (claimErrorCode == 131001);
    if (!claimOk && !claimAlreadyDone) {
      // 第一步领取就失败（非"已领取"），直接返回，不继续 upgrade
      if (claimErrorCode == 20028 && claimSsaCode.isNotEmpty) {
        return (false, '', claimSsaCode);
      }
      if (claimErrorMsg.isNotEmpty) {
        return (false, _ensureChineseOrFallback(claimErrorMsg), null);
      }
      return (false, _mapYouthVipError(claimErrorCode, claimStatus), null);
    }

    // 2. 升级为概念版（完整）会员 —— 概念版双签到第二步
    //    关键：必须严格判断 upgrade 响应，**不能**静默吞失败。
    //    之前静默吞掉导致软件显示 "概念版会员" 但官方仍只显示 "畅听VIP+1天"。
    Map<String, dynamic>? upgrade;
    try {
      upgrade = await _apiClient.upgradeDayVip();
      print('[SIGN_IN] upgrade 响应: $upgrade');
    } catch (e) {
      print('[SIGN_IN] upgrade 异常: $e');
      // 网络层异常：不标记成功，等下统一走升级失败分支
    }

    // 解析 upgrade 结果
    int? upgradeStatus;
    int? upgradeErrorCode;
    String? upgradeMsg;
    String upgradeSsaCode = '';
    if (upgrade != null) {
      upgradeStatus = upgrade['status'] as int?;
      upgradeErrorCode = upgrade['error_code'] as int?;
      upgradeMsg =
          upgrade['error_msg']?.toString() ??
          upgrade['msg']?.toString() ??
          '';
      upgradeSsaCode = upgrade['ssaCode']?.toString() ?? '';
    }

    // 某些后端实现：upgrade 接口会返回 "已升级过" / "今日已升级" 等，
    // 这种属于正常状态（之前已经成功升级），应视为本次签到仍成功。
    // 这里通过 error_code 文案识别（20030 = 已升级过概念版）。
    final upgradeAlreadyDone =
        upgradeErrorCode == 20030 ||
        upgradeErrorCode == 131001 ||
        (upgradeMsg != null && _containsUpgradeDoneHint(upgradeMsg));
    final upgradeOk =
        upgrade != null &&
        (upgradeStatus == 1 || upgradeErrorCode == 0 || upgradeAlreadyDone);

    if (!upgradeOk) {
      // 升级失败：给用户如实提示，**不要**标记成功
      // 注意此时第一步已成功（用户已领到畅听VIP），文案要明确说明：
      // "已领取畅听VIP，但升级概念版失败：xxxx"
      if (upgradeErrorCode == 20028 && upgradeSsaCode.isNotEmpty) {
        return (false, '', upgradeSsaCode);
      }
      final tail = upgradeMsg != null && upgradeMsg.isNotEmpty
          ? _ensureChineseOrFallback(upgradeMsg)
          : _mapYouthVipError(upgradeErrorCode, upgradeStatus);
      return (false, '畅听VIP已领取，但升级概念版失败：$tail', null);
    }

    // 两步都成功 —— 标记今天已签并刷新信息
    try {
      await _fetchUserInfo();
    } catch (e) {
      print('[SIGN_IN] 刷新用户信息异常: $e');
    }
    try {
      await getVipMonthRecord();
    } catch (e) {
      print('[SIGN_IN] 刷新打卡记录异常: $e');
    }

    await _markSignedToday();
    _todayUpgradedToConcept = true;
    return (true, '签到成功（概念版会员）', null);
  }

  // ── 20028 二次安全验证 ──────────────────────────────────────────
  VerifyCaptchaRequest? _pendingVerifyCaptcha;

  /// UI 层监听的待处理验证码请求；非 null 时应弹出验证码弹窗。
  VerifyCaptchaRequest? get pendingVerifyCaptcha => _pendingVerifyCaptcha;

  /// 20028 处理：获取验证码格式 → 交由 UI 弹腾讯滑块验证码 → 提交验证。
  /// 返回 true 表示验证通过（可重试原请求）；false 表示取消/失败/类型不支持。
  Future<bool> _handleVerifyCaptcha(String eventid) async {
    // 1. 获取验证码格式（v_type / txappid）
    final info = await _apiClient.getVerifyInfo(eventid);
    if (info == null) return false;
    final data = info['data'];
    if (data is! Map) return false;
    final vType = (data['v_type'] is num) ? (data['v_type'] as num).toInt() : 23;
    final txappid = data['txappid']?.toString() ?? '';
    if (txappid.isEmpty) return false;

    // 目前仅实现腾讯滑块验证码（v_type=23），其他类型暂不支持
    if (vType != 23) return false;

    // 2. 挂起请求，等待 UI 弹窗完成滑块验证
    final completer = Completer<String?>();
    _pendingVerifyCaptcha = VerifyCaptchaRequest(
      eventid: eventid,
      vType: vType,
      txappid: txappid,
      completer: completer,
    );
    notifyListeners();

    final verifycode = await completer.future.timeout(
      const Duration(minutes: 3),
      onTimeout: () {
        _pendingVerifyCaptcha = null;
        notifyListeners();
        return null;
      },
    );

    _pendingVerifyCaptcha = null;
    notifyListeners();

    if (verifycode == null) return false;

    // 3. 提交验证码完成二次验证
    final result = await _apiClient.verifyUserInfo(
      eventid: eventid,
      vType: vType,
      verifycode: verifycode,
    );
    final ok = result != null &&
        (result['status'] == 1 || result['error_code'] == 0);
    return ok;
  }

  /// UI 回调：滑块验证通过，回填 verifycode。
  void completeVerifyCaptcha(String verifycode) {
    final c = _pendingVerifyCaptcha?.completer;
    if (c != null && !c.isCompleted) c.complete(verifycode);
  }

  /// UI 回调：用户取消 / 组件加载失败。
  void cancelVerifyCaptcha() {
    final c = _pendingVerifyCaptcha?.completer;
    if (c != null && !c.isCompleted) c.complete(null);
  }

  /// 优先返回中文 errorMsg；如果不含中文则用错误码映射兜底
  String _ensureChineseOrFallback(String errorMsg) {
    if (_containsChinese(errorMsg)) {
      // 服务端中文提示，原样返回
      return errorMsg;
    }
    // 英文消息视为不可友好展示，统一用通用兜底
    return '签到失败，请稍后重试';
  }

  /// 将网络层 / 系统异常翻译为友好中文提示
  String _friendlyNetworkError(Object e) {
    final raw = e.toString();
    // 常见网络异常关键字识别
    if (raw.contains('SocketException') ||
        raw.contains('Connection refused') ||
        raw.contains('Failed host lookup') ||
        raw.contains('Network is unreachable') ||
        raw.contains('No address associated with hostname')) {
      return '网络连接失败，请检查网络后重试';
    }
    if (raw.contains('TimeoutException') || raw.contains('timeout')) {
      return '网络请求超时，请稍后重试';
    }
    if (raw.contains('HandshakeException') ||
        raw.contains('CertificateException') ||
        raw.contains('CERTIFICATE')) {
      return '安全证书校验失败，请检查网络环境';
    }
    if (raw.contains('FormatException')) {
      return '服务器返回数据格式异常，请稍后重试';
    }
    if (raw.contains('HttpException') || raw.contains('status code')) {
      return '服务器异常，请稍后重试';
    }
    // 兜底：保持中文，避免用户看到英文
    return '签到失败，请稍后重试';
  }

  /// 判断字符串是否包含中文字符；用于过滤 API 返回的英文错误
  bool _containsChinese(String s) {
    return RegExp(r'[\u4e00-\u9fa5]').hasMatch(s);
  }

  /// 将酷狗 youth vip 相关错误码映射成可读中文提示
  String _mapYouthVipError(int? errorCode, dynamic status) {
    const map = <int, String>{
      20006: '签名错误，请重新登录后重试',
      20010: '参数错误（领取日期格式有误）',
      20018: '登录已过期，请重新登录',
      20028: '酷狗拒绝领取：账号可能不符合资格，或该功能已停用',
      20030: '已升级过概念版，无需重复领取',
      20033: '今日已签到，无需重复领取',
      20034: '领取失败：领取次数已达上限',
      // 131001 系列多为账号风控/黑号限制（用户反馈），给一条明确的中文提示
      131001: '今日已签到，无需重复领取',
    };
    if (errorCode != null && map.containsKey(errorCode)) {
      return map[errorCode]!;
    }
    // 兜底：纯中文 + 服务端原始码（方便排查但用户友好）
    return '签到失败，请稍后重试（错误码：${errorCode ?? '未知'}）';
  }

  // ── 听歌领取 / 广告领取（独立按钮触发，不影响自动签到） ──────────

  bool _listenClaimRunning = false;
  bool get listenClaimRunning => _listenClaimRunning;

  bool _adClaimRunning = false;
  bool get adClaimRunning => _adClaimRunning;

  /// 听歌上报领取 VIP。error_code 130012（今日已领取）视为成功。
  Future<(bool, String)> listenSongClaim() async {
    if (_listenClaimRunning) return (false, '请求进行中');
    if (!_isLoggedIn) return (false, '请先登录');
    _listenClaimRunning = true;
    notifyListeners();
    try {
      final resp = await _apiClient.listenSong();
      if (resp == null) return (false, '请求无响应，请稍后重试');
      if (resp['status'] == 1) return (true, '听歌领取成功');
      final code = resp['error_code'] as int?;
      if (code == 130012) return (true, '今日已领取');
      return (false, _mapListenAdError(code));
    } catch (e) {
      return (false, _friendlyNetworkError(e));
    } finally {
      _listenClaimRunning = false;
      notifyListeners();
    }
  }

  /// 广告播放上报领取 VIP：最多 8 次，成功且非最后一次间隔 30s，
  /// error_code 30002（次数已用光）提前正常停止（对齐 kgcheckin main.js）。
  Future<(bool, String)> claimAdVip() async {
    if (_adClaimRunning) return (false, '请求进行中');
    if (!_isLoggedIn) return (false, '请先登录');
    _adClaimRunning = true;
    notifyListeners();
    var success = 0;
    try {
      for (var i = 1; i <= 8; i++) {
        final resp = await _apiClient.claimAdVip();
        switch (KugouApiClient.parseAdClaimOutcome(resp)) {
          case AdClaimOutcome.success:
            success++;
            if (i != 8) {
              await Future<void>.delayed(const Duration(seconds: 30));
            }
          case AdClaimOutcome.quotaDone:
            return (
              true,
              success > 0
                  ? '广告领取 $success/8 次，今日次数已用光'
                  : '今日广告次数已用光',
            );
          case AdClaimOutcome.failure:
            final code = resp?['error_code'] as int?;
            return (
              false,
              success > 0
                  ? '领取 $success/8 次后失败：${_mapListenAdError(code)}'
                  : '领取失败：${_mapListenAdError(code)}',
            );
        }
      }
      return (true, '广告领取 $success/8 次');
    } catch (e) {
      return (
        false,
        success > 0
            ? '领取 $success/8 次后中断：${_friendlyNetworkError(e)}'
            : _friendlyNetworkError(e),
      );
    } finally {
      _adClaimRunning = false;
      notifyListeners();
    }
  }

  /// 听歌/广告领取相关错误码 → 可读中文提示
  String _mapListenAdError(int? errorCode) {
    const map = <int, String>{
      130012: '今日已领取',
      30002: '今日广告次数已用光',
      20006: '签名错误，请重新登录后重试',
      20010: '参数错误',
      20018: '登录已过期，请重新登录',
      20028: '酷狗拒绝领取：账号可能不符合资格，或该功能已停用',
    };
    if (errorCode != null && map.containsKey(errorCode)) {
      return map[errorCode]!;
    }
    return '领取失败，请稍后重试（错误码：${errorCode ?? '未知'}）';
  }

  Future<void> getRankSongs({
    required String rankId,
    int rankCid = 0,
    int page = 1,
    int pagesize = 30,
    bool forceRefresh = false,
  }) async {
    final freshnessKey = 'rankSongs_$rankId';
    if (!forceRefresh && page == 1 && _isDataFresh(freshnessKey)) return;
    _beginLoading();
    _error = null;
    try {
      if (page == 1) {
        // 自动拉全部：分页循环
        const batchSize = 30;
        const maxPages = 100;
        final all = <KugouSongDetail>[];
        for (int p = 1; p <= maxPages; p++) {
          final songs = await _apiClient.getRankAudio(
            rankId: rankId,
            rankCid: rankCid,
            page: p,
            pagesize: batchSize,
          );
          if (songs == null) {
            if (all.isEmpty) _error = '获取排行榜歌曲失败';
            break;
          }
          all.addAll(songs);
          if (songs.length < batchSize) break;
        }
        _rankSongs = all;
        _dataTimestamps[freshnessKey] = DateTime.now();
      } else {
        final songs = await _apiClient.getRankAudio(
          rankId: rankId,
          rankCid: rankCid,
          page: page,
          pagesize: pagesize,
        );
        if (songs != null) {
          _rankSongs = songs;
        } else {
          _error = '获取排行榜歌曲失败';
        }
      }
    } catch (e) {
      _error = e.toString();
    }
    _endLoading();
  }

  Future<void> getPlaylistTrackAll({
    required String id,
    int page = 1,
    int pagesize = 30,
    bool forceRefresh = false,
  }) async {
    final freshnessKey = 'playlistTrackAll_$id';
    if (!forceRefresh && page == 1 && _isDataFresh(freshnessKey)) return;
    _beginLoading();
    _error = null;
    try {
      if (page == 1) {
        // 自动拉全部：分页循环
        const batchSize = 30;
        const maxPages = 100;
        final all = <KugouSongDetail>[];
        for (int p = 1; p <= maxPages; p++) {
          final songs = await _apiClient.getPlaylistTrackAll(
            id: id,
            page: p,
            pagesize: batchSize,
          );
          if (songs == null) {
            if (all.isEmpty) _error = '获取歌单歌曲失败';
            break;
          }
          all.addAll(songs);
          if (songs.length < batchSize) break;
        }
        _currentPlaylistSongs = all;
        _dataTimestamps[freshnessKey] = DateTime.now();
      } else {
        final songs = await _apiClient.getPlaylistTrackAll(
          id: id,
          page: page,
          pagesize: pagesize,
        );
        if (songs != null) {
          _currentPlaylistSongs = songs;
        } else {
          _error = '获取歌单歌曲失败';
        }
      }
    } catch (e) {
      _error = e.toString();
    }
    _endLoading();
  }

  // ==================== Yueku (乐库) ====================

  Future<void> getYueku() async {
    _setLoading(true);
    try {
      final r = await _apiClient.getYueku();
      if (r != null) {
        _yuekuData = r;
      }
    } catch (_) {}
    _setLoading(false);
  }

  Future<void> getYuekuBanner({bool forceRefresh = false}) async {
    if (!forceRefresh && _isDataFresh('yuekuBanner')) return;
    try {
      final r = await _apiClient.getYuekuBanner();
      if (r != null) {
        _yuekuBanner = r;
        _dataTimestamps['yuekuBanner'] = DateTime.now();
        notifyListeners();
      }
    } catch (_) {}
  }

  // ==================== Scene (场景) ====================

  Future<void> getSceneMusic({bool forceRefresh = false}) async {
    if (!forceRefresh && _isDataFresh('sceneMusic')) return;
    _setLoading(true);
    try {
      final r = await _apiClient.getSceneMusic();
      if (r != null) {
        _sceneData = r;
        _dataTimestamps['sceneMusic'] = DateTime.now();
      }
    } catch (_) {}
    _setLoading(false);
  }

  // ==================== Theme (主题) ====================

  Future<void> getThemeMusic({bool forceRefresh = false}) async {
    if (!forceRefresh && _isDataFresh('themeMusic')) return;
    try {
      final r = await _apiClient.getThemeMusic();
      if (r != null) {
        _themeMusicData = r;
        _dataTimestamps['themeMusic'] = DateTime.now();
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> getThemePlaylist({bool forceRefresh = false}) async {
    if (!forceRefresh && _isDataFresh('themePlaylist')) return;
    try {
      final r = await _apiClient.getThemePlaylist();
      if (r != null) {
        final data = r['data'] as Map<String, dynamic>? ?? r;
        final list = data['list'] ?? data['info'] ?? [];
        _themePlaylistData = (list as List)
            .map((e) => KugouThemeInfo.fromJson(e as Map<String, dynamic>))
            .toList();
        _dataTimestamps['themePlaylist'] = DateTime.now();
        notifyListeners();
      }
    } catch (_) {}
  }

  // ==================== IP (编辑精选) ====================

  Future<void> getIpHome({bool forceRefresh = false}) async {
    if (!forceRefresh && _isDataFresh('ipHome')) return;
    try {
      final r = await _apiClient.getIpHome();
      if (r != null) {
        _ipHomeData = r;
        _dataTimestamps['ipHome'] = DateTime.now();
        notifyListeners();
      }
    } catch (_) {}
  }

  /// 编辑精选专区（/ip/zone）。
  Future<void> getIpZone({bool forceRefresh = false}) async {
    if (!forceRefresh && _isDataFresh('ipZone')) return;
    try {
      final r = await _apiClient.getIpZone();
      if (r != null) {
        _ipZoneData = r;
        _dataTimestamps['ipZone'] = DateTime.now();
        notifyListeners();
      }
    } catch (_) {}
  }

  // ==================== FM (电台) ====================

  Future<void> getFmRecommend() async {
    try {
      final r = await _apiClient.getFmRecommend();
      if (r != null) {
        _fmRecommendData = r;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> getFmClass() async {
    try {
      final r = await _apiClient.getFmClass();
      if (r != null) {
        final data = r['data'] as Map<String, dynamic>? ?? r;
        final list = data['list'] ?? data['info'] ?? [];
        _fmClassList = (list as List)
            .map((e) => KugouFmInfo.fromJson(e as Map<String, dynamic>))
            .toList();
        notifyListeners();
      }
    } catch (_) {}
  }

  // ==================== Sheet (曲谱) ====================

  Future<void> getSheetExplore({int page = 1}) async {
    try {
      final r = await _apiClient.getSheetExplore(page: page);
      if (r != null) {
        final data = r['data'] as Map<String, dynamic>? ?? r;
        final list = data['list'] ?? data['info'] ?? [];
        _sheetExploreList = (list as List)
            .map((e) => KugouSheetInfo.fromJson(e as Map<String, dynamic>))
            .toList();
        notifyListeners();
      }
    } catch (_) {}
  }

  // ==================== Everyday (每日) ====================

  Future<void> getEverydayHistory() async {
    try {
      final r = await _apiClient.getEverydayHistory();
      if (r != null) {
        _everydayHistory = r;
        notifyListeners();
      }
    } catch (_) {}
  }

  // ==================== Top (排行) ====================

  Future<void> getTopAlbum({int page = 1}) async {
    try {
      final r = await _apiClient.getTopAlbum(page: page);
      if (r != null) {
        _topAlbumData = r;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> getTopSong({int page = 1}) async {
    try {
      final r = await _apiClient.getTopSong(page: page);
      if (r != null) {
        _topSongData = r;
        notifyListeners();
      }
    } catch (_) {}
  }

  // ==================== User (用户) ====================

  Future<void> getVipDetail() async {
    try {
      final r = await _apiClient.getUserVipDetail();
      if (r != null) {
        _vipInfo = r;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> getVipMonthRecord() async {
    try {
      // 传入当前年月，否则接口默认返回最早月份（如 4 月）的记录，导致当月打卡不显示
      final now = DateTime.now();
      final month = '${now.year}-${now.month.toString().padLeft(2, '0')}';
      final r = await _apiClient.getYouthMonthVipRecord(month: month);
      if (r != null) {
        _vipMonthRecord = r;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> getUserHistory() async {
    try {
      final r = await _apiClient.getUserHistory();
      if (r != null) {
        _userHistoryData = r;
        notifyListeners();
      }
    } catch (_) {}
  }

  // ==================== Youth (频道) ====================

  Future<void> getYouthChannels() async {
    try {
      final r = await _apiClient.getYouthChannels();
      if (r != null) {
        final data = r['data'] as Map<String, dynamic>? ?? r;
        final list = data['list'] ?? data['info'] ?? data['channels'] ?? [];
        _youthChannels = (list as List)
            .map((e) => KugouYouthChannel.fromJson(e as Map<String, dynamic>))
            .toList();
        notifyListeners();
      }
    } catch (_) {}
  }

  // ==================== Long Audio (听书) ====================

  Future<void> getLongaudioDaily() async {
    try {
      final r = await _apiClient.getLongaudioDaily();
      if (r != null) {
        _longAudioData = r;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> getLongaudioRank() async {
    try {
      final r = await _apiClient.getLongaudioRank();
      if (r != null) {
        // Rank 响应结构：data 为数组，每项含 albums 子数组
        final data = r['data'];
        final albums = <dynamic>[];
        if (data is List) {
          for (final item in data) {
            if (item is Map<String, dynamic>) {
              final sub = item['albums'];
              if (sub is List) albums.addAll(sub);
            }
          }
        } else if (data is Map<String, dynamic>) {
          final list = data['list'] ?? data['info'] ?? [];
          if (list is List) albums.addAll(list);
        }
        _longAudioAlbums = albums
            .whereType<Map<String, dynamic>>()
            .map(KugouLongAudioAlbum.fromJson)
            .toList();
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> getLongaudioVip() async {
    try {
      final r = await _apiClient.getLongaudioVip();
      if (r != null) {
        final data = r['data'] as Map<String, dynamic>? ?? r;
        final list = data['list'] ?? data['info'] ?? [];
        _longAudioVipAlbums = (list as List)
            .map((e) => KugouLongAudioAlbum.fromJson(e as Map<String, dynamic>))
            .toList();
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> getLongaudioWeek() async {
    try {
      final r = await _apiClient.getLongaudioWeek();
      if (r != null) {
        final data = r['data'] as Map<String, dynamic>? ?? r;
        final list = data['list'] ?? data['info'] ?? [];
        _longAudioWeekAlbums = (list as List)
            .map((e) => KugouLongAudioAlbum.fromJson(e as Map<String, dynamic>))
            .toList();
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> getLongaudioAlbumDetail(String albumId) async {
    try {
      final r = await _apiClient.getLongaudioAlbumDetail(albumId);
      if (r != null) {
        _longAudioAlbumDetail = r;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> getLongaudioAlbumAudios(String albumId) async {
    try {
      final r = await _apiClient.getLongaudioAlbumAudios(albumId);
      if (r != null) {
        // Audios 响应结构：data 为顶层数组
        final data = r['data'];
        final list = <dynamic>[];
        if (data is List) {
          list.addAll(data);
        } else if (data is Map<String, dynamic>) {
          final sub = data['audios'] ?? data['list'] ?? data['audio_list'];
          if (sub is List) list.addAll(sub);
        }
        _longAudioAudios = list
            .whereType<Map<String, dynamic>>()
            .map(KugouLongAudioAudio.fromJson)
            .toList();
        notifyListeners();
      }
    } catch (_) {}
  }

  // ==================== Brush & AI ====================

  Future<void> getBrush() async {
    try {
      final r = await _apiClient.getBrush();
      if (r != null) {
        _brushData = r;
        notifyListeners();
      }
    } catch (_) {}
  }

  /// 根据专辑音乐 id（album_audio_id/MixSongID）拉取 AI 推荐歌曲。
  Future<void> getAiRecommend(String albumAudioId) async {
    try {
      final r = await _apiClient.getAiRecommend(albumAudioId);
      if (r != null) {
        _aiRecommendSongs = r;
        notifyListeners();
      }
    } catch (_) {}
  }

  // ==================== Server ====================

  Future<void> getServerNow() async {
    try {
      final r = await _apiClient.getServerNow();
      if (r != null) {
        _serverNow = r;
        notifyListeners();
      }
    } catch (_) {}
  }

  // ==================== Recommend Songs ====================

  Future<void> getRecommendSongs() async {
    _setLoading(true);
    try {
      final result = await _apiClient.getRecommendSongs();
      if (result != null) {
        _recommendSongs = result;
      }
    } catch (e) {
      _error = e.toString();
    }
    _setLoading(false);
  }
}

/// 搜索结果缓存条目
class _SearchCacheEntry {
  final KugouSearchResult result;
  final DateTime timestamp;

  _SearchCacheEntry({required this.result, required this.timestamp});

  static const Duration ttl = Duration(minutes: 5);

  bool get isExpired => DateTime.now().difference(timestamp) > ttl;
}
