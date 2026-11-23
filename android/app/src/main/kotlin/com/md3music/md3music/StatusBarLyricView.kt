package com.md3music.md3music

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.os.SystemClock
import android.view.View
import kotlin.math.abs
import kotlin.math.min

/**
 * Kugou-style, SINGLE LINE overlay painter. All dimensions/positions are set by
 * FloatingLyricService; this View has no background and does not consume touches.
 *
 * Verified from a RedMagic 11 Pro+ window dump: Kugou uses an APPLICATION_OVERLAY
 * in the status bar's physical bounds. Its exact scrolling interpolator is NOT
 * known. The long-line follow algorithm below is an independent approximation.
 */
internal class StatusBarLyricView(context: Context) : View(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG).apply {
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        color = Color.rgb(91, 200, 255)
        textAlign = Paint.Align.LEFT
    }
    private var line = ""
    private var words: List<WordTiming> = emptyList()
    private var basePositionMs = 0L
    private var baseElapsedMs = 0L
    private var playing = false
    private var scrollX = 0f
    private var lastFrameElapsed = 0L
    private var fontDp = 14f

    private val sungColor = 0xFF5BC8FF.toInt()
    private val unsungColor = 0xFF9EDEFF.toInt()

    init {
        setWillNotDraw(false)
        isClickable = false
        setFontDp(fontDp)
    }

    fun setFontDp(value: Float) {
        fontDp = value.coerceIn(12f, 22f)
        // Kugou's BaseLyricView uses an integer size derived from density,
        // NOT the framework TextView default scaledDensity (sp) conversion.
        paint.textSize = (fontDp * resources.displayMetrics.density).toInt().toFloat()
        paint.typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        scrollX = 0f
        invalidate()
    }

    fun setLine(text: String, wordTimings: List<WordTiming>, positionMs: Long, isPlaying: Boolean) {
        val changed = line != text || words != wordTimings
        line = text
        words = wordTimings
        basePositionMs = positionMs
        baseElapsedMs = SystemClock.elapsedRealtime()
        playing = isPlaying
        if (changed) scrollX = 0f
        lastFrameElapsed = 0L
        invalidate()
    }

    fun syncPosition(positionMs: Long, isPlaying: Boolean) {
        val predicted = estimatePositionMs()
        if (!isPlaying || !playing || abs(positionMs - predicted) > 150L) {
            basePositionMs = positionMs
            baseElapsedMs = SystemClock.elapsedRealtime()
        }
        playing = isPlaying
        if (!isPlaying) lastFrameElapsed = 0L
        invalidate()
    }

    fun setPlaying(isPlaying: Boolean) {
        basePositionMs = estimatePositionMs()
        baseElapsedMs = SystemClock.elapsedRealtime()
        playing = isPlaying
        if (!isPlaying) lastFrameElapsed = 0L
        invalidate()
    }

    private fun estimatePositionMs(): Long =
        if (playing) basePositionMs + (SystemClock.elapsedRealtime() - baseElapsedMs)
        else basePositionMs

    private fun sungWidth(): Float {
        if (words.isEmpty()) return paint.measureText(line)
        val pos = estimatePositionMs()
        var px = 0f
        for (w in words) {
            val width = paint.measureText(w.text)
            val ratio = if (w.durMs <= 0L) {
                if (pos >= w.startMs) 1f else 0f
            } else {
                ((pos - w.startMs).toFloat() / w.durMs).coerceIn(0f, 1f)
            }
            px += width * ratio
            if (ratio < 1f) break
        }
        return px.coerceIn(0f, paint.measureText(line))
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        if (line.isEmpty() || width <= 0 || height <= 0) return
        val w = width.toFloat()
        val h = height.toFloat()
        val textW = paint.measureText(line)
        if (textW <= 0f) return
        val inset = resources.displayMetrics.density * 2f
        val usableW = (w - inset * 2f).coerceAtLeast(1f)
        val now = SystemClock.elapsedRealtime()
        val sung = sungWidth()

        // Keep the active word near 55% of the window. Smoothly interpolate
        // to avoid jumps at word boundaries; cap scroll at the text's end.
        val maxScroll = (textW - usableW).coerceAtLeast(0f)
        val target = if (maxScroll == 0f) 0f else if (words.isNotEmpty()) {
            (sung - usableW * 0.55f).coerceIn(0f, maxScroll)
        } else {
            // No word timestamps (LRC): slow one-way marquee after 600 ms.
            val sinceLine = if (playing) now - baseElapsedMs else 0L
            (((sinceLine - 600L).coerceAtLeast(0L)) *
                resources.displayMetrics.density * 25f / 1000f).coerceIn(0f, maxScroll)
        }
        val dt = if (lastFrameElapsed == 0L) 0L else (now - lastFrameElapsed).coerceIn(0L, 100L)
        lastFrameElapsed = now
        scrollX = if (dt == 0L) target else scrollX +
            (target - scrollX) * min(1f, dt.toFloat() / 110f)
        if (maxScroll == 0f) scrollX = 0f

        val baseline = h / 2f - (paint.ascent() + paint.descent()) / 2f
        val x = if (textW <= usableW) (w - textW) / 2f else inset - scrollX
        val save = canvas.save()
        canvas.clipRect(inset, 0f, w - inset, h)
        paint.color = if (words.isEmpty()) sungColor else unsungColor
        canvas.drawText(line, x, baseline, paint)
        if (words.isNotEmpty() && sung > 0f) {
            val colorSave = canvas.save()
            canvas.clipRect(x, 0f, x + sung, h)
            paint.color = sungColor
            canvas.drawText(line, x, baseline, paint)
            canvas.restoreToCount(colorSave)
        }
        canvas.restoreToCount(save)
        if (playing && FloatingLyricService.screenOn &&
            (maxScroll > 0.5f || (words.isNotEmpty() && sung < textW))) {
            postInvalidateDelayed(32L)
        }
    }
}
