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
import android.os.Handler
import android.os.Looper
import android.graphics.Typeface
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.app.NotificationCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.github.proify.lyricon.provider.ConnectionListener
import io.github.proify.lyricon.provider.LyriconFactory
import io.github.proify.lyricon.provider.LyriconProvider
import io.github.proify.lyricon.lyric.model.LyricWord
import io.github.proify.lyricon.lyric.model.RichLyricLine
import io.github.proify.lyricon.lyric.model.Song

class AudioPlaybackService : Service() {
    companion object {
        const val CHANNEL_ID = "md3music_audio_playback"
        const val NOTIFICATION_ID = 1002
        const val ACTION_PREV = "com.md3music.md3music.ACTION_PREV"
        const val ACTION_PLAY_PAUSE = "com.md3music.md3music.ACTION_PLAY_PAUSE"
        const val ACTION_NEXT = "com.md3music.md3music.ACTION_NEXT"
        const val ACTION_STOP = "com.md3music.md3music.ACTION_STOP"
        const val ACTION_TOGGLE_DESKTOP_LYRIC = "com.md3music.md3music.ACTION_TOGGLE_DESKTOP_LYRIC"
        const val ACTION_TOGGLE_FAVORITE = "com.md3music.md3music.ACTION_TOGGLE_FAVORITE"
        // 蓝牙歌词：通过修改 MediaSession 元数据模拟 AVRCP 歌词显示
        const val ACTION_UPDATE_BT_LYRIC = "com.md3music.md3music.ACTION_UPDATE_BT_LYRIC"
        const val ACTION_SET_BT_LYRIC_ENABLED = "com.md3music.md3music.ACTION_SET_BT_LYRIC_ENABLED"
        const val EXTRA_TITLE = "title"
        const val EXTRA_ARTIST = "artist"
        const val EXTRA_ART_URL = "artUrl"
        const val EXTRA_FALLBACK_FILE_PATH = "fallbackFilePath"
        const val EXTRA_IS_PLAYING = "isPlaying"
        const val EXTRA_POSITION = "position"
        const val EXTRA_DURATION = "duration"
        const val EXTRA_DESKTOP_LYRIC_ENABLED = "desktopLyricEnabled"
        const val EXTRA_IS_FAVORITED = "isFavorited"
        const val EXTRA_BT_LYRIC_TEXT = "btLyricText"
        const val EXTRA_BT_LYRIC_ENABLED = "btLyricEnabled"
        // 桌面小组件按钮动作（由 MusicWidgetProvider 转发）
        const val ACTION_WIDGET_PLAY_PAUSE = "com.md3music.md3music.ACTION_WIDGET_PLAY_PAUSE"
        const val ACTION_WIDGET_NEXT = "com.md3music.md3music.ACTION_WIDGET_NEXT"

        // 静态变量用于跨组件传递 FlutterEngine
        private var staticFlutterEngine: FlutterEngine? = null
        private var wakeLock: PowerManager.WakeLock? = null

        fun setFlutterEngine(engine: FlutterEngine) {
            staticFlutterEngine = engine
        }

        /** 检查是否有可用的 FlutterEngine（供 MusicWidgetProvider 判断是否需要拉起 app） */
        fun hasFlutterEngine(): Boolean {
            return staticFlutterEngine != null
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

        // Lyricon Provider 单例引用（companion 持有，方便 MainActivity channel 直接访问）
        @Volatile
        private var lyriconProvider: LyriconProvider? = null
        private var lyriconChannel: MethodChannel? = null

        fun setLyriconChannel(channel: MethodChannel?) {
            lyriconChannel = channel
        }

        /** 在主线程安全调用 lyriconChannel.invokeMethod，避免 SDK 回调在后台线程触发崩溃 */
        private fun invokeLyriconChannelOnMain(method: String, argument: Any?) {
            val channel = lyriconChannel ?: return
            val handler = Handler(Looper.getMainLooper())
            if (Looper.myLooper() == Looper.getMainLooper()) {
                channel.invokeMethod(method, argument)
            } else {
                handler.post { channel.invokeMethod(method, argument) }
            }
        }

        fun getLyriconProvider(): LyriconProvider? = lyriconProvider

        /** 由 MainActivity 的 lyricon channel handler 调用，把 Dart 端 Map 转成 SDK 的 Song */
        fun buildLyriconSong(arg: Map<String, Any?>): Song {
            @Suppress("UNCHECKED_CAST")
            val lyricsRaw = arg["lyrics"] as? List<Map<String, Any?>> ?: emptyList()
            val lyrics = lyricsRaw.map { line ->
                @Suppress("UNCHECKED_CAST")
                val wordsRaw = line["words"] as? List<Map<String, Any?>> ?: emptyList()
                RichLyricLine(
                    begin = (line["begin"] as? Number)?.toLong() ?: 0L,
                    end = (line["end"] as? Number)?.toLong() ?: 0L,
                    text = line["text"] as? String ?: "",
                    translation = line["translation"] as? String,
                    roma = line["roma"] as? String,
                    words = wordsRaw.map { w ->
                        LyricWord(
                            text = w["text"] as? String ?: "",
                            begin = (w["begin"] as? Number)?.toLong() ?: 0L,
                            end = (w["end"] as? Number)?.toLong() ?: 0L
                        )
                    }
                )
            }
            val song = Song(
                id = arg["id"] as? String ?: "",
                name = arg["name"] as? String ?: "",
                artist = arg["artist"] as? String ?: "",
                duration = (arg["duration"] as? Number)?.toLong() ?: 0L,
                lyrics = lyrics
            )
            // 调试日志：让用户用 adb logcat -s LyriconDebug 验证实际数据
            // 关注点：lyrics.size 是否为 0；首行 begin/end 是否合法（begin < end）
            val first = lyrics.firstOrNull()
            val withTranslation = lyrics.count { !it.translation.isNullOrEmpty() }
            val withRoma = lyrics.count { !it.roma.isNullOrEmpty() }
            android.util.Log.d("LyriconDebug",
                "buildLyriconSong: name='${song.name}', artist='${song.artist}', " +
                "duration=${song.duration}, lyrics.size=${lyrics.size}, " +
                "withTranslation=$withTranslation, withRoma=$withRoma, " +
                "first=${first?.let { "begin=${it.begin}, end=${it.end}, text='${it.text}', translation='${it.translation}', roma='${it.roma}', words=${it.words?.size ?: 0}" }}"
            )
            return song
        }
    }

    private var mediaSession: MediaSessionCompat? = null
    private var notificationManager: NotificationManager? = null
    private var receiver: BroadcastReceiver? = null
    private var flutterEngine: FlutterEngine? = null

    // 蓝牙歌词状态：原生端缓存原始元数据，根据开关和当前歌词计算最终显示值
    private var bluetoothLyricEnabled = false
    private var currentBtLyricText = ""
    private var originalTitle = ""
    private var originalArtist = ""
    private var lastArtBitmap: Bitmap? = null
    private var lastArtUrl: String? = null
    // 缓存最近一次通知构建所需的播放状态，供 refreshMetadata 复用
    private var lastIsPlaying = false
    private var lastDesktopLyricEnabled = false
    private var lastIsFavorited = false
    private var lastDuration = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        notificationManager = getSystemService(NotificationManager::class.java)
        initMediaSession()
        registerReceiver()
        acquireWakeLock(this)

        // 初始化 Lyricon Provider（用 try-catch 包裹，防止 SDK 在低版本 Android 抛异常）
        lyriconProvider = try {
            LyriconFactory.createProvider(this).apply {
                autoSync = true
                try {
                    // SDK 的 ConnectionListener 是 interface，必须用 object 表达式实现
                    service.addConnectionListener(object : ConnectionListener {
                        override fun onConnected(provider: LyriconProvider) {
                            invokeLyriconChannelOnMain("onConnectionStateChanged", "connected")
                        }
                        override fun onReconnected(provider: LyriconProvider) {
                            invokeLyriconChannelOnMain("onConnectionStateChanged", "reconnected")
                        }
                        override fun onDisconnected(provider: LyriconProvider) {
                            invokeLyriconChannelOnMain("onConnectionStateChanged", "disconnected")
                        }
                        override fun onConnectTimeout(provider: LyriconProvider) {
                            invokeLyriconChannelOnMain("onConnectionStateChanged", "timeout")
                        }
                    })
                } catch (_: Exception) {}
            }
        } catch (_: Exception) {
            null
        }

        // 自动恢复用户上次保存的 Lyricon 启用状态：
        // 冷启动后用户没播放前 provider 不存在，setEnabled 静默失败；
        // 这里在 Service onCreate（首次 startForegroundService 即首次播放时）
        // 创建 provider 后立即读 SharedPreferences 恢复 enabled，并通知 Dart
        // 端通过 auto_restored 事件触发重推当前歌曲。
        restoreLyriconStateIfNeeded()
        // 恢复蓝牙歌词开关：避免冷启动后开关丢失（Flutter 端也会再推一次，幂等）
        restoreBluetoothLyricState()
    }

    /// 从 SharedPreferences 恢复蓝牙歌词开关状态。
    /// Flutter 端 key 为 settings_bluetooth_lyric_enabled，原生端读取需加 flutter. 前缀。
    private fun restoreBluetoothLyricState() {
        try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            bluetoothLyricEnabled = prefs.getBoolean("flutter.settings_bluetooth_lyric_enabled", false)
        } catch (_: Exception) {}
    }

    /// 从 SharedPreferences 读取 flutter. 前缀的开关状态并恢复。
    /// Flutter SharedPreferences 在 Android 端存储于 FlutterSharedPreferences.xml，
    /// key 带 `flutter.` 前缀。
    private fun restoreLyriconStateIfNeeded() {
        val provider = lyriconProvider ?: run {
            android.util.Log.w("LyriconDebug", "restoreLyriconStateIfNeeded: provider is null")
            return
        }
        try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val enabled = prefs.getBoolean("flutter.lyricon_enabled", false)
            val displayTranslation = prefs.getBoolean("flutter.lyricon_display_translation", true)
            val displayRoma = prefs.getBoolean("flutter.lyricon_display_roma", false)
            android.util.Log.d("LyriconDebug",
                "restoreLyriconStateIfNeeded: enabled=$enabled, displayTranslation=$displayTranslation, " +
                "displayRoma=$displayRoma, channelSet=${lyriconChannel != null}")
            if (enabled) {
                provider.register()
                android.util.Log.d("LyriconDebug", "restoreLyriconStateIfNeeded: provider.register() done")
                // 通知 Dart 端：Provider 已自动恢复 enabled 状态
                // 让 Dart 端同步 _state 并重推当前歌曲
                invokeLyriconChannelOnMain("onConnectionStateChanged", "auto_restored")
            }
            // 同步恢复 displayTranslation / displayRoma 偏好
            try { provider.player.setDisplayTranslation(displayTranslation) } catch (e: Exception) {
                android.util.Log.w("LyriconDebug", "setDisplayTranslation failed: ${e.message}")
            }
            try { provider.player.setDisplayRoma(displayRoma) } catch (e: Exception) {
                android.util.Log.w("LyriconDebug", "setDisplayRoma failed: ${e.message}")
            }
        } catch (e: Exception) {
            android.util.Log.e("LyriconDebug", "restoreLyriconStateIfNeeded failed", e)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                releaseWakeLock()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_PREV, ACTION_PLAY_PAUSE, ACTION_NEXT, ACTION_TOGGLE_DESKTOP_LYRIC, ACTION_TOGGLE_FAVORITE,
            ACTION_WIDGET_PLAY_PAUSE, ACTION_WIDGET_NEXT -> {
                handleAction(intent.action!!)
                return START_STICKY
            }
            ACTION_UPDATE_BT_LYRIC -> {
                currentBtLyricText = intent?.getStringExtra(EXTRA_BT_LYRIC_TEXT) ?: ""
                refreshMetadata()
                return START_STICKY
            }
            ACTION_SET_BT_LYRIC_ENABLED -> {
                bluetoothLyricEnabled = intent?.getBooleanExtra(EXTRA_BT_LYRIC_ENABLED, false) ?: false
                refreshMetadata()
                return START_STICKY
            }
        }

        val title = intent?.getStringExtra(EXTRA_TITLE) ?: ""
        val artist = intent?.getStringExtra(EXTRA_ARTIST) ?: ""
        val artUrl = intent?.getStringExtra(EXTRA_ART_URL)
        val fallbackFilePath = intent?.getStringExtra(EXTRA_FALLBACK_FILE_PATH)
        val isPlaying = intent?.getBooleanExtra(EXTRA_IS_PLAYING, false) ?: false
        val position = intent?.getLongExtra(EXTRA_POSITION, 0L) ?: 0L
        val duration = intent?.getLongExtra(EXTRA_DURATION, 0L) ?: 0L
        val desktopLyricEnabled =
            intent?.getBooleanExtra(EXTRA_DESKTOP_LYRIC_ENABLED, false) ?: false
        val isFavorited =
            intent?.getBooleanExtra(EXTRA_IS_FAVORITED, false) ?: false

        showNotification(title, artist, artUrl, fallbackFilePath, isPlaying, position, duration, desktopLyricEnabled, isFavorited)

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
                ACTION_PLAY_PAUSE, ACTION_WIDGET_PLAY_PAUSE -> "togglePlayPause"
                ACTION_NEXT, ACTION_WIDGET_NEXT -> "next"
                ACTION_TOGGLE_DESKTOP_LYRIC -> "toggleDesktopLyric"
                ACTION_TOGGLE_FAVORITE -> "toggleFavorite"
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
            ACTION_TOGGLE_FAVORITE -> "toggleFavorite"
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
        val sessionIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, sessionIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        mediaSession = MediaSessionCompat(this, "MD3MusicPlayback").apply {
            setFlags(
                MediaSessionCompat.FLAG_HANDLES_MEDIA_BUTTONS or
                        MediaSessionCompat.FLAG_HANDLES_TRANSPORT_CONTROLS
            )
            setSessionActivity(pendingIntent)
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
                override fun onCustomAction(action: String?, extras: android.os.Bundle?) {
                    if (action == ACTION_TOGGLE_DESKTOP_LYRIC) {
                        handleAction(ACTION_TOGGLE_DESKTOP_LYRIC)
                    } else if (action == ACTION_TOGGLE_FAVORITE) {
                        handleAction(ACTION_TOGGLE_FAVORITE)
                    }
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
            addAction(ACTION_TOGGLE_FAVORITE)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(receiver, filter)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            
            // 删除旧渠道（如果存在且配置不正确）- Android 8+ 渠道一旦创建无法修改，必须删除重建
            try {
                val existingChannel = manager.getNotificationChannel(CHANNEL_ID)
                if (existingChannel != null) {
                    // 检查是否需要重建（重要度不是 LOW，或者声音未禁用）
                    if (existingChannel.importance != NotificationManager.IMPORTANCE_LOW ||
                        existingChannel.sound != null) {
                        manager.deleteNotificationChannel(CHANNEL_ID)
                    }
                }
            } catch (_: Exception) {}
            
            // 创建静音通知渠道 - 修复荣耀/vivo 手机通知提示音问题
            val channel = NotificationChannel(
                CHANNEL_ID,
                "音乐播放",
                NotificationManager.IMPORTANCE_LOW  // 使用 LOW 而不是 DEFAULT，减少通知干扰
            ).apply {
                description = "音乐播放控制"
                setShowBadge(false)
                lockscreenVisibility = NotificationCompat.VISIBILITY_PUBLIC
                // 关键修复：禁用声音和震动
                setSound(null, null)
                enableVibration(false)
                // 不在锁屏上显示（可选，根据需求调整）
                // setLockscreenVisibility(Notification.VISIBILITY_PUBLIC)
            }
            manager.createNotificationChannel(channel)
        }
    }

    private fun resizeBitmap(source: Bitmap, maxSize: Int): Bitmap {
        val w = source.width
        val h = source.height
        if (w <= maxSize && h <= maxSize) return source
        val ratio = maxSize.toDouble() / maxOf(w, h)
        return Bitmap.createScaledBitmap(
            source,
            (w * ratio).toInt(),
            (h * ratio).toInt(),
            true
        )
    }

    /// 根据 URI 类型加载封面 Bitmap，支持：
    /// - http(s):// → URL 下载（在线音乐）
    /// - content:// → ContentResolver 加载（MediaStore albumart）
    /// - local://<path> → 提取文件路径，用 MediaMetadataRetriever 读内嵌封面
    /// - file://<path> → 转为文件路径，用 MediaMetadataRetriever 读内嵌封面
    /// - 纯文件路径 → 直接用 MediaMetadataRetriever 读内嵌封面
    /// [fallbackFilePath] 在所有方式失败后作为最终回退
    private fun loadArtworkBitmap(artUri: String, fallbackFilePath: String?): Bitmap? {
        // 1. http(s):// 在线封面
        if (artUri.startsWith("http://") || artUri.startsWith("https://")) {
            return try {
                BitmapFactory.decodeStream(java.net.URL(artUri).openStream())
            } catch (_: Exception) { null }
        }

        // 2. content:// MediaStore albumart
        if (artUri.startsWith("content://")) {
            try {
                val uri = Uri.parse(artUri)
                contentResolver.openInputStream(uri)?.use { input ->
                    return BitmapFactory.decodeStream(input)
                }
            } catch (_: Exception) {}
            // content:// 加载失败，回退到 fallbackFilePath 提取内嵌封面
            if (!fallbackFilePath.isNullOrEmpty()) {
                return extractEmbeddedArtwork(fallbackFilePath)
            }
            return null
        }

        // 3. local://<path> 或 file://<path>：提取文件路径
        val filePath = when {
            artUri.startsWith("local://") -> artUri.substring("local://".length)
            artUri.startsWith("file://") -> {
                val uri = Uri.parse(artUri)
                uri.path ?: artUri.substring("file://".length)
            }
            else -> artUri
        }
        // 边听边存兜底：如果是图片文件（jpg/png/webp），直接 decodeFile；
        // 否则当作音频文件用 MediaMetadataRetriever 读内嵌封面
        val lower = filePath.lowercase()
        if (lower.endsWith(".jpg") || lower.endsWith(".jpeg") ||
            lower.endsWith(".png") || lower.endsWith(".webp")
        ) {
            return try {
                BitmapFactory.decodeFile(filePath)
            } catch (_: Exception) { null }
        }
        return extractEmbeddedArtwork(filePath)
    }

    /// 用 MediaMetadataRetriever 从音频文件中提取内嵌封面图。
    /// 支持真实文件路径、file:// URI 和 content:// URI。
    private fun extractEmbeddedArtwork(filePath: String): Bitmap? {
        return try {
            val retriever = MediaMetadataRetriever()
            if (filePath.startsWith("content://")) {
                // content:// URI 需要 Context 重载
                retriever.setDataSource(this, Uri.parse(filePath))
            } else if (filePath.startsWith("file://")) {
                // file:// URI 转为真实路径
                val path = Uri.parse(filePath).path ?: filePath.substring("file://".length)
                retriever.setDataSource(path)
            } else {
                // 纯文件路径
                retriever.setDataSource(filePath)
            }
            val art = retriever.embeddedPicture
            retriever.release()
            if (art != null) BitmapFactory.decodeByteArray(art, 0, art.size) else null
        } catch (_: Exception) { null }
    }

    private fun showNotification(
        title: String,
        artist: String,
        artUrl: String?,
        fallbackFilePath: String?,
        isPlaying: Boolean,
        position: Long,
        duration: Long,
        desktopLyricEnabled: Boolean = false,
        isFavorited: Boolean = false
    ) {
        // 缓存原始元数据与播放状态，供蓝牙歌词 refreshMetadata 复用
        originalTitle = title
        originalArtist = artist
        lastArtUrl = artUrl
        lastIsPlaying = isPlaying
        lastDesktopLyricEnabled = desktopLyricEnabled
        lastIsFavorited = isFavorited
        lastDuration = duration
        // 计算最终显示值：蓝牙歌词开启且有当前歌词时，title→歌词，artist→「作者 - 标题」
        val displayTitle: String
        val displayArtist: String
        if (bluetoothLyricEnabled && currentBtLyricText.isNotEmpty()) {
            displayTitle = currentBtLyricText
            displayArtist = if (originalArtist.isNotEmpty())
                "$originalArtist - $originalTitle" else originalTitle
        } else {
            displayTitle = originalTitle
            displayArtist = originalArtist
        }

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
        val toggleFavoriteIntent = PendingIntent.getService(
            this, 5, Intent(this, AudioPlaybackService::class.java).apply { action = ACTION_TOGGLE_FAVORITE },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val playPauseIcon = if (isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play
        val lyricIconRes = if (desktopLyricEnabled) R.drawable.ic_lyric_on else R.drawable.ic_lyric_off
        val favoriteIconRes = if (isFavorited) R.drawable.ic_favorite_on else R.drawable.ic_favorite_off

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(displayTitle)
            .setContentText(displayArtist)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setPriority(NotificationCompat.PRIORITY_LOW)  // 降低优先级，配合渠道的 LOW 设置
            .setOnlyAlertOnce(true)  // 关键：确保通知更新时不会触发声音/震动
            .setShowWhen(false)
            .addAction(android.R.drawable.ic_media_previous, "上一首", prevIntent)
            .addAction(playPauseIcon, if (isPlaying) "暂停" else "播放", playPauseIntent)
            .addAction(favoriteIconRes, "收藏", toggleFavoriteIntent)
            .addAction(android.R.drawable.ic_media_next, "下一首", nextIntent)
            .addAction(lyricIconRes, "桌面歌词", toggleLyricIntent)
            .setLargeIcon(BitmapFactory.decodeResource(resources, android.R.drawable.ic_menu_myplaces))
            .setStyle(
                androidx.media.app.NotificationCompat.MediaStyle()
                    .setMediaSession(mediaSession?.sessionToken)
                    .setShowActionsInCompactView(0, 1, 3)
            )

        // 封面加载：支持 http(s):// / content:// / local:// / file:// / 文件路径
        val effectiveArtUrl = artUrl ?: fallbackFilePath
        if (!effectiveArtUrl.isNullOrEmpty()) {
            Thread {
                try {
                    val originalBitmap = loadArtworkBitmap(effectiveArtUrl, fallbackFilePath)
                    if (originalBitmap != null) {
                        // 缓存原始 bitmap 供蓝牙歌词 refreshMetadata 复用，避免重复下载
                        lastArtBitmap = originalBitmap
                        // 同步封面到桌面小组件（与通知栏/MediaSession 一致）
                        MusicWidgetProvider.cachedArtwork = resizeBitmap(originalBitmap, 200)
                        MusicWidgetProvider.notifyArtworkChanged(this@AudioPlaybackService)
                        // 通知 LargeIcon：缩放到 192px（~64dp @ xxhdpi）
                        val iconBitmap = resizeBitmap(originalBitmap, 192)
                        builder.setLargeIcon(iconBitmap)
                        startForeground(NOTIFICATION_ID, builder.build())

                        // MediaSession Metadata：用原始分辨率 bitmap + URI
                        // title/artist 用 display 值（蓝牙歌词开启时为歌词文本）
                        mediaSession?.setMetadata(
                            MediaMetadataCompat.Builder()
                                .putString(MediaMetadataCompat.METADATA_KEY_TITLE, displayTitle)
                                .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, displayArtist)
                                .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, duration)
                                .putBitmap(MediaMetadataCompat.METADATA_KEY_ART, originalBitmap)
                                .putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, originalBitmap)
                                .putString(MediaMetadataCompat.METADATA_KEY_ART_URI, effectiveArtUrl)
                                .build()
                        )
                    } else {
                        startForeground(NOTIFICATION_ID, builder.build())
                    }
                } catch (_: Exception) {
                    startForeground(NOTIFICATION_ID, builder.build())
                }
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
                            PlaybackStateCompat.ACTION_PLAY_PAUSE or
                            PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
                            PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS or
                            PlaybackStateCompat.ACTION_STOP or
                            PlaybackStateCompat.ACTION_SEEK_TO
                )
                .addCustomAction(
                    PlaybackStateCompat.CustomAction.Builder(
                        ACTION_TOGGLE_DESKTOP_LYRIC,
                        "桌面歌词",
                        if (desktopLyricEnabled) R.drawable.ic_lyric_on else R.drawable.ic_lyric_off
                    ).build()
                )
                .addCustomAction(
                    PlaybackStateCompat.CustomAction.Builder(
                        ACTION_TOGGLE_FAVORITE,
                        "收藏",
                        if (isFavorited) R.drawable.ic_favorite_on else R.drawable.ic_favorite_off
                    ).build()
                )
                .build()
        )

        // 同步播放状态到 Lyricon（SDK 的 setPlaybackState 接受 Boolean 重载）
        try {
            lyriconProvider?.player?.setPlaybackState(isPlaying)
        } catch (_: Exception) {}
    }

    /// 蓝牙歌词轻量刷新：歌词行变化或开关切换时，复用缓存的 bitmap 和播放状态
    /// 重建通知和 MediaSession 元数据，不重新下载封面。
    /// 仅在 showNotification 至少被调用过一次后有效（originalTitle 非空判定）。
    private fun refreshMetadata() {
        if (originalTitle.isEmpty() && originalArtist.isEmpty()) return
        val displayTitle: String
        val displayArtist: String
        if (bluetoothLyricEnabled && currentBtLyricText.isNotEmpty()) {
            displayTitle = currentBtLyricText
            displayArtist = if (originalArtist.isNotEmpty())
                "$originalArtist - $originalTitle" else originalTitle
        } else {
            displayTitle = originalTitle
            displayArtist = originalArtist
        }

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
        val toggleLyricIntent = PendingIntent.getService(
            this, 4, Intent(this, AudioPlaybackService::class.java).apply { action = ACTION_TOGGLE_DESKTOP_LYRIC },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val toggleFavoriteIntent = PendingIntent.getService(
            this, 5, Intent(this, AudioPlaybackService::class.java).apply { action = ACTION_TOGGLE_FAVORITE },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val playPauseIcon = if (lastIsPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play
        val lyricIconRes = if (lastDesktopLyricEnabled) R.drawable.ic_lyric_on else R.drawable.ic_lyric_off
        val favoriteIconRes = if (lastIsFavorited) R.drawable.ic_favorite_on else R.drawable.ic_favorite_off

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(displayTitle)
            .setContentText(displayArtist)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .addAction(android.R.drawable.ic_media_previous, "上一首", prevIntent)
            .addAction(playPauseIcon, if (lastIsPlaying) "暂停" else "播放", playPauseIntent)
            .addAction(favoriteIconRes, "收藏", toggleFavoriteIntent)
            .addAction(android.R.drawable.ic_media_next, "下一首", nextIntent)
            .addAction(lyricIconRes, "桌面歌词", toggleLyricIntent)
            .setStyle(
                androidx.media.app.NotificationCompat.MediaStyle()
                    .setMediaSession(mediaSession?.sessionToken)
                    .setShowActionsInCompactView(0, 1, 3)
            )

        // 复用缓存的封面 bitmap（缩放到 192px 作为通知 LargeIcon）
        val cachedBitmap = lastArtBitmap
        if (cachedBitmap != null) {
            builder.setLargeIcon(resizeBitmap(cachedBitmap, 192))
        }
        notificationManager?.notify(NOTIFICATION_ID, builder.build())

        // 更新 MediaSession 元数据（车机 AVRCP 读取此处）
        val metaBuilder = MediaMetadataCompat.Builder()
            .putString(MediaMetadataCompat.METADATA_KEY_TITLE, displayTitle)
            .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, displayArtist)
            .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, lastDuration)
        if (cachedBitmap != null) {
            metaBuilder.putBitmap(MediaMetadataCompat.METADATA_KEY_ART, cachedBitmap)
            metaBuilder.putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, cachedBitmap)
        }
        if (!lastArtUrl.isNullOrEmpty()) {
            metaBuilder.putString(MediaMetadataCompat.METADATA_KEY_ART_URI, lastArtUrl)
        }
        mediaSession?.setMetadata(metaBuilder.build())
    }

    override fun onDestroy() {
        receiver?.let {
            try {
                unregisterReceiver(it)
            } catch (_: Exception) {}
        }
        mediaSession?.release()
        // 释放 Lyricon Provider
        try {
            lyriconProvider?.unregister()
        } catch (_: Exception) {}
        try {
            lyriconProvider?.destroy()
        } catch (_: Exception) {}
        lyriconProvider = null
        releaseWakeLock()
        super.onDestroy()
    }
}
