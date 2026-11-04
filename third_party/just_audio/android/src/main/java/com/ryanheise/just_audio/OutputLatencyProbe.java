package com.ryanheise.just_audio;

import androidx.annotation.VisibleForTesting;
import android.media.AudioTimestamp;
import android.media.AudioTrack;
import android.os.Build;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

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
 * <p><b>多实例（MD3Music 伴唱需要）</b>：原实现是全局单例，后 <code>attach</code>
 * 的 AudioTrack 会覆盖前一个，因此只能测到「最后创建的那条」。伴唱场景下主曲与
 * 伴奏各有自己的 AudioTrack，两路排队深度**不同**（这正是用户听到的错位来源），
 * 必须分别测得。本版本改为按 AudioTrack 实例索引的记录表，两路互不覆盖；
 * 原有的单例语义（{@link #queuedLatencyMs()} 返回「最近一条」）保留以兼容既有调用。
 *
 * <p>无状态可测：所有算术都在包可见的纯函数里，{@link AudioTrack} 只在查询时被动读取，
 * 因此 JVM 单测不需要真实音频设备。
 */
public final class OutputLatencyProbe {

  /** 排队深度超过这个秒数即判定计数器错位：宁可报"不可用"，不报离谱值。 */
  private static final long MAX_PLAUSIBLE_MS = 10_000L;

  /** 单个 AudioTrack 的计数状态。 */
  private static final class TrackState {
    /** 每 PCM 帧字节数（声道数 × 每样本字节），用于字节→帧换算。 */
    final int bytesPerFrame;
    /** 自挂载以来、真正写入成功的帧数。 */
    long writtenFrames;

    TrackState(int bytesPerFrame) {
      this.bytesPerFrame = Math.max(1, bytesPerFrame);
      this.writtenFrames = 0;
    }
  }

  private static final Object LOCK = new Object();
  /** 按 AudioTrack 实例索引；主曲与伴奏各自一条，互不影响。 */
  private static final Map<AudioTrack, TrackState> TRACKS = new ConcurrentHashMap<>();
  /** 最近一次 attach 的轨道，供旧的单例 API（{@link #queuedLatencyMs()}）使用。 */
  private static AudioTrack lastAttached;

  private OutputLatencyProbe() {}

  /** 在 AudioTrack 创建后调用。{@code bytesPerPcmFrame} 取 configuration.outputPcmFrameSize。 */
  public static void attach(AudioTrack audioTrack, int bytesPerPcmFrame) {
    if (audioTrack == null) {
      return;
    }
    synchronized (LOCK) {
      TRACKS.put(audioTrack, new TrackState(bytesPerPcmFrame));
      lastAttached = audioTrack;
    }
  }

  /**
   * 在 AudioTrack 释放前调用，只摘掉这一条轨道。
   *
   * <p>旧签名 {@link #detach()} 会清空全部；多实例下必须按轨道摘除，否则释放背唱轨时
   * 会把主曲的状态一起清掉，导致主曲的排队深度变成不可用。
   */
  public static void detach(AudioTrack audioTrack) {
    if (audioTrack == null) {
      return;
    }
    synchronized (LOCK) {
      TRACKS.remove(audioTrack);
      if (lastAttached == audioTrack) {
        lastAttached = null;
        // 退回到"还活着的任意一条"，保持单例 API 的可用性。
        for (AudioTrack t : TRACKS.keySet()) {
          lastAttached = t;
          break;
        }
      }
    }
  }

  /** 兼容旧调用：清空全部记录。 */
  public static void detach() {
    synchronized (LOCK) {
      TRACKS.clear();
      lastAttached = null;
    }
  }

  /**
   * 记录一次**真正写入成功**的字节数（AudioTrack.write 的返回值 &gt; 0 时调用）。
   *
   * <p>按传入的 AudioTrack 精确定位状态；未登记的轨道直接丢弃（重建过渡期的尾巴写入）。
   */
  public static void onBytesWritten(AudioTrack audioTrack, int bytesWritten) {
    if (audioTrack == null || bytesWritten <= 0) {
      return;
    }
    final TrackState state = TRACKS.get(audioTrack);
    if (state == null) {
      return;
    }
    synchronized (LOCK) {
      state.writtenFrames += bytesWritten / state.bytesPerFrame;
    }
  }

  /**
   * 指定轨道的排队深度（毫秒）。
   *
   * @return 不可用时返回 -1：轨道未登记、API &lt; 24、时间戳取失败、采样率非法，
   *     或计数器明显错位（超过 {@link #MAX_PLAUSIBLE_MS}）。
   */
  public static int queuedLatencyMs(AudioTrack audioTrack) {
    if (audioTrack == null) {
      return -1;
    }
    final TrackState state = TRACKS.get(audioTrack);
    if (state == null) {
      return -1;
    }
    return query(audioTrack, state);
  }

  /** 兼容旧调用：最近一次 attach 的轨道（单轨场景下等价于唯一那条）。 */
  public static int queuedLatencyMs() {
    final AudioTrack current;
    synchronized (LOCK) {
      current = lastAttached;
    }
    return queuedLatencyMs(current);
  }

  /**
   * 原始位置快照（诊断用，可信度高）。
   *
   * <p>与 {@link #queuedLatencyMs} 的区别：后者用「累计写入帧数 − 播放头」求排队深度，
   * 那是个**差值法**——ExoPlayer 会持续喂数据，而 AudioTrack 只保留有限缓冲，
   * 一旦累计写入与播放头的基准不同步（例如 flush/重建/长时间播放），差值就会
   * 持续漂移并被钉在 MAX_PLAUSIBLE_MS 附近（真机实测稳定在 975ms 这种伪值）。
   *
   * <p>这里直接取 {@code AudioTrack.getTimestamp()} 报出的**硬件播放头**与时间戳，
   * 两者是同一时刻的真实对应关系，不含任何累计量，可直接换算「该轨此刻正在
   * 出声的音频时刻」，用于两路真实错位比较。
   *
   * @return 每项 "<code>sessionId:framePos:nanoTimeUs:writtenFrames:latencyMs</code>"，
   *     最多 8 条；不可用时为空串。
   */
  public static String rawSnapshot() {
    final StringBuilder sb = new StringBuilder();
    int shown = 0;
    for (Map.Entry<AudioTrack, TrackState> e : TRACKS.entrySet()) {
      if (shown >= 8) {
        break;
      }
      final AudioTrack t = e.getKey();
      final TrackState st = e.getValue();
      int id = -1;
      long framePos = -1;
      long nanoTime = -1;
      int sr = -1;
      long written;
      synchronized (LOCK) {
        written = st.writtenFrames;
      }
      try {
        id = t.getAudioSessionId();
        sr = t.getSampleRate();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
          final AudioTimestamp ts = new AudioTimestamp();
          if (t.getTimestamp(ts)) {
            framePos = ts.framePosition;
            nanoTime = ts.nanoTime;
          }
        }
      } catch (Throwable ignored) {
      }
      if (shown > 0) {
        sb.append(';');
      }
      sb.append(id).append(':')
          .append(framePos).append(':')
          .append(nanoTime).append(':')
          .append(written).append(':')
          .append(query(t, st));
      shown++;
    }
    return sb.toString();
  }

  /**
   * 当前登记的所有轨道的排队深度快照（诊断用）。
   *
   * @return 每项为 "sessionId:latencyMs" 的字符串，最多 8 条；无轨道时为空串。
   */
  public static String allQueuedLatency() {
    final StringBuilder sb = new StringBuilder();
    int shown = 0;
    for (Map.Entry<AudioTrack, TrackState> e : TRACKS.entrySet()) {
      if (shown >= 8) {
        break;
      }
      final AudioTrack t = e.getKey();
      final int ms = query(t, e.getValue());
      int id = -1;
      try {
        id = t.getAudioSessionId();
      } catch (Throwable ignored) {
      }
      if (shown > 0) {
        sb.append(',');
      }
      sb.append(id).append(':').append(ms);
      shown++;
    }
    return sb.toString();
  }

  private static int query(AudioTrack current, TrackState state) {
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
    final long written;
    synchronized (LOCK) {
      written = state.writtenFrames;
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
    final TrackState state = TRACKS.get(current);
    if (state == null) {
      return;
    }
    synchronized (LOCK) {
      state.writtenFrames = played;
    }
  }

  // ── 以下仅供 JVM 单测（生产代码不调用） ──

  @VisibleForTesting
  static void resetForTest() {
    synchronized (LOCK) {
      TRACKS.clear();
      lastAttached = null;
    }
  }

  @VisibleForTesting
  static void attachForTest(AudioTrack audioTrack, int bytesPerPcmFrame) {
    attach(audioTrack, bytesPerPcmFrame);
  }

  @VisibleForTesting
  static void onBytesWrittenForTest(AudioTrack audioTrack, int bytesWritten) {
    onBytesWritten(audioTrack, bytesWritten);
  }

  @VisibleForTesting
  static long writtenFramesForTest(AudioTrack audioTrack) {
    final TrackState state = TRACKS.get(audioTrack);
    if (state == null) {
      return 0;
    }
    synchronized (LOCK) {
      return state.writtenFrames;
    }
  }
}
