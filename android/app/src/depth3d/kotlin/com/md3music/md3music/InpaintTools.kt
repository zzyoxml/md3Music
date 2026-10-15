package com.md3music.md3music

/**
 * 3D 封面背景修补工具集。
 * 参考 vt-vl-lab/3d-photo-inpainting 的经典部分：
 * - jointBilateralSmooth: 保边深度平滑（bilateral_filtering.py 同构思路，
 *   以亮度差为引导权重，深度在主体边缘外不跨边模糊）。
 * - fgMask: 前景掩码（smoothstep 羽化），1=主体/洞，0=背景。
 */
object InpaintTools {
    private const val D = DepthCoverPlugin.DEPTH_SIZE // 518

    /**
     * 联合双边滤波平滑深度图。radius=2（5×5 窗），sigmaS 按像素距离、
     * sigmaC 按引导亮度差（归一化 0..1）。输出新 FloatArray，不改输入。
     * norm 与 guide 均为 D*D 行主序（guide 为原图灰度，同网格）。
     */
    fun jointBilateralSmooth(
        norm: FloatArray,
        guide: FloatArray,
        radius: Int = 2,
        sigmaS: Float = 1.4f,
        sigmaC: Float = 0.12f,
    ): FloatArray {
        val out = FloatArray(norm.size)
        val inv2s2 = 1f / (2f * sigmaS * sigmaS)
        val inv2c2 = 1f / (2f * sigmaC * sigmaC)
        for (y in 0 until D) {
            for (x in 0 until D) {
                val i = y * D + x
                val c0 = guide[i]
                var wSum = 0f
                var acc = 0f
                for (dy in -radius..radius) {
                    val yy = (y + dy).coerceIn(0, D - 1)
                    for (dx in -radius..radius) {
                        val xx = (x + dx).coerceIn(0, D - 1)
                        val j = yy * D + xx
                        val ds = ((dx * dx + dy * dy).toFloat()) * inv2s2
                        val dc = (guide[j] - c0).let { it * it } * inv2c2
                        val w = kotlin.math.exp(-(ds + dc))
                        acc += w * norm[j]
                        wSum += w
                    }
                }
                out[i] = acc / wSum
            }
        }
        return out
    }

    /** smoothstep(edge0, edge1, x)。 */
    fun smoothstep(e0: Float, e1: Float, x: Float): Float {
        val t = ((x - e0) / (e1 - e0)).coerceIn(0f, 1f)
        return t * t * (3f - 2f * t)
    }

    /**
     * 前景掩码：深度 >= lo 渐入，>= hi 全前景。返回 D*D FloatArray（0..1）。
     * 阈值与现有 BANDS 前景带（0.65..1.00）对齐并留羽化带。
     */
    fun fgMask(norm: FloatArray, lo: Float = 0.55f, hi: Float = 0.65f): FloatArray =
        FloatArray(norm.size) { smoothstep(lo, hi, norm[it]) }

    /**
     * 掩码膨胀（分离式 max filter：水平一趟+垂直一趟，等价方形结构元）。
     * 洞向外扩 [radius] 像素，把主体过渡带（发丝/抗锯齿混合色）吞进洞里，
     * 使 push-pull 的填充源只来自纯净背景——消除轮廓污染环的关键一步。
     */
    fun dilateHole(mask: FloatArray, radius: Int = 2): FloatArray {
        val tmp = FloatArray(mask.size)
        for (y in 0 until D) {
            val row = y * D
            for (x in 0 until D) {
                var m = 0f
                for (dx in -radius..radius) {
                    val xx = (x + dx).coerceIn(0, D - 1)
                    m = maxOf(m, mask[row + xx])
                }
                tmp[row + x] = m
            }
        }
        val out = FloatArray(mask.size)
        for (y in 0 until D) {
            for (x in 0 until D) {
                var m = 0f
                for (dy in -radius..radius) {
                    val yy = (y + dy).coerceIn(0, D - 1)
                    m = maxOf(m, tmp[yy * D + x])
                }
                out[y * D + x] = m
            }
        }
        return out
    }
}
