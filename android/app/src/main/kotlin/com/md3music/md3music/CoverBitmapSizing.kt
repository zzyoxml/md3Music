package com.md3music.md3music

/** 返回不会超过目标边长的2次幂采样倍率。 */
internal fun coverBitmapSampleSize(width: Int, height: Int, maxSize: Int): Int {
    if (width <= 0 || height <= 0 || maxSize <= 0) return 1
    var sampleSize = 1
    while (maxOf(width, height) / sampleSize > maxSize) {
        sampleSize *= 2
    }
    return sampleSize
}
