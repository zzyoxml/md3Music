import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/core/services/desktop_lyric_service.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:md3music/modules/settings/settings_page.dart';
import 'package:md3music/modules/settings/settings_two_pane.dart';
import 'package:md3music/providers/car_mode_provider.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/providers/grid_columns_provider.dart';
import 'package:md3music/providers/comment_display_provider.dart';
import 'package:md3music/providers/cloud_upload_provider.dart';
import 'package:md3music/providers/library_provider.dart';
import 'package:md3music/data/repositories/local_music_repository.dart';
import 'package:md3music/providers/shortcut_config_provider.dart';
import 'package:md3music/widgets/md3_lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/player_seek_bar.dart';
import 'package:md3music/widgets/player_top_bar_actions.dart';
import 'package:md3music/modules/player/player_cover_shadow.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TestPaths extends PathProviderPlatform {
  @override
  Future<String?> getExternalStoragePath() async =>
      Directory('tmp/windows-settings-sync-cache').absolute.path;
}

Map<String, Object?> _themeSnapshot(ThemeProvider theme) => {
  'themeMode': theme.themeMode,
  'useDynamicColor': theme.useDynamicColor,
  'useCoverSeedColor': theme.useCoverSeedColor,
  'useAmStylePlayer': theme.useAmStylePlayer,
  'manualSeedColor': theme.manualSeedColor,
  'useOledBlack': theme.useOledBlack,
  'displayScale': theme.displayScale,
  'navLabelBehavior': theme.navLabelBehavior,
  'fontSource': theme.fontSource,
  'customFontPath': theme.customFontPath,
  'customTextColor': theme.customTextColor,
  'useArtistPhotoBackground': theme.useArtistPhotoBackground,
  'artistPhotoInterval': theme.artistPhotoInterval,
  'artistPhotoOpacity': theme.artistPhotoOpacity,
  'lyricDoubleTapToJump': theme.lyricDoubleTapToJump,
  'useBackgroundImage': theme.useBackgroundImage,
  'backgroundImagePath': theme.backgroundImagePath,
  'backgroundBlur': theme.backgroundBlur,
  'amPlayerBlur': theme.amPlayerBlur,
  'backgroundOpacity': theme.backgroundOpacity,
  'useBackgroundMonet': theme.useBackgroundMonet,
  'useTextShadow': theme.useTextShadow,
  'textShadowBlur': theme.textShadowBlur,
  'emphasizedTypographyEnabled': theme.emphasizedTypographyEnabled,
};

void main() {
  // 原生探测不是页面行为，放进独立时钟，避免真实周期任务污染页面测试。
  setUpAll(() {
    fakeAsync((_) {
      DesktopLyricService.instance;
    });
  });

  test('Windows 重置后主题内存、持久化默认值保持一致', () async {
    SharedPreferences.setMockInitialValues({
      'use_background_image': true,
      'background_blur': 9.0,
      'theme_mode': ThemeMode.dark.index,
      'manual_seed_color': 0xFF123456,
      'use_am_style_player': true,
      'use_dynamic_color': true,
      'use_cover_dynamic_color': true,
      'use_oled_black': true,
      'ui_display_scale': 1.2,
      'custom_text_color': 0xFF123456,
      'use_artist_photo_background': true,
      'artist_photo_interval': 12,
      'artist_photo_opacity': 0.7,
      'lyric_double_tap_to_jump': false,
      'am_player_blur': 8.0,
      'background_opacity': 0.5,
      'use_background_monet': false,
      'use_text_shadow': false,
      'text_shadow_blur': 10.0,
      'emphasized_typography': true,
    });
    FlutterSecureStorage.setMockInitialValues({});
    final theme = ThemeProvider();
    await theme.windowsSettingsReady;
    expect(theme.useBackgroundImage, isTrue);
    expect(theme.backgroundBlur, 9.0);
    await SettingsRepository().resetAllSettingsToDefaults();
    await theme.reloadWindowsSettings();
    expect(theme.useBackgroundImage, isFalse);
    expect(theme.backgroundBlur, 20.0);
    expect(theme.backgroundOpacity, 0.2);
    expect(theme.themeMode, ThemeMode.system);
    expect(theme.manualSeedColor, isNull);
    expect(theme.useAmStylePlayer, isFalse);
    final fresh = ThemeProvider();
    await fresh.windowsSettingsReady;
    expect(
      _themeSnapshot(theme),
      _themeSnapshot(fresh),
      reason: '24 个外观偏好在重置后的运行值必须等于全新启动默认值',
    );
    fresh.dispose();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('use_background_image'), isFalse);
    theme.dispose();
  }, skip: !Platform.isWindows);

  testWidgets('Windows 保活设置页的背景开关跟随实际主题状态', (tester) async {
    final paths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths();
    addTearDown(() => PathProviderPlatform.instance = paths);
    SharedPreferences.setMockInitialValues({'local_music_cached_songs': '[]'});
    FlutterSecureStorage.setMockInitialValues({});
    kWindowsTwoPaneEnabled.value = false;
    addTearDown(() => kWindowsTwoPaneEnabled.value = false);
    final active = ValueNotifier(true);
    addTearDown(active.dispose);
    final theme = ThemeProvider();
    final device = DeviceProvider();
    final car = CarModeProvider();
    final tabs = TabConfigProvider();
    final shortcuts = ShortcutConfigProvider();
    final gridColumns = GridColumnsProvider();
    final commentDisplay = CommentDisplayProvider();
    final cloudUpload = CloudUploadProvider();
    final library = LibraryProvider();
    await Future.wait<void>([
      gridColumns.settingsReady,
      commentDisplay.settingsReady,
      cloudUpload.ensureMatchLoaded(),
    ]);
    final repository = SettingsRepository();
    gridColumns.setColumns(6);
    await commentDisplay.setCommentFontSize(23.0);
    await cloudUpload.setMatchEnabled(false);
    final localMusic = LocalMusicRepository();
    await localMusic.saveFolders(['C:/Music']);
    await localMusic.saveExcludedFolders(['C:/Music/Exclude']);
    await localMusic.setFilterShortAudio(true);
    await library.loadScanFolders();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: theme),
          ChangeNotifierProvider.value(value: device),
          ChangeNotifierProvider.value(value: car),
          ChangeNotifierProvider.value(value: tabs),
          ChangeNotifierProvider.value(value: shortcuts),
          ChangeNotifierProvider.value(value: gridColumns),
          ChangeNotifierProvider.value(value: commentDisplay),
          ChangeNotifierProvider.value(value: cloudUpload),
          ChangeNotifierProvider.value(value: library),
        ],
        child: ValueListenableBuilder<bool>(
          valueListenable: active,
          builder: (_, enabled, child) =>
              TickerMode(enabled: enabled, child: child!),
          child: const MaterialApp(home: SettingsPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SettingsTwoPaneBody), findsNothing);
    kWindowsTwoPaneEnabled.value = true;
    await tester.pumpAndSettle();
    expect(find.byType(SettingsTwoPaneBody), findsOneWidget);
    kWindowsTwoPaneEnabled.value = false;
    await tester.pumpAndSettle();
    expect(find.byType(SettingsTwoPaneBody), findsNothing);
    // 普通仓库设置也要在标签页再次激活时重新读取，不能只同步主题。
    await tester.tap(find.widgetWithText(ListTile, '播放'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '音质与输出'));
    await tester.pumpAndSettle();
    final vip = find.widgetWithText(SwitchListTile, '自动领取VIP');
    final previousVip = tester.widget<SwitchListTile>(vip).value;
    active.value = false;
    await tester.pump();
    await SettingsRepository().setAutoReceiveVip(!previousVip);
    active.value = true;
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(vip).value, !previousVip);
    final output = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, '32bit 播放支持'),
    );
    expect(output.onChanged, isNull, reason: 'Windows 未实现的原生选项不能假装设置成功');
    expect(output.value, isFalse);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    // 模拟另一个 Windows 页面修改实际主题，设置标签页仍然保活。
    await theme.setUseBackgroundImage(true);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '外观'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '界面背景'));
    await tester.pumpAndSettle();
    final toggle = find.widgetWithText(SwitchListTile, '启用自定义背景图片');
    expect(
      tester.widget<SwitchListTile>(toggle).value,
      theme.useBackgroundImage,
    );
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await theme.setUseBackgroundImage(false);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('use_background_image'), isFalse);
    // 用户手动开启，再离开/返回子页，显示值、运行值、保存值必须一致。
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(theme.useBackgroundImage, isTrue);
    expect(prefs.getBool('use_background_image'), isTrue);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '界面背景'));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    // 不只清磁盘：所有已加载 Provider 和播放器全局镜像也必须回到默认。
    await device.setDeviceType(DeviceType.pad);
    await car.setEnabled(true);
    await car.setPanelRatio(0.45);
    await tabs.toggleTabVisibility('fm');
    await shortcuts.toggleShortcutVisibility('favorites');
    await LyricPreferences.instance.load();
    await Md3LyricPreferences.instance.load();
    await Md3LyricPreferences.instance.setLineBalance(true);
    final repo = SettingsRepository();
    await repo.setSeekBarWaveEnabled(false);
    kSeekBarWaveEnabled.value = false;
    await repo.setTopBarPillCollapse(false);
    kTopBarPillCollapseEnabled.value = false;
    await repo.setCoverShadowStrength(0.1);
    kCoverShadowIntensity.value = 0.1;
    kSecondaryPlayerEnabled.value = false;
    // 从真实还原入口验证：运行中的主题、设置显示和分栏一起恢复默认。
    kWindowsTwoPaneEnabled.value = true;
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('关于'),
      400,
      scrollable: find
          .descendant(
            of: find.byType(SettingsTwoPaneBody),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.widgetWithText(ListTile, '关于'));
    await tester.pumpAndSettle();
    final reset = find.widgetWithText(ListTile, '还原所有设置');
    await tester.ensureVisible(reset);
    await tester.tap(reset);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '还原设置'));
    await tester.pumpAndSettle();
    expect(theme.useBackgroundImage, isFalse);
    expect(kWindowsTwoPaneEnabled.value, isFalse);
    expect(find.byType(SettingsTwoPaneBody), findsNothing);
    expect(device.deviceType, DeviceType.auto);
    expect(car.enabled, await repo.getCarModeEnabled());
    expect(car.panelRatio, await repo.getCarModePanelRatio());
    expect(tabs.hiddenTabs, contains('fm'));
    expect(shortcuts.visibleShortcuts.map((s) => s.id), contains('favorites'));
    expect(Md3LyricPreferences.instance.lineBalance, isFalse);
    expect(
      kSecondaryPlayerEnabled.value,
      await repo.getSecondaryPlayerEnabled(),
    );
    expect(
      kSecondaryPlayerProgressEnabled.value,
      await repo.getSecondaryPlayerProgress(),
    );
    expect(
      kHideNavBarOnSecondaryPages.value,
      await repo.getHideNavBarOnSecondaryPages(),
    );
    expect(kSeekBarWaveEnabled.value, await repo.getSeekBarWaveEnabled());
    expect(
      kTopBarPillCollapseEnabled.value,
      await repo.getTopBarPillCollapse(),
    );
    expect(kCoverShadowIntensity.value, await repo.getCoverShadowStrength());
    expect(gridColumns.gridColumns, 4);
    expect(commentDisplay.commentFontSize, 17.0);
    expect(
      cloudUpload.matchEnabled,
      await repository.getCloudUploadMatchEnabled(),
    );
    expect(cloudUpload.matchEnabled, isTrue);
    expect(library.scanFolders, isEmpty);
    expect(library.excludedFolders, isEmpty);
    expect(library.filterShortAudio, isFalse);
    final localMusicPrefs = await SharedPreferences.getInstance();
    expect(
      localMusicPrefs.getString('local_music_cached_songs'),
      '[]',
      reason: '重置目录/筛选偏好不应删除本地歌曲缓存',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    theme.dispose();
    device.dispose();
    car.dispose();
    tabs.dispose();
    shortcuts.dispose();
    gridColumns.dispose();
    commentDisplay.dispose();
    cloudUpload.dispose();
    library.dispose();
  }, skip: !Platform.isWindows);

  testWidgets('Windows 不支持的自动画中画设置显示关闭且不可修改', (tester) async {
    final paths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths();
    addTearDown(() => PathProviderPlatform.instance = paths);
    SharedPreferences.setMockInitialValues({
      'settings_auto_pip': true,
      'local_music_cached_songs': '[]',
    });
    FlutterSecureStorage.setMockInitialValues({});
    kWindowsTwoPaneEnabled.value = false;
    addTearDown(() => kWindowsTwoPaneEnabled.value = false);

    final theme = ThemeProvider();
    final device = DeviceProvider();
    final car = CarModeProvider();
    final tabs = TabConfigProvider();
    final shortcuts = ShortcutConfigProvider();
    final gridColumns = GridColumnsProvider();
    final commentDisplay = CommentDisplayProvider();
    final cloudUpload = CloudUploadProvider();
    final library = LibraryProvider();
    await Future.wait<void>([
      theme.windowsSettingsReady,
      gridColumns.settingsReady,
      commentDisplay.settingsReady,
      cloudUpload.ensureMatchLoaded(),
    ]);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: theme),
          ChangeNotifierProvider.value(value: device),
          ChangeNotifierProvider.value(value: car),
          ChangeNotifierProvider.value(value: tabs),
          ChangeNotifierProvider.value(value: shortcuts),
          ChangeNotifierProvider.value(value: gridColumns),
          ChangeNotifierProvider.value(value: commentDisplay),
          ChangeNotifierProvider.value(value: cloudUpload),
          ChangeNotifierProvider.value(value: library),
        ],
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
    final play = find.widgetWithText(ListTile, '播放');
    await tester.ensureVisible(play);
    await tester.tap(play);
    await tester.pumpAndSettle();
    final screenVideo = find.widgetWithText(ListTile, '屏幕与视频');
    await tester.ensureVisible(screenVideo);
    await tester.tap(screenVideo);
    await tester.pumpAndSettle();

    final autoPip = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, '播放 MV 时自动画中画'),
    );
    expect(autoPip.value, isFalse);
    expect(autoPip.onChanged, isNull);
    expect(find.text('当前 Windows 版本暂不支持画中画'), findsOneWidget);
    expect(
      (await SharedPreferences.getInstance()).getBool('settings_auto_pip'),
      isTrue,
      reason: '不支持的平台不应静默改写原有偏好值',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    theme.dispose();
    device.dispose();
    car.dispose();
    tabs.dispose();
    shortcuts.dispose();
    gridColumns.dispose();
    commentDisplay.dispose();
    cloudUpload.dispose();
    library.dispose();
  }, skip: !Platform.isWindows);
}
