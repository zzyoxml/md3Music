import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../data/models/album.dart';
import '../data/models/artist.dart';
import '../data/models/playlist.dart';
import '../data/models/song.dart';
import '../data/repositories/settings_repository.dart';
import '../services/kugou_api/kugou_api_client.dart';
import '../services/kugou_api/kugou_models.dart';

class KugouProvider extends ChangeNotifier {
  final KugouApiClient _apiClient = KugouApiClient();

  KugouProvider() {
    _autoConnect();
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
  Map<String, dynamic>? _fmData;
  Map<String, dynamic>? _sheetData;
  Map<String, dynamic>? _everydayHistory;
  Map<String, dynamic>? _topAlbumData;
  Map<String, dynamic>? _topSongData;
  KugouUserVipDetail? _vipInfo;
  Map<String, dynamic>? _vipMonthRecord;
  Map<String, dynamic>? _userHistoryData;
  Map<String, dynamic>? _brushData;
  Map<String, dynamic>? _aiRecommendData;
  Map<String, dynamic>? _youthData;
  Map<String, dynamic>? _longAudioData;
  Map<String, dynamic>? _fmRecommendData;
  List<KugouFmInfo> _fmClassList = [];
  List<KugouThemeInfo> _themePlaylistData = [];
  List<KugouSheetInfo> _sheetExploreList = [];
  List<KugouYouthChannel> _youthChannels = [];
  List<KugouLongAudioAlbum> _longAudioAlbums = [];
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
    return _lastSearchKeyword == keyword && _searchResultsByType.containsKey(type);
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
    if (_lastSearchKeyword == keyword && _searchResultsByType.containsKey(type)) {
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
  KugouLyric? get lyric => _lyric;
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
  KugouUserDetail? get userInfo => _userInfo;
  List<KugouSongDetail> get rankSongs => _rankSongs;
  List<KugouSongDetail> get currentPlaylistSongs => _currentPlaylistSongs;
  Map<String, dynamic>? get yuekuData => _yuekuData;
  Map<String, dynamic>? get yuekuBanner => _yuekuBanner;
  Map<String, dynamic>? get sceneData => _sceneData;
  Map<String, dynamic>? get themeMusicData => _themeMusicData;
  Map<String, dynamic>? get ipHomeData => _ipHomeData;
  Map<String, dynamic>? get fmData => _fmData;
  Map<String, dynamic>? get sheetData => _sheetData;
  Map<String, dynamic>? get everydayHistory => _everydayHistory;
  Map<String, dynamic>? get topAlbumData => _topAlbumData;
  Map<String, dynamic>? get topSongData => _topSongData;
  KugouUserVipDetail? get vipInfo => _vipInfo;
  Map<String, dynamic>? get vipMonthRecord => _vipMonthRecord;
  Map<String, dynamic>? get userHistoryData => _userHistoryData;
  Map<String, dynamic>? get brushData => _brushData;
  Map<String, dynamic>? get aiRecommendData => _aiRecommendData;
  Map<String, dynamic>? get youthData => _youthData;
  Map<String, dynamic>? get longAudioData => _longAudioData;
  Map<String, dynamic>? get fmRecommendData => _fmRecommendData;
  List<KugouFmInfo> get fmClassList => _fmClassList;
  List<KugouThemeInfo> get themePlaylistData => _themePlaylistData;
  List<KugouSheetInfo> get sheetExploreList => _sheetExploreList;
  List<KugouYouthChannel> get youthChannels => _youthChannels;
  List<KugouLongAudioAlbum> get longAudioAlbums => _longAudioAlbums;
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
    _beginLoading();
    _error = null;
    try {
      if (type == 'album') {
        final albums = await _apiClient.searchAlbums(keywords);
        if (albums != null) {
          _searchResults = KugouSearchResult(albums: albums);
        } else {
          _error = '搜索失败';
        }
      } else if (type == 'special') {
        final playlists = await _apiClient.searchPlaylists(keywords);
        if (playlists != null) {
          _searchResults = KugouSearchResult(playlists: playlists);
        } else {
          _error = '搜索失败';
        }
      } else {
        final result = await _apiClient.search(keywords, type: type);
        if (result != null) {
          _searchResults = result;
        } else {
          _error = '搜索失败';
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
    String fmt = 'krc',
  }) async {
    _beginLoading();
    _error = null;
    // 先清空旧歌词，避免切换歌曲时残留上首歌的歌词
    _lyric = null;
    _lyricSongId = hash;
    notifyListeners();
    try {
      final result = await _apiClient.getLyric(
        hash,
        songName: songName,
        fmt: fmt,
      );
      if (_lyricSongId != hash) {
        // 期间切换了歌曲，丢弃旧结果
        return;
      }
      if (result != null) {
        _lyric = result;
      } else {
        _error = '获取歌词失败';
      }
    } catch (e) {
      if (_lyricSongId == hash) {
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

  Future<void> getComments(String hash, {String? albumAudioId}) async {
    _beginLoading();
    _error = null;
    try {
      final result = await _apiClient.getComments(
        hash,
        albumAudioId: albumAudioId,
      );
      if (result != null) {
        _comments = result;
      } else {
        _error = '获取评论失败';
      }
    } catch (e) {
      _error = e.toString();
    }
    _endLoading();
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
      if (qrKey == null || qrKey.qrcode == null) return;
      _qrKey = qrKey;
      notifyListeners();
      final qrData = await _apiClient.createLoginQr(qrKey.qrcode!);
      if (qrData != null) {
        _qrData = qrData;
        notifyListeners();
      }
    } catch (_) {}
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
    _apiClient.clearCookies();
    // 清除头像缓存
    _clearAvatarCache();
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

  Future<void> autoReceiveVipIfNeeded() async {
    if (!_isLoggedIn) return;

    final settingsRepo = SettingsRepository();
    final autoReceive = await settingsRepo.getAutoReceiveVip();
    if (!autoReceive) {
      return;
    }

    try {
      final serverNow = await _apiClient.getServerNow();
      if (serverNow == null) {
        return;
      }

      final timestamp =
          (serverNow['data'] as Map?)?['timestamp'] as int? ??
          serverNow['timestamp'] as int?;
      if (timestamp == null) {
        return;
      }

      final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
      final receiveDay =
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

      try {
        await _apiClient.claimDayVip(receiveDay);
      } catch (_) {}

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

  /// 手动签到/领取: 不依赖 autoReceive 开关，强制调 claim + upgrade
  /// 返回 (success, message)
  Future<(bool, String)> manualSignIn() async {
    if (_manualSignInRunning) return (false, '请求进行中');
    if (!_isLoggedIn) return (false, '请先登录');
    _manualSignInRunning = true;
    notifyListeners();
    try {
      final serverNow = await _apiClient.getServerNow();
      final ts =
          (serverNow?['data'] as Map?)?['timestamp'] as int? ??
          serverNow?['timestamp'] as int?;
      if (ts == null) return (false, '获取服务器时间失败');
      final date = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
      final receiveDay =
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

      final claim = await _apiClient.claimDayVip(receiveDay);

      try {
        await _fetchUserInfo();
        await getVipMonthRecord();
      } catch (_) {}

      final claimOk = claim?['status'] == 1;
      if (claimOk) {
        return (true, '签到成功');
      } else {
        final err = claim?['error_msg']?.toString() ?? '今日已签到';
        return (false, err);
      }
    } catch (e) {
      return (false, '网络异常: $e');
    } finally {
      _manualSignInRunning = false;
      notifyListeners();
    }
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
      final r = await _apiClient.getYouthMonthVipRecord();
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
        final data = r['data'] as Map<String, dynamic>? ?? r;
        final list = data['list'] ?? data['info'] ?? [];
        _longAudioAlbums = (list as List)
            .map((e) => KugouLongAudioAlbum.fromJson(e as Map<String, dynamic>))
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

  Future<void> getAiRecommend() async {
    try {
      final r = await _apiClient.getAiRecommend();
      if (r != null) {
        _aiRecommendData = r;
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
