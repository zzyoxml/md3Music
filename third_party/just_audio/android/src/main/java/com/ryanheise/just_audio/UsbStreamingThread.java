package com.ryanheise.just_audio;

import android.util.Log;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.TimeUnit;

/**
 * 独立 USB 写线程：从 ExoPlayer 渲染线程解耦。
 * 移植自 decent-player libs/decent-usb-audio-wrapper-media3 的 UsbStreamingThread.kt。
 *
 * 支持两类缓冲：FloatBuffer（float PCM）与 RawBuffer（整数 PCM 字节）。
 * 队列满时丢最旧（drop-oldest），由 handleBuffer 的背压阈值（16）兜底。
 */
final class UsbStreamingThread {

    private static final String TAG = "UsbStreamingThread";
    private static final int QUEUE_CAPACITY = 128;
    private static final long POLL_TIMEOUT_MS = 100L;

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

    private final UsbAudioSink usbStream;

    private volatile boolean running = false;
    private volatile boolean paused = false;
    private Thread thread = null;
    private int dropCount = 0;

    UsbStreamingThread(UsbAudioSink usbStream) {
        this.usbStream = usbStream;
    }

    void start() {
        running = true;
        thread = new Thread(() -> {
            Log.i(TAG, "USB streaming thread started");
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
                    Log.w(TAG, "Queue EMPTY — poll timeout");
                    continue;
                }
                try {
                    if (buf.isFloat) {
                        usbStream.write(buf.floatData);
                    } else {
                        usbStream.writeRaw(buf.rawData, buf.encoding);
                    }
                } catch (Exception e) {
                    Log.e(TAG, "USB write failed: " + e.getMessage(), e);
                    // 写失败不终止线程，等待下次机会（避免崩溃）
                }
                if (qBefore <= 1) {
                    Log.w(TAG, "Queue nearly empty: " + qBefore + " before write");
                }
            }
            Log.i(TAG, "USB streaming thread exited");
        }, "UsbStreamingThread");
        thread.setPriority(Thread.MAX_PRIORITY);
        thread.start();
    }

    /** 入队 float PCM。非阻塞，队列满丢最旧。 */
    void enqueue(float[] floatBuf) {
        AudioBuffer buf = new AudioBuffer(floatBuf);
        if (!audioQueue.offer(buf)) {
            audioQueue.poll();
            audioQueue.offer(buf);
            dropCount++;
            if (dropCount <= 3 || dropCount % 100 == 0) {
                Log.w(TAG, "Queue full, dropped buffer #" + dropCount);
            }
        }
    }

    /** 入队原始整数 PCM。非阻塞，队列满丢最旧。 */
    void enqueueRaw(byte[] rawBytes, int encoding) {
        AudioBuffer buf = new AudioBuffer(rawBytes, encoding);
        if (!audioQueue.offer(buf)) {
            audioQueue.poll();
            audioQueue.offer(buf);
            dropCount++;
            if (dropCount <= 3 || dropCount % 100 == 0) {
                Log.w(TAG, "Queue full, dropped raw buffer #" + dropCount);
            }
        }
    }

    void pauseStreaming() { paused = true; }

    void resumeStreaming() { paused = false; }

    boolean hasPendingData() { return !audioQueue.isEmpty(); }

    int queueSize() { return audioQueue.size(); }

    void flush() { audioQueue.clear(); }

    void stop() {
        running = false;
        audioQueue.clear();
        if (thread != null) {
            try {
                thread.join(2000);
            } catch (InterruptedException ignored) { }
            thread = null;
        }
    }
}
