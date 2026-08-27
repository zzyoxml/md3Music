import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/services/audio_service_io.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../widgets/apple_lyrics/layout/lyric_preferences.dart';

class SettingsRepository {
  static const String _keyThemeMode = 'settings_theme_mode';
  static const String _keyDefaultQuality = 'settings_default_quality';
  // 按网络区分的音质（WiFi / 移动网络）；未设置时回退到 _keyDefaultQuality
  static const String _keyQualityWifi = 'settings_default_quality_wifi';
  static const String _keyQualityMobile = 'settings_default_quality_mobile';
  static const String _keyCacheSize = 'settings_cache_size';
  static const String _keyAutoPlay = 'settings_auto_play';
  static const String _keyShowLyrics = 'settings_show_lyrics';
  static const String _keyAutoReceiveVip = 'settings_auto_receive_vip';
  static const String _keyUiScale = 'settings_ui_scale';
  // Pad 端网格页面列数偏好
  static const String _keyGridColumns = 'grid_columns';
  // MV 画中画：按 Home 自动进入画中画（默认关闭，手动按钮不受影响）
  static const String _keyAutoPip = 'settings_auto_pip';
  // 逐字歌词时间偏移（ms，默认 0；仅在线音乐生效，正值 = 歌词延后显示）
  static const String _keyLyricTimeOffset = 'lyric_time_offset_ms';

  /// 签到日历键：登录时按账号隔离（`settings_signed_days_$userid`），
  /// 未登录（游客）用全局键。
  String get _signedDaysKey {
    final uid = KugouApiClient().userid;
    return uid == null ? 'settings_signed_days' : 'settings_signed_days_$uid';
  }

  /// 读取本地打卡日期集合（格式 yyyy-MM-dd）
  Future<Set<String>> getSignedDays() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_signedDaysKey);
    return list != null ? Set<String>.from(list) : {};
  }

  /// 持久化本地打卡日期集合
  Future<void> setSignedDays(Set<String> days) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_signedDaysKey, days.toList());
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
    return prefs.getString(_keyDefaultQuality) ?? '128';
  }

  /// WiFi 网络下的默认音质。从未单独设置过时回退到旧的全局默认音质，
  /// 保证老用户升级后两套音质默认值与之前一致。
  Future<String> getWifiQuality() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_keyQualityWifi);
    return v ?? await getDefaultQuality();
  }

  Future<void> setWifiQuality(String quality) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyQualityWifi, quality);
  }

  /// 移动网络下的默认音质。从未单独设置过时回退到旧的全局默认音质。
  Future<String> getMobileQuality() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_keyQualityMobile);
    return v ?? await getDefaultQuality();
  }

  Future<void> setMobileQuality(String quality) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyQualityMobile, quality);
  }

  /// 按网络类型取对应音质。[isWifi] 为 true 用 WiFi 音质，否则用移动网络音质。
  Future<String> getQualityForNetwork(bool isWifi) =>
      isWifi ? getWifiQuality() : getMobileQuality();

  /// 按网络类型写入对应音质（[isWifi] 为 true 写 WiFi 键，否则写移动网络键）。
  Future<void> setQualityForNetwork(bool isWifi, String quality) =>
      isWifi ? setWifiQuality(quality) : setMobileQuality(quality);

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

  /// MV 画中画：按 Home 自动进入画中画是否开启（默认关闭）。
  Future<bool> getAutoPipEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyAutoPip) ?? false;
  }

  Future<void> setAutoPipEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAutoPip, value);
  }

  /// 逐字歌词时间偏移（ms，内存缓存）。播放页每帧高频读取，
  /// 用 ValueNotifier 避免重复异步读 SharedPreferences；设置页修改后即时生效。
  static final ValueNotifier<int> lyricTimeOffsetMs = ValueNotifier<int>(0);

  /// 读取逐字歌词时间偏移（限制 ±10000ms，默认 0）。
  Future<int> getLyricTimeOffset() async {
    final prefs = await SharedPreferences.getInstance();
    final v = (prefs.getInt(_keyLyricTimeOffset) ?? 0).clamp(-10000, 10000);
    lyricTimeOffsetMs.value = v;
    return v;
  }

  /// 保存逐字歌词时间偏移（限制 ±10000ms），并同步内存缓存。
  Future<void> setLyricTimeOffset(int v) async {
    final clamped = v.clamp(-10000, 10000);
    lyricTimeOffsetMs.value = clamped;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyLyricTimeOffset, clamped);
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

  // ===== 实时歌词推送协议 =====
  // 三种协议（Lyricon / SuperLyric / LyricInfo）三选一 + 关闭，翻译/罗马音等偏好共用。

  /// 当前选中的推送协议：'none' / 'lyricon' / 'super_lyric' / 'lyric_info'。
  Future<String> getLyricPushProtocol() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('lyric_push_protocol') ?? 'none';
  }

  Future<void> setLyricPushProtocol(String v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('lyric_push_protocol', v);
  }

  /// 共用：是否推送翻译（默认 true）。
  Future<bool> getLyricPushTranslation() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('lyric_push_translation') ?? true;
  }

  Future<void> setLyricPushTranslation(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('lyric_push_translation', v);
  }

  /// 共用：是否推送罗马音（默认 false）。
  Future<bool> getLyricPushRoma() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('lyric_push_roma') ?? false;
  }

  Future<void> setLyricPushRoma(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('lyric_push_roma', v);
  }

  /// 共用：同时存在翻译和罗马音时是否优先推送翻译（默认 true）。
  Future<bool> getLyricPushPreferTranslation() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('lyric_push_prefer_translation') ?? true;
  }

  Future<void> setLyricPushPreferTranslation(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('lyric_push_prefer_translation', v);
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

  Future<bool> getSuperLyricEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('super_lyric_enabled') ?? false;
  }

  Future<void> setSuperLyricEnabled(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('super_lyric_enabled', v);
  }

  /// SuperLyric：同时存在翻译和罗马音时是否优先推送翻译（默认 true）。
  Future<bool> getSuperLyricPreferTranslation() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('super_lyric_prefer_translation') ?? true;
  }

  Future<void> setSuperLyricPreferTranslation(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('super_lyric_prefer_translation', v);
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

  // 蓝牙歌词封面压缩开关：默认 false（不压缩，保持原始 512px 封面质量）。
  // 开启后原生端 refreshMetadata 使用 256px 缩略图，降低 Binder 负载与 SystemUI 解码压力。
  static const String _keyBluetoothLyricCompressArt = 'settings_bluetooth_lyric_compress_art';

  Future<bool> getBluetoothLyricCompressArt() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyBluetoothLyricCompressArt) ?? false;
  }

  Future<void> setBluetoothLyricCompressArt(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyBluetoothLyricCompressArt, v);
  }

  // ===== LyricInfo 歌词转发 =====
  // 通过 MediaSession 元数据 extras.lyricInfo 发布整首歌词（LRC/ELRC），
  // 供 ColorOS 桌面歌词 / LyricInfo 模块等第三方系统读取。
  static const String _keyLyricInfoEnabled = 'settings_lyric_info_enabled';

  Future<bool> getLyricInfoEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyLyricInfoEnabled) ?? false;
  }

  Future<void> setLyricInfoEnabled(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyLyricInfoEnabled, v);
  }

  // ===== 锁屏歌词 =====
  // 锁屏时全屏显示逐字歌词（覆盖在系统锁屏上方），默认关闭。
  static const String _keyLockScreenLyricEnabled = 'settings_lock_screen_lyric_enabled';

  Future<bool> getLockScreenLyricEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyLockScreenLyricEnabled) ?? false;
  }

  Future<void> setLockScreenLyricEnabled(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyLockScreenLyricEnabled, v);
  }

  // ===== 锁屏歌词字体 =====
  // 字号/粗细独立于 App 内歌词设置；默认跟随 AM 歌词偏好（未单独设置过时一致）。
  static const String _keyLockScreenLyricFontSize = 'settings_lock_screen_lyric_font_size';
  static const String _keyLockScreenLyricFontWeight = 'settings_lock_screen_lyric_font_weight';

  Future<double> getLockScreenLyricFontSize() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_keyLockScreenLyricFontSize) ??
        LyricPreferences.instance.fontSize;
  }

  Future<void> setLockScreenLyricFontSize(double v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyLockScreenLyricFontSize, v);
  }

  Future<int> getLockScreenLyricFontWeight() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyLockScreenLyricFontWeight) ??
        LyricPreferences.instance.fontWeightValue;
  }

  Future<void> setLockScreenLyricFontWeight(int v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyLockScreenLyricFontWeight, v);
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

  // ===== 音乐频谱环绕显示 =====
  static const String _keySpectrumEnabled = 'settings_spectrum_enabled';
  static const String _keySpectrumBandCount = 'settings_spectrum_band_count';
  static const String _keySpectrumStyle = 'settings_spectrum_style';

  /// 全屏播放器是否显示音乐频谱环绕（圆形旋转封面 + 环形频谱柱），默认 false。
  Future<bool> getSpectrumEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keySpectrumEnabled) ?? false;
  }

  Future<void> setSpectrumEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keySpectrumEnabled, value);
  }

  /// 频谱柱数量（20~80，默认 40）。
  Future<int> getSpectrumBandCount() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keySpectrumBandCount) ?? 40;
  }

  Future<void> setSpectrumBandCount(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keySpectrumBandCount, value);
  }

  /// 频谱样式：0=柱状图，1=曲线（默认 0）。
  Future<int> getSpectrumStyle() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keySpectrumStyle) ?? 0;
  }

  Future<void> setSpectrumStyle(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keySpectrumStyle, value);
  }

  // ── 频谱背景层 ──
  static const String _keySpectrumBgOpacity = 'settings_spectrum_bg_opacity';
  static const String _keySpectrumBgHeight = 'settings_spectrum_bg_height';

  /// 频谱背景层透明度（0.1~0.8，默认 0.4）。
  Future<double> getSpectrumBgOpacity() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_keySpectrumBgOpacity) ?? 0.4;
  }

  Future<void> setSpectrumBgOpacity(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keySpectrumBgOpacity, value);
  }

  /// 频谱背景层高度比例（0.2~0.8，默认 0.4，占屏幕高度的比例）。
  Future<double> getSpectrumBgHeight() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_keySpectrumBgHeight) ?? 0.4;
  }

  Future<void> setSpectrumBgHeight(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keySpectrumBgHeight, value);
  }

  // ── 环绕频谱透明度（柱状图 / 曲线，分开记忆） ──
  static const String _keySpectrumBarOpacity = 'settings_spectrum_bar_opacity';
  static const String _keySpectrumCurveOpacity = 'settings_spectrum_curve_opacity';

  /// 频谱动态取色（独立开关，默认关闭）：开启后 AM 播放器频谱颜色取封面主色
  /// 与白色 50/50 混合（与歌词动态取色无关）。
  static const String _keySpectrumDynamicColor = 'settings_spectrum_dynamic_color';

  /// 柱状图频谱透明度（0.1~1.0，默认 1.0 不透明）。
  Future<double> getSpectrumBarOpacity() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_keySpectrumBarOpacity) ?? 1.0;
  }

  Future<void> setSpectrumBarOpacity(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keySpectrumBarOpacity, value);
  }

  /// 曲线频谱透明度（0.1~1.0，默认 1.0 不透明）。
  Future<double> getSpectrumCurveOpacity() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_keySpectrumCurveOpacity) ?? 1.0;
  }

  Future<void> setSpectrumCurveOpacity(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keySpectrumCurveOpacity, value);
  }

  /// 频谱动态取色开关（默认开启）。
  Future<bool> getSpectrumDynamicColor() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keySpectrumDynamicColor) ?? true;
  }

  Future<void> setSpectrumDynamicColor(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keySpectrumDynamicColor, value);
  }

  // ===== MiniPlayer 滑动切歌 =====
  static const String _keyMiniPlayerSwipeSwitch = 'settings_mini_player_swipe_switch';

  /// MiniPlayer 是否支持水平滑动切歌，默认开启。
  Future<bool> getMiniPlayerSwipeSwitchEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyMiniPlayerSwipeSwitch) ?? true;
  }

  Future<void> setMiniPlayerSwipeSwitchEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyMiniPlayerSwipeSwitch, value);
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

  // ===== 桌面快捷方式配置 =====
  static const String _keyDesktopShortcutOrder =
      'settings_desktop_shortcut_order';
  static const String _keyHiddenDesktopShortcuts =
      'settings_hidden_desktop_shortcuts';

  /// 读取桌面快捷方式排序（存储为快捷方式 id 列表）。
  /// 返回 null 表示使用默认顺序。
  Future<List<String>?> getDesktopShortcutOrder() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_keyDesktopShortcutOrder);
  }

  Future<void> setDesktopShortcutOrder(List<String> order) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyDesktopShortcutOrder, order);
  }

  /// 读取关闭（隐藏）的桌面快捷方式 id 集合。
  Future<Set<String>> getHiddenDesktopShortcuts() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_keyHiddenDesktopShortcuts);
    return list != null ? Set<String>.from(list) : {};
  }

  Future<void> setHiddenDesktopShortcuts(Set<String> hidden) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyHiddenDesktopShortcuts, hidden.toList());
  }

  // ===== 收藏歌单排序 =====
  static const String _keySortCollectedByLatestClick =
      'settings_sort_collected_by_latest_click';

  /// 收藏页歌单是否按「最近点击」排序（默认关闭）。
  /// 开启：最近点击的歌单排最前；关闭：按服务端返回顺序排列。
  Future<bool> getSortCollectedByLatestClick() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keySortCollectedByLatestClick) ?? false;
  }

  Future<void> setSortCollectedByLatestClick(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keySortCollectedByLatestClick, value);
  }

  static const String _keyCreatedPlaylistSort =
      'settings_created_playlist_sort';
  static const String _keyCollectedPlaylistSort =
      'settings_collected_playlist_sort';

  /// 收藏页「我创建的歌单」手动排序方向：0=默认顺序，1=升序（A→Z），2=降序（Z→A）。
  Future<int> getCreatedPlaylistSort() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyCreatedPlaylistSort) ?? 0;
  }

  Future<void> setCreatedPlaylistSort(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyCreatedPlaylistSort, value);
  }

  /// 收藏页「我收藏的歌单」手动排序方向：0=默认顺序，1=升序（A→Z），2=降序（Z→A）。
  Future<int> getCollectedPlaylistSort() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyCollectedPlaylistSort) ?? 0;
  }

  Future<void> setCollectedPlaylistSort(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyCollectedPlaylistSort, value);
  }

  static const String _keyCreatedPlaylistOrder =
      'settings_created_playlist_order';
  static const String _keyCollectedPlaylistOrder =
      'settings_collected_playlist_order';

  /// 收藏页「我创建的歌单」手动排序：逗号分隔的歌单 ID 顺序列表。
  Future<List<String>> getCreatedPlaylistOrder() async {
    final prefs = await SharedPreferences.getInstance();
    return _splitPlaylistOrder(prefs.getString(_keyCreatedPlaylistOrder));
  }

  Future<void> setCreatedPlaylistOrder(List<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyCreatedPlaylistOrder, ids.join(','));
  }

  /// 收藏页「我收藏的歌单」手动排序：逗号分隔的歌单 ID 顺序列表。
  Future<List<String>> getCollectedPlaylistOrder() async {
    final prefs = await SharedPreferences.getInstance();
    return _splitPlaylistOrder(prefs.getString(_keyCollectedPlaylistOrder));
  }

  Future<void> setCollectedPlaylistOrder(List<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyCollectedPlaylistOrder, ids.join(','));
  }

  List<String> _splitPlaylistOrder(String? raw) =>
      raw == null || raw.isEmpty ? [] : raw.split(',');

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

  // ===== 音频焦点 =====
  static const String _keyIgnoreAudioFocus = 'settings_ignore_audio_focus';
  static const String _keyAudioFocusInterruptionMode =
      'settings_audio_focus_interruption_mode';

  /// 是否完全忽略音频焦点（不响应来电 / 导航 / 拔耳机等中断），默认关闭。
  Future<bool> getIgnoreAudioFocus() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyIgnoreAudioFocus) ?? false;
  }

  Future<void> setIgnoreAudioFocus(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyIgnoreAudioFocus, value);
  }

  /// 短暂失去音频焦点时的处理策略，默认「暂停后自动恢复」。
  Future<AudioFocusInterruptionMode> getAudioFocusInterruptionMode() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_keyAudioFocusInterruptionMode);
    if (index != null &&
        index >= 0 &&
        index < AudioFocusInterruptionMode.values.length) {
      return AudioFocusInterruptionMode.values[index];
    }
    return AudioFocusInterruptionMode.pauseAndResume;
  }

  Future<void> setAudioFocusInterruptionMode(
      AudioFocusInterruptionMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyAudioFocusInterruptionMode, mode.index);
  }
}
