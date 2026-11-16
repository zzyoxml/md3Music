import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../core/layout/responsive_layout.dart';
import '../../core/services/desktop_lyric_service.dart';
import '../../data/repositories/settings_repository.dart';
import '../../providers/car_mode_provider.dart';
import '../../providers/comment_display_provider.dart';
import '../../providers/cloud_upload_provider.dart';
import '../../providers/grid_columns_provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/device_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/shortcut_config_provider.dart';
import '../../providers/tab_config_provider.dart';
import '../../providers/theme_provider.dart';
import '../../utils/landscape_immersive.dart';
import '../../services/depth_cover_service.dart';
import '../player/mini_player.dart';
import '../../widgets/apple_lyrics/layout/lyric_preferences.dart';
import '../../widgets/md3_lyric_preferences.dart';
import '../../widgets/player_seek_bar.dart';
import '../../widgets/player_top_bar_actions.dart';
import '../../widgets/player_top_bar_tab_dots.dart';
import '../coverflow/coverflow_source.dart';
import '../mcp/mcp_service.dart';
import '../player/player_cover_shadow.dart';

/// 在布局可能因还原而销毁设置页之前，捕获需要同步的运行态。
/// 只由 Windows 的还原入口调用，不改变其它平台的设置加载和存储方式。
class WindowsSettingsRuntime {
  WindowsSettingsRuntime.capture(BuildContext context)
    : theme = context.read<ThemeProvider>(),
      device = context.read<DeviceProvider?>(),
      car = context.read<CarModeProvider?>(),
      tabs = context.read<TabConfigProvider?>(),
      shortcuts = context.read<ShortcutConfigProvider?>(),
      player = context.read<PlayerProvider?>(),
      mcp = context.read<McpService?>(),
      gridColumns = context.read<GridColumnsProvider?>(),
      commentDisplay = context.read<CommentDisplayProvider?>(),
      cloudUpload = context.read<CloudUploadProvider?>(),
      library = context.read<LibraryProvider?>();

  final ThemeProvider theme;
  final DeviceProvider? device;
  final CarModeProvider? car;
  final TabConfigProvider? tabs;
  final ShortcutConfigProvider? shortcuts;
  final PlayerProvider? player;
  final McpService? mcp;
  final GridColumnsProvider? gridColumns;
  final CommentDisplayProvider? commentDisplay;
  final CloudUploadProvider? cloudUpload;
  final LibraryProvider? library;

  Future<void> reset() async {
    if (!Platform.isWindows) return;
    // 启动读取/迁移必须先完成，否则它们可能在清空后重新写回旧配置。
    await Future.wait<void>([
      theme.windowsSettingsReady,
      if (device != null) device!.settingsReady,
      if (car != null) car!.settingsReady,
      if (tabs != null) tabs!.settingsReady,
      if (shortcuts != null) shortcuts!.settingsReady,
      if (player != null) player!.audioReady,
      if (mcp != null) mcp!.settingsReady,
      if (gridColumns != null) gridColumns!.settingsReady,
      if (commentDisplay != null) commentDisplay!.settingsReady,
      LyricPreferences.instance.load(),
      Md3LyricPreferences.instance.load(),
    ]);
    library?.prepareWindowsSettingsReset();
    cloudUpload?.prepareWindowsSettingsReset();
    final repo = SettingsRepository();
    await repo.resetAllSettingsToDefaults();
    await theme.reloadWindowsSettings();
    await device?.reloadWindowsSettings();
    await car?.reloadWindowsSettings();
    await tabs?.resetToDefault();
    await shortcuts?.resetToDefault();
    await LyricPreferences.instance.reset();
    await Md3LyricPreferences.instance.reset();
    await player?.reloadWindowsSettings();
    await mcp?.reloadWindowsSettings();
    await gridColumns?.reloadWindowsSettings();
    await commentDisplay?.reloadWindowsSettings();
    await cloudUpload?.reloadWindowsSettings();
    await library?.reloadWindowsSettings();
    await DesktopLyricService.instance.reloadWindowsSettings();

    kWindowsTwoPaneEnabled.value = await repo.getWindowsTwoPaneEnabled();
    kDesktopModeEnabled.value = await repo.getDesktopModeEnabled();
    kSecondaryPlayerEnabled.value = await repo.getSecondaryPlayerEnabled();
    kSecondaryPlayerProgressEnabled.value = await repo
        .getSecondaryPlayerProgress();
    kSecondaryPlayerOpacity.value = await repo.getSecondaryPlayerOpacity();
    kSecondaryPlayerOnPrimaryPages.value = await repo
        .getSecondaryPlayerOnPrimary();
    kHideNavBarOnSecondaryPages.value = await repo
        .getHideNavBarOnSecondaryPages();
    final isPad =
        device?.deviceType == DeviceType.pad ||
        (device?.deviceType != DeviceType.phone &&
            WidgetsBinding
                        .instance
                        .platformDispatcher
                        .views
                        .first
                        .physicalSize
                        .shortestSide /
                    WidgetsBinding
                        .instance
                        .platformDispatcher
                        .views
                        .first
                        .devicePixelRatio >=
                600);
    kSecondaryPlayerDock.value =
        SecondaryPlayerDockSide.tryParse(
          await repo.getSecondaryPlayerDockRaw(),
        ) ??
        (isPad
            ? SecondaryPlayerDockSide.right
            : SecondaryPlayerDockSide.center);
    SettingsRepository.lyricTimeOffsetMs.value = await repo
        .getLyricTimeOffset();
    kLandscapeImmersiveEnabled = await repo.getLandscapeImmersiveEnabled();
    DepthCoverService.enabledSignal.value = await repo.getDepthCoverEnabled();
    miniPlayerSwipeSwitchEnabled.value = await repo
        .getMiniPlayerSwipeSwitchEnabled();
    kSeekBarWaveEnabled.value = await repo.getSeekBarWaveEnabled();
    kCoverShadowIntensity.value = await repo.getCoverShadowStrength();
    kLandscapeDetachedControlsEnabled.value = await repo
        .getLandscapeDetachedControls();
    kSymmetricWidePaneEnabled.value = await repo.getSymmetricWidePane();
    kWidePaneMarginOverride.value = await repo.getWidePaneMargin();
    kWidePaneIgnoreCutoutEnabled.value = await repo.getWidePaneIgnoreCutout();
    kTopBarPillCollapseEnabled.value = await repo.getTopBarPillCollapse();
    kTopBarTabDotsEnabled.value = await repo.getTopBarTabDots();
    kPlaylistCoverTransitionEnabled.value = await repo
        .getPlaylistCoverTransitionEnabled();
    kCoverFlowSource.value = CoverFlowSource.tryParse(
      await repo.getCoverFlowSourceRaw(),
    );
    SettingsRepository.windowsLiveSettingsRevision.value++;
  }
}
