import 'package:md3music/core/services/desktop_lyric_service.dart';
import 'package:md3music/core/services/equalizer_service.dart';
import 'package:md3music/core/services/output_mode_coordinator.dart';
import 'package:md3music/modules/mcp/mcp_ports.dart';
import 'package:md3music/providers/player_provider.dart';

/// [McpAppFeaturesPort] 的真实实现。
/// 睡眠定时走 PlayerProvider；其余走三个单例服务。
class PlayerProviderBackedAppFeatures implements McpAppFeaturesPort {
  PlayerProviderBackedAppFeatures(this._player);

  final PlayerProvider _player;

  @override
  McpAppFeaturesSnapshot snapshot() {
    final mode = switch (_player.sleepTimerMode) {
      SleepTimerMode.countdown => 'countdown',
      SleepTimerMode.endOfTrack => 'end_of_track',
      SleepTimerMode.off => 'off',
    };
    final coordinator = OutputModeCoordinator.instance;
    final outputMode = coordinator.isUsbdevfsActive
        ? 'usbdevfs'
        : coordinator.isDirectPcmActive
            ? 'direct_pcm'
            : 'system';
    return McpAppFeaturesSnapshot(
      sleepTimerMode: mode,
      sleepTimerRemainingMs: _player.sleepTimerRemaining?.inMilliseconds,
      eqEnabled: EqualizerService.instance.enabled,
      eqPresets: EqualizerService.instance.allPresetNames,
      desktopLyricEnabled: DesktopLyricService.instance.enabled,
      outputMode: outputMode,
      usbDeviceAvailable: coordinator.usbDeviceAvailable,
    );
  }

  @override
  Future<void> setSleepTimer(Duration? duration) =>
      Future<void>.sync(() => _player.setSleepTimer(duration));

  @override
  Future<void> setEqEnabled(bool enabled) =>
      EqualizerService.instance.setEnabled(enabled);

  @override
  Future<void> applyEqPreset(String name) =>
      EqualizerService.instance.applyPreset(name);

  @override
  Future<void> setDesktopLyric(bool enabled) async {
    if (DesktopLyricService.instance.enabled == enabled) return;
    await DesktopLyricService.instance.toggle();
  }
}
