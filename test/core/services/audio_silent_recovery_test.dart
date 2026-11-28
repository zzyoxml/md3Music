import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/audio_service_io.dart';

/// issue #254 无声残留态的回归钉。
///
/// 现场（Android 8.0 / MT6737M 小屏手表）：暂停或切歌之后出现 playing=true、
/// 进度条在走，但系统侧没有任何活跃 AudioTrack；反复点 resume 也修不回来，
/// 只有 force-stop 能恢复一次。
///
/// 审查确认的 Dart 侧真实成因之一：
/// `abortCrossfade(keepVolume: true)`（由 pause()/stop() 触发）**故意**跳过音量
/// 恢复，以免在暂停前让音量先弹上去；但此后没有任何补写 —— 而 PlayerProvider
/// 的恢复淡入只在「暂停淡入淡出」开启时才写音量，该开关默认关闭。
/// 结果：活动播放器永久停在斜坡低值甚至 0，声音没了，UI 状态却全是「在播」。
///
/// 修复方式：暂停/停止**已经生效之后**（此时写音量不可闻）把目标音量补回去。
/// 唯一必须保持沉默的时刻是交叉淡化斜坡推进中 —— 斜坡与外部 setVolume 抢同一
/// 个通道正是切歌爆音 / 音量忽大忽小的来源（见 startCrossfade 的 VolAudit）。
void main() {
  group('issue #254 · 静音后补写音量', () {
    test('非淡化状态下允许补写（pause/stop 之后必须恢复目标音量）', () {
      expect(canRestoreVolumeAfterSilence(crossfading: false), isTrue);
    });

    test('交叉淡化斜坡进行中禁止补写（不与斜坡抢 setVolume 通道）', () {
      expect(
        canRestoreVolumeAfterSilence(crossfading: true),
        isFalse,
        reason: '淡化中写音量会造成斜坡被覆盖 → 切歌爆音/音量忽大忽小',
      );
    });
  });
}
