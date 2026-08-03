package com.md3music.md3music

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.support.v4.media.session.MediaSessionCompat
import android.view.WindowManager
import android.support.v4.media.session.PlaybackStateCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import com.md3music.md3music.AudioPlaybackService
import com.md3music.md3music.FloatingLyricService
import io.github.proify.lyricon.lyric.model.Song
import java.io.File

class MainActivity : FlutterActivity() {
    private val FLOATING_CHANNEL = "com.md3music.md3music/floating_lyric"
    private val FOLDER_PICKER_CHANNEL = "com.md3music.md3music/folder_picker"
    private val FONT_PICKER_CHANNEL = "com.md3music.md3music/font_picker"
    private val MEDIA_STORE_CHANNEL = "com.md3music.md3music/media_store"
    private val HOME_WIDGET_CHANNEL = "com.md3music.md3music/home_widget"
    private var pendingDesktopLyricAction: String? = null
    private var folderPickerResult: MethodChannel.Result? = null
    private var fontPickerResult: MethodChannel.Result? = null

    companion object {
        private const val FOLDER_PICKER_REQUEST_CODE = 9999
        private const val FONT_PICKER_REQUEST_CODE = 10000

        // 静态引用：让 Service 也能调用 MethodChannel（无 FlutterEngine 缓存时走这里）
        private var cachedEngine: FlutterEngine? = null
        private var cachedChannel: MethodChannel? = null
        // KugouApiService 单例引用，便于 Activity onDestroy / onTrimMemory 时确定性关停
        @Volatile private var kugouApiService: KugouApiService? = null

        fun setKugouApiService(service: KugouApiService?) {
            kugouApiService = service
        }

        /** Activity 销毁或被系统回收时调用，尽力通知本地 API 服务器停止监听 */
        fun shutdownNodeJs() {
            try {
                kugouApiService?.stopServer()
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

        // 注册 MetadataWriterPlugin：处理下载完成后嵌入元数据（标题/艺术家/专辑/封面/歌词）
        MetadataWriterPlugin().register(flutterEngine)

        // 注册均衡器插件：Android 原生 Equalizer，绑定 just_audio 的 audio session ID
        EqualizerPlugin().register(flutterEngine)

        // 初始化 Node.js 本地 API 服务器
        android.util.Log.d("MainActivity", "Initializing KugouApiService...")
        val apiSvc = KugouApiService(this, flutterEngine)
        setKugouApiService(apiSvc)
        android.util.Log.d("MainActivity", "KugouApiService initialized")

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
                        putExtra(AudioPlaybackService.EXTRA_FALLBACK_FILE_PATH, call.argument<String>("fallbackFilePath"))
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
                // 蓝牙歌词：更新当前歌词文本（title→歌词，artist→「作者 - 标题」由原生端处理）
                "updateBluetoothLyric" -> {
                    val intent = Intent(this, AudioPlaybackService::class.java).apply {
                        action = AudioPlaybackService.ACTION_UPDATE_BT_LYRIC
                        putExtra(
                            AudioPlaybackService.EXTRA_BT_LYRIC_TEXT,
                            call.argument<String>("lyric") ?: ""
                        )
                    }
                    startService(intent)
                    result.success(true)
                }
                // 蓝牙歌词：开关切换
                "setBluetoothLyricEnabled" -> {
                    val intent = Intent(this, AudioPlaybackService::class.java).apply {
                        action = AudioPlaybackService.ACTION_SET_BT_LYRIC_ENABLED
                        putExtra(
                            AudioPlaybackService.EXTRA_BT_LYRIC_ENABLED,
                            call.argument<Boolean>("enabled") ?: false
                        )
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
                        // SDK 0.1.70+ 已原生支持 setDisplayRoma，直接调用
                        provider?.player?.setDisplayRoma(enabled)
                        result.success(true)
                    } catch (_: Exception) {
                        // 兜底：反射调用兼容旧版 SDK
                        try {
                            val method = provider?.player?.javaClass?.getMethod("setDisplayRoma", Boolean::class.java)
                            method?.invoke(provider?.player, enabled)
                            result.success(true)
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        // 注册文件夹选择器 MethodChannel
        val folderPickerChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FOLDER_PICKER_CHANNEL
        )
        folderPickerChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickFolder" -> {
                    folderPickerResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                    }
                    startActivityForResult(intent, FOLDER_PICKER_REQUEST_CODE)
                }
                "getPersistedUriPermission" -> {
                    val treeUri = call.argument<String>("uri")
                    if (treeUri != null) {
                        try {
                            val uri = Uri.parse(treeUri)
                            contentResolver.takePersistableUriPermission(
                                uri,
                                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("PERMISSION_ERROR", e.message, null)
                        }
                    } else {
                        result.error("INVALID_URI", "URI is null", null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // 注册字体文件选择器 MethodChannel
        // 用 ACTION_OPEN_DOCUMENT 打开系统文件选择器，过滤 TTF/OTF 文件
        // 选中后原生端把 content URI 流拷贝到 filesDir/fonts/user_custom.ttf
        // 返回真实路径给 Dart 端用 FontLoader 加载
        val fontPickerChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FONT_PICKER_CHANNEL
        )
        fontPickerChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickFontFile" -> {
                    fontPickerResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        // 主 MIME：font/ttf；EXTRA_MIME_TYPES 兼容 OTF 与未注册 MIME
                        type = "font/ttf"
                        putExtra(
                            Intent.EXTRA_MIME_TYPES,
                            arrayOf(
                                "font/ttf",
                                "font/otf",
                                "font/sfnt",
                                "application/x-font-ttf",
                                "application/x-font-otf",
                                "application/x-font-truetype",
                                "application/octet-stream"
                            )
                        )
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    startActivityForResult(intent, FONT_PICKER_REQUEST_CODE)
                }
                else -> result.notImplemented()
            }
        }

        // 注册 MediaStore 扫描器 MethodChannel
        // Android 11+ 沙箱模式下，通过 MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        // 可以读取系统已索引的所有音频（含网易云/QQ 音乐/酷狗等通过 MediaStore 公开的部分）。
        val mediaStoreChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MEDIA_STORE_CHANNEL
        )
        mediaStoreChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getSdkVersion" -> {
                    result.success(Build.VERSION.SDK_INT)
                }
                "queryAudioFiles" -> {
                    try {
                        // MediaStore 查询是同步阻塞的，在子线程执行避免 ANR
                        Thread {
                            try {
                                val files = MediaStoreScanner.queryAudioFiles(this)
                                runOnUiThread { result.success(files) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error("QUERY_ERROR", e.message, null)
                                }
                            }
                        }.start()
                    } catch (e: Exception) {
                        result.error("QUERY_ERROR", e.message, null)
                    }
                }
                "resolveLocalPath" -> {
                    // 把 content:// URI 解析为真实文件路径（just_audio 可播放）
                    val uriStr = call.argument<String>("uri")
                    if (uriStr == null) {
                        result.error("INVALID_URI", "uri is null", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        try {
                            val path = MediaStoreScanner.resolveLocalPath(this, uriStr)
                            runOnUiThread { result.success(path) }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error("RESOLVE_ERROR", e.message, null)
                            }
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }

        // 注册桌面小组件 MethodChannel：Flutter 侧推送播放状态到 AppWidget
        val homeWidgetChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            HOME_WIDGET_CHANNEL
        )
        homeWidgetChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "updateWidget" -> {
                    val title = call.argument<String>("title") ?: ""
                    val artist = call.argument<String>("artist") ?: ""
                    val isPlaying = call.argument<Boolean>("isPlaying") ?: false
                    val position = call.argument<Number>("position")?.toLong() ?: 0L
                    val duration = call.argument<Number>("duration")?.toLong() ?: 0L
                    MusicWidgetProvider.updateAllWidgets(
                        this, title, artist, isPlaying, position, duration
                    )
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // 注册屏幕常亮 MethodChannel：Dart 端 WakelockService 调用，开关 FLAG_KEEP_SCREEN_ON
        val wakelockChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.md3music.md3music/wakelock"
        )
        wakelockChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setKeepScreenOn" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    if (on) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == FOLDER_PICKER_REQUEST_CODE) {
            if (resultCode == RESULT_OK && data?.data != null) {
                val treeUri = data.data!!
                // 持久化 URI 权限
                try {
                    contentResolver.takePersistableUriPermission(
                        treeUri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    )
                } catch (_: Exception) {}
                folderPickerResult?.success(treeUri.toString())
            } else {
                folderPickerResult?.success(null)
            }
            folderPickerResult = null
        } else if (requestCode == FONT_PICKER_REQUEST_CODE) {
            if (resultCode == RESULT_OK && data?.data != null) {
                val uri = data.data!!
                // 后台线程：把 content URI 流拷贝到 filesDir/fonts/user_custom.ttf
                // 拷贝成功后在主线程返回真实路径给 Flutter
                Thread {
                    try {
                        val targetDir = File(filesDir, "fonts").apply { mkdirs() }
                        val targetFile = File(targetDir, "user_custom.ttf")
                        contentResolver.openInputStream(uri).use { input ->
                            targetFile.outputStream().use { output ->
                                input?.copyTo(output)
                            }
                        }
                        // 关键：success 与清空 fontPickerResult 必须在同一个主线程任务里原子完成
                        // 否则子线程的 fontPickerResult = null 会在主线程处理 success 之前执行，
                        // 导致 ?.success(...) 被空安全调用跳过，Dart 端 invokeMethod 永远收不到回调
                        runOnUiThread {
                            fontPickerResult?.success(targetFile.absolutePath)
                            fontPickerResult = null
                        }
                    } catch (e: Exception) {
                        runOnUiThread {
                            fontPickerResult?.error("COPY_FAILED", e.message, null)
                            fontPickerResult = null
                        }
                    }
                }.start()
            } else {
                fontPickerResult?.success(null)
                fontPickerResult = null
            }
        }
    }

    override fun onDestroy() {
        // Activity 销毁（含应用从最近任务划掉时系统先回调 onDestroy 再杀进程）
        // 同步通知 Rust 服务器停止监听，释放端口
        shutdownNodeJs()
        cachedEngine = null
        cachedChannel = null
        super.onDestroy()
    }
}
