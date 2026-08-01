import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsRepository {
  static const String _keyThemeMode = 'settings_theme_mode';
  static const String _keyDefaultQuality = 'settings_default_quality';
  static const String _keyCacheSize = 'settings_cache_size';
  // 边听边存开关
  static const String _keyStreamCacheEnabled = 'settings_stream_cache_enabled';
  // 边听边存容量上限（单位 MB）
  static const String _keyStreamCacheLimitMb = 'settings_stream_cache_limit_mb';
  static const String _keyAutoPlay = 'settings_auto_play';
  static const String _keyShowLyrics = 'settings_show_lyrics';
  static const String _keyAutoReceiveVip = 'settings_auto_receive_vip';
  static const String _keyApiServerUrl = 'settings_api_server_url';
  static const String _keySignedDays = 'settings_signed_days';
  // 自定义下载目录：空字符串表示使用默认目录（应用私有 documents/downloads）
  static const String _keyDownloadDir = 'settings_download_dir';
  // 下载时内嵌字级 LRC 歌词（逐字），关闭则嵌入行级 LRC
  static const String _keyDownloadWordLevelLyrics = 'settings_download_word_level_lyrics';
  static const String _keyUiScale = 'settings_ui_scale';
  // Pad 端网格页面列数偏好
  static const String _keyGridColumns = 'grid_columns';

  /// 读取本地打卡日期集合（格式 yyyy-MM-dd）
  Future<Set<String>> getSignedDays() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_keySignedDays);
    return list != null ? Set<String>.from(list) : {};
  }

  /// 持久化本地打卡日期集合
  Future<void> setSignedDays(Set<String> days) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keySignedDays, days.toList());
  }

  Future<String> getApiServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyApiServerUrl) ?? 'http://115.29.236.96:5621';
  }

  Future<void> setApiServerUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyApiServerUrl, url);
  }

  Future<ThemeMode> getThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_keyThemeMode);
    if (index != null && index >= 0 && index < ThemeMode.values.length) {
      return ThemeMode.values[index];
    }
    return ThemeMode.system;
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyThemeMode, mode.index);
  }

  Future<String> getDefaultQuality() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyDefaultQuality) ?? 'hq';
  }

  Future<void> setDefaultQuality(String quality) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDefaultQuality, quality);
  }

  Future<int> getCacheSize() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyCacheSize) ?? 500;
  }

  Future<void> setCacheSize(int sizeMb) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyCacheSize, sizeMb);
  }

  /// 边听边存功能是否开启，默认开启。
  Future<bool> getStreamCacheEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyStreamCacheEnabled) ?? true;
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

  Future<bool> getAutoPlay() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyAutoPlay) ?? true;
  }

  Future<void> setAutoPlay(bool autoPlay) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAutoPlay, autoPlay);
  }

  Future<bool> getShowLyrics() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyShowLyrics) ?? true;
  }

  Future<void> setShowLyrics(bool showLyrics) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyShowLyrics, showLyrics);
  }

  Future<bool> getAutoReceiveVip() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyAutoReceiveVip) ?? true;
  }

  Future<void> setAutoReceiveVip(bool autoReceive) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAutoReceiveVip, autoReceive);
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

  // ===== 桌面歌词配置 =====

  Future<double> getDesktopLyricFontSize() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble('settings_dl_font_size') ?? 18.0;
  }

  Future<void> setDesktopLyricFontSize(double size) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('settings_dl_font_size', size);
  }

  Future<bool> getDesktopLyricDoubleLine() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('settings_dl_double_line') ?? false;
  }

  Future<void> setDesktopLyricDoubleLine(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('settings_dl_double_line', v);
  }

  Future<int> getDesktopLyricOpacity() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('settings_dl_opacity') ?? 80;
  }

  Future<void> setDesktopLyricOpacity(int v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('settings_dl_opacity', v);
  }

  Future<int> getDesktopLyricGradientStart() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('settings_dl_grad_start') ?? 0xFF00E5FF;
  }

  Future<void> setDesktopLyricGradientStart(int v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('settings_dl_grad_start', v);
  }

  Future<int> getDesktopLyricGradientEnd() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('settings_dl_grad_end') ?? 0xFFFF00FF;
  }

  Future<void> setDesktopLyricGradientEnd(int v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('settings_dl_grad_end', v);
  }

  Future<int> getDesktopLyricUnplayedColor() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('settings_dl_unplayed_color') ?? 0xFF666666;
  }

  Future<void> setDesktopLyricUnplayedColor(int v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('settings_dl_unplayed_color', v);
  }

  Future<bool> getDesktopLyricLocked() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('settings_dl_locked') ?? false;
  }

  Future<void> setDesktopLyricLocked(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('settings_dl_locked', v);
  }

  // ===== Lyricon 配置 =====

  Future<bool> getLyriconEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('lyricon_enabled') ?? false;
  }

  Future<void> setLyriconEnabled(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('lyricon_enabled', v);
  }

  Future<bool> getLyriconDisplayTranslation() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('lyricon_display_translation') ?? true;
  }

  Future<void> setLyriconDisplayTranslation(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('lyricon_display_translation', v);
  }

  Future<bool> getLyriconDisplayRoma() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('lyricon_display_roma') ?? false;
  }

  Future<void> setLyriconDisplayRoma(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('lyricon_display_roma', v);
  }

  /// 同时存在翻译和罗马音时是否优先推送翻译。
  /// 开启后：setSong 时若某行同时携带 translation 和 roma，则丢弃 roma，
  /// 让 Lyricon 设备只显示翻译。关闭后：二者都推送，由 setDisplayTranslation
  /// 和 setDisplayRoma 开关分别控制显示。
  Future<bool> getLyriconPreferTranslation() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('lyricon_prefer_translation') ?? true;
  }

  Future<void> setLyriconPreferTranslation(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('lyricon_prefer_translation', v);
  }

  // ===== 蓝牙歌词配置 =====
  // 通过修改 MediaSession 元数据（title 显示歌词，artist 显示「作者 - 标题」），
  // 在蓝牙 AVRCP 协议下让汽车主机等设备显示当前歌词。
  static const String _keyBluetoothLyricEnabled = 'settings_bluetooth_lyric_enabled';

  Future<bool> getBluetoothLyricEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyBluetoothLyricEnabled) ?? false;
  }

  Future<void> setBluetoothLyricEnabled(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyBluetoothLyricEnabled, v);
  }

  // ===== UI 缩放 =====

  Future<double> getUiScale() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_keyUiScale) ?? 1.0;
  }

  Future<void> setUiScale(double scale) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyUiScale, scale);
  }

  // ===== 忽略音频焦点 =====
  static const String _keyIgnoreAudioFocus = 'settings_ignore_audio_focus';

  /// 是否忽略音频焦点（允许多声音同时播放），默认 false。
  Future<bool> getIgnoreAudioFocus() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyIgnoreAudioFocus) ?? false;
  }

  Future<void> setIgnoreAudioFocus(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyIgnoreAudioFocus, value);
  }

  // ===== 暂停淡入淡出 =====
  static const String _keyPauseFadeEnabled = 'settings_pause_fade_enabled';

  /// 暂停/播放时是否启用音量淡入淡出，默认 false。
  Future<bool> getPauseFadeEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyPauseFadeEnabled) ?? false;
  }

  Future<void> setPauseFadeEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyPauseFadeEnabled, value);
  }

  // ===== 播放时保持屏幕常亮 =====
  static const String _keyKeepScreenOn = 'settings_keep_screen_on';

  /// 播放歌曲/MV 时是否保持屏幕常亮，默认 false。
  Future<bool> getKeepScreenOn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyKeepScreenOn) ?? false;
  }

  Future<void> setKeepScreenOn(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyKeepScreenOn, value);
  }

  // ===== 主页 Tab 配置 =====
  static const String _keyTabOrder = 'settings_tab_order';
  static const String _keyHiddenTabs = 'settings_hidden_tabs';

  /// 读取 tab 排序（存储为 tab id 列表）。
  /// 返回 null 表示使用默认顺序。
  Future<List<String>?> getTabOrder() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_keyTabOrder);
  }

  Future<void> setTabOrder(List<String> order) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyTabOrder, order);
  }

  /// 读取隐藏的 tab id 集合。
  Future<Set<String>> getHiddenTabs() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_keyHiddenTabs);
    return list != null ? Set<String>.from(list) : {};
  }

  Future<void> setHiddenTabs(Set<String> hidden) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyHiddenTabs, hidden.toList());
  }

  // ===== Pad 端网格列数 =====

  /// 读取 Pad 端网格页面列数偏好，默认 4。
  Future<int> getGridColumns() async {
    final prefs = await SharedPreferences.getInstance();
    // Pad 端默认 4 栏
    return prefs.getInt(_keyGridColumns) ?? 4;
  }

  Future<void> setGridColumns(int count) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyGridColumns, count);
  }
}
