import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/mcp/mcp_ports.dart';
import 'package:md3music/providers/library_provider.dart';

/// [McpLocalLibrarySource] 的真实实现：读 LibraryProvider 已装载的本地曲库。
///
/// 只读访问，不触发扫描；曲库未装载完成时自然返回空结果。
class LibraryProviderBackedLocalSource implements McpLocalLibrarySource {
  LibraryProviderBackedLocalSource(this._provider);

  final LibraryProvider _provider;

  @override
  List<Song> search(String keyword, {int limit = 10}) =>
      _provider.searchLocal(keyword).take(limit).toList(growable: false);

  @override
  Song? findById(String id) {
    for (final s in _provider.allSongs) {
      if (s.id == id) return s;
    }
    return null;
  }
}
