package com.ryanheise.just_audio;

/**
 * 线性插值重采样器（float interleaved）。
 *
 * 仅用于"输出格式强制"路径：用户选择的输出采样率与解码源不一致时，在数据进入
 * USB 队列前重采样。默认自适应路径完全不经过此类（bit-perfect 不受影响）。
 *
 * 跨块处理：保持小数帧位置 pos 连续；每块边界相位误差 < 1 帧（强制重采样场景可接受，
 * 不做跨块重叠插值以避免持有上一块引用）。
 */
final class UsbPcmResampler {

    private int srcRate = 0;
    private int dstRate = 0;
    private int channels = 0;

    /** 下一输出帧在当前块内的（小数）源帧位置。 */
    private double pos = 0.0;

    void setFormat(int srcRate, int channels, int dstRate) {
        if (srcRate != this.srcRate || channels != this.channels || dstRate != this.dstRate) {
            pos = 0.0;
        }
        this.srcRate = srcRate;
        this.channels = channels;
        this.dstRate = dstRate;
    }

    void reset() {
        pos = 0.0;
    }

    /**
     * 重采样一个 interleaved float 块。无需重采样时原样返回。
     */
    float[] process(float[] in) {
        if (in == null || in.length == 0 || channels <= 0
                || srcRate <= 0 || dstRate <= 0 || srcRate == dstRate) {
            return in;
        }
        final int ch = channels;
        final int inFrames = in.length / ch;
        if (inFrames == 0) return new float[0];

        final double step = (double) srcRate / dstRate;
        final int cap = (int) Math.ceil(inFrames / step) + 2;
        final float[] out = new float[cap * ch];
        int outFrames = 0;
        double p = pos;

        while (true) {
            int idx = (int) Math.floor(p);
            if (p < 0) idx = 0;                 // 跨块边界钳位（相位误差 <1 帧，不累积）
            if (idx >= inFrames - 1) break;     // 需要下一块首帧做插值，留待下一块
            final double frac = p - idx;
            final int base = idx * ch;
            for (int c = 0; c < ch; c++) {
                final float a = in[base + c];
                final float b = in[base + ch + c];
                out[outFrames * ch + c] = (float) (a + (b - a) * frac);
            }
            outFrames++;
            p += step;
        }
        pos = p - inFrames;
        if (pos < 0) pos = 0;

        final float[] result = new float[outFrames * ch];
        System.arraycopy(out, 0, result, 0, result.length);
        return result;
    }

    /**
     * 声道转换（在重采样前执行，channelCount 以目标声道为准）。
     * 支持任意 srcCh/dstCh 组合，保证输出帧布局严格为 frames × dstCh：
     * - 下混：N→1 取前两声道平均（单声道直通）；N→2 取前两声道。
     * - 上混：1→N 全部复制；2→N 按 UAC 标准声道位置填充——
     *   FL(0)=L、FR(1)=R、FC(2)=(L+R)/2、LFE(3)=静音、BL(4)=L、BR(5)=R、
     *   SL(6)=L、SR(7)=R；超出 8 位的位置偶数位填 L、奇数位填 R。
     * 无需转换时原样返回。
     */
    static float[] convertChannels(float[] in, int srcCh, int dstCh) {
        if (in == null || in.length == 0 || srcCh <= 0 || dstCh <= 0 || srcCh == dstCh) {
            return in;
        }
        final int frames = in.length / srcCh;
        final float[] out = new float[frames * dstCh];
        for (int i = 0; i < frames; i++) {
            // 源前两声道（单声道时 L=R=唯一声道）
            final float l = srcCh == 1 ? in[i] : in[i * srcCh];
            final float r = srcCh == 1 ? in[i] : in[i * srcCh + 1];
            if (dstCh == 1) {
                out[i] = srcCh == 1 ? in[i] : (l + r) * 0.5f;
                continue;
            }
            for (int c = 0; c < dstCh; c++) {
                final float v;
                if (srcCh == 1) {
                    v = in[i];                                  // 单声道上混：全声道复制
                } else {
                    v = upmixChannel(c, l, r);                  // 立体声按标准位置上混
                }
                out[i * dstCh + c] = v;
            }
        }
        return out;
    }

    /**
     * 立体声 → 目标声道位置 c 的采样值（UAC 声道位置顺序，见类注释）。
     * 必须逐位置显式映射——任何位置都要写入，错帧会导致 DAC 变速/杂音。
     */
    private static float upmixChannel(int c, float l, float r) {
        switch (c) {
            case 0: return l;          // FL 前置左
            case 1: return r;          // FR 前置右
            case 2: return (l + r) * 0.5f; // FC 前置中置
            case 3: return 0f;         // LFE 低音炮（静音，避免音乐灌入低音单元）
            case 4: return l;          // BL 后置左
            case 5: return r;          // BR 后置右
            case 6: return l;          // SL 侧置左
            case 7: return r;          // SR 侧置右
            default: return (c & 1) == 0 ? l : r; // 更高位置：成对分配 L/R
        }
    }
}
