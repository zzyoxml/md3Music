package com.ryanheise.just_audio;

import androidx.media3.exoplayer.audio.DefaultAudioSink;
import androidx.media3.exoplayer.audio.DefaultAudioTrackBufferSizeProvider;

/**
 * MD3Music fork：按输出档位选择 AudioTrack 缓冲深度。
 *
 * <p>Media3 默认的 PCM 缓冲是「minBufferSize × 4，钳在 250~750ms」
 * （见 {@link DefaultAudioTrackBufferSizeProvider} 的 MIN/MAX_PCM_BUFFER_DURATION_US）。
 * 后台播放撞上前台高负载（大核被吃满、解码线程被调度延迟）时，这几百毫秒的抗抖
 * 余量经常不够：渲染线程晚喂一次就欠载，听感是「卡顿 / 爆音」。
 *
 * <p>因此**非低延迟档**把目标放宽到「× 8，钳在 500~2000ms」，用更深的排队换稳定性。
 *
 * <p>「系统 Direct PCM + 低延迟」档必须保持 Media3 默认值：该档的目标就是小缓冲进
 * fast 通道，而 {@code DefaultAudioSink} 建轨前还会在此基础上再砍半（见
 * {@code createAudioTrackV29} 前的缓冲补丁）。若在这里先把缓冲垫深，砍半后仍远大于
 * fast track 阈值，低延迟会彻底失效 —— 两个目标直接冲突，必须二选一。
 *
 * <p>本类只在 {@code configure()} 时被调用，档位切换需要重配 AudioTrack（应用侧已有
 * pause→play 的重建通道）。加深缓冲不会引入音画不同步：本 fork 只播音频，
 * MV / 动态封面走 video_player 的独立播放器实例。
 */
public final class AdaptiveAudioTrackBufferSizeProvider
    implements DefaultAudioSink.AudioTrackBufferSizeProvider {

  /** 抗卡顿档：minBufferSize × 8，钳在 500~2000ms。 */
  private static final DefaultAudioSink.AudioTrackBufferSizeProvider DEEP =
      new DefaultAudioTrackBufferSizeProvider.Builder()
          .setMinPcmBufferDurationUs(500_000)
          .setMaxPcmBufferDurationUs(2_000_000)
          .setPcmBufferMultiplicationFactor(8)
          .build();

  @Override
  public int getBufferSizeInBytes(
      int minBufferSizeInBytes,
      int encoding,
      int outputMode,
      int pcmFrameSize,
      int sampleRate,
      int bitrate,
      double maxAudioTrackPlaybackSpeed) {
    // MD3Music fork: offload 档必须回落到 Media3 默认实现 —— offload 的缓冲时长语义是
    // 「编码帧 50s」（DefaultAudioTrackBufferSizeProvider.OFFLOAD_BUFFER_DURATION_US），
    // 与本类的 PCM 深缓冲目标（500~2000ms 排队）不是一回事；套用 DEEP 会把编码缓冲
    // 压到 PCM 量级，直接增加 offload 欠载与断音风险。
    if (outputMode == DefaultAudioSink.OUTPUT_MODE_OFFLOAD) {
      return DefaultAudioSink.AudioTrackBufferSizeProvider.DEFAULT.getBufferSizeInBytes(
          minBufferSizeInBytes,
          encoding,
          outputMode,
          pcmFrameSize,
          sampleRate,
          bitrate,
          maxAudioTrackPlaybackSpeed);
    }
    DefaultAudioSink.AudioTrackBufferSizeProvider target =
        DirectPcmController.isLowLatencyEnabled()
            ? DefaultAudioSink.AudioTrackBufferSizeProvider.DEFAULT
            : DEEP;
    return target.getBufferSizeInBytes(
        minBufferSizeInBytes,
        encoding,
        outputMode,
        pcmFrameSize,
        sampleRate,
        bitrate,
        maxAudioTrackPlaybackSpeed);
  }
}
