// 位置上报节流的平台差异契约测试。
//
// 钉死一条「改错了不会报错、只会让歌词不滚动」的规则：
//
// - **Android**：系统会按 elapsed 自己推进通知进度条（`PlaybackStateCompat` 传
//   `STATE_PLAYING` + position 后的既有行为），所以 30s 一次足够，勤推会让
//   SystemUI 高频重建媒体卡片（魅族等 ROM 实测卡顿）。
// - **Windows**：SMTC **不**自己推进时间轴，Position 就是最后一次
//   `UpdateTimelineProperties` 写进去的值。沿用 30s 会让播控中心、任务栏进度条
//   与第三方任务栏歌词工具看到「冻结 30 秒、猛跳一下」——按 Position 取歌词行的
//   工具会一直停在同一句，表现为「能识别歌曲、歌词不滚动」。
//
// 真机实测佐证（2026-11-02，Windows 本机枚举 SMTC）：
//   同一时刻采样 Playing + pos=68.89 → 21s 后仍 68.89 → 61s 后 129.13。
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/notification_position_gate.dart';

void main() {
  group('间隔选择', () {
    test('Windows 用 1s —— SMTC 不会自己推进时间轴', () {
      expect(
        notificationPositionInterval(platform: TargetPlatform.windows),
        kWindowsNotificationPositionInterval,
      );
      expect(kWindowsNotificationPositionInterval, const Duration(seconds: 1));
    });

    test('Android 保持 30s —— 系统会按 elapsed 外推', () {
      for (final p in [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.linux,
        TargetPlatform.fuchsia,
      ]) {
        expect(
          notificationPositionInterval(platform: p),
          kDefaultNotificationPositionInterval,
          reason: '$p 不该用 Windows 的间隔',
        );
      }
    });

    test('Web 走默认间隔（没有原生媒体会话）', () {
      expect(
        notificationPositionInterval(isWeb: true),
        kDefaultNotificationPositionInterval,
      );
    });
  });

  group('是否该推', () {
    final t0 = DateTime(2026, 11, 2, 14, 0, 0);

    test('暂停一律不推（暂停瞬间已由 playingStream(false) 推过终态）', () {
      expect(
        shouldPushNotificationPosition(
          isPlaying: false,
          lastPush: null,
          now: t0,
          platform: TargetPlatform.windows,
        ),
        isFalse,
      );
      expect(
        shouldPushNotificationPosition(
          isPlaying: false,
          lastPush: t0.subtract(const Duration(hours: 1)),
          now: t0,
          platform: TargetPlatform.windows,
        ),
        isFalse,
      );
    });

    test('从未推过时立即推（起播/恢复的首帧就要有基线）', () {
      for (final p in [TargetPlatform.windows, TargetPlatform.android]) {
        expect(
          shouldPushNotificationPosition(
            isPlaying: true,
            lastPush: null,
            now: t0,
            platform: p,
          ),
          isTrue,
          reason: '$p 首次必须立即推',
        );
      }
    });

    test('Windows：1s 后就能再推（位置必须持续可见地前进）', () {
      expect(
        shouldPushNotificationPosition(
          isPlaying: true,
          lastPush: t0,
          now: t0.add(const Duration(seconds: 1)),
          platform: TargetPlatform.windows,
        ),
        isTrue,
      );
      // 500ms 还不推（1s 是下限，避免 200ms 的 positionStream 每次都推）
      expect(
        shouldPushNotificationPosition(
          isPlaying: true,
          lastPush: t0,
          now: t0.add(const Duration(milliseconds: 500)),
          platform: TargetPlatform.windows,
        ),
        isFalse,
      );
    });

    test('Android：29s 内不推、30s 才推', () {
      expect(
        shouldPushNotificationPosition(
          isPlaying: true,
          lastPush: t0,
          now: t0.add(const Duration(seconds: 29)),
          platform: TargetPlatform.android,
        ),
        isFalse,
      );
      expect(
        shouldPushNotificationPosition(
          isPlaying: true,
          lastPush: t0,
          now: t0.add(const Duration(seconds: 30)),
          platform: TargetPlatform.android,
        ),
        isTrue,
      );
    });

    test('同一时刻：Windows 推而 Android 不推（这正是本条教训的核心）', () {
      final now = t0.add(const Duration(seconds: 2));
      expect(
        shouldPushNotificationPosition(
          isPlaying: true,
          lastPush: t0,
          now: now,
          platform: TargetPlatform.windows,
        ),
        isTrue,
      );
      expect(
        shouldPushNotificationPosition(
          isPlaying: true,
          lastPush: t0,
          now: now,
          platform: TargetPlatform.android,
        ),
        isFalse,
      );
    });

    test('显式 interval 覆盖平台默认（便于将来按场景细分）', () {
      expect(
        shouldPushNotificationPosition(
          isPlaying: true,
          lastPush: t0,
          now: t0.add(const Duration(milliseconds: 600)),
          interval: const Duration(milliseconds: 500),
          platform: TargetPlatform.android,
        ),
        isTrue,
      );
    });
  });
}
