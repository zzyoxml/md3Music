package com.md3music.md3music

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.app.NotificationCompat
import androidx.core.graphics.drawable.IconCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class AudioPlaybackService : Service() {
    companion object {
        const val CHANNEL_ID = "md3music_audio_playback"
        const val NOTIFICATION_ID = 1002
        const val ACTION_PREV = "com.md3music.md3music.ACTION_PREV"
        const val ACTION_PLAY_PAUSE = "com.md3music.md3music.ACTION_PLAY_PAUSE"
        const val ACTION_NEXT = "com.md3music.md3music.ACTION_NEXT"
        const val ACTION_STOP = "com.md3music.md3music.ACTION_STOP"
        const val ACTION_TOGGLE_DESKTOP_LYRIC = "com.md3music.md3music.ACTION_TOGGLE_DESKTOP_LYRIC"
        const val EXTRA_TITLE = "title"
        const val EXTRA_ARTIST = "artist"
        const val EXTRA_ART_URL = "artUrl"
        const val EXTRA_IS_PLAYING = "isPlaying"
        const val EXTRA_POSITION = "position"
        const val EXTRA_DURATION = "duration"
        const val EXTRA_DESKTOP_LYRIC_ENABLED = "desktopLyricEnabled"

        // 静态变量用于跨组件传递 FlutterEngine
        private var staticFlutterEngine: FlutterEngine? = null
        private var wakeLock: PowerManager.WakeLock? = null

        fun setFlutterEngine(engine: FlutterEngine) {
            staticFlutterEngine = engine
        }

        fun acquireWakeLock(context: Context) {
            if (wakeLock == null || !wakeLock!!.isHeld) {
                val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "md3music::audio_playback"
                )
                wakeLock?.acquire(24 * 60 * 60 * 1000L)
            }
        }

        fun releaseWakeLock() {
            wakeLock?.let {
                if (it.isHeld) it.release()
            }
            wakeLock = null
        }
    }

    private var mediaSession: MediaSessionCompat? = null
    private var notificationManager: NotificationManager? = null
    private var receiver: BroadcastReceiver? = null
    private var flutterEngine: FlutterEngine? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        notificationManager = getSystemService(NotificationManager::class.java)
        initMediaSession()
        registerReceiver()
        acquireWakeLock(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                releaseWakeLock()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_PREV, ACTION_PLAY_PAUSE, ACTION_NEXT, ACTION_TOGGLE_DESKTOP_LYRIC -> {
                handleAction(intent.action!!)
            }
        }

        val title = intent?.getStringExtra(EXTRA_TITLE) ?: ""
        val artist = intent?.getStringExtra(EXTRA_ARTIST) ?: ""
        val artUrl = intent?.getStringExtra(EXTRA_ART_URL)
        val isPlaying = intent?.getBooleanExtra(EXTRA_IS_PLAYING, false) ?: false
        val position = intent?.getLongExtra(EXTRA_POSITION, 0L) ?: 0L
        val duration = intent?.getLongExtra(EXTRA_DURATION, 0L) ?: 0L
        val desktopLyricEnabled =
            intent?.getBooleanExtra(EXTRA_DESKTOP_LYRIC_ENABLED, false) ?: false

        showNotification(title, artist, artUrl, isPlaying, position, duration, desktopLyricEnabled)

        if (isPlaying) {
            acquireWakeLock(this)
        }

        return START_STICKY
    }

    private fun handleAction(action: String) {
        val engine = flutterEngine ?: staticFlutterEngine
        if (engine != null) {
            val method = when (action) {
                ACTION_PREV -> "previous"
                ACTION_PLAY_PAUSE -> "togglePlayPause"
                ACTION_NEXT -> "next"
                ACTION_TOGGLE_DESKTOP_LYRIC -> "toggleDesktopLyric"
                else -> return
            }
            MethodChannel(engine.dartExecutor.binaryMessenger, "com.md3music.md3music/floating_lyric")
                .invokeMethod(method, null)
        } else {
            sendFlutterCommand(action)
        }
    }

    private fun sendFlutterCommand(action: String) {
        val method = when (action) {
            ACTION_PREV -> "previous"
            ACTION_PLAY_PAUSE -> "togglePlayPause"
            ACTION_NEXT -> "next"
            ACTION_TOGGLE_DESKTOP_LYRIC -> "toggleDesktopLyric"
            else -> return
        }
        val intent = Intent("com.md3music.md3music.FLUTTER_COMMAND").apply {
            putExtra("method", method)
        }
        sendBroadcast(intent)
    }

    fun setFlutterEngine(engine: FlutterEngine) {
        flutterEngine = engine
    }

    private fun initMediaSession() {
        mediaSession = MediaSessionCompat(this, "MD3MusicPlayback").apply {
            setFlags(
                MediaSessionCompat.FLAG_HANDLES_MEDIA_BUTTONS or
                        MediaSessionCompat.FLAG_HANDLES_TRANSPORT_CONTROLS
            )
            setCallback(object : MediaSessionCompat.Callback() {
                override fun onPlay() = handleAction(ACTION_PLAY_PAUSE)
                override fun onPause() = handleAction(ACTION_PLAY_PAUSE)
                override fun onSkipToNext() = handleAction(ACTION_NEXT)
                override fun onSkipToPrevious() = handleAction(ACTION_PREV)
                override fun onStop() = handleAction(ACTION_STOP)
                override fun onSeekTo(pos: Long) {
                    val engine = flutterEngine ?: staticFlutterEngine ?: return
                    MethodChannel(engine.dartExecutor.binaryMessenger, "com.md3music.md3music/floating_lyric")
                        .invokeMethod("seekTo", pos.toInt())
                }
            })
            isActive = true
        }
    }

    private fun registerReceiver() {
        receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                handleAction(intent?.action ?: return)
            }
        }
        val filter = IntentFilter().apply {
            addAction(ACTION_PREV)
            addAction(ACTION_PLAY_PAUSE)
            addAction(ACTION_NEXT)
            addAction(ACTION_TOGGLE_DESKTOP_LYRIC)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(receiver, filter)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "音乐播放",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "音乐播放控制"
                setShowBadge(false)
                lockscreenVisibility = NotificationCompat.VISIBILITY_PUBLIC
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun showNotification(
        title: String,
        artist: String,
        artUrl: String?,
        isPlaying: Boolean,
        position: Long,
        duration: Long,
        desktopLyricEnabled: Boolean = false
    ) {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val prevIntent = PendingIntent.getService(
            this, 1, Intent(this, AudioPlaybackService::class.java).apply { action = ACTION_PREV },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val playPauseIntent = PendingIntent.getService(
            this, 2, Intent(this, AudioPlaybackService::class.java).apply { action = ACTION_PLAY_PAUSE },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val nextIntent = PendingIntent.getService(
            this, 3, Intent(this, AudioPlaybackService::class.java).apply { action = ACTION_NEXT },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        // 桌面歌词开关：通知栏按钮 → 调 dart 端 toggleDesktopLyric
        val toggleLyricIntent = PendingIntent.getService(
            this, 4, Intent(this, AudioPlaybackService::class.java).apply { action = ACTION_TOGGLE_DESKTOP_LYRIC },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val playPauseIcon = if (isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play
        val lyricIcon = createWordIcon(desktopLyricEnabled)

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(title)
            .setContentText(artist)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .addAction(android.R.drawable.ic_media_previous, "上一首", prevIntent)
            .addAction(playPauseIcon, if (isPlaying) "暂停" else "播放", playPauseIntent)
            .addAction(android.R.drawable.ic_media_next, "下一首", nextIntent)
            .addAction(
                NotificationCompat.Action.Builder(
                    IconCompat.createWithBitmap(lyricIcon),
                    "桌面歌词",
                    toggleLyricIntent
                ).build()
            )
            .setLargeIcon(BitmapFactory.decodeResource(resources, android.R.drawable.ic_menu_myplaces))
            .setStyle(
                androidx.media.app.NotificationCompat.MediaStyle()
                    .setMediaSession(mediaSession?.sessionToken)
                    .setShowActionsInCompactView(0, 1, 2, 3)
            )

        if (!artUrl.isNullOrEmpty()) {
            Thread {
                try {
                    val bitmap = BitmapFactory.decodeStream(java.net.URL(artUrl).openStream())
                    if (bitmap != null) builder.setLargeIcon(bitmap)
                } catch (_: Exception) {}
                startForeground(NOTIFICATION_ID, builder.build())
            }.start()
        } else {
            startForeground(NOTIFICATION_ID, builder.build())
        }

        mediaSession?.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setState(
                    if (isPlaying) PlaybackStateCompat.STATE_PLAYING else PlaybackStateCompat.STATE_PAUSED,
                    position, 1f
                )
                .setActions(
                    PlaybackStateCompat.ACTION_PLAY or
                            PlaybackStateCompat.ACTION_PAUSE or
                            PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
                            PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS or
                            PlaybackStateCompat.ACTION_STOP or
                            PlaybackStateCompat.ACTION_SEEK_TO
                )
                .build()
        )

        mediaSession?.setMetadata(
            MediaMetadataCompat.Builder()
                .putString(MediaMetadataCompat.METADATA_KEY_TITLE, title)
                .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, artist)
                .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, duration)
                .build()
        )
    }

    override fun onDestroy() {
        receiver?.let {
            try {
                unregisterReceiver(it)
            } catch (_: Exception) {}
        }
        mediaSession?.release()
        releaseWakeLock()
        super.onDestroy()
    }

    /** 生成带“词”字的通知栏图标 Bitmap */
    private fun createWordIcon(enabled: Boolean): Bitmap {
        val size = (resources.displayMetrics.density * 24).toInt()
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = if (enabled) 0xFF00E5FF.toInt() else 0xFFCCCCCC.toInt()
            textSize = size * 0.55f
            typeface = Typeface.DEFAULT_BOLD
            textAlign = Paint.Align.CENTER
        }
        val x = size / 2f
        val y = size / 2f - (paint.descent() + paint.ascent()) / 2f
        canvas.drawText("词", x, y, paint)
        return bitmap
    }
}
