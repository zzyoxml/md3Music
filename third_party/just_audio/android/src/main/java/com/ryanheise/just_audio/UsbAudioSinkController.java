package com.ryanheise.just_audio;

import android.content.Context;
import android.util.Log;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.exoplayer.audio.AudioSink;
import androidx.media3.exoplayer.audio.ForwardingAudioSink;
import java.nio.ByteBuffer;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * USB 独占输出控制器（MD3Music fork）。
 *
 * 设计（对齐 decent-player 的 UsbAudioSink.kt，裁剪掉 NativeAudioEngine 部分）：
 * - [wrap] 始终包装 AudioSink：未开启独占时完全透传，开启后拦截 handleBuffer 的
 *   PCM → UsbStreamingThread → 应用侧 UsbAudioSink（JNI usbdevfs 直写 DAC）。
 * - 包装器在 ExoPlayer 构建时注入，运行时开关（enable/disable）无需重建播放器。
 * - 委托 AudioTrack 保持存活但被静音并强制路由内置扬声器，仅用于 ExoPlayer 时钟/状态机。
 * - 采样率/声道变化（configure 回调）时经 [UsbAudioReconfigListener] 交给应用侧重建流。
 *
 * 线程模型：configure/handleBuffer 在 ExoPlayer 渲染线程执行；USB 写入在
 * UsbStreamingThread（MAX_PRIORITY）执行；enable/disable 由应用侧 MethodChannel 线程触发。
 */
public final class UsbAudioSinkController {

    private static final String TAG = "UsbAudioSinkCtrl";

    /** 队列接近满时返回 false，让 ExoPlayer 稍后重试（背压，匹配 DAC 时钟）。 */
    private static final int QUEUE_BACKPRESSURE_THRESHOLD = 16;

    // ── 全局开关与活动流（由应用侧 UsbAudioPlugin 管理） ──
    private static volatile boolean exclusiveEnabled = false;
    private static volatile UsbAudioSink activeStream = null;
    private static volatile int activeDacBitDepth = 0;
    private static volatile UsbAudioReconfigListener reconfigListener = null;

    // ── 32bit 播放支持开关（默认关闭） ─────────────────────────
    // 开启后让 ExoPlayer 恢复 float 输出（24/32bit 高规格走 float32 直通 AudioTrack）。
    // 注意：部分设备 stereo float 播放异常（速度加快/音高变高），故默认关闭，需用户主动开启。
    // DefaultAudioSink 每个 configure 都会读取该实时标志，因此切歌即生效，无需重建播放器。
    private static volatile boolean floatOutputEnabled = false;

    public static void setFloatOutputEnabled(boolean enabled) {
        floatOutputEnabled = enabled;
    }

    public static boolean isFloatOutputEnabled() {
        return floatOutputEnabled;
    }

    // ── 最近一次 ExoPlayer 解码输出格式（无论是否开启独占都会捕获，供歌曲信息页/初始化使用） ──
    private static volatile int lastSampleRate = 0;
    private static volatile int lastChannelCount = 0;
    private static volatile int lastEncoding = C.ENCODING_PCM_16BIT;

    // ── 当前 USB 流实际使用的采样率/声道（格式变更检测用） ──
    private static volatile int usbSampleRate = 0;
    private static volatile int usbChannelCount = 0;

    /** 最近一次播放器音量（0..1）。DAC 音量 = 系统媒体音量 × 该值。 */
    private static volatile float lastPlayerVolume = 1f;

    /** 播放器音量变化回调（应用侧用它更新 DAC 硬件音量）。 */
    public interface UsbVolumeListener {
        void onPlayerVolumeChanged(float volume);
    }

    private static volatile UsbVolumeListener volumeListener = null;

    public static void setVolumeListener(UsbVolumeListener listener) {
        volumeListener = listener;
    }

    public static float getLastPlayerVolume() {
        return lastPlayerVolume;
    }

    // ── PCM 频谱捕获（MD3Music 频谱功能用） ────────────────────────
    // 无论是否 USB 独占，都在 handleBuffer 截取解码后的原始 PCM 快照。
    // 该数据在 AudioFlinger 混音之前，不受系统媒体音量影响 —— 静音播放时
    // 频谱依然有真实数据（Visualizer 做不到这点）。
    public interface PcmCaptureListener {
        /**
         * @param buffer      当前块 PCM（position 指向读取起点，调用方勿改动原始 buffer）
         * @param encoding    C.ENCODING_PCM_16BIT / PCM_24BIT / PCM_32BIT / PCM_FLOAT
         * @param sampleRate  解码采样率（Hz）
         * @param channelCount 声道数
         */
        void onPcm(java.nio.ByteBuffer buffer, int encoding, int sampleRate, int channelCount);
    }

    private static volatile PcmCaptureListener pcmCaptureListener = null;

    public static void setPcmCaptureListener(PcmCaptureListener listener) {
        pcmCaptureListener = listener;
    }

    /** 所有存活包装器（应用可能创建多个播放器实例）。 */
    private static final List<UsbInterceptAudioSink> liveSinks = new CopyOnWriteArrayList<>();

    /** 采样率/声道变化时由控制器回调应用侧重建 USB 流。 */
    public interface UsbAudioReconfigListener {
        /**
         * @return 已按新格式创建并 start 的流；失败返回 null（控制器将回退普通输出）。
         */
        UsbAudioSink onFormatChanged(int sampleRate, int channelCount, int pcmEncoding);
    }

    private UsbAudioSinkController() {}

    // ── 静态 API（供应用侧插件调用） ──────────────────────────────

    /** 包装 AudioSink。未开启独占时行为与不包装完全一致。 */
    public static AudioSink wrap(AudioSink delegate, Context context) {
        UsbInterceptAudioSink sink = new UsbInterceptAudioSink(delegate, context);
        liveSinks.add(sink);
        return sink;
    }

    /** 开启独占。应用侧须先完成：打开设备 → 创建流 → 按 xHCI 时序 setAlt/SET_CUR/start。 */
    public static synchronized boolean enable(UsbAudioSink stream, int dacBitDepth,
                                              int sampleRate, int channelCount) {
        if (stream == null || !stream.isReady()) {
            Log.e(TAG, "enable: stream not ready");
            return false;
        }
        if (sampleRate <= 0) sampleRate = lastSampleRate;
        if (channelCount <= 0) channelCount = lastChannelCount;
        activeStream = stream;
        activeDacBitDepth = dacBitDepth;
        usbSampleRate = sampleRate;
        usbChannelCount = channelCount;
        exclusiveEnabled = true;
        for (UsbInterceptAudioSink s : liveSinks) s.onExclusiveChanged(true);
        Log.i(TAG, "exclusive ENABLED: " + usbSampleRate + "Hz/" + usbChannelCount
                + "ch dac=" + dacBitDepth + "bit");
        return true;
    }

    /**
     * 关闭独占（阶段一）：停写线程、清活动流。
     * 注意：不在此处恢复 delegate 音量/路由 —— 必须先由调用方释放 USB 设备
     * （stop→drain→release→closeDevice，否则 DAC 仍被占用，delegate 路由回去会无声），
     * 再调用 [onUsbReleased] 恢复。顺序见 UsbAudioPlugin.disableExclusive。
     */
    public static synchronized UsbAudioSink disable() {
        UsbAudioSink old = activeStream;
        exclusiveEnabled = false;
        for (UsbInterceptAudioSink s : liveSinks) s.stopStreamingThread();
        activeStream = null;
        activeDacBitDepth = 0;
        Log.i(TAG, "exclusive DISABLED (delegate restore deferred to onUsbReleased)");
        return old;
    }

    /** 关闭独占（阶段二）：USB 设备完全释放后调用，恢复 delegate 音量/路由。 */
    public static synchronized void onUsbReleased() {
        for (UsbInterceptAudioSink s : liveSinks) s.onExclusiveChanged(false);
    }

    public static boolean isEnabled() { return exclusiveEnabled; }

    public static void setReconfigListener(UsbAudioReconfigListener listener) {
        reconfigListener = listener;
    }

    public static int getLastSampleRate() { return lastSampleRate; }
    public static int getLastChannelCount() { return lastChannelCount; }
    public static int getLastEncoding() { return lastEncoding; }

    /** 歌曲信息页用：当前解码输出格式。 */
    public static Map<String, Object> getFormatInfo() {
        Map<String, Object> m = new HashMap<>();
        m.put("sampleRate", lastSampleRate);
        m.put("channelCount", lastChannelCount);
        m.put("encoding", lastEncoding);
        m.put("hasData", lastSampleRate > 0);
        return m;
    }

    /** 实时状态（设置页/歌曲信息页轮询）。 */
    public static Map<String, Object> getStatus() {
        Map<String, Object> m = new HashMap<>();
        m.put("enabled", exclusiveEnabled);
        m.put("streamReady", activeStream != null && activeStream.isReady());
        m.put("streamAlive", activeStream != null && activeStream.isAlive());
        m.put("framesWritten", activeStream != null ? activeStream.getFramesWritten() : 0L);
        m.put("sampleRate", usbSampleRate);
        m.put("channelCount", usbChannelCount);
        m.put("dacBitDepth", activeDacBitDepth);
        // 最近一次解码输出格式（未开启独占时也能展示歌曲信息）
        m.put("lastSampleRate", lastSampleRate);
        m.put("lastChannelCount", lastChannelCount);
        m.put("lastEncoding", lastEncoding);
        return m;
    }

    static String encName(int encoding) {
        if (encoding == C.ENCODING_PCM_FLOAT) return "FLOAT";
        if (encoding == C.ENCODING_PCM_16BIT) return "16BIT";
        if (encoding == C.ENCODING_PCM_24BIT) return "24BIT";
        if (encoding == C.ENCODING_PCM_32BIT) return "32BIT";
        return "UNKNOWN(" + encoding + ")";
    }

    // ── 拦截型 AudioSink ─────────────────────────────────────────

    static final class UsbInterceptAudioSink extends ForwardingAudioSink {

        private final Context context;
        private UsbStreamingThread streamingThread = null;
        private boolean delegateMuted = false;
        private float pendingVolume = 1f;
        private int currentEncoding = C.ENCODING_PCM_16BIT;
        private int currentSampleRate = 0;
        private int currentChannelCount = 0;
        private boolean isPlaying = false;
        private long handleBufferCallCount = 0;
        private long posLogCount = 0;
        private long usbStartMediaTimeUs = 0L;
        private boolean usbStartMediaTimeNeedsInit = true;
        private boolean handledEndOfStream = false;

        UsbInterceptAudioSink(AudioSink delegate, Context ctx) {
            super(delegate);
            this.context = ctx.getApplicationContext();
        }

        @Override
        public void configure(Format inputFormat, int specifiedBufferSize, int[] outputChannels)
                throws ConfigurationException {
            int enc = inputFormat.pcmEncoding;
            if (enc != Format.NO_VALUE) currentEncoding = enc;
            int sr = inputFormat.sampleRate > 0 ? inputFormat.sampleRate : 0;
            int ch = inputFormat.channelCount > 0 ? inputFormat.channelCount : 0;
            if (sr > 0 && ch > 0) {
                lastSampleRate = sr;
                lastChannelCount = ch;
            }
            lastEncoding = currentEncoding;
            currentSampleRate = sr;
            currentChannelCount = ch;
            Log.i(TAG, "configure: enc=" + encName(currentEncoding) + " rate=" + sr + " ch=" + ch);

            if (exclusiveEnabled && activeStream != null && activeStream.isAlive()) {
                // 切歌/采样率切换：重建 USB 流（先停旧流，再让应用侧按新格式重建）
                if (sr > 0 && ch > 0 && (sr != usbSampleRate || ch != usbChannelCount)) {
                    reconfigStream(sr, ch, currentEncoding);
                }
                super.configure(inputFormat, specifiedBufferSize, outputChannels);
                muteDelegateIfNeeded();
                return;
            }

            super.configure(inputFormat, specifiedBufferSize, outputChannels);
        }

        private void reconfigStream(int sampleRate, int channelCount, int encoding) {
            Log.i(TAG, "reconfigStream: " + sampleRate + "Hz/" + channelCount + "ch (was "
                    + usbSampleRate + "/" + usbChannelCount + ")");
            UsbAudioReconfigListener listener = reconfigListener;
            if (listener == null) {
                Log.w(TAG, "reconfigStream: no listener — keeping old stream");
                return;
            }
            // 与 enable/disable 互斥，避免并发切换时 double-release
            synchronized (UsbAudioSinkController.class) {
            // 1) 停掉所有写线程（线程持有旧流引用）
            for (UsbInterceptAudioSink s : liveSinks) s.stopStreamingThread();
            // 2) 停旧流并释放原生上下文（drain 必须在 setAlt(0) 前完成）。
            //    先置空 activeStream，防止重建窗口内 handleBuffer 触碰已释放的上下文
            UsbAudioSink old = activeStream;
            activeStream = null;
            if (old != null) {
                try { old.stop(); old.drainUrbs(); old.release(); } catch (Exception e) {
                    Log.e(TAG, "old stream release failed: " + e.getMessage());
                }
            }
            // 3) 应用侧重建（打开设备→创建流→setAlt(0)→SET_CUR→setAlt(N)→start）
            UsbAudioSink fresh = null;
            try {
                fresh = listener.onFormatChanged(sampleRate, channelCount, encoding);
            } catch (Exception e) {
                Log.e(TAG, "reconfig listener threw: " + e.getMessage(), e);
            }
            if (fresh != null && fresh.isReady()) {
                activeStream = fresh;
                usbSampleRate = sampleRate;
                usbChannelCount = channelCount;
                Log.i(TAG, "reconfigStream OK → " + sampleRate + "Hz/" + channelCount + "ch");
            } else {
                // 重建失败：回退普通输出。disable() 已停线程/清流；恢复 delegate 音量。
                // 设备连接保留（插件侧 currentAdapter 已清空，下次 enable 复用）。
                Log.e(TAG, "reconfigStream FAILED — falling back to normal output");
                if (fresh != null) { try { fresh.release(); } catch (Exception ignored) {} }
                disable();
                onUsbReleased();
            }
            }
        }

        @Override
        public boolean handleBuffer(ByteBuffer buffer, long presentationTimeUs, int encodedAccessUnitCount)
                throws InitializationException, WriteException {
            // ── 频谱 PCM 捕获：无论是否 USB 独占都截取（解码后、混音前，静音也有数据） ──
            PcmCaptureListener pcmListener = pcmCaptureListener;
            if (pcmListener != null && currentSampleRate > 0 && buffer != null && buffer.remaining() > 0) {
                try {
                    pcmListener.onPcm(
                            buffer.duplicate().order(buffer.order()),
                            currentEncoding, currentSampleRate, currentChannelCount);
                } catch (Exception e) {
                    Log.w(TAG, "pcm capture listener threw: " + e.getMessage());
                }
            }
            UsbAudioSink stream = activeStream;
            if (exclusiveEnabled && stream != null && stream.isAlive()) {
                muteDelegateIfNeeded();
                if (streamingThread == null) {
                    streamingThread = new UsbStreamingThread(stream);
                    // 暂停状态接管 → 线程创建即暂停（不消费队列 → 不写 DAC）
                    if (!isPlaying) streamingThread.pauseStreaming();
                    streamingThread.start();
                    Log.i(TAG, "USB streaming thread created (isPlaying=" + isPlaying + ")");
                }
                // 捕获媒体时间线偏移，用于 framesWritten → 播放进度换算
                if (usbStartMediaTimeNeedsInit) {
                    usbStartMediaTimeUs = Math.max(0L, presentationTimeUs);
                    usbStartMediaTimeNeedsInit = false;
                    Log.i(TAG, "usbStartMediaTimeUs=" + usbStartMediaTimeUs);
                }
                handleBufferCallCount++;
                // 诊断：前 5 次 + 每 500 次打印，观察暂停后是否仍有数据喂入
                if (handleBufferCallCount <= 5 || handleBufferCallCount % 500 == 0) {
                    Log.i(TAG, "handleBuffer #" + handleBufferCallCount + " pts=" + presentationTimeUs
                            + " isPlaying=" + isPlaying + " queue=" + streamingThread.queueSize()
                            + " enc=" + encName(currentEncoding));
                }
                // 背压：队列接近满时让 ExoPlayer 重试（暂停时线程不消费 → 队列堆积 →
                // 背压触发，renderer 停止 feed，但状态机保持正常，seek/恢复播放不受影响）
                if (streamingThread.queueSize() >= QUEUE_BACKPRESSURE_THRESHOLD) {
                    return false;
                }
                ByteBuffer snapshot = buffer.slice().order(buffer.order());
                if (currentEncoding == C.ENCODING_PCM_FLOAT) {
                    int totalSamples = snapshot.remaining() / 4;
                    if (totalSamples > 0) {
                        float[] floatBuf = new float[totalSamples];
                        snapshot.asFloatBuffer().get(floatBuf);
                        if (handleBufferCallCount <= 3) {
                            Log.i(TAG, "handleBuffer #" + handleBufferCallCount
                                    + ": FLOAT samples=" + totalSamples);
                        }
                        streamingThread.enqueue(floatBuf);
                    }
                } else {
                    int remaining = snapshot.remaining();
                    if (remaining > 0) {
                        byte[] rawBytes = new byte[remaining];
                        snapshot.get(rawBytes);
                        if (handleBufferCallCount <= 3) {
                            Log.i(TAG, "handleBuffer #" + handleBufferCallCount
                                    + ": RAW " + encName(currentEncoding) + " bytes=" + remaining);
                        }
                        streamingThread.enqueueRaw(rawBytes, currentEncoding);
                    }
                }
                buffer.position(buffer.limit());
                return true;
            }
            unmuteDelegateIfNeeded();
            return super.handleBuffer(buffer, presentationTimeUs, encodedAccessUnitCount);
        }

        @Override
        public long getCurrentPositionUs(boolean sourceEnded) {
            if (exclusiveEnabled && activeStream != null && activeStream.isAlive()) {
                if (usbStartMediaTimeNeedsInit) return AudioSink.CURRENT_POSITION_NOT_SET;
                long frames = activeStream.getFramesWritten();
                if (currentSampleRate > 0) {
                    return usbStartMediaTimeUs + frames * C.MICROS_PER_SECOND / currentSampleRate;
                }
                return AudioSink.CURRENT_POSITION_NOT_SET;
            }
            return super.getCurrentPositionUs(sourceEnded);
        }

        @Override public void play() {
            super.play();
            isPlaying = true;
            if (streamingThread != null) streamingThread.resumeStreaming();
            Log.i(TAG, "sink.play() → isPlaying=true (exclusive=" + exclusiveEnabled + ")");
        }

        @Override public void pause() {
            isPlaying = false;
            if (streamingThread != null) streamingThread.pauseStreaming();
            super.pause();
            Log.i(TAG, "sink.pause() → isPlaying=false (exclusive=" + exclusiveEnabled + ")");
        }

        @Override public void flush() {
            super.flush();
            if (streamingThread != null) streamingThread.flush();
            UsbAudioSink stream = activeStream;
            if (exclusiveEnabled && stream != null) {
                try { stream.flush(); } catch (Exception e) {
                    Log.e(TAG, "stream.flush failed: " + e.getMessage());
                }
            }
            usbStartMediaTimeNeedsInit = true;
            handledEndOfStream = false;
        }

        @Override public void reset() {
            // USB 流跨 reset 存活，configure() 管理其生命周期（与 dec 一致）
            super.reset();
        }

        @Override public void release() {
            stopStreamingThread();
            super.release();
            liveSinks.remove(this);
        }

        @Override public void setVolume(float volume) {
            // 节流：音量值没变时不通知应用侧（ExoPlayer 初始化可能多次 setVolume 同值）
            boolean changed = volume != lastPlayerVolume;
            pendingVolume = volume;
            lastPlayerVolume = volume;
            if (changed) {
                // 通知应用侧更新 DAC 硬件音量（独占时有效；未独占时应用侧会忽略）
                UsbVolumeListener l = volumeListener;
                if (l != null) l.onPlayerVolumeChanged(volume);
            }
            if (exclusiveEnabled && activeStream != null && activeStream.isAlive()) {
                // 独占：委托静音（真实音量走 USB 流，原生按位深直写不受音量影响）
                if (!delegateMuted) {
                    super.setVolume(0f);
                    delegateMuted = true;
                }
            } else {
                // 透传：始终把音量传给委托（dec 是条件包装无此路径，本设计始终包装必须处理）
                super.setVolume(volume);
                delegateMuted = false;
            }
        }

        @Override public void playToEndOfStream() throws WriteException {
            handledEndOfStream = true;
            super.playToEndOfStream();
        }

        @Override public boolean isEnded() {
            boolean r = super.isEnded();
            if (exclusiveEnabled && (++posLogCount % 500 == 1L)) {
                Log.i(TAG, "isEnded=" + r + " hasPending(super)=" + super.hasPendingData()
                        + " hasPending(thread)=" + (streamingThread != null && streamingThread.hasPendingData()));
            }
            return r;
        }

        @Override public boolean hasPendingData() {
            if (exclusiveEnabled && streamingThread != null && streamingThread.hasPendingData()) {
                return true;
            }
            return super.hasPendingData();
        }

        /** 开关状态变化时由控制器调用。 */
        void onExclusiveChanged(boolean enabled) {
            if (enabled) {
                // 注意：不做 setPreferredDevice 强制路由 —— 那会重启 delegate AudioTrack，
                // 导致 ExoPlayer renderer 误判为播放中（暂停状态也会被喂数据 → 每秒滴答播放）。
                // DAC 已被我们 claim（force=true 断开内核驱动），AudioFlinger 的 usb HAL
                // 打开必然失败并自动 fallback，无需显式路由即可防抢占。
                muteDelegateIfNeeded();
                usbStartMediaTimeNeedsInit = true;
            } else {
                stopStreamingThread();
                unmuteDelegateIfNeeded();
            }
        }

        private void stopStreamingThread() {
            if (streamingThread != null) {
                streamingThread.stop();
                streamingThread = null;
            }
        }

        private void muteDelegateIfNeeded() {
            if (!delegateMuted) {
                super.setVolume(0f);
                delegateMuted = true;
            }
        }

        private void unmuteDelegateIfNeeded() {
            if (delegateMuted) {
                super.setVolume(pendingVolume);
                delegateMuted = false;
            }
        }
    }
}
