/// 本地音乐文件夹数据模型。
///
/// 表示一个包含音频文件的目录，用于"文件夹"浏览模式。
class MusicFolder {
  /// 文件夹完整路径（如 `/storage/emulated/0/Music`）
  final String path;

  /// 文件夹名称（从 path 提取的最后一段）
  final String name;

  /// 该文件夹下所有歌曲的 ID 列表
  final List<String> songIds;

  const MusicFolder({
    required this.path,
    required this.name,
    required this.songIds,
  });

  int get songCount => songIds.length;

  /// 用于 UI 显示的文件夹名：从完整路径提取最后一段。
  /// 若路径为 `/storage/emulated/0/Music`，则返回 `Music`。
  String get displayName {
    final parts = path.split('/').where((p) => p.isNotEmpty);
    return parts.isNotEmpty ? parts.last : path;
  }
}
