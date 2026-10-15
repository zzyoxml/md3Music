package com.ryanheise.just_audio;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import java.util.Arrays;
import org.junit.Before;
import org.junit.Test;

/** 蝰蛇母带 DSP 核心单元测试（纯 JVM）。 */
public class ViperMasterChainTest {

  private static final int SR = 48000;
  private static final int CH = 2;
  private static final int LA = ViperMasterChain.LOOKAHEAD;

  private ViperMasterChain chain;

  @Before
  public void setUp() {
    chain = new ViperMasterChain();
    chain.configure(SR, CH);
  }

  /** 双声道正弦（左右幅度可不同）。 */
  private static float[] stereoSine(int frames, float freq, float ampL, float ampR) {
    float[] data = new float[frames * CH];
    for (int i = 0; i < frames; i++) {
      float s = (float) Math.sin(2.0 * Math.PI * freq * i / SR);
      data[i * CH] = ampL * s;
      data[i * CH + 1] = ampR * s;
    }
    return data;
  }

  private float[] run(float[] in, int frames) {
    float[] out = new float[(frames + LA) * CH];
    int n = chain.process(in, frames, out);
    assertTrue(n >= 0 && n <= frames);
    return Arrays.copyOf(out, n * CH);
  }

  /** 稳态区间峰值（跳过前 skip 帧暖机/瞬态）。 */
  private static float peakAfter(float[] data, int skipFrames) {
    float peak = 0f;
    for (int i = skipFrames * CH; i < data.length; i++) {
      peak = Math.max(peak, Math.abs(data[i]));
    }
    return peak;
  }

  // ---------- 关闭态：逐样本透传（USB bit-perfect 承诺） ----------

  @Test
  public void disabledPassesThroughBitExact() {
    int frames = 4800;
    float[] in = stereoSine(frames, 1000f, 1.5f, -1.5f); // 超刻度也必须原样
    float[] out = run(in, frames);
    assertEquals(frames, out.length / CH);
    assertArrayEquals(in, out, 0f);
  }

  // ---------- 开启态 + 全 0 增益：低电平原样 ----------

  @Test
  public void enabledIdentityIsSampleExactBelowKnee() {
    chain.setEnabled(true);
    int frames = 4800;
    float[] in = stereoSine(frames, 1000f, 0.5f, -0.5f);
    float[] out = run(in, frames);
    // lookahead 暖机压住最后 256 帧，其余逐样本一致
    assertEquals(frames - LA, out.length / CH);
    assertArrayEquals(Arrays.copyOf(in, out.length), out, 0f);
  }

  // ---------- headroom：+12dB EQ 后信号不被推爆 ----------

  @Test
  public void eqBoostIsPreAttenuatedToAvoidClipping() {
    float[] gains = new float[ViperMasterChain.BAND_COUNT];
    gains[4] = 12f; // 500Hz 段 +12dB
    chain.setGains(gains); // 关闭态 setGains 直接落盘
    chain.setEnabled(true);
    int frames = 4800;
    float[] in = stereoSine(frames, 500f, 0.9f, 0.9f);
    float[] out = run(in, frames);
    // 预衰减 ≈ 1/3.981，EQ 后回到 ≈0.9；若 headroom 缺失限幅器会把峰值拉到 ≈1.0
    float peak = peakAfter(out, 1024);
    assertTrue("peak=" + peak, peak >= 0.81f && peak <= 0.99f);
    // 全程不得越数字满刻度
    for (float v : out) {
      assertTrue("overflow " + v, Math.abs(v) <= 1.001f);
    }
  }

  // ---------- 交叉淡化平滑性 ----------

  @Test
  public void gainChangeCrossfadesWithoutClick() {
    chain.setEnabled(true);
    int frames = 4800;
    float[] in = stereoSine(frames, 1000f, 0.5f, 0.5f);
    float[] before = run(in, frames);

    float[] gains = new float[ViperMasterChain.BAND_COUNT];
    gains[5] = 6f; // 1000Hz 段：与信号同频，带内经 headroom 预衰减后增益归一
    chain.setGains(gains); // 开启态触发 15ms 交叉淡化
    float[] during = run(in, frames);

    // 1000Hz@0.5 正弦的天然相邻样本差 ≈ 0.065；无点击则过渡期差分有界
    for (int c = 0; c < CH; c++) {
      for (int i = c; i + CH < during.length; i += CH) {
        float delta = Math.abs(during[i + CH] - during[i]);
        assertTrue("click " + delta, delta <= 0.15f);
      }
    }
    // 淡化完成后（跳过 15ms=720 帧）稳态回到 ≈0.5（headroom 使带内增益归一）
    float peak = peakAfter(during, 1024);
    assertTrue("peak=" + peak, peak >= 0.475f && peak <= 0.525f);
    assertTrue(before.length > 0);
  }

  // ---------- 限幅：超刻度峰值被压回满刻度内 ----------

  @Test
  public void limiterHoldsPeaksAtFullScale() {
    chain.setEnabled(true);
    int frames = 4800;
    float[] in = stereoSine(frames, 1000f, 1.5f, 1.5f); // 直接喂超刻度
    float[] out = run(in, frames);
    for (float v : out) {
      assertTrue("overflow " + v, Math.abs(v) <= 1.0001f);
    }
    float peak = peakAfter(out, 512);
    // 天花板 1.0 的满刻度峰再过 knee 0.95 软削波：softLimit(1.0)=0.98161
    assertTrue("peak=" + peak, peak >= 0.98f); // 不能把电平整体压没
  }

  // ---------- 联动：左右共用一条增益包络，保立体声像 ----------

  @Test
  public void limiterLinksChannelsPreservingImage() {
    chain.setEnabled(true);
    int frames = 4800;
    // 左 1.5 触发限幅，右 0.2 远低；联动时右声道会被同一条包络压到 ≈0.2/1.5=0.133
    float[] in = stereoSine(frames, 1000f, 1.5f, 0.2f);
    float[] out = run(in, frames);
    float peakL = 0f;
    float peakR = 0f;
    for (int i = 512 * CH; i < out.length; i += CH) {
      peakL = Math.max(peakL, Math.abs(out[i]));
      peakR = Math.max(peakR, Math.abs(out[i + 1]));
    }
    assertTrue("peakL=" + peakL, peakL <= 1.0001f);
    // 非联动实现会给出 0.2（右声道不被压），联动实现 ≈0.1333
    assertTrue("peakR=" + peakR, peakR >= 0.12f && peakR <= 0.15f);
  }

  // ---------- 软削波：knee 0.95 以上进入指数弧线 ----------

  @Test
  public void softClipTamesAboveKnee() {
    chain.setEnabled(true);
    int frames = 4800;
    float[] in = new float[frames * CH];
    Arrays.fill(in, 0.99f); // 窗口峰值 <1，限幅不介入；0.99 > knee
    float[] out = run(in, frames);
    float last = out[out.length - CH]; // 暖机后恒定值
    // 0.95 + 0.05*(1-exp(-0.8)) ≈ 0.97753
    assertTrue("out=" + last, last >= 0.975f && last <= 0.980f);
    assertTrue(last < 0.99f);
    assertTrue(last > 0.95f);
  }

  // ---------- 曲尾：EOS 排空 lookahead，内容守恒 ----------

  @Test
  public void endOfStreamDrainsLookaheadTail() {
    chain.setEnabled(true);
    int frames = 4800;
    float[] in = stereoSine(frames, 1000f, 0.5f, -0.5f);
    float[] out = run(in, frames);
    assertEquals(frames - LA, out.length / CH);
    assertEquals(LA, chain.pendingTailFrames());

    float[] tail = new float[(LA + 8) * CH];
    int tailFrames = chain.drainTail(tail);
    assertEquals(LA, tailFrames);
    assertEquals(0, chain.pendingTailFrames());
    // 尾音内容 = 输入的最后 256 帧（全 0 增益下逐样本一致）
    float[] expected = Arrays.copyOfRange(in, (frames - LA) * CH, frames * CH);
    assertArrayEquals(expected, Arrays.copyOf(tail, LA * CH), 0f);
  }
}
