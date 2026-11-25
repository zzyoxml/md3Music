package com.md3music.md3music.stem

import android.content.Context
import android.util.Log
import org.tensorflow.lite.Interpreter
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * 基于 TFLite（XNNPACK / CPU）的 MSS 解释器。
 *
 * ## 为什么强制 CPU、不用 GPU
 *
 * 参考仓 README 与实测结论都指向同一件事：**GPU 会性能倒退**。模型里有 32 个
 * `TRANSPOSE`/`TRANSPOSE_CONV`，在 GPU 上都要额外的 layout 转换；而 demo 里用旧
 * Java `GpuDelegate` 时部分 PowerVR/Mali 驱动会直接在驱动内部 segfault，把进程
 * 带走（Java 层 catch 不住）。因此这里只走 CPU + XNNPACK 多线程。
 *
 * ## 算子兼容
 *
 * 模型 228 个算子（CONV_2D 77 / TRANSPOSE 32 / CONCATENATION 32 / ADD 32 / PAD 28
 * / SLICE 20 / TRANSPOSE_CONV 4 / RESHAPE 2 / MUL 1），TFLite 标准内核全部覆盖，
 * 不需要 XNNPACK 之外的自定义算子。
 */
internal class TfliteMssInterpreter private constructor(
    private val interpreter: Interpreter,
    private val stateShapesList: List<IntArray>,
) : MssInterpreter {

    companion object {
        private const val TAG = "StemSep"
        const val MODEL_ASSET = "stem/mss-model.tflite"

        /**
         * 期望模型字节数（4,902,660）。拷到 filesDir 时用它校验，避免半写/截断
         * 的旧副本被当成有效模型（会以 "ByteBuffer is not large enough" 之类的
         * 莫名错误失败）。
         */
        private const val MODEL_BYTES = 4_902_660L

        /** 首次加载可能较慢（解压资产 + 建解释器），给一个独立的超时预算。 */
        private const val LOAD_TIMEOUT_MS = 8_000L

        /** 模型是否随包（公开树不带资产 → false）。 */
        fun assetPresent(context: Context): Boolean = try {
            context.assets.list("stem")?.contains("mss-model.tflite") == true
        } catch (t: Throwable) {
            false
        }

        /**
         * 创建解释器。失败返回 null（调用方据此把功能标为不可用，绝不崩）。
         */
        fun create(context: Context): TfliteMssInterpreter? {
            if (!assetPresent(context)) {
                Log.i(TAG, "模型缺失（公开树不带资产），端侧分离不可用")
                return null
            }
            return try {
                val modelFile = materialize(context)
                val threads = maxOf(2, Runtime.getRuntime().availableProcessors() / 2)
                val options = Interpreter.Options()
                    .setNumThreads(threads)
                    .setUseXNNPACK(true)
                    // 不做 GPU 委托：见类注释
                val itp = Interpreter(modelFile, options)

                // 契约自检：形状不符就当作不可用，避免后面算出垃圾频谱
                val inShape = itp.getInputTensor(0).shape()
                val outShape = itp.getOutputTensor(0).shape()
                if (inShape.size != 4 || inShape[1] != MssEngine.FRAMES ||
                    inShape[2] != 4 || inShape[3] != MssEngine.BINS
                ) {
                    Log.e(TAG, "输入张量形状不符: ${inShape.joinToString()}")
                    itp.close()
                    return null
                }
                if (outShape.size != 4 || outShape[1] != MssEngine.FRAMES ||
                    outShape[2] != 16 || outShape[3] != MssEngine.BINS
                ) {
                    Log.e(TAG, "输出张量形状不符: ${outShape.joinToString()}")
                    itp.close()
                    return null
                }

                val shapes = ArrayList<IntArray>()
                for (i in 1 until itp.inputTensorCount) {
                    shapes.add(itp.getInputTensor(i).shape())
                }
                Log.i(
                    TAG,
                    "模型就绪 threads=$threads states=${shapes.size} " +
                        "input=${inShape.joinToString("x")} output=${outShape.joinToString("x")}",
                )
                TfliteMssInterpreter(itp, shapes)
            } catch (t: Throwable) {
                Log.e(TAG, "创建解释器失败: ${t.javaClass.simpleName} ${t.message}")
                null
            }
        }

        /**
         * 把资产模型解到 filesDir（长度一致才复用）。
         *
         * TFLite 的 `Interpreter(File)` 需要真实文件；直接用 AssetFileDescriptor
         * 在压缩资产上不可靠，因此统一落地。校验用期望字节数而非实际长度比对，
         * 这样资产被替换后会自动重拷。
         */
        private fun materialize(context: Context): File {
            val dir = File(context.filesDir, "stem")
            if (!dir.exists()) dir.mkdirs()
            val out = File(dir, "mss-model.tflite")
            if (out.exists() && out.length() == MODEL_BYTES) return out

            val tmp = File(dir, "mss-model.tflite.tmp")
            context.assets.open(MODEL_ASSET).use { input ->
                FileOutputStream(tmp).use { os ->
                    val buf = ByteArray(1 shl 16)
                    while (true) {
                        val n = input.read(buf)
                        if (n <= 0) break
                        os.write(buf, 0, n)
                    }
                    os.flush()
                }
            }
            if (tmp.length() != MODEL_BYTES) {
                Log.e(TAG, "模型拷贝长度异常 actual=${tmp.length()} expect=$MODEL_BYTES")
            }
            // 覆盖旧的（原子性够用：先写 tmp 再 rename，避免半写副本被读到）
            if (out.exists()) out.delete()
            if (!tmp.renameTo(out)) {
                tmp.copyTo(out, overwrite = true)
                tmp.delete()
            }
            return out
        }
    }

    private val inBuf: ByteBuffer =
        ByteBuffer.allocateDirect(MssEngine.FRAMES * 4 * MssEngine.BINS * 4)
            .order(ByteOrder.nativeOrder())
    private val outBuf: ByteBuffer =
        ByteBuffer.allocateDirect(MssEngine.FRAMES * 16 * MssEngine.BINS * 4)
            .order(ByteOrder.nativeOrder())

    private val stateIn: Array<ByteBuffer>
    private val stateOut: Array<ByteBuffer>
    private val inputs: Array<Any>
    private val outputs: Map<Int, Any>

    init {
        val n = stateShapesList.size
        stateIn = Array(n) { i ->
            val size = stateShapesList[i].fold(1) { acc, d -> acc * d }
            ByteBuffer.allocateDirect(size * 4).order(ByteOrder.nativeOrder())
        }
        stateOut = Array(n) { i ->
            val size = stateShapesList[i].fold(1) { acc, d -> acc * d }
            ByteBuffer.allocateDirect(size * 4).order(ByteOrder.nativeOrder())
        }
        // 输入 0 = 频谱，1..n = 28 路状态；输出 0 = 频谱，1..n = 28 路状态
        inputs = Array(n + 1) { i -> if (i == 0) inBuf else stateIn[i - 1] }
        val map = HashMap<Int, Any>(n + 1)
        map[0] = outBuf
        for (i in 1..n) map[i] = stateOut[i - 1]
        outputs = map
    }

    override fun stateShapes(): List<IntArray> = stateShapesList

    override fun run(input: FloatArray, states: List<FloatArray>, output: FloatArray) {
        inBuf.rewind()
        inBuf.asFloatBuffer().put(input)
        for (i in states.indices) {
            stateIn[i].rewind()
            stateIn[i].asFloatBuffer().put(states[i])
        }
        for (i in states.indices) stateIn[i].rewind()
        inBuf.rewind()

        interpreter.runForMultipleInputsOutputs(inputs, outputs)

        outBuf.rewind()
        outBuf.asFloatBuffer().get(output)
        // 状态就地回灌：下一块必须接着这个流式状态算，否则每块都是「冷启动」
        for (i in states.indices) {
            stateOut[i].rewind()
            stateOut[i].asFloatBuffer().get(states[i])
        }
    }

    override fun close() {
        try {
            interpreter.close()
        } catch (t: Throwable) {
            Log.w(TAG, "关闭解释器失败: ${t.message}")
        }
    }
}
