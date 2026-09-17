package com.ryanheise.just_audio;

import android.util.Log;
import androidx.annotation.Nullable;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.exoplayer.audio.AudioSink;
import androidx.media3.exoplayer.audio.ForwardingAudioSink;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;

/**
 * 音量均衡（响度归一）增益装饰器（MD3Music fork）。
 *
 * <p>在 AudioSink 出口对 PCM 逐样本乘以一个「逐轨固定线性增益」。增益可 &gt;1（放大，
 * ExoPlayer 的 AudioTrack 只能衰减），用于把安静歌放大到参考响度；也可 &lt;1 压低响亮歌。
 * 正常输出与 USB 独占输出两条路径统一生效（本装饰器包在 UsbAudioSinkController.wrap 之外，
 * 其 handleBuffer 先缩放，再把已增益的 PCM 交给下层，USB 捕获到的即为此缩放后的数据）。
 *
 * <p>工程要点：
 * <ul>
 *   <li>基于 {@link ForwardingAudioSink}，仅 override configure / handleBuffer，其余透传。</li>
 *   <li>handleBuffer 只有在未完全消费（返回 false）时，ExoPlayer 会用<b>同一</b> buffer 重试，
 *       因此返回 false 前必须用 1/gain 撤销本次就地缩放，避免重复放大。</li>
 *   <li>仅对 PCM 缩放；passthrough（压缩编码）跳过。编码在 configure 里从 inputFormat 记录。</li>
 * </ul>
 */
public final class NormalizationGainAudioSink extends ForwardingAudioSink {

    private static final String TAG = "NormGainSink";

    /** 增益钳位，与 EchoMusic shared/loudness.ts 的 MIN/MAX_NORMALIZATION_GAIN_DB 一致。 */
    private static final double MIN_GAIN_DB = -40.0;
    private static final double MAX_GAIN_DB = 20.0 * Math.log10(3.0); // ≈ +9.54 dB（线性 3×）

    /** 当前线性增益，默认 1.0（旁路）。跨线程（channel 线程写、渲染线程读）。 */
    private volatile float gain = 1.0f;

    /** 当前解码输出编码（passthrough 时不会是 PCM，缩放会跳过）。 */
    private volatile int pcmEncoding = C.ENCODING_PCM_16BIT;

    /** 已创建实例（每 AudioSink 一个）。供 app 侧全局增益设置广播给所有实例。 */
    private static final java.util.List<NormalizationGainAudioSink> INSTANCES =
            new java.util.concurrent.CopyOnWriteArrayList<>();

    private NormalizationGainAudioSink(AudioSink delegate) {
        super(delegate);
        INSTANCES.add(this);
    }

    /** 包装 AudioSink。不启用（gain=1）时行为与不包装完全一致。 */
    public static NormalizationGainAudioSink wrap(AudioSink delegate) {
        return new NormalizationGainAudioSink(delegate);
    }

    /** 全局设置归一增益（单位 dB），广播到所有已创建的实例。 */
    public static void setGlobalGainDb(double gainDb) {
        for (NormalizationGainAudioSink sink : INSTANCES) {
            sink.setNormalizationGainDb(gainDb);
        }
    }

    /** 设置归一增益（单位 dB）。调用任意线程安全。 */
    public void setNormalizationGainDb(double gainDb) {
        double clamped = Math.min(MAX_GAIN_DB, Math.max(MIN_GAIN_DB, gainDb));
        gain = (float) Math.pow(10.0, clamped / 20.0);
        Log.i(TAG, "setNormalizationGainDb=" + gainDb + " linear=" + gain);
    }

    @Override
    public void configure(
            Format inputFormat, int specifiedBufferSize, @Nullable int[] outputChannels)
            throws ConfigurationException {
        super.configure(inputFormat, specifiedBufferSize, outputChannels);
        // 记录解码输出编码用于 handleBuffer 精确缩放。
        pcmEncoding =
                isPcmEncoding(inputFormat.pcmEncoding) ? inputFormat.pcmEncoding : C.ENCODING_INVALID;
    }

    @Override
    public boolean handleBuffer(
            ByteBuffer buffer, long presentationTimeUs, int encodedAccessUnitCount)
            throws InitializationException, WriteException {
        float g = gain;
        boolean scaled = false;
        if (g != 1.0f && buffer != null && buffer.hasRemaining() && pcmEncoding != C.ENCODING_INVALID) {
            scaleBuffer(buffer, g, pcmEncoding);
            scaled = true;
        }
        boolean handled;
        try {
            handled = super.handleBuffer(buffer, presentationTimeUs, encodedAccessUnitCount);
        } catch (RuntimeException e) {
            // 异常时同样撤销，保证底层可安全重试。
            if (scaled) scaleBuffer(buffer, 1.0f / g, pcmEncoding);
            throw e;
        }
        if (!handled && scaled) {
            // 未消费完：底层将用同一 buffer 重试，撤销本次缩放避免重复放大。
            scaleBuffer(buffer, 1.0f / g, pcmEncoding);
        }
        return handled;
    }

    private static boolean isPcmEncoding(@C.Encoding int encoding) {
        return encoding == C.ENCODING_PCM_8BIT
                || encoding == C.ENCODING_PCM_16BIT
                || encoding == C.ENCODING_PCM_24BIT
                || encoding == C.ENCODING_PCM_32BIT
                || encoding == C.ENCODING_PCM_FLOAT;
    }

    /** 就地缩放 [position, limit) 的 PCM 数据。不改变 buffer 的 position/limit。 */
    private static void scaleBuffer(ByteBuffer buffer, float gain, int encoding) {
        ByteBuffer dup = buffer.duplicate().order(ByteOrder.LITTLE_ENDIAN);
        if (encoding == C.ENCODING_PCM_FLOAT) {
            FloatBuffer fb = dup.asFloatBuffer();
            while (fb.hasRemaining()) {
                float v = fb.get();
                fb.put(fb.position() - 1, clampFloat(v * gain));
            }
            return;
        }
        switch (encoding) {
            case C.ENCODING_PCM_8BIT:
                while (dup.hasRemaining()) {
                    int v = (dup.get() & 0xFF) - 128; // 无符号 8bit → ±128
                    dup.put((byte) (clamp(v * gain, -128, 127) + 128));
                }
                break;
            case C.ENCODING_PCM_16BIT:
                while (dup.remaining() >= 2) {
                    short v = dup.getShort();
                    dup.putShort((short) clamp(v * gain, Short.MIN_VALUE, Short.MAX_VALUE));
                }
                break;
            case C.ENCODING_PCM_24BIT:
                while (dup.remaining() >= 3) {
                    int v = readInt24(dup);
                    writeInt24(dup, clamp(v * gain, -8388608, 8388607));
                }
                break;
            case C.ENCODING_PCM_32BIT:
                while (dup.remaining() >= 4) {
                    int v = dup.getInt();
                    dup.putInt(clamp(v * gain, Integer.MIN_VALUE, Integer.MAX_VALUE));
                }
                break;
            default:
                // 未知 PCM：不缩放
                break;
        }
    }

    private static int readInt24(ByteBuffer b) {
        int x = (b.get() & 0xFF) | ((b.get() & 0xFF) << 8) | ((b.get() & 0xFF) << 16);
        return (x & 0x800000) != 0 ? (x | 0xFF000000) : x; // 符号扩展
    }

    private static void writeInt24(ByteBuffer b, int v) {
        b.put((byte) (v & 0xFF));
        b.put((byte) ((v >> 8) & 0xFF));
        b.put((byte) ((v >> 16) & 0xFF));
    }

    private static int clamp(double v, int min, int max) {
        if (v < min) return min;
        if (v > max) return max;
        return (int) v;
    }

    private static float clampFloat(float v) {
        if (v < -1.0f) return -1.0f;
        if (v > 1.0f) return 1.0f;
        return v;
    }
}