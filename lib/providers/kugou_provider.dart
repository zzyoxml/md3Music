import 'package:flutter/foundation.dart';

import '../data/models/album.dart';
import '../data/models/artist.dart';
import '../data/models/playlist.dart';
import '../data/models/song.dart';
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
      debugPrint('🔌 自动连接 API 服务器: ${KugouEndpoints.baseUrl}');
      await _apiClient.registerDevice();
      debugPrint('✅ API 连接成功');
    } catch (e) {
      debugPrint('❌ API 连接失败: $e');
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

  Future<void> search(String keywords, {String type = 'song'}) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final result = await _apiClient.search(keywords, type: type);
      if (result != null) {
        _searchResults = result;
      } else {
        _error = '搜索失败';
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
    notifyListeners();

    try {
      final result = await _apiClient.getLyric(hash, songName: songName);
      if (result != null) {
        _lyric = result;
      } else {
        _error = '获取歌词失败';
      }
    } catch (e) {
      _error = e.toString();
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
      final result = await _apiClient.getSongDetail(hash);
      if (result != null) {
        if (_searchResults != null) {
          final songs = _searchResults!.songs;
          final idx = songs.indexWhere((s) => s.hash == hash);
          if (idx >= 0) {
            _searchResults = KugouSearchResult(
              songs: songs,
              artists: _searchResults!.artists,
              albums: _searchResults!.albums,
              playlists: _searchResults!.playlists,
              total: _searchResults!.total,
            );
          }
        }
      } else {
        _error = '获取歌曲详情失败';
      }
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

  Future<void> getPersonalFm() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final result = await _apiClient.getPersonalFm();
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
      debugPrint(
        'QR check status: ${result.status}, token: ${result.token != null ? 'present' : 'null'}',
      );

      if (result.status == 4 && result.token != null && result.userid != null) {
        _isLoggedIn = true;
        await _apiClient.setLoginCookies(result.token!, result.userid!);
        await _fetchUserInfo();
        notifyListeners();
      } else if (result.status == 2) {
        debugPrint('QR code scanned, waiting for confirmation');
      } else if (result.status == 1) {
        debugPrint('QR code waiting for scan');
      } else if (result.status == 0 || result.status == 800) {
        debugPrint('QR code expired');
      }
      return result.status;
    } catch (e) {
      debugPrint('Check QR code error: $e');
      return null;
    }
  }

  Future<void> _fetchUserInfo() async {
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

  void logout() {
    _isLoggedIn = false;
    _userInfo = null;
    _qrKey = null;
    _qrData = null;
    _apiClient.clearCookies();
    notifyListeners();
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
}
