package com.ryanheise.just_audio;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

/** RBJ peaking 双二阶滤波器单元测试。 */
public class ViperBiquadTest {

  /** 喂单位幅度正弦，跳过瞬态后测稳态峰值幅度（输入幅度=1，输出即增益倍数）。 */
  private static double steadyAmplitude(ViperBiquad b, float sampleRate, float freq) {
    double omega = 2.0 * Math.PI * freq / sampleRate;
    double max = 0.0;
    for (int i = 0; i < 2048 + 8192; i++) {
      double y = b.process((float) Math.sin(omega * i));
      if (i >= 2048) {
        max = Math.max(max, Math.abs(y));
      }
    }
    return max;
  }

  @Test
  public void peakingBoostMatchesDesignGain() {
    // +6dB → 中心频点幅度 = 10^(6/20) ≈ 1.9953
    ViperBiquad b = ViperBiquad.peaking(48000f, 1000f, 1.414f, 6f);
    double amp = steadyAmplitude(b, 48000f, 1000f);
    double expected = Math.pow(10.0, 6.0 / 20.0);
    assertEquals(expected, amp, 0.05 * expected);
  }

  @Test
  public void peakingCutMatchesDesignGain() {
    // -12dB → 中心频点幅度 = 10^(-12/20) ≈ 0.3162
    ViperBiquad b = ViperBiquad.peaking(48000f, 1000f, 1.414f, -12f);
    double amp = steadyAmplitude(b, 48000f, 1000f);
    double expected = Math.pow(10.0, -12.0 / 20.0);
    assertEquals(expected, amp, 0.05 * expected);
  }

  @Test
  public void nonFiniteInputSanitizedAndRecovers() {
    ViperBiquad b = ViperBiquad.peaking(48000f, 1000f, 1.414f, 6f);
    float nan = b.process(Float.NaN);
    // NaN 输入必须被清零且状态自愈
    assertEquals(0f, nan, 0f);
    // 后续正常输入不被污染
    float y = b.process(0.5f);
    assertTrue(Float.isFinite(y));
  }

  @Test
  public void magnitudeAtCenterEqualsDesignGain() {
    ViperBiquad b = ViperBiquad.peaking(48000f, 1000f, 1.414f, 6f);
    double w0 = 2.0 * Math.PI * 1000.0 / 48000.0;
    double expected = Math.pow(10.0, 6.0 / 20.0);
    assertEquals(expected, b.magnitudeAt(w0), 0.02 * expected);
  }
}
