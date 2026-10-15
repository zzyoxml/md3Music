package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.audio.BaseAudioProcessor;
import java.lang.ref.WeakReference;
import java.nio.ByteBuffer;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * 蝰蛇母带处理链的 Media3 音频处理器封装（MD3Music fork）。
 *
 * <p>挂进 DefaultAudioSink 的 AudioProcessorChain（见 AudioPlayer.buildAudioSink），
 * 输入恒为 16bit PCM（fork 恒关 float 输出，转换由 sink 前置处理器完成）。
 * DSP 本体在 {@link ViperMasterChain}（纯 Java，JVM 单测覆盖）。
 *
 * <p>控制面与 NormalizationGainAudioSink 同一模式：弱引用静态实例表 + volatile 挂起字段，
 * app 侧 ViperDspPlugin 调 setGlobal* 广播到所有播放器实例（主/辅播放器 crossfade 双链
 * 同吃音效），实际状态在音频线程 queueInput 头部消费，避免跨线程直改 DSP 状态。
 * 关闭时逐字节透传，保证 USB 独占输出 bit-perfect。
 */
public final class ViperMasterProcessor extends BaseAudioProcessor {

  /** 频段数（Kotlin 插件参数校验用）。 */
  public static final int BAND_COUNT = ViperMasterChain.BAND_COUNT;

  /** 存活实例（弱引用，广播时顺带清理死亡引用）。主/辅播放器各一个。 */
  private static final List<WeakReference<ViperMasterProcessor>> INSTANCES =
      new CopyOnWriteArrayList<>();

  private static volatile boolean globalEnabled;
  private static volatile float[] globalGains = new float[BAND_COUNT];

  private final ViperMasterChain chain = new ViperMasterChain();
  private volatile boolean enabledTarget;
  private volatile float[] pendingGains;
  private float[] inScratch = new float[0];
  private float[] outScratch = new float[0];

  public ViperMasterProcessor() {
    INSTANCES.add(new WeakReference<>(this));
    // 播放器重建后吸收当前全局状态（构造与广播的竞态由 volatile 顺序兜底）
    enabledTarget = globalEnabled;
    pendingGains = globalGains.clone();
    pullControl();
  }

  /** 广播开关到所有存活实例并清理死亡引用（任意线程可调）。 */
  public static void setGlobalEnabled(boolean value) {
    globalEnabled = value;
    for (WeakReference<ViperMasterProcessor> ref : INSTANCES) {
      ViperMasterProcessor p = ref.get();
      if (p == null) {
        INSTANCES.remove(ref);
      } else {
        p.enabledTarget = value;
      }
    }
  }

  /** 广播 10 段增益（dB）到所有存活实例并清理死亡引用（任意线程可调）。 */
  public static void setGlobalEqGains(float[] gains) {
    if (gains == null || gains.length != BAND_COUNT) {
      return;
    }
    globalGains = gains.clone();
    for (WeakReference<ViperMasterProcessor> ref : INSTANCES) {
      ViperMasterProcessor p = ref.get();
      if (p == null) {
        INSTANCES.remove(ref);
      } else {
        p.pendingGains = gains.clone();
      }
    }
  }

  /** 音频线程消费 volatile 挂起字段（queueInput/onFlush 头部调用）。 */
  private void pullControl() {
    boolean enabled = enabledTarget;
    if (chain.isEnabled() != enabled) {
      chain.setEnabled(enabled);
    }
    float[] gains = pendingGains;
    if (gains != null) {
      pendingGains = null;
      chain.setGains(gains);
    }
  }

  @Override
  public AudioFormat onConfigure(AudioFormat inputAudioFormat)
      throws UnhandledAudioFormatException {
    if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT
        || inputAudioFormat.sampleRate <= 0
        || inputAudioFormat.channelCount <= 0) {
      throw new UnhandledAudioFormatException(inputAudioFormat);
    }
    chain.configure(inputAudioFormat.sampleRate, inputAudioFormat.channelCount);
    return inputAudioFormat; // 16bit 进 16bit 出
  }

  @Override
  public void queueInput(ByteBuffer inputBuffer) {
    pullControl();
    int position = inputBuffer.position();
    int limit = inputBuffer.limit();
    int size = limit - position;
    if (size == 0) {
      return;
    }
    if (!chain.isEnabled()) {
      // 关闭：逐字节透传（bit-perfect）
      ByteBuffer buffer = replaceOutputBuffer(size);
      buffer.put(inputBuffer); // 消费到 limit
      buffer.flip();
      return;
    }
    int channelCount = inputAudioFormat.channelCount;
    int bytesPerFrame = inputAudioFormat.bytesPerFrame;
    int inFrames = size / bytesPerFrame;
    ensureScratch(inFrames, channelCount);
    int samples = inFrames * channelCount;
    // short → float（/32768 精确，回程 *32768 可无损往返）
    for (int i = 0; i < samples; i++) {
      inScratch[i] = inputBuffer.getShort(position + i * 2) / 32768f;
    }
    int outFrames = chain.process(inScratch, inFrames, outScratch);
    ByteBuffer buffer = replaceOutputBuffer(outFrames * bytesPerFrame);
    writeScratchPcm16(buffer, outFrames * channelCount);
    inputBuffer.position(limit);
    buffer.flip();
  }

  @Override
  public ByteBuffer getOutput() {
    if (super.isEnded() && chain.pendingTailFrames() > 0) {
      // EOS：排空 lookahead 尾音（EchoMusic graph.finish 同款语义）
      int channelCount = inputAudioFormat.channelCount;
      ensureScratch(0, channelCount);
      int frames = chain.drainTail(outScratch);
      int bytes = frames * inputAudioFormat.bytesPerFrame;
      ByteBuffer buffer = replaceOutputBuffer(bytes);
      writeScratchPcm16(buffer, frames * channelCount);
      buffer.flip();
    }
    return super.getOutput();
  }

  @Override
  public boolean isEnded() {
    return super.isEnded() && chain.pendingTailFrames() == 0;
  }

  @Override
  protected void onFlush() {
    pullControl();
    chain.reset(); // seek/格式切换：清延迟线与滤波器状态，不拖尾
  }

  @Override
  protected void onReset() {
    chain.reset();
  }

  private void ensureScratch(int frames, int channelCount) {
    int inSamples = frames * channelCount;
    if (inScratch.length < inSamples) {
      inScratch = new float[inSamples];
    }
    int outSamples = (frames + ViperMasterChain.LOOKAHEAD) * channelCount;
    if (outScratch.length < outSamples) {
      outScratch = new float[outSamples];
    }
  }

  /** outScratch[0..samples) → 16bit PCM（钳位后四舍五入）。 */
  private void writeScratchPcm16(ByteBuffer buffer, int samples) {
    for (int i = 0; i < samples; i++) {
      float v = outScratch[i] * 32768f;
      int s = v >= 32767f ? 32767 : (v <= -32768f ? -32768 : Math.round(v));
      buffer.putShort((short) s);
    }
  }
}
