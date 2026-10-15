import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/services/audio_service_io.dart';
import '../../core/services/spectrum_service.dart';
import '../../core/services/volume_normalization_service.dart';
import '../../modules/player/car_mode_layout.dart';
import '../../services/kugou_api/kugou_api_client.dart';

class SettingsRepository {
  // Windows 的播放/MV 页面可能被桌面标签页保活，设置变更后通知已挂载页面刷新。
  static final ValueNotifier<int> windowsLiveSettingsRevision = ValueNotifier(0);
  static const String _keyThemeMode = 'settings_theme_mode';
  static const String _keyDefaultQuality = 'settings_default_quality';
  // 按网络区分的音质（WiFi / 移动网络）；未设置时回退到 _keyDefaultQuality
  static const String _keyQualityWifi = 'settings_default_quality_wifi';
  static const String _keyQualityMobile = 'settings_default_quality_mobile';
  static const String _keyCacheSize = 'settings_cache_size';
  // 「启动时自动播放」三件套：总开关 / 播放内容 / 是否连带推起播放页。
  // 默认总开关关（不改启动行为）、播放内容为「继续上次播放」、推页开
  // （一旦用户主动开了总开关，意图就是「进 App 就在听」，直接落在播放页
  //   比停在首页更符合预期）。
  static const String _keyStartupAutoPlay = 'settings_startup_auto_play';
  static const String _keyStartupAutoPlaySource =
      'settings_startup_auto_play_source';
  static const String _keyStartupAutoPlayOpenPage =
      'settings_startup_auto_play_open_page';
  // 早期预留的死键，全仓无任何调用方，勿与上面的启动自动播放混用。
  static const String _keyAutoPlay = 'settings_auto_play';
  static const String _keyShowLyrics = 'settings_show_lyrics';
  static const String _keyAutoReceiveVip = 'settings_auto_receive_vip';
  static const String _keyUiScale = 'settings_ui_scale';
  // Pad 端网格页面列数偏好
  static const String _keyGridColumns = 'grid_columns';
  // MV 画中画：按 Home 自动进入画中画（默认关闭，手动按钮不受影响）
  static const String _keyAutoPip = 'settings_auto_pip';
  static const String _keyMvDanmakuEnabled = 'settings_mv_danmaku_enabled';
  static const String _keyMvDanmakuOpacity = 'settings_mv_danmaku_opacity';
  static const String _keySongDanmakuEnabled = 'settings_song_danmaku_enabled';

  /// 封面流歌单源（CoverFlowSource.rawValue：'daily' / 'personalFm' / 'homeDiscover'）。
  /// 存原始字符串而非 int 下标：枚举顺序是 UI 契约，持久化不跟它走。
  static const String _keyCoverFlowSource = 'settings_coverflow_source';

  /// 读取封面流歌单源原始值；未设置返回 null（调用方按默认源处理）。
  Future<String?> getCoverFlowSourceRaw() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyCoverFlowSource);
  }

  /// 持久化封面流歌单源原始值。
  Future<void> setCoverFlowSourceRaw(String raw) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyCoverFlowSource, raw);
  }

  /// 「听歌数据云同步」总开关。默认开启：总控云端播放历史上传、CSCC 真实
  /// 播放上报与听歌等级累计（三个服务各自直读 prefs，兜底值需与此保持一致）。
  static const String _keyUploadListeningDuration =
      'settings_upload_listening_duration';
  // 逐字歌词时间偏移（ms，默认 0；仅在线音乐生效，正值 = 歌词延后显示）
  static const String _keyLyricTimeOffset = 'lyric_time_offset_ms';

  /// 新版本提醒开关：启动时检查 GitHub Release，发现新版本 toast 提醒。默认开启。
  static const String _keyUpdateReminderEnabled =
      'settings_update_reminder_enabled';

  /// Android 桌面图标是否使用旧版图标（默认关闭，沿用当前图标）。
  static const String _keyLegacyAppIconEnabled =
      'settings_legacy_app_icon_enabled';

  /// 上次网络检查的时间戳（ms）。属于记账状态而非用户设置，故不加 settings_ 前缀。
  static const String _keyUpdateLastCheckMs = 'update_last_check_ms';

  /// 上次已提醒过的版本号（形如 5.6.5），用于同一版本只提醒一次。同上，不加前缀。
  static const String _keyUpdateLastNotifiedVersion =
      'update_last_notified_version';

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

  // —— 桌面化布局（横屏平板）分栏宽度偏好 —— //
  // 侧栏宽度（dp）与双栏详情占比随设备持久化（见横屏平板重设计计划 4.5）。
  static const String _keyDesktopSidebarWidth = 'desktop_sidebar_width';
  static const String _keyDesktopDetailRatio = 'desktop_detail_ratio';

  /// 桌面外壳（侧栏 + 顶部工具栏）总开关。
  /// 默认关闭：无论横竖屏都走常规响应式布局（手机底栏 / 横屏侧边 Rail）；
  /// 开启后无论横竖屏都强制使用桌面外壳（见 [isDesktopLayout]）。
  /// 键公开：`runBootstrap` 首帧前播种要读同一个键，勿再写字面量。
  static const String desktopModeEnabledPreferenceKey =
      'settings_desktop_mode_enabled';

  /// 是否启用桌面外壳。未设置时默认 false（不使用新横屏界面）。
  Future<bool> getDesktopModeEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(desktopModeEnabledPreferenceKey) ?? false;
  }

  Future<void> setDesktopModeEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(desktopModeEnabledPreferenceKey, enabled);
  }

  /// 悬浮迷你播放器（二级页面底部悬浮播放条）总开关。
  /// 默认关闭；开启后在主页与二级页面使用悬浮播放条。
  static const String secondaryPlayerEnabledPreferenceKey =
      'settings_secondary_player_enabled';

  /// 是否启用悬浮迷你播放器。未设置时默认关闭。
  Future<bool> getSecondaryPlayerEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(secondaryPlayerEnabledPreferenceKey) ?? false;
  }

  Future<void> setSecondaryPlayerEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(secondaryPlayerEnabledPreferenceKey, enabled);
  }

  /// 云盘上传「匹配官方曲库」开关（云盘页上传菜单/上传队列面板内切换）。
  /// 默认开启：上传前按文件 MD5 调 KMR 匹配，命中后关联官方歌曲信息
  /// （官方歌名/歌手/歌词/封面）。
  static const String cloudUploadMatchEnabledPreferenceKey =
      'settings_cloud_upload_match';

  /// 是否启用云盘上传前曲库匹配。未设置时默认开启。
  Future<bool> getCloudUploadMatchEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(cloudUploadMatchEnabledPreferenceKey) ?? true;
  }

  Future<void> setCloudUploadMatchEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(cloudUploadMatchEnabledPreferenceKey, enabled);
  }

  /// Android 预测性返回手势（predictive back）总开关。
  /// 默认关闭；开启后使用标准 Android 路由过渡的页面在系统返回手势期间
  /// 实时预览上一页（需 Android 14+ 且手势导航；不满足时行为与关闭一致）。
  static const String predictiveBackEnabledPreferenceKey =
      'settings_predictive_back_enabled';

  /// 是否启用预测性返回手势。未设置时默认关闭。
  Future<bool> getPredictiveBackEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(predictiveBackEnabledPreferenceKey) ?? false;
  }

  Future<void> setPredictiveBackEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(predictiveBackEnabledPreferenceKey, enabled);
  }

  /// 歌单封面连贯过渡总开关（列表卡片封面飞进详情页头）。默认开启。
  static const String playlistCoverTransitionEnabledPreferenceKey =
      'settings_playlist_cover_transition_enabled';

  Future<bool> getPlaylistCoverTransitionEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(playlistCoverTransitionEnabledPreferenceKey) ?? true;
  }

  Future<void> setPlaylistCoverTransitionEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(
      playlistCoverTransitionEnabledPreferenceKey,
      enabled,
    );
  }

  /// 悬浮播放器的进度指示开关。默认开启（未设置时返回 true）。
  static const String secondaryPlayerProgressPreferenceKey =
      'settings_secondary_player_progress';

  Future<bool> getSecondaryPlayerProgress() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(secondaryPlayerProgressPreferenceKey) ?? true;
  }

  Future<void> setSecondaryPlayerProgress(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(secondaryPlayerProgressPreferenceKey, enabled);
  }

  /// 一级页面是否也用悬浮底栏（false = 一级页面退回底部常驻条）。默认开启。
  static const String secondaryPlayerOnPrimaryPreferenceKey =
      'settings_secondary_player_on_primary';

  Future<bool> getSecondaryPlayerOnPrimary() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(secondaryPlayerOnPrimaryPreferenceKey) ?? true;
  }

  Future<void> setSecondaryPlayerOnPrimary(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(secondaryPlayerOnPrimaryPreferenceKey, enabled);
  }

  /// 二级页面（及以后）是否收起底部导航栏。**默认 true（隐藏）**。
  ///
  /// 「二级页面」的认定与悬浮播放条共用一条判据（`page_title_alignment.dart` 的
  /// `isPrimaryNavTab`）：不在导航栏里、或标题居中、或被 push 出栈底，都算二级。
  /// 本开关只作用于**竖屏底部 NavigationBar**；横屏侧边 NavigationRail 在二级页
  /// 始终收起，不受本开关影响。
  static const String hideNavBarOnSecondaryPreferenceKey =
      'settings_hide_navbar_on_secondary';

  Future<bool> getHideNavBarOnSecondaryPages() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(hideNavBarOnSecondaryPreferenceKey) ?? true;
  }

  Future<void> setHideNavBarOnSecondaryPages(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(hideNavBarOnSecondaryPreferenceKey, enabled);
  }

  /// 悬浮播放器折叠态停靠位（'left' | 'center' | 'right'）。
  /// null = 未设置（调用方按设备形态取默认：手机 center / Pad right）。
  static const String _keySecondaryPlayerDock =
      'settings_secondary_player_dock';

  Future<String?> getSecondaryPlayerDockRaw() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keySecondaryPlayerDock);
  }

  Future<void> setSecondaryPlayerDockRaw(String side) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keySecondaryPlayerDock, side);
  }

  /// 桌面侧栏宽度（dp）。未设置时返回 null，由调用方套用默认值。
  Future<double?> getDesktopSidebarWidth() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_keyDesktopSidebarWidth);
  }

  Future<void> setDesktopSidebarWidth(double width) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyDesktopSidebarWidth, width);
  }

  /// 双栏 Master-Detail 中详情面板占比（0~1）。未设置时返回 null。
  Future<double?> getDesktopDetailRatio() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_keyDesktopDetailRatio);
  }

  Future<void> setDesktopDetailRatio(double ratio) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyDesktopDetailRatio, ratio);
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

  /// 「强调排版」开关（M3E Emphasized Typography），默认开启。
  /// 开启时全局 TextTheme 走 M3ETypography.emphasized（提升字重 + 写入 wght/opsz 字轴）；
  /// 关闭后回退到手写的常规 TextTheme。
  static const String _keyEmphasizedTypography = 'emphasized_typography';

  Future<bool> getEmphasizedTypographyEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyEmphasizedTypography) ?? true;
  }

  Future<void> setEmphasizedTypographyEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyEmphasizedTypography, value);
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

  /// 新版本提醒开关（默认开启）。关闭后启动时不再查询 Release。
  Future<bool> getUpdateReminderEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyUpdateReminderEnabled) ?? true;
  }

  Future<void> setUpdateReminderEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyUpdateReminderEnabled, enabled);
  }

  /// 是否还原旧版 Android 桌面图标。未设置时沿用当前图标。
  Future<bool> getLegacyAppIconEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyLegacyAppIconEnabled) ?? false;
  }

  Future<void> setLegacyAppIconEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyLegacyAppIconEnabled, enabled);
  }

  /// 上次成功发起 Release 检查的时间戳（ms）；未检查过返回 0。
  Future<int> getUpdateLastCheckMs() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyUpdateLastCheckMs) ?? 0;
  }

  Future<void> setUpdateLastCheckMs(int milliseconds) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyUpdateLastCheckMs, milliseconds);
  }

  /// 上次已提醒的新版本号（形如 5.6.5）；未提醒过返回空串。
  Future<String> getUpdateLastNotifiedVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyUpdateLastNotifiedVersion) ?? '';
  }

  Future<void> setUpdateLastNotifiedVersion(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyUpdateLastNotifiedVersion, version);
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

  /// MV 弹幕开关。默认关闭 —— 与酷狗官方 App 的 MV 弹幕默认行为一致。
  Future<bool> getMvDanmakuEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyMvDanmakuEnabled) ?? false;
  }

  Future<void> setMvDanmakuEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyMvDanmakuEnabled, value);
    if (Platform.isWindows) windowsLiveSettingsRevision.value++;
  }

  /// MV 弹幕总透明度（PiliPlus `danmakuOpacity` 的对应物）。
  /// 合法区间 [0.1, 1.0]，越界读回/写入一律钳制。
  Future<double> getMvDanmakuOpacity() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_keyMvDanmakuOpacity)?.clamp(0.1, 1.0) ?? 1.0;
  }

  Future<void> setMvDanmakuOpacity(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyMvDanmakuOpacity, value.clamp(0.1, 1.0));
    if (Platform.isWindows) windowsLiveSettingsRevision.value++;
  }

  /// 歌曲弹幕开关。默认关闭 —— 与 MV 弹幕同一口径。
  /// 播放页低频读内存镜像即可，避免每帧异步读 SharedPreferences；
  /// 设置页修改后经镜像即时生效，无需重进播放页（同步时机对齐 lyricTimeOffsetMs：
  /// getter 读盘后回填、setter 写盘前先更新）。
  static final ValueNotifier<bool> songDanmakuEnabled =
      ValueNotifier<bool>(false);

  Future<bool> getSongDanmakuEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getBool(_keySongDanmakuEnabled) ?? false;
    songDanmakuEnabled.value = v;
    return v;
  }

  Future<void> setSongDanmakuEnabled(bool value) async {
    songDanmakuEnabled.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keySongDanmakuEnabled, value);
  }

  /// 「听歌数据云同步」总开关，默认开启。
  ///
  /// 语义（2026-10 由「上传听歌时长」扩展）：同时总控
  /// 1. 云端播放历史上传（PlayHistorySyncService → /playhistory/upload）
  /// 2. CSCC 真实播放事件上报（ListenReportService → /user/listen/report）
  /// 3. 听歌等级/时长差量上报（ListeningGradeService → /user/grade/info）
  /// 键名沿用旧键不改：显式关闭过的用户升级后保持关闭，未写过的默认开启。
  Future<bool> getUploadListeningDuration() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyUploadListeningDuration) ?? true;
  }

  Future<void> setUploadListeningDuration(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyUploadListeningDuration, value);
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
    return prefs.getInt('settings_dl_opacity') ?? 50;
  }

  Future<void> setDesktopLyricOpacity(int v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('settings_dl_opacity', v);
  }

  Future<int> getDesktopLyricGradientStart() async {
    final prefs = await SharedPreferences.getInstance();
    // toUnsigned(32)：修复前原生回灌的负数 Kotlin Int 可能还留在盘里
    return (prefs.getInt('settings_dl_grad_start') ?? 0xFF00E5FF).toUnsigned(32);
  }

  Future<void> setDesktopLyricGradientStart(int v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('settings_dl_grad_start', v);
  }

  Future<int> getDesktopLyricGradientEnd() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getInt('settings_dl_grad_end') ?? 0xFFFF00FF).toUnsigned(32);
  }

  Future<void> setDesktopLyricGradientEnd(int v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('settings_dl_grad_end', v);
  }

  Future<int> getDesktopLyricUnplayedColor() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getInt('settings_dl_unplayed_color') ?? 0xFFFFFFFF)
        .toUnsigned(32);
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

  /// 配色模式：0 = 预设配色，1 = 自调颜色。
  ///
  /// 「当前是不是自调颜色」必须独立持久化，**不能**靠"有没有预设被选中"推断：
  /// 自调把渐变两端并成任意色后必然与四个预设全部失配，切回预设配色时
  /// 就无从决定该恢复哪一组，只能退化成"一个都不选中"。
  Future<int> getDesktopLyricColorMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('settings_dl_color_mode') ?? 0;
  }

  Future<void> setDesktopLyricColorMode(int v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('settings_dl_color_mode', v);
  }

  /// 最近一次选中的预设下标（0..3）。进入自调颜色后**不清零**，
  /// 切回预设配色时据此还原，见 DesktopLyricService.setColorMode。
  Future<int> getDesktopLyricPresetIndex() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('settings_dl_preset_index') ?? 0;
  }

  Future<void> setDesktopLyricPresetIndex(int v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('settings_dl_preset_index', v);
  }

  // ===== 自定义配色槽位 =====
  //
  // 「自调颜色」写的是这一份，**不是**渐变本身 —— 预设色是常量不能被改，
  // 拖色相只动这里；第 5 个「自定义」色块读的就是它，所以能实时跟着自调变。
  Future<int> getDesktopLyricCustomGradStart() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getInt('settings_dl_custom_grad_start') ?? 0xFF00E5FF)
        .toUnsigned(32);
  }

  Future<void> setDesktopLyricCustomGradStart(int v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('settings_dl_custom_grad_start', v);
  }

  Future<int> getDesktopLyricCustomGradEnd() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getInt('settings_dl_custom_grad_end') ?? 0xFFFF00FF)
        .toUnsigned(32);
  }

  Future<void> setDesktopLyricCustomGradEnd(int v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('settings_dl_custom_grad_end', v);
  }

  Future<int> getDesktopLyricCustomUnplayed() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getInt('settings_dl_custom_unplayed') ?? 0xFFFFFFFF)
        .toUnsigned(32);
  }

  Future<void> setDesktopLyricCustomUnplayed(int v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('settings_dl_custom_unplayed', v);
  }

  // ===== 实时歌词推送协议 =====
  // 三种协议（Lyricon / SuperLyric / LyricInfo）三选一 + 关闭，翻译/罗马音等偏好共用。

  /// 当前选中的推送协议：'none' / 'lyricon' / 'super_lyric' / 'lyric_info'。
  Future<String> getLyricPushProtocol() async {
    final prefs = await SharedPreferences.getInstance();
    // MD3Music fork: 默认 lyric_info（Vivo 车载歌词依赖此链路推送整首歌词；
    // 原默认 none 导致 lyricInfo 不推，原子随身听缺 8/16 能力位、车机无歌词）。
    return prefs.getString('lyric_push_protocol') ?? 'lyric_info';
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

  // ===== 遥控器模式（TV 构建）=====
  // 'auto'（默认：TV 设备开）/ 'always_on' / 'always_off'。

  Future<String> getRemoteControlMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('settings_remote_control_mode') ?? 'auto';
  }

  Future<void> setRemoteControlMode(String v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('settings_remote_control_mode', v);
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

  // ===== 魅族 Flyme 状态栏歌词 =====
  // 键名必须与原生 FlymeLyricBridge.PREF_KEY（加 flutter. 前缀后）一致，
  // 因为进程被 MediaSession 唤醒时原生要先于 Dart 恢复开关状态。
  static const String _keyFlymeStatusBarLyricEnabled =
      'settings_flyme_status_bar_lyric_enabled';

  Future<bool> getFlymeStatusBarLyricEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyFlymeStatusBarLyricEnabled) ?? false;
  }

  Future<void> setFlymeStatusBarLyricEnabled(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyFlymeStatusBarLyricEnabled, v);
  }

  /// 状态栏歌词提前量（ms）。默认值与上限只在这里定义，其它地方读取。
  /// 120ms 的来由：notify() → SystemUI 取通知并重绘约 100ms 量级，
  /// 加上 LRC 时间戳普遍标在"字已出声"之后，抵消后大致同步。
  static const int kFlymeLyricAdvanceDefaultMs = 120;
  static const int kFlymeLyricAdvanceMaxMs = 600;
  // 与 DesktopLyricService.setFlymeAdvanceMs 的钳位保持一致，两处都要改才同步
  static const String _keyFlymeLyricAdvanceMs =
      'settings_flyme_lyric_advance_ms';

  // 注意：这个值不需要原生侧对应键 —— 提前量参与的是 Dart 侧"选哪一行"，
  // 原生只会收到已经选好的一行文本。与开关不同（开关必须原生也能恢复）。
  Future<int> getFlymeLyricAdvanceMs() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getInt(_keyFlymeLyricAdvanceMs) ??
            kFlymeLyricAdvanceDefaultMs)
        .clamp(0, kFlymeLyricAdvanceMaxMs);
  }

  Future<void> setFlymeLyricAdvanceMs(int v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _keyFlymeLyricAdvanceMs,
      v.clamp(0, kFlymeLyricAdvanceMaxMs),
    );
  }

  // ===== 蓝牙歌词配置 =====
  // 通过修改 MediaSession 元数据（title 显示歌词，artist 显示「作者 - 标题」），
  // 在蓝牙 AVRCP 协议下让汽车主机等设备显示当前歌词。
  static const String _keyBluetoothLyricEnabled =
      'settings_bluetooth_lyric_enabled';

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
  static const String _keyBluetoothLyricCompressArt =
      'settings_bluetooth_lyric_compress_art';

  Future<bool> getBluetoothLyricCompressArt() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyBluetoothLyricCompressArt) ?? false;
  }

  Future<void> setBluetoothLyricCompressArt(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyBluetoothLyricCompressArt, v);
  }

  // 3D 封面（深度视差）总开关：默认 false（不启用，首次开启会触发模型下载）。
  static const String _keyDepthCoverEnabled = 'settings_depth_cover_enabled';

  Future<bool> getDepthCoverEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyDepthCoverEnabled) ?? false;
  }

  Future<void> setDepthCoverEnabled(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyDepthCoverEnabled, v);
  }

  // 3D 封面视差强度：背景层最大平移像素，默认 9（越大越"浮"，0 = 完全不动）。
  static const String _keyDepthCoverStrength = 'settings_depth_cover_strength';

  Future<double> getDepthCoverStrength() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_keyDepthCoverStrength) ?? 9.0;
  }

  Future<void> setDepthCoverStrength(double v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyDepthCoverStrength, v);
  }

  // 封面阴影强度：全屏播放器封面投影的浓度/位移缩放系数，合法区间 [0, 1]，
  // 0 = 关闭投影，1 = 最强；默认 0.7（必须与 PlayerCoverShadow.defaultIntensity
  // 保持一致，否则首帧投影强度与设置页显示的缺省值对不上）。
  static const String _keyCoverShadowStrength =
      'settings_cover_shadow_strength';

  Future<double> getCoverShadowStrength() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_keyCoverShadowStrength)?.clamp(0.0, 1.0) ?? 0.7;
  }

  Future<void> setCoverShadowStrength(double v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyCoverShadowStrength, v.clamp(0.0, 1.0));
  }

  // 3D 封面 AI 背景修补（MI-GAN 神经细化）：默认 true（开启）。
  // 关闭后跳过神经细化，封面背景修补仅用 push-pull 金字塔（更快、省内存）。
  static const String _keyDepthCoverNeuralInpaint =
      'settings_depth_cover_neural_inpaint';

  Future<bool> getDepthCoverNeuralInpaint() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyDepthCoverNeuralInpaint) ?? true;
  }

  Future<void> setDepthCoverNeuralInpaint(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyDepthCoverNeuralInpaint, v);
  }

  // ===== LyricInfo 歌词转发 =====
  // 通过 MediaSession 元数据 extras.lyricInfo 发布整首歌词（LRC/ELRC），
  // 供 ColorOS 桌面歌词 / LyricInfo 模块等第三方系统读取。
  static const String _keyLyricInfoEnabled = 'settings_lyric_info_enabled';

  Future<bool> getLyricInfoEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyLyricInfoEnabled) ?? false;
  }

  static const String _keyLyricInfoColorOs = 'settings_lyric_info_coloros';

  /// ColorOS Bridge 兼容模式：lyricInfo JSON 输出 lyric=纯 LRC + rawLyric=ELRC，
  /// 适配 ColorOS-Live-Lyrics-Bridge 插件（逐字高亮等增强）。默认开启。
  Future<bool> getLyricInfoColorOs() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyLyricInfoColorOs) ?? true;
  }

  Future<void> setLyricInfoColorOs(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyLyricInfoColorOs, v);
  }

  Future<void> setLyricInfoEnabled(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyLyricInfoEnabled, v);
  }

  // ===== 锁屏歌词 =====
  // 锁屏时全屏显示逐字歌词（覆盖在系统锁屏上方），默认关闭。
  static const String _keyLockScreenLyricEnabled =
      'settings_lock_screen_lyric_enabled';

  Future<bool> getLockScreenLyricEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyLockScreenLyricEnabled) ?? false;
  }

  Future<void> setLockScreenLyricEnabled(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyLockScreenLyricEnabled, v);
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

  // ===== 系统音效 =====
  static const String _keyDisableSystemAudioEffects =
      'settings_disable_system_audio_effects';

  /// 是否禁用本应用挂载的 Android 系统音效链，默认关闭。
  Future<bool> getDisableSystemAudioEffects() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyDisableSystemAudioEffects) ?? false;
  }

  Future<void> setDisableSystemAudioEffects(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyDisableSystemAudioEffects, value);
  }

  // ===== 蝰蛇母带 =====
  static const String _keyViperMasterEnabled = 'settings_viper_master_enabled';
  static const String _keyViperTapeQualityEnabled =
      'settings_viper_tape_quality_enabled';

  /// 蝰蛇母带处理（10 段 EQ + 限幅母带链），默认关闭。
  Future<bool> getViperMasterEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyViperMasterEnabled) ?? false;
  }

  Future<void> setViperMasterEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyViperMasterEnabled, value);
  }

  /// 蝰蛇母带音源档位（实验功能，出现「蝰蛇母带」音质档），默认关闭。
  Future<bool> getViperTapeQualityEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyViperTapeQualityEnabled) ?? false;
  }

  Future<void> setViperTapeQualityEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyViperTapeQualityEnabled, value);
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

  // ===== 交叉淡化（crossfade）=====
  static const String _keyCrossfadeEnabled = 'settings_crossfade_enabled';
  static const String _keyCrossfadeSeconds = 'settings_crossfade_seconds';

  /// 交叉淡化时长的允许范围（秒）。
  static const int kCrossfadeMinSeconds = 2;
  static const int kCrossfadeMaxSeconds = 12;
  static const int kCrossfadeDefaultSeconds = 4;

  /// 自动切歌时是否把本首的渐出与下一首的渐入叠加，默认 false。
  Future<bool> getCrossfadeEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyCrossfadeEnabled) ?? false;
  }

  Future<void> setCrossfadeEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyCrossfadeEnabled, value);
  }

  /// 交叉淡化时长（秒），默认 [kCrossfadeDefaultSeconds]。
  Future<int> getCrossfadeSeconds() async {
    final prefs = await SharedPreferences.getInstance();
    final value =
        prefs.getInt(_keyCrossfadeSeconds) ?? kCrossfadeDefaultSeconds;
    return value.clamp(kCrossfadeMinSeconds, kCrossfadeMaxSeconds);
  }

  Future<void> setCrossfadeSeconds(int seconds) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _keyCrossfadeSeconds,
      seconds.clamp(kCrossfadeMinSeconds, kCrossfadeMaxSeconds),
    );
  }

  // ===== 自动混音（AutoMix）=====
  static const String _keyAutomixEnabled = 'settings_automix_enabled';

  /// 自动混音开关。仅在交叉淡化开启时有意义：关闭时按固定时长淡化，
  /// 开启时按节拍/节奏密度自适应（分析不可用自动回退）。
  Future<bool> getAutomixEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyAutomixEnabled) ?? false;
  }

  Future<void> setAutomixEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAutomixEnabled, value);
  }

  // ===== 音量均衡（响度归一） =====
  static const String _keyVolumeNormalizationEnabled =
      'settings_volume_normalization_enabled';
  static const String _keyVolumeNormalizationLufs =
      'settings_volume_normalization_lufs';

  /// 音量均衡开关，默认 false。
  Future<bool> getVolumeNormalizationEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyVolumeNormalizationEnabled) ?? false;
  }

  Future<void> setVolumeNormalizationEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyVolumeNormalizationEnabled, value);
  }

  /// 参考响度（LUFS），默认 -14，钳到 -20~-8。
  Future<double> getVolumeNormalizationReferenceLufs() async {
    final prefs = await SharedPreferences.getInstance();
    final value =
        prefs.getDouble(_keyVolumeNormalizationLufs) ??
        VolumeNormalizationService.defaultReferenceLufs;
    return value.clamp(-20.0, -8.0);
  }

  Future<void> setVolumeNormalizationReferenceLufs(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(
      _keyVolumeNormalizationLufs,
      value.clamp(-20.0, -8.0),
    );
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

  /// 播放页进度条「波浪起伏」总开关（回退开关）。
  /// 默认开启（= 2026-10-01 新增的 MD3 波浪样式）；关闭后进度条退回直线形态。
  static const String seekBarWaveEnabledPreferenceKey =
      'settings_seek_bar_wave_enabled';

  /// 进度条是否画波浪。未设置时默认开启（保留新增样式）。
  Future<bool> getSeekBarWaveEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(seekBarWaveEnabledPreferenceKey) ?? true;
  }

  Future<void> setSeekBarWaveEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(seekBarWaveEnabledPreferenceKey, value);
  }

  /// 宽屏（横屏/平板）播放详情页「横屏控制面板独立页」开关。
  /// 默认关闭（宽屏常驻底部控制带，进度/传输/音量与歌词同屏）；
  /// 开启后把控制面板搬进独立「控制」页签，歌词/歌单/评论获得整栏高度。
  static const String landscapeDetachedControlsPreferenceKey =
      'settings_landscape_detached_controls';

  /// 宽屏布局是否拆出独立控制页签。未设置时默认关闭（常驻控制带）。
  Future<bool> getLandscapeDetachedControls() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(landscapeDetachedControlsPreferenceKey) ?? false;
  }

  Future<void> setLandscapeDetachedControls(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(landscapeDetachedControlsPreferenceKey, value);
  }

  /// 顶栏「胶囊按钮收缩」开关（竖屏把睡眠定时 / 一起听与 ⋯ 合成一颗只露图标的胶囊）。
  /// 默认开启；关闭后这两格文案常显、点一下就直接执行，但仍是同一颗连体胶囊（背景不分颗）。
  /// 音质格不受本开关影响 —— 它只看旁边有没有别的格（`collapseOnlyWithPeers`）。
  static const String topBarPillCollapsePreferenceKey =
      'settings_top_bar_pill_collapse';

  /// 竖屏顶栏尾部是否收缩成图标胶囊。未设置时默认开启。
  Future<bool> getTopBarPillCollapse() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(topBarPillCollapsePreferenceKey) ?? true;
  }

  Future<void> setTopBarPillCollapse(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(topBarPillCollapsePreferenceKey, value);
  }

  /// 播放页页签条是否放到**顶栏中央**（设置 → 播放页样式 → 顶栏与页签）。
  ///
  /// 默认关闭：竖屏页签条留在底部、横屏留在右栏底部，且都是改造前的 icon + 指示线
  /// 形态。开启后竖屏底部那条取消、改为顶栏中央的一排圆点，横屏右栏底部同时改圆点
  /// （位置不变）。
  static const String topBarTabDotsPreferenceKey = 'settings_top_bar_tab_dots';

  /// 竖屏页签条是否以圆点形式上顶栏。未设置时默认关闭（底部 icon 形态）。
  Future<bool> getTopBarTabDots() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(topBarTabDotsPreferenceKey) ?? false;
  }

  Future<void> setTopBarTabDots(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(topBarTabDotsPreferenceKey, value);
  }

  // ===== 音乐频谱环绕显示 =====
  static const String _keySpectrumEnabled = 'settings_spectrum_enabled';
  static const String _keySpectrumBandCount = 'settings_spectrum_band_count';
  static const String _keySpectrumStyle = 'settings_spectrum_style';
  static const String _keySpectrumVisualizerFallback =
      'settings_spectrum_visualizer_fallback';

  /// 全屏播放器是否显示音乐频谱环绕（圆形旋转封面 + 环形频谱柱），默认 false。
  ///
  /// 读写都同步维护 [kSpectrumEnabled] 镜像：播放页的封面连贯资格在 build 期
  /// 求值，不能等这份异步结果（详见 spectrum_service.dart 里该镜像的说明）。
  Future<bool> getSpectrumEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    kSpectrumEnabled = prefs.getBool(_keySpectrumEnabled) ?? false;
    return kSpectrumEnabled;
  }

  Future<void> setSpectrumEnabled(bool value) async {
    // 镜像**先写**：调用方（播放页开关）同帧就 setState 了本地状态，
    // 镜像晚一步会让「形状判据」与「本地状态」短暂不同源。
    kSpectrumEnabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keySpectrumEnabled, value);
  }

  /// 是否允许用 android.media.audiofx.Visualizer 作为频谱兜底数据源。
  ///
  /// 默认 **false**。挂载 Visualizer 会让 AudioFlinger 在该输出流上插入
  /// record-type 采集端点，把这条正在播放的轨道从 low-latency fast track
  /// 降级为普通通道，此后轻微抖动就会欠载（表现为「进出播放页一声爆音」）。
  /// 它还需要 RECORD_AUDIO 权限。PCM 截取路径不需要权限，是首选数据源。
  Future<bool> getSpectrumVisualizerFallback() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keySpectrumVisualizerFallback) ?? false;
  }

  Future<void> setSpectrumVisualizerFallback(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keySpectrumVisualizerFallback, value);
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

  /// 频谱样式：0=柱状图，1=曲线（默认 0），2=背景层。同步维护 [kSpectrumStyle] 镜像。
  Future<int> getSpectrumStyle() async {
    final prefs = await SharedPreferences.getInstance();
    kSpectrumStyle = prefs.getInt(_keySpectrumStyle) ?? 0;
    return kSpectrumStyle;
  }

  Future<void> setSpectrumStyle(int value) async {
    // 同 setSpectrumEnabled：镜像先写，与调用方同帧生效。
    kSpectrumStyle = value;
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
  static const String _keySpectrumCurveOpacity =
      'settings_spectrum_curve_opacity';

  /// 频谱动态取色（独立开关，默认关闭）：开启后 AM 播放器频谱颜色取封面主色
  /// 与白色 50/50 混合（与歌词动态取色无关）。
  static const String _keySpectrumDynamicColor =
      'settings_spectrum_dynamic_color';

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

  // ── 音乐节奏震动 ──
  // 键名与 MusicHapticsService 内的常量必须逐字一致：两侧各持一份真相时，
  // 症状是"设置页打开了但重启后又是关的"。

  static const String _keyMusicHapticsEnabled = 'settings_music_haptics_enabled';
  static const String _keyMusicHapticsStrength = 'settings_music_haptics_strength';
  static const String _keyMusicHapticsSensitivity =
      'settings_music_haptics_sensitivity';
  static const String _keyMusicHapticsWaveform = 'settings_music_haptics_waveform';
  static const String _keyMusicHapticsSnare = 'settings_music_haptics_snare';
  static const String _keyMusicHapticsOffset =
      'settings_music_haptics_offset';
  static const String _keyMusicHapticsScope =
      'settings_music_haptics_scope';

  /// 音乐节奏震动总开关，默认**关闭**：这是个会持续驱动马达的功能，
  /// 默认开会在用户不知情的情况下耗电发热。
  Future<bool> getMusicHapticsEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyMusicHapticsEnabled) ?? false;
  }

  Future<void> setMusicHapticsEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyMusicHapticsEnabled, value);
  }

  /// 震动强度 0.2~1.0，默认 0.8。
  Future<double> getMusicHapticsStrength() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getDouble(_keyMusicHapticsStrength) ?? 0.8).clamp(0.2, 1.0);
  }

  Future<void> setMusicHapticsStrength(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyMusicHapticsStrength, value.clamp(0.2, 1.0));
  }

  /// 检测灵敏度 0.3~3.0，默认 1.0。越大越容易触发。
  Future<double> getMusicHapticsSensitivity() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getDouble(_keyMusicHapticsSensitivity) ?? 1.0).clamp(0.3, 3.0);
  }

  Future<void> setMusicHapticsSensitivity(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyMusicHapticsSensitivity, value.clamp(0.3, 3.0));
  }

  /// 触感波形：'auto' | 'pulse' | 'smooth'，默认 'auto'。
  Future<String> getMusicHapticsWaveform() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyMusicHapticsWaveform) ?? 'auto';
  }

  Future<void> setMusicHapticsWaveform(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyMusicHapticsWaveform, value);
  }

  /// 是否让高频（军鼓/踩镲）也触发震动，默认开。
  Future<bool> getMusicHapticsSnare() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyMusicHapticsSnare) ?? true;
  }

  Future<void> setMusicHapticsSnare(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyMusicHapticsSnare, value);
  }

  /// 节奏偏移（点火延迟补偿），0~600 毫秒。
  ///
  /// 默认 580 = `MusicHapticsService.defaultOffsetMs`（真机实测校准值）。这里
  /// 刻意写字面量而非 import 服务层：数据层不该为了一个默认值依赖 core/services。
  ///
  /// 与 MusicHapticsService 的 `setOffset` 写同一个键：设置页拖动滑块时两边
  /// 都要写，否则重启后回退。
  Future<int> getMusicHapticsOffset() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getInt(_keyMusicHapticsOffset) ?? 580).clamp(0, 600);
  }

  Future<void> setMusicHapticsOffset(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyMusicHapticsOffset, value.clamp(0, 600));
  }

  /// 震动生效范围：'playerPage' | 'inApp' | 'always'，默认 'playerPage'。
  /// 与 MusicHapticsScope.persistKey 对应（键名与 MusicHapticsService 的
  /// `_keyScope` 逐字一致，见本区块头部注释）。
  Future<String> getMusicHapticsScope() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyMusicHapticsScope) ?? 'playerPage';
  }

  Future<void> setMusicHapticsScope(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyMusicHapticsScope, value);
  }

  // ===== MiniPlayer 滑动切歌 =====
  static const String _keyMiniPlayerSwipeSwitch =
      'settings_mini_player_swipe_switch';

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
  static const String _keyTabConfigMigrationVersion =
      'settings_tab_config_migration_version';

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

  /// 读取主页 Tab 配置迁移版本。
  Future<int> getTabConfigMigrationVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyTabConfigMigrationVersion) ?? 0;
  }

  Future<void> setTabConfigMigrationVersion(int version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyTabConfigMigrationVersion, version);
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
  static const String _keyZenCoverLongPress = 'settings_zen_cover_long_press';
  static const String _keyLandscapeImmersive = 'settings_landscape_immersive';
  static const String _keyShowQualityDowngradeToast =
      'settings_show_quality_downgrade_toast';

  /// 是否完全忽略音频焦点（不响应来电 / 导航 / 拔耳机等中断），默认关闭。
  Future<bool> getIgnoreAudioFocus() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyIgnoreAudioFocus) ?? false;
  }

  Future<void> setIgnoreAudioFocus(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyIgnoreAudioFocus, value);
  }

  /// 短暂失去音频焦点时的处理策略，默认「保持播放」。
  Future<AudioFocusInterruptionMode> getAudioFocusInterruptionMode() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_keyAudioFocusInterruptionMode);
    if (index != null &&
        index >= 0 &&
        index < AudioFocusInterruptionMode.values.length) {
      return AudioFocusInterruptionMode.values[index];
    }
    return AudioFocusInterruptionMode.keepPlaying;
  }

  Future<void> setAudioFocusInterruptionMode(
    AudioFocusInterruptionMode mode,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyAudioFocusInterruptionMode, mode.index);
  }

  // ===== 播放提示与交互开关 =====

  /// 长按封面进入/退出 Zen 模式开关，默认开启。
  Future<bool> getZenCoverLongPress() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyZenCoverLongPress) ?? true;
  }

  Future<void> setZenCoverLongPress(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyZenCoverLongPress, value);
    if (Platform.isWindows) windowsLiveSettingsRevision.value++;
  }

  /// 全屏播放器横屏自动沉浸（隐藏状态栏/导航栏）开关，默认开启。
  Future<bool> getLandscapeImmersiveEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyLandscapeImmersive) ?? true;
  }

  Future<void> setLandscapeImmersiveEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyLandscapeImmersive, value);
  }

  /// 音质降级提示开关，默认关闭。播放音质不可用自动降级时弹出提示。
  Future<bool> getShowQualityDowngradeToast() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyShowQualityDowngradeToast) ?? false;
  }

  Future<void> setShowQualityDowngradeToast(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyShowQualityDowngradeToast, value);
  }

  // ===== 记忆播放状态 =====
  static const String _keyRestoreMemory = 'settings_restore_memory';

  /// 「记忆播放状态」开关，默认开启。
  /// 开启时冷启动恢复上次播放的歌曲与进度；关闭后不恢复、
  /// 不再写入持久化播放状态，并清除已保存的数据（见 PlayerProvider）。
  Future<bool> getRestoreMemoryEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyRestoreMemory) ?? true;
  }

  Future<void> setRestoreMemoryEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyRestoreMemory, value);
  }

  // ===== 启动时自动播放 =====
  /// 「启动时自动播放」总开关，默认关闭。关闭时启动流程完全不参与播放
  /// （不读音源、不发任何请求）。取值口径见 [getStartupAutoPlaySource]。
  Future<bool> getStartupAutoPlayEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyStartupAutoPlay) ?? false;
  }

  Future<void> setStartupAutoPlayEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyStartupAutoPlay, value);
  }

  /// 启动时播放的内容，取 StartupAutoPlaySource.value
  /// （'resume' / 'daily' / 'fmHeart' / 'fmExplore' / 'fmNiche' / 'fmRadio'）。
  /// 从未设置过时回退到「继续上次播放」——唯一不依赖登录、也不依赖网络的
  /// 音源，作为默认值不会给新用户带来「突然发一堆网络请求」的意外。
  /// 解析与越界回落由 StartupAutoPlaySource.fromValue 负责，
  /// 旧版本遗留的非法值不会让启动流程崩掉。
  Future<String> getStartupAutoPlaySource() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyStartupAutoPlaySource) ?? 'resume';
  }

  Future<void> setStartupAutoPlaySource(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyStartupAutoPlaySource, value);
  }

  /// 起播后是否自动推起完整播放页，默认开启。仅在总开关打开时才有意义。
  Future<bool> getStartupAutoPlayOpenPage() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyStartupAutoPlayOpenPage) ?? true;
  }

  Future<void> setStartupAutoPlayOpenPage(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyStartupAutoPlayOpenPage, value);
  }

  // ===== 本地音乐评论区 =====
  static const String _keyCloseLocalMusicComments =
      'settings_close_local_music_comments';

  /// 「关闭本地音乐评论区」开关，默认开启。
  /// 开启时本地歌曲不显示播放器评论 tab，也不提供「看评论」入口；在线歌曲不受影响。
  Future<bool> getCloseLocalMusicComments() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyCloseLocalMusicComments) ?? true;
  }

  Future<void> setCloseLocalMusicComments(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyCloseLocalMusicComments, value);
  }

  // ===== 本地音乐在线信息匹配 =====
  static const String _keyAutoMatchOnlineInfo = 'settings_auto_match_online';

  /// 「自动匹配在线信息」开关，默认开启。
  /// 开启时扫描/启动后自动为本地歌曲搜索匹配在线歌曲（高置信度才确认），
  /// 补充封面兜底、歌词精确检索与评论区；关闭后仍可手动逐首匹配。
  Future<bool> getAutoMatchOnlineInfo() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyAutoMatchOnlineInfo) ?? true;
  }

  Future<void> setAutoMatchOnlineInfo(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAutoMatchOnlineInfo, value);
  }

  // ===== 专辑动态封面 =====
  static const String _keyDynamicAlbumCover = 'settings_dynamic_album_cover';
  static const String _keyDynamicAlbumCoverOnMobile =
      'settings_dynamic_album_cover_on_mobile';

  /// 全屏播放器专辑动态封面开关，默认开启。
  Future<bool> getDynamicAlbumCover() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyDynamicAlbumCover) ?? true;
  }

  Future<void> setDynamicAlbumCover(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyDynamicAlbumCover, value);
    if (Platform.isWindows) windowsLiveSettingsRevision.value++;
  }

  /// 移动网络下是否也加载动态封面，默认关闭（单首视频约 9.5MB；
  /// 公开构建每次播放都会重新拉流，流量开销更明显）。
  Future<bool> getDynamicAlbumCoverOnMobile() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyDynamicAlbumCoverOnMobile) ?? false;
  }

  Future<void> setDynamicAlbumCoverOnMobile(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyDynamicAlbumCoverOnMobile, value);
  }

  // ===== 车机模式 =====
  static const String _keyCarModeEnabled = 'settings_car_mode_enabled';
  static const String _keyCarModeAutoScreen = 'settings_car_mode_auto_screen';
  static const String _keyCarModePanelRatio = 'settings_car_mode_panel_ratio';
  static const String _keyCarModeDockClearance =
      'settings_car_mode_dock_clearance';
  static const String _keyCarModePanelSide = 'settings_car_mode_panel_side';

  /// 「车机模式」开关，默认关闭。
  /// 开启后任何界面（设置页 / 登录页 / 引导页 / 用户协议页除外）常驻一块
  /// 全屏播放器面板，且全站不再显示 MiniPlayer。
  /// 这是**强制开启**开关：无论屏幕是什么类型都启用。它与自动检测开关
  /// （[_keyCarModeAutoScreen]）相互独立，任一命中即启用车机模式。
  Future<bool> getCarModeEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyCarModeEnabled) ?? false;
  }

  Future<void> setCarModeEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyCarModeEnabled, value);
  }

  /// 「检测到车机屏幕时自动开启」开关，默认关闭。
  /// 独立于「车机模式」总开关：开启后按屏幕长比自动判断（见
  /// [isCarLikeScreen]），命中车机屏即自动启用常驻面板。
  Future<bool> getCarModeAutoScreenEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyCarModeAutoScreen) ?? false;
  }

  Future<void> setCarModeAutoScreenEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyCarModeAutoScreen, value);
  }

  /// 常驻播放器面板的宽度占比，默认 0.30。
  ///
  /// 合法区间取**最宽**范围（底部布局 10% ~ 50%，见
  /// [kCarModePanelMinRatioBottom]）：本层只挡手改 prefs / 历史脏数据这类
  /// 明显越界值；布局相关的精确下限（侧边 20% / 底部 10%）由
  /// [CarModeProvider.setPanelRatio] 按当前布局夹取 —— 本层不知道布局形态，
  /// 若在这里按 20% 夹会把底部布局存的 10%~20% 值在读回时错误抬高。
  Future<double> getCarModePanelRatio() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getDouble(_keyCarModePanelRatio);
    if (value == null) return kCarModePanelDefaultRatio;
    return value.clamp(kCarModePanelMinRatioBottom, kCarModePanelMaxRatio);
  }

  Future<void> setCarModePanelRatio(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(
      _keyCarModePanelRatio,
      value.clamp(kCarModePanelMinRatioBottom, kCarModePanelMaxRatio),
    );
  }

  /// 底部面板的 dock 避让高度（dp，逻辑像素）。
  ///
  /// 车联 dock 栏以系统悬浮窗绘在 App 之上、不产生 WindowInsets，用户在
  /// 设置页按 dock 实际高度校准并持久化；默认 [kCarModeBottomDockClearance]
  /// （48dp）。范围 0–160：0 = 不避让（贴屏幕底边），160 覆盖常见车机 dock。
  Future<double> getCarModeDockClearance() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getDouble(_keyCarModeDockClearance);
    if (value == null) return kCarModeBottomDockClearance;
    return value.clamp(0.0, kCarModeDockClearanceMax);
  }

  Future<void> setCarModeDockClearance(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(
      _keyCarModeDockClearance,
      value.clamp(0.0, kCarModeDockClearanceMax),
    );
  }

  /// 常驻播放器面板的停靠位置，默认右侧。
  Future<CarModePanelSide> getCarModePanelSide() async {
    final prefs = await SharedPreferences.getInstance();
    return CarModePanelSide.fromIndex(prefs.getInt(_keyCarModePanelSide));
  }

  Future<void> setCarModePanelSide(CarModePanelSide side) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyCarModePanelSide, side.index);
  }

  // ===== MCP（AI 代理接口）=====
  // 默认全部关闭：AI 直接操控真实播放器属高风险能力，必须用户显式开启。
  static const String _keyMcpEnabled = 'settings_mcp_enabled';
  static const String _keyMcpPort = 'settings_mcp_port';
  static const String _keyMcpBindLan = 'settings_mcp_bind_lan';
  static const String _keyMcpReadOnly = 'settings_mcp_read_only';
  static const String _keyMcpToken = 'settings_mcp_token';
  static const String _keyMcpGroupPlayer = 'settings_mcp_group_player';
  static const String _keyMcpGroupDiscovery = 'settings_mcp_group_discovery';
  static const String _keyMcpGroupLibraryWrite =
      'settings_mcp_group_library_write';
  static const String _keyMcpGroupAppFeatures =
      'settings_mcp_group_app_features';
  static const String _keyMcpRequireConfirm = 'settings_mcp_require_confirm';
  static const String _keyMcpTokenSecure = 'settings_mcp_token_secure';
  static const FlutterSecureStorage _mcpSecureStorage = FlutterSecureStorage();

  /// 是否启用内置 MCP 服务端，默认 false（不监听任何端口）。
  Future<bool> getMcpEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyMcpEnabled) ?? false;
  }

  Future<void> setMcpEnabled(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyMcpEnabled, v);
  }

  /// MCP 监听端口，默认 17888（端口固定是刚需：MCP 客户端配置是静态 URL）。
  Future<int> getMcpPort() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyMcpPort) ?? 17888;
  }

  Future<void> setMcpPort(int v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyMcpPort, v);
  }

  /// true = 绑定 0.0.0.0（局域网可达，强制 token 鉴权）；false = 仅回环。默认 false。
  Future<bool> getMcpBindLan() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyMcpBindLan) ?? false;
  }

  Future<void> setMcpBindLan(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyMcpBindLan, v);
  }

  /// true = 隐藏并拒绝所有会改变播放状态的工具。默认 false。
  Future<bool> getMcpReadOnly() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyMcpReadOnly) ?? false;
  }

  Future<void> setMcpReadOnly(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyMcpReadOnly, v);
  }

  /// 鉴权 token；未生成过返回空串（由 McpSettingsStore 首次读取时生成并落盘）。
  Future<String> getMcpToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyMcpToken) ?? '';
  }

  Future<void> setMcpToken(String v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyMcpToken, v);
  }

  /// MCP 令牌（加密存储）。读不到返回空串。
  Future<String> getMcpTokenSecure() async {
    return await _mcpSecureStorage.read(key: _keyMcpTokenSecure) ?? '';
  }

  Future<void> setMcpTokenSecure(String v) async {
    await _mcpSecureStorage.write(key: _keyMcpTokenSecure, value: v);
  }

  /// 迁移完成后清除 SharedPreferences 里的明文旧值。
  Future<void> clearMcpToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyMcpToken);
  }

  /// MCP 工具组开关，默认全开。
  Future<bool> getMcpGroupPlayer() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyMcpGroupPlayer) ?? true;
  }

  Future<void> setMcpGroupPlayer(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyMcpGroupPlayer, v);
  }

  Future<bool> getMcpGroupDiscovery() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyMcpGroupDiscovery) ?? true;
  }

  Future<void> setMcpGroupDiscovery(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyMcpGroupDiscovery, v);
  }

  Future<bool> getMcpGroupLibraryWrite() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyMcpGroupLibraryWrite) ?? true;
  }

  Future<void> setMcpGroupLibraryWrite(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyMcpGroupLibraryWrite, v);
  }

  Future<bool> getMcpGroupAppFeatures() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyMcpGroupAppFeatures) ?? true;
  }

  Future<void> setMcpGroupAppFeatures(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyMcpGroupAppFeatures, v);
  }

  /// MCP 写操作是否需要 App 内二次确认，默认 true。
  Future<bool> getMcpRequireConfirm() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyMcpRequireConfirm) ?? true;
  }

  Future<void> setMcpRequireConfirm(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyMcpRequireConfirm, v);
  }
}
