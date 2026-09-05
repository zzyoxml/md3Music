package com.md3music.md3music;

import com.ryanheise.just_audio.UsbAudioSink;

/**
 * 把应用模块的 UsbAudioStream（JNI usbdevfs 驱动）适配为 just_audio fork 定义的
 * {@link UsbAudioSink} 接口，供 UsbAudioSinkController 在编译期引用。
 */
public class UsbAudioAdapter implements UsbAudioSink {

    private final UsbAudioStream stream;

    public UsbAudioAdapter(UsbAudioStream stream) {
        this.stream = stream;
    }

    public UsbAudioStream getStream() {
        return stream;
    }

    @Override public boolean isReady() { return stream.isReady(); }
    @Override public boolean isAlive() { return stream.isAlive(); }
    @Override public long getFramesWritten() { return stream.getFramesWritten(); }
    @Override public boolean start() { return stream.start(); }
    @Override public void stop() { stream.stop(); }
    @Override public int drainUrbs() { return stream.drainUrbs(); }
    @Override public void release() { stream.release(); }
    @Override public void flush() { stream.flush(); }
    @Override public void write(float[] pcm) { stream.write(pcm); }
    @Override public void writeRaw(byte[] pcm, int encoding) { stream.writeRaw(pcm, encoding); }
}
