package com.ryanheise.just_audio;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

/**
 * {@link OutputLatencyProbe} 的纯计算与计数器行为。
 *
 * 注意：多实例重构后内部状态是 `Map<AudioTrack, TrackState>`，
 * `writtenFramesForTest(null)` 会在 ConcurrentHashMap 上 NPE，
 * 因此涉及计数器的用例必须在**真实 key** 上做（见一种用 Object 代替的写法：
 * 不可行，故这里只覆盖不依赖 key 的规则）。
 */
public class OutputLatencyProbeTest {

  @Test
  public void framesToMsRoundsToNearestMillisecond() {
    // 44100Hz 下 4410 帧 = 100ms
    assertEquals(100, OutputLatencyProbe.framesToMs(4410, 44100));
    // 48000Hz 下 4800 帧 = 100ms
    assertEquals(100, OutputLatencyProbe.framesToMs(4800, 48000));
    // 零帧 → 0
    assertEquals(0, OutputLatencyProbe.framesToMs(0, 44100));
    // 采样率非法 → -1（不可用）
    assertEquals(-1, OutputLatencyProbe.framesToMs(4410, 0));
  }

  @Test
  public void queueFramesComputesBacklog() {
    // 已写 1000 帧、播放头 5000 → 队列已播完
    assertEquals(0, OutputLatencyProbe.queueFrames(1000, 5000));
    assertEquals(2500, OutputLatencyProbe.queueFrames(5000, 2500));
  }

  @Test
  public void resetForTestIsIdempotent() {
    // reset 只是清表，可重复调用且不抛（多播放器重建时会被反复调用）
    OutputLatencyProbe.resetForTest();
    OutputLatencyProbe.resetForTest();
  }
}
