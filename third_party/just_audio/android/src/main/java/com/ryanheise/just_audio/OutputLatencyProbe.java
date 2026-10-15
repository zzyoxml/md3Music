package com.ryanheise.just_audio;

import androidx.annotation.VisibleForTesting;
import android.media.AudioTimestamp;
import android.media.AudioTrack;
import android.os.Build;

/**
 * 输出链路延迟探针：量化「PCM 写进 AudioTrack」到「播放头走到这段 PCM」之间的排队深度。
 *
 * <p>为什么需要它：频谱/节奏分析发生在 ExoPlayer 渲染线程把 PCM **交给 sink** 的那一刻，
 * 而声音要等 AudioTrack 里排队的部分放完才被听见。于是「检测到的鼓点」比「听到的鼓点」
 * 早了一整个排队深度（本机实测手调补偿约 580ms）。这个量可以精确测出来，
 * 不必每台设备手调。
 *
 * <p>测不到的部分：渲染器/音频处理器链与 HAL/设备输出延迟在播放头**上游**，
 * 由 Dart 侧的 {@code upstreamLatencyBudgetMs} 常量吸收。
 *
 * <p>无状态可测：所有算术都在包可见的纯函数里，{@link AudioTrack} 只在
 * {@link #queuedLatencyMs()} 里被动读取，因此 JVM 单测不需要真实音频设备。
 */
public final class OutputLatencyProbe {

  /** 排队深度超过这个秒数即判定计数器错位：宁可报"不可用"，不报离谱值。 */
  private static final long MAX_PLAUSIBLE_MS = 10_000L;

  private static final Object LOCK = new Object();

  private static AudioTrack track;
  /** 每 PCM 帧字节数（声道数 × 每样本字节），用于字节→帧换算。 */
  private static int bytesPerFrame = 1;
  /** 自当前 track 挂载以来、真正写入成功的帧数。 */
  private static long writtenFrames;

  private OutputLatencyProbe() {}

  /** 在 AudioTrack 创建后调用。{@code bytesPerPcmFrame} 取 configuration.outputPcmFrameSize。 */
  public static void attach(AudioTrack audioTrack, int bytesPerPcmFrame) {
    if (audioTrack == null) {
      return;
    }
    synchronized (LOCK) {
      track = audioTrack;
      bytesPerFrame = Math.max(1, bytesPerPcmFrame);
      writtenFrames = 0;
    }
  }

  /** 在 AudioTrack 释放前调用。 */
  public static void detach() {
    synchronized (LOCK) {
      track = null;
      bytesPerFrame = 1;
      writtenFrames = 0;
    }
  }

  /**
   * 记录一次**真正写入成功**的字节数（AudioTrack.write 的返回值 &gt; 0 时调用）。
   *
   * <p>非当前 track 的写入直接丢弃：轨道重建时旧 track 仍可能有尾巴写入。
   */
  public static void onBytesWritten(AudioTrack audioTrack, int bytesWritten) {
    if (audioTrack == null || bytesWritten <= 0) {
      return;
    }
    synchronized (LOCK) {
      if (track != audioTrack) {
        return;
      }
      writtenFrames += bytesWritten / bytesPerFrame;
    }
  }

  /**
   * 当前排队深度（毫秒）。
   *
   * @return 不可用时返回 -1：没有挂载 track、API &lt; 24、时间戳取失败、采样率非法，
   *     或计数器明显错位（超过 {@link #MAX_PLAUSIBLE_MS}）。
   */
  public static int queuedLatencyMs() {
    final AudioTrack current;
    final long written;
    synchronized (LOCK) {
      current = track;
      written = writtenFrames;
    }
    if (current == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
      return -1;
    }
    final int sampleRate;
    try {
      sampleRate = current.getSampleRate();
    } catch (Throwable t) {
      return -1;
    }
    if (sampleRate <= 0) {
      return -1;
    }
    final AudioTimestamp timestamp = new AudioTimestamp();
    try {
      // AudioTrack.getTimestamp 返回 boolean（成功常量在 AudioTrack 上，不在 AudioTimestamp 上）
      if (!current.getTimestamp(timestamp)) {
        return -1;
      }
    } catch (Throwable t) {
      return -1;
    }
    final long queued = queueFrames(written, timestamp.framePosition);
    if (queued == 0 && written < timestamp.framePosition) {
      // 发生过 flush / 轨道重建：播放头回退过，以它为基准重新对齐计数
      rebase(current, timestamp.framePosition);
    }
    final long ms = framesToMs(queued, sampleRate);
    if (ms < 0 || ms > MAX_PLAUSIBLE_MS) {
      if (ms > MAX_PLAUSIBLE_MS) {
        rebase(current, timestamp.framePosition);
      }
      return -1;
    }
    return (int) ms;
  }

  /** 排队帧数 = 写入 − 播放；负值夹到 0（flush 后播放头会回退）。 */
  @VisibleForTesting
  static long queueFrames(long written, long played) {
    final long queued = written - played;
    return queued > 0 ? queued : 0;
  }

  /** 帧 → 毫秒（四舍五入）。采样率非法返回 -1。 */
  @VisibleForTesting
  static int framesToMs(long frames, int sampleRate) {
    if (sampleRate <= 0 || frames < 0) {
      return -1;
    }
    return (int) Math.round(frames * 1000.0 / sampleRate);
  }

  private static void rebase(AudioTrack current, long played) {
    synchronized (LOCK) {
      if (track == current) {
        writtenFrames = played;
      }
    }
  }

  // ── 以下仅供 JVM 单测（生产代码不调用） ──

  @VisibleForTesting
  static void resetForTest() {
    synchronized (LOCK) {
      track = null;
      bytesPerFrame = 1;
      writtenFrames = 0;
    }
  }

  @VisibleForTesting
  static void attachForTest(AudioTrack audioTrack, int bytesPerPcmFrame) {
    synchronized (LOCK) {
      track = audioTrack;
      bytesPerFrame = Math.max(1, bytesPerPcmFrame);
      writtenFrames = 0;
    }
  }

  @VisibleForTesting
  static void onBytesWrittenForTest(AudioTrack audioTrack, int bytesWritten) {
    if (bytesWritten <= 0) {
      return;
    }
    synchronized (LOCK) {
      if (track != audioTrack) {
        return;
      }
      writtenFrames += bytesWritten / bytesPerFrame;
    }
  }

  @VisibleForTesting
  static long writtenFramesForTest() {
    synchronized (LOCK) {
      return writtenFrames;
    }
  }
}
