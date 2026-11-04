package com.md3music.md3music

/**
 * Push-Pull 金字塔插值修补（Gortler et al. 2006；Facebook 3D Photos 同类思路）。
 *
 * 输入：原图像素（ARGB IntArray，w*h）+ 前景掩码（同分辨率，1=洞）。
 * 输出：修补后的整幅背景图（洞被周围背景像素金字塔加权填充，非洞像素原样保留）。
 *
 * 优点：O(n)、零依赖、大洞也能平滑填充；代价是填充区偏平滑（对音乐封面
 * 视差场景足够——洞只在小幅位移时露出，平滑填充远优于透明洞/轮廓拉伸）。
 */
object PullPushFiller {

    /** 单层像素：rgb 打包 + 权重（洞=0）。 */
    private class Level(val w: Int, val h: Int) {
        val r = FloatArray(w * h)
        val g = FloatArray(w * h)
        val b = FloatArray(w * h)
        val wt = FloatArray(w * h)
    }

    /**
     * 修补入口。mask[y*w+x] ∈ 0..1 为洞的概率（≥0.5 视为完全洞、权重 0），
     * 0..0.5 之间按线性降权——掩码羽化边缘自然过渡。
     */
    fun fill(pixels: IntArray, w: Int, h: Int, mask: FloatArray): IntArray {
        // 1) 镜像 pad 8px：让 push-pull 在边缘也能用真实背景而非拉伸（防边缘条带）
        val pad = 8
        val pw = w + 2 * pad
        val ph = h + 2 * pad
        val pPix = IntArray(pw * ph)
        val pMask = FloatArray(pw * ph)
        for (y in 0 until ph) {
            val sy = mirror(y - pad, h)
            for (x in 0 until pw) {
                val sx = mirror(x - pad, w)
                val si = sy * w + sx
                val di = y * pw + x
                pPix[di] = pixels[si]
                pMask[di] = mask[si]
            }
        }
        // 2) Pull：逐层 2x 降采样，洞像素权重 0
        val levels = ArrayList<Level>()
        levels.add(toLevel(pPix, pMask, pw, ph))
        while (levels.last().w > 1 || levels.last().h > 1) {
            val up = levels.last()
            val nw = (up.w + 1) / 2
            val nh = (up.h + 1) / 2
            val lo = Level(nw, nh)
            for (y in 0 until nh) {
                for (x in 0 until nw) {
                    var r = 0f
                    var g = 0f
                    var b = 0f
                    var ws = 0f
                    for (dy in 0..1) for (dx in 0..1) {
                        val ux = (x * 2 + dx).coerceAtMost(up.w - 1)
                        val uy = (y * 2 + dy).coerceAtMost(up.h - 1)
                        val ui = uy * up.w + ux
                        val wgt = up.wt[ui]
                        r += up.r[ui] * wgt
                        g += up.g[ui] * wgt
                        b += up.b[ui] * wgt
                        ws += wgt
                    }
                    val li = y * nw + x
                    if (ws > 1e-6f) {
                        lo.r[li] = r / ws
                        lo.g[li] = g / ws
                        lo.b[li] = b / ws
                    }
                    lo.wt[li] = ws / 4f
                }
            }
            levels.add(lo)
        }
        // 3) Push：自顶向下回填洞像素（双线性插值上层），非洞像素保持原样
        for (li in levels.size - 2 downTo 0) {
            val lo = levels[li]
            val up = levels[li + 1]
            val isBase = li == 0
            for (y in 0 until lo.h) {
                for (x in 0 until lo.w) {
                    val i = y * lo.w + x
                    val keep = lo.wt[i]
                    // 非底层：只回填完全洞（羽化像素在下采样层保持原值，避免漂移）
                    if (keep >= 1f - 1e-6f || (!isBase && keep > 1e-6f)) continue
                    // 上层坐标（双线性）
                    val fx = (x - 0.5f) / 2f
                    val fy = (y - 0.5f) / 2f
                    val x0 = fx.toInt().coerceIn(0, up.w - 1)
                    val y0 = fy.toInt().coerceIn(0, up.h - 1)
                    val x1 = (x0 + 1).coerceAtMost(up.w - 1)
                    val y1 = (y0 + 1).coerceAtMost(up.h - 1)
                    val tx = (fx - x0).coerceIn(0f, 1f)
                    val ty = (fy - y0).coerceIn(0f, 1f)
                    fun pick(arr: FloatArray) =
                        arr[y0 * up.w + x0] * (1 - tx) * (1 - ty) +
                            arr[y0 * up.w + x1] * tx * (1 - ty) +
                            arr[y1 * up.w + x0] * (1 - tx) * ty +
                            arr[y1 * up.w + x1] * tx * ty
                    val pr = pick(up.r)
                    val pg = pick(up.g)
                    val pb = pick(up.b)
                    if (isBase && keep > 1e-6f) {
                        // 底层羽化像素：原色（主体边缘污染源）与填充色按 keep 混合，
                        // 消除轮廓硬边环——这是「主体外轮廓条带」的直接修复点
                        lo.r[i] = lo.r[i] * keep + pr * (1 - keep)
                        lo.g[i] = lo.g[i] * keep + pg * (1 - keep)
                        lo.b[i] = lo.b[i] * keep + pb * (1 - keep)
                    } else {
                        lo.r[i] = pr
                        lo.g[i] = pg
                        lo.b[i] = pb
                    }
                    // 继承上层有效权重（>0 即可继续下传；全洞金字塔顶wt=0则保持0，
                    // 最终裁回输出时洞像素为 0,0,0——仅发生在全图皆洞的极端输入）
                    lo.wt[i] = up.wt[y0 * up.w + x0]
                }
            }
        }
        // 4) 裁回原尺寸输出
        val base = levels[0]
        val out = IntArray(w * h)
        for (y in 0 until h) {
            for (x in 0 until w) {
                val bi = (y + pad) * pw + (x + pad)
                val a = (pixels[y * w + x] ushr 24) and 0xFF
                val r = base.r[bi].toInt().coerceIn(0, 255)
                val g = base.g[bi].toInt().coerceIn(0, 255)
                val b = base.b[bi].toInt().coerceIn(0, 255)
                out[y * w + x] = (a shl 24) or (r shl 16) or (g shl 8) or b
            }
        }
        return out
    }

    private fun toLevel(pix: IntArray, mask: FloatArray, w: Int, h: Int): Level {
        val lv = Level(w, h)
        for (i in pix.indices) {
            val p = pix[i]
            val hole = mask[i]
            // 洞概率 >=0.5 → 权重 0；羽化区线性降权
            val keep = ((0.5f - hole) * 2f).coerceIn(0f, 1f)
            lv.r[i] = ((p shr 16) and 0xFF).toFloat()
            lv.g[i] = ((p shr 8) and 0xFF).toFloat()
            lv.b[i] = (p and 0xFF).toFloat()
            lv.wt[i] = keep
        }
        return lv
    }

    /** 镜像坐标折返（-1 → 0，w → w-1）。 */
    private fun mirror(v: Int, size: Int): Int {
        var x = v
        if (x < 0) x = -x - 1
        if (x >= size) x = 2 * size - x - 1
        return x.coerceIn(0, size - 1)
    }
}
