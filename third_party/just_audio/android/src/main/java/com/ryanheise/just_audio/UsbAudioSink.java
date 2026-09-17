package com.ryanheise.just_audio;

/**
 * USB 音频流抽象：由应用侧（com.md3music.md3music.UsbAudioAdapter）实现，
 * 包装实际的 UsbAudioStream（JNI → usbdevfs 直写 DAC）。
 *
 * 定义在 just_audio fork 内是为了让 UsbAudioSinkController（同为 fork 内代码）
 * 能在编译期引用，同时避免 fork 反向依赖应用模块。
 */
public interface UsbAudioSink {
    /** 原生上下文是否创建成功。 */
    boolean isReady();

    /** 流是否处于运行状态（start 后、stop 前）。 */
    boolean isAlive();

    /** 自上次 start 以来写入 USB 的总帧数（用于进度跟踪）。 */
    long getFramesWritten();

    /** 启动流（提交 URB）。 */
    boolean start();

    /** 停止接收新写入（不排空管道）。 */
    void stop();

    /** 排空所有在飞 URB（必须在 stop 后、setAlt(0) 前调用）。 */
    int drainUrbs();

    /** 释放原生上下文。 */
    void release();

    /** 重置帧累加器与残余缓冲（seek/flush 时调用，防爆音）。 */
    void flush();

    /** 写入交错 float32 PCM。 */
    void write(float[] pcm);

    /** 写入原始整数 PCM 字节；encoding 为 Media3 的 C.ENCODING_PCM_* 常量。 */
    void writeRaw(byte[] pcm, int encoding);
}
