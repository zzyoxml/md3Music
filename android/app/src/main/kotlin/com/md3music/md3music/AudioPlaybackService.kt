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
import android.os.SystemClock
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import android.util.Log
import androidx.core.app.NotificationCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import com.hchen.superlyricapi.SuperLyricData
import com.hchen.superlyricapi.SuperLyricHelper
import com.hchen.superlyricapi.SuperLyricLine
import com.hchen.superlyricapi.SuperLyricWord
import io.flutter.plugins.GeneratedPluginRegistrant
import io.github.proify.lyricon.provider.ConnectionListener
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
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
        // LyricInfo 歌词转发：通过 MediaSession 元数据 extras.lyricInfo 发布整首歌词
        const val ACTION_UPDATE_LYRIC_INFO = "com.md3music.md3music.ACTION_UPDATE_LYRIC_INFO"
        const val EXTRA_LYRIC_INFO = "lyricInfo"
        // 桌面小组件按钮动作（由 MusicWidgetProvider 转发）
        const val ACTION_WIDGET_PLAY_PAUSE = "com.md3music.md3music.ACTION_WIDGET_PLAY_PAUSE"
        const val ACTION_WIDGET_NEXT = "com.md3music.md3music.ACTION_WIDGET_NEXT"
        // 线控耳机媒体键（由 MediaButtonReceiver 转发，唤醒播放）
        const val ACTION_MEDIA_BUTTON = "com.md3music.md3music.ACTION_MEDIA_BUTTON"
        const val EXTRA_MEDIA_COMMAND = "mediaCommand"

        private const val TAG = "AudioPlaybackService"

        // 静态变量用于跨组件传递 FlutterEngine
        private var staticFlutterEngine: FlutterEngine? = null
        private var wakeLock: PowerManager.WakeLock? = null

        /// 进程被杀后由本服务创建的后台 FlutterEngine 是否已就绪。
        /// Dart 端 PlayerProvider 完成状态恢复后会通过 playerReady 通知置为 true。
        @Volatile
        var playerReadyReceived = false

        /// 当前是否正在播放（供 LockScreenLyricReceiver 判断锁屏时是否拉起歌词界面）。
        @Volatile
        var isNowPlaying = false

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
                // P0: 不再固定 24h 超时。播放期间持有，暂停/停止时由
                // onStartCommand 与 ACTION_STOP 主动释放，避免 CPU 无法休眠耗电
                wakeLock?.acquire()
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

        // —— 词幕（Lyricon）连接重试控制 ——
        // 启动/连接过程中可能因中心服务尚未就绪等原因失败，按预设次数重试；
        // 全部失败后向 Dart 发 connect_failed 事件，由 UI 弹窗提示用户。
        private const val LYRICON_MAX_RETRIES = 3
        private const val LYRICON_RETRY_DELAY_MS = 2000L
        // P0: setMetadata 合并节流窗口：歌词行高频变化时 300ms 内只执行一次刷新
        private const val METADATA_REFRESH_DELAY_MS = 300L
        // P0: 蓝牙歌词通知重建最小间隔：通知栏歌词 2s 刷新一次足够（车机读 MediaSession），
        // 抑制 SystemUI 通知管线被歌词行变化持续唤醒
        private const val BT_NOTIFY_THROTTLE_MS = 2000L
        private val lyriconRetryHandler = Handler(Looper.getMainLooper())
        // 用户意图上是否启用词幕（非 SDK 的 ConnectionStatus），决定失败后是否重试
        @Volatile
        private var lyriconEnabled = false
        // 已重试次数 / 是否已有一次重试排期（避免并发事件重复 register）
        @Volatile
        private var lyriconRetryCount = 0
        @Volatile
        private var lyriconRetryScheduled = false

        // 缓存最近一次 isPlaying，供 setPosition 组装 Auto PlaybackState
        @Volatile
        private var lyriconIsPlaying = false

        fun setLyriconChannel(channel: MethodChannel?) {
            lyriconChannel = channel
        }

        /** 同步记录用户意图的启用状态（setEnabled / 启动恢复时调用）。 */
        fun setLyriconEnabledState(enabled: Boolean) {
            lyriconEnabled = enabled
            if (!enabled) {
                // 用户主动禁用：取消排期中的重试并清零计数
                lyriconRetryCount = 0
                lyriconRetryScheduled = false
                lyriconRetryHandler.removeCallbacksAndMessages(null)
            }
        }

        /**
         * 连接失败（timeout/disconnected）后的重试调度。
         * 仅在用户仍启用词幕时有效；重试次数耗尽后向 Dart 发送 connect_failed。
         * 每次重试间隔 [LYRICON_RETRY_DELAY_MS]，避免对中心服务发起风暴式重连。
         */
        private fun retryLyriconConnect(reason: String) {
            if (!lyriconEnabled) return
            if (lyriconRetryScheduled) return
            val provider = getLyriconProvider() ?: return
            if (lyriconRetryCount >= LYRICON_MAX_RETRIES) {
                lyriconRetryCount = 0
                lyriconRetryScheduled = false
                android.util.Log.w("LyriconDebug",
                    "lyricon connect failed after $LYRICON_MAX_RETRIES retries ($reason)")
                invokeLyriconChannelOnMain("onConnectionStateChanged", "connect_failed")
                return
            }
            lyriconRetryCount++
            lyriconRetryScheduled = true
            val attempt = lyriconRetryCount
            android.util.Log.d("LyriconDebug",
                "lyricon retry $attempt/$LYRICON_MAX_RETRIES (reason=$reason)")
            lyriconRetryHandler.postDelayed({
                lyriconRetryScheduled = false
                if (!lyriconEnabled) return@postDelayed
                val p = getLyriconProvider() ?: return@postDelayed
                try {
                    p.register()
                } catch (_: Exception) {
                    // register 抛异常也视为一次失败，继续下一轮重试
                    retryLyriconConnect("register exception")
                }
            }, LYRICON_RETRY_DELAY_MS)
        }

        /** 连接成功（connected/reconnected）或重新启用时重置重试状态。 */
        private fun resetLyriconRetryState() {
            lyriconRetryCount = 0
            lyriconRetryScheduled = false
            lyriconRetryHandler.removeCallbacksAndMessages(null)
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

        /**
         * 组装带时间戳的 framework PlaybackState，走 SDK 的 Auto 同步路径。
         * PlaybackState.Builder 会自动把构造时刻的 SystemClock.elapsedRealtime() 记为
         * lastPositionUpdateTime，SDK 的 Auto 模式据此按时间差插值推进播放时间轴，
         * 从而在两次更新之间平滑走时（消除 200ms 播步）。
         */
        fun buildLyriconPlaybackState(
            positionMs: Long,
            isPlaying: Boolean,
        ): android.media.session.PlaybackState {
            return android.media.session.PlaybackState.Builder()
                .setState(
                    if (isPlaying) PlaybackStateCompat.STATE_PLAYING else PlaybackStateCompat.STATE_PAUSED,
                    positionMs,
                    if (isPlaying) 1f else 0f,
                )
                .build()
        }

        /**
         * 注册 Lyricon Provider MethodChannel（Dart ↔ 原生双向）。
         * 由 MainActivity（正常启动）与 setupHeadlessChannels（进程被杀唤醒）
         * 共用，避免 headless 场景下 Dart 的 setSong/setEnabled 等调用因缺少
         * 原生 handler 而静默失败，也保证原生 onConnectionStateChanged 事件
         * 能送达 Dart（这是 Lyricon 自动恢复的前提）。
         */
        fun registerLyriconChannel(engine: FlutterEngine) {
            val channel = MethodChannel(
                engine.dartExecutor.binaryMessenger,
                "com.md3music.md3music/lyricon"
            )
            setLyriconChannel(channel)
            channel.setMethodCallHandler { call, result ->
                val provider = getLyriconProvider()
                when (call.method) {
                    "setEnabled" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        setLyriconEnabledState(enabled)
                        try {
                            if (enabled) {
                                // 重新启用：清零重试计数，重新走连接流程
                                resetLyriconRetryState()
                                provider?.register()
                            } else {
                                provider?.unregister()
                            }
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
                                val song = buildLyriconSong(arg)
                                provider?.player?.setSong(song)
                                // 切歌后立即喂一个 Auto PlaybackState 基点（新歌 position 0 + 当前播放态）。
                                // 若只 setSong 不推 PlaybackState，中心服务无法确定播放进度与状态，
                                // 歌词会不渲染、回退显示"作者-歌名"。
                                val startPos = (arg["startPositionMs"] as? Number)
                                    ?.toLong() ?: 0L
                                provider?.player?.setPlaybackState(
                                    buildLyriconPlaybackState(startPos, lyriconIsPlaying)
                                )
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
                            // 不再调 setPosition（会切成 Manually 同步），
                            // 改喂带时间戳的 Auto PlaybackState，SDK 在两次更新间插值平滑
                            provider?.player?.setPlaybackState(
                                buildLyriconPlaybackState(pos, lyriconIsPlaying)
                            )
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
                        lyriconIsPlaying = isPlaying
                        try {
                            // 统一走 Auto PlaybackState，附带 position+speed 时间戳
                            provider?.player?.setPlaybackState(
                                buildLyriconPlaybackState(pos, isPlaying)
                            )
                            result.success(true)
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                    "seekTo" -> {
                        val pos = call.argument<Number>("positionMs")?.toLong() ?: 0L
                        try {
                            // 统一走 Auto PlaybackState：seek 仅需把新位置作为基点喂给 SDK，
                            // 若用 player.seekTo 会切回 Manually，下一次 syncs 会 seekTo(旧 lastPosition=0) 闪回开头
                            provider?.player?.setPlaybackState(
                                buildLyriconPlaybackState(pos, lyriconIsPlaying)
                            )
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
                                val method = provider?.player?.javaClass
                                    ?.getMethod("setDisplayRoma", Boolean::class.java)
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
        }

        /**
         * 注册 SuperLyric MethodChannel（Dart → 原生单向）。
         * 由 MainActivity（正常启动）与 setupHeadlessChannels（进程被杀唤醒）共用。
         * Dart 端在切歌 / 歌词行变化时推送当前行，本 handler 组装 SuperLyricData
         * 经 SuperLyricHelper.sendLyric 发布到系统服务。播放/暂停由 SuperLyric
         * 自动监听 App 的 MediaSession 处理（sendStop），此处不手动发送。
         */
        fun registerSuperLyricChannel(engine: FlutterEngine) {
            val channel = MethodChannel(
                engine.dartExecutor.binaryMessenger,
                "com.md3music.md3music/super_lyric"
            )
            channel.setMethodCallHandler { call, result ->
                if (call.method != "sendLyric") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val arg = call.arguments as? Map<*, *> ?: run {
                    result.success(false)
                    return@setMethodCallHandler
                }
                @Suppress("UNCHECKED_CAST")
                val wordsRaw = arg["words"] as? List<Map<*, *>> ?: emptyList()
                val words = wordsRaw.mapNotNull { w ->
                    val text = w["text"] as? String ?: return@mapNotNull null
                    val start = (w["start"] as? Number)?.toLong() ?: 0L
                    val end = (w["end"] as? Number)?.toLong() ?: 0L
                    SuperLyricWord(text, start, end)
                }
                val startTime = (arg["startTime"] as? Number)?.toLong() ?: 0L
                val endTime = (arg["endTime"] as? Number)?.toLong() ?: 0L
                val text = arg["text"] as? String
                val translation = arg["translation"] as? String
                val roma = arg["roma"] as? String

                val data = SuperLyricData()
                (arg["title"] as? String)?.let { data.setTitle(it) }
                (arg["artist"] as? String)?.let { data.setArtist(it) }
                if (!text.isNullOrEmpty()) {
                    data.setLyric(SuperLyricLine(text, words.toTypedArray(), startTime, endTime))
                }
                if (!translation.isNullOrEmpty()) {
                    data.setTranslation(SuperLyricLine(translation, startTime, endTime))
                }
                if (!roma.isNullOrEmpty()) {
                    data.setSecondary(SuperLyricLine(roma, startTime, endTime))
                }

                try {
                    SuperLyricHelper.sendLyric(data)
                    android.util.Log.d("SuperLyricDebug",
                        "sendLyric: title='${arg["title"]}', artist='${arg["artist"]}', " +
                        "text='$text', words=${words.size}, translation='$translation', roma='$roma'")
                    result.success(true)
                } catch (e: Exception) {
                    android.util.Log.w("SuperLyricDebug",
                        "sendLyric failed: ${e.javaClass.simpleName}: ${e.message}")
                    result.success(false)
                }
            }
        }
    }

    private var mediaSession: MediaSessionCompat? = null
    private var notificationManager: NotificationManager? = null
    private var receiver: BroadcastReceiver? = null
    private var lockScreenReceiver: BroadcastReceiver? = null
    private var flutterEngine: FlutterEngine? = null
    // Lyricon Provider 是否已 register（restoreLyriconStateIfNeeded 可能被调用多次，需幂等）
    private var lyriconRegistered = false

    // 蓝牙歌词状态：原生端缓存原始元数据，根据开关和当前歌词计算最终显示值
    private var bluetoothLyricEnabled = false
    private var currentBtLyricText = ""
    private var originalTitle = ""
    private var originalArtist = ""
    // LyricInfo 歌词转发：缓存整首歌词 JSON（空 = 不发布），
    // 写入 MediaSession 元数据 extras.lyricInfo 供第三方系统读取
    @Volatile
    private var currentLyricInfo = ""
    // 上次已写入元数据的 lyricInfo，用于 refreshMetadata 判断是否需强制刷新
    private var lastShownLyricInfo = ""
    // 封面缓存：后台封面线程写入，主线程 refreshMetadata（蓝牙歌词）读取，
    // 必须 @Volatile 保证跨线程可见性
    @Volatile
    private var lastArtBitmap: Bitmap? = null
    private var lastArtUrl: String? = null
    // 缓存最近一次通知构建所需的播放状态，供 refreshMetadata 复用
    private var lastIsPlaying = false
    private var lastDesktopLyricEnabled = false
    private var lastIsFavorited = false
    private var lastDuration = 0L
    // 是否已调用过 startForeground（启动前台服务后必须尽快调用，Android 12+ 超时崩溃）
    private var foregroundStarted = false
    // 媒体键命令合并：唤醒期间连续按键只保留最新命令、只启动一个派发会话，
    // 避免双击（play→next）并发创建多个后台 FlutterEngine
    private val mediaCommandLock = Any()
    private var pendingMediaCommand: String? = null
    private var mediaCommandInFlight = false

    // P0: 蓝牙歌词刷新节流状态：通知重建最小间隔 + 最近一次显示的文本
    private var lastBtLyricNotifyTime = 0L
    private var lastShownBtLyricTitle: String? = null
    private var lastShownBtLyricArtist: String? = null

    // P0: setMetadata 节流合并：歌词行高频变化时在 [METADATA_REFRESH_DELAY_MS]
    // 窗口内合并为一次刷新，避免无节流 setMetadata 驱动 SystemUI 媒体卡片
    // 高频刷新（魅族等 ROM 下拉状态栏实测卡顿）
    private val metadataRefreshHandler = Handler(Looper.getMainLooper())
    private var pendingMetadataRefresh = false
    // P0: 256px 降采样封面缓存：蓝牙歌词刷新走小图，Binder 负载 ~2MB → ~256KB；
    // 由 showNotification 后台封面线程生成（与 lastArtBitmap 同源）
    @Volatile
    private var lastArtThumb: Bitmap? = null

    // P0: 缓存通知 PendingIntent（showNotification / refreshMetadata 共用），
    // 避免蓝牙歌词高频刷新时每次重建 5+ 个 PendingIntent 对象
    private var cachedLaunchPendingIntent: PendingIntent? = null
    private val cachedServicePendingIntents = arrayOfNulls<PendingIntent>(6)

    private fun launchPendingIntent(): PendingIntent {
        cachedLaunchPendingIntent?.let { return it }
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        return PendingIntent.getActivity(
            this, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        ).also { cachedLaunchPendingIntent = it }
    }

    private fun servicePendingIntent(requestCode: Int, action: String): PendingIntent {
        cachedServicePendingIntents[requestCode]?.let { return it }
        return PendingIntent.getService(
            this, requestCode,
            Intent(this, AudioPlaybackService::class.java).apply { this.action = action },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        ).also { cachedServicePendingIntents[requestCode] = it }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        notificationManager = getSystemService(NotificationManager::class.java)
        initMediaSession()
        registerReceiver()
        // 锁屏歌词：动态注册 SCREEN_OFF/SCREEN_ON 广播（前台服务存活期间注册，
        // 比 manifest 静态广播在 MIUI 等 ROM 上更可靠）
        try {
            lockScreenReceiver = LockScreenLyricReceiver()
            val filter = IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_OFF)
                addAction(Intent.ACTION_SCREEN_ON)
            }
            registerReceiver(lockScreenReceiver, filter)
            android.util.Log.i("LockScreenLyric", "AudioPlaybackService.onCreate: lock screen receiver registered")
        } catch (e: Exception) {
            android.util.Log.e("LockScreenLyric", "register lock screen receiver failed: $e")
        }
        // P0: 不再在 onCreate 无条件持有 WakeLock（此时未必在播放）。
        // 仅当 onStartCommand 收到 isPlaying=true 时才持有，暂停时释放。

        // 初始化 Lyricon Provider（用 try-catch 包裹，防止 SDK 在低版本 Android 抛异常）
        lyriconProvider = try {
            LyriconFactory.createProvider(this).apply {
                autoSync = true
                try {
                    // SDK 的 ConnectionListener 是 interface，必须用 object 表达式实现
                    service.addConnectionListener(object : ConnectionListener {
                        override fun onConnected(provider: LyriconProvider) {
                            resetLyriconRetryState()
                            invokeLyriconChannelOnMain("onConnectionStateChanged", "connected")
                        }
                        override fun onReconnected(provider: LyriconProvider) {
                            resetLyriconRetryState()
                            invokeLyriconChannelOnMain("onConnectionStateChanged", "reconnected")
                        }
                        override fun onDisconnected(provider: LyriconProvider) {
                            // 用户主动禁用（unregister）也会触发本回调，此时 lyriconEnabled 为 false，
                            // retryLyriconConnect 内部会直接返回；仅对「仍启用但断联」的场景重试。
                            invokeLyriconChannelOnMain("onConnectionStateChanged", "disconnected")
                            retryLyriconConnect("disconnected")
                        }
                        override fun onConnectTimeout(provider: LyriconProvider) {
                            invokeLyriconChannelOnMain("onConnectionStateChanged", "timeout")
                            retryLyriconConnect("timeout")
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
        // 注册 SuperLyric 发布者（应用播放服务启动即首次播放时注册，进程终止后系统自动清理；
        // 播放/暂停由 SuperLyric 自动监听 App 的 MediaSession 处理）
        try {
            SuperLyricHelper.registerPublisher()
        } catch (_: Exception) {}
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
            // 记录用户意图：headless 唤醒 / 连接失败重试都依赖该标志判断是否继续重试
            setLyriconEnabledState(enabled)
            android.util.Log.d("LyriconDebug",
                "restoreLyriconStateIfNeeded: enabled=$enabled, displayTranslation=$displayTranslation, " +
                "displayRoma=$displayRoma, channelSet=${lyriconChannel != null}")
            if (enabled) {
                // 幂等：headless 唤醒时会再次调用本方法（首次在 onCreate，channel 尚为 null），
                // 只在首次真正 register，避免对 SDK 重复注册。
                if (!lyriconRegistered) {
                    provider.register()
                    lyriconRegistered = true
                    android.util.Log.d("LyriconDebug", "restoreLyriconStateIfNeeded: provider.register() done")
                }
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
                isNowPlaying = false
                // 停止播放/退出 App 后锁屏歌词不应残留
                LockScreenLyricActivity.dismiss()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_PREV, ACTION_PLAY_PAUSE, ACTION_NEXT, ACTION_TOGGLE_DESKTOP_LYRIC, ACTION_TOGGLE_FAVORITE,
            ACTION_WIDGET_PLAY_PAUSE, ACTION_WIDGET_NEXT -> {
                handleAction(intent.action!!)
                return START_STICKY
            }
            ACTION_MEDIA_BUTTON -> {
                // 线控耳机唤醒播放：先保证前台服务状态（startForegroundService 必须尽快
                // 调用 startForeground，否则 Android 12+ 会抛 ForegroundServiceDidNotStartInTimeException）
                ensureForeground()
                val command = intent?.getStringExtra(EXTRA_MEDIA_COMMAND) ?: "play"
                handleMediaButtonCommand(command)
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
            ACTION_UPDATE_LYRIC_INFO -> {
                currentLyricInfo = intent?.getStringExtra(EXTRA_LYRIC_INFO) ?: ""
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

        // WakeLock 在 showNotification 之前处理：
        // showNotification 内含封面线程/startForeground/MediaSession 更新，
        // 若其抛异常会跳过 releaseWakeLock，导致暂停后 CPU 无法休眠（功耗降不下来）。
        // 提前处理保证 isPlaying=false 时 WakeLock 一定被释放。
        if (isPlaying) {
            acquireWakeLock(this)
        } else {
            // P0: 暂停时立即释放 WakeLock，避免 CPU 无法休眠造成耗电
            releaseWakeLock()
        }

        showNotification(title, artist, artUrl, fallbackFilePath, isPlaying, position, duration, desktopLyricEnabled, isFavorited)

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

    /// 前台服务占位通知：唤醒场景下服务可能刚被 startForegroundService 拉起，
    /// 需要尽快进入前台。真实内容随后由 Dart 端 updateNotification 覆盖。
    private fun ensureForeground() {
        if (foregroundStarted) return
        foregroundStarted = true
        try {
            val builder = NotificationCompat.Builder(this, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setContentTitle("md3music")
                .setContentText("准备播放")
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setPriority(NotificationCompat.PRIORITY_LOW)
            startForeground(NOTIFICATION_ID, builder.build())
        } catch (_: Exception) {}
    }

    /// 线控耳机媒体键 → 派发命令到 Dart 端。
    /// - 进程存活：复用现有 FlutterEngine（含 MainActivity 缓存的引擎）
    /// - 进程被杀：创建后台 FlutterEngine 启动 App，恢复上次播放状态后执行命令
    ///
    /// 唤醒期间可能连续收到多个按键（双击=下一首），这里做命令合并：
    /// 任意时刻只保留「最新」命令（pendingMediaCommand），且同一进程内只启动
    /// 一个派发会话，避免并发创建多个后台 FlutterEngine。
    private fun handleMediaButtonCommand(command: String) {
        val method = when (command) {
            "play" -> "play"
            "pause", "stop" -> "pause"
            "next" -> "next"
            "previous" -> "previous"
            else -> "play"
        }
        var launch = false
        synchronized(mediaCommandLock) {
            pendingMediaCommand = method
            if (!mediaCommandInFlight) {
                mediaCommandInFlight = true
                launch = true
            }
        }
        if (!launch) return
        Thread {
            try {
                val engine = obtainFlutterEngine()
                if (engine != null) {
                    dispatchToDartWithRetry(engine)
                } else {
                    createHeadlessEngineAndDispatch()
                }
            } finally {
                synchronized(mediaCommandLock) {
                    mediaCommandInFlight = false
                    pendingMediaCommand = null
                }
            }
        }.start()
    }

    /// 取走当前待派发的媒体命令（取后清空，避免被后续处理重复消费）。
    private fun takeMediaCommand(): String? = synchronized(mediaCommandLock) {
        val m = pendingMediaCommand
        pendingMediaCommand = null
        m
    }

    /// 找到可用的 FlutterEngine：实例字段 → 静态引用 → FlutterEngineCache。
    /// 已销毁的引擎（isExecutingDart() == false）会被跳过，避免对死引擎派发命令。
    private fun obtainFlutterEngine(): FlutterEngine? {
        val candidates = listOfNotNull(
            flutterEngine,
            staticFlutterEngine,
            FlutterEngineCache.getInstance().get("md3music_engine"),
        )
        for (engine in candidates) {
            if (engine.dartExecutor.isExecutingDart()) {
                if (engine !== staticFlutterEngine) staticFlutterEngine = engine
                if (engine !== flutterEngine) flutterEngine = engine
                return engine
            }
        }
        return null
    }

    /// 进程存活场景：Dart 端可能仍在初始化（PlayerProvider 恢复状态中）。
    /// 仅当派发失败（channel 尚未注册）时重试；成功后即停止，避免对已开始播放的
    /// 歌曲重复调用 resume 造成音量波动。每次重试都取「最新」命令，唤醒期间的
    /// 双击（play→next）能正确合并为 next。
    ///
    /// 同步执行（调用方已在后台线程）：必须在本方法内消费 pendingMediaCommand，
    /// 否则外层 finally 会提前清空命令导致派发丢失（headless 场景曾因此失效）。
    private fun dispatchToDartWithRetry(engine: FlutterEngine) {
        try {
            for (i in 0 until 3) {
                val method = takeMediaCommand() ?: return
                if (dispatchOnce(engine, method)) return
                Thread.sleep(500)
            }
        } catch (_: Exception) {}
    }

    /// 进程被杀场景：创建后台 FlutterEngine 运行完整 App（main() → runApp →
    /// PlayerProvider 自动恢复上次播放状态），等待 Dart 端上报 playerReady 后
    /// 派发命令完成「唤醒播放」。引擎放入 FlutterEngineCache，用户随后打开 App
    /// 时由 MainActivity 复用（provideFlutterEngine），避免双引擎冲突。
    ///
    /// 线程注意：FlutterEngine 必须在主线程创建并执行入口（引擎的平台线程即创建
    /// 线程，后台线程创建会导致后续 MainActivity 复用/UI 附着失败）。
    /// 本方法在调用方（handleMediaButtonCommand 的后台线程）内同步执行到命令
    /// 被消费为止：内层不再新起线程，避免外层 finally 提前清空
    /// pendingMediaCommand 导致 play/next 命令派发丢失。
    private fun createHeadlessEngineAndDispatch() {
        playerReadyReceived = false
        val engineLatch = CountDownLatch(1)
        runOnMainThread {
            try {
                val engine = FlutterEngine(applicationContext)
                // 手动创建的引擎不会自动注册插件（just_audio 等），必须显式注册
                GeneratedPluginRegistrant.registerWith(engine)
                FlutterEngineCache.getInstance().put("md3music_engine", engine)
                staticFlutterEngine = engine
                flutterEngine = engine
                setupHeadlessChannels(engine)
                engine.dartExecutor.executeDartEntrypoint(
                    DartExecutor.DartEntrypoint.createDefault()
                )
            } catch (e: Exception) {
                Log.w(TAG, "headless engine create failed: $e")
            } finally {
                engineLatch.countDown()
            }
        }
        try {
            engineLatch.await(5, TimeUnit.SECONDS)
            val engine = flutterEngine ?: staticFlutterEngine
            if (engine == null || !engine.dartExecutor.isExecutingDart()) return
            // 等待 Dart 端 PlayerProvider 完成状态恢复（本地歌曲快，在线歌曲走 API 较慢）
            for (i in 0 until 30) {
                if (playerReadyReceived) break
                Thread.sleep(1000)
            }
            // playerReady 意味着 Dart main() 已跑完 runApp，Lyricon 反向 handler
            // 必然已注册，此时补发 auto_restored 事件才可靠（setupHeadlessChannels
            // 里那次可能因 Dart 尚未注册 handler 而丢消息）。幂等：register 已由
            // onCreate 完成，这里只负责把事件送达 Dart。
            restoreLyriconStateIfNeeded()
            val method = takeMediaCommand() ?: return
            dispatchOnce(engine, method)
        } catch (_: Exception) {}
    }

    /// 在主线程通过 MethodChannel 派发一次命令到 Dart 端。
    /// 返回是否成功（Dart 端 handler 已注册且方法被处理）。
    /// 注意：handler 注册 ≠ PlayerProvider 就绪，play 命令的就绪时序由
    /// playerReady 信号保证（headless 场景）。
    private fun dispatchOnce(engine: FlutterEngine, method: String): Boolean {
        val latch = CountDownLatch(1)
        val dispatched = arrayOf(false)
        runOnMainThread {
            try {
                MethodChannel(
                    engine.dartExecutor.binaryMessenger,
                    "com.md3music.md3music/floating_lyric"
                ).invokeMethod(method, null, object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        dispatched[0] = true
                        latch.countDown()
                    }
                    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                        latch.countDown()
                    }
                    override fun notImplemented() {
                        latch.countDown()
                    }
                })
            } catch (_: Exception) {
                latch.countDown()
            }
        }
        try {
            latch.await(2, TimeUnit.SECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        return dispatched[0]
    }

    private fun runOnMainThread(block: () -> Unit) {
        val handler = Handler(Looper.getMainLooper())
        if (Looper.myLooper() == Looper.getMainLooper()) {
            block()
        } else {
            handler.post(block)
        }
    }

    /// 为后台（headless）FlutterEngine 注册原生端 MethodChannel handler。
    /// MainActivity 正常启动时会注册完整 handler（含桌面歌词等）；进程被杀后由
    /// 本服务兜底注册，保证通知栏 / MediaSession 在唤醒场景下仍能正常更新。
    private fun setupHeadlessChannels(engine: FlutterEngine) {
        try {
            MethodChannel(
                engine.dartExecutor.binaryMessenger,
                "com.md3music.md3music/floating_lyric"
            ).setMethodCallHandler { call, result ->
                when (call.method) {
                    "playerReady" -> {
                        playerReadyReceived = true
                        result.success(null)
                    }
                    "showNotification", "updateNotification" -> {
                        showNotification(
                            title = call.argument<String>("title") ?: "",
                            artist = call.argument<String>("artist") ?: "",
                            artUrl = call.argument<String>("artUrl"),
                            fallbackFilePath = call.argument<String>("fallbackFilePath"),
                            isPlaying = call.argument<Boolean>("isPlaying") ?: false,
                            position = call.argument<Number>("position")?.toLong() ?: 0L,
                            duration = call.argument<Number>("duration")?.toLong() ?: 0L,
                            desktopLyricEnabled = call.argument<Boolean>("desktopLyricEnabled") ?: false,
                            isFavorited = call.argument<Boolean>("isFavorited") ?: false,
                        )
                        result.success(true)
                    }
                    "hideNotification" -> {
                        stopForeground(STOP_FOREGROUND_REMOVE)
                        releaseWakeLock()
                        isNowPlaying = false
                        LockScreenLyricActivity.dismiss()
                        stopSelf()
                        result.success(true)
                    }
                    "updateBluetoothLyric" -> {
                        currentBtLyricText = call.argument<String>("lyric") ?: ""
                        refreshMetadata()
                        result.success(true)
                    }
                    "setBluetoothLyricEnabled" -> {
                        bluetoothLyricEnabled = call.argument<Boolean>("enabled") ?: false
                        refreshMetadata()
                        result.success(true)
                    }
                    // 锁屏歌词：开关 / 数据推送（正常启动走 MainActivity，headless 在此兜底）
                    "showLockScreenLyric" -> {
                        result.success(true)
                    }
                    "hideLockScreenLyric" -> {
                        LockScreenLyricActivity.dismiss()
                        result.success(true)
                    }
                    "updateLockScreenLyric" -> {
                        LockScreenLyricActivity.applyCall(call)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
            // 进程被杀唤醒场景：Lyricon channel 原生 handler 只能在这里注册
            // （无 MainActivity），注册后重新通知 Dart 端 Lyricon 已自动恢复，
            // 否则词幕不会随播放自动连接（Dart 端 _state 一直停留在 disabled）。
            registerLyriconChannel(engine)
            // SuperLyric channel 原生 handler 同样只能在 headless 场景下在此注册
            registerSuperLyricChannel(engine)
            restoreLyriconStateIfNeeded()
        } catch (_: Exception) {}
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
                // P0: HttpURLConnection 显式设置超时，避免慢响应导致线程永久阻塞
                val conn = java.net.URL(artUri).openConnection() as java.net.HttpURLConnection
                conn.connectTimeout = 5000
                conn.readTimeout = 10000
                conn.instanceFollowRedirects = true
                try {
                    BitmapFactory.decodeStream(conn.inputStream)
                } finally {
                    conn.disconnect()
                }
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
        val retriever = MediaMetadataRetriever()
        return try {
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
            if (art != null) BitmapFactory.decodeByteArray(art, 0, art.size) else null
        } catch (_: Exception) {
            null
        } finally {
            // P0: 异常路径也必须释放 native 资源，避免 FD 泄漏
            try { retriever.release() } catch (_: Exception) {}
        }
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
        // 同步「正在播放」状态，供锁屏歌词广播（ACTION_SCREEN_OFF）判断
        isNowPlaying = isPlaying
        lastDesktopLyricEnabled = desktopLyricEnabled
        lastIsFavorited = isFavorited
        lastDuration = duration
        // 通知会在下方所有分支中调用 startForeground，标记已进入前台
        foregroundStarted = true
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

        // P0: 复用缓存的 PendingIntent（懒加载一次，后续共用），避免每次通知重建对象
        val pendingIntent = launchPendingIntent()
        val prevIntent = servicePendingIntent(1, ACTION_PREV)
        val playPauseIntent = servicePendingIntent(2, ACTION_PLAY_PAUSE)
        val nextIntent = servicePendingIntent(3, ACTION_NEXT)
        val toggleLyricIntent = servicePendingIntent(4, ACTION_TOGGLE_DESKTOP_LYRIC)
        val toggleFavoriteIntent = servicePendingIntent(5, ACTION_TOGGLE_FAVORITE)

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

        // 先立即发布通知（默认封面），避免 startForegroundService 的 5 秒限制；
        // 同时立即同步 MediaSession 元数据（title/artist/时长），
        // 防止封面缺失时残留上一首歌曲的封面/标题（云盘歌封面为异步提取，会晚到）
        startForeground(NOTIFICATION_ID, builder.build())
        updateMediaSessionMetadata(displayTitle, displayArtist, duration, null, effectiveArtUrl)

        if (!effectiveArtUrl.isNullOrEmpty()) {
            Thread {
                try {
                    val originalBitmap = loadArtworkBitmap(effectiveArtUrl, fallbackFilePath)
                    if (originalBitmap != null) {
                        // P0: 统一降采样到 512px 后再缓存/使用，避免原始大图（2000x2000+）常驻内存
                        val displayBitmap = resizeBitmap(originalBitmap, 512)
                        if (displayBitmap !== originalBitmap) {
                            originalBitmap.recycle()
                        }
                        // 切歌时不再显式 recycle 旧封面：主线程 refreshMetadata（蓝牙歌词
                        // 逐句刷新）可能正持有 lastArtBitmap 并放入 MediaSession 元数据，
                        // 后台线程显式回收存在 use-after-recycle 竞态 → 偶发闪退。
                        // 旧 bitmap 失去强引用后由 GC 回收，此处仅做引用切换。
                        lastArtBitmap = displayBitmap
                        // P0: 256px 小图缓存，供蓝牙歌词刷新路径（refreshMetadata）复用，
                        // 单次 setMetadata Binder 负载 ~2MB → ~256KB
                        lastArtThumb = resizeBitmap(displayBitmap, 256)
                        // 同步封面到桌面小组件（与通知栏/MediaSession 一致）
                        MusicWidgetProvider.cachedArtwork = resizeBitmap(displayBitmap, 200)
                        MusicWidgetProvider.notifyArtworkChanged(this@AudioPlaybackService)
                        // 通知 LargeIcon：缩放到 192px（~64dp @ xxhdpi）
                        val iconBitmap = resizeBitmap(displayBitmap, 192)
                        builder.setLargeIcon(iconBitmap)
                        startForeground(NOTIFICATION_ID, builder.build())

                        // MediaSession Metadata：用降采样 bitmap + URI
                        // title/artist 用 display 值（蓝牙歌词开启时为歌词文本）
                        updateMediaSessionMetadata(
                            displayTitle, displayArtist, duration, displayBitmap, effectiveArtUrl
                        )
                    }
                } catch (_: Exception) {}
            }.start()
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

        // 同步播放状态到 Lyricon：必须走 Auto PlaybackState（带 position+speed 时间戳）。
        // 不能调 Boolean 重载 / setPosition / seekTo，否则会切回 Manually 并 seek 到
        // 旧位置（lastPosition=0），导致歌词每隔一次同步就闪回开头。
        try {
            lyriconProvider?.player?.setPlaybackState(
                buildLyriconPlaybackState(position, isPlaying)
            )
        } catch (_: Exception) {}
    }

    /// 统一更新 MediaSession 元数据。每次新建 Builder 重建，
    /// 避免封面缺失/加载失败时残留上一首歌曲的封面 bitmap。
    /// [artwork] 为 null 时仅同步 title/artist（封面留给异步线程补充）。
    private fun updateMediaSessionMetadata(
        title: String,
        artist: String,
        duration: Long,
        artwork: Bitmap?,
        artUri: String?
    ) {
        val metaBuilder = MediaMetadataCompat.Builder()
            .putString(MediaMetadataCompat.METADATA_KEY_TITLE, title)
            .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, artist)
            .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, duration)
        if (artwork != null) {
            metaBuilder.putBitmap(MediaMetadataCompat.METADATA_KEY_ART, artwork)
            metaBuilder.putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, artwork)
        }
        if (!artUri.isNullOrEmpty()) {
            metaBuilder.putString(MediaMetadataCompat.METADATA_KEY_ART_URI, artUri)
        }
        // LyricInfo 歌词转发：发布整首歌词 JSON 到 MediaMetadata.extras，
        // 供 ColorOS 桌面歌词 / LyricInfo 模块等第三方系统读取（空则不发布）
        if (currentLyricInfo.isNotEmpty()) {
            metaBuilder.putString(EXTRA_LYRIC_INFO, currentLyricInfo)
        }
        mediaSession?.setMetadata(metaBuilder.build())
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

        // P0: 文本未变化（歌词行未变 / 开关未切换）时直接跳过，避免无效刷新。
        // 但 LyricInfo 歌词转发（currentLyricInfo 变化）不依赖 title/artist 变化，
        // 即使 title/artist 未变也需要更新 MediaSession 元数据以写入 extras.lyricInfo，
        // 因此本跳过逻辑仅在 lyricInfo 不变时生效。
        val lyricInfoChanged = currentLyricInfo != lastShownLyricInfo
        if (displayTitle == lastShownBtLyricTitle && displayArtist == lastShownBtLyricArtist && !lyricInfoChanged) return
        lastShownBtLyricTitle = displayTitle
        lastShownBtLyricArtist = displayArtist
        lastShownLyricInfo = currentLyricInfo

        // P0: 通知重建节流：歌词行变化驱动，通知栏重建限制为最少 2s 一次
        // （车机 AVRCP 歌词读的是 MediaSession，不受节流影响；通知栏歌词 2s 刷新足够）
        val now = SystemClock.elapsedRealtime()
        val shouldUpdateNotification = now - lastBtLyricNotifyTime >= BT_NOTIFY_THROTTLE_MS
        if (shouldUpdateNotification) {
            lastBtLyricNotifyTime = now
            val playPauseIcon = if (lastIsPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play
            val lyricIconRes = if (lastDesktopLyricEnabled) R.drawable.ic_lyric_on else R.drawable.ic_lyric_off
            val favoriteIconRes = if (lastIsFavorited) R.drawable.ic_favorite_on else R.drawable.ic_favorite_off

            val builder = NotificationCompat.Builder(this, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setContentTitle(displayTitle)
                .setContentText(displayArtist)
                .setContentIntent(launchPendingIntent())
                .setOngoing(true)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .addAction(android.R.drawable.ic_media_previous, "上一首", servicePendingIntent(1, ACTION_PREV))
                .addAction(playPauseIcon, if (lastIsPlaying) "暂停" else "播放", servicePendingIntent(2, ACTION_PLAY_PAUSE))
                .addAction(favoriteIconRes, "收藏", servicePendingIntent(5, ACTION_TOGGLE_FAVORITE))
                .addAction(android.R.drawable.ic_media_next, "下一首", servicePendingIntent(3, ACTION_NEXT))
                .addAction(lyricIconRes, "桌面歌词", servicePendingIntent(4, ACTION_TOGGLE_DESKTOP_LYRIC))
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
        }

        // P0: setMetadata 300ms 合并节流：歌词行高频变化时合并为一次刷新，
        // 避免无节流 setMetadata 驱动 SystemUI 媒体卡片高频刷新（魅族等 ROM 卡顿）
        scheduleMetadataRefresh()
    }

    /// P0: 排期一次 MediaSession 元数据刷新（300ms 合并窗口）。
    /// 窗口内多次歌词变化只执行一次 setMetadata，使用执行时刻的最新字段值。
    private fun scheduleMetadataRefresh() {
        if (pendingMetadataRefresh) return
        pendingMetadataRefresh = true
        metadataRefreshHandler.postDelayed({
            pendingMetadataRefresh = false
            performMetadataRefresh()
        }, METADATA_REFRESH_DELAY_MS)
    }

    /// P0: 执行 MediaSession 元数据刷新（合并窗口后，取最新歌词/开关状态）。
    /// 封面压缩开关（Flutter 设置 settings_bluetooth_lyric_compress_art，默认关）：
    /// 开启用 256px 缩略图（lastArtThumb，Binder 负载 ~2MB → ~256KB），关闭用原始 512px。
    /// 每次直接读 SharedPreferences（进程内缓存，读取开销可忽略；开关切换即时生效）。
    private fun performMetadataRefresh() {
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
        val metaBuilder = MediaMetadataCompat.Builder()
            .putString(MediaMetadataCompat.METADATA_KEY_TITLE, displayTitle)
            .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, displayArtist)
            .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, lastDuration)
        val compressArt = try {
            getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .getBoolean("flutter.settings_bluetooth_lyric_compress_art", false)
        } catch (_: Exception) {
            false
        }
        val artwork = if (compressArt) lastArtThumb else lastArtBitmap
        if (artwork != null) {
            metaBuilder.putBitmap(MediaMetadataCompat.METADATA_KEY_ART, artwork)
            metaBuilder.putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, artwork)
        }
        if (!lastArtUrl.isNullOrEmpty()) {
            metaBuilder.putString(MediaMetadataCompat.METADATA_KEY_ART_URI, lastArtUrl)
        }
        // LyricInfo 歌词转发：蓝牙歌词刷新路径也保留 lyricInfo（空则不发布）
        if (currentLyricInfo.isNotEmpty()) {
            metaBuilder.putString(EXTRA_LYRIC_INFO, currentLyricInfo)
        }
        mediaSession?.setMetadata(metaBuilder.build())
    }

    override fun onDestroy() {
        receiver?.let {
            try {
                unregisterReceiver(it)
            } catch (_: Exception) {}
        }
        lockScreenReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (_: Exception) {}
        }
        lockScreenReceiver = null
        mediaSession?.release()
        // 释放 Lyricon Provider
        try {
            lyriconProvider?.unregister()
        } catch (_: Exception) {}
        try {
            lyriconProvider?.destroy()
        } catch (_: Exception) {}
        lyriconProvider = null
        // 取消排期中的词幕重连任务，防止服务销毁后回调仍触发
        setLyriconEnabledState(false)
        // P0: 取消排期中的 setMetadata 合并刷新，防止服务销毁后仍回调
        metadataRefreshHandler.removeCallbacksAndMessages(null)
        releaseWakeLock()
        // 释放缓存的封面 bitmap
        lastArtBitmap?.let { if (!it.isRecycled) it.recycle() }
        lastArtBitmap = null
        lastArtThumb?.let { if (!it.isRecycled) it.recycle() }
        lastArtThumb = null
        super.onDestroy()
    }
}
