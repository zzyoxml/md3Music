package com.ryanheise.just_audio;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import androidx.media3.common.C;
import androidx.media3.common.audio.AudioProcessor;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;

/**
 * 分离处理器的透传与补 dry 语义（纯 JVM，不需要 TFLite）。
 *
 * 这些断言是「fork 改动不能影响既有播放路径」的护栏：USB 独占 / Direct PCM
 * 依赖逐字节透传，任何偏差都会破坏 bit-perfect。
 */
public class StemSeparateProcessorTest {

  private static final int SR = 48000;
  private static final int CH = 2;

  private StemSeparateProcessor processor;

  @Before
  public void setUp() {
    StemSeparateProcessor.clearInstancesForTest();
    processor = new StemSeparateProcessor();
  }

  @After
  public void tearDown() {
    StemSeparateProcessor.clearInstancesForTest();
  }

  private static AudioProcessor.AudioFormat pcm16(int sr, int ch) {
    return new AudioProcessor.AudioFormat(sr, ch, C.ENCODING_PCM_16BIT);
  }

  /**
   * 把 float 样本按 16bit 编码装箱（模拟 int 管线）。
   *
   * 用 **32768** 而不是 32767：处理器内部读 16bit 用的是 `/32768f`
   * （与 app 侧 PcmEncoding 口径一致），装箱也走同一个缩放系数才能无损往返；
   * 混用会在每个样本上引入 1 LSB 偏差（0.49896 vs 0.5），把「透传等价」
   * 这类断言全部变成假失败。
   */
  private static ByteBuffer pcmBuffer(float[] samples) {
    ByteBuffer b = ByteBuffer.allocate(samples.length * 2).order(ByteOrder.LITTLE_ENDIAN);
    for (float v : samples) {
      b.putShort(toPcm16(v));
    }
    b.flip();
    return b;
  }

  /**
   * 钳位后按 32767 缩放进 16bit 域，**带 0.5 四舍五入**。
   *
   * 纯截断会在极小样本上出问题：`float32(1/32767) * 32767` 浮点结果是
   * `0.99999999`，截断成 0，于是 ramp[1] 往返后变成 0 而不是 1/32767 ——
   * 这类断言会误报成「透传不一致」。四舍五入才是 16bit 量化的正确语义。
   */
  private static short toPcm16(float v) {
    if (v <= -1f) return Short.MIN_VALUE;
    if (v >= 1f) return Short.MAX_VALUE;
    return (short) Math.round(v * 32768f);
  }

  /** 16bit 输出读成 float（/32768 口径，与处理器内部一致）。 */
  private static float[] readAll(AudioProcessor p) {
    ByteBuffer out = p.getOutput();
    ByteBuffer dup = out.duplicate().order(ByteOrder.LITTLE_ENDIAN);
    float[] got = new float[dup.remaining() / 2];
    for (int i = 0; i < got.length; i++) {
      got[i] = dup.getShort() / 32768f;
    }
    return got;
  }

  /** float 输出直接读。 */
  private static float[] readAllFloat(AudioProcessor p) {
    ByteBuffer out = p.getOutput();
    ByteBuffer dup = out.duplicate().order(ByteOrder.LITTLE_ENDIAN);
    float[] got = new float[dup.remaining() / 4];
    for (int i = 0; i < got.length; i++) {
      got[i] = dup.getFloat();
    }
    return got;
  }

  /** 逐帧递增的测试信号（每帧左右不同，便于检出通道错位）。 */
  private static float[] ramp(int frames, int ch) {
    float[] s = new float[frames * ch];
    for (int i = 0; i < frames; i++) {
      for (int c = 0; c < ch; c++) {
        s[i * ch + c] = (i * (c == 0 ? 1 : 3) + c) / 32768f;
      }
    }
    return s;
  }

  /** float 编码的输入缓冲。 */
  private static ByteBuffer floatBuffer(float[] samples) {
    ByteBuffer b = ByteBuffer.allocate(samples.length * 4).order(ByteOrder.LITTLE_ENDIAN);
    for (float v : samples) {
      b.putFloat(v);
    }
    b.flip();
    return b;
  }

  private static final class FakeHook implements StemSeparateHook {
    int configureCount;
    int flushCount;
    int releaseCount;
    int lastConfigureRate;
    int lastConfigureChannels;
    /** 每次 process 返回多少帧；null = 返回全部帧。 */
    Integer fixedWritten;
    boolean ready = true;
    /** 输出内容标记：每帧写入 MARKER。 */
    boolean writeMarker;

    static final float MARKER = 0.5f;

    @Override
    public void configure(int sampleRate, int channelCount) {
      configureCount++;
      lastConfigureRate = sampleRate;
      lastConfigureChannels = channelCount;
    }

    @Override
    public int process(float[] in, int frames, float[] out, int channelCount) {
      int written = fixedWritten == null ? frames : fixedWritten;
      if (writeMarker) {
        for (int i = 0; i < written * channelCount; i++) {
          out[i] = MARKER;
        }
      }
      return written;
    }

    @Override
    public void flush() {
      flushCount++;
    }

    @Override
    public void release() {
      releaseCount++;
    }

    @Override
    public boolean isReady() {
      return ready;
    }
  }

  @Test
  public void disabledProcessorIsBitExactPassthrough() throws Exception {
    processor.configure(pcm16(SR, CH));
    float[] in = ramp(64, CH);
    processor.queueInput(pcmBuffer(in));
    assertFloatArrayEquals("未启用时必须逐字节原样透传", in, readAll(processor));
  }

  @Test
  public void hookNotReadyStillPassesThroughDry() throws Exception {
    FakeHook hook = new FakeHook();
    hook.ready = false;
    StemSeparateProcessor.setGlobalHook(hook);
    StemSeparateProcessor.setGlobalEnabled(true);

    processor.configure(pcm16(SR, CH));
    float[] in = ramp(64, CH);
    processor.queueInput(pcmBuffer(in));

    assertFloatArrayEquals("hook 未就绪时必须回落原音，不能补零", in, readAll(processor));
  }

  @Test
  public void fullHookOutputReplacesDry() throws Exception {
    FakeHook hook = new FakeHook();
    hook.writeMarker = true;
    StemSeparateProcessor.setGlobalHook(hook);
    StemSeparateProcessor.setGlobalEnabled(true);

    processor.configure(pcm16(SR, CH));
    processor.queueInput(pcmBuffer(ramp(64, CH)));

    float[] got = readAll(processor);
    for (float v : got) {
      assertEquals("hook 已写满时应全部采用 hook 输出", FakeHook.MARKER, v, PCM16_STEP);
    }
  }

  @Test
  public void partialHookOutputPadsTailWithDryNotSilence() throws Exception {
    FakeHook hook = new FakeHook();
    hook.fixedWritten = 16; // 只写前 16 帧
    hook.writeMarker = true;
    StemSeparateProcessor.setGlobalHook(hook);
    StemSeparateProcessor.setGlobalEnabled(true);

    processor.configure(pcm16(SR, CH));
    float[] in = ramp(64, CH);
    processor.queueInput(pcmBuffer(in));

    float[] got = readAll(processor);
    assertEquals(64 * CH, got.length);
    // 前 16 帧是 hook 输出
    for (int i = 0; i < 16 * CH; i++) {
      assertEquals(FakeHook.MARKER, got[i], PCM16_STEP);
    }
    // 尾部必须是输入原音（补零会听成断续）
    for (int i = 16 * CH; i < got.length; i++) {
      assertEquals("尾部必须补 dry 而不是静音", in[i], got[i], PCM16_STEP);
    }
  }

  @Test
  public void hookReturningZeroFallsBackToEntireDry() throws Exception {
    FakeHook hook = new FakeHook();
    hook.fixedWritten = 0;
    StemSeparateProcessor.setGlobalHook(hook);
    StemSeparateProcessor.setGlobalEnabled(true);

    processor.configure(pcm16(SR, CH));
    float[] in = ramp(64, CH);
    processor.queueInput(pcmBuffer(in));

    assertFloatArrayEquals("hook 返回 0 表示本批未就绪，整段回落原音", in, readAll(processor));
  }

  @Test
  public void hookThrowingDoesNotBreakPlayback() throws Exception {
    StemSeparateHook boom =
        new StemSeparateHook() {
          @Override
          public void configure(int sampleRate, int channelCount) {}

          @Override
          public int process(float[] in, int frames, float[] out, int channelCount) {
            throw new IllegalStateException("推理爆炸");
          }

          @Override
          public void flush() {}

          @Override
          public void release() {}

          @Override
          public boolean isReady() {
            return true;
          }
        };
    StemSeparateProcessor.setGlobalHook(boom);
    StemSeparateProcessor.setGlobalEnabled(true);

    processor.configure(pcm16(SR, CH));
    float[] in = ramp(64, CH);
    processor.queueInput(pcmBuffer(in));

    assertFloatArrayEquals("hook 抛异常时本批必须回落原音", in, readAll(processor));
  }

  @Test
  public void nonPcm16IsPassthroughAndNeverThrows() throws Exception {
    // passthrough 压缩编码（如 offload 前的 AC3）：绝不能抛
    // UnhandledAudioFormatException，否则整条播放链断掉。
    processor.configure(new AudioProcessor.AudioFormat(SR, CH, C.ENCODING_AC3));
    float[] in = ramp(64, CH);
    processor.queueInput(pcmBuffer(in));
    assertFloatArrayEquals("16bit 透传", in, readAll(processor));
  }

  @Test
  public void configureForwardsFormatToHook() throws Exception {
    FakeHook hook = new FakeHook();
    StemSeparateProcessor.setGlobalHook(hook);
    StemSeparateProcessor.setGlobalEnabled(true);

    processor.configure(pcm16(SR, CH));

    assertEquals(1, hook.configureCount);
    assertEquals(SR, hook.lastConfigureRate);
    assertEquals(CH, hook.lastConfigureChannels);
  }

  @Test
  public void flushForwardsToHook() throws Exception {
    FakeHook hook = new FakeHook();
    StemSeparateProcessor.setGlobalHook(hook);
    StemSeparateProcessor.setGlobalEnabled(true);

    processor.configure(pcm16(SR, CH));
    processor.queueInput(pcmBuffer(ramp(32, CH)));
    // 消费掉待处理输出，让 flush 能推进
    readAll(processor);
    processor.flush();

    assertEquals("seek/格式切换必须清 hook 的流式状态", 1, hook.flushCount);
  }

  @Test
  public void mixIsClampedToUnitRange() throws Exception {
    StemSeparateProcessor.setGlobalMix(-1.0f);
    assertEquals(0.0f, StemSeparateProcessor.getGlobalMix(), 1e-6f);
    StemSeparateProcessor.setGlobalMix(2.0f);
    assertEquals(1.0f, StemSeparateProcessor.getGlobalMix(), 1e-6f);
    StemSeparateProcessor.setGlobalMix(Float.NaN);
    assertEquals("NaN 不得写入（会污染混音系数）", 1.0f, StemSeparateProcessor.getGlobalMix(), 1e-6f);
    StemSeparateProcessor.setGlobalMix(0.5f);
    assertEquals(0.5f, StemSeparateProcessor.getGlobalMix(), 1e-6f);
  }

  @Test
  public void enabledWithoutHookIsPassthrough() throws Exception {
    StemSeparateProcessor.setGlobalEnabled(true); // 没注入 hook
    processor.configure(pcm16(SR, CH));
    float[] in = ramp(64, CH);
    processor.queueInput(pcmBuffer(in));
    assertFloatArrayEquals("16bit 透传", in, readAll(processor));
    assertTrue(StemSeparateProcessor.isGloballyEnabled());
  }

  /**
   * 16bit 管线的量化步长（1/32768）。
   *
   * 16bit 域只有 32768 个量化级，float → short → float 往返必然差半个到一
   * 个步长；断言不能用 1e-6（那是 float 精度，不是 16bit 精度），否则「透传
   * 等价」这类用例会因纯粹的量化误差假失败。
   */
  private static final float PCM16_STEP = 1f / 32768f;

  /** JUnit 4.13 的 assertArrayEquals 只支持 double[]，float 单独比较。 */
  private static void assertFloatArrayEquals(String msg, float[] a, float[] b) {
    assertEquals(msg + " 长度", a.length, b.length);
    for (int i = 0; i < a.length; i++) {
      assertEquals(msg + " @" + i, a[i], b[i], PCM16_STEP);
    }
  }

  // ── float 管线回归（本次修复的核心：32bit 开启时分离必须仍然生效）──

  @Test
  public void floatEncodingIsSupportedNotUnsupported() throws Exception {
    // 开启「32bit 播放支持」/ Direct PCM 高规格档后，DefaultAudioSink 走 float
    // 管线。修复前本处理器只认 16bit，float 下 unsupported=true 直接透传 ——
    // 表现为「端侧分离没效果」。这里锁死 float 必须被接受。
    FakeHook hook = new FakeHook();
    StemSeparateProcessor.setGlobalHook(hook);
    StemSeparateProcessor.setGlobalEnabled(true);

    processor.configure(new AudioProcessor.AudioFormat(SR, CH, C.ENCODING_PCM_FLOAT));
    // configure 必须把格式转给 hook，而不是把 unsupported 置位
    assertTrue("float 必须被支持，否则 32bit 模式下分离静默失效", hook.configureCount >= 1);
  }

  @Test
  public void floatPipelineActuallyAppliesHook() throws Exception {
    FakeHook hook = new FakeHook();
    hook.writeMarker = true;
    StemSeparateProcessor.setGlobalHook(hook);
    StemSeparateProcessor.setGlobalEnabled(true);

    processor.configure(new AudioProcessor.AudioFormat(SR, CH, C.ENCODING_PCM_FLOAT));
    float[] in = ramp(64, CH);
    processor.queueInput(floatBuffer(in));

    float[] got = readAllFloat(processor);
    assertEquals(64 * CH, got.length);
    for (float v : got) {
      assertEquals("float 管线必须真正采用 hook 输出", FakeHook.MARKER, v, 1e-6f);
    }
  }

  @Test
  public void floatDisabledIsBitExactPassthrough() throws Exception {
    processor.configure(new AudioProcessor.AudioFormat(SR, CH, C.ENCODING_PCM_FLOAT));
    float[] in = ramp(64, CH);
    processor.queueInput(floatBuffer(in));
    assertFloatArrayEquals("未启用时 float 也必须逐字节透传", in, readAllFloat(processor));
  }

  @Test
  public void floatPartialOutputPadsTailWithDry() throws Exception {
    FakeHook hook = new FakeHook();
    hook.fixedWritten = 16;
    hook.writeMarker = true;
    StemSeparateProcessor.setGlobalHook(hook);
    StemSeparateProcessor.setGlobalEnabled(true);

    processor.configure(new AudioProcessor.AudioFormat(SR, CH, C.ENCODING_PCM_FLOAT));
    float[] in = ramp(64, CH);
    processor.queueInput(floatBuffer(in));

    float[] got = readAllFloat(processor);
    for (int i = 0; i < 16 * CH; i++) {
      assertEquals(FakeHook.MARKER, got[i], PCM16_STEP);
    }
    for (int i = 16 * CH; i < got.length; i++) {
      assertEquals("float 尾部同样必须补 dry", in[i], got[i], 1e-6f);
    }
  }
}
