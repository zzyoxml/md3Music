package com.md3music.md3music

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.BitmapShader
import android.graphics.Shader
import android.os.Bundle
import android.util.Log
import android.widget.RemoteViews

/**
 * 桌面音乐播放器小组件。
 *
 * 样式对齐 app 内 MiniPlayer 与 MD3E：专辑封面圆角、播放按钮 primary 圆形
 * 填充、下一首次级圆形按钮、MD3 胶囊进度条。颜色由 Flutter 侧推送的当前
 * ColorScheme 提供（color_* extras，与 PersonalFmWidgetProvider 同一套协议），
 * app 从未推送过时用 Material 3 基准紫兜底。封面位图经 Canvas 裁圆角。
 * 兼容性约束同私人FM小部件：不用负 margin、不用裸 <View>。
 */
class MusicWidgetProvider : AppWidgetProvider() {

    companion object {
        private const val TAG = "MusicWidget"

        const val ACTION_UPDATE_WIDGET = "com.md3music.md3music.ACTION_UPDATE_WIDGET"
        const val ACTION_PLAY_PAUSE = "com.md3music.md3music.ACTION_WIDGET_PLAY_PAUSE"
        const val ACTION_NEXT = "com.md3music.md3music.ACTION_WIDGET_NEXT"

        const val EXTRA_TITLE = "widget_title"
        const val EXTRA_ARTIST = "widget_artist"
        const val EXTRA_IS_PLAYING = "widget_is_playing"
        const val EXTRA_POSITION = "widget_position"
        const val EXTRA_DURATION = "widget_duration"

        // 动态取色 extras（与 PersonalFmWidgetProvider 同一套 color_ 前缀协议）
        private const val COLOR_PREFIX = "color_"
        private val COLOR_KEYS = arrayOf(
            "panelBg", "primary", "onPrimary", "surfaceHigh",
            "onSurface", "onSurfaceVariant", "outlineVariant",
        )

        // Material 3 基准紫（浅色）兜底：app 从未推送过主题色时使用
        private val defaultColors = mapOf(
            "panelBg" to 0xFFF7F2FA.toInt(),
            "primary" to 0xFF6750A4.toInt(),
            "onPrimary" to 0xFFFFFFFF.toInt(),
            "surfaceHigh" to 0xFFECE6F0.toInt(),
            "onSurface" to 0xFF1D1B20.toInt(),
            "onSurfaceVariant" to 0xFF49454F.toInt(),
            "outlineVariant" to 0xFFCAC4D0.toInt(),
        )

        private fun c(key: String): Int =
            lastColors[key] ?: (defaultColors[key] ?: 0)

        /// 全局封面缓存：由 AudioPlaybackService 加载通知封面时同步写入。
        /// Widget 直接读取此 bitmap，不再自己解析文件路径。
        @Volatile
        var cachedArtwork: Bitmap? = null

        /**
         * 从 Flutter 侧调用：更新所有已放置的 widget 实例。
         */
        fun updateAllWidgets(
            context: Context,
            title: String,
            artist: String,
            isPlaying: Boolean,
            position: Long,
            duration: Long
        ) {
            val intent = Intent(context, MusicWidgetProvider::class.java).apply {
                action = ACTION_UPDATE_WIDGET
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_ARTIST, artist)
                putExtra(EXTRA_IS_PLAYING, isPlaying)
                putExtra(EXTRA_POSITION, position)
                putExtra(EXTRA_DURATION, duration)
            }
            try {
                context.sendBroadcast(intent)
            } catch (e: Exception) {
                Log.w(TAG, "updateAllWidgets broadcast failed", e)
            }
        }

        /**
         * 由 AudioPlaybackService 加载封面后调用：同步刷新 widget 封面。
         */
        fun notifyArtworkChanged(context: Context) {
            val intent = Intent(context, MusicWidgetProvider::class.java).apply {
                action = ACTION_UPDATE_WIDGET
                // 复用上次缓存的文本状态，仅更新封面
                putExtra(EXTRA_TITLE, lastTitle)
                putExtra(EXTRA_ARTIST, lastArtist)
                putExtra(EXTRA_IS_PLAYING, lastPlaying)
                putExtra(EXTRA_POSITION, lastPosition)
                putExtra(EXTRA_DURATION, lastDuration)
            }
            try {
                context.sendBroadcast(intent)
            } catch (_: Exception) {}
        }

        /**
         * 由 Flutter 侧调用（MainActivity 转发）：仅推送主题色，文本走缓存。
         */
        fun updateTheme(context: Context, colors: Map<String, Number>) {
            val intent = Intent(context, MusicWidgetProvider::class.java).apply {
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
        private var lastPosition = 0L
        private var lastDuration = 0L
        private val lastColors = mutableMapOf<String, Int>()

        // 圆角封面结果缓存：记录源的尺寸指纹，避免切歌后同尺寸新封面误命中
        // 旧封面缓存（AudioPlaybackService 对所有歌曲统一降采样到 200px）
        private var roundedCover: Bitmap? = null
        private var roundedCoverSource: Int = 0
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

        when (intent.action) {
            ACTION_UPDATE_WIDGET -> {
                // color_* extras 存在时先读主题色（与 FM 小部件同一推送协议）
                for (key in COLOR_KEYS) {
                    if (intent.hasExtra(COLOR_PREFIX + key)) {
                        lastColors[key] = intent.getIntExtra(COLOR_PREFIX + key, c(key))
                    }
                }
                val manager = AppWidgetManager.getInstance(context)
                val ids = manager.getAppWidgetIds(
                    ComponentName(context, MusicWidgetProvider::class.java)
                )
                for (id in ids) {
                    updateWidget(context, manager, id, intent)
                }
            }
            ACTION_PLAY_PAUSE -> {
                // 先尝试通过 Service 转发给 Flutter；若 app 进程已死则启动 app
                val serviceIntent = Intent(context, AudioPlaybackService::class.java).apply {
                    action = AudioPlaybackService.ACTION_WIDGET_PLAY_PAUSE
                }
                try {
                    context.startService(serviceIntent)
                } catch (_: Exception) {}
                // 若无可用 FlutterEngine，直接拉起 app（Flutter 侧会自动恢复播放状态）
                if (!AudioPlaybackService.hasFlutterEngine()) {
                    launchApp(context)
                }
            }
            ACTION_NEXT -> {
                val serviceIntent = Intent(context, AudioPlaybackService::class.java).apply {
                    action = AudioPlaybackService.ACTION_WIDGET_NEXT
                }
                try {
                    context.startService(serviceIntent)
                } catch (_: Exception) {}
                if (!AudioPlaybackService.hasFlutterEngine()) {
                    launchApp(context)
                }
            }
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
            val views = RemoteViews(context.packageName, R.layout.widget_music_player)
            val density = context.resources.displayMetrics.density

            val title = dataIntent?.getStringExtra(EXTRA_TITLE) ?: lastTitle
            val artist = dataIntent?.getStringExtra(EXTRA_ARTIST) ?: lastArtist
            val isPlaying = dataIntent?.getBooleanExtra(EXTRA_IS_PLAYING, lastPlaying) ?: lastPlaying
            val position = dataIntent?.getLongExtra(EXTRA_POSITION, lastPosition) ?: lastPosition
            val duration = dataIntent?.getLongExtra(EXTRA_DURATION, lastDuration) ?: lastDuration

            // 缓存文本状态，供封面更新时复用
            lastTitle = title
            lastArtist = artist
            lastPlaying = isPlaying
            lastPosition = position
            lastDuration = duration

            // 动态取色：卡片底 / 文本 / 按钮全部对齐推送的 ColorScheme
            views.setInt(R.id.music_card_bg, "setColorFilter", c("panelBg"))
            views.setTextViewText(R.id.widget_title, title)
            views.setTextColor(R.id.widget_title, c("onSurface"))
            views.setTextViewText(R.id.widget_artist, artist)
            views.setTextColor(R.id.widget_artist, c("onSurfaceVariant"))

            // 播放/暂停：primary 圆底 + onPrimary 图标（MD3E 主操作）
            views.setInt(R.id.music_btn_play_bg, "setColorFilter", c("primary"))
            views.setImageViewResource(
                R.id.music_btn_play_icon,
                if (isPlaying) R.drawable.ic_wg_pause else R.drawable.ic_wg_play_arrow
            )
            views.setInt(R.id.music_btn_play_icon, "setColorFilter", c("onPrimary"))

            // 下一首：surfaceContainerHigh 圆底 + onSurfaceVariant 图标（次操作）
            views.setInt(R.id.music_btn_next_bg, "setColorFilter", c("surfaceHigh"))
            views.setInt(R.id.music_btn_next_icon, "setColorFilter", c("onSurfaceVariant"))

            // MD3 胶囊进度条：Canvas 手绘位图（底槽 outlineVariant、进度 primary），
            // 避免 RemoteViews.setProgressTintList 的版本门槛
            val progress = if (duration > 0) {
                ((position.toFloat() / duration.toFloat()) * 100).toInt().coerceIn(0, 100)
            } else {
                0
            }
            try {
                views.setImageViewBitmap(
                    R.id.widget_progress, progressBitmap(progress)
                )
            } catch (e: Exception) {
                Log.w(TAG, "progress bitmap failed", e)
            }

            // 封面：从 MediaSession 缓存读取，Canvas 裁 12dp 圆角后显示
            //（无封面时显示 theme 色占位底 + 保留空位）
            val art = cachedArtwork
            if (art != null) {
                try {
                    // 用源引用指纹判定缓存：切歌后新封面尺寸相同（统一 200px），
                    // 只比尺寸会误命中旧封面 → 第二首仍显示第一首封面
                    val fingerprint = System.identityHashCode(art) + art.width * 31 + art.height
                    val roundedBmp = if (roundedCover != null && fingerprint == roundedCoverSource) {
                        roundedCover!!
                    } else {
                        rounded(art, 12f, density).also {
                            roundedCover = it
                            roundedCoverSource = fingerprint
                        }
                    }
                    views.setImageViewBitmap(R.id.widget_artwork, roundedBmp)
                    views.setViewVisibility(R.id.widget_artwork, android.view.View.VISIBLE)
                } catch (e: Exception) {
                    Log.w(TAG, "rounded cover failed", e)
                }
            } else {
                views.setViewVisibility(R.id.widget_artwork, android.view.View.GONE)
            }
            views.setInt(R.id.music_cover_bg, "setColorFilter", c("surfaceHigh"))

            // 点击整个 widget 打开 app
            val openIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            val openPending = PendingIntent.getActivity(
                context, 0, openIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_root, openPending)

            // 播放/暂停按钮
            val playPauseIntent = Intent(context, MusicWidgetProvider::class.java).apply {
                action = ACTION_PLAY_PAUSE
            }
            val playPausePending = PendingIntent.getBroadcast(
                context, 1, playPauseIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_btn_play_pause, playPausePending)

            // 下一首按钮
            val nextIntent = Intent(context, MusicWidgetProvider::class.java).apply {
                action = ACTION_NEXT
            }
            val nextPending = PendingIntent.getBroadcast(
                context, 2, nextIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_btn_next, nextPending)

            manager.updateAppWidget(appWidgetId, views)
        } catch (e: Exception) {
            Log.w(TAG, "updateWidget failed (id=$appWidgetId)", e)
        }
    }

    /** 把缓存的原始封面裁成圆角（RemoteViews 无 ShapeableImageView，手动 Canvas 裁切）。 */
    private fun rounded(src: Bitmap, radiusDp: Float, density: Float): Bitmap {
        val out = Bitmap.createBitmap(src.width, src.height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        paint.shader = BitmapShader(src, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
        val r = radiusDp * density
        canvas.drawRoundRect(0f, 0f, out.width.toFloat(), out.height.toFloat(), r, r, paint)
        return out
    }

    /**
     * MD3 胶囊进度条位图：全宽底槽 outlineVariant + 胶囊进度 primary。
     * 600×12px 固定尺寸经 fitXY 拉伸，进度变化时重绘（位图仅 28KB，播放进度
     * 推送已节流，开销可忽略）。
     */
    private fun progressBitmap(progress: Int, width: Int = 600, height: Int = 12): Bitmap {
        val out = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        val radius = height / 2f
        val bg = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = c("outlineVariant") }
        canvas.drawRoundRect(0f, 0f, width.toFloat(), height.toFloat(), radius, radius, bg)
        if (progress > 0) {
            val fg = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = c("primary") }
            // 最小画成一个胶囊头，0~100% 线性展开
            val w = (width * progress / 100f).coerceAtLeast(height.toFloat())
            canvas.drawRoundRect(0f, 0f, w, height.toFloat(), radius, radius, fg)
        }
        return out
    }
}
