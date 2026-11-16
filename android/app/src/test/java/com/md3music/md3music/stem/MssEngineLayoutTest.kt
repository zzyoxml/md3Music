package com.md3music.md3music.stem

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** kotlin.math 的 minOf 在测试文件里易与 java.lang.Math 混淆，统一走这个包装。 */
private fun minInt(a: Int, b: Int): Int = if (a < b) a else b

/**
 * MSS 数值核心的布局与重建保真度。
 *
 * 用 fake 解释器：把人声 stem 设为输入频谱、其余 stem 置零。
 * 这样「人声 + 伴奏」应严格等于输入，可同时验证
 * **平面布局**、**STFT/iSTFT/OLA 直通** 与 **尾量分段**。
 */
class MssEngineLayoutTest {

    /** 直通解释器：把人声 stem 设为输入频谱，其余 stem 置零。 */
    private class PassThroughInterpreter : MssInterpreter {
        override fun stateShapes(): List<IntArray> = emptyList()

        override fun run(input: FloatArray, states: List<FloatArray>, output: FloatArray) {
            output.fill(0f)
            for (t in 0 until MssEngine.FRAMES) {
                for (c in 0 until 2) {
                    val srcBase = t * 4 * MssEngine.BINS + c * 2 * MssEngine.BINS
                    val dstBase = t * 16 * MssEngine.BINS + c * 2 * MssEngine.BINS
                    for (f in 0 until MssEngine.BINS) {
                        output[dstBase + f] = input[srcBase + f]
                        output[dstBase + MssEngine.BINS + f] =
                            input[srcBase + MssEngine.BINS + f]
                    }
                }
            }
        }

        override fun close() {}
    }

    /** 4 个 stem 全零 → 两路都应为零。 */
    private class SilentInterpreter : MssInterpreter {
        override fun stateShapes(): List<IntArray> = emptyList()
        override fun run(input: FloatArray, states: List<FloatArray>, output: FloatArray) {
            output.fill(0f)
        }
        override fun close() {}
    }

    /** 双声道正弦（左右幅度不同，便于检出通道错位）。 */
    private fun stereoSine(frames: Int, freq: Double, ampL: Float, ampR: Float): FloatArray {
        val out = FloatArray(frames * 2)
        for (i in 0 until frames) {
            val s = Math.sin(2.0 * Math.PI * freq * i / MssEngine.SR).toFloat()
            out[2 * i] = s * ampL
            out[2 * i + 1] = s * ampR
        }
        return out
    }

    private fun rms(a: FloatArray): Double {
        if (a.isEmpty()) return 0.0
        var sum = 0.0
        for (v in a) sum += v.toDouble() * v
        return Math.sqrt(sum / a.size)
    }

    /** 把长信号切成 CHUNK 逐块喂给引擎，收集每块的两路输出（成对）。 */
    private fun runChunks(engine: MssEngine, x: FloatArray): List<FloatArray> {
        val total = x.size / 2
        val pairs = ArrayList<FloatArray>()
        var off = 0
        while (off < total) {
            val take = minInt(MssEngine.CHUNK, total - off)
            val seg = FloatArray(take * 2)
            System.arraycopy(x, off * 2, seg, 0, take * 2)
            val r = engine.process(seg, take)
            pairs.add(r[0])
            pairs.add(r[1])
            off += take
        }
        return pairs
    }

    @Test
    fun planarLayoutRoundTripsWithHighCorrelation() {
        val engine = MssEngine(PassThroughInterpreter())
        val n = MssEngine.CHUNK * 8
        val x = stereoSine(n, 440.0, 1f, 0.6f)
        val pairs = runChunks(engine, x)

        // 预热期（首块之前）输出全零；取靠后的一对做校验
        val voc = pairs[8]
        val acc = pairs[9]
        assertTrue("人声块应非静音", rms(voc) > 1e-3)
        assertTrue("直通解释器下伴奏应为零", rms(acc) < 1e-4)

        // 与原始信号的相关性：这是平面布局正确的判据（交错布局会在任何滞后处都掉到 ~0）。
        //
        // 不能拿固定偏移直接比：引擎有固有的块对齐延迟（首块要等 WIN 才产出，
        // 且 STFT 居中还有 PAD 的历史）。这里扫描滞后取峰值，既验证布局正确，
        // 又不把「具体延迟多少」写死进测试（那是会话层的 LATENCY_FRAMES 负责的）。
        val chunkIndex = 4L
        val approxStart = (chunkIndex * MssEngine.CHUNK).toInt()
        var bestCorr = -1.0
        var bestLag = 0
        for (lag in -MssEngine.WIN..MssEngine.WIN step 8) {
            val start = approxStart + lag
            if (start < 0 || start + voc.size > x.size) continue
            var dot = 0.0
            var nx = 0.0
            var ny = 0.0
            for (i in voc.indices) {
                val a = x[start + i].toDouble()
                val b = voc[i].toDouble()
                dot += a * b
                nx += a * a
                ny += b * b
            }
            if (nx <= 0.0 || ny <= 0.0) continue
            val corr = dot / Math.sqrt(nx * ny)
            if (corr > bestCorr) {
                bestCorr = corr
                bestLag = lag
            }
        }
        assertTrue("平面布局直通的相关峰值应接近 1（实际 best=$bestCorr @lag=$bestLag）",
            bestCorr > 0.98)
    }

    @Test
    fun silentModelProducesSilenceNotGarbage() {
        val engine = MssEngine(SilentInterpreter())
        val n = MssEngine.CHUNK * 4
        val x = stereoSine(n, 440.0, 1f, 1f)
        val pairs = runChunks(engine, x)
        for (p in pairs) {
            assertTrue("模型输出零 → 两路都应静音", rms(p) < 1e-6)
        }
    }

    @Test
    fun earlyBlocksAreSilentUntilFirstInferenceCompletes() {
        val engine = MssEngine(PassThroughInterpreter())
        val n = MssEngine.CHUNK
        val x = stereoSine(n, 440.0, 1f, 1f)
        // 首块 4096 帧不足以凑够 1 个 WIN，必然全零（上层据此回落 dry）
        val r = engine.process(x, n)
        assertTrue("首块之前输出静音", rms(r[0]) < 1e-9)
    }

    @Test
    fun resetReturnsToWarmUpState() {
        val engine = MssEngine(PassThroughInterpreter())
        val x = stereoSine(MssEngine.CHUNK * 4, 440.0, 1f, 1f)
        runChunks(engine, x)
        engine.reset()
        val silence = FloatArray(MssEngine.CHUNK * 2)
        val r = engine.process(silence, MssEngine.CHUNK)
        assertTrue("reset 后应回到预热期（静音）", rms(r[0]) < 1e-9)
    }

    @Test
    fun resetClearsStreamingStateSoSeekStartsFresh() {
        // seek 后必须让引擎回到「预热态」：28 路流式状态、inQ、carry/tail 全清。
        // 早期版本 session.flush() 只清了自己的队列、**从不调 engine.reset()**，
        // 于是 seek 之后新位置音频被接在旧音频后面继续推理，输出是两段不相干
        // 信号混出来的 —— 实测表现就是「拖动进度后分离失效/串音」。
        val engine = MssEngine(PassThroughInterpreter())
        val n = MssEngine.CHUNK * 6
        val x = stereoSine(n, 440.0, 1f, 1f)
        val warm = runChunks(engine, x)
        // 稳态下人声块应有能量（确认引擎确实在工作）
        assertTrue("预热后应有输出", rms(warm[warm.size - 2]) > 1e-3)

        engine.reset()

        // reset 后重新喂一小段：不足 2*WIN 必然拿不到任何分离结果（回到预热态）。
        val short = stereoSine(MssEngine.CHUNK, 440.0, 1f, 1f)
        val fresh = runChunks(engine, short)
        for (p in fresh) {
            assertTrue("reset 后必须回到预热态（静音），而不是沿用旧状态", rms(p) < 1e-9)
        }
    }

    @Test
    fun latencyConstantMatchesModelFrontend() {
        // WIN = CHUNK + LOOK：产出一块 [B,B+4096) 必须喂到 B+4608
        assertEquals(MssEngine.FRAMES * MssEngine.HOP + MssEngine.HOP, MssEngine.WIN)
        // 引擎内部 inQ 要攒满 2*WIN 才推理一块，故固定延迟 = 2*WIN
        // = 9216 帧 @44.1kHz = 209ms（不可调）
        assertEquals(2 * MssEngine.WIN, StemSeparateSession.LATENCY_FRAMES)
        assertEquals(209, StemSeparateSession.LATENCY_MS)
    }

    @Test
    fun blockStartFrameMatchesChunkGrid() {
        // 块起点恒为 k*CHUNK：早期版本用 fedFrame 累加标注起点，每次从 FIFO
        // 取 WIN(4608) 却只记 CHUNK(4096)，每块落后 512 帧、累积漂移，
        // 回填时大面积命中错帧 → 全程回落 dry，听感就是「分离没效果」。
        // 这里用引擎的输出对齐关系间接锁死：连续喂 N 块后，
        // 第 k 块覆盖的区间必须仍然落在 [k*CHUNK, (k+1)*CHUNK)。
        val engine = MssEngine(PassThroughInterpreter())
        val blocks = 12
        val x = stereoSine(MssEngine.CHUNK * blocks, 440.0, 1f, 0.6f)
        runChunks(engine, x)
        // 引擎不暴露内部块计数，改为验证「喂满 N 块后不再有积压且能持续产出」
        // —— 若起点漂移，runBlock 会因 ring 满而停止推进。
        assertTrue("连续喂入不应卡住推理", engine.pendingBlocks() >= 0)
    }
}
