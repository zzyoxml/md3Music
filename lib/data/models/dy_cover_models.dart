/// 专辑动态封面（酷狗 `/album/dycover` 的 `data[i].dycover` 段）。
///
/// 上游实测结构（2026-09-17）：
/// ```json
/// {"status":1,"data":[{"base":{...},"dycover":{
///   "h264_hash":"...","h264_url":"http://kgv.stream.tencentmusic.com/xxx.f160030.mp4?...",
///   "h264_backup_url":["...&isbak=1"],
///   "h265_hash":"...","h265_url":"...f160130.mp4?..."}}]}
/// ```
/// 专辑没有动态封面时该元素是空对象 `{}`，因此所有字段都必须兜底。
class DyCoverInfo {
  /// 专辑音乐 id（= 歌曲的 `Song.albumAudioId`），用于拼媒体代理地址。
  final String albumAudioId;

  /// h264 主地址（优先使用：兼容性最好）。**仅用于「是否具备动态封面」的判定**：
  /// 播放地址一律走本地回环代理，客户端不直接访问 CDN 明文地址。
  final String? h264Url;

  /// h265 主地址（保留字段，当前不启用）。
  final String? h265Url;

  /// h264 文件 md5（上游 `h264_hash`，大写 hex），可用于调试与去重。
  final String? h264Hash;

  const DyCoverInfo({
    required this.albumAudioId,
    this.h264Url,
    this.h265Url,
    this.h264Hash,
  });

  /// 是否拿到可播放地址。
  bool get hasVideo => (h264Url ?? '').isNotEmpty;

  static String? _str(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  /// 从 `/album/dycover` 响应中取第 [index] 个条目的 dycover。
  ///
  /// 返回 null 表示「该专辑没有动态封面」或「响应结构不符合预期」，
  /// 调用方一律按“无动态封面”处理（不视为错误）。
  static DyCoverInfo? fromResponse(
    Map<String, dynamic> json, {
    required String albumAudioId,
    int index = 0,
  }) {
    final data = json['data'];
    if (data is! List || index < 0 || index >= data.length) return null;
    final item = data[index];
    if (item is! Map) return null;
    final dy = item['dycover'];
    if (dy is! Map) return null;

    final primary = _str(dy['h264_url']);
    final backup = () {
      final list = dy['h264_backup_url'];
      if (list is List && list.isNotEmpty) return _str(list.first);
      return null;
    }();

    final info = DyCoverInfo(
      albumAudioId: albumAudioId,
      h264Url: primary ?? backup,
      h265Url: _str(dy['h265_url']),
      h264Hash: _str(dy['h264_hash']),
    );
    return info.hasVideo ? info : null;
  }
}
