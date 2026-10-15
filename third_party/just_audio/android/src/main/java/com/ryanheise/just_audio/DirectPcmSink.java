package com.ryanheise.just_audio;

import androidx.annotation.Nullable;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.MimeTypes;
import androidx.media3.exoplayer.audio.AudioSink;
import androidx.media3.exoplayer.audio.ForwardingAudioSink;
import java.nio.ByteBuffer;

/**
 * 系统 Direct PCM 的 AudioSink 拦截层（MD3Music fork）。
 *
 * **本层对 PCM 字节完全透传** —— 这是 bit-perfect 的核心约束：不做任何重采样、
 * 位深转换、增益或 dither。真正改变输出行为的三处都在 delegate
 * （{@code DefaultAudioSink}）里，以补丁形式实现：
 *
 * <ol>
 *   <li>{@code floatOutputRequested()} 强制 float32 —— 否则 24/32bit 源会被
 *       {@code ToInt16PcmAudioProcessor} 降为 16bit；</li>
 *   <li>{@code createAudioTrackV29} 请求 {@code PERFORMANCE_MODE_LOW_LATENCY}；</li>
 *   <li>缓冲尺寸调小（受 minBufferSize × 2 下限保护）。</li>
 * </ol>
 *
 * 本层只负责三件事：
 * <ul>
 *   <li>{@link #getFormatSupport}：声明「能直接吃 32bit 表示」，让
 *       {@code MediaCodecAudioRenderer} 给解码器下发
 *       {@code KEY_PCM_ENCODING=ENCODING_PCM_FLOAT}。这是顺序无关的唯一切入点
 *       （同 {@code UsbAudioSinkController} 的做法）。</li>
 *   <li>{@link #configure}：记录解码流格式，供状态上报与 bit-perfect 判据使用。</li>
 *   <li>{@link #setVolume}：记录实际音量（unity 判定用）。</li>
 * </ul>
 *
 * 未开启 Direct PCM 时全部退化为 {@code super} 调用，行为与改动前逐样本一致。
 */
public final class DirectPcmSink extends ForwardingAudioSink {

    public DirectPcmSink(AudioSink sink) {
        super(sink);
    }

    /**
     * Direct PCM 开启且「高规格输出」子开关生效时，声明 FLOAT / PCM_32BIT 可直接使用。
     *
     * <p>为什么不能只靠「32bit 播放支持」开关（{@code floatOutputRequested()}）：
     * 那个开关在独占路径上被硬编码为 false，能否生效取决于「解码器创建时刻独占是否已开」，
     * 同一首歌会因顺序不同得到不同结果（见 {@code UsbAudioSinkController} 的注释）。
     * 这里按「Direct PCM 状态本身」决定，语义与顺序无关。
     */
    @Override
    public @AudioSink.SinkFormatSupport int getFormatSupport(Format format) {
        if (DirectPcmController.isHighPrecisionOutputEnabled()
                && MimeTypes.AUDIO_RAW.equals(format.sampleMimeType)
                && (format.pcmEncoding == C.ENCODING_PCM_FLOAT
                        || format.pcmEncoding == C.ENCODING_PCM_32BIT)) {
            return AudioSink.SINK_FORMAT_SUPPORTED_DIRECTLY;
        }
        return super.getFormatSupport(format);
    }

    @Override
    public void configure(Format inputFormat, int specifiedBufferSize, @Nullable int[] outputChannels)
            throws ConfigurationException {
        DirectPcmController.onFormatConfigured(
                inputFormat.sampleRate, inputFormat.channelCount, inputFormat.pcmEncoding);
        // 不改写格式：本次不做进程内重采样，AudioTrack 率恒等于源率。
        // 率与 DAC 原生率不一致时由 AudioFlinger 重采样 —— 状态区会如实标注
        // 「非 bit-perfect」，而不是悄悄对齐（对齐方案见计划 P1）。
        super.configure(inputFormat, specifiedBufferSize, outputChannels);
    }

    @Override
    public void setVolume(float volume) {
        DirectPcmController.onVolume(volume);
        super.setVolume(volume);
    }

    @Override
    public void setAudioSessionId(int audioSessionId) {
        DirectPcmController.onAudioSessionId(audioSessionId);
        super.setAudioSessionId(audioSessionId);
    }

    // 注：本 fork 的 ForwardingAudioSink（media3 1.4.1）**没有**转发
    // handleSetOutputDeviceUs，因此无法在此钩住「输出设备被系统切换」。
    // 设备变化改由 DirectPcmPlugin 的 AudioManager.registerAudioDeviceCallback
    // 监听并推状态；DirectPcmCapabilities.resolveDevice 在 deviceId 匹配不到时
    // 会退化为「挑一个外置 DAC 输出」，不会因拔插而卡在旧设备上。

    @Override
    public void setPreferredDevice(@Nullable android.media.AudioDeviceInfo deviceInfo) {
        if (deviceInfo != null) {
            DirectPcmController.setDeviceId(deviceInfo.getId());
        }
        super.setPreferredDevice(deviceInfo);
    }

    @Override
    public boolean handleBuffer(ByteBuffer buffer, long offsetUs, int size)
            throws InitializationException, WriteException {
        // 字节级透传：DirectPcmSink 不碰任何样本。
        return super.handleBuffer(buffer, offsetUs, size);
    }
}
