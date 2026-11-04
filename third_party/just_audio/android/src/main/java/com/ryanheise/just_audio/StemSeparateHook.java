package com.ryanheise.just_audio;

/**
 * 端侧人声/伴奏分离的执行钩子（MD3Music fork）。
 *
 * <p>由 app 侧（Kotlin 插件）实现并注入 {@link StemSeparateProcessor}。fork 自身
 * 不依赖任何推理运行时（TFLite/ONNX），只负责把解码后的 PCM 递进去、把处理结果
 * 递回 AudioSink，因此公开树可以安全地携带本接口与处理器。
 *
 * <p><b>统一用 float 表示样本</b>（`1.0f` = 0 dBFS）。理由：
 * <ul>
 *   <li>float 输出管线（开启「32bit 播放支持」/ Direct PCM 高规格档）本来就是
 *       float32，用 short 中转会把 24bit 精度砍成 16bit；</li>
 *   <li>16bit 输入用 `x / 32768f` 进来、`x * 32767f` 回去可无损往返（实测），
 *       两条管线共用一套实现；</li>
 *   <li>分离内部（STFT/OLA/混音）本来就是 float 运算，少一层来回转换。</li>
 * </ul>
 *
 * <p><b>线程纪律</b>：{@link #process} 在 ExoPlayer 的**渲染线程**上被调用，
 * 实现必须**非阻塞**——只做取数与混音，推理交给自己的 worker 线程。任何阻塞
 * 都会直接变成音频欠载。
 *
 * <p><b>帧对齐契约</b>：输出帧与输入帧一一对应。实现方必须保证第 i 帧输出
 * 永远对应第 i 帧输入（预热期与过期块回落原音），这样上层不需要任何延迟补偿。
 */
public interface StemSeparateHook {

  /** 音频格式变化（含首次配置）。渲染线程调用，必须快速返回。 */
  void configure(int sampleRate, int channelCount);

  /**
   * 处理一段交错的 PCM（float 表示，`1.0f` = 0 dBFS）。
   *
   * @param in 输入样本（交错，长度 = {@code frames * channelCount}），只读
   * @param frames 输入帧数
   * @param out 输出缓冲（长度 >= {@code frames * channelCount}），实现写入的样本数
   *            由返回值告知；未写满的部分由调用方用**输入原音**补齐
   * @param channelCount 声道数
   * @return 实际写入 {@code out} 的帧数（0..frames）。返回 0 表示这一批还没准备好，
   *         调用方会整段回落到原音，绝不补零（补零会听成断续）
   */
  int process(float[] in, int frames, float[] out, int channelCount);

  /** seek / 格式切换：清空流式状态与缓冲。渲染线程调用，必须快速返回。 */
  void flush();

  /** 释放资源。可能不在渲染线程上。 */
  void release();

  /** 模型是否已就绪（未就绪时处理器直接透传，省掉一次跨线程调用）。 */
  boolean isReady();
}
