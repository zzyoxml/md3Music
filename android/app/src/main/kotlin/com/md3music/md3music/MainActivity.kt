package com.md3music.md3music

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import com.md3music.md3music.AudioPlaybackService
import com.md3music.md3music.FloatingLyricService
import io.github.proify.lyricon.lyric.model.Song

class MainActivity : FlutterActivity() {
    private val FLOATING_CHANNEL = "com.md3music.md3music/floating_lyric"
    private var pendingDesktopLyricAction: String? = null

    companion object {
        // 静态引用：让 Service 也能调用 MethodChannel（无 FlutterEngine 缓存时走这里）
        private var cachedEngine: FlutterEngine? = null
        private var cachedChannel: MethodChannel? = null
        // NodeJsService 单例引用，便于 Activity onDestroy / onTrimMemory 时确定性关停
        @Volatile private var nodeJsService: NodeJsService? = null

        fun setNodeJsService(service: NodeJsService?) {
            nodeJsService = service
        }

        /** Activity 销毁或被系统回收时调用，尽力通知 Node.js 停止事件循环 */
        fun shutdownNodeJs() {
            try {
                nodeJsService?.stopServer()
            } catch (_: Exception) {
                // 进程即将销毁，吞掉异常
            }
        }

        fun sendDesktopLyricAction(action: String) {
            cachedChannel?.invokeMethod("desktopLyricAction", action)
        }

        fun sendDesktopLyricConfigChanged(config: Map<String, Any?>) {
            cachedChannel?.invokeMethod("desktopLyricConfigChanged", config)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 缓存引擎：Service 端没有 FlutterEngine 时（app 进程被回收场景），能复用
        FlutterEngineCache.getInstance().put("md3music_engine", flutterEngine)
        cachedEngine = flutterEngine
        cachedChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FLOATING_CHANNEL)

        // 将 FlutterEngine 传递给 AudioPlaybackService
        AudioPlaybackService.setFlutterEngine(flutterEngine)

        // 初始化 Node.js 本地 API 服务器
        android.util.Log.d("MainActivity", "Initializing NodeJsService...")
        val nodeSvc = NodeJsService(this, flutterEngine)
        setNodeJsService(nodeSvc)
        android.util.Log.d("MainActivity", "NodeJsService initialized")

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FLOATING_CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startFloatingLyric" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
                        val intent = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName"))
                        startActivity(intent)
                        result.error("PERMISSION_DENIED", "需要悬浮窗权限", null)
                    } else {
                        val intent = Intent(this, FloatingLyricService::class.java).apply {
                            action = FloatingLyricService.ACTION_UPDATE_LYRIC
                            putExtra(FloatingLyricService.EXTRA_LYRIC, call.argument<String>("lyric") ?: "")
                            putExtra(FloatingLyricService.EXTRA_TITLE, call.argument<String>("title") ?: "")
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
                        result.success(true)
                    }
                }
                "updateLyric" -> {
                    val intent = Intent(this, FloatingLyricService::class.java).apply {
                        action = FloatingLyricService.ACTION_UPDATE_LYRIC
                        putExtra(FloatingLyricService.EXTRA_LYRIC, call.argument<String>("lyric") ?: "")
                        putExtra(FloatingLyricService.EXTRA_NEXT_LYRIC, call.argument<String>("nextLyric") ?: "")
                        putExtra(FloatingLyricService.EXTRA_SUNG_CHAR_COUNT, call.argument<Int>("sungCharCount") ?: -1)
                    }
                    startService(intent)
                    result.success(true)
                }
                "updateTitle" -> {
                    val intent = Intent(this, FloatingLyricService::class.java).apply {
                        action = FloatingLyricService.ACTION_UPDATE_TITLE
                        putExtra(FloatingLyricService.EXTRA_TITLE, call.argument<String>("title") ?: "")
                    }
                    startService(intent)
                    result.success(true)
                }
                "updateProgress" -> {
                    val intent = Intent(this, FloatingLyricService::class.java).apply {
                        action = FloatingLyricService.ACTION_UPDATE_PROGRESS
                        putExtra(FloatingLyricService.EXTRA_POSITION, (call.argument<Number>("position")?.toLong() ?: 0L))
                        putExtra(FloatingLyricService.EXTRA_DURATION, (call.argument<Number>("duration")?.toLong() ?: 0L))
                    }
                    startService(intent)
                    result.success(true)
                }
                "stopFloatingLyric" -> {
                    val intent = Intent(this, FloatingLyricService::class.java).apply { action = FloatingLyricService.ACTION_STOP }
                    startService(intent)
                    result.success(true)
                }
                "hasOverlayPermission" -> {
                    result.success(if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) Settings.canDrawOverlays(this) else true)
                }
                "setDesktopLyricConfig" -> {
                    val intent = Intent(this, FloatingLyricService::class.java).apply {
                        action = FloatingLyricService.ACTION_SET_CONFIG
                        call.argument<Double>(FloatingLyricService.EXTRA_FONT_SIZE)?.let {
                            putExtra(FloatingLyricService.EXTRA_FONT_SIZE, it.toFloat())
                        }
                        call.argument<Boolean>(FloatingLyricService.EXTRA_DOUBLE_LINE)?.let {
                            putExtra(FloatingLyricService.EXTRA_DOUBLE_LINE, it)
                        }
                        call.argument<Int>(FloatingLyricService.EXTRA_OPACITY)?.let {
                            putExtra(FloatingLyricService.EXTRA_OPACITY, it)
                        }
                        call.argument<Boolean>(FloatingLyricService.EXTRA_LOCKED)?.let {
                            putExtra(FloatingLyricService.EXTRA_LOCKED, it)
                        }
                        call.argument<Int>(FloatingLyricService.EXTRA_GRADIENT_START)?.let {
                            putExtra(FloatingLyricService.EXTRA_GRADIENT_START, it)
                        }
                        call.argument<Int>(FloatingLyricService.EXTRA_GRADIENT_END)?.let {
                            putExtra(FloatingLyricService.EXTRA_GRADIENT_END, it)
                        }
                        call.argument<Int>(FloatingLyricService.EXTRA_UNPLAYED_COLOR)?.let {
                            putExtra(FloatingLyricService.EXTRA_UNPLAYED_COLOR, it)
                        }
                    }
                    startService(intent)
                    result.success(true)
                }
                "setPlaying" -> {
                    val intent = Intent(this, FloatingLyricService::class.java).apply {
                        action = FloatingLyricService.ACTION_SET_PLAYING
                        putExtra(
                            FloatingLyricService.EXTRA_IS_PLAYING,
                            call.argument<Boolean>(FloatingLyricService.EXTRA_IS_PLAYING) ?: false
                        )
                    }
                    startService(intent)
                    result.success(true)
                }
                "seekTo" -> {
                    // seekTo 由 MediaSession 直接调用，无需额外处理
                    result.success(true)
                }
                "showNotification", "updateNotification" -> {
                    val intent = Intent(this, AudioPlaybackService::class.java).apply {
                        putExtra(AudioPlaybackService.EXTRA_TITLE, call.argument<String>("title") ?: "")
                        putExtra(AudioPlaybackService.EXTRA_ARTIST, call.argument<String>("artist") ?: "")
                        putExtra(AudioPlaybackService.EXTRA_ART_URL, call.argument<String>("artUrl"))
                        putExtra(AudioPlaybackService.EXTRA_IS_PLAYING, call.argument<Boolean>("isPlaying") ?: false)
                        putExtra(AudioPlaybackService.EXTRA_POSITION, call.argument<Number>("position")?.toLong() ?: 0L)
                        putExtra(AudioPlaybackService.EXTRA_DURATION, call.argument<Number>("duration")?.toLong() ?: 0L)
                        putExtra(
                            AudioPlaybackService.EXTRA_DESKTOP_LYRIC_ENABLED,
                            call.argument<Boolean>(AudioPlaybackService.EXTRA_DESKTOP_LYRIC_ENABLED) ?: false
                        )
                        putExtra(
                            AudioPlaybackService.EXTRA_IS_FAVORITED,
                            call.argument<Boolean>(AudioPlaybackService.EXTRA_IS_FAVORITED) ?: false
                        )
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(true)
                }
                "hideNotification" -> {
                    val intent = Intent(this, AudioPlaybackService::class.java).apply {
                        action = AudioPlaybackService.ACTION_STOP
                    }
                    startService(intent)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // 注册 Lyricon Provider MethodChannel，让 Dart 端能控制 Lyricon 播放器
        val lyriconChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.md3music.md3music/lyricon"
        )
        AudioPlaybackService.setLyriconChannel(lyriconChannel)
        lyriconChannel.setMethodCallHandler { call, result ->
            val provider = AudioPlaybackService.getLyriconProvider()
            when (call.method) {
                "setEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    try {
                        if (enabled) provider?.register() else provider?.unregister()
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                "setSong" -> {
                    val arg = call.argument<Map<String, Any?>>("song")
                    if (arg == null) {
                        try {
                            // SDK 的 setSong 不接受 null，传一个空 Song 表示清空
                            provider?.player?.setSong(Song())
                            result.success(true)
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    } else {
                        try {
                            val song = AudioPlaybackService.buildLyriconSong(arg)
                            provider?.player?.setSong(song)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("BUILD_SONG_FAILED", e.message, null)
                        }
                    }
                }
                "sendText" -> {
                    val text = call.argument<String>("text")
                    try {
                        provider?.player?.sendText(text)
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                "setPosition" -> {
                    val pos = call.argument<Number>("positionMs")?.toLong() ?: 0L
                    try {
                        provider?.player?.setPosition(pos)
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                "setPlaybackState" -> {
                    val state = call.argument<Number>("state")?.toInt()
                        ?: PlaybackStateCompat.STATE_NONE
                    val pos = call.argument<Number>("position")?.toLong() ?: 0L
                    // SDK 的 setPlaybackState 接受 Boolean，从 PlaybackStateCompat 状态码推导 isPlaying
                    val isPlaying = state == PlaybackStateCompat.STATE_PLAYING
                    try {
                        // 位置通过 setPosition 同步（原本打包在 PlaybackStateCompat 中）
                        provider?.player?.setPosition(pos)
                        provider?.player?.setPlaybackState(isPlaying)
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                "seekTo" -> {
                    val pos = call.argument<Number>("positionMs")?.toLong() ?: 0L
                    try {
                        provider?.player?.seekTo(pos)
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                "setDisplayTranslation" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    try {
                        provider?.player?.setDisplayTranslation(enabled)
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                "setDisplayRoma" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    try {
                        provider?.player?.setDisplayRoma(enabled)
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // 注册元数据写入插件（下载完成后嵌入标题/艺术家/专辑/封面/歌词）
        MetadataWriterPlugin().register(flutterEngine)
    }

    override fun onDestroy() {
        // Activity 销毁（含应用从最近任务划掉时系统先回调 onDestroy 再杀进程）
        // 同步通知 Node.js 停止 libuv 事件循环，释放 8080 端口
        shutdownNodeJs()
        cachedEngine = null
        cachedChannel = null
        super.onDestroy()
    }
}
