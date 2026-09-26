package com.md3music.md3music

import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 魅族 Flyme 状态栏歌词桥接。
 *
 * 机制：Flyme 复用了 Android 的 Notification.tickerText —— 当通知的 flags 带上两个
 * Flyme 私有位（0x01000000 常驻、0x02000000 只刷新 ticker）时，Flyme SystemUI 会把
 * tickerText 渲染到状态栏左侧的专用区域。AOSP 不认识这两位，故 dumpsys 显示为
 * UNKNOWN(0x03000000)。
 *
 * 关键约束（真机抓取酷狗行为确认）：歌词必须挂在**正在播放的那条媒体通知**上，复用它的
 * id 与 channel，原地改 tickerText/flags 后重新 notify。另起一条通知会在下拉栏出现
 * 两个播放器，且 Flyme 不渲染。媒体通知由 Media3 生成，App 侧通过
 * MD3MusicMediaSessionService 里的包装 Provider 拿到它的对象与 id。
 *
 * 节流：Android 与 Flyme 对 notify() 有频率限制，逐字刷新会导致 SystemUI 掉帧甚至通道
 * 被封闭。调用方（Dart DesktopLyricService）已保证只在 LRC 行切换时推送，此处不再二次
 * 节流。
 *
 * 线程：attach/decorate/repost 三个入口分别来自 Media3 的 provider 回调、Dart 的
 * MethodChannel、以及 NotificationManager。本 App 的 ExoPlayer 未设置自定义
 * applicationLooper，MediaNotificationManager 也用主 Looper，因此三者都在平台主线程上，
 * 不构成竞态。**若将来有人给 player 设了非主线程的 applicationLooper，下面的
 * `n.flags = n.flags or f` 就是共享对象上的读-改-写，需要加锁。**
 */
object FlymeLyricBridge {

    private const val TAG = "FlymeStatusBarLyric"

    /** 公开文档给出的值：Flyme 状态栏 ticker 一直显示，直到下一次更新 */
    private const val FLAG_ALWAYS_SHOW_TICKER = 0x01000000

    /** 公开文档给出的值：只更新 ticker，不重绘通知其余内容 */
    private const val FLAG_ONLY_UPDATE_TICKER = 0x02000000

    private const val FLYME_TICKER_FLAGS =
        FLAG_ALWAYS_SHOW_TICKER or FLAG_ONLY_UPDATE_TICKER

    const val CHANNEL_NAME = "com.md3music.md3music/flyme_status_bar_lyric"

    /** 与 Dart 侧 SettingsRepository 共用同一个 SharedPreferences 命名空间 */
    private const val PREFS = "FlutterSharedPreferences"
    private const val PREF_KEY = "flutter.settings_flyme_status_bar_lyric_enabled"

    @Volatile
    private var enabled = false

    @Volatile
    private var currentLyric = ""

    /** Media3 最近一次**真正交出去渲染**的媒体通知及其 id。只在同步返回路径更新 */
    @Volatile
    private var mediaNotification: Notification? = null

    @Volatile
    private var mediaNotificationId = -1

    /**
     * 该 id 是否曾被确认出现在 activeNotifications 里。
     * 用于区分"还没 post 出去"（跳过但保留缓存）与"post 过又被撤下"（丢弃缓存）。
     */
    @Volatile
    private var postedConfirmed = false

    @Volatile
    private var appContext: Context? = null

    /** 仅用公开 API 判定厂商，供设置页展示与兜底 */
    fun isFlymeDevice(): Boolean {
        val display = Build.DISPLAY ?: ""
        if (display.contains("flyme", ignoreCase = true)) return true
        return Build.MANUFACTURER.equals("meizu", ignoreCase = true) ||
                Build.BRAND.equals("meizu", ignoreCase = true)
    }

    /**
     * 反射读设备上 Flyme 私加字段的**真实值**。
     *
     * 魅族官方文档的判定口径就是"这两个 flag 不存在则机型不支持"，比猜厂商准确：
     * 既能认出移植了该机制的非 Flyme ROM，也能识别 Flyme 自己砍掉该特性的版本。
     */
    private val deviceFlags: Int? by lazy {
        try {
            val a = Notification::class.java.getField("FLAG_ALWAYS_SHOW_TICKER").getInt(null)
            val b = Notification::class.java.getField("FLAG_ONLY_UPDATE_TICKER").getInt(null)
            a or b
        } catch (t: Throwable) {
            Log.d(TAG, "反射读 Flyme flag 失败: ${t.javaClass.simpleName}")
            null
        }
    }

    /** 综合判定：反射拿到字段（直接证据）或厂商为魅族（兜底）都算支持 */
    fun isSupported(): Boolean = deviceFlags != null || isFlymeDevice()

    /** 优先用设备真实值；读不到再回落到文档公开常量 */
    private fun effectiveFlags(): Int = deviceFlags ?: FLYME_TICKER_FLAGS

    /**
     * 缓存媒体通知并贴上当前歌词。**只能用于 Provider.createNotification 的同步返回路径** ——
     * 那条路径的对象确定会被 Media3 发出去。
     *
     * 异步 artwork 回调路径必须改用 decorateOnly()：那条路径带序列号守卫，对象可能被 Media3
     * 丢弃；若在此缓存，之后每句歌词都会把状态栏翻回上一首的卡片，而 Media3 以为自己发的
     * 是最新的，永不自愈。
     */
    fun attach(context: Context, notificationId: Int, notification: Notification) {
        // 诊断用：Media3 在播放态/timeline/元数据/自定义按钮变化时都会重建并重发通知，
        // 每次都会走到这里。若同一句歌词在此期间被重新 post，Flyme 会把 marquee 从头
        // 再滚一遍 —— 表现即"字没变却又滚了一次"。真机用 `adb logcat -s FlymeStatusBarLyric`
        // 数这条的次数，即可与 Dart 侧的重推区分开。只记录，不拦截。
        if (enabled && currentLyric.isNotEmpty()) {
            Log.d(TAG, "媒体通知被重建，歌词未变仍会重贴 ticker=[$currentLyric]")
        }
        appContext = context.applicationContext
        // 换绑新对象/新 id 时重置确认位：否则上一首残留的 true 会让新歌在
        // "尚未 post"的窗口里被误判为"已被撤下"，进而清空缓存导致歌词出不来
        if (mediaNotificationId != notificationId || mediaNotification !== notification) {
            postedConfirmed = false
        }
        mediaNotificationId = notificationId
        mediaNotification = notification
        decorate(notification)
    }

    /** 只贴歌词、不更新缓存。用于可能被丢弃的异步重发路径 */
    fun decorateOnly(notification: Notification) {
        decorate(notification)
    }

    /** Dart 推送当前歌词行。空串等价于清空。 */
    fun updateLyric(lyric: String?) {
        // 关闭状态下不做任何事：否则每句歌词都会白跑一次 notify()，
        // 而 Dart 侧的 catch 会把这种无效调用完全掩盖掉
        if (!enabled) return
        val text = lyric?.trim().orEmpty()
        if (text == currentLyric) return
        currentLyric = text
        val n = mediaNotification ?: run {
            Log.d(TAG, "媒体通知尚未就绪，丢弃本次歌词")
            return
        }
        decorate(n)
        repost(n)
    }

    fun setEnabled(context: Context, value: Boolean) {
        appContext = context.applicationContext
        // 原生侧也做一次门控：设备不支持时强制关闭，避免挂上系统不认的私有 flag
        val effective = value && isSupported()
        if (value && !effective) {
            Log.i(TAG, "设备不支持状态栏歌词，忽略开启请求")
        }
        val changed = enabled != effective
        enabled = effective
        try {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                    .edit().putBoolean(PREF_KEY, effective).apply()
        } catch (_: Exception) {
        }
        if (!effective) {
            currentLyric = ""
        }
        // 开启与关闭都要立即重发。若只在关闭时重发，播放中途打开开关会没反应：
        // Dart 紧接着回灌当前行，却被 updateLyric 的"同一行早退"去重吞掉，
        // 表现为要等到下一句歌词才生效。
        if (changed || !effective) {
            mediaNotification?.let { decorate(it); repost(it) }
        }
    }

    /** 进程被 MediaSession 唤醒、但 Dart 还没来得及回灌开关时，先从偏好里恢复 */
    fun restoreFromPrefs(context: Context) {
        appContext = context.applicationContext
        val stored = try {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                    .getBoolean(PREF_KEY, false)
        } catch (_: Exception) {
            false
        }
        // 与 setEnabled 同口径：偏好可能来自备份/迁移，仍要过一遍能力门控
        val was = enabled
        enabled = stored && isSupported()
        // attach() 可能早于本方法执行（那时 enabled 还是 false，通知上没贴歌词），
        // 状态翻成 true 时必须补一次重发，否则歌词要等到下一句才出现
        if (!was && enabled) {
            mediaNotification?.let { decorate(it); repost(it) }
        }
    }

    private fun decorate(n: Notification) {
        val f = effectiveFlags()
        val show = enabled && currentLyric.isNotEmpty()
        if (show) {
            n.tickerText = currentLyric
            n.flags = n.flags or f
        } else {
            n.tickerText = ""
            n.flags = n.flags and f.inv()
        }
        // 刻意不额外设置 FLAG_NO_CLEAR：暂停时 tickerText 仍在，若钉住 NO_CLEAR
        // 会让播放通知在暂停期间永久不可划走。媒体通知本身已有 ONGOING_EVENT 保护。
    }

    private fun repost(n: Notification) {
        val ctx = appContext ?: return
        if (mediaNotificationId < 0) return
        try {
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val active = nm.activeNotifications.any { it.id == mediaNotificationId }

            if (active) {
                postedConfirmed = true
            } else if (!postedConfirmed) {
                // attach() 发生在 Media3 真正 post 之前，这个窗口里必然查不到。
                // 此时只跳过本次重发、保留缓存：下一句歌词自然补上。
                // 若在此清空缓存，缓存要等到下次 createNotification 才重建，
                // 表现为歌词可能永远出不来，除非暂停再播放。
                Log.d(TAG, "通知 ${mediaNotificationId} 尚未确认在册，跳过本次重发但保留缓存")
                return
            } else {
                // 曾经在册、现在消失 => 已被 Media3/系统 cancel。
                // 再 notify 会把一张 PendingIntent 已释放的死通知复活，且无人负责取消它。
                Log.d(TAG, "通知 ${mediaNotificationId} 已被撤下，丢弃缓存")
                mediaNotification = null
                mediaNotificationId = -1
                postedConfirmed = false
                return
            }
            nm.notify(mediaNotificationId, n)
        } catch (e: Exception) {
            Log.w(TAG, "notify 失败: ${e.javaClass.simpleName}: ${e.message}")
        }
    }

    /** 供 MainActivity 与 headless 引擎共用 */
    fun registerChannel(engine: FlutterEngine, context: Context) {
        restoreFromPrefs(context)
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL_NAME)
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "isFlymeStatusBarLyricSupported" -> result.success(isSupported())
                        "setFlymeStatusBarLyricEnabled" -> {
                            setEnabled(context, call.argument<Boolean>("enabled") ?: false)
                            result.success(true)
                        }
                        "updateFlymeStatusBarLyric" -> {
                            updateLyric(call.argument<String>("lyric"))
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                }
    }
}
