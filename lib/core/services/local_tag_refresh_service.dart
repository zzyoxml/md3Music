import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../main.dart' show appNavigatorKey;
import '../../providers/library_provider.dart';

/// 在用外部编辑器（Lyrico 等）改过本地文件后，等 App 回到前台时刷新标签。
///
/// ## 为什么需要这个
///
/// Lyrico 是**外部 Activity**：`launchLyricoEdit` 只能确认「已成功拉起」，
/// 用户在里面改了多久、改了什么，本进程一概不知。等它结束也没有回调——
/// 唯一可靠的时机是 **App 重新回到前台**（`AppLifecycleState.resumed`）。
///
/// 若只在拉起后立即刷新，刷新必然发生在用户还在编辑时，读到的是旧文件，
/// 这正是 issue #250「lyrico 修改后仍没有歌词」的直接原因。
///
/// ## 刷新范围
///
/// 只针对被编辑的那几个路径（[markEdited] 登记），不做全库重扫：大曲库重扫
/// 代价极高，而且绝大多数文件根本没被动过。刷新同时覆盖
/// - 持久化缓存里的 title/artist/album/localLyrics；
/// - 内存索引与专辑/艺术家/文件夹分类（见 [LibraryProvider.refreshLocalTags]）。
///
/// 登记是**一次性**的：刷新完即清空，避免每次回前台都重复解析。
class LocalTagRefreshService with WidgetsBindingObserver {
  LocalTagRefreshService._();

  static final LocalTagRefreshService instance = LocalTagRefreshService._();

  /// 待刷新的文件路径（外部编辑返回后处理）。
  final Set<String> _pendingPaths = <String>{};

  /// 已安装观察者（幂等）。
  bool _observing = false;

  /// 正在刷新，避免回前台瞬间重复触发。
  bool _running = false;

  /// 登记「这个文件被外部编辑器改过」，等下次回到前台时刷新。
  void markEdited(String? path) {
    if (path == null || path.isEmpty) return;
    _pendingPaths.add(path);
    _ensureObserving();
    debugPrint('[LocalTagRefresh] 已登记待刷新: $path');
  }

  void _ensureObserving() {
    if (_observing) return;
    WidgetsBinding.instance.addObserver(this);
    _observing = true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // 不 await：生命周期回调不能阻塞。
    // ignore: discarded_futures
    _flush();
  }

  /// 立即处理已登记路径（回到前台时自动调用；也可手动触发）。
  Future<void> _flush() async {
    if (_running) return;
    final paths = _pendingPaths.toList();
    if (paths.isEmpty) return;
    // 先清空再刷新：即使刷新失败也不无限重试（用户可手动重扫）。
    _pendingPaths.clear();
    _running = true;
    try {
      // 生命周期回调里没有 widget 上下文，经根 Navigator 的 context 取 Provider
      // （与 app.dart 里其它「服务 → Provider」的取法一致）。
      final context = appNavigatorKey.currentContext;
      if (context == null || !context.mounted) {
        // 树还没就绪（极早期）：放回去等下次回前台。
        _pendingPaths.addAll(paths);
        return;
      }
      final library = context.read<LibraryProvider>();
      final updated = await library.refreshLocalTags(paths);
      debugPrint('[LocalTagRefresh] 刷新完成: $updated 首');
    } catch (error) {
      debugPrint('[LocalTagRefresh] 刷新失败: $error');
    } finally {
      _running = false;
    }
  }

  /// 当前待处理数量（诊断用）。
  @visibleForTesting
  int get pendingCount => _pendingPaths.length;
}
