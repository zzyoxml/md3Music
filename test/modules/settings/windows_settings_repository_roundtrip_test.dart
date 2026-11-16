import 'dart:io';
import 'package:md3music/core/services/audio_service_io.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/modules/player/car_mode_layout.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:md3music/data/repositories/settings_repository.dart';

// Windows 设置持久化契约：修改、重新读取、还原默认值，不改动真实用户配置。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final repo = SettingsRepository();
  final settings = <(String, Future<bool> Function(), Future<void> Function(bool))>[
    ('WindowsTwoPaneEnabled', repo.getWindowsTwoPaneEnabled, repo.setWindowsTwoPaneEnabled),
    ('DesktopModeEnabled', repo.getDesktopModeEnabled, repo.setDesktopModeEnabled),
    ('SecondaryPlayerEnabled', repo.getSecondaryPlayerEnabled, repo.setSecondaryPlayerEnabled),
    ('CloudUploadMatchEnabled', repo.getCloudUploadMatchEnabled, repo.setCloudUploadMatchEnabled),
    ('PredictiveBackEnabled', repo.getPredictiveBackEnabled, repo.setPredictiveBackEnabled),
    ('PlaylistCoverTransitionEnabled', repo.getPlaylistCoverTransitionEnabled, repo.setPlaylistCoverTransitionEnabled),
    ('SecondaryPlayerProgress', repo.getSecondaryPlayerProgress, repo.setSecondaryPlayerProgress),
    ('SecondaryPlayerOnPrimary', repo.getSecondaryPlayerOnPrimary, repo.setSecondaryPlayerOnPrimary),
    ('HideNavBarOnSecondaryPages', repo.getHideNavBarOnSecondaryPages, repo.setHideNavBarOnSecondaryPages),
    ('EmphasizedTypographyEnabled', repo.getEmphasizedTypographyEnabled, repo.setEmphasizedTypographyEnabled),
    ('AutoPlay', repo.getAutoPlay, repo.setAutoPlay),
    ('UpdateReminderEnabled', repo.getUpdateReminderEnabled, repo.setUpdateReminderEnabled),
    ('LegacyAppIconEnabled', repo.getLegacyAppIconEnabled, repo.setLegacyAppIconEnabled),
    ('ShowLyrics', repo.getShowLyrics, repo.setShowLyrics),
    ('AutoReceiveVip', repo.getAutoReceiveVip, repo.setAutoReceiveVip),
    ('AutoPipEnabled', repo.getAutoPipEnabled, repo.setAutoPipEnabled),
    ('MvDanmakuEnabled', repo.getMvDanmakuEnabled, repo.setMvDanmakuEnabled),
    ('SongDanmakuEnabled', repo.getSongDanmakuEnabled, repo.setSongDanmakuEnabled),
    ('UploadListeningDuration', repo.getUploadListeningDuration, repo.setUploadListeningDuration),
    ('DesktopLyricDoubleLine', repo.getDesktopLyricDoubleLine, repo.setDesktopLyricDoubleLine),
    ('DesktopLyricLocked', repo.getDesktopLyricLocked, repo.setDesktopLyricLocked),
    ('LyricPushTranslation', repo.getLyricPushTranslation, repo.setLyricPushTranslation),
    ('LyricPushRoma', repo.getLyricPushRoma, repo.setLyricPushRoma),
    ('LyricPushPreferTranslation', repo.getLyricPushPreferTranslation, repo.setLyricPushPreferTranslation),
    ('LyriconEnabled', repo.getLyriconEnabled, repo.setLyriconEnabled),
    ('LyriconDisplayTranslation', repo.getLyriconDisplayTranslation, repo.setLyriconDisplayTranslation),
    ('LyriconDisplayRoma', repo.getLyriconDisplayRoma, repo.setLyriconDisplayRoma),
    ('LyriconPreferTranslation', repo.getLyriconPreferTranslation, repo.setLyriconPreferTranslation),
    ('SuperLyricEnabled', repo.getSuperLyricEnabled, repo.setSuperLyricEnabled),
    ('SuperLyricPreferTranslation', repo.getSuperLyricPreferTranslation, repo.setSuperLyricPreferTranslation),
    ('FlymeStatusBarLyricEnabled', repo.getFlymeStatusBarLyricEnabled, repo.setFlymeStatusBarLyricEnabled),
    ('BluetoothLyricEnabled', repo.getBluetoothLyricEnabled, repo.setBluetoothLyricEnabled),
    ('BluetoothLyricCompressArt', repo.getBluetoothLyricCompressArt, repo.setBluetoothLyricCompressArt),
    ('DepthCoverEnabled', repo.getDepthCoverEnabled, repo.setDepthCoverEnabled),
    ('DepthCoverNeuralInpaint', repo.getDepthCoverNeuralInpaint, repo.setDepthCoverNeuralInpaint),
    ('LyricInfoEnabled', repo.getLyricInfoEnabled, repo.setLyricInfoEnabled),
    ('LyricInfoColorOs', repo.getLyricInfoColorOs, repo.setLyricInfoColorOs),
    ('LockScreenLyricEnabled', repo.getLockScreenLyricEnabled, repo.setLockScreenLyricEnabled),
    ('DisableSystemAudioEffects', repo.getDisableSystemAudioEffects, repo.setDisableSystemAudioEffects),
    ('ViperMasterEnabled', repo.getViperMasterEnabled, repo.setViperMasterEnabled),
    ('ViperTapeQualityEnabled', repo.getViperTapeQualityEnabled, repo.setViperTapeQualityEnabled),
    ('PauseFadeEnabled', repo.getPauseFadeEnabled, repo.setPauseFadeEnabled),
    ('CrossfadeEnabled', repo.getCrossfadeEnabled, repo.setCrossfadeEnabled),
    ('AutomixEnabled', repo.getAutomixEnabled, repo.setAutomixEnabled),
    ('SkipLiveEnabled', repo.getSkipLiveEnabled, repo.setSkipLiveEnabled),
    ('VolumeNormalizationEnabled', repo.getVolumeNormalizationEnabled, repo.setVolumeNormalizationEnabled),
    ('KeepScreenOn', repo.getKeepScreenOn, repo.setKeepScreenOn),
    ('SeekBarWaveEnabled', repo.getSeekBarWaveEnabled, repo.setSeekBarWaveEnabled),
    ('LandscapeDetachedControls', repo.getLandscapeDetachedControls, repo.setLandscapeDetachedControls),
    ('TopBarPillCollapse', repo.getTopBarPillCollapse, repo.setTopBarPillCollapse),
    ('TopBarTabDots', repo.getTopBarTabDots, repo.setTopBarTabDots),
    ('SpectrumEnabled', repo.getSpectrumEnabled, repo.setSpectrumEnabled),
    ('SpectrumVisualizerFallback', repo.getSpectrumVisualizerFallback, repo.setSpectrumVisualizerFallback),
    ('SpectrumDynamicColor', repo.getSpectrumDynamicColor, repo.setSpectrumDynamicColor),
    ('MusicHapticsEnabled', repo.getMusicHapticsEnabled, repo.setMusicHapticsEnabled),
    ('MusicHapticsSnare', repo.getMusicHapticsSnare, repo.setMusicHapticsSnare),
    ('MiniPlayerSwipeSwitchEnabled', repo.getMiniPlayerSwipeSwitchEnabled, repo.setMiniPlayerSwipeSwitchEnabled),
    ('SortCollectedByLatestClick', repo.getSortCollectedByLatestClick, repo.setSortCollectedByLatestClick),
    ('IgnoreAudioFocus', repo.getIgnoreAudioFocus, repo.setIgnoreAudioFocus),
    ('ZenCoverLongPress', repo.getZenCoverLongPress, repo.setZenCoverLongPress),
    ('LandscapeImmersiveEnabled', repo.getLandscapeImmersiveEnabled, repo.setLandscapeImmersiveEnabled),
    ('ShowQualityDowngradeToast', repo.getShowQualityDowngradeToast, repo.setShowQualityDowngradeToast),
    ('MvAudioFallbackEnabled', repo.getMvAudioFallbackEnabled, repo.setMvAudioFallbackEnabled),
    ('RestoreMemoryEnabled', repo.getRestoreMemoryEnabled, repo.setRestoreMemoryEnabled),
    ('StartupAutoPlayEnabled', repo.getStartupAutoPlayEnabled, repo.setStartupAutoPlayEnabled),
    ('StartupAutoPlayOpenPage', repo.getStartupAutoPlayOpenPage, repo.setStartupAutoPlayOpenPage),
    ('CloseLocalMusicComments', repo.getCloseLocalMusicComments, repo.setCloseLocalMusicComments),
    ('AutoMatchOnlineInfo', repo.getAutoMatchOnlineInfo, repo.setAutoMatchOnlineInfo),
    ('DynamicAlbumCover', repo.getDynamicAlbumCover, repo.setDynamicAlbumCover),
    ('DynamicAlbumCoverOnMobile', repo.getDynamicAlbumCoverOnMobile, repo.setDynamicAlbumCoverOnMobile),
    ('CarModeEnabled', repo.getCarModeEnabled, repo.setCarModeEnabled),
    ('CarModeAutoScreenEnabled', repo.getCarModeAutoScreenEnabled, repo.setCarModeAutoScreenEnabled),
    ('McpEnabled', repo.getMcpEnabled, repo.setMcpEnabled),
    ('McpBindLan', repo.getMcpBindLan, repo.setMcpBindLan),
    ('McpReadOnly', repo.getMcpReadOnly, repo.setMcpReadOnly),
    ('McpGroupPlayer', repo.getMcpGroupPlayer, repo.setMcpGroupPlayer),
    ('McpGroupDiscovery', repo.getMcpGroupDiscovery, repo.setMcpGroupDiscovery),
    ('McpGroupLibraryWrite', repo.getMcpGroupLibraryWrite, repo.setMcpGroupLibraryWrite),
    ('McpGroupAppFeatures', repo.getMcpGroupAppFeatures, repo.setMcpGroupAppFeatures),
    ('McpRequireConfirm', repo.getMcpRequireConfirm, repo.setMcpRequireConfirm),
  ];
  for (final setting in settings) {
    test('Windows 设置读写和重置一致：${setting.$1}', () async {
      SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
      FlutterSecureStorage.setMockInitialValues({});
      final initial = await setting.$2();
      await setting.$3(!initial);
      expect(await setting.$2(), !initial);
      await repo.resetAllSettingsToDefaults();
      expect(await setting.$2(), initial);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('kugou_token'), 'keep-login');
    }, skip: !Platform.isWindows);
  }
  test('Windows 数值/选项读写和重置一致：CoverFlowSourceRaw', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getCoverFlowSourceRaw();
    final changed = initial == 'daily' ? 'personalFm' : 'daily';
    await repo.setCoverFlowSourceRaw(changed);
    expect(await repo.getCoverFlowSourceRaw(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getCoverFlowSourceRaw(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：SecondaryPlayerOpacity', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getSecondaryPlayerOpacity();
    final changed = initial == 0.4 ? 0.6 : 0.4;
    await repo.setSecondaryPlayerOpacity(changed);
    expect(await repo.getSecondaryPlayerOpacity(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getSecondaryPlayerOpacity(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：SecondaryPlayerDockRaw', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getSecondaryPlayerDockRaw();
    final changed = initial == 'left' ? 'right' : 'left';
    await repo.setSecondaryPlayerDockRaw(changed);
    expect(await repo.getSecondaryPlayerDockRaw(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getSecondaryPlayerDockRaw(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：DesktopSidebarWidth', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getDesktopSidebarWidth();
    final changed = initial == 220.0 ? 260.0 : 220.0;
    await repo.setDesktopSidebarWidth(changed);
    expect(await repo.getDesktopSidebarWidth(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getDesktopSidebarWidth(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：DesktopDetailRatio', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getDesktopDetailRatio();
    final changed = initial == 0.4 ? 0.6 : 0.4;
    await repo.setDesktopDetailRatio(changed);
    expect(await repo.getDesktopDetailRatio(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getDesktopDetailRatio(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：WifiQuality', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getWifiQuality();
    final changed = initial == 'high' ? 'lossless' : 'high';
    await repo.setWifiQuality(changed);
    expect(await repo.getWifiQuality(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getWifiQuality(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：MobileQuality', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getMobileQuality();
    final changed = initial == 'high' ? 'lossless' : 'high';
    await repo.setMobileQuality(changed);
    expect(await repo.getMobileQuality(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getMobileQuality(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：CacheSize', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getCacheSize();
    final changed = initial == 1 ? 2 : 1;
    await repo.setCacheSize(changed);
    expect(await repo.getCacheSize(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getCacheSize(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：UpdateLastCheckMs', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getUpdateLastCheckMs();
    final changed = initial == 1 ? 2 : 1;
    await repo.setUpdateLastCheckMs(changed);
    expect(await repo.getUpdateLastCheckMs(), changed);
    await repo.resetAllSettingsToDefaults();
    // 更新检查历史不是用户偏好，重置设置不应重复推送已经提醒的版本。
    expect(await repo.getUpdateLastCheckMs(), changed);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：UpdateLastNotifiedVersion', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getUpdateLastNotifiedVersion();
    final changed = initial == 'audit-one' ? 'audit-two' : 'audit-one';
    await repo.setUpdateLastNotifiedVersion(changed);
    expect(await repo.getUpdateLastNotifiedVersion(), changed);
    await repo.resetAllSettingsToDefaults();
    // 更新检查历史不是用户偏好，重置设置不应重复推送已经提醒的版本。
    expect(await repo.getUpdateLastNotifiedVersion(), changed);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：MvDanmakuOpacity', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getMvDanmakuOpacity();
    final changed = initial == 0.4 ? 0.6 : 0.4;
    await repo.setMvDanmakuOpacity(changed);
    expect(await repo.getMvDanmakuOpacity(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getMvDanmakuOpacity(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：LyricTimeOffset', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getLyricTimeOffset();
    final changed = initial == 1 ? 2 : 1;
    await repo.setLyricTimeOffset(changed);
    expect(await repo.getLyricTimeOffset(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getLyricTimeOffset(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：DesktopLyricFontSize', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getDesktopLyricFontSize();
    expect(initial, Platform.isWindows ? 40.0 : 18.0);
    final changed = initial == 20.0 ? 24.0 : 20.0;
    await repo.setDesktopLyricFontSize(changed);
    expect(await repo.getDesktopLyricFontSize(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getDesktopLyricFontSize(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：DesktopLyricOpacity', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getDesktopLyricOpacity();
    final changed = initial == 1 ? 2 : 1;
    await repo.setDesktopLyricOpacity(changed);
    expect(await repo.getDesktopLyricOpacity(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getDesktopLyricOpacity(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：DesktopLyricGradientStart', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getDesktopLyricGradientStart();
    final changed = initial == 1 ? 2 : 1;
    await repo.setDesktopLyricGradientStart(changed);
    expect(await repo.getDesktopLyricGradientStart(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getDesktopLyricGradientStart(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：DesktopLyricGradientEnd', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getDesktopLyricGradientEnd();
    final changed = initial == 1 ? 2 : 1;
    await repo.setDesktopLyricGradientEnd(changed);
    expect(await repo.getDesktopLyricGradientEnd(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getDesktopLyricGradientEnd(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：DesktopLyricUnplayedColor', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getDesktopLyricUnplayedColor();
    final changed = initial == 1 ? 2 : 1;
    await repo.setDesktopLyricUnplayedColor(changed);
    expect(await repo.getDesktopLyricUnplayedColor(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getDesktopLyricUnplayedColor(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：DesktopLyricColorMode', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getDesktopLyricColorMode();
    final changed = initial == 1 ? 2 : 1;
    await repo.setDesktopLyricColorMode(changed);
    expect(await repo.getDesktopLyricColorMode(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getDesktopLyricColorMode(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：DesktopLyricPresetIndex', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getDesktopLyricPresetIndex();
    final changed = initial == 1 ? 2 : 1;
    await repo.setDesktopLyricPresetIndex(changed);
    expect(await repo.getDesktopLyricPresetIndex(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getDesktopLyricPresetIndex(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：DesktopLyricCustomGradStart', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getDesktopLyricCustomGradStart();
    final changed = initial == 1 ? 2 : 1;
    await repo.setDesktopLyricCustomGradStart(changed);
    expect(await repo.getDesktopLyricCustomGradStart(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getDesktopLyricCustomGradStart(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：DesktopLyricCustomGradEnd', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getDesktopLyricCustomGradEnd();
    final changed = initial == 1 ? 2 : 1;
    await repo.setDesktopLyricCustomGradEnd(changed);
    expect(await repo.getDesktopLyricCustomGradEnd(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getDesktopLyricCustomGradEnd(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：DesktopLyricCustomUnplayed', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getDesktopLyricCustomUnplayed();
    final changed = initial == 1 ? 2 : 1;
    await repo.setDesktopLyricCustomUnplayed(changed);
    expect(await repo.getDesktopLyricCustomUnplayed(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getDesktopLyricCustomUnplayed(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：LyricPushProtocol', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getLyricPushProtocol();
    final changed = initial == 'metadata' ? 'lyric' : 'metadata';
    await repo.setLyricPushProtocol(changed);
    expect(await repo.getLyricPushProtocol(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getLyricPushProtocol(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：RemoteControlMode', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getRemoteControlMode();
    final changed = initial == 'auto' ? 'force' : 'auto';
    await repo.setRemoteControlMode(changed);
    expect(await repo.getRemoteControlMode(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getRemoteControlMode(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：FlymeLyricAdvanceMs', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getFlymeLyricAdvanceMs();
    final changed = initial == 1 ? 2 : 1;
    await repo.setFlymeLyricAdvanceMs(changed);
    expect(await repo.getFlymeLyricAdvanceMs(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getFlymeLyricAdvanceMs(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：DepthCoverStrength', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getDepthCoverStrength();
    final changed = initial == 0.4 ? 0.6 : 0.4;
    await repo.setDepthCoverStrength(changed);
    expect(await repo.getDepthCoverStrength(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getDepthCoverStrength(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：CoverShadowStrength', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getCoverShadowStrength();
    final changed = initial == 0.4 ? 0.6 : 0.4;
    await repo.setCoverShadowStrength(changed);
    expect(await repo.getCoverShadowStrength(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getCoverShadowStrength(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：UiScale', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getUiScale();
    final changed = initial == 1.0 ? 1.2 : 1.0;
    await repo.setUiScale(changed);
    expect(await repo.getUiScale(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getUiScale(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：CrossfadeSeconds', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getCrossfadeSeconds();
    final changed = initial == 2 ? 3 : 2;
    await repo.setCrossfadeSeconds(changed);
    expect(await repo.getCrossfadeSeconds(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getCrossfadeSeconds(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：VolumeNormalizationReferenceLufs', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getVolumeNormalizationReferenceLufs();
    final changed = initial == -16.0 ? -12.0 : -16.0;
    await repo.setVolumeNormalizationReferenceLufs(changed);
    expect(await repo.getVolumeNormalizationReferenceLufs(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getVolumeNormalizationReferenceLufs(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：SpectrumBandCount', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getSpectrumBandCount();
    final changed = initial == 32 ? 64 : 32;
    await repo.setSpectrumBandCount(changed);
    expect(await repo.getSpectrumBandCount(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getSpectrumBandCount(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：SpectrumStyle', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getSpectrumStyle();
    final changed = initial == 1 ? 2 : 1;
    await repo.setSpectrumStyle(changed);
    expect(await repo.getSpectrumStyle(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getSpectrumStyle(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：SpectrumBgOpacity', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getSpectrumBgOpacity();
    final changed = initial == 0.4 ? 0.6 : 0.4;
    await repo.setSpectrumBgOpacity(changed);
    expect(await repo.getSpectrumBgOpacity(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getSpectrumBgOpacity(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：SpectrumBgHeight', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getSpectrumBgHeight();
    final changed = initial == 0.3 ? 0.4 : 0.3;
    await repo.setSpectrumBgHeight(changed);
    expect(await repo.getSpectrumBgHeight(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getSpectrumBgHeight(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：SpectrumBarOpacity', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getSpectrumBarOpacity();
    final changed = initial == 0.4 ? 0.6 : 0.4;
    await repo.setSpectrumBarOpacity(changed);
    expect(await repo.getSpectrumBarOpacity(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getSpectrumBarOpacity(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：SpectrumCurveOpacity', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getSpectrumCurveOpacity();
    final changed = initial == 0.4 ? 0.6 : 0.4;
    await repo.setSpectrumCurveOpacity(changed);
    expect(await repo.getSpectrumCurveOpacity(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getSpectrumCurveOpacity(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：MusicHapticsStrength', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getMusicHapticsStrength();
    final changed = initial == 0.4 ? 0.6 : 0.4;
    await repo.setMusicHapticsStrength(changed);
    expect(await repo.getMusicHapticsStrength(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getMusicHapticsStrength(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：MusicHapticsSensitivity', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getMusicHapticsSensitivity();
    final changed = initial == 0.4 ? 0.6 : 0.4;
    await repo.setMusicHapticsSensitivity(changed);
    expect(await repo.getMusicHapticsSensitivity(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getMusicHapticsSensitivity(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：MusicHapticsWaveform', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getMusicHapticsWaveform();
    final changed = initial == 'sine' ? 'square' : 'sine';
    await repo.setMusicHapticsWaveform(changed);
    expect(await repo.getMusicHapticsWaveform(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getMusicHapticsWaveform(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：MusicHapticsOffset', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getMusicHapticsOffset();
    final changed = initial == 1 ? 2 : 1;
    await repo.setMusicHapticsOffset(changed);
    expect(await repo.getMusicHapticsOffset(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getMusicHapticsOffset(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：MusicHapticsScope', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getMusicHapticsScope();
    final changed = initial == 'all' ? 'online' : 'all';
    await repo.setMusicHapticsScope(changed);
    expect(await repo.getMusicHapticsScope(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getMusicHapticsScope(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：TabConfigMigrationVersion', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getTabConfigMigrationVersion();
    final changed = initial == 1 ? 2 : 1;
    await repo.setTabConfigMigrationVersion(changed);
    expect(await repo.getTabConfigMigrationVersion(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getTabConfigMigrationVersion(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：CreatedPlaylistSort', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getCreatedPlaylistSort();
    final changed = initial == 1 ? 2 : 1;
    await repo.setCreatedPlaylistSort(changed);
    expect(await repo.getCreatedPlaylistSort(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getCreatedPlaylistSort(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：CollectedPlaylistSort', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getCollectedPlaylistSort();
    final changed = initial == 1 ? 2 : 1;
    await repo.setCollectedPlaylistSort(changed);
    expect(await repo.getCollectedPlaylistSort(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getCollectedPlaylistSort(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：GridColumns', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getGridColumns();
    final changed = initial == 1 ? 2 : 1;
    await repo.setGridColumns(changed);
    expect(await repo.getGridColumns(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getGridColumns(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：StartupAutoPlaySource', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getStartupAutoPlaySource();
    final changed = initial == 'resume' ? 'daily' : 'resume';
    await repo.setStartupAutoPlaySource(changed);
    expect(await repo.getStartupAutoPlaySource(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getStartupAutoPlaySource(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：CarModePanelRatio', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getCarModePanelRatio();
    final changed = initial == 0.3 ? 0.4 : 0.3;
    await repo.setCarModePanelRatio(changed);
    expect(await repo.getCarModePanelRatio(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getCarModePanelRatio(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：CarModeDockClearance', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getCarModeDockClearance();
    final changed = initial == 20.0 ? 30.0 : 20.0;
    await repo.setCarModeDockClearance(changed);
    expect(await repo.getCarModeDockClearance(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getCarModeDockClearance(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：McpPort', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getMcpPort();
    final changed = initial == 1 ? 2 : 1;
    await repo.setMcpPort(changed);
    expect(await repo.getMcpPort(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getMcpPort(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：McpToken', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getMcpToken();
    final changed = initial == 'audit-one' ? 'audit-two' : 'audit-one';
    await repo.setMcpToken(changed);
    expect(await repo.getMcpToken(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getMcpToken(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 数值/选项读写和重置一致：McpTokenSecure', () async {
    SharedPreferences.setMockInitialValues({'kugou_token': 'keep-login'});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getMcpTokenSecure();
    final changed = initial == 'audit-one' ? 'audit-two' : 'audit-one';
    await repo.setMcpTokenSecure(changed);
    expect(await repo.getMcpTokenSecure(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getMcpTokenSecure(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 枚举/排序读写和重置一致：ThemeMode', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getThemeMode();
    final changed = initial == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    await repo.setThemeMode(changed);
    expect(await repo.getThemeMode(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getThemeMode(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 枚举/排序读写和重置一致：AudioFocusInterruptionMode', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getAudioFocusInterruptionMode();
    final changed = initial == AudioFocusInterruptionMode.keepPlaying ? AudioFocusInterruptionMode.pauseAndResume : AudioFocusInterruptionMode.keepPlaying;
    await repo.setAudioFocusInterruptionMode(changed);
    expect(await repo.getAudioFocusInterruptionMode(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getAudioFocusInterruptionMode(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 枚举/排序读写和重置一致：CarModePanelSide', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getCarModePanelSide();
    final changed = initial == CarModePanelSide.left ? CarModePanelSide.right : CarModePanelSide.left;
    await repo.setCarModePanelSide(changed);
    expect(await repo.getCarModePanelSide(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getCarModePanelSide(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 枚举/排序读写和重置一致：TabOrder', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getTabOrder();
    final changed = <String>['user', 'discover'];
    await repo.setTabOrder(changed);
    expect(await repo.getTabOrder(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getTabOrder(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 枚举/排序读写和重置一致：HiddenTabs', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getHiddenTabs();
    final changed = <String>{'discover'};
    await repo.setHiddenTabs(changed);
    expect(await repo.getHiddenTabs(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getHiddenTabs(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 枚举/排序读写和重置一致：DesktopShortcutOrder', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getDesktopShortcutOrder();
    final changed = <String>['search', 'favorites'];
    await repo.setDesktopShortcutOrder(changed);
    expect(await repo.getDesktopShortcutOrder(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getDesktopShortcutOrder(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 枚举/排序读写和重置一致：HiddenDesktopShortcuts', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getHiddenDesktopShortcuts();
    final changed = <String>{'favorites'};
    await repo.setHiddenDesktopShortcuts(changed);
    expect(await repo.getHiddenDesktopShortcuts(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getHiddenDesktopShortcuts(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 枚举/排序读写和重置一致：CreatedPlaylistOrder', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getCreatedPlaylistOrder();
    final changed = <String>['audit-id'];
    await repo.setCreatedPlaylistOrder(changed);
    expect(await repo.getCreatedPlaylistOrder(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getCreatedPlaylistOrder(), initial);
  }, skip: !Platform.isWindows);

  test('Windows 枚举/排序读写和重置一致：CollectedPlaylistOrder', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final initial = await repo.getCollectedPlaylistOrder();
    final changed = <String>['audit-id'];
    await repo.setCollectedPlaylistOrder(changed);
    expect(await repo.getCollectedPlaylistOrder(), changed);
    await repo.resetAllSettingsToDefaults();
    expect(await repo.getCollectedPlaylistOrder(), initial);
  }, skip: !Platform.isWindows);

}
