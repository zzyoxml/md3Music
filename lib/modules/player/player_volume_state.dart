import '../../core/services/device_capabilities.dart';
import '../../core/services/direct_pcm_service.dart';
import '../../core/services/output_mode_coordinator.dart';
import '../../core/services/usb_audio_service.dart';
import '../../providers/player_provider.dart';

/// 音量三态的单一真值：长按音质徽章的弹窗与横屏控制页的常驻音量条共用，
/// 保证两处行为与文案不再分叉（此前 AM 版弹窗缺 unity 分支，unity 档下滑块失灵）。
/// 判据口径与 AGENTS §4.11「音量面板三态」一致。
enum PlayerVolumeSource { app, usbExclusive, unityLocked }

class PlayerVolumeState {
  const PlayerVolumeState({required this.source, required this.value});

  final PlayerVolumeSource source;

  /// 0..1。unityLocked 时为应用音量（实际输出恒 1.0，仅用于展示禁用态滑块）。
  final double value;

  bool get interactive => source != PlayerVolumeSource.unityLocked;

  /// unity 档的徽标文案单一来源（弹窗 notice 与常驻音量条共用）。
  static String get unityChipLabel => '系统音量控制中';

  /// unity 档的提示文案单一来源（弹窗 notice 与常驻音量条共用）。
  static String get unityHintLabel =>
      'Direct PCM（unity 音量）下应用音量固定为 100%，请用系统媒体音量键调节。';

  /// 模式徽标文案（与原弹窗一致）。
  String get chipLabel => switch (source) {
    PlayerVolumeSource.usbExclusive => 'USB 独占音量',
    PlayerVolumeSource.unityLocked => unityChipLabel,
    PlayerVolumeSource.app => '应用音量',
  };

  /// 底部说明文案（与原弹窗一致）。
  String get hintLabel => switch (source) {
    PlayerVolumeSource.usbExclusive => '与设置页「USB 音量」同步',
    PlayerVolumeSource.unityLocked => unityHintLabel,
    PlayerVolumeSource.app => '普通播放音量（重启后保留）',
  };

  /// 生产入口：从各单例读判据。
  factory PlayerVolumeState.of(PlayerProvider player) {
    final UsbAudioService usb = UsbAudioService.instance;
    final bool usbEnabled = usb.lastStatus['enabled'] == true;
    return PlayerVolumeState.resolve(
      appVolume: player.volume,
      usbEnabled: usbEnabled,
      usbVolumePercent: usb.usbVolumePercent,
      unityLocked:
          !usbEnabled && OutputModeCoordinator.instance.forceUnityVolume,
    );
  }

  /// 纯函数（可单测）：四参全显式，生产经 [PlayerVolumeState.of] 调用。
  /// 优先级：USB 独占 > unity 锁定 > 应用音量。
  static PlayerVolumeState resolve({
    required double appVolume,
    required bool usbEnabled,
    required double usbVolumePercent,
    required bool unityLocked,
  }) {
    if (usbEnabled) {
      return PlayerVolumeState(
        source: PlayerVolumeSource.usbExclusive,
        value: (usbVolumePercent / 100).clamp(0.0, 1.0),
      );
    }
    if (unityLocked) {
      return PlayerVolumeState(
        source: PlayerVolumeSource.unityLocked,
        value: appVolume.clamp(0.0, 1.0),
      );
    }
    return PlayerVolumeState(
      source: PlayerVolumeSource.app,
      value: appVolume.clamp(0.0, 1.0),
    );
  }

  /// 拖动/落盘下发：USB 走 setUsbVolume、应用走 player.setVolume；
  /// unityLocked 不可交互，调用是 no-op（滑块已被禁用，正常到不了这里）。
  /// [persist] 透传：拖动中传 false（跳过磁盘写），松手传 true。
  Future<void> apply(
    PlayerProvider player,
    double value, {
    bool persist = true,
  }) async {
    switch (source) {
      case PlayerVolumeSource.usbExclusive:
        await UsbAudioService.instance.setUsbVolume(
          value * 100,
          persist: persist,
        );
      case PlayerVolumeSource.app:
        await player.setVolume(value, persist: persist);
      case PlayerVolumeSource.unityLocked:
        break;
    }
  }

  /// unity 档的一键出口（语义与 MD 弹窗既有按钮一致）：关闭该档后恢复应用内滑块。
  /// 不依赖实例状态，[PlayerVolumeUnityNotice] 的按钮也走这里。
  static Future<void> disableUnityVolume() => DirectPcmService.instance
      .setFeature(DirectPcmFeature.unityVolume, false);

  @override
  bool operator ==(Object other) =>
      other is PlayerVolumeState &&
      other.source == source &&
      other.value == value;

  @override
  int get hashCode => Object.hash(source, value);
}
