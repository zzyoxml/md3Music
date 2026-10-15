package com.ryanheise.just_audio;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

/** {@link OutputLatencyProbe} 的纯计算与计数器行为。 */
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
  public void queueFramesClampsNegativeToZero() {
    // flush 后播放头回退：负差值必须夹到 0，而不是返回巨大正数
    assertEquals(0, OutputLatencyProbe.queueFrames(1000, 5000));
    assertEquals(2500, OutputLatencyProbe.queueFrames(5000, 2500));
  }

  @Test
  public void writtenBytesAccumulateIntoFrames() {
    OutputLatencyProbe.resetForTest();
    // bytesPerFrame=4（立体声 16bit）：1000+2000+3000 字节 = 6000/4 = 1500 帧
    OutputLatencyProbe.attachForTest(null, 4);
    OutputLatencyProbe.onBytesWrittenForTest(null, 1000);
    OutputLatencyProbe.onBytesWrittenForTest(null, 2000);
    OutputLatencyProbe.onBytesWrittenForTest(null, 3000);
    assertEquals(1500, OutputLatencyProbe.writtenFramesForTest());

    // 写入失败/0 字节不计
    OutputLatencyProbe.onBytesWrittenForTest(null, 0);
    OutputLatencyProbe.onBytesWrittenForTest(null, -5);
    assertEquals(1500, OutputLatencyProbe.writtenFramesForTest());
  }

  @Test
  public void staleTrackWritesAreDiscarded() {
    OutputLatencyProbe.resetForTest();
    OutputLatencyProbe.attachForTest(null, 4);
    // track=null 时只有 null 写入才计入；非 null 的 track 一律丢弃
    OutputLatencyProbe.onBytesWrittenForTest(null, 400);
    assertEquals(100, OutputLatencyProbe.writtenFramesForTest());
  }
}
