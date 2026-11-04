import 'package:flutter/foundation.dart';

import '../services/kugou_api/kugou_api_client.dart';
import '../services/kugou_api/kugou_models.dart';

/// 黑名单条目状态：present=已加入；absent=确定不在（仅在拉满后可判）；
/// unknown=未拉满无法判定（UI 按「未加入」处理，交由服务端判定重复）。
enum BlacklistStatus { present, absent, unknown }

/// 内容黑名单（歌曲「不感兴趣」/ 歌手「屏蔽」）的跨页状态源。
/// 按 label 分桶缓存，供管理页列表与歌曲菜单 / 歌手页的状态判断共用；
/// 与 KugouProvider 联动（app.dart 的 ChangeNotifierProxyProvider）：
/// 登录态/账号变化时清空缓存，防止跨账号串状态。
class BlacklistProvider extends ChangeNotifier {
  /// 常规分页大小（与服务端默认一致）。
  static const int pageSize = 30;

  /// ensureFullyLoaded 的单页拉取大小（服务端上限 500）。
  static const int _fullPageSize = 500;

  /// ensureFullyLoaded 的页数保护：500/页 × 20 页仍未拉满就放弃
  /// （正常远达不到；防御 token 失效等异常下死循环）。
  static const int _maxFullPages = 20;

  final KugouApiClient _apiClient = KugouApiClient();

  final Map<String, _BlacklistBucket> _buckets = {
    'song': _BlacklistBucket(),
    'singer': _BlacklistBucket(),
  };

  // 登录态跟踪：isLoggedIn 或 userid 翻转（登录/登出/换号）即清空缓存。
  bool _lastLoggedIn = false;
  String? _lastUserid;

  _BlacklistBucket _bucketOf(String label) =>
      _buckets[label == 'singer' ? 'singer' : 'song']!;

  /// 由 app.dart 在 KugouProvider 通知时同步（非公开 API，UI 不直接调用）。
  void syncLoginState({required bool loggedIn, String? userid}) {
    if (_lastLoggedIn == loggedIn && _lastUserid == userid) return;
    _lastLoggedIn = loggedIn;
    _lastUserid = userid;
    reset();
  }

  // ---- 桶状态读取 ----

  List<KugouBlacklistEntry> entries(String label) =>
      List.unmodifiable(_bucketOf(label).entries);

  bool isLoading(String label) => _bucketOf(label).loading;

  /// 是否成功拉过至少一页（区分「空黑名单」与「还没加载/失败」）。
  bool isLoaded(String label) => _bucketOf(label).loaded;

  /// 是否已拉满全部条目（后续没有更多页）。
  bool isFullyLoaded(String label) => _bucketOf(label).fullyLoaded;

  int totalOf(String label) => _bucketOf(label).total;

  Object? errorOf(String label) => _bucketOf(label).error;

  /// 是否还有下一页（管理页「加载更多」按钮的可见性）。
  bool hasMore(String label) {
    final b = _bucketOf(label);
    return b.loaded && !b.fullyLoaded && b.page * pageSize < b.total;
  }

  /// 条目状态判定（菜单/歌手页用）。
  BlacklistStatus statusFor(String label, String key) {
    final b = _bucketOf(label);
    if (b.keys.contains(key)) return BlacklistStatus.present;
    return b.fullyLoaded ? BlacklistStatus.absent : BlacklistStatus.unknown;
  }

  // ---- 拉取 ----

  /// 拉取第一页（已加载过且非强制时直接复用缓存）。
  Future<void> load(String label, {bool force = false}) {
    final b = _bucketOf(label);
    if (!force) {
      if (b.loaded) return Future.value();
      final f = b.inFlight;
      if (f != null) return f;
    }
    return _fetch(label, page: 1, reset: true);
  }

  /// 加载下一页（管理页「加载更多」）。
  Future<void> loadMore(String label) {
    final b = _bucketOf(label);
    if (b.loading || !b.loaded || b.fullyLoaded) return Future.value();
    return _fetch(label, page: b.page + 1);
  }

  /// 全量拉取（分页 500/页），用于菜单/歌手页可靠的「已加入」判定。
  /// 统一从第 1 页按大页重拉（键集合去重，幂等），避免与常规分页的页大小错位漏项。
  Future<void> ensureFullyLoaded(String label) async {
    final b = _bucketOf(label);
    if (b.fullyLoaded) return;
    for (var page = 1; page <= _maxFullPages; page++) {
      await _fetch(
        label,
        page: page,
        pagesize: _fullPageSize,
        reset: page == 1,
      );
      if (b.error != null) return;
      if (b.fullyLoaded) return;
    }
  }

  Future<void> _fetch(
    String label, {
    required int page,
    int pagesize = pageSize,
    bool reset = false,
  }) {
    final b = _bucketOf(label);
    if (b.inFlight != null) return b.inFlight!;
    final future = _doFetch(label, page: page, pagesize: pagesize, reset: reset);
    b.inFlight = future;
    return future;
  }

  Future<void> _doFetch(
    String label, {
    required int page,
    required int pagesize,
    required bool reset,
  }) async {
    final b = _bucketOf(label);
    b.loading = true;
    b.error = null;
    notifyListeners();
    try {
      final resp = await _apiClient.getBlacklistList(
        label: label,
        page: page,
        pagesize: pagesize,
      );
      final snapshot =
          resp == null ? null : KugouBlacklistSnapshot.fromJson(resp);
      if (snapshot == null || !snapshot.ok) {
        b.error = snapshot == null
            ? Exception('黑名单请求失败')
            : Exception('黑名单业务失败');
      } else {
        if (reset) {
          b.entries.clear();
          b.keys.clear();
        }
        for (final e in snapshot.entries) {
          if (b.keys.add(e.key)) b.entries.add(e);
        }
        b.page = snapshot.page;
        b.total = snapshot.total;
        b.loaded = true;
        b.fullyLoaded = snapshot.entries.isEmpty ||
            snapshot.page * snapshot.pagesize >= snapshot.total;
      }
    } catch (e) {
      b.error = e;
    } finally {
      b.loading = false;
      b.inFlight = null;
      notifyListeners();
    }
  }

  // ---- 编辑 ----

  /// 加入歌曲黑名单（不感兴趣）。成功后条目补录入桶（未拉过列表也记录），
  /// 菜单/歌手页的状态立即翻转。返回是否成功。
  Future<bool> addSong({
    required String hash,
    String name = '',
    String? mixSongId,
    String? moduleId,
  }) {
    final key = hash.toLowerCase();
    return _add(
      label: 'song',
      key: key,
      name: name,
      mixSongId: mixSongId,
      request: () => _apiClient.editBlacklist(
        hash: key,
        name: name,
        mixsongid: mixSongId,
        moduleId: moduleId,
      ),
    );
  }

  /// 加入歌手黑名单（屏蔽）。
  Future<bool> addSinger({
    required String singerId,
    String name = '',
    String? moduleId,
  }) {
    return _add(
      label: 'singer',
      key: singerId,
      name: name,
      request: () => _apiClient.editBlacklist(
        label: 'singer',
        singerid: singerId,
        name: name,
        moduleId: moduleId,
      ),
    );
  }

  Future<bool> _add({
    required String label,
    required String key,
    required String name,
    String? mixSongId,
    required Future<Map<String, dynamic>?> Function() request,
  }) async {
    final b = _bucketOf(label);
    final resp = await request();
    final ok = resp != null && KugouApiClient.isBizOk(resp);
    if (!ok) return false;
    if (b.keys.add(key)) {
      b.entries.insert(
        0,
        KugouBlacklistEntry(
          label: label,
          key: key,
          name: name,
          mixSongId: mixSongId,
          createdAtSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        ),
      );
      b.total += 1;
      notifyListeners();
    }
    return true;
  }

  /// 从黑名单移除条目（管理页）。成功后本地移除，并从第 1 页重新对齐
  /// （force 重拉，防分页窗口错位漏项），重拉完成后才返回。
  Future<bool> remove(KugouBlacklistEntry entry) async {
    final resp = entry.label == 'singer'
        ? await _apiClient.editBlacklist(
            label: 'singer',
            singerid: entry.key,
            name: entry.name,
            isDelete: true,
          )
        : await _apiClient.editBlacklist(
            label: 'song',
            hash: entry.key,
            name: entry.name,
            mixsongid: entry.mixSongId,
            isDelete: true,
          );
    final ok = resp != null && KugouApiClient.isBizOk(resp);
    if (!ok) return false;
    final b = _bucketOf(entry.label);
    if (b.keys.remove(entry.key)) {
      b.entries.removeWhere((e) => e.key == entry.key);
      b.total = b.total > 0 ? b.total - 1 : 0;
      notifyListeners();
      if (b.loaded) await load(entry.label, force: true);
    }
    return true;
  }

  /// 清空全部缓存（登录/登出/换号时由 syncLoginState 触发）。
  void reset() {
    for (final b in _buckets.values) {
      b.clear();
    }
    notifyListeners();
  }
}

class _BlacklistBucket {
  final List<KugouBlacklistEntry> entries = [];
  final Set<String> keys = {};
  int page = 0;
  int total = 0;
  bool loading = false;
  bool loaded = false;
  bool fullyLoaded = false;
  Object? error;
  Future<void>? inFlight;

  void clear() {
    entries.clear();
    keys.clear();
    page = 0;
    total = 0;
    loading = false;
    loaded = false;
    fullyLoaded = false;
    error = null;
    inFlight = null;
  }
}
