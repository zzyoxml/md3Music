import 'package:shared_preferences/shared_preferences.dart';

/// 私有设置读写器：边听边存 / 下载 相关设置。
///
/// 原定义于公开的 `SettingsRepository`，已整体迁移至此（仅私有构建使用，
/// 导出公开版本时随 `lib/private/` 排除）。key 与历史值保持一致，
/// 存量用户设置无缝兼容。
class PrivateSettings {
  static const String _keyStreamCacheEnabled = 'settings_stream_cache_enabled';
  static const String _keyStreamCacheLimitMb = 'settings_stream_cache_limit_mb';
  static const String _keyDownloadDir = 'settings_download_dir';
  static const String _keyDownloadWordLevelLyrics =
      'settings_download_word_level_lyrics';

  /// 边听边存功能是否开启，默认关闭。
  Future<bool> getStreamCacheEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyStreamCacheEnabled) ?? false;
  }

  Future<void> setStreamCacheEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyStreamCacheEnabled, value);
  }

  /// 边听边存容量上限（单位 MB），默认 2048（即 2GB）。
  Future<int> getStreamCacheLimitMb() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyStreamCacheLimitMb) ?? 2048;
  }

  Future<void> setStreamCacheLimitMb(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyStreamCacheLimitMb, value);
  }

  /// 读取用户配置的自定义下载目录。
  /// 返回 null/空字符串 表示使用默认目录（应用私有 documents/downloads）。
  Future<String?> getDownloadDir() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_keyDownloadDir);
    if (value == null || value.isEmpty) return null;
    return value;
  }

  /// 持久化用户配置的自定义下载目录。
  /// 传入 null 或空字符串表示恢复使用默认目录。
  Future<void> setDownloadDir(String? path) async {
    final prefs = await SharedPreferences.getInstance();
    if (path == null || path.isEmpty) {
      await prefs.remove(_keyDownloadDir);
    } else {
      await prefs.setString(_keyDownloadDir, path);
    }
  }

  /// 下载时是否内嵌字级 LRC 歌词（逐字时间戳）。
  /// 默认 true：尝试嵌入逐字 LRC，无逐字数据时自动降级为行级 LRC。
  Future<bool> getDownloadWordLevelLyrics() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyDownloadWordLevelLyrics) ?? true;
  }

  Future<void> setDownloadWordLevelLyrics(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyDownloadWordLevelLyrics, value);
  }
}
