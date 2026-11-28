import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/utils/app_toast.dart';
import '../data/models/album.dart';
import '../data/repositories/collected_playlist_store.dart';
import '../providers/playlist_collection_notifier.dart';
import '../services/kugou_api/kugou_api_client.dart';

/// 专辑行尾「收藏」按钮（与歌曲行的红心同一套视觉规格）。
///
/// **为什么做成独立组件**：专辑收藏的完整流程（含取消收藏找回 listid）
/// 原本只写在 `album_detail_page.dart` 里。列表行需要同一能力时，
/// 复制那 80 行会把「乐观更新 + 回滚 + CollectedPlaylistStore 同步」的
/// 三处一致点散成两份，日后必然不同步。这里只抽**行内的轻量入口**，
/// 详情页仍保留自己的实现（它还有 albumDetail 的 artistId 兜底）。
///
/// 状态判定走 [CollectedPlaylistStore] 本地缓存（同步可用、无网络），
/// 列表里不需要为了画一颗心去请求服务端。
class AlbumFavoriteButton extends StatefulWidget {
  const AlbumFavoriteButton({
    super.key,
    required this.album,
    this.size = 44,
  });

  final Album album;

  /// 触控盒边长。默认 44，与 [SongListItem] 的心形按钮一致。
  final double size;

  @override
  State<AlbumFavoriteButton> createState() => _AlbumFavoriteButtonState();
}

class _AlbumFavoriteButtonState extends State<AlbumFavoriteButton> {
  /// 本地缓存读出的 listid；null 表示未收藏。
  String? _listId;
  bool _loaded = false;

  /// 请求进行中：防连点重复提交。
  bool _busy = false;

  bool get _collected => _listId != null;

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  @override
  void didUpdateWidget(covariant AlbumFavoriteButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 列表复用时 album 变了要重新读状态，否则会把上一张的收藏态画到新行上。
    if (oldWidget.album.id != widget.album.id) {
      _loaded = false;
      _listId = null;
      _loadState();
    }
  }

  Future<void> _loadState() async {
    final id = await CollectedPlaylistStore.getListId(widget.album.id);
    if (!mounted) return;
    setState(() {
      _listId = id;
      _loaded = true;
    });
  }

  /// 收藏后在用户歌单里找回对应 listid（同 album_detail_page 的口径：
  /// 按 global_collection_id 或名称匹配）。失败不阻断，下次取消时再找。
  Future<String?> _findCollectedListId(KugouApiClient api) async {
    try {
      final result = await api.getUserPlaylist();
      final items = result?['data']?['info'];
      if (items is List) {
        for (final item in items) {
          if (item is Map<String, dynamic>) {
            final gid = item['global_collection_id']?.toString() ?? '';
            final name = item['name']?.toString() ?? '';
            if (gid == widget.album.id || name == widget.album.name) {
              return item['listid']?.toString();
            }
          }
        }
      }
    } catch (_) {
      // 忽略：拿不到 listid 不影响收藏本身
    }
    return null;
  }

  Future<void> _toggle() async {
    if (_busy) return;
    final api = KugouApiClient();
    if (!api.isLoggedIn) {
      showToast('请先登录', long: true);
      return;
    }

    setState(() => _busy = true);
    if (_collected) {
      await _uncollect(api);
    } else {
      await _collect(api);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _collect(KugouApiClient api) async {
    // 乐观更新：先点亮，失败回滚
    setState(() => _listId = '');
    try {
      final result = await api.collectAlbum(
        widget.album.name,
        // Album 模型不带 artistId（榜单/新碟接口只回歌手名）。
        // collectAlbum 的 artistId 允许空串，服务端按 list_create_userid
        // 记录；详情页在拿不到时同样传空，这里保持同一口径。
        artistId: '',
        albumId: widget.album.id,
      );
      if (result == null) {
        if (mounted) {
          setState(() => _listId = null);
          showToast('收藏失败，请重试', long: true);
        }
        return;
      }
      final newId = await _findCollectedListId(api);
      await CollectedPlaylistStore.setListId(widget.album.id, newId);
      if (!mounted) return;
      setState(() => _listId = newId ?? widget.album.id);
      _notifyCollectionChanged();
    } catch (e) {
      if (mounted) {
        setState(() => _listId = null);
        showToast('收藏失败', long: true);
      }
    }
  }

  Future<void> _uncollect(KugouApiClient api) async {
    setState(() => _listId = null);
    String? listId = await CollectedPlaylistStore.getListId(widget.album.id);
    listId ??= await _findCollectedListId(api);
    if (listId == null || listId.isEmpty) {
      if (mounted) {
        setState(() => _listId = widget.album.id);
        showToast('找不到收藏记录，无法取消', long: true);
      }
      return;
    }
    try {
      final result = await api.deletePlaylist(listId, type: 0);
      if (result != null && mounted) {
        await CollectedPlaylistStore.remove(widget.album.id);
        if (!mounted) return;
        setState(() => _listId = null);
        _notifyCollectionChanged();
      } else if (mounted) {
        setState(() => _listId = widget.album.id);
        showToast('取消收藏失败', long: true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _listId = widget.album.id);
        showToast('取消收藏失败', long: true);
      }
    }
  }

  /// 通知「我的收藏」刷新。Provider 缺席时静默跳过：
  /// 组件测试/局部 harness 不一定会挂这个 Provider，收藏本身不该因此失败。
  void _notifyCollectionChanged() {
    try {
      context.read<PlaylistCollectionNotifier>().notifyChanged();
    } on ProviderNotFoundException {
      // 无 Provider（测试 harness）：收藏已写本地缓存，刷新交给宿主。
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 未读完缓存前只占位，不画错误状态（避免闪一下空心再变实心）。
    final icon = !_loaded
        ? Icons.favorite_border
        : (_collected ? Icons.favorite : Icons.favorite_border);
    final color = (!_loaded || !_collected) ? cs.onSurfaceVariant : cs.error;

    return Semantics(
      button: true,
      label: _collected ? '取消收藏' : '收藏',
      child: GestureDetector(
        onTap: _toggle,
        behavior: HitTestBehavior.opaque,
        // 与 SongListItem._favoriteButton 同规格：44×44 触控盒、18 图标。
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: Center(
            child: Icon(icon, size: 18, color: color),
          ),
        ),
      ),
    );
  }
}
