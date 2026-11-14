package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.audio.AudioProcessor;
import androidx.media3.common.audio.BaseAudioProcessor;
import java.lang.ref.WeakReference;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * 端侧人声/伴奏分离的 Media3 音频处理器（MD3Music fork）。
 *
 * <p>挂在 {@code DefaultAudioSink} 的 AudioProcessorChain **首位**（见
 * {@code AudioPlayer.buildAudioSink}），链序为：
 *
 * <pre>
 * [ToInt16 → channelMap → trimming] → [StemSeparate, ViperMaster] → SilenceSkip → Sonic
 * </pre>
 *
 * <p>把分离放在链首的理由：
 * <ul>
 *   <li>ExoPlayer 继续当解码器与时钟，歌词/通知栏/媒体会话/倍速全部不用改；</li>
 *   <li>分离结果再进蝰蛇母带与均衡器，音效作用于「伴奏」而不是原曲；</li>
 *   <li>下游的 {@code NormalizationGainAudioSink} 仍然照常生效。</li>
 * </ul>
 *
 * <p><b>为什么不用「自建 AudioTrack」</b>：参考实现（StemSplitter demo）自己
 * 解码 + 推理 + 出声，代价是原曲必须绕开 just_audio，于是媒体会话、歌词时钟、
 * EQ、offload、USB 独占、交叉淡化全部要另接一遍。本处理器只做「取 PCM →
 * 交给 hook → 写回」，上面这些能力全部免费继承。
 *
 * <p><b>透传保证</b>：未启用、hook 为 null、模型未就绪、或输入不是 16bit PCM 时，
 * 逐字节原样透传，行为与不包装完全一致（USB 独占 / Direct PCM 的 bit-perfect
 * 口径不受影响）。
 *
 * <p><b>控制面</b>：与 {@code NormalizationGainAudioSink} / {@code ViperMasterProcessor}
 * 同一模式——静态广播 + volatile 字段 + 弱引用实例表，app 侧插件调静态方法即可
 * 覆盖主/辅/headless 三个播放器，不污染 just_audio 上游 Dart API。
 */
public final class StemSeparateProcessor extends BaseAudioProcessor {

  /** 存活实例（弱引用，广播时顺带清理死亡引用）。主/辅播放器各一个。 */
  private static final List<WeakReference<StemSeparateProcessor>> INSTANCES =
      new CopyOnWriteArrayList<>();

  /** 全局开关：是否请求分离。 */
  private static volatile boolean globalEnabled;

  /** 全局 hook（由 app 插件注入；null = 无实现，透传）。 */
  private static volatile StemSeparateHook globalHook;

  /** 全局混音比例（伴奏占比，0..1）；1.0 = 纯伴奏。 */
  private static volatile float globalMix = 1.0f;

  // ── 每个实例的本地状态（渲染线程独占，无需同步）──

  /** 当前是否真的在处理（= 全局启用 && hook 就绪 && 格式受支持）。 */
  private boolean active;

  /** 输入不是 16bit PCM（例如 passthrough 压缩编码）→ 永远透传。 */
  private boolean unsupported;

  /** 复用的 float 缓冲，避免渲染线程每批都分配大对象。 */
  private float[] inScratch = new float[0];
  private float[] outScratch = new float[0];

  public StemSeparateProcessor() {
    INSTANCES.add(new WeakReference<>(this));
    active = globalEnabled && globalHook != null;
  }

  // ── 静态控制面（任意线程可调）──

  /** 注入/替换 hook。传 null 表示卸载实现。 */
  public static void setGlobalHook(StemSeparateHook hook) {
    globalHook = hook;
    for (WeakReference<StemSeparateProcessor> ref : INSTANCES) {
      StemSeparateProcessor p = ref.get();
      if (p == null) {
        INSTANCES.remove(ref);
      } else {
        p.active = globalEnabled && hook != null;
      }
    }
  }

  /** 开关分离。关闭后立即透传（不需要重建 ExoPlayer）。 */
  public static void setGlobalEnabled(boolean enabled) {
    globalEnabled = enabled;
    for (WeakReference<StemSeparateProcessor> ref : INSTANCES) {
      StemSeparateProcessor p = ref.get();
      if (p == null) {
        INSTANCES.remove(ref);
      } else {
        p.active = enabled && globalHook != null;
      }
    }
  }

  /** 设置伴奏占比（0..1，1 = 纯伴奏）。越界会被钳位。 */
  public static void setGlobalMix(float mix) {
    if (Float.isNaN(mix)) {
      return;
    }
    globalMix = mix < 0f ? 0f : (mix > 1f ? 1f : mix);
  }

  /** 当前伴奏占比（诊断用）。 */
  public static float getGlobalMix() {
    return globalMix;
  }

  /** 当前是否请求分离（诊断用）。 */
  public static boolean isGloballyEnabled() {
    return globalEnabled;
  }

  /** 清空实例表（仅测试用）。 */
  static void clearInstancesForTest() {
    INSTANCES.clear();
    globalEnabled = false;
    globalHook = null;
    globalMix = 1.0f;
  }

  // ── AudioProcessor 实现 ──

  /**
   * 自己记一份输入格式。
   *
   * 不直接读基类的 `inputAudioFormat`：那是 `protected` 字段，由 `configure`
   * 在链路真正装配时写入；单测里直接 new + configure 的路径下它可能仍是
   * `NOT_SET`（全 -1），此时按 `bytesPerFrame=-1` 算 `frames` 会得到负数，
   * 于是每一批都被当成空数据透传 —— 表现就是「hook 从未被调用」。
   * 自己的字段在 `onConfigure` 里写入，任何调用顺序都可靠。
   */
  private volatile AudioProcessor.AudioFormat inputFormat = AudioProcessor.AudioFormat.NOT_SET;

  /**
   * 输入编码：PCM_16BIT 或 PCM_FLOAT。
   *
   * <p>为什么必须支持 float：{@code DefaultAudioSink} 在 float 输出时走的是
   * 另一条管线（`toFloatPcmAvailableAudioProcessors`），**不挂**
   * `audioProcessorChain`。开启「32bit 播放支持」或 Direct PCM 高规格档后，
   * 24/32bit 源会被 `isEncodingHighResolutionPcm` 判为高规格 → 走 float 分支
   * → 本处理器根本不在链上，`queueInput` 永不调用，表现为「端侧分离没效果」
   * 且**没有任何日志**（连 configure 都收不到）。这与设备实测一致。
   *
   * <p>因此 float 分支必须显式挂一个本处理器实例（见
   * `DefaultAudioSink.configure`），且这里要能接受 PCM_FLOAT。
   */
  private boolean floatInput;

  @Override
  public AudioProcessor.AudioFormat onConfigure(AudioProcessor.AudioFormat inputAudioFormat)
      throws AudioProcessor.UnhandledAudioFormatException {
    inputFormat = inputAudioFormat;
    if (inputAudioFormat.sampleRate <= 0 || inputAudioFormat.channelCount <= 0) {
      unsupported = true;
      return inputAudioFormat;
    }
    // 只认 16bit 与 float；其余（含 passthrough 压缩编码）透传，绝不抛异常打断播放。
    floatInput = inputAudioFormat.encoding == C.ENCODING_PCM_FLOAT;
    if (!floatInput && inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) {
      unsupported = true;
      return inputAudioFormat;
    }
    unsupported = false;
    StemSeparateHook hook = globalHook;
    if (hook != null) {
      hook.configure(inputAudioFormat.sampleRate, inputAudioFormat.channelCount);
    }
    return inputAudioFormat; // 同格式进出，编码不变
  }

  @Override
  public boolean isActive() {
    return true;
  }

  @Override
  public void queueInput(ByteBuffer inputBuffer) {
    final int position = inputBuffer.position();
    final int limit = inputBuffer.limit();
    final int size = limit - position;
    if (size <= 0) {
      return;
    }

    final StemSeparateHook hook = globalHook;
    // 每次现读全局开关，而不是依赖实例表在某次广播时被刷成 active：
    // 播放器与插件的创建顺序不受控（headless 引擎、重建的 sink 都可能晚于
    // setGlobalEnabled），只认字段能避免「开了却没效果」这类静默失效。
    final boolean enabledNow = globalEnabled;
    if (!enabledNow || unsupported || hook == null || !hook.isReady()) {
      // 透传：逐字节原样（bit-perfect 口径）
      passthrough(inputBuffer, position, size);
      return;
    }

    final int channelCount = inputFormat.channelCount;
    final int bytesPerFrame = inputFormat.bytesPerFrame;
    final int frames = size / bytesPerFrame;
    if (frames <= 0 || channelCount <= 0) {
      passthrough(inputBuffer, position, size);
      return;
    }

    final int samples = frames * channelCount;
    ensureScratch(samples);

    // 显式小端读取：ByteBuffer 默认是大端，依赖默认 order 会把每个样本的高低
    // 字节读反（历史坑，见 app 侧 PcmEncoding 的注释）。duplicate() 只复制视图，
    // 不复制内容，也不会改动源 buffer 的 position/limit。
    final ByteBuffer src = inputBuffer.duplicate().order(ByteOrder.LITTLE_ENDIAN);
    final int bytesPerSample = floatInput ? 4 : 2;
    if (floatInput) {
      // float 分支：1.0f = 0 dBFS，直接就是 [-1,1]，不需要缩放。
      for (int i = 0; i < samples; i++) {
        inScratch[i] = src.getFloat(position + i * bytesPerSample);
      }
    } else {
      for (int i = 0; i < samples; i++) {
        inScratch[i] = src.getShort(position + i * bytesPerSample) / 32768f;
      }
    }

    int written;
    try {
      written = hook.process(inScratch, frames, outScratch, channelCount);
    } catch (RuntimeException e) {
      // 推理异常绝不允许把播放带崩：本批回落原音，交由 app 侧统计/降级。
      written = 0;
    }
    if (written < 0) {
      written = 0;
    } else if (written > frames) {
      written = frames;
    }

    final ByteBuffer buffer = replaceOutputBuffer(size);
    buffer.order(ByteOrder.LITTLE_ENDIAN);
    final int writtenSamples = written * channelCount;
    if (floatInput) {
      for (int i = 0; i < writtenSamples; i++) {
        buffer.putFloat(outScratch[i]);
      }
      // 未写满的尾部补**输入原音**而不是静音：补零会听成断续/爆音。
      for (int i = writtenSamples; i < samples; i++) {
        buffer.putFloat(inScratch[i]);
      }
    } else {
      for (int i = 0; i < writtenSamples; i++) {
        buffer.putShort(toPcm16(outScratch[i]));
      }
      for (int i = writtenSamples; i < samples; i++) {
        buffer.putShort(toPcm16(inScratch[i]));
      }
    }
    inputBuffer.position(limit);
    buffer.flip();
  }

  /**
   * float → 16bit 整数。
   *
   * 用 **32768** 而不是 32767：读取侧是 `short / 32768f`（app 侧 PcmEncoding
   * 的既有口径），写回必须用同一个系数才能无损往返。`-1.0f` 精确映射到
   * `Short.MIN_VALUE`；`+1.0f` 钳到 `Short.MAX_VALUE`（32767 不存在对称的正端）。
   */
  private static short toPcm16(float v) {
    if (v <= -1f) return Short.MIN_VALUE;
    if (v >= 1f) return Short.MAX_VALUE;
    return (short) Math.round(v * 32768f);
  }

  /** 逐字节原样透传 [position, position+size)。 */
  private void passthrough(ByteBuffer inputBuffer, int position, int size) {
    final ByteBuffer buffer = replaceOutputBuffer(size);
    final ByteBuffer src = inputBuffer.duplicate();
    src.position(position);
    src.limit(position + size);
    buffer.put(src);
    inputBuffer.position(inputBuffer.limit());
    buffer.flip();
  }

  @Override
  protected void onFlush() {
    StemSeparateHook hook = globalHook;
    if (hook != null) {
      try {
        hook.flush();
      } catch (RuntimeException ignored) {
        // seek 期间清理失败不影响后续处理
      }
    }
  }

  @Override
  protected void onReset() {
    StemSeparateHook hook = globalHook;
    if (hook != null) {
      try {
        hook.flush();
      } catch (RuntimeException ignored) {
        // 同上
      }
    }
  }

  private void ensureScratch(int samples) {
    if (inScratch.length < samples) {
      inScratch = new float[samples];
    }
    if (outScratch.length < samples) {
      outScratch = new float[samples];
    }
  }
}
