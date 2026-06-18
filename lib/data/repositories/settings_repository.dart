import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsRepository {
  static const String _keyThemeMode = 'settings_theme_mode';
  static const String _keyDefaultQuality = 'settings_default_quality';
  static const String _keyCacheSize = 'settings_cache_size';
  static const String _keyAutoPlay = 'settings_auto_play';
  static const String _keyShowLyrics = 'settings_show_lyrics';
  static const String _keyAutoReceiveVip = 'settings_auto_receive_vip';
  static const String _keyApiServerUrl = 'settings_api_server_url';

  Future<String> getApiServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyApiServerUrl) ?? 'http://musicplayer.ccwu.cc';
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
}
