import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/modules/player/player_volume_state.dart';

/// [PlayerVolumeState.resolve] 真值表（纯逻辑单测，不触任何插件/单例）。
///
/// 只 import player_volume_state.dart 本身 —— 该文件的 `.of`/`apply`/`disableUnityVolume`
/// 会触达 MethodChannel/Provider 单例，均不在本测试路径上；`resolve` 为纯函数。
void main() {
  group('PlayerVolumeState.resolve 三态真值表', () {
    test('usbEnabled=true → usbExclusive，value = usbVolumePercent/100', () {
      expect(
        PlayerVolumeState.resolve(
          appVolume: 0.4,
          usbEnabled: true,
          usbVolumePercent: 0,
          unityLocked: false,
        ),
        const PlayerVolumeState(
          source: PlayerVolumeSource.usbExclusive,
          value: 0.0,
        ),
      );
      expect(
        PlayerVolumeState.resolve(
          appVolume: 0.4,
          usbEnabled: true,
          usbVolumePercent: 50,
          unityLocked: false,
        ),
        const PlayerVolumeState(
          source: PlayerVolumeSource.usbExclusive,
          value: 0.5,
        ),
      );
      expect(
        PlayerVolumeState.resolve(
          appVolume: 0.4,
          usbEnabled: true,
          usbVolumePercent: 100,
          unityLocked: false,
        ),
        const PlayerVolumeState(
          source: PlayerVolumeSource.usbExclusive,
          value: 1.0,
        ),
      );
    });

    test('usbEnabled=true 且 usbVolumePercent 超界 → clamp 到 0..1', () {
      expect(
        PlayerVolumeState.resolve(
          appVolume: 0.4,
          usbEnabled: true,
          usbVolumePercent: 150,
          unityLocked: false,
        ).value,
        1.0,
      );
      expect(
        PlayerVolumeState.resolve(
          appVolume: 0.4,
          usbEnabled: true,
          usbVolumePercent: -20,
          unityLocked: false,
        ).value,
        0.0,
      );
    });

    test('usbEnabled=true 优先于 unityLocked（独占压过 unity）', () {
      final PlayerVolumeState state = PlayerVolumeState.resolve(
        appVolume: 0.3,
        usbEnabled: true,
        usbVolumePercent: 60,
        unityLocked: true,
      );
      expect(state.source, PlayerVolumeSource.usbExclusive);
      expect(state.interactive, isTrue);
    });

    test('usbEnabled=false + unityLocked=true → unityLocked，value=appVolume', () {
      final PlayerVolumeState state = PlayerVolumeState.resolve(
        appVolume: 0.37,
        usbEnabled: false,
        usbVolumePercent: 100,
        unityLocked: true,
      );
      expect(state.source, PlayerVolumeSource.unityLocked);
      expect(state.value, 0.37);
      expect(state.interactive, isFalse);
      expect(state.chipLabel, '系统音量控制中');
    });

    test('usbEnabled=false + unityLocked=false → app，value=appVolume', () {
      final PlayerVolumeState state = PlayerVolumeState.resolve(
        appVolume: 0.72,
        usbEnabled: false,
        usbVolumePercent: 100,
        unityLocked: false,
      );
      expect(state.source, PlayerVolumeSource.app);
      expect(state.value, 0.72);
      expect(state.interactive, isTrue);
      expect(state.hintLabel, contains('重启后保留'));
    });

    test('appVolume 超界同样 clamp 到 0..1（app 与 unity 两态）', () {
      expect(
        PlayerVolumeState.resolve(
          appVolume: 1.5,
          usbEnabled: false,
          usbVolumePercent: 100,
          unityLocked: false,
        ).value,
        1.0,
      );
      expect(
        PlayerVolumeState.resolve(
          appVolume: -0.5,
          usbEnabled: false,
          usbVolumePercent: 100,
          unityLocked: true,
        ).value,
        0.0,
      );
    });
  });

  group('PlayerVolumeState 文案', () {
    test('chipLabel 三态文案与原弹窗一致', () {
      expect(
        const PlayerVolumeState(
          source: PlayerVolumeSource.usbExclusive,
          value: 1,
        ).chipLabel,
        'USB 独占音量',
      );
      expect(
        const PlayerVolumeState(
          source: PlayerVolumeSource.unityLocked,
          value: 1,
        ).chipLabel,
        '系统音量控制中',
      );
      expect(
        const PlayerVolumeState(source: PlayerVolumeSource.app, value: 1)
            .chipLabel,
        '应用音量',
      );
    });

    test('hintLabel 三态文案与原弹窗一致', () {
      expect(
        const PlayerVolumeState(
          source: PlayerVolumeSource.usbExclusive,
          value: 1,
        ).hintLabel,
        '与设置页「USB 音量」同步',
      );
      expect(
        const PlayerVolumeState(
          source: PlayerVolumeSource.unityLocked,
          value: 1,
        ).hintLabel,
        'Direct PCM（unity 音量）下应用音量固定为 100%，请用系统媒体音量键调节。',
      );
      expect(
        const PlayerVolumeState(source: PlayerVolumeSource.app, value: 1)
            .hintLabel,
        '普通播放音量（重启后保留）',
      );
    });
  });
}
