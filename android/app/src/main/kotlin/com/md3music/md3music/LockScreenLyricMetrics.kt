package com.md3music.md3music

/// 锁屏歌词行盒几何（纯逻辑，不依赖 `android.graphics`）。
///
/// 存在的理由：AM 播放页用 Flutter `TextStyle(height: …)` 排版，行盒内的多余
/// leading **上下各分一半**（半行距），字形因此在行盒里垂直居中；而 Canvas 的
/// `drawText` 是「基线定位」，旧实现用 `行顶 - ascent` 把 leading 全压在字形
/// 下方，于是每个视觉行、每段副行下方的空白都比 AM 大一截（22px 字号/行距 1.5
/// 的实测口径：换行行间空白 ≈7.5px vs AM ≈4.2px）。
///
/// 本对象把口径全部抽成纯函数，绘制期只查表（`RenderedLine.rowBaselines` /
/// `auxBaselines`），既保证与 AM 逐项同式，也能在 JVM 单测里验证，不必上真机看。
///
/// 与 AM 的逐项对应（`lib/widgets/apple_lyrics/layout/lyric_layout.dart`）：
/// - [wrapBoxFactor] ↔ `wrapLineHeightFactor`（0.8）
/// - [auxLineBoxFactor] ↔ `translationLineHeight`（1.5）
/// - [auxGapFactor] ↔ `auxSubHeight` 里的 0.3em 间隙
/// - [auxFontFactor] ↔ `translationFontSize` 的 0.7em
/// - [readableFloor] ↔ `clampReadableFontSize`（字重 <400 时下限 13，否则 12）
internal object LockScreenLyricMetrics {

    /// 换行行盒系数：换行后的视觉行盒 = 主行盒 × 0.8。
    const val wrapBoxFactor = 0.8f

    /// 副行行盒系数：副行每个视觉行盒 = 副行字号 × 1.5。
    const val auxLineBoxFactor = 1.5f

    /// 副行与主行之间的间隙：`副行字号 × 0.3`。
    const val auxGapFactor = 0.3f

    /// 副行字号系数：主行字号 × 0.7（再由 [readableFloor] 兜可读下限）。
    const val auxFontFactor = 0.7f

    /// 半行距的上下分配比。
    ///
    /// 0.5 = 上下各一半（Flutter `TextStyle(height:)` 的默认行为）。留成常量是因为
    /// Android `Paint.fontMetrics` 与 Skia 度量在个别自定义字体上会有 ±1px 级差异，
    /// 真机 A/B 后若发现系统性偏移，只调这一个旋钮即可，不必改公式。
    const val halfLeadingSplit = 0.5f

    /// 主行可读下限之外的固定下限（副行字号不小于该值）。
    const val auxMinFontPx = 12f

    /// 细体（字重 <400）的副行下限：笔画过细时 12px 不可读，抬一档到 13px。
    const val auxMinThinFontPx = 13f

    /// 副行字号的可读下限（与 AM `clampReadableFontSize` 同口径）。
    fun readableFloor(weight: Int): Float =
        if (weight < 400) auxMinThinFontPx else auxMinFontPx

    /// 副行字号：`max(主字号 × 0.7, 可读下限)`。
    fun auxFontSize(fontSizePx: Float, weight: Int): Float {
        val raw = fontSizePx * auxFontFactor
        val floor = readableFloor(weight)
        return if (raw < floor) floor else raw
    }

    /// 主行行盒高：`字号 × 行距系数`（与 AM `fontSize * LyricLayout.lineHeight` 一致）。
    fun mainLineHeight(fontSizePx: Float, lineMult: Float): Float =
        fontSizePx * lineMult

    /// 某一视觉行的行盒高：第 1 个视觉行是完整主行盒，其余为 0.8 倍。
    fun rowBoxHeight(mainH: Float, rowIndex: Int): Float =
        if (rowIndex <= 0) mainH else mainH * wrapBoxFactor

    /// 某一视觉行相对块顶的行盒顶：`0`、`mainH`、`mainH + 0.8mainH`、…
    fun rowTop(mainH: Float, rowIndex: Int): Float =
        if (rowIndex <= 0) 0f else mainH + (rowIndex - 1) * mainH * wrapBoxFactor

    /// 主文本（含换行）占用的高度：`mainH + (rows - 1) × 0.8mainH`。
    fun mainRowsHeight(mainH: Float, rows: Int): Float =
        if (rows <= 1) mainH else mainH + (rows - 1) * mainH * wrapBoxFactor

    /// 副行占用的垂直高度：`rows × 副行字号 × 1.5 + 副行字号 × 0.3`。
    ///
    /// 与 AM `auxSubHeight` 同式：**行数必须参与计算**——旧实现恒用 1.3 倍单行高，
    /// 翻译换到 2 行时预留不足，多出来的行会压到下一行歌词上。
    fun auxReserveHeight(auxFontPx: Float, auxRows: Int): Float {
        if (auxRows <= 0) return 0f
        return auxRows * auxFontPx * auxLineBoxFactor + auxFontPx * auxGapFactor
    }

    /// 副行第 j 个视觉行盒相对块顶的顶边。
    fun auxRowTop(mainH: Float, mainRows: Int, auxFontPx: Float, auxRowIndex: Int): Float =
        mainRowsHeight(mainH, mainRows) + auxFontPx * auxGapFactor +
            auxRowIndex * auxFontPx * auxLineBoxFactor

    /// 行盒内的 baseline 距行盒顶的距离（半行距模型）。
    ///
    /// `halfLead = (行盒高 - 字形高) / 2`，baseline = `行盒顶 + halfLead + (-ascent)`。
    /// 行盒小于字形时 halfLead 为负（行盒相互重叠），与 Flutter `TextStyle(height:)`
    /// 在行距系数 <1 时的行为一致，不做夹取——夹取会破坏「设置里调多紧就多紧」。
    fun baselineInBox(
        boxHeight: Float,
        ascAbs: Float,
        descent: Float,
        split: Float = halfLeadingSplit,
    ): Float {
        val glyph = ascAbs + descent
        val halfLead = (boxHeight - glyph) * split
        return halfLead + ascAbs
    }

    /// 主行第 [rowIndex] 个视觉行的 baseline（相对块顶）。
    fun mainRowBaseline(
        mainH: Float,
        rowIndex: Int,
        ascAbs: Float,
        descent: Float,
    ): Float = rowTop(mainH, rowIndex) +
        baselineInBox(rowBoxHeight(mainH, rowIndex), ascAbs, descent)

    /// 副行第 [auxRowIndex] 个视觉行的 baseline（相对块顶）。
    fun auxRowBaseline(
        mainH: Float,
        mainRows: Int,
        auxFontPx: Float,
        auxRowIndex: Int,
        auxAscAbs: Float,
        auxDescent: Float,
    ): Float = auxRowTop(mainH, mainRows, auxFontPx, auxRowIndex) +
        baselineInBox(auxFontPx * auxLineBoxFactor, auxAscAbs, auxDescent)

    /// 整行块高：主文本（含换行）+ 副行预留。
    fun lineBlockHeight(mainH: Float, rows: Int, auxFontPx: Float, auxRows: Int): Float =
        mainRowsHeight(mainH, rows) + auxReserveHeight(auxFontPx, auxRows)
}
