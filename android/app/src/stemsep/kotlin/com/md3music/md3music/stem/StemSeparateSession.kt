package com.md3music.md3music.stem

import android.util.Log
import com.ryanheise.just_audio.StemSeparateHook
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 端侧分离调度核心（实现 fork 的 [StemSeparateHook]）。
 *
 * ## 为什么必须整体延迟一个窗口（104.5 ms）
 *
 * 产出一块覆盖 `[B, B+CHUNK)`（4096 帧）的音频，模型必须已经喂到
 * `B + WIN`（4608 帧）—— 块内 8 帧 STFT 从 `-PAD` 起、最远要看 `CHUNK+LOOK`。
 * 因此**渲染第 j 帧的这一刻，分离第 j 帧所需的输入根本还没到齐**，
 * 「零延迟 + 帧对齐」在数学上不可能。
 *
 * 本实现采用**固定延迟** `D = WIN`（4608 帧 = 104.5 ms）：
 *
 * - 输出第 j 帧 = 输入第 j 帧的分离结果，且只有在已喂到 `j + D` 时才放出；
 * - 预热期（该块还没算完）输出**输入第 j 帧的原音（dry）**，不是静音；
 * - 已过期（某块算得太慢、已越过其作用区间）→ 该区间继续走 dry。
 *
 * 结果：**音画恒定偏差 104.5 ms，且永不累积漂移**。UI 侧把「进度读数」减去这个
 * 常量即可让歌词对上（见 Dart 侧 `kStemSeparateLatencyMs`）——这比参考实现
 * （整段静音 + 溢出丢块）既不断音也不漂移。
 *
 * ## 混音
 *
 * 等功率：`gVocal = cos(mix·π/2)`、`gAccomp = sin(mix·π/2)`，`mix` = 伴奏占比。
 * `mix = 1` → 纯伴奏（与 `AccompanyMix.accompanyOnly` 一致）。
 *
 * ## 线程模型
 *
 * [process] 跑在 ExoPlayer **渲染线程**：只做出队/混音，绝不阻塞、不分配大对象；
 * 推理在专用 worker 线程。worker 落后时丢**最旧**输入，不让内存增长或卡住播放。
 */
internal class StemSeparateSession(
    private val engineFactory: () -> MssEngine?,
) : StemSeparateHook {

    companion object {
        private const val TAG = "StemSep"

        /**
         * 固定延迟（帧）= 2 × WIN（9216 帧 ≈ 209 ms）。
         *
         * 为什么是 2×WIN 而不是 WIN：引擎内部 `inQ` 要攒满 `2*WIN` 才推理一块
         * （`MssEngine.kt` 的 `inLen >= 2 * WIN`），推理后丢掉 `2*CHUNK`。于是
         * 块 k 真正算得出来需要已喂到 `2*WIN + k*2*CHUNK`：
         *
         * | 块 | 覆盖区间 | 需要已消费帧 |
         * |---|---|---|
         * | 0 | [0, 4096) | 9216 |
         * | 1 | [4096, 8192) | 17408 |
         * | k | [k*4096, (k+1)*4096) | 9216 + k*8192 |
         *
         * 若仍按 WIN（4608）放出，帧 [0,4096) 会在 consumed=4608 时就被要求
         * 输出，而块 0 到 9216 才算得出来 → 前 5120 帧必然全是 dry，听感就是
         * 「开了分离却几乎都是原音」。取 D=2*WIN 时块 k 恰在需要它的那一刻
         * 算完，预热期只有起播/seek 后 209ms，之后全程都有分离结果。
         */
        const val LATENCY_FRAMES = 2 * MssEngine.WIN

        /**
         * 延迟对应的毫秒数（44.1 kHz 域）。
         *
         * 9216 帧 = 208.98ms，**四舍五入**取 209（不是整数除法的 208）：
         * Dart 侧 `kStemSeparateLatencyMs` 用它做歌词补偿，两边必须是同一个值，
         * 否则歌词会恒定偏 1ms 且难以察觉来源。
         */
        const val LATENCY_MS = (LATENCY_FRAMES * 1000 + MssEngine.SR / 2) / MssEngine.SR

        /** 输入 FIFO 上限（CHUNK 数）。4 块 ≈ 372 ms 余量，够抗一次调度抖动。 */
        private const val FIFO_WINDOWS = 4

        /** 连续这么多块 RTF > [OVERLOAD_RTF] 判定算力不足。 */
        private const val OVERLOAD_STREAK = 6

        /** 连续这么多块恢复正常 RTF 才解除降级（防止在阈值附近抖动）。 */
        private const val RECOVER_STREAK = 12

        /** RTF 超过它认为本机跟不上（1.0 = 刚好实时）。 */
        private const val OVERLOAD_RTF = 0.95

        /** dry 环形容量：必须覆盖一个延迟窗口 + 一块余量。 */
        private const val DRY_RING = LATENCY_FRAMES + 2 * MssEngine.CHUNK
    }

    /** 诊断快照（给设置页状态行）。 */
    data class Stats(
        val ready: Boolean,
        val blocks: Long,
        val avgBlockMs: Double,
        val rtf: Double,
        val dryPercent: Double,
        val overloaded: Boolean,
        val sampleRate: Int,
        val channels: Int,
        val droppedBlocks: Long,
        val latencyMs: Int,
        /** 引擎被重置的次数：seek 后应递增，否则说明 flush 没传到模型。 */
        val resetCount: Long,
        /** 因单批限速被跳过的帧数：持续增长 = 音频线程被反复拖住（卡音信号）。 */
        val skippedFrames: Long,
    )

    private val running = AtomicBoolean(false)

    @Volatile private var worker: Thread? = null

    /** 模型引擎（worker 里懒创建；失败则永不就绪，处理器自动透传）。 */
    @Volatile private var engine: MssEngine? = null

    @Volatile private var loadFailed = false

    /**
     * 待重置标志：渲染线程置位，worker 线程消费。
     *
     * 初值 true —— 引擎第一次建好后先自清一次，保证从空白状态开跑。
     * 用 volatile 而非锁：渲染线程只做一次写，绝不阻塞。
     */
    @Volatile private var pendingReset = true

    /** 目标伴奏占比（渲染线程写、worker 读）。 */
    @Volatile private var targetMix = 1.0f

    /** 已平滑到的伴奏占比（渲染线程独占）。 */
    private var smoothMix = 1.0f

    @Volatile private var deviceSampleRate = MssEngine.SR
    @Volatile private var deviceChannels = 2

    // ── 输入侧（渲染线程写、worker 读）──
    private val inLock = Any()
    private val fifo = FloatArray(MssEngine.CHUNK * 2 * FIFO_WINDOWS)
    private var fifoLen = 0
    private var overflowFrames = 0L
    /** 已送入模型的总帧号（诊断用；块起点改由 [blockIndex] 推导）。 */
    private var fedFrame = 0L
    /** 已完成的推理块数：块 k 覆盖 [k*CHUNK, (k+1)*CHUNK)。 */
    private var blockIndex = 0L

    // ── 输出侧（worker 写、渲染线程读）──
    private val outLock = Any()
    private val blocks = ArrayDeque<OutBlock>()
    private class OutBlock(val startFrame: Long, val vocals: FloatArray, val accomp: FloatArray)

    /** 已产出到音频流的绝对帧号。 */
    private var emitFrame = 0L

    /** 已接收的 44.1k 帧总数。 */
    private var consumedFrame = 0L

    /**
     * dry 环形：保存尚未放出区间 `[emitFrame, consumedFrame)` 的原音。
     *
     * 用绝对帧号取模索引，容量 [DRY_RING] 足够覆盖「延迟 + 一块」。
     */
    private val dryRing = FloatArray(DRY_RING * 2)

    private var inResampler: CubicResampler? = null
    private var outResampler: CubicResampler? = null

    // 渲染线程临时缓冲
    private var emitBuf = FloatArray(MssEngine.CHUNK * 2)

    // 统计
    @Volatile private var blocksDone = 0L
    @Volatile private var totalBlockMs = 0.0
    @Volatile private var dryFrames = 0L
    @Volatile private var emittedFrames = 0L
    @Volatile private var overloadStreak = 0
    @Volatile private var overloaded = false

    /** 连续正常 RTF 的块数（用于从 overloaded 恢复）。 */
    @Volatile private var recoverStreak = 0
    @Volatile private var droppedBlocks = 0L

    /**
     * 因单批限速而被跳过的帧数（诊断用）。
     *
     * 只在「某批迟到导致欠账超过 2×frames」时增长。持续增长说明音频线程
     * 被反复拖住，是卡音的量化信号。
     */
    @Volatile private var skippedFrames = 0L

    /** 引擎已被 worker 重置的次数（诊断用，锁死 seek 后确实重置了）。 */
    @Volatile private var resetBlocksOnReset = 0L

    override fun configure(sampleRate: Int, channelCount: Int) {
        deviceSampleRate = if (sampleRate >= 8000) sampleRate else MssEngine.SR
        deviceChannels = maxOf(1, channelCount)
        // 与 seek 走同一条清理路径（置 pendingReset + 清队列），避免两套语义
        flush()
        val needRs = deviceSampleRate != MssEngine.SR
        inResampler = if (needRs) CubicResampler(deviceSampleRate, MssEngine.SR, deviceChannels) else null
        outResampler = if (needRs) CubicResampler(MssEngine.SR, deviceSampleRate, deviceChannels) else null
        Log.i(TAG, "configure device=$deviceSampleRate ch=$deviceChannels resample=$needRs delay=${LATENCY_MS}ms")
        ensureWorker()
    }

    /** 设置伴奏占比（0 = 纯原曲，1 = 纯伴奏）。 */
    fun setMix(mix: Float) {
        targetMix = if (mix.isNaN()) 1.0f else mix.coerceIn(0f, 1f)
    }

    override fun isReady(): Boolean = running.get() && engine != null && !loadFailed

    /**
     * seek / 换曲：清空全部状态。
     *
     * **必须在渲染线程上极快返回**（连续拖进度条时会被高频调用），因此这里
     * 只做两件安全的事：
     * 1. 清本 session 自己的队列（FIFO / 块 / dry 环形 / 重采样器）；
     * 2. **置 [pendingReset] 标志**，让 worker 线程在自己的线程上重置引擎。
     *
     * 不能在渲染线程直接 `engine.reset()`：`MssEngine` 内部（`inQ` / 28 路
     * `state` / ring）全是裸字段、非线程安全，只归 worker 线程访问。直接在渲染
     * 线程 reset 会与 `eng.process` 数据竞争，轻则输出错帧、重则数组越界。
     *
     * 早期版本 `flush()` 只清 session 队列、**从不重置引擎**，于是 seek 后模型
     * 里还留着 seek 之前的旧音频与 28 路流式状态，新位置音频被接在旧内容后面
     * 继续推理 → 输出是两段不相干音频混出来的，听感即「拖动进度后分离失效」。
     */
    override fun flush() {
        pendingReset = true
        resetSessionQueues()
    }

    override fun release() {
        running.set(false)
        val w = worker
        worker = null
        if (w != null) {
            try {
                w.join(1200)
            } catch (ignored: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
        engine?.close()
        engine = null
    }

    /**
     * 清本 session 独占的队列（渲染线程安全）。
     *
     * 与引擎重置**成对出现**：`blockIndex` / `fedFrame` / `consumedFrame` /
     * `emitFrame` 必须一起归零，否则块起点网格 `k*CHUNK` 会和引擎真实消费位置
     * 错开（与上一轮修掉的「块起点漂移」是同一类问题，只是方向相反）。
     */
    private fun resetSessionQueues() {
        synchronized(inLock) {
            fifoLen = 0
            fedFrame = 0
            blockIndex = 0
            // 模型侧待处理的帧号也要归零：引擎会被 worker 重置，两边必须同起点
            consumedFrame = 0
        }
        synchronized(outLock) {
            blocks.clear()
            emitFrame = 0
        }
        dryRing.fill(0f)
        smoothMix = targetMix
        inResampler?.reset()
        outResampler?.reset()
        overloadStreak = 0
        recoverStreak = 0
    }

    // ─────────────────────────── 渲染线程 ───────────────────────────

    override fun process(
        `in`: FloatArray,
        frames: Int,
        out: FloatArray,
        channelCount: Int,
    ): Int {
        if (frames <= 0) return 0
        val totalSamples = frames * channelCount
        val ch = minOf(2, channelCount)

        // 样本已是 float（1.0f = 0 dBFS），与 16bit 管线共用同一套实现：
        // 处理器把 short 归一化后传进来，这里无需再转换。
        val floatIn = `in`

        // 2) 设备率 → 44.1k
        val inRes = inResampler
        val modelSamples: Int
        val modelData: FloatArray
        if (inRes != null) {
            modelData = inRes.process(floatIn, frames)
            modelSamples = inRes.lastOutSamples()
        } else {
            modelData = floatIn
            modelSamples = totalSamples
        }
        val modelFrames = modelSamples / ch
        if (modelFrames <= 0) return 0

        // 3) 入 FIFO（给模型），同时把 dry 写进环形（给本帧的回填兜底）
        synchronized(inLock) {
            pushFifo(modelData, modelFrames * ch)
            for (i in 0 until modelFrames) {
                val slot = ((consumedFrame + i) % DRY_RING).toInt()
                dryRing[slot * 2] = modelData[i * ch]
                dryRing[slot * 2 + 1] =
                    if (ch > 1) modelData[i * ch + 1] else modelData[i * ch]
            }
            consumedFrame += modelFrames.toLong()
        }

        // 4) 可放出的帧数：必须已喂到 emit + LATENCY。
        //
        // **必须限速**：emitCount 是「欠下的账」，没有上限。一旦某批迟到
        // （GC / 调度抖动），下一批就要一次性补做更多帧，形成
        // 「越卡 → 单批越重 → 更容易超预算 → 更卡」的正反馈 —— 实测听感
        // 就是「一卡一卡」。这里把单批上限设为 2×frames：
        // 超出部分**直接推进 emitFrame 而不再逐帧处理**（丢弃），由 dry 兜底。
        // 宁可丢一小段原音，也不让音频线程被放大的工作量拖死。
        var avail = consumedFrame - LATENCY_FRAMES
        if (avail < 0) avail = 0
        var emitCount = if (avail > emitFrame) (avail - emitFrame) else 0L
        val emitCap = (frames * 2).toLong()
        var skipped = 0L
        if (emitCount > emitCap) {
            // 追赶：把超出部分整体跳过（不逐帧写），emitFrame 直接前移
            skipped = emitCount - emitCap
            emitFrame += skipped
            emitCount = emitCap
        }

        // 5) 按块批量回填（有块用块，没块用 dry）
        //
        // 旧实现是**逐帧**遍历 blocks.iterator() 找覆盖帧，每秒产生约 44k 个
        // Iterator 对象 + 88k 次 cos/sin + 88k 次取模，全部落在音频渲染线程上
        // → 年轻代 GC 压力 → 停顿正好砸在音频线程 → 一卡一卡。
        // 块区间本就严格对齐 [k*CHUNK,(k+1)*CHUNK)，因此可以**一次定位、
        // 连续写一整段**，复杂度从 O(帧数) 降到 O(块数)。
        if (emitBuf.size < (emitCount.toInt() * 2).coerceAtLeast(2)) {
            emitBuf = FloatArray((emitCount.toInt() * 2).coerceAtLeast(2))
        }
        val tgt = targetMix
        var dry = 0L
        var cur = smoothMix
        synchronized(outLock) {
            // 丢弃起点已越过（整块都过期）的块
            while (blocks.isNotEmpty() && blocks.first().startFrame + MssEngine.CHUNK <= emitFrame) {
                blocks.removeFirst()
                droppedBlocks++
            }

            var cursor = 0L // 已写到 emitBuf 的相对帧数
            while (cursor < emitCount) {
                val frame = emitFrame + cursor
                val head: OutBlock? = if (blocks.isEmpty()) null else blocks.first()
                // 该帧是否落在 head 块的覆盖区间内
                val off = if (head != null) frame - head.startFrame else -1L

                if (head != null && off >= 0 && off < MssEngine.CHUNK) {
                    // ── 段内全部来自块：一次算增益，连续写完这段 ──
                    val end = minOf(MssEngine.CHUNK - off, emitCount - cursor)
                    cur = advanceMix(cur, tgt)
                    val a = cur * (Math.PI.toFloat() / 2f)
                    val gv = Math.cos(a.toDouble()).toFloat()
                    val ga = Math.sin(a.toDouble()).toFloat()
                    var k = 0L
                    while (k < end) {
                        val o = 2 * (cursor + k).toInt()
                        val s = 2 * (off + k).toInt()
                        emitBuf[o] = head.vocals[s] * gv + head.accomp[s] * ga
                        emitBuf[o + 1] = head.vocals[s + 1] * gv + head.accomp[s + 1] * ga
                        k++
                    }
                    cursor += end
                    // 该块用尽则出队（下一轮会看新 head）
                    if (off + end >= MssEngine.CHUNK) {
                        blocks.removeFirst()
                    }
                } else {
                    // ── 段内全部走 dry：按环形分 1~2 段连续拷 ──
                    // dry 段的右边界是「下一个块的起点」或「本批结束」，
                    // 且必须在 [0, DRY_RING) 内取整，保证不绕环两次。
                    var limit = emitCount - cursor
                    if (head != null) {
                        // 若 head 在未来，则 dry 到 head.startFrame 为止
                        val gap = head.startFrame - frame
                        if (gap > 0) limit = minOf(limit, gap)
                        // 若 head 已过期（off < 0 但整块未越过），上面已丢弃过，
                        // 这里只可能是「尚未到达」，保持上面结果
                    }
                    val slotStart = (frame % DRY_RING).toInt()
                    val toRingEnd = (DRY_RING - slotStart).toLong()
                    val first = minOf(limit, toRingEnd)
                    var k = 0L
                    while (k < first) {
                        val ringIdx = 2 * (slotStart + k.toInt())
                        val o = 2 * (cursor + k).toInt()
                        emitBuf[o] = dryRing[ringIdx]
                        emitBuf[o + 1] = dryRing[ringIdx + 1]
                        k++
                    }
                    cursor += first
                    dry += first
                    val rest = limit - first
                    if (rest > 0) {
                        // 绕回环首继续拷
                        var j = 0L
                        while (j < rest) {
                            val ringIdx = 2 * j.toInt()
                            val o = 2 * (cursor + j).toInt()
                            emitBuf[o] = dryRing[ringIdx]
                            emitBuf[o + 1] = dryRing[ringIdx + 1]
                            j++
                        }
                        cursor += rest
                        dry += rest
                    }
                    if (limit <= 0L) break // 防御：不应发生
                }
            }
            // 收尾：出队已经完整放出的块
            while (blocks.isNotEmpty() && blocks.first().startFrame + MssEngine.CHUNK <= emitFrame + emitCount) {
                blocks.removeFirst()
            }
        }
        smoothMix = cur
        emitFrame += emitCount
        dryFrames += dry
        emittedFrames += emitCount
        skippedFrames += skipped

        // 6) 44.1k → 设备率，并写入 out（写不满的尾部由处理器补 dry）
        val written: Int
        if (emitCount <= 0) {
            written = 0
        } else {
            val outRes = outResampler
            if (outRes != null) {
                val res = outRes.process(emitBuf, emitCount.toInt())
                val n = outRes.lastOutSamples()
                val copy = minOf(n, totalSamples)
                for (i in 0 until copy) {
                    out[i] = res[i]
                }
                written = (copy / channelCount)
            } else {
                val n = minOf(emitCount.toInt() * 2, totalSamples)
                for (i in 0 until n) {
                    out[i] = emitBuf[i]
                }
                written = n / channelCount
            }
        }
        return written.coerceIn(0, frames)
    }

    // ─────────────────────────── worker ───────────────────────────

    private fun ensureWorker() {
        if (running.get()) return
        running.set(true)
        val t = Thread({ workerLoop() }, "stem-separate")
        t.isDaemon = true
        worker = t
        t.start()
    }

    private fun workerLoop() {
        try {
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_DISPLAY)
        } catch (ignored: Throwable) {
        }
        if (engine == null && !loadFailed) {
            try {
                engine = engineFactory()
            } catch (t: Throwable) {
                Log.e(TAG, "引擎创建失败: ${t.javaClass.simpleName} ${t.message}")
            }
            if (engine == null) {
                loadFailed = true
                Log.e(TAG, "端侧分离不可用（模型或运行时缺失）")
            }
        }
        while (running.get()) {
            // 消费渲染线程留下的重置请求 —— **在取下一块之前**，保证「重置」
            // 一定发生在旧音频推理之后、新音频推理之前。这一步只能在 worker
            // 线程做：MssEngine 内部状态非线程安全。
            if (pendingReset) {
                pendingReset = false
                engine?.reset()
                resetBlocksOnReset++
            }
            val window = takeWindow()
            if (window == null) {
                try {
                    Thread.sleep(4)
                } catch (ignored: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return
                }
                continue
            }
            val eng = engine ?: continue
            val t0 = System.nanoTime()
            // 块起点 = 块序号 × CHUNK，**不依赖任何累加计数**。
            //
            // 早期版本用 `fedFrame` 累加来标注起点，但每次从 FIFO 取的是 WIN
            // (4608) 而 process 的 n 只推进 CHUNK (4096)：每块少记 512 帧，起点
            // 越算越落后，回填时大面积命中错帧 → 全程回落 dry，听感就是「分离
            // 没效果」。改成按序号推导后，块区间恒为 [k*CHUNK, (k+1)*CHUNK)，
            // 与模型输出的连续性天然一致，构造上不可能漂移。
            val startFrame = blockIndex * MssEngine.CHUNK.toLong()
            val result = try {
                eng.process(window, MssEngine.CHUNK)
            } catch (t: Throwable) {
                Log.w(TAG, "推理失败，跳过该块: ${t.javaClass.simpleName} ${t.message}")
                continue
            }
            blockIndex++
            synchronized(inLock) { fedFrame += MssEngine.CHUNK.toLong() }
            val dtMs = (System.nanoTime() - t0) / 1e6
            blocksDone++
            totalBlockMs += dtMs
            val rtf = dtMs / (MssEngine.CHUNK * 1000.0 / MssEngine.SR)
            if (rtf > OVERLOAD_RTF) {
                if (++overloadStreak >= OVERLOAD_STREAK) {
                    if (!overloaded) Log.w(TAG, "算力不足 RTF=$rtf，停止分离输出（持续 dry）")
                    overloaded = true
                }
            } else {
                overloadStreak = 0
                // 允许恢复：早期版本一旦置 overloaded 就永不解除，偶发一次高负载
                // 会让端侧分离「从此只有原音」。用连续 N 块正常 RTF 作为解除条件。
                if (overloaded && ++recoverStreak >= RECOVER_STREAK) {
                    overloaded = false
                    recoverStreak = 0
                    Log.i(TAG, "算力恢复 RTF=$rtf，恢复分离输出")
                }
            }
            if (overloaded) continue
            synchronized(outLock) {
                blocks.addLast(OutBlock(startFrame, result[0], result[1]))
                while (blocks.size > FIFO_WINDOWS) {
                    blocks.removeFirst()
                    droppedBlocks++
                }
            }
        }
    }

    /**
     * 比例平滑推进一档（按**段**调用，不再按帧）。
     *
     * 旧实现每帧推进 0.05，即每帧都算一次 cos/sin（约 88k 次/秒，全在音频
     * 渲染线程上）。块的时长约 93ms，一段推进一次足以避免比例突变爆音 ——
     * 人耳对增益的感知远粗于逐帧精度。
     *
     * 系数取 0.05 * 段长倍数在此不合适（段长不固定），改用「固定步长」：
     * 每段逼近 5%，跨约 20 段（≈1.9s）完成收敛，手感依旧平滑。
     */
    private fun advanceMix(current: Float, target: Float): Float {
        val next = current + (target - current) * 0.05f
        // 收敛后直接吸附，避免长期残留 1e-7 级差导致每段仍算 cos/sin
        return if (Math.abs(next - target) < 1e-4f) target else next
    }


    /**
     * 从 FIFO 取一段，不足返回 null。
     *
     * 取 **CHUNK（4096）帧**而不是 WIN（4608）：`MssEngine.process` 内部会把
     * 收到的样本攒进自己的 `inQ`，凑满 `2*WIN` 才推理一块、每块丢弃 `2*CHUNK`。
     * 若这里按 WIN 取并交给它，引擎内部队列的增长与丢弃速率对不上（每次只进
     * CHUNK 却按 CHUNK 丢），前视量会被悄悄改写。
     *
     * 统一成「每次喂 CHUNK」后，引擎内部的攒批完全由它自己负责，前视 512 帧
     * 自然由 `inQ` 持有 —— 与参考实现的喂法一致。块的绝对起点也随之恒等于
     * `k*CHUNK`（见 [blockIndex]），不会累积漂移。
     */
    private fun takeWindow(): FloatArray? {
        synchronized(inLock) {
            val need = MssEngine.CHUNK * 2
            if (fifoLen < need) return null
            val w = FloatArray(need)
            System.arraycopy(fifo, 0, w, 0, need)
            val remain = fifoLen - need
            if (remain > 0) System.arraycopy(fifo, need, fifo, 0, remain)
            fifoLen = remain
            return w
        }
    }

    /**
     * 入队交错样本（44.1k 域）；溢出丢最旧。
     *
     * 必须处理「单次输入超过整个 FIFO 容量」的情况：早期实现只把旧数据搬走，
     * 没有对 `len > fifo.size` 做兜底，于是 `arraycopy(samples, 0, fifo, fifoLen,
     * len)` 直接越过数组末尾抛 ArrayIndexOutOfBoundsException（实测在批量喂入
     * 8 个 CHUNK 时触发）。音频线程上的异常会被处理器 catch 成「本批回落原音」，
     * 表现为间歇性卡音 —— 这也是卡音来源之一。
     *
     * 修法：输入超过容量时**只保留最新的 fifo.size 个样本**（旧数据本来就要丢）。
     */
    private fun pushFifo(samples: FloatArray, len: Int) {
        if (len <= 0) return
        if (len >= fifo.size) {
            // 输入比整个 FIFO 还大：只保留最新的一段，其余全丢
            val keep = fifo.size
            val srcOff = len - keep
            System.arraycopy(samples, srcOff, fifo, 0, keep)
            overflowFrames += ((fifoLen + srcOff) / 2).toLong()
            fifoLen = keep
            return
        }
        if (len > fifo.size - fifoLen) {
            val drop = len - (fifo.size - fifoLen)
            if (drop >= fifoLen) {
                fifoLen = 0
            } else {
                System.arraycopy(fifo, drop, fifo, 0, fifoLen - drop)
                fifoLen -= drop
            }
            overflowFrames += (drop / 2).toLong()
        }
        System.arraycopy(samples, 0, fifo, fifoLen, len)
        fifoLen += len
    }

    fun stats(): Stats {
        val b = blocksDone
        val avg = if (b > 0) totalBlockMs / b else 0.0
        val rtf = if (b > 0) avg / (MssEngine.CHUNK * 1000.0 / MssEngine.SR) else 0.0
        val dry = if (emittedFrames > 0) dryFrames.toDouble() / emittedFrames * 100.0 else 100.0
        return Stats(
            ready = isReady(),
            blocks = b,
            avgBlockMs = avg,
            rtf = rtf,
            dryPercent = dry,
            overloaded = overloaded,
            sampleRate = deviceSampleRate,
            channels = deviceChannels,
            droppedBlocks = droppedBlocks,
            latencyMs = LATENCY_MS,
            resetCount = resetBlocksOnReset,
            skippedFrames = skippedFrames,
        )
    }
}
