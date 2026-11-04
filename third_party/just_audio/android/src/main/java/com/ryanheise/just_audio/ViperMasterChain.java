package com.ryanheise.just_audio;

import java.util.Arrays;

/**
 * 蝰蛇母带 DSP 核心（纯 Java、零 Android 依赖，可直接跑 JVM 单元测试）。
 *
 * <p>规格逐项对齐 EchoMusic native/echo-audio-player/src/dsp/basic.rs 与 limiter.rs：
 * <ul>
 *   <li>10 段 RBJ peaking EQ：31..16k、Q=1.414、±12dB、单段 |gain|&lt;0.05dB 视为无此段</li>
 *   <li>级联 headroom 预衰减：512 对数频点 + 各段中心频率测频响峰值，峰值&gt;1 先乘 1/peak</li>
 *   <li>参数变化 15ms 线性交叉淡化：新旧两套滤波器并行处理同一输入再混合，无点击</li>
 *   <li>256 帧 lookahead 联动峰值限幅：全声道一条增益包络；attack=1-0.000001^(1/256)、
 *       release=0.1s 指数平滑、天花板 1.0（仅拦截超数字满刻度的峰）</li>
 *   <li>knee 0.95 软削波；NaN/Inf 输入清零</li>
 * </ul>
 *
 * <p>线程约定：所有 DSP 状态只在音频线程变更（queueInput/getOutput/flush）；
 * 控制参数由 {@link ViperMasterProcessor} 以 volatile 挂起字段投递、queueInput 头部消费。
 * 关闭态 {@link #process} 逐样本原样透传——USB 独占输出的 bit-perfect 承诺。
 */
public final class ViperMasterChain {

  public static final int BAND_COUNT = 10;
  public static final float[] BAND_FREQUENCIES = {
    31f, 62f, 125f, 250f, 500f, 1000f, 2000f, 4000f, 8000f, 16000f,
  };
  /** 段 Q，与 EchoMusic dsp/basic.rs 的 EQ_Q 一致（RBJ 标准音乐均衡 Q）。 */
  public static final float BAND_Q = 1.414f;
  public static final float MIN_GAIN_DB = -12f;
  public static final float MAX_GAIN_DB = 12f;
  public static final int LOOKAHEAD = 256;
  /** 限幅天花板（EchoMusic limiter.rs DEFAULT_CEILING）：仅拦截超数字满刻度的峰。 */
  public static final float CEILING = 1.0f;
  public static final float SOFT_KNEE = 0.95f;
  public static final float TRANSITION_SECONDS = 0.015f;
  public static final double RELEASE_SECONDS = 0.1;
  /** 单段增益绝对值低于该 dB 值视为无此段（EchoMusic 同款 0.05）。 */
  public static final float BAND_EPSILON_DB = 0.05f;

  /** attack：峰值到达输出前（LOOKAHEAD 帧）残留增益差 < 1ppm。 */
  private static final float ATTACK_COEFF =
      (float) (1.0 - Math.pow(0.000001, 1.0 / LOOKAHEAD));
  private static final int HEADROOM_POINTS = 512;

  private int sampleRate;
  private int channelCount;

  private final float[] gains = new float[BAND_COUNT];
  private ViperBiquad[][] bankOut; // 当前/淡化起点 EQ bank（每声道一行）
  private ViperBiquad[][] bankIn;  // 淡化目标 bank
  private float preGainOut = 1f;
  private float preGainIn = 1f;
  private int fadeTotal;
  private int fadeDone;

  private float[][] delayRing;
  private float[] slotPeak;
  private int[] deque; // 单调递减队列：窗口滑动最大值（O(1)/帧）
  private int dequeHead;
  private int dequeCount;
  private int tail;
  private int ringFill;
  private float env = 1f;
  private float releaseCoeff;

  private float[] preFrame; // configure 时按声道数重建
  private boolean enabled;
  private boolean draining;

  /** 构造时以 48k/立体声默认配置；播放器 onConfigure 会重新配置。 */
  public ViperMasterChain() {
    configure(48000, 2);
  }

  // ==================== 配置与控制 ====================

  /** （重新）配置采样率与声道数；保留增益，重建 bank 与延迟线。 */
  public void configure(int sampleRate, int channelCount) {
    this.sampleRate = Math.max(1, sampleRate);
    this.channelCount = Math.max(1, channelCount);
    this.delayRing = new float[this.channelCount][LOOKAHEAD];
    this.slotPeak = new float[LOOKAHEAD];
    this.deque = new int[LOOKAHEAD];
    this.preFrame = new float[this.channelCount];
    this.releaseCoeff = (float) Math.exp(-1.0 / (RELEASE_SECONDS * this.sampleRate));
    this.bankOut = newBank();
    this.bankIn = this.bankOut;
    this.preGainOut = measurePreGain();
    this.preGainIn = this.preGainOut;
    this.fadeTotal = 0;
    this.fadeDone = 0;
    this.env = 1f;
    this.draining = false;
    this.tail = 0;
    this.ringFill = 0;
    this.dequeHead = 0;
    this.dequeCount = 0;
    // enabled 保留：开关跨格式生效
  }

  public boolean isEnabled() {
    return enabled;
  }

  /**
   * 开关处理链。
   * 开启：延迟线为空，进入暖机（内容顺序守恒，仅引入 LOOKAHEAD 帧延迟）。
   * 关闭：先把压在延迟线里的帧排空再直通，保证内容无缝、不丢单。
   */
  public void setEnabled(boolean value) {
    if (value) {
      enabled = true;
      draining = false;
    } else if (enabled) {
      if (ringFill > 0) {
        draining = true; // process 里排空后自动落 enabled=false
      } else {
        enabled = false;
      }
    }
  }

  /** 设置 10 段增益（dB，钳到 ±12）。关闭态直接落盘；开启态触发 15ms 交叉淡化。 */
  public void setGains(float[] values) {
    if (values == null || values.length != BAND_COUNT) {
      return;
    }
    for (int i = 0; i < BAND_COUNT; i++) {
      float g = values[i];
      if (!Float.isFinite(g)) {
        g = 0f;
      }
      gains[i] = Math.min(MAX_GAIN_DB, Math.max(MIN_GAIN_DB, g));
    }
    if (!enabled) {
      bankOut = newBank();
      bankIn = bankOut;
      preGainOut = measurePreGain();
      preGainIn = preGainOut;
      fadeTotal = 0;
      fadeDone = 0;
      return;
    }
    if (fadeTotal > 0) {
      commitFade(); // 淡化中则先提交当前目标作为新起点
    }
    bankIn = newBank();
    preGainIn = measurePreGain();
    fadeTotal = Math.max(1, Math.round(TRANSITION_SECONDS * sampleRate));
    fadeDone = 0;
  }

  // ==================== 主处理 ====================

  /**
   * 处理 frames 帧交错浮点样本（in 不被修改），结果写入 out 开头，返回输出帧数。
   * out 容量须 ≥ (frames + LOOKAHEAD) * channelCount（关闭排空/暖机差值场景）。
   */
  public int process(float[] in, int frames, float[] out) {
    int ch = channelCount;
    if (!enabled) {
      System.arraycopy(in, 0, out, 0, frames * ch);
      return frames;
    }
    int pos = 0;
    if (draining) {
      // 关闭瞬间：先放出延迟线里压着的帧（内容无缝），再直通本次输入
      while (ringFill > 0) {
        pos = emitOldest(out, pos);
      }
      draining = false;
      enabled = false;
      System.arraycopy(in, 0, out, pos, frames * ch);
      return pos / ch + frames;
    }
    for (int f = 0; f < frames; f++) {
      float t = fadeTotal > 0 ? (fadeDone + 1f) / fadeTotal : 1f;
      float pg = preGainOut + (preGainIn - preGainOut) * t;
      int base = f * ch;
      for (int c = 0; c < ch; c++) {
        float x = in[base + c];
        if (!Float.isFinite(x)) {
          x = 0f; // sanitize
        }
        x *= pg;
        preFrame[c] = applyEq(c, x, t);
      }
      if (ringFill == LOOKAHEAD) {
        pos = emitOldest(out, pos); // pop-before-push：窗口含最老帧
      }
      pushFrame(preFrame);
      if (fadeTotal > 0 && ++fadeDone >= fadeTotal) {
        commitFade();
      }
    }
    return pos / ch;
  }

  /** 曲尾排空 lookahead 尾音，返回输出帧数（≤ LOOKAHEAD）。 */
  public int drainTail(float[] out) {
    int pos = 0;
    while (ringFill > 0) {
      pos = emitOldest(out, pos);
    }
    return pos / channelCount;
  }

  /** 还压在延迟线里的帧数（EOS 时由处理器排空）。 */
  public int pendingTailFrames() {
    return ringFill;
  }

  /** seek/格式切换：清空延迟线与滤波器状态，保留增益与开关（歌曲边界不拖尾）。 */
  public void reset() {
    for (float[] row : delayRing) {
      Arrays.fill(row, 0f);
    }
    Arrays.fill(slotPeak, 0f);
    dequeHead = 0;
    dequeCount = 0;
    tail = 0;
    ringFill = 0;
    env = 1f;
    if (fadeTotal > 0) {
      commitFade();
    }
    resetBank(bankOut);
    if (bankIn != bankOut) {
      resetBank(bankIn);
    }
    if (draining) {
      draining = false;
      enabled = false;
    }
  }

  // ==================== 内部实现 ====================

  /** 取最老帧 → 联动限幅（单调队列窗口峰值）→ 软削波 → 写出，返回新 pos。 */
  private int emitOldest(float[] out, int pos) {
    int ch = channelCount;
    float peak = dequeCount > 0 ? slotPeak[deque[dequeHead]] : 0f;
    float target = peak > CEILING ? CEILING / peak : 1f;
    env =
        target < env
            ? env + (target - env) * ATTACK_COEFF
            : env + (target - env) * releaseCoeff;
    int slot = tail;
    if (dequeCount > 0 && deque[dequeHead] == slot) {
      dequeHead = (dequeHead + 1) % LOOKAHEAD;
      dequeCount--;
    }
    tail = (tail + 1) % LOOKAHEAD;
    ringFill--;
    for (int c = 0; c < ch; c++) {
      out[pos + c] = softLimit(delayRing[c][slot] * env);
    }
    return pos + ch;
  }

  /** 把一帧写入延迟线尾部并维护跨声道 slotPeak 与单调队列。 */
  private void pushFrame(float[] frame) {
    int slot = (tail + ringFill) % LOOKAHEAD;
    float max = 0f;
    for (int c = 0; c < channelCount; c++) {
      delayRing[c][slot] = frame[c];
      float a = Math.abs(frame[c]);
      if (a > max) {
        max = a;
      }
    }
    slotPeak[slot] = max;
    while (dequeCount > 0
        && slotPeak[deque[(dequeHead + dequeCount - 1) % LOOKAHEAD]] <= max) {
      dequeCount--;
    }
    deque[(dequeHead + dequeCount) % LOOKAHEAD] = slot;
    dequeCount++;
    ringFill++;
  }

  /** 按淡化进度混合新旧 bank；非淡化态只跑 bankOut。 */
  private float applyEq(int c, float x, float t) {
    if (fadeTotal <= 0) {
      return runRow(bankOut[c], x);
    }
    float y0 = runRow(bankOut[c], x);
    float y1 = runRow(bankIn[c], x);
    return y0 + (y1 - y0) * t;
  }

  private static float runRow(ViperBiquad[] row, float x) {
    for (ViperBiquad b : row) {
      if (b != null) {
        x = b.process(x);
      }
    }
    return x;
  }

  /** knee 0.95 软削波（EchoMusic soft_limit_sample 同款）。 */
  private static float softLimit(float x) {
    float m = Math.abs(x);
    if (m <= SOFT_KNEE) {
      return x;
    }
    float range = 1f - SOFT_KNEE;
    float limited = SOFT_KNEE + range * (1f - (float) Math.exp(-(m - SOFT_KNEE) / range));
    if (limited > 1f) {
      limited = 1f;
    }
    return x < 0 ? -limited : limited;
  }

  private void commitFade() {
    bankOut = bankIn;
    preGainOut = preGainIn;
    fadeTotal = 0;
    fadeDone = 0;
  }

  /** 按当前 gains 构建整条 bank（|gain|<0.05dB 的段不建滤波器）。 */
  private ViperBiquad[][] newBank() {
    ViperBiquad[][] bank = new ViperBiquad[channelCount][BAND_COUNT];
    for (int c = 0; c < channelCount; c++) {
      for (int b = 0; b < BAND_COUNT; b++) {
        if (Math.abs(gains[b]) < BAND_EPSILON_DB) {
          continue;
        }
        bank[c][b] = ViperBiquad.peaking(sampleRate, BAND_FREQUENCIES[b], BAND_Q, gains[b]);
      }
    }
    return bank;
  }

  /** 级联 headroom：512 对数频点 + 各段中心频率找峰值，返回线性预衰减（≤1）。 */
  private float measurePreGain() {
    ViperBiquad[] row = bankIn[0];
    boolean any = false;
    for (ViperBiquad b : row) {
      if (b != null) {
        any = true;
        break;
      }
    }
    if (!any) {
      return 1f;
    }
    double peak = 1.0;
    double logMin = Math.log(20.0);
    double logMax = Math.log(20000.0);
    for (int i = 0; i < HEADROOM_POINTS; i++) {
      double f = Math.exp(logMin + (logMax - logMin) * i / (HEADROOM_POINTS - 1.0));
      if (f >= sampleRate * 0.5) {
        break; // 超过奈奎斯特
      }
      peak = Math.max(peak, cascadeMagnitude(row, 2.0 * Math.PI * f / sampleRate));
    }
    for (float fc : BAND_FREQUENCIES) { // 各段中心频率补测（对数点可能踩不中）
      if (fc >= sampleRate * 0.5) {
        continue;
      }
      peak = Math.max(peak, cascadeMagnitude(row, 2.0 * Math.PI * fc / sampleRate));
    }
    return peak > 1.0 ? (float) (1.0 / peak) : 1f;
  }

  private static double cascadeMagnitude(ViperBiquad[] row, double omega) {
    double mag = 1.0;
    for (ViperBiquad b : row) {
      if (b != null) {
        mag *= b.magnitudeAt(omega);
        if (!Double.isFinite(mag) || mag > 1e12) {
          return Double.MAX_VALUE;
        }
      }
    }
    return mag;
  }

  private static void resetBank(ViperBiquad[][] bank) {
    for (ViperBiquad[] row : bank) {
      for (ViperBiquad b : row) {
        if (b != null) {
          b.reset();
        }
      }
    }
  }
}
