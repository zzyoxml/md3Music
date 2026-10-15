import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../data/models/album.dart';
import '../data/models/artist.dart';
import '../data/models/kugou_account.dart';
import '../data/models/playlist.dart';
import '../data/models/song.dart';
import '../data/repositories/home_discover_progress_store.dart';
import '../data/repositories/settings_repository.dart';
import '../core/services/listening_grade_service.dart';
import '../services/kugou_api/kugou_api_client.dart';
import '../services/kugou_api/lyric_lookup_result.dart';
import '../services/kugou_api/kugou_models.dart';
import 'lyric_request_lifecycle.dart';

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

/// 手机验证码登录结果状态。
enum PhoneLoginStatus {
  /// 登录成功
  success,

  /// 手机号绑定多个账号，需用户选择（见 [KugouProvider.pendingLoginAccounts]）
  needChooseAccount,

  /// 登录失败（错误信息见 [KugouProvider.error]）
  failed,
}

/// 手机验证码登录结果。
class PhoneLoginResult {
  final PhoneLoginStatus status;

  const PhoneLoginResult(this.status);
}

/// 账号切换结果（含登录态过期检测）。
enum SwitchAccountResult {
  /// 切换成功
  success,

  /// 目标账号凭证缺失/不完整，切换失败
  noCredentials,

  /// 目标账号凭证已切换，但 token 已失效（登录过期）
  tokenExpired,
}

/// 热搜榜单卡的加载状态（独立于全局 `_isLoading`/`_error`，
/// 见 KugouProvider.loadHotSearch 的隔离说明）。
enum HotSearchStatus { idle, loading, ready, failed }

class HotSearchState {
  final HotSearchStatus status;
  final List<HotSearchBoard> boards;
  final String? error;

  const HotSearchState({
    this.status = HotSearchStatus.idle,
    this.boards = const [],
    this.error,
  });
}

class KugouProvider extends ChangeNotifier {
  // —— 歌词持久化可选扩展点（默认关闭）——
  // 由私有构建（lib/private）注入实现：歌词的读取/存储旁路。
  // 公开构建不注入，均为空操作。
  static Future<KugouLyric?> Function(String hash)? restoreLyric;
  static void Function(String hash, KugouLyric lyric)? storeLyric;

  final KugouApiClient _apiClient = KugouApiClient();

  KugouProvider({bool registerDeviceOnStart = true}) {
    _loadLocalSignedDays();
    if (registerDeviceOnStart) _autoConnect();
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
        // 已保存凭证的恢复不依赖用户资料接口成功。
        notifyListeners();
        // 重启后按当前账号重载签到日历（构造函数里的首次加载可能在
        // _initFromStorage 完成前，此时 userid 尚不可用）
        _localSignedDays.clear();
        await _loadLocalSignedDays();
        await _fetchUserInfo();
        await autoReceiveVipIfNeeded();
        // 每次打开 App 自动从云端同步一次听歌时长（拉取服务器权威 d_sec 并抬升
        // 本地基准）。放在最后：不阻塞上面的关键路径，且失败由方法内部吞掉。
        await getGradeInfo();
      }
    } catch (_) {}
  }

  KugouApiClient get apiClient => _apiClient;

  KugouSearchResult? _searchResults;
  final ValueNotifier<HotSearchState> _hotSearch =
      ValueNotifier(const HotSearchState());
  KugouRankList? _rankList;
  List<KugouSongDetail> _recommendSongs = [];

  // ==================== 首页刷歌推荐（/home/discover） ====================
  //
  // 上游没有 page/offset，"刷到第几"只能由这里数出来，所以刷歌的权威态是这一组
  // 三个字段，而不是 UI 拿到的那个 List：
  //   _homeDiscoverCursor 已消费歌曲总数 → 下次请求的 today_play_num
  //   _homeDiscoverSeen    已消费过的 hash → 服务端去重之外的客户端兜底
  //   _homeDiscoverSongs   展示与播放用的完整列表（首屏 4 首 + 后续批次 + 补货）
  //
  // 三者必须一起推进：只推 cursor 不记 seen，服务端若不认 today_play_num 就会
  // 把同一批歌无限重放；只记 seen 不推 cursor，则会卡在同一个召回窗口里出不来。
  List<KugouSongDetail> _homeDiscoverSongs = [];
  int _homeDiscoverCursor = 0;
  final Set<String> _homeDiscoverSeen = <String>{};
  bool _homeDiscoverProgressLoaded = false;
  bool _homeDiscoverLoadingMore = false;
  static const HomeDiscoverProgressStore _homeDiscoverStore =
      HomeDiscoverProgressStore();

  // ==================== 新歌速递（/top/song） ====================
  //
  // 与刷歌不同：这个榜有真正的 page 分页，所以翻页进度只需记「取到了第几页」，
  // 不用游标 + 断点落盘那一套。seen 只是客户端去重兜底（榜面刷新时相邻两页
  // 可能重叠），丢掉了顶多多一首歌，不像刷歌那样会影响后续取数。
  List<KugouSongDetail> _newSongs = [];
  int _newSongPage = 0;
  bool _newSongHasMore = true;
  bool _newSongLoadingMore = false;
  final Set<String> _newSongSeen = <String>{};
  static const int newSongPageSize = 30;

  KugouPlaylist? _playlistDetail;
  KugouArtistDetail? _artistDetail;
  KugouAlbumDetail? _albumDetail;
  List<String> _searchSuggest = [];
  KugouPlayUrl? _songUrl;
  KugouLyric? _lyric;
  String? _lyricSongId;
  int _lyricRequestGeneration = 0;
  // 歌词 LRU 仅保存有效歌词；typed API 已能区分 notFound 与失败，
  // 但有限TTL负缓存尚未落地，因此当前不缓存无歌词结果。
  // 播放页 / 桌面歌词链路 / Lyricon 三通道共享，命中不再发网络请求
  // （fmt='lrc' 实际是 LRC+KRC 并发双请求，重复拉取代价翻倍）。
  final Map<LyricRequestKey, KugouLyric> _lyricCache = {};
  // 共享请求的各消费者都能收到正文首包；中途加入时也能立即展示已到的正文。
  final Map<LyricRequestKey, Set<void Function(KugouLyric)>> _lyricProgressListeners = {};
  final Map<LyricRequestKey, KugouLyric> _lyricPartialResults = {};
  final LyricRequestDeduplicator<LyricLookupResult> _lyricRequests =
      LyricRequestDeduplicator<LyricLookupResult>();
  final LyricNotFoundCache _lyricNotFoundCache = LyricNotFoundCache(
    ttl: const Duration(minutes: 5),
    capacity: 16,
  );
  static const int _lyricCacheLimit = 16;
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

  /// 手机验证码登录时，手机号绑定多个账号的待选择候选列表。
  List<KugouLoginAccount> _pendingLoginAccounts = [];

  Map<String, dynamic>? _yuekuData;
  Map<String, dynamic>? _yuekuBanner;
  Map<String, dynamic>? _sceneData;
  Map<String, dynamic>? _themeMusicData;
  Map<String, dynamic>? _ipHomeData;
  Map<String, dynamic>? _ipZoneData;
  Map<String, dynamic>? _fmData;
  Map<String, dynamic>? _sheetData;
  Map<String, dynamic>? _everydayHistory;
  List<KugouAlbumBrief> _topAlbums = [];
  KugouUserVipDetail? _vipInfo;
  KugouGradeInfo? _gradeInfo;
  Map<String, dynamic>? _vipMonthRecord;
  KugouUserPreference? _userPreference;
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
  int _longAudioAudiosPage = 1;
  bool _longAudioAudiosHasMore = false;
  List<KugouLongAudioAlbum> _longAudioFreeAlbums = [];
  int _longAudioFreePage = 1;
  bool _longAudioFreeHasMore = false;
  bool _longAudioFreeLoading = false;

  /// 听书分类（tag_id, 名称），来自 /longaudio/tag/list 的 son[]（按上游 sort 升序）。
  List<(int, String)> _longAudioTags = [];
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
      _isDataFresh('homeDiscover') &&
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

  /// 热搜榜单状态。UI 用 ValueListenableBuilder 订阅，避免整页 notifyListeners。
  ValueListenable<HotSearchState> get hotSearchState => _hotSearch;
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

  /// 手机号绑定多个账号时的待选择候选列表（needChooseAccount 时读取）
  List<KugouLoginAccount> get pendingLoginAccounts => _pendingLoginAccounts;
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
  List<KugouAlbumBrief> get topAlbums => _topAlbums;
  List<KugouSongDetail> get newSongs => _newSongs;
  bool get newSongHasMore => _newSongHasMore;
  KugouUserVipDetail? get vipInfo => _vipInfo;
  KugouGradeInfo? get gradeInfo => _gradeInfo;
  KugouUserPreference? get userPreference => _userPreference;

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
  int get longAudioAudiosPage => _longAudioAudiosPage;
  bool get longAudioAudiosHasMore => _longAudioAudiosHasMore;
  List<KugouLongAudioAlbum> get longAudioFreeAlbums => _longAudioFreeAlbums;
  int get longAudioFreePage => _longAudioFreePage;
  bool get longAudioFreeHasMore => _longAudioFreeHasMore;
  bool get longAudioFreeLoading => _longAudioFreeLoading;
  List<(int, String)> get longAudioTags => _longAudioTags;
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

  // ==================== 首页刷歌推荐 ====================

  List<KugouSongDetail> get homeDiscoverSongs => _homeDiscoverSongs;
  bool get homeDiscoverLoadingMore => _homeDiscoverLoadingMore;
  List<Song> get homeDiscoverSongsAsSongs =>
      _homeDiscoverSongs.map((e) => e.toSong()).toList();

  /// 首屏刷歌的条数。刻意用文档默认的 4：它对应酷狗首页一次滑动一屏的量，
  /// 发现页卡片也只渲染这么多。
  static const int homeDiscoverFirstPageSize = 4;

  /// 滑动/补货每批的条数。
  static const int homeDiscoverBatchSize = 30;

  /// 一次取批次时最多试几轮。整批都推过（seen 全命中）时把游标往前推再试，
  /// 服务端召回窗口重叠、或 `today_play_num` 不被认时靠这个兜住。
  static const int homeDiscoverMaxAttempts = 3;

  Future<void> _ensureHomeDiscoverProgress() async {
    if (_homeDiscoverProgressLoaded) return;
    _homeDiscoverProgressLoaded = true;
    final progress = await _homeDiscoverStore.load();
    _homeDiscoverCursor = progress.cursor;
    _homeDiscoverSeen
      ..clear()
      ..addAll(progress.seen);
  }

  /// 断点落盘。写失败只是丢一次断点（下次从头刷），不向上抛——调用方多半正挂在
  /// 播放链路上，不该为一个可丢的缓存失败。
  void _persistHomeDiscoverProgress() {
    unawaited(
      _homeDiscoverStore.save(
        HomeDiscoverProgress(
          cursor: _homeDiscoverCursor,
          seen: Set<String>.of(_homeDiscoverSeen),
        ),
      ),
    );
  }

  /// 把一批新歌并进刷歌列表：推进游标、记 seen、按 hash 去重。
  ///
  /// 返回真正新增的条数——调用方据此判断"还有没有更多"以及要不要再要一批。
  ///
  /// 刻意**重新赋值** [_homeDiscoverSongs] 而不是原地 `add`：刷歌的详情页用
  /// `Selector<KugouProvider, List<KugouSongDetail>>` 订阅这份列表，而 `Selector`
  /// 拿新旧值做 `==` 比较——同一个 List 实例原地改内容，引用没变、比较结果永远
  /// 相等，于是新批次进了数据却永远画不出来（滑到底部什么也不发生）。换成新
  /// 实例既能让 `Selector` 正常重建，也顺带让「这批是新内容」这件事在 widget
  /// 树里是显式可见的。
  int _ingestHomeDiscoverSongs(List<KugouSongDetail> incoming) {
    if (incoming.isEmpty) return 0;
    final merged = <KugouSongDetail>[];
    for (final song in incoming) {
      if (song.hash.isEmpty) continue;
      if (!_homeDiscoverSeen.add(song.hash)) continue;
      merged.add(song);
    }
    if (merged.isEmpty) return 0;
    _homeDiscoverSongs = <KugouSongDetail>[
      ..._homeDiscoverSongs,
      ...merged,
    ];
    // 游标按"并进去多少"推进，而不是按"服务端推了多少"：seen 拦掉的重复项
    // 并没有真正被消费，拿它们去填 today_play_num 会让游标跑得比实际快，
    // 越刷越深、最后连服务端也取不到东西。
    _homeDiscoverCursor += merged.length;
    _persistHomeDiscoverProgress();
    return merged.length;
  }

  /// 首屏刷歌（发现页卡片 + 详情页首次进入）。
  ///
  /// [forceRefresh] 只绕过 5 分钟 TTL，**不重置游标与 seen**：重置等于让用户
  /// 反复看见刚刷过的那几首，"刷"就没有意义了。要换一批就继续往下拉。
  Future<void> getHomeDiscover({bool forceRefresh = false}) async {
    if (!forceRefresh && _isDataFresh('homeDiscover')) return;
    _beginLoading();
    _error = null;
    try {
      await _ensureHomeDiscoverProgress();
      final result = await _apiClient.getHomeDiscover(
        pagesize: homeDiscoverFirstPageSize,
        todayPlayNum: _homeDiscoverCursor,
      );
      if (result == null) {
        _error = '获取刷歌推荐失败';
        return;
      }
      // 整批都推过时不清空列表：宁可这一轮卡片为空、留给用户下拉重试，也不要
      // 用空列表盖掉已经拿到的歌（歌单页 _fetchSongs 是同一个道理）。
      if (result.isEmpty) return;
      _ingestHomeDiscoverSongs(result);
      _dataTimestamps['homeDiscover'] = DateTime.now();
    } catch (e) {
      _error = e.toString();
    }
    _endLoading();
  }

  /// 追加一批刷歌推荐，返回**真正新并进 [_homeDiscoverSongs] 的那些**。
  ///
  /// 列表是被这个方法就地追加的，调用方不需要（也不应该）再往里塞一遍——返回值
  /// 是给"要不要接着要下一批""还有没有更多"这类判断用的，不是给调用方复用的。
  /// 这一点与 [fetchMorePersonalFm] 正好相反：那个**不**动 [personalFmSongs]，
  /// 必须靠 [appendFmSongs] 另写一次。之所以能反过来，是因为刷歌的游标与去重
  /// 全在本方法内部完成——游标必须跟"真正消费掉多少"同步推进，而消费这件事
  /// 只有这里做得到；拆到调用方做，游标就无从与列表保持一致。
  ///
  /// [minCount] 是"这一趟至少要凑到多少首才算成功"。空批或整批都听过时把游标
  /// 往前推一格再试，最多 [maxAttempts] 轮；全试完仍不足则返回已凑到的部分
  /// （可能为空，空表示确实取不动了，调用方据此显示"没有更多了"）。
  Future<List<KugouSongDetail>> fetchMoreHomeDiscover({
    int minCount = homeDiscoverBatchSize,
    int maxAttempts = homeDiscoverMaxAttempts,
  }) async {
    if (_homeDiscoverLoadingMore) return const [];
    _homeDiscoverLoadingMore = true;
    // 声明在 try 之外：finally 里要靠它决定要不要通知订阅者。
    final fresh = <KugouSongDetail>[];
    try {
      await _ensureHomeDiscoverProgress();
      for (var attempt = 0; attempt < maxAttempts; attempt++) {
        if (attempt > 0) {
          // 上一轮整批被 seen 拦掉了，说明还停在同一个召回窗口里。
          // 游标只在这里（拿不到新歌时）单独推一格：这里推的是"服务端已经给过
          // 我们的条数"，与 _ingestHomeDiscoverSongs 推的"真正消费掉的条数"
          // 是两笔账，混在一起会让游标失控。
          _homeDiscoverCursor += homeDiscoverBatchSize;
          _persistHomeDiscoverProgress();
        }
        final result = await _apiClient.getHomeDiscover(
          pagesize: homeDiscoverBatchSize,
          todayPlayNum: _homeDiscoverCursor,
          noCache: true,
        );
        if (result == null || result.isEmpty) continue;
        final added = _ingestHomeDiscoverSongs(result);
        if (added > 0) {
          fresh.addAll(
            _homeDiscoverSongs.skip(_homeDiscoverSongs.length - added),
          );
          if (fresh.length >= minCount) break;
        }
      }
      return fresh;
    } finally {
      _homeDiscoverLoadingMore = false;
      // 必须自己通知：本方法不走 [_beginLoading]/[_endLoading] 计数器（它是滑动
      // 与补货的增量路径，不该把整页的 loading 指示器点亮），所以不能指望那对
      // 边沿通知顺带把新批次推给 UI。不通知的话详情页会一直停在 _hasMore 翻转
      // 之后的旧列表上——数据到了、画面没动。
      if (fresh.isNotEmpty) notifyListeners();
    }
  }

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
    // 刷歌只清展示列表：游标与 seen 是"刷到哪了"的权威态，保存在
    // HomeDiscoverProgressStore 里，一并清掉会让下拉刷新把刚刷过的歌重新端上来。
    _homeDiscoverSongs = [];
    // 新歌速递整组回到「未取过」：分页页码与 seen 都是本页态，没有像刷歌那样
    // 的持久化断点，清掉即可（_dataTimestamps 稍后整体 clear，TTL 一并失效）。
    _newSongs = [];
    _newSongSeen.clear();
    _newSongPage = 0;
    _newSongHasMore = true;
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
          final newAlbums = albums
              .where((a) => !existingIds.contains(a.id))
              .toList();
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
          final newPlaylists = playlists
              .where((p) => !existingIds.contains(p.id))
              .toList();
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
          final newSongs = result.songs
              .where((s) => !existingHashes.contains(s.hash))
              .toList();
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

  /// 加载热搜榜单。默认只在 `idle` 态发请求（进搜索页拉一次；失败也不自动重试，
  /// 由卡内「重试」按钮带 forceRefresh 再打）。
  ///
  /// 刻意不使用 `_beginLoading()` / 不写 `_error`：热搜是进页后台请求，
  /// 失败若污染全局 loading/error，搜索页结果区会被误判成「搜索失败」
  /// （判据见 `search_page.dart` 的 `kugouProvider.error != null && 结果为空`）。
  Future<void> loadHotSearch({bool forceRefresh = false}) async {
    final current = _hotSearch.value;
    if (current.status == HotSearchStatus.loading) return;
    if (!forceRefresh && current.status != HotSearchStatus.idle) return;

    _hotSearch.value = const HotSearchState(status: HotSearchStatus.loading);
    try {
      final boards = await _apiClient.getHotSearch();
      if (boards.isEmpty) {
        _hotSearch.value =
            const HotSearchState(status: HotSearchStatus.failed, error: '暂无热搜数据');
      } else {
        _hotSearch.value = HotSearchState(
          status: HotSearchStatus.ready,
          boards: boards,
        );
      }
    } catch (e) {
      _hotSearch.value =
          HotSearchState(status: HotSearchStatus.failed, error: e.toString());
    }
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

  Future<KugouLyric?> getLyric(
    String hash, {
    String? songName,
    String fmt = 'lrc',
    String? localIdentity,
    bool forceRefresh = false,
    void Function(KugouLyric lyric)? onProgress,
  }) async => (await getLyricResult(
    hash,
    songName: songName,
    fmt: fmt,
    localIdentity: localIdentity,
    forceRefresh: forceRefresh,
    onProgress: onProgress,
  )).lyric;

  Future<LyricLookupResult> getLyricResult(
    String hash, {
    String? songName,
    String fmt = 'lrc',
    String? localIdentity,
    bool forceRefresh = false,
    void Function(KugouLyric lyric)? onProgress,
  }) async {
    // 本地歌曲优先以路径作为身份；没有路径时退回 songName，避免所有空 hash 共用一个键。
    final trackKey = hash.isEmpty
        ? 'local_${localIdentity ?? songName ?? ''}'
        : hash.toLowerCase();
    final requestKey = LyricRequestKey.forRequest(
      identity: trackKey,
      format: fmt,
      songName: songName,
    );
    final requestGeneration = ++_lyricRequestGeneration;
    final clock = Stopwatch()..start();
    var receivedFirst = false;
    void deliverProgress(KugouLyric lyric) {
      if (!receivedFirst) {
        receivedFirst = true;
        debugPrint('[LyricTiming] first=${clock.elapsedMilliseconds}ms track=$trackKey');
      }
      if (_lyricRequestGeneration == requestGeneration && _lyricSongId == trackKey) {
        _lyric = lyric;
        _error = null;
        notifyListeners();
      }
      onProgress?.call(lyric);
    }
    _lyricSongId = trackKey;

    // 正向 LRU 命中：回填 provider 状态后直接返回，不发网络请求。
    if (!forceRefresh) {
      final cached = _lyricCache.remove(requestKey);
      if (cached != null) {
        _lyricCache[requestKey] = cached; // 刷新访问序
        if (_lyricRequestGeneration != requestGeneration) {
          return const LyricLookupResult.canceled();
        }
        _lyric = cached;
        _error = null;
        notifyListeners();
        return LyricLookupResult.found(cached);
      }
    }

    if (forceRefresh) _lyricNotFoundCache.remove(requestKey);
    if (!forceRefresh && _lyricNotFoundCache.contains(requestKey)) {
      if (_lyricRequestGeneration != requestGeneration) {
        return const LyricLookupResult.canceled();
      }
      _lyric = null;
      _error = null;
      notifyListeners();
      return const LyricLookupResult.notFound();
    }

    _beginLoading();
    _error = null;
    // 先清空旧歌词，避免切换歌曲时残留上首歌的歌词
    _lyric = null;
    _lyricSongId = trackKey;
    notifyListeners();
    try {
      _lyricProgressListeners.putIfAbsent(requestKey, () => {}).add(deliverProgress);
      final partial = _lyricPartialResults[requestKey];
      if (partial != null) deliverProgress(partial);
      // Task 15：默认 fmt='lrc' 时，API 客户端会并发发起 LRC + KRC 两个请求，
      // 返回的 KugouLyric 同时携带 decodedContent（LRC 明文）与
      // decodedKrcContent（KRC 明文）。任一请求失败不影响另一个。
      // 这里只调用一次，结果统一存入 _lyric，由 [krcLyric] / [lrcLyric]
      // getter 暴露，调用方通过 KugouLyric.displayKrcLyric / displayLrcLyric
      // 显式分别取两种文本。
      final result = await _lyricRequests.run(requestKey, () async {
        // 私有构建可注入持久化歌词恢复；失败不缓存，继续在线查询。
        KugouLyric? restored;
        if (hash.isNotEmpty) {
          try {
            restored = await KugouProvider.restoreLyric?.call(hash);
          } catch (_) {
            // 持久化不可用时仍可由在线请求恢复歌词。
          }
        }
        if (restored != null) return LyricLookupResult.found(restored);
        return _apiClient.getLyricResult(hash, songName: songName, fmt: fmt,
          onProgress: (lyric) {
            _lyricPartialResults[requestKey] = lyric;
            for (final listener in _lyricProgressListeners[requestKey]?.toList() ??
                <void Function(KugouLyric)>[]) {
              listener(lyric);
            }
          },
        );
      });
      final isCurrentRequest =
          _lyricRequestGeneration == requestGeneration &&
          _lyricSongId == trackKey;
      if (isCurrentRequest) {
        if (result.isFound) {
          final lyric = result.lyric!;
          _lyricNotFoundCache.remove(requestKey);
          _lyric = lyric;
          _putLyricCache(requestKey, lyric);
          // 可选扩展：歌词持久化存储（默认关闭）
          if (hash.isNotEmpty) {
            try {
              KugouProvider.storeLyric?.call(hash, lyric);
            } catch (_) {
              // 存储失败不影响本次已取得的歌词。
            }
          }
          _error = null;
        } else if (result.status == LyricLookupStatus.notFound) {
          _lyricNotFoundCache.put(requestKey);
          // 确认无歌词是正常状态，不显示网络失败提示。
          _error = null;
        } else {
          _error = '获取歌词失败';
        }
      }
      // 展示代次过期只阻止 Provider 状态提交；每个调用者仍拿到共享请求结果。
      return result;
    } catch (e) {
      if (_lyricRequestGeneration == requestGeneration &&
          _lyricSongId == trackKey) {
        _error = e.toString();
      }
      // 网络异常不写缓存：下次重试真实请求
      return const LyricLookupResult.transientFailure();
    } finally {
      final listeners = _lyricProgressListeners[requestKey];
      listeners?.remove(deliverProgress);
      if (listeners?.isEmpty == true) {
        _lyricProgressListeners.remove(requestKey);
        _lyricPartialResults.remove(requestKey);
      }
      debugPrint('[LyricTiming] complete=${clock.elapsedMilliseconds}ms track=$trackKey');
      _endLoading();
    }
  }

  /// 写入歌词缓存并处理超限驱逐（LRU，逐出最久未用项）。
  void _putLyricCache(LyricRequestKey key, KugouLyric? lyric) {
    if (lyric == null) return;
    if (_lyricCache.containsKey(key)) _lyricCache.remove(key);
    _lyricCache[key] = lyric;
    while (_lyricCache.length > _lyricCacheLimit) {
      final oldest = _lyricCache.keys.first;
      _lyricCache.remove(oldest);
    }
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

  /// [noCache] 透传给 [KugouApiClient.getPersonalFm]；首刷会自行置为 true
  /// （见下），其余路径按调用方给的值走。
  Future<void> getPersonalFm({
    String? mode,
    int? songPoolId,
    String? hash,
    String? songId,
    String? action,
    bool noCache = false,
    bool forceRefresh = false,
  }) async {
    // isInteractive 只看调用方传进来的原始参数（在任何默认值之前算），
    // 这样新鲜度短路与 _dataTimestamps['personalFm'] 的记账语义保持原样。
    final isInteractive = mode != null || action != null || hash != null;
    if (!isInteractive && !forceRefresh && _isDataFresh('personalFm')) return;
    // 非交互的首刷补上 action=login，让上游按登录态出个性化批次；
    // 必须同时 noCache，否则这批 login 会被本地 URL 缓存原样回放，改动等于没生效。
    final isFirstPull = !isInteractive && action == null;
    _beginLoading();
    _error = null;
    try {
      var result = await _apiClient.getPersonalFm(
        mode: mode,
        songPoolId: songPoolId,
        hash: hash,
        songId: songId,
        action: isFirstPull ? 'login' : action,
        noCache: isFirstPull ? true : noCache,
      );
      // login 兜底：游客态或上游不认这个 action 时会回空批（_get 把错误吞成 null），
      // 这时退回改动前的默认口径再要一次——与 FmRefill「带游标要不到就退回不带
      // 游标再要一次」同一手法，宁可少一次个性化也不能把电台放成空的。
      if (isFirstPull && (result == null || result.isEmpty)) {
        result = await _apiClient.getPersonalFm(
          songPoolId: songPoolId,
          noCache: true,
        );
      }
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

  /// 拉一批用于续播的私人 FM 歌曲，只把结果交给调用方。
  ///
  /// 与 [getPersonalFm] 的区别是它**不替换** [personalFmSongs]：续播是往队列尾巴
  /// 上接，整体替换会把正在播的那首挤出列表，之后就再也认不出那条队列是电台的。
  /// 走 noCache 是必须的，理由见 [KugouApiClient.getPersonalFm]。
  Future<List<KugouSongDetail>?> fetchMorePersonalFm({
    required String mode,
    required int songPoolId,
    String? hash,
    String? songId,
  }) {
    return _apiClient.getPersonalFm(
      mode: mode,
      songPoolId: songPoolId,
      hash: hash,
      songId: songId,
      action: 'play',
      noCache: true,
    );
  }

  /// 私人 FM 行为回报（红心 / 取消红心 / 垃圾桶 / 播放完成），只做转发。
  ///
  /// 与 [getPersonalFm]、[fetchMorePersonalFm] 都不同：这是一次后台反馈 ping，
  /// 所以**不动** [personalFmSongs]、不 [_beginLoading] / [_endLoading]、也不写
  /// [_error]——否则一次静默回报会把页面转起圈来或顶出页面级错误。
  /// 返回值原样透传（`garbage` 会带回替换批次，红心一类直接忽略）。
  /// 参数与强制 noCache 的理由见 [KugouApiClient.reportPersonalFmAction]。
  Future<List<KugouSongDetail>?> reportPersonalFmAction({
    required String action,
    String? mode,
    int? songPoolId,
    String? hash,
    String? songId,
    String? curMark,
    int? playtime,
    bool isOverplay = false,
  }) {
    return _apiClient.reportPersonalFmAction(
      action: action,
      mode: mode,
      songPoolId: songPoolId,
      hash: hash,
      songId: songId,
      curMark: curMark,
      playtime: playtime,
      isOverplay: isOverplay,
    );
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
        await _apiClient.setLoginCookies(
          result.token!,
          result.userid!,
          vipToken: result.vipToken,
        );
        _isLoggedIn = true;
        notifyListeners();
        // 登录结果先交给页面，资料加载不阻塞扫码成功后的返回。
        unawaited(refreshUserInfo());
      } else if (result.status == 4) {
        _error = '登录响应缺少凭证，请刷新二维码重试';
        notifyListeners();
        return null;
      }
      return result.status;
    } catch (e) {
      _error = '扫码登录失败，请重试';
      notifyListeners();
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

  // 手机号+验证码登录（支持一个手机号绑定多个账号：返回 info_list/user_list
  // 时需用户选择，见 pendingLoginAccounts）
  Future<PhoneLoginResult> loginByPhone(String mobile, String code) async {
    try {
      final res = await _apiClient.loginByCellphone(mobile, code);
      final data = res?['data'] as Map?;
      final token = data?['token']?.toString();
      final userid = data?['userid']?.toString();

      // 单账号：直接登录成功
      if (res?['status'] == 1 && token != null && userid != null) {
        await _completePhoneLogin(data);
        return const PhoneLoginResult(PhoneLoginStatus.success);
      }

      // 多账号：data 里带账号列表（info_list / user_list），需用户选择。
      // 注意：该场景 Rust 服务端包装为 HTTP 502 + status=0 + error_code=34175，
      // 故不能仅凭 status==1 判断，需检查账号列表是否存在。
      final candidates = _parseLoginUserList(data);
      if (candidates.isNotEmpty) {
        _pendingLoginAccounts = candidates;
        notifyListeners();
        return const PhoneLoginResult(PhoneLoginStatus.needChooseAccount);
      }

      _error = res?['error_msg']?.toString() ?? '登录失败';
      notifyListeners();
      return const PhoneLoginResult(PhoneLoginStatus.failed);
    } catch (e) {
      _error = '登录失败: ${e.toString()}';
      notifyListeners();
      return const PhoneLoginResult(PhoneLoginStatus.failed);
    }
  }

  /// 多账号选择后的二次登录：携带选中账号的 userid 重新请求验证码登录。
  Future<bool> loginByPhoneWithAccount(
    String mobile,
    String code,
    String userid,
  ) async {
    try {
      final res = await _apiClient.loginByCellphone(
        mobile,
        code,
        userid: userid,
      );
      if (res?['status'] == 1) {
        final data = res?['data'] as Map?;
        final token = data?['token']?.toString();
        final uid = data?['userid']?.toString();
        if (token != null && uid != null) {
          await _completePhoneLogin(data);
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

  /// 手机验证码登录成功后的公共收尾：清头像缓存 → 保存凭证 → 拉取用户信息。
  Future<void> _completePhoneLogin(Map? data) async {
    final token = data?['token']?.toString();
    final userid = data?['userid']?.toString();
    final vipToken = data?['vip_token']?.toString();
    if (token == null || userid == null) return;

    _pendingLoginAccounts = [];
    // 登录新用户前，清除旧用户的头像缓存
    await _clearAvatarCacheIfUserChanged(userid);
    await _apiClient.setLoginCookies(token, userid, vipToken: vipToken);
    _isLoggedIn = true;
    // 关键：登录新账号前清空当前用户内存缓存（与 switchAccount 一致）。
    // 否则 getUserDetail 失败时 _userInfo 残留旧账号，用户中心顶部显示旧昵称。
    _userInfo = null;
    _vipInfo = null;
    _gradeInfo = null;
    _vipMonthRecord = null;
    _userPreference = null;
    _qrKey = null;
    _qrData = null;
    await _fetchUserInfo();
    print('✅ [Account] 登录新账号: $userid, userInfo=${_userInfo?.nickname}');
    notifyListeners();
  }

  /// 解析多账号响应中的账号列表（兼容 info_list / user_list 等字段名）。
  List<KugouLoginAccount> _parseLoginUserList(Map? data) {
    if (data == null) return [];
    final raw =
        data['info_list'] ??
        data['user_list'] ??
        data['userList'] ??
        data['lists'] ??
        data['list'];
    if (raw is! List || raw.isEmpty) return [];
    return raw
        .whereType<Map>()
        .map((e) => KugouLoginAccount.fromJson(Map<String, dynamic>.from(e)))
        .where((a) => a.userid.isNotEmpty)
        .toList();
  }

  Future<void> refreshUserInfo() async {
    _isLoggedIn = _apiClient.isLoggedIn;
    notifyListeners();
    try {
      final userInfo = await _apiClient.getUserDetail();
      if (userInfo != null) {
        _userInfo = userInfo;
        // 回填账号列表中的昵称/头像（多账号展示）
        await _apiClient.updateAccountProfile(
          userInfo.userid ?? _apiClient.userid ?? '',
          nickname: userInfo.nickname,
          avatar: userInfo.avatar,
        );
        notifyListeners();
      }
    } catch (_) {}
  }

  /// 修改个人资料（/user/update）。仅提交非 null 字段，
  /// signature/birthday/tags 传空串表示清空。
  /// 返回 (业务是否成功, 服务端 msg)；成功后自动刷新用户信息。
  Future<(bool, String?)> updateUserProfile({
    String? nickname,
    int? sex,
    String? birthday,
    String? signature,
    String? province,
    String? city,
    String? memo,
    String? tags,
  }) async {
    Map<String, dynamic>? resp;
    try {
      resp = await _apiClient.updateUserProfile(
        nickname: nickname,
        sex: sex,
        birthday: birthday,
        signature: signature,
        province: province,
        city: city,
        memo: memo,
        tags: tags,
      );
    } catch (_) {
      return (false, null);
    }
    if (resp == null) return (false, null);
    final ok = KugouApiClient.isBizOk(resp);
    final msg = resp['msg'] is String ? resp['msg'] as String : null;
    if (ok) await refreshUserInfo();
    return (ok, msg);
  }

  /// 修改头像（/user/update/avatar，相册图片字节）。
  /// 返回 (业务是否成功, 服务端 msg)；成功后自动刷新用户信息。
  /// 注意头像为异步审核制，写入成功不代表我的页立即显示新头像。
  Future<(bool, String?)> updateUserAvatar(Uint8List bytes) async {
    Map<String, dynamic>? resp;
    try {
      resp = await _apiClient.updateUserAvatar(bytes);
    } catch (_) {
      return (false, null);
    }
    if (resp == null) return (false, null);
    final ok = KugouApiClient.isBizOk(resp);
    final msg = resp['msg'] is String ? resp['msg'] as String : null;
    if (ok) await refreshUserInfo();
    return (ok, msg);
  }

  /// 拉取当前账号的听歌偏好（/user/preference）。
  /// 返回拉到的偏好（失败/未登录返回 null，调用方自行提示）。
  Future<KugouUserPreference?> getUserPreference() async {
    try {
      final r = await _apiClient.getUserPreference();
      if (r != null) {
        _userPreference = r;
        notifyListeners();
      }
      return r;
    } catch (_) {
      return null;
    }
  }

  /// 更新听歌偏好（/user/preference/update）。仅提交非 null 字段
  /// （mode/gender/age 传 id、lang/style/songLang 传 JSON 字符串，空串=清除）。
  /// 返回 (业务是否成功, 服务端 msg)；成功后回读一次，保证本地缓存与服务端一致。
  Future<(bool, String?)> updateUserPreference({
    String? mode,
    String? gender,
    String? age,
    String? lang,
    String? style,
    String? songLang,
  }) async {
    Map<String, dynamic>? resp;
    try {
      resp = await _apiClient.updateUserPreference(
        mode: mode,
        gender: gender,
        age: age,
        lang: lang,
        style: style,
        songLang: songLang,
      );
    } catch (_) {
      return (false, null);
    }
    if (resp == null) return (false, null);
    final ok = KugouApiClient.isBizOk(resp);
    final msg = resp['msg'] is String ? resp['msg'] as String : null;
    if (ok) {
      try {
        final fresh = await _apiClient.getUserPreference();
        if (fresh != null) _userPreference = fresh;
      } catch (_) {}
      notifyListeners();
    }
    return (ok, msg);
  }

  // 内部调用, 保留为下划线形式仅在类内使用
  Future<void> _fetchUserInfo() => refreshUserInfo();

  // ==================== 多账号管理 ====================

  /// 已保存的账号列表（供「账号管理」UI 展示）。
  List<KugouAccount> get savedAccounts => _apiClient.savedAccounts;

  /// 切换到指定账号：切换内存凭证 + 检查登录态是否过期 + 重载该账号的用户信息与签到日历。
  /// 返回切换结果（[SwitchAccountResult.tokenExpired] 表示凭证已切换但登录已过期）。
  Future<SwitchAccountResult> switchAccount(String userid) async {
    final ok = await _apiClient.switchToUser(userid);
    if (!ok) return SwitchAccountResult.noCredentials;

    _isLoggedIn = _apiClient.isLoggedIn;

    // 切换账号后清除旧账号的用户级内存缓存
    _userInfo = null;
    _qrKey = null;
    _qrData = null;
    _vipInfo = null;
    _gradeInfo = null;
    _vipMonthRecord = null;
    _userHistoryData = null;
    _everydayHistory = null;
    _userPreference = null;

    // 头像缓存按账号隔离：账号变化时清空
    _clearAvatarCacheIfUserChanged(userid);

    // 刷歌断点同样按账号隔离（游标 = 这个账号今天刷到哪了）
    _resetHomeDiscoverProgress();

    // 重载新账号的签到日历
    _localSignedDays.clear();
    await _loadLocalSignedDays();

    if (_isLoggedIn) {
      // 检查目标账号登录态是否过期（token 已切换到该账号，直接校验）。
      // 过期时仍在账号列表标记「登录已过期」，由 UI 引导重新登录/删除。
      final valid = await _apiClient.checkTokenValid();
      if (!valid) {
        await _apiClient.markAccountExpired(userid);
        print('⚠️ [Account] 账号 $userid 登录已过期');
        notifyListeners();
        return SwitchAccountResult.tokenExpired;
      }
      await _fetchUserInfo();
      // 会员到期时间与签到日历按账号隔离：切换后必须立即重载新账号的数据，
      // 否则「我的」页面会员卡片仍显示上一账号的信息（且 _vipInfo 已被清空）。
      await getVipDetail();
      await getGradeInfo();
      await _loadLocalSignedDays();
    }

    print('✅ [Account] 已切换到账号: $userid');
    notifyListeners();
    return SwitchAccountResult.success;
  }

  /// 删除指定账号。若删除的是当前账号，自动切换到最近登录的其他账号；
  /// 无其他账号时回到未登录态。
  Future<void> removeAccount(String userid) async {
    final wasCurrent = userid == _apiClient.userid;
    await _apiClient.removeAccount(userid);

    if (wasCurrent) {
      // 重置当前用户缓存
      _userInfo = null;
      _qrKey = null;
      _qrData = null;
      _vipInfo = null;
      _gradeInfo = null;
      _vipMonthRecord = null;
      _userHistoryData = null;
      _everydayHistory = null;
      _userPreference = null;
      _localSignedDays.clear();
      _resetHomeDiscoverProgress();

      final remaining = _apiClient.sortedAccounts;
      if (remaining.isNotEmpty) {
        // 自动切换到最近登录的其他账号
        _isLoggedIn = false;
        await switchAccount(remaining.first.userid);
        notifyListeners();
        return;
      }
      _isLoggedIn = false;
      await _loadLocalSignedDays();
      _clearAvatarCache();
    }

    print('✅ [Account] 已删除账号: $userid');
    notifyListeners();
  }

  Future<void> logout() async {
    // 多账号：退出当前账号；若还有其他账号则自动切换过去
    final uid = _apiClient.userid;
    if (uid == null) {
      _isLoggedIn = false;
      notifyListeners();
      return;
    }
    _isLoggedIn = false;
    await removeAccount(uid);
  }

  /// 丢掉刷歌的断点与已消费集合。
  ///
  /// 断点与账号绑定：游标是"这个账号今天刷到哪了"，带着它换账号会让新账号从
  /// 旧账号的位置继续刷，等于替新账号凭空消费掉一批推荐位。`logout` 与
  /// `switchAccount` 都会走到这里，所以顺带把 [_homeDiscoverProgressLoaded]
  /// 一起复位——不复位的话 [HomeDiscoverProgressStore] 的进程内缓存已经被
  /// 上一账号填满，下一次 `load()` 根本不会回读。
  void _resetHomeDiscoverProgress() {
    _homeDiscoverCursor = 0;
    _homeDiscoverSeen.clear();
    _homeDiscoverProgressLoaded = false;
    unawaited(_homeDiscoverStore.clear());
  }

  void _clearAvatarCache() {
    try {
      // emptyCache 返回 Future，异步错误需用 catchError 捕获，
      // 否则会冒泡为未处理异常（测试环境无 path_provider 插件时尤为明显）
      DefaultCacheManager().emptyCache().catchError((_) {});
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
          upgrade['error_msg']?.toString() ?? upgrade['msg']?.toString() ?? '';
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
    final vType = (data['v_type'] is num)
        ? (data['v_type'] as num).toInt()
        : 23;
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
    final ok =
        result != null && (result['status'] == 1 || result['error_code'] == 0);
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
              success > 0 ? '广告领取 $success/8 次，今日次数已用光' : '今日广告次数已用光',
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

  Future<void> getTopAlbum({int page = 1, bool forceRefresh = false}) async {
    if (!forceRefresh && _isDataFresh('topAlbum')) return;
    try {
      final r = await _apiClient.getTopAlbum(page: page);
      if (r != null) {
        final data = r['data'] as Map<String, dynamic>? ?? r;
        // 上游真实结构（2026-09-19 真机取证）：分语种桶 chn/eur/jpn/kor，
        // 每桶 3 条、不受 pagesize 影响；无统一 list 字段，故按桶合并。
        // list/albums/info 作为兜底链保留，防上游改版回统一列表。
        final primary = data['list'] ?? data['albums'] ?? data['info'];
        final List<dynamic> list;
        if (primary is List && primary.isNotEmpty) {
          list = primary;
        } else {
          list = [
            for (final key in const ['chn', 'eur', 'jpn', 'kor'])
              if (data[key] is List) ...(data[key] as List),
          ];
        }
        _topAlbums = list
            .whereType<Map<String, dynamic>>()
            .map(KugouAlbumBrief.fromJson)
            .where((a) => a.id.isNotEmpty && a.name.isNotEmpty)
            .toList();
        _dataTimestamps['topAlbum'] = DateTime.now();
        notifyListeners();
      }
    } catch (_) {}
  }

  /// 新歌速递首屏（第 1 页）。
  ///
  /// 空结果**不**盖 `_dataTimestamps['newSong']`：请求本身成功、只是榜面为空，
  /// 盖上时间戳等于让发现页接下来 5 分钟（TTL 内直接跳过取数）只显示一个空区块；
  /// 不盖则下次进页还能重试。与 [getHomeDiscover] 的「空批不写时间戳」同一条纪律。
  Future<void> getNewSongs({bool forceRefresh = false}) async {
    if (!forceRefresh && _isDataFresh('newSong')) return;
    _beginLoading();
    _error = null;
    try {
      final list = await _apiClient.getTopSong(
        page: 1,
        pagesize: newSongPageSize,
      );
      if (list == null) {
        _error = '获取新歌速递失败';
      } else if (list.isEmpty) {
        _newSongHasMore = false;
      } else {
        _newSongSeen.clear();
        _newSongs = [];
        _newSongPage = 1;
        _newSongs = _mergeNewSongs(list);
        _newSongHasMore = list.length >= newSongPageSize;
        _dataTimestamps['newSong'] = DateTime.now();
      }
    } catch (e) {
      _error = e.toString();
    }
    _endLoading();
  }

  /// 追加下一页新歌速递，返回**真正新并进 [_newSongs] 的那些**
  /// （契约与 [fetchMoreHomeDiscover] 一致：空列表就是「确实没有更多了」，
  /// 调用方据此收口，不需要也不应该再往列表里塞一遍）。
  Future<List<KugouSongDetail>> fetchMoreNewSongs() async {
    if (_newSongLoadingMore || !_newSongHasMore) return const [];
    _newSongLoadingMore = true;
    // 声明在 try 之外：finally 里要靠它决定要不要通知订阅者。
    final fresh = <KugouSongDetail>[];
    try {
      final next = _newSongPage + 1;
      final list = await _apiClient.getTopSong(
        page: next,
        pagesize: newSongPageSize,
      );
      if (list == null || list.isEmpty) {
        _newSongHasMore = false;
        return const [];
      }
      _newSongPage = next;
      fresh.addAll(_mergeNewSongs(list));
      // 短页即榜单到底：上游不会给「还有更多」的显式标记，只能靠条数判断。
      if (list.length < newSongPageSize) _newSongHasMore = false;
      return fresh;
    } catch (_) {
      // 不翻转 [_newSongHasMore]：一次异常不该永久杀掉翻页，下次滑动还会再试。
      return fresh;
    } finally {
      _newSongLoadingMore = false;
      // 必须自己通知：本方法不走 [_beginLoading]/[_endLoading] 计数器（它是滑动
      // 的增量路径，不该点亮整页的 loading 指示器），所以不能指望那对边沿通知
      // 顺带把新批次推给 UI。
      if (fresh.isNotEmpty) notifyListeners();
    }
  }

  /// 按 hash 去重后把一批歌并进 [_newSongs]，返回真正新增的那些。
  ///
  /// 与 [_ingestHomeDiscoverSongs] 一样刻意**重新赋值**而不是原地 `add`：订阅方用
  /// `Selector<KugouProvider, List<KugouSongDetail>>` 拿新旧值做 `==` 比较，同一个
  /// List 实例原地改内容、引用没变、比较结果永远相等，于是新批次进了数据却永远
  /// 画不出来。
  ///
  /// 与那里有一处**故意不同**：空 hash 的歌在这里保留（只是不拿它当去重键）。
  /// 刷歌的 hash 是取数游标本身，空值必须丢；新歌榜的字段形态还没取证，照抄
  /// 「空 hash 即丢弃」一旦碰上上游换键名就会让整块新区静默变空。
  List<KugouSongDetail> _mergeNewSongs(List<KugouSongDetail> incoming) {
    final merged = <KugouSongDetail>[];
    for (final song in incoming) {
      if (song.hash.isNotEmpty && !_newSongSeen.add(song.hash)) continue;
      merged.add(song);
    }
    if (merged.isEmpty) return merged;
    _newSongs = <KugouSongDetail>[
      ..._newSongs,
      ...merged,
    ];
    return merged;
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

  /// 拉取听歌等级信息，并同步服务器累计时长到本地基准（避免上报被拒）。
  ///
  /// 返回是否成功拿到服务器数据 —— 供「同步云端时长」按钮给出真实反馈
  /// （此前该方法是 `void` 且静默吞异常，调用方无从判断成败）。
  Future<bool> getGradeInfo() async {
    try {
      final r = await _apiClient.getGradeInfo();
      if (r == null) return false;
      _gradeInfo = KugouGradeInfo.fromJson(r);
      // 打印服务器实际返回的 d_sec，用于确认服务器是否记账（排查用）
      // ignore: avoid_print
      print(
        '[GradeQuery] server d_sec=${_gradeInfo?.dSec} grade=${_gradeInfo?.pGrade} point=${_gradeInfo?.pCurrentPoint}/${_gradeInfo?.pNextGradePoint}',
      );
      final serverDsec = _gradeInfo?.dSec;
      if (serverDsec != null) {
        await ListeningGradeService.instance.resyncFromServer(serverDsec);
      }
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
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
        final allRank = albums
            .whereType<Map<String, dynamic>>()
            .map(KugouLongAudioAlbum.fromJson)
            .toList();
        _longAudioAlbums = allRank;
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
        final allVip = (list as List)
            .map((e) => KugouLongAudioAlbum.fromJson(e as Map<String, dynamic>))
            .toList();
        _longAudioVipAlbums = allVip;
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
        final allWeek = (list as List)
            .map((e) => KugouLongAudioAlbum.fromJson(e as Map<String, dynamic>))
            .toList();
        _longAudioWeekAlbums = allWeek;
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

  Future<void> getLongaudioAlbumAudios(
    String albumId, {
    int page = 1,
    int pageSize = 30,
    bool append = false,
  }) async {
    try {
      final r = await _apiClient.getLongaudioAlbumAudios(
        albumId,
        page: page,
        pageSize: pageSize,
      );
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
        final items = list
            .whereType<Map<String, dynamic>>()
            .map(KugouLongAudioAudio.fromJson)
            .toList();
        if (append) {
          _longAudioAudios = [..._longAudioAudios, ...items];
          _longAudioAudiosPage = page;
        } else {
          _longAudioAudios = items;
          _longAudioAudiosPage = 1;
        }
        _longAudioAudiosHasMore = items.length >= pageSize;
        notifyListeners();
      }
    } catch (_) {}
  }

  /// 免费听书库列表（Rust 转发 /longaudio/v1/album/list）。
  /// 响应：data.data_list[] + data.is_end（0=还有下一页）。
  /// 该库本身即限免专辑（官方 App 均可播放），不做 VIP 过滤。
  Future<void> getLongaudioFreeList({
    int tagId = 906,
    int sort = 0,
    int gender = 0,
    int status = 0,
    int page = 1,
    int pageSize = 20,
    bool append = false,
  }) async {
    if (_longAudioFreeLoading) return;
    _longAudioFreeLoading = true;
    notifyListeners();
    try {
      final r = await _apiClient.getLongaudioAlbumList(
        tagId: tagId,
        sort: sort,
        gender: gender,
        status: status,
        page: page,
        pageSize: pageSize,
      );
      if (r != null) {
        final data = r['data'];
        final list = data is Map<String, dynamic> ? data['data_list'] : null;
        final items =
            (list is List
                    ? list.whereType<Map<String, dynamic>>()
                    : <Map<String, dynamic>>[])
                .map(KugouLongAudioAlbum.fromJson)
                .toList();
        if (append) {
          _longAudioFreeAlbums = [..._longAudioFreeAlbums, ...items];
          _longAudioFreePage = page;
        } else {
          _longAudioFreeAlbums = items;
          _longAudioFreePage = 1;
        }
        final isEnd = data is Map<String, dynamic> ? data['is_end'] : 0;
        _longAudioFreeHasMore = isEnd != 1;
        // ignore: avoid_print
        print(
          '[AudiobookFree] tag_id=$tagId sort=$sort gender=$gender status=$status page=$page items=${items.length} isEnd=$isEnd',
        );
        notifyListeners();
      }
    } catch (e) {
      // ignore: avoid_print
      print('[AudiobookFree] exception: $e');
    } finally {
      _longAudioFreeLoading = false;
      notifyListeners();
    }
  }

  /// 听书分类标签树：请求 /longaudio/tag/list，取 data[0].son[]（tag_id/tag_name/sort）。
  /// 已拉取过则不重复请求。
  Future<void> getLongaudioTags() async {
    if (_longAudioTags.isNotEmpty) return;
    try {
      final r = await _apiClient.getLongaudioTagList();
      if (r != null) {
        final data = r['data'];
        final first = data is List && data.isNotEmpty ? data.first : null;
        final son = first is Map<String, dynamic> ? first['son'] : null;
        if (son is List) {
          final tags = <(int, String)>[];
          for (final e in son.whereType<Map<String, dynamic>>()) {
            final id = e['tag_id'];
            final name = e['tag_name']?.toString() ?? '';
            if (id is num && name.isNotEmpty) {
              tags.add((id.toInt(), name));
            }
          }
          // 保持上游 son[] 原顺序（即酷狗 App 的分类展示顺序）
          _longAudioTags = tags;
          // ignore: avoid_print
          print('[AudiobookTags] son=${tags.length}');
          notifyListeners();
        }
      }
    } catch (e) {
      // ignore: avoid_print
      print('[AudiobookTags] exception: $e');
    }
  }

  /// 听书关键词搜索：请求 /search/audiobook（Rust 转发 /complexsearch/v4/search/song）。
  /// 上游返回 data.lists 听书「章节」，这里按 AlbumID 去重成专辑，并清理 <em> 高亮与封面占位。
  Future<List<KugouLongAudioAlbum>> searchLongAudio(String keyword) async {
    try {
      final r = await _apiClient.getLongaudioSearch(keyword);
      if (r == null) {
        // ignore: avoid_print
        print('[AudiobookSearch] getLongaudioSearch 返回 null, keyword=$keyword');
        return const [];
      }
      final data = r['data'];
      final lists = data is Map<String, dynamic> ? data['lists'] : null;
      if (lists is! List || lists.isEmpty) {
        // ignore: avoid_print
        print(
          '[AudiobookSearch] data 无 lists, keyword=$keyword status=${r['status']} err=${r['error_code']}',
        );
        return const [];
      }
      // 按专辑聚合：同专辑去重（不做 VIP 过滤，限免专辑章节付费标识不可靠，全量展示）。
      final titleMap = <String, KugouLongAudioAlbum>{};
      for (final it in lists) {
        if (it is! Map<String, dynamic>) continue;
        final albumId = it['AlbumID']?.toString() ?? '';
        if (albumId.isEmpty) continue;
        final name = _stripHtmlTags(it['AlbumName']?.toString() ?? '');
        if (name.isEmpty) continue;
        if (titleMap.containsKey(albumId)) continue;
        final coverRaw =
            (it['trans_param'] is Map<String, dynamic>
                ? it['trans_param']!['union_cover']
                : null) ??
            it['Image'];
        titleMap[albumId] = KugouLongAudioAlbum(
          id: albumId,
          name: name,
          coverUrl: coverRaw == null
              ? null
              : _stripArtworkUrl(coverRaw.toString()),
          author: _stripHtmlTags(it['SingerName']?.toString() ?? ''),
        );
      }
      // ignore: avoid_print
      print(
        '[AudiobookSearch] chapters=${lists.length} albums=${titleMap.length}, keyword=$keyword',
      );
      return titleMap.values.toList();
    } catch (e) {
      // ignore: avoid_print
      print('[AudiobookSearch] parse exception: $e');
      return const [];
    }
  }

  /// 移除标题中的 <em>/</em> 等 HTML 高亮标签。
  static String _stripHtmlTags(String s) =>
      s.replaceAll(RegExp(r'<[^>]*>'), '').trim();

  /// 封面：去掉 imge.kugou.com 链接外侧的反引号，并替换 {size} 占位。
  static String _stripArtworkUrl(String s) =>
      s.replaceAll('`', '').replaceAll('{size}', '400');

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

  @override
  void dispose() {
    _hotSearch.dispose();
    super.dispose();
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
