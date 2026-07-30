package com.md3music.md3music

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.widget.RemoteViews

/**
 * 桌面音乐播放器小组件。
 *
 * 样式参照 app 内 MiniPlayer：封面 + 标题 + 艺术家 + 播放/暂停 + 下一首 + 进度条。
 * 封面直接从 AudioPlaybackService 的 MediaSession 封面缓存同步，保证与通知栏一致。
 */
class MusicWidgetProvider : AppWidgetProvider() {

    companion object {
        const val ACTION_UPDATE_WIDGET = "com.md3music.md3music.ACTION_UPDATE_WIDGET"
        const val ACTION_PLAY_PAUSE = "com.md3music.md3music.ACTION_WIDGET_PLAY_PAUSE"
        const val ACTION_NEXT = "com.md3music.md3music.ACTION_WIDGET_NEXT"

        const val EXTRA_TITLE = "widget_title"
        const val EXTRA_ARTIST = "widget_artist"
        const val EXTRA_IS_PLAYING = "widget_is_playing"
        const val EXTRA_POSITION = "widget_position"
        const val EXTRA_DURATION = "widget_duration"

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
            context.sendBroadcast(intent)
        }

        /**
         * 由 AudioPlaybackService 加载封面后调用：同步刷新 widget 封面。
         */
        fun notifyArtworkChanged(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(
                ComponentName(context, MusicWidgetProvider::class.java)
            )
            if (ids.isEmpty()) return
            val intent = Intent(context, MusicWidgetProvider::class.java).apply {
                action = ACTION_UPDATE_WIDGET
                // 复用上次缓存的文本状态，仅更新封面
                putExtra(EXTRA_TITLE, lastTitle)
                putExtra(EXTRA_ARTIST, lastArtist)
                putExtra(EXTRA_IS_PLAYING, lastPlaying)
                putExtra(EXTRA_POSITION, lastPosition)
                putExtra(EXTRA_DURATION, lastDuration)
            }
            context.sendBroadcast(intent)
        }

        // 缓存最近一次的文本状态，供封面更新时复用
        private var lastTitle = "MD3Music"
        private var lastArtist = "未在播放"
        private var lastPlaying = false
        private var lastPosition = 0L
        private var lastDuration = 0L
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

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)

        when (intent.action) {
            ACTION_UPDATE_WIDGET -> {
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
                    val launchIntent = Intent(context, MainActivity::class.java).apply {
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                        putExtra("widget_action", "togglePlayPause")
                    }
                    context.startActivity(launchIntent)
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
                    val launchIntent = Intent(context, MainActivity::class.java).apply {
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                        putExtra("widget_action", "next")
                    }
                    context.startActivity(launchIntent)
                }
            }
        }
    }

    private fun updateWidget(
        context: Context,
        manager: AppWidgetManager,
        appWidgetId: Int,
        dataIntent: Intent?
    ) {
        val views = RemoteViews(context.packageName, R.layout.widget_music_player)

        val title = dataIntent?.getStringExtra(EXTRA_TITLE) ?: "MD3Music"
        val artist = dataIntent?.getStringExtra(EXTRA_ARTIST) ?: "未在播放"
        val isPlaying = dataIntent?.getBooleanExtra(EXTRA_IS_PLAYING, false) ?: false
        val position = dataIntent?.getLongExtra(EXTRA_POSITION, 0L) ?: 0L
        val duration = dataIntent?.getLongExtra(EXTRA_DURATION, 0L) ?: 0L

        // 缓存文本状态，供封面异步加载完成后复用
        lastTitle = title
        lastArtist = artist
        lastPlaying = isPlaying
        lastPosition = position
        lastDuration = duration

        // 更新文本
        views.setTextViewText(R.id.widget_title, title)
        views.setTextViewText(R.id.widget_artist, artist)

        // 更新播放/暂停图标
        views.setImageViewResource(
            R.id.widget_btn_play_pause,
            if (isPlaying) android.R.drawable.ic_media_pause
            else android.R.drawable.ic_media_play
        )

        // 更新进度条
        if (duration > 0) {
            val progress = ((position.toFloat() / duration.toFloat()) * 100).toInt()
            views.setInt(R.id.widget_progress, "setProgress", progress.coerceIn(0, 100))
        } else {
            views.setInt(R.id.widget_progress, "setProgress", 0)
        }

        // 封面：直接从 MediaSession 缓存读取（与通知栏一致）
        val art = cachedArtwork
        if (art != null) {
            views.setImageViewBitmap(R.id.widget_artwork, art)
        }

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
    }
}
