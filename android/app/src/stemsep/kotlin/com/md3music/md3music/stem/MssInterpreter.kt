package com.md3music.md3music.stem

/**
 * MSS 推理后端抽象。
 *
 * 把 TFLite 隔离在这个接口后面有两个好处：
 * 1. [MssEngine] 的 STFT/OLA 与张量布局可以**纯 JVM 单测**（注入 fake 解释器），
 *    不需要 TFLite 运行库，也不需要真机；
 * 2. 日后若要换 LiteRT / ONNX 后端，只替换实现，数值核心不动。
 */
internal interface MssInterpreter {

    /** 28 路流式状态的形状（按 `input_2..29` 的顺序）。 */
    fun stateShapes(): List<IntArray>

    /**
     * 跑一次推理。
     *
     * @param input 长度 `8*4*1024` 的平面布局输入（就地读）
     * @param states 28 路状态；**必须就地回灌**（模型输出的 state 覆盖它）
     * @param output 长度 `8*16*1024` 的输出平面缓冲（就地写）
     */
    fun run(input: FloatArray, states: List<FloatArray>, output: FloatArray)

    /** 释放底层资源。 */
    fun close()
}
