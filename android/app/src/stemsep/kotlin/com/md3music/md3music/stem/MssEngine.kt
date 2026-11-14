package com.md3music.md3music.stem

/**
 * MSS（Flamingo 的 4-stem 流式分离模型）数值核心。
 *
 * 纯 Kotlin / 无 Android 依赖，可 JVM 单测。推理后端由 [MssInterpreter] 注入，
 * 因此这里只负责 STFT / iSTFT / OLA 与张量布局，不碰 TFLite。
 *
 * ## 契约（实测锁定，见参考仓 data/MEASURED.md 与 mss_contract.json）
 *
 * - 输入 `input_1` `[1,8,4,1024]`：8 帧 STFT，每帧 4 个**平面**
 *   `L_re[1024] / L_im[1024] / R_re[1024] / R_im[1024]`。
 * - 输入 `input_2..29`：28 路多尺度流式状态，零初始化，每块回灌。
 * - 输出 `[1,8,16,1024]`：4 stem × 2ch × (re, im)，
 *   顺序 0-3 人声 / 4-7 贝斯 / 8-11 鼓 / 12-15 其他。
 * - STFT 2048 点、hop 512、周期 Hann、44.1 kHz；用 bin 0..1023（丢弃 10.2–22.05 kHz）。
 *
 * ## 两个历史坑（照抄会出「碎成一片 / 声音怪」）
 *
 * 1. **平面布局**：写成 re/im 交错的 `putFloat(re); putFloat(im)` 会把每个 1024
 *    长的平面在 bin 512 处劈开，模型看到的是乱序频谱 —— 实测输出与输入相关性
 *    从 +0.999998 掉到 −0.020558。
 * 2. **尾量分段**：`tailV/tailA` 存的是 `[L 段][R 段]` 两个 TAIL 长的一半，
 *    不是交错。整段拷进左声道会把右声道尾巴折进左声道（每 93ms 块的前约
 *    35ms 被破坏，SNR 从 157dB 掉到 34.9dB）。
 */
internal class MssEngine(private val interpreter: MssInterpreter) {

    companion object {
        const val SR = 44100
        const val N_FFT = 2048
        const val HOP = 512
        const val BINS = 1024
        const val FRAMES = 8

        /** 每次推理产出的样本数（8 × 512 ≈ 93ms）。 */
        const val CHUNK = FRAMES * HOP

        /** 前视历史：iSTFT 居中的 1024 点。 */
        private const val PAD = N_FFT / 2

        /** 8 帧从 -PAD 起，最远要到 CHUNK+512，故每次推理需多看 512 个样本。 */
        private const val LOOK = HOP

        /** 每次推理消费的样本数（CHUNK + LOOK = 4608）。 */
        const val WIN = CHUNK + LOOK

        /** OLA 尾量。 */
        private const val TAIL = N_FFT - HOP

        /** 单块累计缓冲长度。 */
        private const val OLA = PAD + CHUNK + TAIL

        /** 已完成块等待播放的环形深度。 */
        private const val RING = 8
    }

    private val win = FloatArray(N_FFT)
    private val cosT = FloatArray(N_FFT / 2)
    private val sinT = FloatArray(N_FFT / 2)
    private val rev = IntArray(N_FFT)

    private val carry = FloatArray(2 * PAD)
    private val tailV = FloatArray(2 * TAIL)
    private val tailA = FloatArray(2 * TAIL)
    private val tailW = FloatArray(TAIL)

    private val buf = FloatArray(2 * (PAD + WIN))
    private val inQ = FloatArray(2 * (WIN + 4 * CHUNK))
    private var inLen = 0

    /**
     * 已完成块等待取用。
     *
     * 用二维环 + 头指针：早期用单个 `float[]` + 头指针实现，一次调用里若连着跑
     * 两块，第一块之后的块会被整体丢掉 —— 听感就是音频被切碎。
     */
    private val vocRing = Array(RING) { FloatArray(2 * CHUNK) }
    private val accRing = Array(RING) { FloatArray(2 * CHUNK) }
    private var ringW = 0
    private var ringR = 0
    private var ringN = 0
    private var ringOff = 0

    private val re = FloatArray(N_FFT)
    private val im = FloatArray(N_FFT)

    // 单块累计器
    private val vL = FloatArray(OLA)
    private val vR = FloatArray(OLA)
    private val aL = FloatArray(OLA)
    private val aR = FloatArray(OLA)
    private val wsum = FloatArray(OLA)

    /** 张量输入/输出缓冲，复用避免每次推理都分配。 */
    private val inPlane = FloatArray(FRAMES * 4 * BINS)
    private val outPlane = FloatArray(FRAMES * 16 * BINS)

    /** 28 路流式状态（每块回灌）。 */
    private val state = ArrayList<FloatArray>()

    init {
        for (i in 0 until N_FFT) {
            win[i] = (0.5 - 0.5 * Math.cos(2.0 * Math.PI * i / N_FFT)).toFloat()
        }
        for (i in 0 until N_FFT / 2) {
            cosT[i] = Math.cos(-2.0 * Math.PI * i / N_FFT).toFloat()
            sinT[i] = Math.sin(-2.0 * Math.PI * i / N_FFT).toFloat()
        }
        val bits = Integer.numberOfTrailingZeros(N_FFT)
        for (i in 0 until N_FFT) {
            rev[i] = Integer.reverse(i) ushr (32 - bits)
        }
        for (shape in interpreter.stateShapes()) {
            var size = 1
            for (d in shape) size *= d
            state.add(FloatArray(size))
        }
    }

    /** 清空全部流式状态（换曲 / seek / 重新开启伴唱）。 */
    fun reset() {
        for (s in state) s.fill(0f)
        carry.fill(0f)
        tailV.fill(0f)
        tailA.fill(0f)
        tailW.fill(0f)
        inLen = 0
        ringW = 0
        ringR = 0
        ringN = 0
        ringOff = 0
    }

    /** 环形里排队待取的块数（诊断用）。 */
    fun pendingBlocks(): Int = ringN

    /** 释放推理后端。 */
    fun close() {
        try {
            interpreter.close()
        } catch (t: Throwable) {
            // 释放失败不影响进程退出
        }
    }

    /**
     * 送入一段交错立体声，取出本批可用输出。
     *
     * @return `[vocals, accompaniment]`，均为长度 2*n 的交错立体声。预热期
     *         （首块还没算完）返回全零，由调用方回落到原音。
     */
    fun process(inter: FloatArray, n: Int): Array<FloatArray> {
        // ── 入队 ──
        if (n * 2 > inQ.size - inLen) {
            // 溢出丢最旧：慢设备上宁可丢历史也不让队列无限增长
            val drop = n * 2 - (inQ.size - inLen)
            System.arraycopy(inQ, drop, inQ, 0, inLen - drop)
            inLen -= drop
        }
        System.arraycopy(inter, 0, inQ, inLen, n * 2)
        inLen += n * 2

        // ── 每个满窗口推理一次 ──
        while (inLen >= 2 * WIN && ringN < RING) {
            runBlock()
            System.arraycopy(inQ, 2 * CHUNK, inQ, 0, inLen - 2 * CHUNK)
            inLen -= 2 * CHUNK
        }

        // ── 产出恰好 n 个样本（首块完成前为 0）──
        val voc = FloatArray(2 * n)
        val acc = FloatArray(2 * n)
        val need = 2 * n
        var got = 0
        while (got < need && ringN > 0) {
            val v = vocRing[ringR]
            val a = accRing[ringR]
            val take = minOf(2 * CHUNK - ringOff, need - got)
            System.arraycopy(v, ringOff, voc, got, take)
            System.arraycopy(a, ringOff, acc, got, take)
            ringOff += take
            got += take
            if (ringOff >= 2 * CHUNK) {
                ringOff = 0
                ringR = (ringR + 1) % RING
                ringN--
            }
        }
        return arrayOf(voc, acc)
    }

    /** 对 `inQ[0 .. WIN)` 做一次推理，向 ring 写入 CHUNK 个样本。 */
    private fun runBlock() {
        buf.fill(0f)
        System.arraycopy(carry, 0, buf, 0, carry.size)
        System.arraycopy(inQ, 0, buf, carry.size, WIN * 2)

        // ── 前向 STFT（平面布局！）──
        for (t in 0 until FRAMES) {
            for (c in 0 until 2) {
                val start = t * HOP
                for (i in 0 until N_FFT) {
                    re[i] = buf[2 * (start + i) + c] * win[i]
                    im[i] = 0f
                }
                fft(forward = true)
                val base = t * 4 * BINS + c * 2 * BINS
                for (f in 0 until BINS) {
                    inPlane[base + f] = re[f]              // *_re 平面
                    inPlane[base + BINS + f] = im[f]       // *_im 平面
                }
            }
        }

        // ── 推理 ──
        interpreter.run(inPlane, state, outPlane)

        // ── 逆变换 + 叠加 ──
        vL.fill(0f); vR.fill(0f)
        aL.fill(0f); aR.fill(0f)
        wsum.fill(0f)
        // tailV / tailA 是 [L…][R…] 两段，不是交错（见类注释的坑 2）
        System.arraycopy(tailV, 0, vL, PAD, TAIL)
        System.arraycopy(tailV, TAIL, vR, PAD, TAIL)
        System.arraycopy(tailA, 0, aL, PAD, TAIL)
        System.arraycopy(tailA, TAIL, aR, PAD, TAIL)
        System.arraycopy(tailW, 0, wsum, PAD, tailW.size)

        for (t in 0 until FRAMES) {
            val start = t * HOP
            var i = 0
            while (i < N_FFT && start + i < OLA) {
                wsum[start + i] += win[i] * win[i]
                i++
            }
            for (c in 0 until 2) {
                val dstV = if (c == 0) vL else vR
                val dstA = if (c == 0) aL else aR
                for (stem in 0 until 2) {
                    re.fill(0f)
                    im.fill(0f)
                    for (f in 0 until BINS) {
                        val p = (t * 16 + c * 2) * BINS + f
                        var r: Float
                        var i2: Float
                        if (stem == 0) {
                            r = outPlane[p]
                            i2 = outPlane[p + BINS]            // *_im 平面
                        } else {
                            // 伴奏 = 贝斯 + 鼓 + 其他（stem 1..3）
                            r = 0f
                            i2 = 0f
                            for (s in 1 until 4) {
                                r += outPlane[p + s * 4 * BINS]
                                i2 += outPlane[p + s * 4 * BINS + BINS]
                            }
                        }
                        re[f] = r
                        im[f] = i2
                    }
                    // Hermitian 镜像保证逆变换结果为实数
                    for (f in 1 until BINS) {
                        re[N_FFT - f] = re[f]
                        im[N_FFT - f] = -im[f]
                    }
                    fft(forward = false)
                    var i2idx = 0
                    while (i2idx < N_FFT && start + i2idx < OLA) {
                        val v = re[i2idx] * win[i2idx]
                        if (stem == 0) {
                            dstV[start + i2idx] += v
                        } else {
                            dstA[start + i2idx] += v
                        }
                        i2idx++
                    }
                }
            }
        }

        // ── 按窗能量归一，产出 CHUNK 个样本 ──
        val voc = FloatArray(2 * CHUNK)
        val acc = FloatArray(2 * CHUNK)
        for (i in 0 until CHUNK) {
            val p = PAD + i
            val w = maxOf(wsum[p], 1e-8f)
            voc[2 * i] = vL[p] / w
            voc[2 * i + 1] = vR[p] / w
            acc[2 * i] = aL[p] / w
            acc[2 * i + 1] = aR[p] / w
        }

        // ── 携带量与尾量 ──
        System.arraycopy(buf, 2 * CHUNK, carry, 0, carry.size)
        System.arraycopy(vL, PAD + CHUNK, tailV, 0, TAIL)
        System.arraycopy(vR, PAD + CHUNK, tailV, TAIL, TAIL)
        System.arraycopy(aL, PAD + CHUNK, tailA, 0, TAIL)
        System.arraycopy(aR, PAD + CHUNK, tailA, TAIL, TAIL)
        System.arraycopy(wsum, PAD + CHUNK, tailW, 0, TAIL)

        if (ringN < RING) {
            System.arraycopy(voc, 0, vocRing[ringW], 0, 2 * CHUNK)
            System.arraycopy(acc, 0, accRing[ringW], 0, 2 * CHUNK)
            ringW = (ringW + 1) % RING
            ringN++
        }
    }

    /** 原地 radix-2 FFT。 */
    private fun fft(forward: Boolean) {
        for (i in 0 until N_FFT) {
            val j = rev[i]
            if (j > i) {
                val t = re[i]; re[i] = re[j]; re[j] = t
                val t2 = im[i]; im[i] = im[j]; im[j] = t2
            }
        }
        var len = 2
        while (len <= N_FFT) {
            val half = len shr 1
            val step = N_FFT / len
            var i = 0
            while (i < N_FFT) {
                for (k in 0 until half) {
                    val wr = cosT[k * step]
                    val wi = if (forward) sinT[k * step] else -sinT[k * step]
                    val a = i + k
                    val b = a + half
                    val xr = re[b] * wr - im[b] * wi
                    val xi = re[b] * wi + im[b] * wr
                    re[b] = re[a] - xr; im[b] = im[a] - xi
                    re[a] += xr; im[a] += xi
                }
                i += len
            }
            len = len shl 1
        }
        if (!forward) {
            val s = 1f / N_FFT
            for (i in 0 until N_FFT) {
                re[i] *= s
                im[i] *= s
            }
        }
    }
}
