import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/services/kugou_api/listen_together_models.dart';

/// 一起听「跟随起播位置」回归。
///
/// 已修复缺陷：进入他人房间后从 0 开始播放，必须手动暂停再播放才会跟随
/// 房主进度。根因是起播位置**没有随播放源交给播放器**。
///
/// 关键机制（决定了修复方式，勿改回「加载后 seek」）：
/// `just_audio.seek()` 在 `ProcessingState.loading` 时**直接 return 静默丢弃**
/// （见 third_party/just_audio `seek()` 的 switch 分支）。因此：
///   1. 在 `playSong()` 返回后自行 seek —— 那时多半还在 loading → 丢弃；
///   2. 「轮询等 ready 再 seek」—— Media3 未播放时不保证进入 ready，
///      轮询超时后仍在 loading → 仍丢弃（这就是「有概率」的来源）。
/// 唯一可靠的做法是把位置作为 `setAudioSource(initialPosition:)` 传给平台层，
/// 在 prepare 阶段一次性定位，不存在竞态。
///
/// 本组用例锁定 [roomStartSeekTarget] 的判据：它决定起播要不要带定位目标。
PlayerSyncState remote({
  String hash = '9c719c80',
  bool isPlaying = true,
  int progressMs = 0,
  int updatedAtMs = 1000000,
}) =>
    PlayerSyncState(
      hash: hash,
      originalHash: '',
      mixSongId: '123456',
      isPlaying: isPlaying,
      progressMs: progressMs,
      durationMs: 219000,
      listVersion: '',
      updatedAtMs: updatedAtMs,
    );

void main() {
  group('roomStartSeekTarget — 跟随起播位置判定', () {
    test('房主播到 1 分钟时进房：应给出对齐目标', () {
      // updatedAt = now → 无时间推进，投影即 progressMs
      final target = roomStartSeekTarget(
        remote(progressMs: 60000),
        nowMs: 1000000,
      );
      expect(target, const Duration(milliseconds: 60000));
    });

    test('关键回归：播放中进房，投影须含 updatedAt 到 now 的推进量', () {
      // 快照停在 60s，10s 后才被消费 → 应对齐到 70s，而非 60s
      final target = roomStartSeekTarget(
        remote(progressMs: 60000, updatedAtMs: 1000000),
        nowMs: 1010000,
      );
      expect(target, const Duration(milliseconds: 70000));
    });

    test('房主暂停在 90s 时进房：投影不推进，仍对齐 90s', () {
      final target = roomStartSeekTarget(
        remote(isPlaying: false, progressMs: 90000, updatedAtMs: 1000000),
        nowMs: 1050000,
      );
      expect(target, const Duration(milliseconds: 90000));
    });

    test('房主刚起播（进度 0）：返回 null，表示从头播不用 seek', () {
      final target = roomStartSeekTarget(
        remote(progressMs: 0),
        nowMs: 1000000,
      );
      expect(target, isNull);
    });

    test('进度在阈值内（1000ms）：仍视为从头播，返回 null', () {
      final target = roomStartSeekTarget(
        remote(progressMs: 1000),
        nowMs: 1000000,
      );
      expect(target, isNull);
    });

    test('刚好越过阈值：给出对齐目标', () {
      final target = roomStartSeekTarget(
        remote(progressMs: 1001),
        nowMs: 1000000,
      );
      expect(target, const Duration(milliseconds: 1001));
    });

    test('自定义阈值生效', () {
      final target = roomStartSeekTarget(
        remote(progressMs: 3000),
        nowMs: 1000000,
        thresholdMs: 5000,
      );
      expect(target, isNull);
    });

    test('暂停且进度为 0：返回 null', () {
      final target = roomStartSeekTarget(
        remote(isPlaying: false, progressMs: 0),
        nowMs: 1000000,
      );
      expect(target, isNull);
    });

    test('updatedAt 在未来（时钟回拨）：推进量不倒退，取 progressMs 原值', () {
      // elapsed 为负 → projectRemotePosition 不加推进，保留 progressMs
      final target = roomStartSeekTarget(
        remote(progressMs: 30000, updatedAtMs: 1005000),
        nowMs: 1000000,
      );
      expect(target, const Duration(milliseconds: 30000));
    });
  });
}
