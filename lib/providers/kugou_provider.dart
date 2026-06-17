import 'package:flutter/foundation.dart';

import '../data/models/album.dart';
import '../data/models/artist.dart';
import '../data/models/playlist.dart';
import '../data/models/song.dart';
import '../data/repositories/settings_repository.dart';
import '../services/kugou_api/kugou_api_client.dart';
import '../services/kugou_api/kugou_endpoints.dart';
import '../services/kugou_api/kugou_models.dart';

class KugouProvider extends ChangeNotifier {
  final KugouApiClient _apiClient = KugouApiClient();

  KugouProvider() {
    _autoConnect();
  }

  Future<void> _autoConnect() async {
    try {
      debugPrint('自动连接 API 服务器: ${KugouEndpoints.baseUrl}');
      await _apiClient.registerDevice();
      debugPrint('API 连接成功');

      if (_apiClient.isLoggedIn) {
        _isLoggedIn = true;
        debugPrint('检测到已保存的登录状态，自动恢复登录');
        await _fetchUserInfo();
        await autoReceiveVipIfNeeded();
      }
    } catch (e) {
      debugPrint('API 连接失败: $e');
    }
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

  void _setLoading(bool v) {
    _isLoading = v;
    notifyListeners();
  }

  Future<void> search(String keywords, {String type = 'song'}) async {
    _isLoading = true;
    _error = null;
    notifyListeners();
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
    } catch (e) {
      _error = e.toString();
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> getHotSearch() async {
    _isLoading = true;
    _error = null;
    notifyListeners();
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
    _isLoading = false;
    notifyListeners();
  }

  Future<void> getRankList() async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      final result = await _apiClient.getRankList();
      if (result != null) {
        _rankList = result;
      } else {
        _error = '获取排行榜失败';
      }
    } catch (e) {
      _error = e.toString();
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> getRecommendDaily() async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      final result = await _apiClient.getRecommendDaily();
      if (result != null) {
        _recommendSongs = result;
      } else {
        _error = '获取每日推荐失败';
      }
    } catch (e) {
      _error = e.toString();
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> getSongUrl(String hash, {String quality = '128'}) async {
    _isLoading = true;
    _error = null;
    notifyListeners();
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
    _isLoading = false;
    notifyListeners();
  }

  Future<void> getLyric(String hash, {String? songName}) async {
    _isLoading = true;
    _error = null;
    // 先清空旧歌词，避免切换歌曲时残留上首歌的歌词
    _lyric = null;
    _lyricSongId = hash;
    notifyListeners();
    try {
      final result = await _apiClient.getLyric(hash, songName: songName);
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
    _isLoading = false;
    notifyListeners();
  }

  Future<void> getPlaylistDetail(String ids) async {
    _isLoading = true;
    _error = null;
    notifyListeners();
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
    _isLoading = false;
    notifyListeners();
  }

  Future<void> getComments(String hash, {String? albumAudioId}) async {
    _isLoading = true;
    _error = null;
    notifyListeners();
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
    _isLoading = false;
    notifyListeners();
  }

  Future<void> getSongDetail(String hash) async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      await _apiClient.getSongDetail(hash);
    } catch (e) {
      _error = e.toString();
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> getArtistDetail(String artistId) async {
    _isLoading = true;
    _error = null;
    notifyListeners();
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
    _isLoading = false;
    notifyListeners();
  }

  Future<void> getAlbumDetail(String albumId) async {
    _isLoading = true;
    _error = null;
    notifyListeners();
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
    _isLoading = false;
    notifyListeners();
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
    _isLoading = true;
    _error = null;
    notifyListeners();
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
    _isLoading = false;
    notifyListeners();
  }

  Future<void> getPersonalFm({
    String? mode,
    int? songPoolId,
    String? hash,
    String? songId,
    String? action,
  }) async {
    _isLoading = true;
    _error = null;
    notifyListeners();
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
      } else {
        _error = '获取猜你喜欢失败';
      }
    } catch (e) {
      _error = e.toString();
    }
    _isLoading = false;
    notifyListeners();
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

  Future<void> getPlaylist({String? categoryId, int page = 1}) async {
    try {
      final result = await _apiClient.getPlaylist(
        categoryId: categoryId,
        page: page,
      );
      if (result != null) {
        _playlistCategory = result;
        _playlistList = result.playlistList;
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
    } catch (e) {
      debugPrint('Generate QR code error: $e');
    }
  }

  Future<int?> checkQrCode() async {
    if (_qrKey == null || _qrKey?.qrcode == null) return null;
    try {
      final result = await _apiClient.checkLoginQr(_qrKey!.qrcode!);
      if (result == null) return null;
      if (result.status == 4 && result.token != null && result.userid != null) {
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
    } catch (e) {
      debugPrint('Check QR code error: $e');
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
      debugPrint('sendLoginCaptcha response: $res');
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
      debugPrint('loginByPhone response: $res');
      if (res?['status'] == 1) {
        final data = res?['data'] as Map?;
        final token = data?['token']?.toString();
        final userid = data?['userid']?.toString();
        final vipToken = data?['vip_token']?.toString();
        if (token != null && userid != null) {
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
    } catch (e) {
      debugPrint('Fetch user info error: $e');
    }
  }

  // 内部调用, 保留为下划线形式仅在类内使用
  Future<void> _fetchUserInfo() => refreshUserInfo();

  void logout() {
    _isLoggedIn = false;
    _userInfo = null;
    _qrKey = null;
    _qrData = null;
    _apiClient.clearCookies();
    notifyListeners();
  }

  Future<void> autoReceiveVipIfNeeded() async {
    if (!_isLoggedIn) return;

    final settingsRepo = SettingsRepository();
    final autoReceive = await settingsRepo.getAutoReceiveVip();
    if (!autoReceive) {
      debugPrint('autoReceiveVipIfNeeded: 自动领取VIP已禁用');
      return;
    }

    try {
      final serverNow = await _apiClient.getServerNow();
      if (serverNow == null) {
        debugPrint('autoReceiveVipIfNeeded: 获取服务器时间失败');
        return;
      }

      final timestamp =
          (serverNow['data'] as Map?)?['timestamp'] as int? ??
          serverNow['timestamp'] as int?;
      if (timestamp == null) {
        debugPrint('autoReceiveVipIfNeeded: 服务器时间为空');
        return;
      }

      final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
      final receiveDay =
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

      debugPrint('autoReceiveVipIfNeeded: 尝试领取每日VIP, date=$receiveDay');

      try {
        final claimResult = await _apiClient.claimDayVip(receiveDay);
        debugPrint('autoReceiveVipIfNeeded: claimDayVip result=$claimResult');
      } catch (e) {
        debugPrint('autoReceiveVipIfNeeded: claimDayVip failed: $e');
      }

      try {
        await _fetchUserInfo();
      } catch (e) {
        debugPrint('autoReceiveVipIfNeeded: fetchUserInfo failed: $e');
      }

      try {
        await getVipMonthRecord();
      } catch (e) {
        debugPrint('autoReceiveVipIfNeeded: getVipMonthRecord failed: $e');
      }
    } catch (e) {
      debugPrint('autoReceiveVipIfNeeded error: $e');
    }
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
      debugPrint('manualSignIn error: $e');
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
  }) async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
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
    } catch (e) {
      _error = e.toString();
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> getPlaylistTrackAll({
    required String id,
    int page = 1,
    int pagesize = 30,
  }) async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
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
    } catch (e) {
      _error = e.toString();
    }
    _isLoading = false;
    notifyListeners();
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

  Future<void> getYuekuBanner() async {
    try {
      final r = await _apiClient.getYuekuBanner();
      if (r != null) {
        _yuekuBanner = r;
        notifyListeners();
      }
    } catch (_) {}
  }

  // ==================== Scene (场景) ====================

  Future<void> getSceneMusic() async {
    _setLoading(true);
    try {
      final r = await _apiClient.getSceneMusic();
      if (r != null) {
        _sceneData = r;
      }
    } catch (_) {}
    _setLoading(false);
  }

  // ==================== Theme (主题) ====================

  Future<void> getThemeMusic() async {
    try {
      final r = await _apiClient.getThemeMusic();
      if (r != null) {
        _themeMusicData = r;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> getThemePlaylist() async {
    try {
      final r = await _apiClient.getThemePlaylist();
      if (r != null) {
        final data = r['data'] as Map<String, dynamic>? ?? r;
        final list = data['list'] ?? data['info'] ?? [];
        _themePlaylistData = (list as List)
            .map((e) => KugouThemeInfo.fromJson(e as Map<String, dynamic>))
            .toList();
        notifyListeners();
      }
    } catch (_) {}
  }

  // ==================== IP (编辑精选) ====================

  Future<void> getIpHome() async {
    try {
      final r = await _apiClient.getIpHome();
      if (r != null) {
        _ipHomeData = r;
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
      debugPrint('[VIP-DEBUG] monthVipRecord raw: $r');
      if (r != null) {
        _vipMonthRecord = r;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[VIP-DEBUG] monthVipRecord error: $e');
    }
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
