package com.md3music.md3music

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.app.ActivityManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.ServiceConnection
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.os.Handler
import android.os.Looper
import android.graphics.Typeface
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock
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
import com.ryanheise.just_audio.AudioPlayer
import io.flutter.plugins.GeneratedPluginRegistrant
import io.github.proify.lyricon.provider.ConnectionListener
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.ConcurrentHashMap
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
        // 阶段7：保活通知专用频道（IMPORTANCE_NONE，系统默认不显示、不打扰）。
        // 通知对象常驻支撑 startForeground，避免服务被系统降级（DETACH 方案已废弃）。
        const val KEEPALIVE_CHANNEL_ID = "md3music_keepalive"
        const val NOTIFICATION_ID = 1002
        // 阶段8：桌面歌词关闭后通知保活服务立即恢复前台（让位结束）
        const val ACTION_REFRESH_FOREGROUND = "com.md3music.md3music.REFRESH_FOREGROUND"
        const val ACTION_PREV = "com.md3music.md3music.ACTION_PREV"
        const val ACTION_PLAY_PAUSE = "com.md3music.md3music.ACTION_PLAY_PAUSE"
        const val ACTION_NEXT = "com.md3music.md3music.ACTION_NEXT"
        const val ACTION_STOP = "com.md3music.md3music.ACTION_STOP"
        const val ACTION_TOGGLE_DESKTOP_LYRIC = "com.md3music.md3music.ACTION_TOGGLE_DESKTOP_LYRIC"
        const val ACTION_TOGGLE_FAVORITE = "com.md3music.md3music.ACTION_TOGGLE_FAVORITE"
        // 蓝牙歌词兼容通道；不得再改写 SystemUI 共用 MediaSession 的 TITLE/ARTIST。
        const val ACTION_UPDATE_BT_LYRIC = "com.md3music.md3music.ACTION_UPDATE_BT_LYRIC"
        const val ACTION_SET_BT_LYRIC_ENABLED = "com.md3music.md3music.ACTION_SET_BT_LYRIC_ENABLED"
        const val EXTRA_TITLE = "title"
        const val EXTRA_MEDIA_ID = "mediaId"
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
        const val EXTRA_HAS_LYRIC_TRANSLATION = "hasLyricTranslation"
        const val EXTRA_LYRIC_SESSION_GENERATION = "lyricSessionGeneration"
        // 桌面小组件按钮动作（由 MusicWidgetProvider 转发）
        const val ACTION_WIDGET_PLAY_PAUSE = "com.md3music.md3music.ACTION_WIDGET_PLAY_PAUSE"
        const val ACTION_WIDGET_NEXT = "com.md3music.md3music.ACTION_WIDGET_NEXT"
        // 私人FM桌面小组件按钮动作（由 PersonalFmWidgetProvider 转发）
        const val ACTION_WIDGET_FM_PLAY_PAUSE = "com.md3music.md3music.ACTION_FM_WIDGET_PLAY_PAUSE"
        const val ACTION_WIDGET_FM_TOGGLE_FAVORITE = "com.md3music.md3music.ACTION_FM_WIDGET_TOGGLE_FAVORITE"
        const val ACTION_WIDGET_FM_SELECT_STATION = "com.md3music.md3music.ACTION_FM_WIDGET_SELECT_STATION"
        const val ACTION_WIDGET_FM_OPEN_TRACK = "com.md3music.md3music.ACTION_FM_WIDGET_OPEN_TRACK"
        // 小部件封面点击：拉起 app 并打开播放器页
        const val ACTION_WIDGET_FM_OPEN_PLAYER = "com.md3music.md3music.ACTION_FM_WIDGET_OPEN_PLAYER"
        // FM 小部件动作参数（档位下标 / 歌曲 hash）
        const val EXTRA_FM_ACTION_STATION_INDEX = "action_station_index"
        const val EXTRA_FM_ACTION_TRACK_HASH = "action_track_hash"
        // 线控耳机媒体键（由 MediaButtonReceiver 转发，唤醒播放）
        const val ACTION_MEDIA_BUTTON = "com.md3music.md3music.ACTION_MEDIA_BUTTON"
        const val EXTRA_MEDIA_COMMAND = "mediaCommand"

        private const val TAG = "AudioPlaybackService"

        // 静态变量用于跨组件传递 FlutterEngine
        private var staticFlutterEngine: FlutterEngine? = null
        private var wakeLock: PowerManager.WakeLock? = null
        private var wifiLock: WifiManager.WifiLock? = null

        // 方案A：在线封面本地缓存（根治切歌空档）。内存缓存 key=artUrl，磁盘缓存按 URL hash 命名。
        // 命中内存/磁盘 → 免网络下载，切歌秒显；未命中才下载并写缓存。
        private val coverMemoryCache = ConcurrentHashMap<String, Bitmap>()
        private const val COVER_CACHE_DIR = "cover_cache"
        // 磁盘缓存上限（张）：超限清空最旧文件，避免无限增长
        private const val COVER_CACHE_MAX = 200

        /// 进程被杀后由本服务创建的后台 FlutterEngine 是否已就绪。
        /// Dart 端 PlayerProvider 完成状态恢复后会通过 playerReady 通知置为 true。
        @Volatile
        var playerReadyReceived = false

        /// 当前是否正在播放（供 LockScreenLyricReceiver 判断锁屏时是否拉起歌词界面）。
        @Volatile
        var isNowPlaying = false
        /// MD3Music fork（方案A·封面兜底）：前台服务启动被拒（mAllowStartForeground=false，
        /// 如后台切歌/跨fade 收敛瞬间）时由 MainActivity 直接调用注入封面，
        /// 不依赖 AudioPlaybackService 启动。处理 http(s) 在线封面，命中内存缓存免下载。
        @JvmStatic
        fun injectCover(
            mediaId: String,
            title: String,
            artist: String,
            artUrl: String?,
            fallbackFilePath: String?
        ) {
            val effective = artUrl ?: fallbackFilePath ?: return
            Thread {
                try {
                    // 1) 内存缓存命中：先剔除已回收的失效条目，避免复用后 isRecycled 判 false
                    var bmp: Bitmap? = null
                    if (effective.startsWith("http://") || effective.startsWith("https://")) {
                        val cached = coverMemoryCache[effective]
                        bmp = if (cached != null && cached.isRecycled) {
                            coverMemoryCache.remove(effective)
                            null
                        } else cached
                    }
                    // 2) 未命中：按来源加载（http 下载 / file·local·纯路径读内嵌封面），
                    //    http 下载失败时回退 fallbackFilePath
                    if (bmp == null) {
                        bmp = loadCoverBitmapForInject(effective, fallbackFilePath)
                    }
                    if (bmp != null && !bmp.isRecycled) {
                        // 降采样到 512px 后再注入，避免大图常驻内存
                        val display = resizeCoverBitmap(bmp, 512)
                        AudioPlayer.updateActiveSessionMetadata(
                            mediaId, 0L, title, artist, display, effective)
                        Log.i(TAG, "injectCover: 封面注入成功 title=" + title)
                    } else {
                        Log.w(TAG, "injectCover: 封面加载失败 url=" + effective)
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "injectCover 异常 " + e.message)
                }
            }.start()
        }

        /// 兜底封面加载：http(s) 在线下载（成功写入内存缓存）；非 http 或下载失败时
        /// 依次尝试 [source]（file:///local:///纯路径）与 [fallback] 的内嵌封面。
        private fun loadCoverBitmapForInject(source: String, fallback: String?): Bitmap? {
            var bmp: Bitmap? = null
            if (source.startsWith("http://") || source.startsWith("https://")) {
                try {
                    val conn = java.net.URL(source).openConnection() as java.net.HttpURLConnection
                    conn.connectTimeout = 5000
                    conn.readTimeout = 10000
                    conn.instanceFollowRedirects = true
                    try {
                        bmp = BitmapFactory.decodeStream(conn.inputStream)
                        if (bmp != null && !bmp.isRecycled) coverMemoryCache[source] = bmp
                    } finally {
                        conn.disconnect()
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "injectCover http 下载异常 ${e.message} url=$source")
                }
            }
            if (bmp == null || bmp.isRecycled) {
                bmp = decodeEmbeddedCoverCompat(source, fallback)
            }
            return if (bmp != null && !bmp.isRecycled) bmp else null
        }

        /// 从 file:///local:///纯路径依次取内嵌封面；优先 [source]，失败再试 [fallback]。
        private fun decodeEmbeddedCoverCompat(source: String, fallback: String?): Bitmap? {
            for (c in listOf(source, fallback).filterNotNull()) {
                val path = when {
                    c.startsWith("file://") -> Uri.parse(c).path ?: c.substring("file://".length)
                    c.startsWith("local://") -> c.substring("local://".length)
                    else -> c
                }
                val bmp = try {
                    val mmr = MediaMetadataRetriever()
                    mmr.setDataSource(path)
                    val art = mmr.embeddedPicture
                    mmr.release()
                    if (art != null) BitmapFactory.decodeByteArray(art, 0, art.size) else null
                } catch (e: Exception) {
                    null
                }
                if (bmp != null && !bmp.isRecycled) return bmp
            }
            return null
        }

        /// 兜底封面降采样：与实例方法 resizeBitmap 语义一致（超限才缩放）。
        private fun resizeCoverBitmap(source: Bitmap, maxSize: Int): Bitmap {
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

        fun setFlutterEngine(engine: FlutterEngine) {
            staticFlutterEngine = engine
        }
        /// MD3Music fork（方案1·修复预取通道）：MainActivity 正常运行（前台/后台）时
        /// floating_lyric 通道没有注册 prefetchCover 处理（只在 headless 引擎注册），
        /// 导致 Dart 端 _prefetchUpcomingCovers 的封面预取全部静默失败 → 切歌时封面
        /// 未缓存、只能现场联网下载（慢网/CDN 抖动时明显延迟）。
        /// 此静态入口供 MainActivity 直接调用，写入与实例路径共用的 coverMemoryCache
        /// 与磁盘缓存（cacheDir/cover_cache），切歌时 injectCover/showNotification 命中秒显。
        @JvmStatic
        fun prefetchCovers(context: Context, urls: List<String>) {
            for (url in urls) {
                if (url.isEmpty() || (!url.startsWith("http://") && !url.startsWith("https://"))) continue
                // 内存缓存命中（且未回收）则跳过
                val cached = coverMemoryCache[url]
                if (cached != null && !cached.isRecycled) continue
                if (cached != null && cached.isRecycled) coverMemoryCache.remove(url)
                // 磁盘缓存命中则直接回填内存
                val cacheFile = try {
                    File(File(context.cacheDir, COVER_CACHE_DIR), url.hashCode().toString() + ".jpg")
                } catch (_: Exception) {
                    null
                }
                if (cacheFile != null && cacheFile.exists()) {
                    try {
                        val bmp = BitmapFactory.decodeFile(cacheFile.absolutePath)
                        if (bmp != null && !bmp.isRecycled) {
                            coverMemoryCache[url] = bmp
                            continue
                        }
                    } catch (_: Exception) {}
                }
                // 网路线程下载并写内存 + 磁盘缓存
                Thread {
                    try {
                        val conn = java.net.URL(url).openConnection() as java.net.HttpURLConnection
                        conn.connectTimeout = 3000
                        conn.readTimeout = 5000
                        conn.instanceFollowRedirects = true
                        try {
                            val bmp = BitmapFactory.decodeStream(conn.inputStream)
                            if (bmp != null && !bmp.isRecycled) {
                                val small = if (bmp.width <= 512 && bmp.height <= 512) bmp else {
                                    val ratio = 512.0 / maxOf(bmp.width, bmp.height)
                                    Bitmap.createScaledBitmap(
                                        bmp,
                                        (bmp.width * ratio).toInt(),
                                        (bmp.height * ratio).toInt(),
                                        true
                                    )
                                }
                                if (small !== bmp) bmp.recycle()
                                coverMemoryCache[url] = small
                                try {
                                    val dir = File(context.cacheDir, COVER_CACHE_DIR)
                                    if (!dir.exists()) dir.mkdirs()
                                    val cf = File(dir, url.hashCode().toString() + ".jpg")
                                    if (!cf.exists()) {
                                        FileOutputStream(cf).use { out ->
                                            small.compress(Bitmap.CompressFormat.JPEG, 88, out)
                                        }
                                    }
                                } catch (_: Exception) {}
                                Log.i(TAG, "封面预取完成 url=$url")
                            }
                        } finally {
                            conn.disconnect()
                        }
                    } catch (_: Exception) {}
                }.start()
            }
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
            // 息屏后台网络挂起保护：播放期间同时持有 WifiLock，
            // 避免系统/ROM 在屏幕关闭后把 Wi-Fi 数据通路降级或挂起，
            // 导致切歌时新连接（URL/歌词/封面）全部失败（现象：像断网但没断网）。
            // 与 WakeLock 同生命周期：暂停/停止时由 releaseWakeLock 释放。
            if (wifiLock == null || !wifiLock!!.isHeld) {
                try {
                    val wm = context.getApplicationContext()
                        .getSystemService(Context.WIFI_SERVICE) as WifiManager
                    wifiLock = wm.createWifiLock(
                        WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                        "md3music::audio_playback"
                    )
                    wifiLock?.acquire()
                } catch (_: Exception) {}
            }
        }

        fun releaseWakeLock() {
            wakeLock?.let {
                if (it.isHeld) it.release()
            }
            wakeLock = null
            wifiLock?.let {
                if (it.isHeld) it.release()
            }
            wifiLock = null
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

    private var notificationManager: NotificationManager? = null
    private var receiver: BroadcastReceiver? = null
    private var lockScreenReceiver: BroadcastReceiver? = null
    private var flutterEngine: FlutterEngine? = null
    // Lyricon Provider 是否已 register（restoreLyriconStateIfNeeded 可能被调用多次，需幂等）
    private var lyriconRegistered = false

    // 蓝牙歌词兼容状态。保留通道与设置，但共享 MediaSession 始终使用真实歌曲身份。
    private var bluetoothLyricEnabled = false
    private var currentBtLyricText = ""
    @Volatile
    private var originalMediaId = ""
    private var originalTitle = ""
    private var originalArtist = ""
    @Volatile
    private var metadataGeneration = 0L
    // LyricInfo 歌词转发：缓存整首歌词 JSON（空 = 不发布），
    // 写入 MediaSession 元数据 extras.lyricInfo 供第三方系统读取
    @Volatile
    private var currentLyricInfo = ""
    @Volatile
    private var currentLyricInfoMediaId = ""
    @Volatile
    private var currentLyricSessionGeneration = 0
    // 当前 lyricInfo 是否含可用翻译（colorOs 模式 JSON 有非空 translationLyric）。
    // 决定是否发布 ColorOS 翻译切换按钮（Bridge 在 OPlus 锁屏接管显示）。
    @Volatile
    private var hasLyricTranslation = false
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

    // 方案B阶段1：绑定媒体3会话承载服务，使其 onCreate 注册为 fork 的 host（渲染 now playing 通知）
    private var media3ServiceBound = false
    private val media3ServiceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {}
        override fun onServiceDisconnected(name: ComponentName?) {}
    }

    // P0: 蓝牙歌词刷新状态：最近一次显示的文本（避免无效刷新）
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
        // 方案B阶段1：绑定媒体3会话承载服务（实例化 host，供 fork 会话渲染 now playing 通知）。
        // 用带 SERVICE_INTERFACE action 的 Intent 绑定，确保 onBind 返回非空 binder 使连接成功。
        try {
            val m3Intent = Intent(this, MD3MusicMediaSessionService::class.java)
                .setAction("androidx.media3.session.MediaSessionService")
            bindService(m3Intent, media3ServiceConnection, Context.BIND_AUTO_CREATE)
            media3ServiceBound = true
        } catch (_: Exception) {}
        // 方案B阶段4：注册媒体3自定义命令监听。媒体3通知栏按钮（桌面歌词/收藏）
        // 触发后路由到与既有 ACTION 相同的 Flutter 通道处理逻辑。
        // 阶段6：原生上一首/下一首命令拦截后也走这里，转发 App 自有切歌逻辑。
        try {
            AudioPlayer.setCustomActionListener(object : AudioPlayer.CustomActionListener {
                override fun onToggleDesktopLyric() { handleAction(ACTION_TOGGLE_DESKTOP_LYRIC) }
                override fun onToggleFavorite() { handleAction(ACTION_TOGGLE_FAVORITE) }
                // 阶段6修复：媒体卡片/通知栏原生 PREVIOUS/NEXT → App 自有切歌逻辑
                override fun onPrevious() { handleAction(ACTION_PREV) }
                override fun onNext() { handleAction(ACTION_NEXT) }
            })
        } catch (_: Throwable) {}
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
            ACTION_WIDGET_PLAY_PAUSE, ACTION_WIDGET_NEXT,
            ACTION_WIDGET_FM_PLAY_PAUSE, ACTION_WIDGET_FM_TOGGLE_FAVORITE,
            ACTION_WIDGET_FM_SELECT_STATION, ACTION_WIDGET_FM_OPEN_TRACK,
            ACTION_WIDGET_FM_OPEN_PLAYER -> {
                handleAction(intent)
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
                applyLyricInfoUpdate(
                    intent?.getStringExtra(EXTRA_LYRIC_INFO) ?: "",
                    intent?.getStringExtra(EXTRA_MEDIA_ID) ?: "",
                    intent?.getIntExtra(EXTRA_LYRIC_SESSION_GENERATION, 0) ?: 0,
                    if (intent?.hasExtra(EXTRA_HAS_LYRIC_TRANSLATION) == true)
                        intent.getBooleanExtra(EXTRA_HAS_LYRIC_TRANSLATION, false)
                    else null
                )
                return START_STICKY
            }
            ACTION_REFRESH_FOREGROUND -> {
                // 阶段8：桌面歌词关闭（让位结束），立即恢复保活前台
                refreshKeepaliveForeground()
                return START_STICKY
            }
        }

        val mediaId = intent?.getStringExtra(EXTRA_MEDIA_ID) ?: ""
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

        showNotification(
            mediaId,
            title,
            artist,
            artUrl,
            fallbackFilePath,
            isPlaying,
            position,
            duration,
            desktopLyricEnabled,
            isFavorited
        )

        return START_STICKY
    }

    private fun applyLyricInfoUpdate(
        incomingLyricInfo: String,
        incomingMediaId: String,
        incomingGeneration: Int,
        explicitHasTranslation: Boolean?
    ) {
        if (incomingGeneration > 0 &&
            currentLyricSessionGeneration > 0 &&
            incomingGeneration < currentLyricSessionGeneration) {
            Log.w(
                TAG,
                "Ignored stale lyricInfo generation=$incomingGeneration " +
                    "current=$currentLyricSessionGeneration"
            )
            return
        }
        currentLyricInfo = incomingLyricInfo
        currentLyricInfoMediaId = incomingMediaId
        currentLyricSessionGeneration = incomingGeneration
        hasLyricTranslation = explicitHasTranslation ?: try {
            if (incomingLyricInfo.isEmpty()) false
            else org.json.JSONObject(incomingLyricInfo).let {
                it.optString("translationLyric").isNotEmpty() ||
                    it.optString("translation") == "lrc"
            }
        } catch (_: Exception) {
            false
        }
        Log.i(
            TAG,
            "LyricInfo updated hasTranslation=$hasLyricTranslation " +
                "payloadChars=${currentLyricInfo.length} " +
                "mediaIdMatched=${incomingMediaId.isEmpty() || incomingMediaId == originalMediaId} " +
                "generation=$incomingGeneration"
        )
        refreshMetadata()
    }

    /** MediaSession / 广播接收器的既有入口：只有 action、无参数。 */
    private fun handleAction(action: String) {
        handleAction(Intent().apply { this.action = action })
    }

    private fun handleAction(intent: Intent?) {
        val action = intent?.action ?: return
        val engine = flutterEngine ?: staticFlutterEngine
        if (engine != null) {
            val method = when (action) {
                ACTION_PREV -> "previous"
                ACTION_PLAY_PAUSE, ACTION_WIDGET_PLAY_PAUSE -> "togglePlayPause"
                ACTION_NEXT, ACTION_WIDGET_NEXT -> "next"
                ACTION_TOGGLE_DESKTOP_LYRIC -> "toggleDesktopLyric"
                ACTION_TOGGLE_FAVORITE -> "toggleFavorite"
                // 私人FM小部件动作（PersonalFmWidgetProvider 转发）
                ACTION_WIDGET_FM_PLAY_PAUSE -> "widgetFmPlayPause"
                ACTION_WIDGET_FM_TOGGLE_FAVORITE -> "widgetFmToggleFavorite"
                ACTION_WIDGET_FM_SELECT_STATION -> "widgetFmSelectStation"
                ACTION_WIDGET_FM_OPEN_TRACK -> "widgetFmOpenTrack"
                ACTION_WIDGET_FM_OPEN_PLAYER -> "widgetFmOpenPlayer"
                else -> return
            }
            // FM 动作携带参数：档位下标（Int）/ 歌曲 hash（String），其余为 null
            val args: Any? = when (action) {
                ACTION_WIDGET_FM_SELECT_STATION ->
                    intent.getIntExtra(EXTRA_FM_ACTION_STATION_INDEX, 0)
                ACTION_WIDGET_FM_OPEN_TRACK ->
                    intent.getStringExtra(EXTRA_FM_ACTION_TRACK_HASH)
                else -> null
            }
            MethodChannel(engine.dartExecutor.binaryMessenger, "com.md3music.md3music/floating_lyric")
                .invokeMethod(method, args)
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

    /// 解决方案B阶段5：前台服务保活通知。
    /// 展示层已由媒体3 now-playing 通知（MD3MusicMediaSessionService）承载，本服务仍需保持前台
    /// （后台 Flutter 引擎/WakeLock 保活）。
    ///
    /// 阶段7（关键修复）：不再使用 Android 14+ 的 STOP_FOREGROUND_DETACH。
    /// 实测（2026-08-30）DETACH 移除通知后，系统/部分 ROM 会把服务从 FGS 降级为普通 SVC
    /// （日志：Service.startForeground() not allowed due to mAllowStartForeground false；
    /// uidState: SVC；code:DENIED），此时进程变为后台状态 → 后台网络被系统/ROM 限制 →
    /// 挂后台切歌时 URL/歌词/封面等新连接全部失败（现象：像断网但没断网）。
    /// 改为常驻 startForeground：保活通知走 IMPORTANCE_NONE 渠道（系统不显示、不打扰），
    /// 通知对象持续存在，服务保持 FGS，进程不降级，后台网络不受限。
    private fun startForegroundDetached(builder: NotificationCompat.Builder) {
        // 阶段8：桌面歌词开启期间保活让位——FloatingLyricService 常驻 FGS
        // （1003 可见通知）已撑住进程前台，保活空通知（1002）不再需要，
        // 避免系统里多个前台服务/通知并存。桌面歌词关闭后由
        // ACTION_REFRESH_FOREGROUND 或下一次周期通知更新恢复。
        // 用存活探测而非纯标志位：桌面歌词被系统强杀时 onDestroy 可能未执行、
        // isRunning 残留 true，此时不能继续让位（会失去前台保护）。
        if (isFloatingLyricActuallyRunning()) {
            // 让位给 FloatingLyricService（1003 常驻 FGS 撑住进程前台）。
            // 但 startForegroundService 拉起本服务会产生"5 秒内必须 startForeground"
            // 的系统义务，直接跳过会触发 ForegroundServiceDidNotStartInTimeException
            // 闪退（实测 2026-09-02：桌面歌词运行中暂停/恢复等媒体状态变化重启本服务即崩）。
            // 修复：先挂不可见保活通知履行义务，再立即移除——让位语义不变。
            try {
                startForeground(NOTIFICATION_ID, builder.build())
                try { stopForeground(Service.STOP_FOREGROUND_REMOVE) } catch (_: Throwable) {}
            } catch (_: Throwable) {}
            foregroundStarted = false
            Log.d(TAG, "startForegroundDetached: deferred to FloatingLyricService")
            return
        }
        try {
            startForeground(NOTIFICATION_ID, builder.build())
            foregroundStarted = true
            Log.d(TAG, "startForegroundDetached: foreground kept (no detach)")
        } catch (e: Throwable) {
            // 阶段6修复：导航等 App 夺走音频焦点后本 App 转后台，此时通知更新触发
            // 的服务启动可能被系统拒绝（ForegroundServiceStartNotAllowedException，
            // mAllowStartForeground=false）。必须吞掉并自停，防止：
            // 1) 本次 startForeground 抛异常直接闪退；
            // 2) startForegroundService 已拉起服务但未成功 startForeground 时，
            //    5 秒后触发 RemoteServiceException("did not call startForeground") 二次崩溃。
            // 播放本身由媒体3会话承载（MD3MusicMediaSessionService），本服务自停不影响播放。
            Log.w(TAG, "startForegroundDetached rejected: ${e.javaClass.simpleName}: ${e.message}")
            // MD3Music fork（方案B·封面修复）：仅当服务尚未成功进入前台时才自停
            // （防 startForegroundService 已拉起但未 startForeground 的 5 秒崩溃）。
            // 若服务已在运行（foregroundStarted=true，本次只是通知更新被拒），保留服务，
            // 否则 onDestroy 会 recycle lastArtBitmap，导致后台封面线程注入时
            // bitmap 已被回收（Can't compress a recycled bitmap），封面缺失。
            if (!foregroundStarted) {
                try { stopSelf() } catch (_: Throwable) {}
            }
        }
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
            startForegroundDetached(builder)
        } catch (_: Exception) {}
    }

    /// 阶段8：桌面歌词关闭（让位结束）后立即恢复保活前台。
    /// 复用 KEEPALIVE_CHANNEL_ID 空通知，不等下一次 30s 周期通知更新。
    private fun refreshKeepaliveForeground() {
        if (isFloatingLyricActuallyRunning()) return
        // 仅在播放中恢复保活前台。暂停/已停止不恢复：暂停期间无切歌需求，
        // 且本次 startService 若新建了服务实例（服务已被 stopSelf）应立即自停，
        // 避免「停止播放后关桌面歌词」残留一个常驻前台服务。
        if (!lastIsPlaying) {
            try { stopSelf() } catch (_: Throwable) {}
            return
        }
        try {
            val pendingIntent = launchPendingIntent()
            val builder = NotificationCompat.Builder(this, KEEPALIVE_CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setContentTitle("")
                .setContentText("")
                .setContentIntent(pendingIntent)
                .setOngoing(true)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .setPriority(NotificationCompat.PRIORITY_MIN)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setSilent(true)
            startForegroundDetached(builder)
        } catch (_: Throwable) {}
    }

    /// 阶段8：桌面歌词服务是否真实存活（标志位 + 服务存活探测）。
    /// onDestroy 在进程被系统强杀时可能不执行，标志位会残留，须以服务实况为准。
    private fun isFloatingLyricActuallyRunning(): Boolean {
        if (!FloatingLyricService.isRunning) return false
        return try {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            am.getRunningServices(100)
                .any { it.service.className == FloatingLyricService::class.java.name }
        } catch (_: Exception) {
            true // 探测失败时保守按标志位处理（不打断正常让位）
        }
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
        // MD3Music fork（方向1）：headless 引擎帧的播放器不创建媒体3会话，
        // 使系统仅暴露前台 UI 播放器的会话，杜绝「媒体卡片暂停 vs app 内播放」不同步。
        try { AudioPlayer.setMediaSessionEnabled(false) } catch (_: Throwable) {}
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
                            mediaId = call.argument<String>("songId") ?: "",
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
                    "updateLyricInfo" -> {
                        applyLyricInfoUpdate(
                            call.argument<String>("lyricInfo") ?: "",
                            call.argument<String>("songId") ?: "",
                            call.argument<Int>("sessionGeneration") ?: 0,
                            call.argument<Boolean>("hasTranslation")
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
                    "prefetchCover" -> {
                        // 方案B：Dart 切歌前预取后续歌曲封面到本地缓存，切歌时秒显。
                        val urls = call.argument<List<String>>("urls").orEmpty()
                        urls.forEach { prefetchCover(it) }
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
                    "updateLockScreenLyricData" -> {
                        LockScreenLyricActivity.applyDataCall(call)
                        result.success(true)
                    }
                    "updateLockScreenProgress" -> {
                        LockScreenLyricActivity.applyProgressCall(call)
                        result.success(true)
                    }
                    "updateLockScreenAccent" -> {
                        LockScreenLyricActivity.applyAccentCall(call)
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
            // 音量均衡通道：headless 引擎同样需要，播放/AudioService 在此 isolate 运行。
            registerVolumeNormalizationChannel(engine)
            // Lyrico 外部编辑通道：UI 可能复用 headless 引擎，缺了会 MissingPluginException
            ExternalEditorPlugin(applicationContext).register(engine)
        } catch (_: Exception) {}
    }

    /// 注册音量均衡 MethodChannel：把当前歌曲响度归一增益（dB）广播给 AudioSink 增益装饰器。
    private fun registerVolumeNormalizationChannel(engine: FlutterEngine) {
        try {
            MethodChannel(
                engine.dartExecutor.binaryMessenger,
                "com.md3music.md3music/volume_normalization"
            ).setMethodCallHandler { call, result ->
                when (call.method) {
                    "setGainDb" -> {
                        val db = call.argument<Double>("gainDb") ?: 0.0
                        com.ryanheise.just_audio.NormalizationGainAudioSink.setGlobalGainDb(db)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        } catch (_: Exception) {}
    }

    fun setFlutterEngine(engine: FlutterEngine) {
        flutterEngine = engine
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
                    // 阶段6：重要度改为 MIN（保活通知彻底隐藏/最小化），旧渠道需删除重建
                    if (existingChannel.importance != NotificationManager.IMPORTANCE_MIN ||
                        existingChannel.sound != null) {
                        manager.deleteNotificationChannel(CHANNEL_ID)
                    }
                }
            } catch (_: Exception) {}
            
            // 创建静音通知渠道 - 修复荣耀/vivo 手机通知提示音问题
            // 阶段7：IMPORTANCE_MIN + 常驻 startForeground（不 DETACH），保活通知只出现在
            // 折叠的「其他通知」区（或 DETACH 已移除的旧行为不再使用），不产生打扰；
            // 渠道静音（setSound null）避免部分 ROM 通知「叮咚响」。
            val channel = NotificationChannel(
                CHANNEL_ID,
                "音乐播放",
                NotificationManager.IMPORTANCE_MIN
            ).apply {
                description = "音乐播放控制（静默保活）"
                setShowBadge(false)
                lockscreenVisibility = NotificationCompat.VISIBILITY_PRIVATE
                // 关键修复：禁用声音和震动
                setSound(null, null)
                enableVibration(false)
            }
            manager.createNotificationChannel(channel)

            // 保活通知专用频道：IMPORTANCE_NONE 使「播放保活」在系统
            // 「应用信息 → 通知」里默认关闭（不显示、不打扰），用户仍可手动开启。
            try {
                val existingKeepalive = manager.getNotificationChannel(KEEPALIVE_CHANNEL_ID)
                if (existingKeepalive != null &&
                    existingKeepalive.importance != NotificationManager.IMPORTANCE_NONE) {
                    // 渠道一旦创建 importance 不可改，必须先删重建让默认关闭生效
                    manager.deleteNotificationChannel(KEEPALIVE_CHANNEL_ID)
                }
                manager.createNotificationChannel(
                    NotificationChannel(
                        KEEPALIVE_CHANNEL_ID,
                        "播放保活",
                        NotificationManager.IMPORTANCE_NONE
                    ).apply {
                        description = "静默保活（不显示）"
                        setShowBadge(false)
                        lockscreenVisibility = NotificationCompat.VISIBILITY_PRIVATE
                        setSound(null, null)
                        enableVibration(false)
                    }
                )
            } catch (_: Exception) {}
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

    // ===== 方案A：在线封面本地缓存（根治切歌空档） =====

    private fun coverCacheFile(artUrl: String): File? {
        return try {
            val dir = File(cacheDir, COVER_CACHE_DIR)
            if (!dir.exists()) dir.mkdirs()
            File(dir, artUrl.hashCode().toString() + ".jpg")
        } catch (_: Exception) {
            null
        }
    }

    /// 从缓存取封面：先内存后磁盘，命中即返回（同步、无需网络）。
    private fun getCachedCover(artUrl: String): Bitmap? {
        coverMemoryCache[artUrl]?.let { return it }
        val cacheFile = coverCacheFile(artUrl) ?: return null
        if (cacheFile.exists()) {
            return try {
                val bmp = BitmapFactory.decodeFile(cacheFile.absolutePath)
                if (bmp != null) {
                    coverMemoryCache[artUrl] = bmp
                    Log.d(TAG, "封面磁盘缓存命中 url=$artUrl")
                }
                bmp
            } catch (_: Exception) {
                null
            }
        }
        return null
    }

    /// 将封面写入磁盘缓存 + 内存缓存；超过上限时清理最旧文件。
    private fun putCoverCache(artUrl: String, bmp: Bitmap) {
        try {
            coverMemoryCache[artUrl] = bmp
            val cacheFile = coverCacheFile(artUrl) ?: return
            if (!cacheFile.exists()) {
                FileOutputStream(cacheFile).use { out ->
                    bmp.compress(Bitmap.CompressFormat.JPEG, 88, out)
                    out.flush()
                }
            }
            // 限制磁盘缓存数量：清空最旧文件
            try {
                val dir = File(cacheDir, COVER_CACHE_DIR)
                val files = dir.listFiles()?.filter { it.isFile } ?: emptyList()
                if (files.size > COVER_CACHE_MAX) {
                    files.sortedBy { it.lastModified() }
                        .take(files.size - COVER_CACHE_MAX)
                        .forEach { it.delete() }
                }
            } catch (_: Exception) {}
        } catch (_: Exception) {}
    }

    /// 主动预取封面到缓存（方案B：进入下一首前调用，命中后切歌秒显）。
    private fun prefetchCover(artUrl: String?) {
        if (artUrl.isNullOrEmpty()) return
        if (!artUrl.startsWith("http://") && !artUrl.startsWith("https://")) return
        if (getCachedCover(artUrl) != null) return  // 已缓存，无需下载
        // 网路线程下载并写入缓存，不阻塞播放
        Thread {
            try {
                val conn = java.net.URL(artUrl).openConnection() as java.net.HttpURLConnection
                conn.connectTimeout = 3000
                conn.readTimeout = 5000
                conn.instanceFollowRedirects = true
                try {
                    val bmp = BitmapFactory.decodeStream(conn.inputStream)
                    if (bmp != null) {
                        val small = resizeBitmap(bmp, 512)
                        if (small !== bmp) bmp.recycle()
                        putCoverCache(artUrl, small)
                        Log.d(TAG, "封面预取完成 url=$artUrl")
                    }
                } finally {
                    conn.disconnect()
                }
            } catch (_: Exception) {}
        }.start()
    }

    /// 根据 URI 类型加载封面 Bitmap，支持：
    /// - http(s):// → URL 下载（在线音乐）
    /// - content:// → ContentResolver 加载（MediaStore albumart）
    /// - local://<path> → 提取文件路径，用 MediaMetadataRetriever 读内嵌封面
    /// - file://<path> → 转为文件路径，用 MediaMetadataRetriever 读内嵌封面
    /// - 纯文件路径 → 直接用 MediaMetadataRetriever 读内嵌封面
    /// [fallbackFilePath] 在所有方式失败后作为最终回退
    private fun loadArtworkBitmap(artUri: String, fallbackFilePath: String?): Bitmap? {
        // 1. http(s):// 在线封面（方案A：优先本地缓存，命中免下载秒显）
        if (artUri.startsWith("http://") || artUri.startsWith("https://")) {
            // 缓存命中：内存或磁盘，直接返回（切歌空档的根治关键）
            getCachedCover(artUri)?.let { return it }
            return try {
                // P0: HttpURLConnection 显式设置超时，避免慢响应导致线程永久阻塞
                val conn = java.net.URL(artUri).openConnection() as java.net.HttpURLConnection
                conn.connectTimeout = 5000
                conn.readTimeout = 10000
                conn.instanceFollowRedirects = true
                try {
                    val bmp = BitmapFactory.decodeStream(conn.inputStream)
                    if (bmp != null) {
                        Log.i(TAG, "封面 http 下载成功 ${bmp.width}x${bmp.height} url=$artUri")
                        // 写入本地缓存，下次切到同歌秒显
                        putCoverCache(artUri, bmp)
                    } else {
                        Log.w(TAG, "封面 http 解码失败(响应非图片/空流) url=$artUri")
                    }
                    bmp
                } finally {
                    conn.disconnect()
                }
            } catch (e: Exception) {
                // 封面链路日志：网络波动/超时会造成这里 null→MediaSession 无 bitmap，正是偶现失效点
                Log.w(TAG, "封面 http 下载异常 ${e.message} url=$artUri")
                null
            }
        }

        // 2. content:// MediaStore albumart
        if (artUri.startsWith("content://")) {
            try {
                val uri = Uri.parse(artUri)
                contentResolver.openInputStream(uri)?.use { input ->
                    val bmp = BitmapFactory.decodeStream(input)
                    if (bmp != null) {
                        Log.i(TAG, "封面 content 加载成功 ${bmp.width}x${bmp.height} url=$artUri")
                    } else {
                        Log.w(TAG, "封面 content 解码失败 url=$artUri")
                    }
                    return bmp
                }
            } catch (e: Exception) {
                Log.w(TAG, "封面 content 加载异常 ${e.message} url=$artUri")
            }
            // content:// 加载失败，回退到 fallbackFilePath 提取内嵌封面
            if (!fallbackFilePath.isNullOrEmpty()) {
                Log.d(TAG, "封面 content 失败，回退内嵌封面 fallback=$fallbackFilePath")
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
                val bmp = BitmapFactory.decodeFile(filePath)
                if (bmp != null) {
                    Log.i(TAG, "封面文件解码成功 ${bmp.width}x${bmp.height} path=$filePath")
                } else {
                    Log.w(TAG, "封面文件解码失败(空/损坏) path=$filePath")
                }
                bmp
            } catch (e: Exception) {
                Log.w(TAG, "封面文件解码异常 ${e.message} path=$filePath")
                null
            }
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
            if (art != null) {
                val bmp = BitmapFactory.decodeByteArray(art, 0, art.size)
                if (bmp != null) {
                    Log.i(TAG, "内嵌封面提取成功 ${bmp.width}x${bmp.height} src=$filePath")
                } else {
                    Log.w(TAG, "内嵌封面字节解码失败 src=$filePath")
                }
                bmp
            } else {
                Log.w(TAG, "内嵌封面不存在(embeddedPicture=null) src=$filePath")
                null
            }
        } catch (e: Exception) {
            Log.w(TAG, "内嵌封面提取异常 ${e.message} src=$filePath")
            null
        } finally {
            // P0: 异常路径也必须释放 native 资源，避免 FD 泄漏
            try { retriever.release() } catch (_: Exception) {}
        }
    }

    private fun showNotification(
        mediaId: String,
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
        if (mediaId.isNotEmpty() && mediaId != originalMediaId) {
            originalMediaId = mediaId
            metadataGeneration++
            if (currentLyricInfoMediaId.isNotEmpty() &&
                currentLyricInfoMediaId != mediaId) {
                currentLyricInfo = ""
                hasLyricTranslation = false
                lastShownLyricInfo = ""
            }
        }
        val requestMediaId = mediaId.ifEmpty { originalMediaId }
        val requestGeneration = metadataGeneration
        // 缓存稳定歌曲元数据。蓝牙歌词不能再覆盖 SystemUI 正在消费的同一 MediaSession。
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
        // 方案B阶段4：随通知更新把桌面歌词/收藏状态推到媒体3会话（渲染成通知栏按钮）。
        pushMedia3CustomActions(
            desktopLyricEnabled,
            isFavorited,
            hasTranslationForCurrentTrack()
        )
        val displayTitle = originalTitle
        val displayArtist = originalArtist

        // 点击保活通知回到 App（懒加载一次，后续共用）
        val pendingIntent = launchPendingIntent()

        // 方案B阶段5：自定义 MediaSessionCompat 已移除，展示层由媒体3 now-playing 通知承载。
        // 本服务仍须 startForeground 保持前台（Android 8+ 硬性要求），故构建「静默保活通知」：
        // 阶段7：内容置空 + IMPORTANCE_NONE 频道常驻（不 DETACH，避免服务被系统降级为 SVC）。
        val builder = NotificationCompat.Builder(this, KEEPALIVE_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("")          // 空内容：IMPORTANCE_NONE 渠道系统不显示
            .setContentText("")
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPriority(NotificationCompat.PRIORITY_MIN)  // 最小打扰，避免与媒体3通知并列醒目
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setSilent(true)

        // 封面加载：支持 http(s):// / content:// / local:// / file:// / 文件路径
        val effectiveArtUrl = artUrl ?: fallbackFilePath

        // 先立即进入前台（保活通知常驻，避免 startForegroundService 的 5 秒限制；
        // 不再 DETACH，防止服务被系统降级导致后台网络受限）；
        // 元数据由媒体3会话注入（见下），无需本服务发布 MediaSession 元数据。
        startForegroundDetached(builder)
        scheduleMetadataRefresh()

        // P0: 不再广播「无 bitmap」的首帧 metadata——SystemUI 控制中心主面板
        // MainPanelItemViewHolder 会先 setCover(null) 并在 flip 动画中吞掉后续补帧，
        // 导致封面永远停在无封面。改为封面加载成功后再一次性 setMetadata(带 bitmap)，
        // 使 SystemUI 首次拿到 metadata 即带封面；仅封面失败/无源时才发无封面兜底。
        if (!effectiveArtUrl.isNullOrEmpty()) {
            Log.d(TAG, "触发后台封面加载 effectiveArtUrl=$effectiveArtUrl fallback=$fallbackFilePath")
            Thread {
                try {
                    val originalBitmap = loadArtworkBitmap(effectiveArtUrl, fallbackFilePath)
                    if (originalBitmap != null) {
                        if (!isMetadataRequestCurrent(requestMediaId, requestGeneration)) {
                            Log.i(
                                TAG,
                                "Discarded stale artwork result mediaIdHash=${requestMediaId.hashCode()}"
                            )
                            return@Thread
                        }
                        // P0: 统一降采样到 512px 后再缓存/使用，避免原始大图（2000x2000+）常驻内存
                        val displayBitmap = resizeBitmap(originalBitmap, 512)
                        // MD3Music fork：仅回收「非缓存」的原图。loadArtworkBitmap 命中内存/磁盘
                        // 缓存时返回的是 coverMemoryCache 里的共享对象，recycle 它会污染缓存，
                        // 导致后续 loadArtworkBitmap / injectCover 命中已回收位图 → 封面加载失败
                        // / resizeBitmap 抛 IllegalStateException。
                        val sharedCacheEntry = coverMemoryCache[effectiveArtUrl]
                        if (displayBitmap !== originalBitmap && originalBitmap !== sharedCacheEntry) {
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

                        // 封面同步注入 just_audio 的媒体3 会话（该会话无封面，播放中会被 SystemUI
                        // 提为控制中心顶层）。用官方 replaceMediaItem 同 uri 替换当前 MediaItem，
                        // 只更新 metadata 不打断播放，保证控制中心/媒体3通知栏选中媒体3 会话时也有封面。
                        // 阶段2：改为直接强依赖调用（已通过 media3-common 建立编译类路径），
                        // 移除原反射的静默吞错（catch Throwable），使封面注入失败可被日志暴露。
                        AudioPlayer.updateActiveSessionMetadata(
                            requestMediaId,
                            requestGeneration,
                            displayTitle,
                            displayArtist,
                            displayBitmap,
                            effectiveArtUrl
                        )
                        Log.i(TAG, "封面后台加载完成，已注入媒体3会话 bitmap=${displayBitmap.width}x${displayBitmap.height}")
                    } else {
                        // 封面链路日志：所有来源均失败 → MediaSession 无 bitmap
                        Log.w(TAG, "封面后台加载失败(所有来源返回 null) effectiveArtUrl=$effectiveArtUrl " +
                                "MediaSession 将缺失 ART bitmap")
                        // 封面确实失败：兜底同步标题到媒体3会话（媒体3 Metadata 由 ExoPlayer
                        // 播放内容自驱动，此处仅保证标题/艺术家正确）
                        AudioPlayer.updateActiveSessionTitleArtist(
                            requestMediaId, requestGeneration, displayTitle, displayArtist)
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "封面后台线程异常 ${e.message}", e)
                    // 异常也兜底同步标题到媒体3会话
                    AudioPlayer.updateActiveSessionTitleArtist(
                        requestMediaId, requestGeneration, displayTitle, displayArtist)
                }
            }.start()
        } else {
            Log.w(TAG, "无有效封面源(artUrl、fallback 均为空)，MediaSession 无封面")
            // 无封面源：同步标题到媒体3会话（保证标题/艺术家正确）
            AudioPlayer.updateActiveSessionTitleArtist(
                requestMediaId, requestGeneration, displayTitle, displayArtist)
        }

        // 同步播放状态到 Lyricon：必须走 Auto PlaybackState（带 position+speed 时间戳）。
        // 不能调 Boolean 重载 / setPosition / seekTo，否则会切回 Manually 并 seek 到
        // 旧位置（lastPosition=0），导致歌词每隔一次同步就闪回开头。
        try {
            lyriconProvider?.player?.setPlaybackState(
                buildLyriconPlaybackState(position, isPlaying)
            )
        } catch (_: Exception) {}
    }

    /// 方案B阶段4：把当前桌面歌词/收藏状态推给媒体3会话，渲染为通知栏自定义按钮。
    /// 图标资源在 app 模块（R.drawable），fork 仅持有 command/回调，不依赖资源。
    /// 阶段6：下一首已改回 media3 原生按钮，这里保留 翻译(可选)/桌面歌词/收藏。
    /// 翻译按钮仅在 hasLyricTranslation 时发布（ColorOS Bridge 消费）；占位图标必须是
    /// 包内有效资源（CustomAction.Builder 需要有效 iconResId，SystemUI 建立 Action 时
    /// 先解析该资源）。Bridge 识别 Action 后会换成自己的标准翻译图标。
    private fun pushMedia3CustomActions(
        desktopLyricEnabled: Boolean,
        isFavorited: Boolean,
        hasTranslation: Boolean,
    ) {
        try {
            AudioPlayer.setActiveSessionCustomActions(
                desktopLyricEnabled, isFavorited, hasTranslation,
                R.drawable.ic_translation,
                R.drawable.ic_lyric_on, R.drawable.ic_lyric_off,
                R.drawable.ic_favorite_on, R.drawable.ic_favorite_off,
            )
        } catch (e: Throwable) {
            Log.w(TAG, "pushMedia3CustomActions failed: ${e.message}", e)
        }
    }

    /// 蓝牙歌词轻量刷新：歌词行变化或开关切换时，复用缓存的 bitmap 和播放状态
    /// 重建通知和 MediaSession 元数据，不重新下载封面。
    /// 仅在 showNotification 至少被调用过一次后有效（originalTitle 非空判定）。
    private fun refreshMetadata() {
        val effectiveLyricInfo = lyricInfoForCurrentTrack()
        val lyricInfoChanged = effectiveLyricInfo != lastShownLyricInfo
        if (originalTitle.isEmpty() && originalArtist.isEmpty()) {
            // 阶段6修复：标题/艺术家尚未由 showNotification 设置（如冷启动恢复播放态时
            // lyricInfo 推送先于首次通知更新到达）时，不能整体 return——否则本次 lyricInfo
            // 被丢弃。Dart 端每首歌只推一次（_lyricInfoPushed 去重），丢弃后不再重试，
            // 该曲的 lyricInfo 就永久丢失。此处仅当 lyricInfo 无变化才跳过。
            if (!lyricInfoChanged) return
            lastShownLyricInfo = effectiveLyricInfo
            scheduleMetadataRefresh()
            return
        }
        // Bluetooth AVRCP 与 SystemUI 共用该 MediaSession；为保证锁屏曲目身份稳定，
        // 这里始终发布真实歌名/歌手，不再逐句改写 TITLE/ARTIST。
        val displayTitle = originalTitle
        val displayArtist = originalArtist

        // P0: 文本未变化（歌词行未变 / 开关未切换）时直接跳过，避免无效刷新。
        // 但 LyricInfo 歌词转发（currentLyricInfo 变化）不依赖 title/artist 变化，
        // 即使 title/artist 未变也需要更新 MediaSession 元数据以写入 extras.lyricInfo，
        // 因此本跳过逻辑仅在 lyricInfo 不变时生效。
        if (displayTitle == lastShownBtLyricTitle && displayArtist == lastShownBtLyricArtist && !lyricInfoChanged) return
        lastShownBtLyricTitle = displayTitle
        lastShownBtLyricArtist = displayArtist
        lastShownLyricInfo = effectiveLyricInfo

        // 方案B阶段5：保活通知走 IMPORTANCE_NONE 渠道（系统不显示），
        // 不再在此显式 notify（否则第二条无封面卡片会重新出现，造成"封面消失"观感）。
        // 展示层完全交给媒体3 now-playing 通知（有封面/控制按钮）。

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
        val mediaId = originalMediaId
        if (mediaId.isEmpty()) return
        val displayTitle = originalTitle
        val displayArtist = originalArtist
        val effectiveLyricInfo = lyricInfoForCurrentTrack()
        // 方案B阶段5：自定义会话已移除，不再 setMetadata。
        // 媒体3会话的元数据（标题/艺术家/封面/LyricInfo）由下方 updateActiveSession* 同步，
        // 播放态由 ExoPlayer 自动驱动系统媒体卡片；封面压缩开关不再影响 MediaSession 下发。
        // 根因3修复：标题/艺术家 与 extras.lyricInfo 合并为一次 replaceMediaItem，
        // 消除 OPlus 防抖窗口内紧邻补丁导致的 lyricInfo 丢弃（within debounce period, ignore）。
        // 一次提交稳定 title/artist 与当前歌曲匹配的 lyricInfo。
        AudioPlayer.updateActiveSessionTitleArtistAndLyricInfo(
            mediaId,
            metadataGeneration,
            displayTitle,
            displayArtist,
            effectiveLyricInfo
        )
        // 方案B阶段4：按当前开关状态渲染媒体3通知栏的自定义按钮（桌面歌词/收藏）。
        pushMedia3CustomActions(
            lastDesktopLyricEnabled,
            lastIsFavorited,
            hasTranslationForCurrentTrack()
        )
    }

    private fun lyricInfoForCurrentTrack(): String {
        if (currentLyricInfo.isEmpty()) return ""
        return if (currentLyricInfoMediaId.isEmpty() ||
            currentLyricInfoMediaId == originalMediaId) currentLyricInfo else ""
    }

    private fun hasTranslationForCurrentTrack(): Boolean =
        lyricInfoForCurrentTrack().isNotEmpty() && hasLyricTranslation

    private fun isMetadataRequestCurrent(mediaId: String, generation: Long): Boolean =
        mediaId.isNotEmpty() &&
            mediaId == originalMediaId &&
            generation == metadataGeneration

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
        // 方案B阶段1：解除媒体3会话承载服务绑定，并让 fork 注销 host
        if (media3ServiceBound) {
            try {
                unbindService(media3ServiceConnection)
            } catch (_: Exception) {}
            media3ServiceBound = false
        }
        // 方案B阶段4：注销媒体3自定义命令监听
        try {
            AudioPlayer.setCustomActionListener(null)
        } catch (_: Throwable) {}
        super.onDestroy()
    }
}
