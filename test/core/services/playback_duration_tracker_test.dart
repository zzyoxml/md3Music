import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/playback_duration_tracker.dart';

/// [PlaybackDurationTracker] 单测：验证 CSCC `duration` 语义
/// （墙钟累计、扣除暂停、拖动不计时、切歌隐式结账）。
///
/// 时间源完全注入，测试不依赖真实时间。
void main() {
  /// 可控时间源：`elapse(ms)` 推进时钟。
  late int now;
  late PlaybackDurationTracker tracker;

  setUp(() {
    now = 1000000;
    tracker = PlaybackDurationTracker(nowMillis: () => now);
  });

  void elapse(int ms) => now += ms;

  group('基础计时', () {
    test('未开始时 isTracking=false 且 end 返回 null', () {
      expect(tracker.isTracking, isFalse);
      expect(tracker.songId, isNull);
      expect(tracker.end(), isNull);
    });

    test('start 后持续播放：时长 = 墙钟差', () {
      tracker.start(songId: 's1', mixsongid: 'm1');
      expect(tracker.isTracking, isTrue);
      expect(tracker.songId, 's1');

      elapse(30000);
      final seg = tracker.end();

      expect(seg, isNotNull);
      expect(seg!.songId, 's1');
      expect(seg.mixsongid, 'm1');
      expect(seg.durationMs, 30000);
      expect(seg.reason, PlaybackEndReason.completed);
      // end 之后回到未跟踪态
      expect(tracker.isTracking, isFalse);
    });

    test('end 时若仍在播放，先并入正在跑的一段', () {
      tracker.start(songId: 's1', mixsongid: 'm1');
      elapse(10000);
      final seg = tracker.end();
      expect(seg!.durationMs, 10000);
    });
  });

  group('暂停不累计', () {
    test('播放 10s → 暂停 60s → 再播 5s：只累计 15s', () {
      tracker.start(songId: 's1', mixsongid: 'm1');
      elapse(10000); // 播放 10s
      tracker.setPlaying(false);
      elapse(60000); // 暂停 60s 不计
      tracker.setPlaying(true);
      elapse(5000); // 再播 5s
      final seg = tracker.end();

      expect(seg!.durationMs, 15000);
    });

    test('重复同态调用是幂等的（不会重复计入）', () {
      tracker.start(songId: 's1', mixsongid: 'm1');
      elapse(4000);
      tracker.setPlaying(false);
      tracker.setPlaying(false); // 重复暂停
      elapse(9000); // 暂停期间
      tracker.setPlaying(true);
      tracker.setPlaying(true); // 重复恢复
      elapse(6000);
      final seg = tracker.end();

      expect(seg!.durationMs, 10000); // 4s + 6s
    });

    test('暂停中直接 end：累计到暂停那一刻为止', () {
      tracker.start(songId: 's1', mixsongid: 'm1');
      elapse(7000);
      tracker.setPlaying(false);
      elapse(20000); // 暂停期间
      final seg = tracker.end();

      expect(seg!.durationMs, 7000);
    });

    test('未开始时 setPlaying 不产生副作用', () {
      tracker.setPlaying(true);
      elapse(5000);
      tracker.setPlaying(false);
      expect(tracker.isTracking, isFalse);
      expect(tracker.end(), isNull);
    });
  });

  group('拖动不计时', () {
    test('seek 不增加时长，只重置起表基准', () {
      tracker.start(songId: 's1', mixsongid: 'm1');
      elapse(5000);
      tracker.onSeek(); // 拖动（USB 独占下可能耗时数百 ms）
      elapse(300);
      tracker.onSeek();
      elapse(2000);
      final seg = tracker.end();

      // 墙钟从 start 到 end 共 7300ms，全部计入（seek 本身不跳表）
      expect(seg!.durationMs, 7300);
    });

    test('暂停期间 seek 不改变状态（仍为暂停）', () {
      tracker.start(songId: 's1', mixsongid: 'm1');
      elapse(3000);
      tracker.setPlaying(false);
      elapse(1000);
      tracker.onSeek(); // 暂停中拖动，不应起表
      elapse(50000);
      final seg = tracker.end();

      expect(seg!.durationMs, 3000);
    });

    test('未开始时 seek 无副作用', () {
      tracker.onSeek();
      elapse(1000);
      expect(tracker.end(), isNull);
    });
  });

  group('切歌结账（snapshot + start）', () {
    test('snapshot 取出被替代的段，且新段时长独立', () {
      tracker.start(songId: 's1', mixsongid: 'm1');
      elapse(20000);
      final superseded = tracker.snapshot();
      tracker.start(songId: 's2', mixsongid: 'm2');

      expect(superseded, isNotNull);
      expect(superseded!.songId, 's1');
      expect(superseded.durationMs, 20000);
      expect(superseded.reason, PlaybackEndReason.switched);

      elapse(8000);
      final seg = tracker.end();
      expect(seg!.songId, 's2');
      expect(seg.durationMs, 8000);
    });

    test('snapshot 无进行段时返回 null', () {
      expect(tracker.snapshot(), isNull);
    });

    test('切歌后新段不继承前一首的暂停态（显式 playing 决定起表）', () {
      tracker.start(songId: 's1', mixsongid: 'm1');
      elapse(5000);
      tracker.setPlaying(false); // 暂停中切歌
      elapse(1000);
      final superseded = tracker.snapshot();

      expect(superseded!.durationMs, 5000);
      // 新段显式 playing=true → 立刻起表
      tracker.start(songId: 's2', mixsongid: 'm2', playing: true);
      elapse(4000);
      final seg = tracker.end();
      expect(seg!.durationMs, 4000);
    });

    test('切歌后新段显式 playing=false → 不起表（缓冲不计时）', () {
      tracker.start(songId: 's1', mixsongid: 'm1');
      elapse(5000);
      tracker.snapshot();
      tracker.start(songId: 's2', mixsongid: 'm2', playing: false);
      elapse(4000); // 缓冲期
      expect(tracker.end()!.durationMs, 0);
    });

    test('同一 id 重复 start 需调用方按 id 去重（本类不做判定）', () {
      tracker.start(songId: 's1', mixsongid: 'm1');
      elapse(12000);
      final superseded = tracker.snapshot();
      expect(superseded!.durationMs, 12000);
    });
  });

  group('playing=false 不起表（真机首测 duration 偏大的修复）', () {
    test('start(playing:false) 后墙钟流逝不计入', () {
      tracker.start(songId: 's1', mixsongid: 'm1', playing: false);
      // 切歌缓冲期：即使过了 6 分钟也不该计入（复现 392555ms 缺陷）
      elapse(392555);
      final seg = tracker.end();
      expect(seg!.durationMs, 0);
    });

    test('start(playing:false) 后 setPlaying(true) 才开始计时', () {
      tracker.start(songId: 's1', mixsongid: 'm1', playing: false);
      elapse(3000); // 缓冲 3s，不计
      tracker.setPlaying(true);
      elapse(20000);
      final seg = tracker.end();
      expect(seg!.durationMs, 20000); // 只算真正出声的 20s
    });

    test('start 默认 playing=true，行为与旧版一致', () {
      tracker.start(songId: 's1', mixsongid: 'm1');
      elapse(9000);
      expect(tracker.end()!.durationMs, 9000);
    });

    test('playing:false 时 seek 不起表', () {
      tracker.start(songId: 's1', mixsongid: 'm1', playing: false);
      tracker.onSeek();
      elapse(5000);
      expect(tracker.end()!.durationMs, 0);
    });
  });

  group('discard', () {
    test('discard 后不上报且状态清空', () {
      tracker.start(songId: 's1', mixsongid: 'm1');
      elapse(40000);
      tracker.discard();

      expect(tracker.isTracking, isFalse);
      expect(tracker.songId, isNull);
      expect(tracker.end(), isNull);
    });

    test('discard 后可重新 start，时长从 0 起算', () {
      tracker.start(songId: 's1', mixsongid: 'm1');
      elapse(40000);
      tracker.discard();
      tracker.start(songId: 's2', mixsongid: 'm2');
      elapse(6000);
      expect(tracker.end()!.durationMs, 6000);
    });
  });

  group('上报门槛', () {
    test('reachesThreshold 按 >= 判定', () {
      const seg = PlaybackSegment(
        songId: 's',
        mixsongid: 'm',
        durationMs: 15000,
        reason: PlaybackEndReason.completed,
      );
      expect(seg.reachesThreshold(15000), isTrue);
      expect(seg.reachesThreshold(15001), isFalse);
    });
  });

  group('结束原因 → state 文案', () {
    test('三种原因映射固定中文枚举', () {
      expect(PlaybackEndReason.completed.state, '完整播放');
      expect(PlaybackEndReason.switched.state, '切换下一首');
      expect(PlaybackEndReason.stopped.state, '手动停止');
    });

    test('切歌结账的 state 是「切换下一首」', () {
      tracker.start(songId: 's1', mixsongid: 'm1');
      elapse(20000);
      final superseded = tracker.snapshot();
      expect(superseded!.reason.state, '切换下一首');
    });
  });
}
