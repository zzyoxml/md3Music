package com.ryanheise.just_audio;

import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.TimeUnit;

/**
 * 独立 USB 写线程：从 ExoPlayer 渲染线程解耦。
 * 移植自 decent-player libs/decent-usb-audio-wrapper-media3 的 UsbStreamingThread.kt。
 *
 * 支持两类缓冲：FloatBuffer（float PCM）与 RawBuffer（整数 PCM 字节）。
 * 队列满时丢最旧（drop-oldest），由 handleBuffer 的背压阈值（16）兜底。
 *
 * 背压模型（对齐系统 AudioTrack.write 的阻塞语义）：
 * 渲染线程在队列达到水线时调用 [awaitSpace] 有界阻塞，而不是立即返回 false 让
 * ExoPlayer 按「(被阻塞buffer pts − audioClock位置)/2」调度睡眠。我们的位置时钟
 * 依赖渲染线程持续喂入（framesWritten），调度睡眠会与位置冻结形成死锁
 * （实测 192k 源 burst 间隙 hbCount 永久冻结）。阻塞等待空位后数据即时可写。
 */
final class UsbStreamingThread {

    private static final String TAG = "UsbStreamingThread";
    private static final int QUEUE_CAPACITY = 128;
    private static final long POLL_TIMEOUT_MS = 100L;
    /** 背压水线：与 UsbAudioSinkController.QUEUE_BACKPRESSURE_THRESHOLD 保持一致。 */
    static final int BACKPRESSURE_THRESHOLD = 16;

    /** 统一缓冲包装（Java 版 sealed class 替代）。 */
    private static final class AudioBuffer {
        final boolean isFloat;
        final float[] floatData;
        final byte[] rawData;
        final int encoding;

        AudioBuffer(float[] data) {
            isFloat = true;
            floatData = data;
            rawData = null;
            encoding = 0;
        }

        AudioBuffer(byte[] data, int enc) {
            isFloat = false;
            floatData = null;
            rawData = data;
            encoding = enc;
        }
    }

    private final ArrayBlockingQueue<AudioBuffer> audioQueue =
            new ArrayBlockingQueue<>(QUEUE_CAPACITY);
    private final Object spaceLock = new Object();

    private final UsbAudioSink usbStream;

    private volatile boolean running = false;
    private volatile boolean paused = false;
    private Thread thread = null;
    private int dropCount = 0;
    /** flush 代次：seek/切歌清队列时递增，阻塞中的渲染线程据此立即退出。 */
    private volatile int flushGeneration = 0;

    UsbStreamingThread(UsbAudioSink usbStream) {
        this.usbStream = usbStream;
    }

    void start() {
        running = true;
        thread = new Thread(() -> {
            UsbAudioSinkController.logI(TAG, "USB streaming thread started");
            while (running) {
                if (paused) {
                    try { Thread.sleep(50); } catch (InterruptedException ignored) { }
                    continue;
                }
                final int qBefore = audioQueue.size();
                AudioBuffer buf;
                try {
                    buf = audioQueue.poll(POLL_TIMEOUT_MS, TimeUnit.MILLISECONDS);
                } catch (InterruptedException e) {
                    continue;
                }
                if (buf == null) {
                    if (!emptySnapshotDone) {
                        // 每个 flush 周期只打一次状态快照：renderer 停喂时定位用
                        emptySnapshotDone = true;
                        UsbAudioSinkController.logStreamingState(
                                "Queue EMPTY — renderer stopped feeding?",
                                thread != null && thread.isAlive(), audioQueue.size());
                    } else {
                        UsbAudioSinkController.logW(TAG, "Queue EMPTY — poll timeout");
                    }
                    // 停喂探测：由控制器统一判定（阈值 2.5s + 冷却 8s + 次数上限）
                    UsbAudioSinkController.onStallProbe(!paused);
                    continue;
                }
                try {
                    if (buf.isFloat) {
                        usbStream.write(buf.floatData);
                    } else {
                        usbStream.writeRaw(buf.rawData, buf.encoding);
                    }
                } catch (Exception e) {
                    UsbAudioSinkController.logE(TAG, "USB write failed: " + e.getMessage(), e);
                    // 写失败不终止线程，等待下次机会（避免崩溃）
                }
                if (qBefore <= 1) {
                    UsbAudioSinkController.logW(TAG, "Queue nearly empty: " + qBefore + " before write");
                }
                // 消费腾出空位：立即唤醒可能正在 awaitSpace 的渲染线程
                synchronized (spaceLock) { spaceLock.notifyAll(); }
            }
            UsbAudioSinkController.logI(TAG, "USB streaming thread exited");
        }, "UsbStreamingThread");
        thread.setPriority(Thread.MAX_PRIORITY);
        thread.start();
    }

    /**
     * 渲染线程背压：有界阻塞直到队列低于水线。
     *
     * @return true=已有空位可写；false=超时或被 pause/stop/flush 打断（调用方回退
     *         为 return false，不劣于旧行为）
     */
    boolean awaitSpace(long timeoutMs) {
        final int genAtEntry = flushGeneration;
        final long deadline = UsbAudioSinkController.nowMs() + timeoutMs;
        synchronized (spaceLock) {
            while (running && !paused && flushGeneration == genAtEntry) {
                if (audioQueue.size() < BACKPRESSURE_THRESHOLD) return true;
                long remain = deadline - UsbAudioSinkController.nowMs();
                if (remain <= 0) return false;
                try {
                    // 步进等待：enqueue/flush/stop/pause/resume/消费 均会 notifyAll
                    spaceLock.wait(Math.min(2L, remain));
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    return false;
                }
            }
            return false;
        }
    }

    /** 入队 float PCM。非阻塞，队列满丢最旧。 */
    void enqueue(float[] floatBuf) {
        UsbAudioSinkController.onDataEnqueued();
        AudioBuffer buf = new AudioBuffer(floatBuf);
        if (!audioQueue.offer(buf)) {
            audioQueue.poll();
            audioQueue.offer(buf);
            dropCount++;
            if (dropCount <= 3 || dropCount % 100 == 0) {
                UsbAudioSinkController.logW(TAG, "Queue full, dropped buffer #" + dropCount);
            }
        }
        synchronized (spaceLock) { spaceLock.notifyAll(); }
    }

    /** 入队原始整数 PCM。非阻塞，队列满丢最旧。 */
    void enqueueRaw(byte[] rawBytes, int encoding) {
        UsbAudioSinkController.onDataEnqueued();
        AudioBuffer buf = new AudioBuffer(rawBytes, encoding);
        if (!audioQueue.offer(buf)) {
            audioQueue.poll();
            audioQueue.offer(buf);
            dropCount++;
            if (dropCount <= 3 || dropCount % 100 == 0) {
                UsbAudioSinkController.logW(TAG, "Queue full, dropped raw buffer #" + dropCount);
            }
        }
        synchronized (spaceLock) { spaceLock.notifyAll(); }
    }

    void pauseStreaming() {
        paused = true;
        synchronized (spaceLock) { spaceLock.notifyAll(); }
    }

    void resumeStreaming() {
        paused = false;
        synchronized (spaceLock) { spaceLock.notifyAll(); }
    }

    /** Queue EMPTY 状态快照每个 flush 周期只打一次（flush 时由 sink 调用重置）。 */
    private volatile boolean emptySnapshotDone = false;

    void resetEmptySnapshot() { emptySnapshotDone = false; }

    boolean hasPendingData() { return !audioQueue.isEmpty(); }

    int queueSize() { return audioQueue.size(); }

    void flush() {
        audioQueue.clear();
        synchronized (spaceLock) {
            flushGeneration++;
            spaceLock.notifyAll();
        }
    }

    void stop() {
        running = false;
        audioQueue.clear();
        synchronized (spaceLock) { spaceLock.notifyAll(); }
        if (thread != null) {
            try {
                thread.join(2000);
            } catch (InterruptedException ignored) { }
            thread = null;
        }
    }
}
