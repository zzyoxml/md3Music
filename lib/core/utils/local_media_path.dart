import 'dart:io';

/// 把应用内的本地媒体路径形态归一为 `dart:io` 可用的绝对路径。
///
/// **要治的是什么**：本地歌曲的 `localPath` 在播放解析后会被回写成
/// `file://` URI（`player_provider._resolvePlaybackUrlImpl` → `Uri.file(raw)`，
/// 中文/空格还会 percent 编码），而封面读取链路（[LocalArtworkCache] →
/// `readArtworkInIsolate` → `File(path)`）原先把它当裸磁盘路径用：
/// `File('file:///storage/.../%E6%99%B4%E5%A4%A9.mp3').existsSync()` 恒为 false
/// → 判定「无内嵌封面」→ 播放页只剩音符占位符（列表用曲库对象、路径未被回写，
/// 所以列表正常）。原生通知链自己会剥 `file://` 前缀（见
/// `AudioPlaybackService.extractEmbeddedArtwork`），吃亏的只有 Dart 侧。
///
/// **支持形态**：裸绝对路径、`file://` URI（含 percent 编码）、`local://<path>`
/// （`local://` 前缀由 `local_music_repository` / `external_media_intent_service`
/// 用作「内嵌封面」标识）。
///
/// **刻意不处理**的入参：`content://`、`http(s)://` 等非本地形态**原样返回**，
/// 由调用方决定语义（封面缓存层按「读不到」返回 null）。裸路径也不做 percent
/// 解码——文件名里字面含 `%` 时解码会误伤（同 `local_http_server` 的既有取舍）。
///
/// 返回 null 表示「不是可读的本地路径」（空串、纯空白、`file://` 无路径）。
String? normalizeLocalMediaPath(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;

  // `local://<path>`：库内「内嵌封面」标识，去掉前缀后按普通本地路径继续处理。
  if (trimmed.startsWith('local://')) {
    return normalizeLocalMediaPath(trimmed.substring('local://'.length));
  }

  if (trimmed.startsWith('file://')) {
    final path = _fileUriToPath(trimmed);
    if (path == null || path.trim().isEmpty) return null;
    return path;
  }

  return trimmed;
}

/// `file://` → 磁盘路径。优先走 `Uri.toFilePath`（正确还原 percent 编码）；
/// URI 解析失败时退化为「剥前缀 + decodeFull」，宁可按原样试一次也不直接判空。
String? _fileUriToPath(String uriText) {
  // 先按原文剥前缀判断「到底有没有路径」：`Uri.parse('file://')` 会把空
  // authority 规范化成 `path == '/'`，直接看 `uri.path` 会被骗成「根目录」。
  final body = uriText.substring('file://'.length);
  if (body.replaceAll('/', '').replaceAll(r'\', '').isEmpty) return null;

  final uri = Uri.tryParse(uriText);
  if (uri != null && uri.scheme == 'file') {
    try {
      return uri.toFilePath();
    } on UnsupportedError {
      // 非本平台形态（如 Windows 上解析 POSIX file URI）→ 走下面的兜底。
    } on FormatException {
      // 同上。
    }
    final decoded = _tryDecode(uri.path);
    // URI 的 path 不带盘符斜杠语义：Windows 上 `file:///C:/a.mp3` 的 path 是
    // `/C:/a.mp3`，交给 `File` 前把前导斜杠去掉。
    if (Platform.isWindows &&
        decoded.length > 2 &&
        decoded[0] == '/' &&
        decoded[2] == ':') {
      return decoded.substring(1);
    }
    return decoded.isEmpty ? null : decoded;
  }
  // URI 解析失败（含非法 percent）：按原文剥前缀后解码。
  final decoded = _tryDecode(body);
  return decoded.isEmpty ? null : decoded;
}

/// percent 解码；非法编码不抛错，按原文返回。
String _tryDecode(String value) {
  try {
    return Uri.decodeFull(value);
  } catch (_) {
    return value;
  }
}
