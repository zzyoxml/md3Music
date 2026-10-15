package com.md3music.md3music

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
import android.os.Bundle
import android.util.Log
import android.widget.RemoteViews
import androidx.palette.graphics.Palette

/**
 * 2×2 封面播放器小组件。
 *
 * 专辑封面全幅铺底（Canvas 裁 16dp 圆角），歌名/歌手居中，底部三键。
 * 播放键颜色从封面 Palette 动态取色；异常兜底策略与 MusicWidgetProvider
 * 一致的三级链：封面 Palette → Flutter 推送的 color_* 主题协议 →
 * Material 3 基准紫。封面位图由 AudioPlaybackService 写入
 * [cachedArtwork]（400px，全幅背景需要比 4×1 小部件的 200px 更高分辨率）。
 * 兼容性约束同现有小部件：不用负 margin、不用裸 <View>。
 */
class CoverPlayerWidgetProvider : AppWidgetProvider() {

    companion object {
        private const val TAG = "CoverPlayerWidget"

        const val ACTION_UPDATE_WIDGET = "com.md3music.md3music.ACTION_COVER_WIDGET_UPDATE"

        // 按钮动作直接复用 AudioPlaybackService 已有 action：
        // ACTION_PREV 在 onStartCommand/handleAction 中已映射到 Flutter 命令 "previous"
        private const val ACTION_PREV = "com.md3music.md3music.ACTION_PREV"
        private const val ACTION_PLAY_PAUSE = "com.md3music.md3music.ACTION_WIDGET_PLAY_PAUSE"
        private const val ACTION_NEXT = "com.md3music.md3music.ACTION_WIDGET_NEXT"

        const val EXTRA_TITLE = "widget_title"
        const val EXTRA_ARTIST = "widget_artist"
        const val EXTRA_IS_PLAYING = "widget_is_playing"

        /// 文本随行标志：updateAllWidgets(true) 携带最新文本；
        /// notifyArtworkChanged(false) 不携带——文本在 onReceive 处理时
        /// 现读 companion 缓存，消除「后台线程烤入过期文本后到覆盖」的竞态
        const val EXTRA_HAS_TEXT = "widget_has_text"

        // 动态取色 extras（与 MusicWidgetProvider 同一套 color_ 前缀协议）
        private const val COLOR_PREFIX = "color_"
        private val COLOR_KEYS = arrayOf(
            "panelBg", "primary", "onPrimary", "surfaceHigh",
            "onSurface", "onSurfaceVariant",
        )

        // Material 3 基准紫（浅色）兜底：app 从未推送过主题色且封面取色不可用时使用
        private val defaultColors = mapOf(
            "panelBg" to 0xFFF7F2FA.toInt(),
            "primary" to 0xFF6750A4.toInt(),
            "onPrimary" to 0xFFFFFFFF.toInt(),
            "surfaceHigh" to 0xFFECE6F0.toInt(),
            "onSurface" to 0xFF1D1B20.toInt(),
            "onSurfaceVariant" to 0xFF49454F.toInt(),
        )

        private fun themeColor(key: String): Int =
            lastColors[key] ?: (defaultColors[key] ?: 0)

        /// 全局封面缓存：由 AudioPlaybackService 加载通知封面时写入（400px）。
        @Volatile
        var cachedArtwork: Bitmap? = null

        /** 从 Flutter 侧调用：更新所有已放置的 widget 实例。 */
        fun updateAllWidgets(
            context: Context,
            title: String,
            artist: String,
            isPlaying: Boolean
        ) {
            Log.i(TAG, "[diag] updateAllWidgets title=$title artist=$artist isPlaying=$isPlaying")
            val intent = Intent(context, CoverPlayerWidgetProvider::class.java).apply {
                action = ACTION_UPDATE_WIDGET
                putExtra(EXTRA_HAS_TEXT, true)
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_ARTIST, artist)
                putExtra(EXTRA_IS_PLAYING, isPlaying)
            }
            try {
                context.sendBroadcast(intent)
            } catch (e: Exception) {
                Log.w(TAG, "updateAllWidgets broadcast failed", e)
            }
        }

        /** 由 AudioPlaybackService 加载封面后调用：复用缓存文本，仅刷新封面。 */
        fun notifyArtworkChanged(context: Context) {
            Log.i(TAG, "[diag] notifyArtworkChanged artHash=${cachedArtwork?.let { System.identityHashCode(it) }}（不携带文本，处理时现读缓存）")
            val intent = Intent(context, CoverPlayerWidgetProvider::class.java).apply {
                action = ACTION_UPDATE_WIDGET
                putExtra(EXTRA_HAS_TEXT, false)
            }
            try {
                context.sendBroadcast(intent)
            } catch (_: Exception) {}
        }

        /** 由 Flutter 侧调用（MainActivity 转发）：仅推送主题色，文本走缓存。 */
        fun updateTheme(context: Context, colors: Map<String, Number>) {
            val intent = Intent(context, CoverPlayerWidgetProvider::class.java).apply {
                action = ACTION_UPDATE_WIDGET
                for ((key, value) in colors) {
                    putExtra(COLOR_PREFIX + key, value.toInt())
                }
            }
            try {
                context.sendBroadcast(intent)
            } catch (_: Exception) {}
        }

        // 缓存最近一次的文本状态，供封面更新时复用
        private var lastTitle = "MD3Music"
        private var lastArtist = "未在播放"
        private var lastPlaying = false
        private val lastColors = mutableMapOf<String, Int>()

        // 圆角封面结果缓存：记录「源尺寸指纹 + 目标宽高」双重指纹，
        // 避免切歌同尺寸误命中，也避免小部件尺寸变化后复用旧宽高比的裁切
        private var roundedCover: Bitmap? = null
        private var roundedCoverSource: Int = 0
        private var roundedCoverTarget: Int = 0

        // Palette 提取缓存：accent 供播放键（反色莫奈化），scrimBase 供遮罩渐变。
        // 随封面指纹失效（同步 generate 只对 400px 位图执行，毫秒级）
        private var accentColor: Int? = null
        private var scrimBase: Int = 0xFF10131A.toInt()
        private var paletteFingerprint: Int = 0
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (appWidgetId in appWidgetIds) {
            updateWidget(context, appWidgetManager, appWidgetId, null)
        }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle?
    ) {
        updateWidget(context, appWidgetManager, appWidgetId, null)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        Log.i(TAG, "[diag] onReceive action=${intent.action} title=${intent.getStringExtra(EXTRA_TITLE)} playing=${if (intent.hasExtra(EXTRA_IS_PLAYING)) intent.getBooleanExtra(EXTRA_IS_PLAYING, false) else null}")

        when (intent.action) {
            ACTION_UPDATE_WIDGET -> {
                for (key in COLOR_KEYS) {
                    if (intent.hasExtra(COLOR_PREFIX + key)) {
                        lastColors[key] = intent.getIntExtra(COLOR_PREFIX + key, themeColor(key))
                    }
                }
                val manager = AppWidgetManager.getInstance(context)
                val ids = manager.getAppWidgetIds(
                    ComponentName(context, CoverPlayerWidgetProvider::class.java)
                )
                for (id in ids) {
                    updateWidget(context, manager, id, intent)
                }
            }
            ACTION_PREV -> forwardToService(context, ACTION_PREV)
            ACTION_PLAY_PAUSE -> forwardToService(context, ACTION_PLAY_PAUSE)
            ACTION_NEXT -> forwardToService(context, ACTION_NEXT)
        }
    }

    /** 转发到 AudioPlaybackService（其 onStartCommand 已处理这些 action）；
     *  app 进程无可用 FlutterEngine 时直接拉起 app 恢复状态。 */
    private fun forwardToService(context: Context, action: String) {
        val serviceIntent = Intent(context, AudioPlaybackService::class.java).apply {
            this.action = action
        }
        try {
            context.startService(serviceIntent)
        } catch (_: Exception) {}
        if (!AudioPlaybackService.hasFlutterEngine()) {
            launchApp(context)
        }
    }

    private fun launchApp(context: Context) {
        try {
            val launchIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            context.startActivity(launchIntent)
        } catch (e: Exception) {
            Log.w(TAG, "launchApp failed", e)
        }
    }

    private fun updateWidget(
        context: Context,
        manager: AppWidgetManager,
        appWidgetId: Int,
        dataIntent: Intent?
    ) {
        try {
            val views = RemoteViews(context.packageName, R.layout.widget_cover_player)
            val density = context.resources.displayMetrics.density

            // 文本来源：文本广播（has_text=true）用 Intent 值；封面广播现读
            // companion 缓存（主线程按序处理，拿到的是已处理完文本广播后的最新值）
            val fromIntent = dataIntent?.getBooleanExtra(EXTRA_HAS_TEXT, true) ?: true
            val title = if (fromIntent) dataIntent?.getStringExtra(EXTRA_TITLE) ?: lastTitle
                        else lastTitle
            val artist = if (fromIntent) dataIntent?.getStringExtra(EXTRA_ARTIST) ?: lastArtist
                         else lastArtist
            val isPlaying = if (fromIntent)
                dataIntent?.getBooleanExtra(EXTRA_IS_PLAYING, lastPlaying) ?: lastPlaying
            else lastPlaying

            lastTitle = title
            lastArtist = artist
            lastPlaying = isPlaying

            val art = cachedArtwork
            Log.i(TAG, "[diag] updateWidget title=$title artist=$artist isPlaying=$isPlaying artNull=${art == null} artHash=${art?.let { System.identityHashCode(it) }}")
            val scrimLight = if (art != null) {
                ensurePalette(art)
                scrimIsLight()
            } else {
                true   // 无封面：浅色占位底，深墨文字
            }

            // 文本色随遮罩基色亮度联动（固定墨色，避免深色主题下主题色不可读）
            val textColor = if (scrimLight) 0xE610131A.toInt() else 0xF2FFFFFF.toInt()
            val subTextColor = if (scrimLight) 0x9910131A.toInt() else 0xB3FFFFFF.toInt()

            // 封面：按小部件实际宽高比预裁到视图尺寸后统一切 16dp 圆角。
            // 不能「先切圆角再交给 centerCrop」：竖长视图会水平裁掉位图两侧，
            // 位图自带圆角恰好落在裁掉区，角落只剩 scrim/启动器兜底，出现方角外露。
            if (art != null) {
                try {
                    val opts = manager.getAppWidgetOptions(appWidgetId)
                    val viewW = (opts.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH)
                        .takeIf { it > 0 } ?: 147) * density
                    val viewH = (opts.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT)
                        .takeIf { it > 0 } ?: 132) * density
                    // 引用指纹判定缓存：切歌后新封面尺寸相同，只比尺寸会误命中旧封面
                    val fingerprint = System.identityHashCode(art) + art.width * 31 + art.height
                    val target = viewW.toInt() * 1000003 + viewH.toInt()
                    val roundedBmp = if (roundedCover != null &&
                        fingerprint == roundedCoverSource && target == roundedCoverTarget
                    ) {
                        roundedCover!!
                    } else {
                        coverCropped(
                            art, viewW.toInt(), viewH.toInt(),
                            (16f * density).toInt(), scrimBase
                        ).also {
                            roundedCover = it
                            roundedCoverSource = fingerprint
                            roundedCoverTarget = target
                        }
                    }
                    views.setImageViewBitmap(R.id.cover_bg, roundedBmp)
                } catch (e: Exception) {
                    Log.w(TAG, "rounded cover failed", e)
                    views.setInt(R.id.cover_bg, "setColorFilter", themeColor("panelBg"))
                }
            } else {
                views.setInt(R.id.cover_bg, "setColorFilter", themeColor("panelBg"))
            }
            views.setViewVisibility(
                R.id.cover_scrim,
                if (art == null) android.view.View.VISIBLE else android.view.View.GONE
            )

            views.setTextViewText(R.id.cover_widget_title, title)
            views.setTextColor(R.id.cover_widget_title, textColor)
            views.setTextViewText(R.id.cover_widget_artist, artist)
            views.setTextColor(R.id.cover_widget_artist, subTextColor)

            // 播放键：accent 圆底 + 对比色图标（Task 4 接入 Palette 后 accent 来自封面）
            val accent = resolveAccent(art)
            Log.i(TAG, "[diag] accent=0x${accent.first.toUInt().toString(16)} scrimBase=0x${scrimBase.toUInt().toString(16)}")
            views.setInt(R.id.cover_btn_play_bg, "setColorFilter", accent.first)
            // 播放/暂停 = 双图标叠放 + 可见性切换：不用 setImageViewResource 换资源
            //（跨应用版本时 MIUI 桌面会忽略/错解资源切换，图标卡死；可见性通道可靠）
            views.setInt(R.id.cover_icon_pause, "setColorFilter", accent.second)
            views.setInt(R.id.cover_icon_play, "setColorFilter", accent.second)
            views.setViewVisibility(
                R.id.cover_icon_pause,
                if (isPlaying) android.view.View.VISIBLE else android.view.View.GONE
            )
            views.setViewVisibility(
                R.id.cover_icon_play,
                if (isPlaying) android.view.View.GONE else android.view.View.VISIBLE
            )

            // 上一首/下一首：无圆底纯图标（同参考图）
            views.setInt(R.id.cover_icon_prev, "setColorFilter", textColor)
            views.setInt(R.id.cover_icon_next, "setColorFilter", textColor)

            // 点击整个 widget 打开 app
            val openIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            val openPending = PendingIntent.getActivity(
                context, 10, openIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_root, openPending)

            views.setOnClickPendingIntent(R.id.cover_btn_prev, broadcastPending(context, 11, ACTION_PREV))
            views.setOnClickPendingIntent(R.id.cover_btn_play, broadcastPending(context, 12, ACTION_PLAY_PAUSE))
            views.setOnClickPendingIntent(R.id.cover_btn_next, broadcastPending(context, 13, ACTION_NEXT))

            manager.updateAppWidget(appWidgetId, views)
        } catch (e: Exception) {
            Log.w(TAG, "updateWidget failed (id=$appWidgetId)", e)
        }
    }

    private fun broadcastPending(context: Context, requestCode: Int, action: String): PendingIntent {
        val intent = Intent(context, CoverPlayerWidgetProvider::class.java).apply {
            this.action = action
        }
        return PendingIntent.getBroadcast(
            context, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    /** 封面 Palette 提取（按封面指纹缓存）：accent 供播放键，dominant 供遮罩基色。 */
    private fun ensurePalette(art: Bitmap) {
        val fingerprint = System.identityHashCode(art) + art.width * 31 + art.height
        if (fingerprint == paletteFingerprint) return
        paletteFingerprint = fingerprint
        scrimBase = 0xFF10131A.toInt()
        accentColor = null
        try {
            val palette = Palette.from(art).maximumColorCount(16).generate()
            val accentSwatch = palette.vibrantSwatch ?: palette.lightVibrantSwatch
                ?: palette.darkVibrantSwatch ?: palette.dominantSwatch
            accentColor = accentSwatch?.rgb
            val scrimSwatch = palette.dominantSwatch ?: palette.mutedSwatch
                ?: palette.darkMutedSwatch ?: accentSwatch
            scrimBase = scrimSwatch?.rgb ?: 0xFF10131A.toInt()
        } catch (e: Exception) {
            Log.w(TAG, "palette extract failed", e)
        }
    }

    /** 遮罩基色亮度：决定文字/图标用深墨还是白。 */
    private fun scrimIsLight(): Boolean =
        androidx.core.graphics.ColorUtils.calculateLuminance(scrimBase) > 0.5

    /**
     * 播放键可读性护栏：取色原色与遮罩基色亮度差不足（暗上暗/亮上亮，如
     * Wolves 深蓝封面取色 0xff082040 与遮罩同色导致按钮隐身）时，向白/黑
     * 混合拉开对比——只调明度不改色相，仍是封面色系；对比充足则原色直出。
     */
    private fun ensureAccentReadable(accent: Int): Int {
        val lum = androidx.core.graphics.ColorUtils.calculateLuminance(accent).toFloat()
        val scrimLum = androidx.core.graphics.ColorUtils.calculateLuminance(scrimBase).toFloat()
        if (kotlin.math.abs(lum - scrimLum) >= 0.20f) return accent
        return if (lum <= scrimLum) {
            val target = (scrimLum + 0.30f).coerceAtMost(0.75f)
            androidx.core.graphics.ColorUtils.blendARGB(
                accent, Color.WHITE, ((target - lum) / (1f - lum)).coerceIn(0f, 1f)
            )
        } else {
            val target = (scrimLum - 0.30f).coerceAtLeast(0.10f)
            androidx.core.graphics.ColorUtils.blendARGB(
                accent, Color.BLACK, ((lum - target) / lum).coerceIn(0f, 1f)
            )
        }
    }

    /** 用指定 alpha 重建颜色（保留 RGB）。 */
    private fun applyAlpha(color: Int, alpha: Int): Int =
        (color and 0xFFFFFF) or (alpha shl 24)

    /**
     * 播放键色 = 封面取色（vibrant → lightVibrant → darkVibrant → dominant）
     * 直接使用，不做反色/莫奈化；图标色按取色亮度取深墨/白保证对比度。
     * 兜底链不变：无封面 → color_ 主题协议 → M3 基准紫。
     */
    private fun resolveAccent(art: Bitmap?): Pair<Int, Int> {
        if (art != null) {
            ensurePalette(art)
            accentColor?.let { accent ->
                val readable = ensureAccentReadable(accent)
                val onAccent = if (androidx.core.graphics.ColorUtils
                        .calculateLuminance(readable) > 0.5
                ) {
                    0xFF1D1B20.toInt()
                } else {
                    Color.WHITE
                }
                return readable to onAccent
            }
        }
        val primary = themeColor("primary")
        val onPrimary = themeColor("onPrimary")
        return primary to onPrimary
    }

    /** 把缓存封面按目标视图宽高比 center-crop，烘焙取色渐变遮罩后切圆角。
     *  遮罩与封面在同一 Canvas 合成、圆角蒙版最后统一处理——整张背景只有
     *  一条抗锯齿边，消除「独立 scrim 层与封面圆角不重合」的边缘露色。 */
    private fun coverCropped(
        src: Bitmap, outW: Int, outH: Int, radiusPx: Int, scrimColor: Int
    ): Bitmap {
        val out = Bitmap.createBitmap(outW, outH, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        // scale-to-fill：取 max(outW/srcW, outH/srcH)，居中裁掉多余部分（同 centerCrop）
        val scale = maxOf(outW / src.width.toFloat(), outH / src.height.toFloat())
        val dx = (outW - src.width * scale) / 2f
        val dy = (outH - src.height * scale) / 2f
        val fill = Paint(Paint.FILTER_BITMAP_FLAG)
        canvas.save()
        canvas.translate(dx, dy)
        canvas.scale(scale, scale)
        canvas.drawBitmap(src, 0f, 0f, fill)
        canvas.restore()
        // 遮罩：封面取色基色，顶部 alpha 0x33 → 底部 alpha 0xE0
        //（顶部保留封面观感，底部文字/按钮区保证对比度）
        val scrim = Paint(Paint.ANTI_ALIAS_FLAG)
        scrim.shader = LinearGradient(
            0f, 0f, 0f, outH.toFloat(),
            applyAlpha(scrimColor, 0x33), applyAlpha(scrimColor, 0xE0),
            Shader.TileMode.CLAMP
        )
        canvas.drawRect(0f, 0f, outW.toFloat(), outH.toFloat(), scrim)
        // 圆角蒙版：EVEN_ODD + dstOut 擦掉圆角以外的像素（遮罩一并被裁齐）
        val eraser = Paint(Paint.ANTI_ALIAS_FLAG)
        eraser.xfermode = android.graphics.PorterDuffXfermode(
            android.graphics.PorterDuff.Mode.DST_OUT
        )
        val inverse = android.graphics.Path().apply {
            addRect(0f, 0f, outW.toFloat(), outH.toFloat(), android.graphics.Path.Direction.CW)
            addRoundRect(
                0f, 0f, outW.toFloat(), outH.toFloat(),
                radiusPx.toFloat(), radiusPx.toFloat(), android.graphics.Path.Direction.CCW
            )
            fillType = android.graphics.Path.FillType.EVEN_ODD
        }
        canvas.drawPath(inverse, eraser)
        return out
    }

}
