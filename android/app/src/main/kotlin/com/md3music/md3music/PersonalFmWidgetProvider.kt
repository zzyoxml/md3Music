package com.md3music.md3music

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.BitmapShader
import android.graphics.Shader
import android.os.Bundle
import android.util.Log
import android.util.LruCache
import android.view.View
import android.widget.RemoteViews
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL

/**
 * 私人FM桌面小组件：1:1 复刻发现页 PersonalFmSection 卡片。
 *
 * 数据流与异常处理对齐 [MusicWidgetProvider]：
 * - Flutter（FmWidgetSync）经 MethodChannel 推送快照 → 广播 ACTION_FM_UPDATE_WIDGET
 *   → 遍历实例重绘 RemoteViews；快照字段缓存于 companion，封面就绪的重绘
 *   （ACTION_FM_COVER_READY）与进程重启后的 onUpdate 均复用缓存渲染。
 * - 按钮 → PendingIntent 广播 → try-catch startService 转发 AudioPlaybackService
 *   → MethodChannel 调 Flutter；无可用引擎时拉起 app 兜底（不崩溃、静默降级）。
 * - 档位抽屉开合是纯 UI 状态，由 [fmDrawerOpen] 本地维护，不经 Flutter。
 * - 主题色由快照携带（color_* extras），原生缓存；从未收到推送时用 Material 3
 *   基准紫兜底。圆角底统一用「ImageView + 白色 shape + setColorFilter」实现。
 */
class PersonalFmWidgetProvider : AppWidgetProvider() {

    companion object {
        // 快照更新广播（Flutter → MainActivity → 本方法发出）
        const val ACTION_FM_UPDATE_WIDGET = "com.md3music.md3music.ACTION_FM_UPDATE_WIDGET"
        // 封面就绪后的内部重绘（无 extras，禁止覆盖缓存快照）
        const val ACTION_FM_COVER_READY = "com.md3music.md3music.ACTION_FM_COVER_READY"
        // 登录引导卡点击（拉起 app 进登录页）
        const val ACTION_FM_OPEN_LOGIN = "com.md3music.md3music.ACTION_FM_WIDGET_OPEN_LOGIN"
        // 播放类动作常量定义在 AudioPlaybackService（PendingIntent 直接引用），
        // 保证 Provider 与 Service 两端字符串一致。

        private const val EXTRA_FM_STATION_INDEX = "fm_stationIndex"
        private const val EXTRA_FM_STATION_DESC = "fm_stationDescription"
        private const val EXTRA_FM_IS_LOGGED_IN = "fm_isLoggedIn"
        private const val EXTRA_FM_IS_LOADING = "fm_isLoading"
        private const val EXTRA_FM_IS_PLAYING = "fm_isPlaying"
        private const val EXTRA_FM_IS_FAVORITE = "fm_isFavorite"
        private const val EXTRA_FM_TITLE = "fm_title"
        private const val EXTRA_FM_ARTIST = "fm_artist"
        private const val EXTRA_FM_COVER_URL = "fm_coverUrl"
        private const val EXTRA_FM_NEXT_HASH = "fm_nextHash"
        private const val EXTRA_FM_NEXT_COVER = "fm_nextCover"
        // 小部件按钮 PendingIntent 携带的动作参数（转发 Service 时改用
        // AudioPlaybackService.EXTRA_FM_ACTION_* 键，避免与快照 extras 混淆）
        private const val EXTRA_FM_TRACK_HASH = "fm_trackHash"

        private const val COLOR_PREFIX = "color_"
        private val COLOR_KEYS = arrayOf(
            "panelBg", "drawerBg", "onDrawer", "primary", "onPrimary",
            "surfaceHigh", "onSurface", "onSurfaceVariant", "outlineVariant",
            "surfaceHighest", "primaryContainer", "onPrimaryContainer",
        )

        // Material 3 基准紫（浅色）兜底：app 从未推送过主题色时使用
        private val defaultColors = mapOf(
            "panelBg" to 0xFFF7F2FA.toInt(),
            "drawerBg" to 0xFFE8DEF8.toInt(),
            "onDrawer" to 0xFF1D192B.toInt(),
            "primary" to 0xFF6750A4.toInt(),
            "onPrimary" to 0xFFFFFFFF.toInt(),
            "surfaceHigh" to 0xFFECE6F0.toInt(),
            "onSurface" to 0xFF1D1B20.toInt(),
            "onSurfaceVariant" to 0xFF49454F.toInt(),
            "outlineVariant" to 0xFFCAC4D0.toInt(),
            "surfaceHighest" to 0xFFE6E0E9.toInt(),
            "primaryContainer" to 0xFFEADDFF.toInt(),
            "onPrimaryContainer" to 0xFF21005D.toInt(),
        )

        // ---- 快照缓存：onUpdate / 封面重绘 / 进程内复用（照抄 MusicWidgetProvider 范式）----
        private var lastLoggedIn = false
        private var lastStationIndex = 0
        private var lastStationDesc = "贴着你标过红心的歌来"
        private var lastIsLoading = false
        private var lastIsPlaying = false
        private var lastIsFavorite = false
        private var lastTitle = "点播放，开启你的电台"
        private var lastArtist = ""
        private var lastCoverUrl: String? = null
        private var lastNextHash1: String? = null
        private var lastNextCover1: String? = null
        private var lastNextHash2: String? = null
        private var lastNextCover2: String? = null
        private var lastNextHash3: String? = null
        private var lastNextCover3: String? = null
        private val lastColors = mutableMapOf<String, Int>()

        // 封面内存缓存（原始 bitmap，渲染时按槽位圆角裁切）。
        // 注意：Android 12+ 对 RemoteViews 位图内存有硬上限（约 2.5MB），
        // 必须经 decodeCover 降采样到显示尺寸后再进 RemoteViews，否则系统会
        // 拒绝整个小部件更新（表现为「载入窗口小部件时出现问题」）。
        private const val TAG = "PersonalFmWidget"
        private val coverCache = object : LruCache<String, Bitmap>(
            (Runtime.getRuntime().maxMemory() / 16).toInt().coerceIn(8 * 1024 * 1024, 64 * 1024 * 1024)
        ) {}
        // 圆角结果缓存：key = url@radius，避免每次渲染都重新分配位图
        private val roundedCache = object : LruCache<String, Bitmap>(
            (Runtime.getRuntime().maxMemory() / 32).toInt().coerceIn(4 * 1024 * 1024, 32 * 1024 * 1024)
        ) {}
        private val coverInFlight = mutableSetOf<String>()
        private val coverFailedUntil = mutableMapOf<String, Long>()

        // 由 Flutter 侧调用（MainActivity 转发）：把快照 Map 拍平成 extras 后广播。
        // 空串表示「无此值」（Intent extras 传不了 null）。
        fun updateAllWidgets(context: Context, data: Map<String, Any?>) {
            val intent = Intent(context, PersonalFmWidgetProvider::class.java).apply {
                action = ACTION_FM_UPDATE_WIDGET
                for ((key, value) in data) {
                    when (value) {
                        null -> {}
                        is String -> putExtra("fm_$key", value)
                        is Boolean -> putExtra("fm_$key", value)
                        is Int -> putExtra("fm_$key", value)
                        is Map<*, *> -> {
                            // 主题色表：拍平成 color_<role> extras
                            for ((ck, cv) in value) {
                                if (cv is Number) putExtra(COLOR_PREFIX + ck, cv.toInt())
                            }
                        }
                    }
                }
            }
            try {
                context.sendBroadcast(intent)
            } catch (e: Exception) {
                Log.w(TAG, "updateAllWidgets broadcast failed", e)
            }
        }

        private fun renderAll(context: Context) {
            try {
                val manager = AppWidgetManager.getInstance(context)
                val ids = manager.getAppWidgetIds(
                    ComponentName(context, PersonalFmWidgetProvider::class.java)
                )
                // renderWidget 是实例方法：用一个无状态实例渲染全部小部件
                val provider = PersonalFmWidgetProvider()
                for (id in ids) {
                    provider.renderWidget(context, manager, id)
                }
            } catch (e: Exception) {
                Log.w(TAG, "renderAll failed", e)
            }
        }

        private fun c(key: String): Int =
            lastColors[key] ?: (defaultColors[key] ?: 0)
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        // 进程重启后无推送：用缓存快照 + 默认主题色渲染兜底
        for (appWidgetId in appWidgetIds) {
            renderWidget(context, appWidgetManager, appWidgetId)
        }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle?
    ) {
        // 用户拖拽调整小部件尺寸：按新宽度重算预告封面槽位数
        renderWidget(context, appWidgetManager, appWidgetId)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)

        when (intent.action) {
            ACTION_FM_UPDATE_WIDGET -> {
                readSnapshot(intent)
                renderAll(context)
            }
            ACTION_FM_COVER_READY -> {
                // 只重绘，不读 extras（避免空广播覆盖缓存快照）
                renderAll(context)
            }
            ACTION_FM_OPEN_LOGIN -> {
                // 登录引导卡：拉起 app；MainActivity 读 widget_action=openLogin
                // 后转发 Flutter 打开登录页（引擎不可用时静默，仅打开 app）
                launchApp(context, "openLogin")
            }
            AudioPlaybackService.ACTION_WIDGET_FM_PLAY_PAUSE,
            AudioPlaybackService.ACTION_WIDGET_FM_TOGGLE_FAVORITE,
            AudioPlaybackService.ACTION_WIDGET_FM_SELECT_STATION,
            AudioPlaybackService.ACTION_WIDGET_FM_OPEN_TRACK -> {
                // 先尝试经 Service 转发给 Flutter；app 进程状态异常时静默降级
                val serviceIntent = Intent(context, AudioPlaybackService::class.java).apply {
                    action = intent.action
                    if (intent.hasExtra(EXTRA_FM_STATION_INDEX)) {
                        putExtra(
                            AudioPlaybackService.EXTRA_FM_ACTION_STATION_INDEX,
                            intent.getIntExtra(EXTRA_FM_STATION_INDEX, 0)
                        )
                    }
                    if (intent.hasExtra(EXTRA_FM_TRACK_HASH)) {
                        putExtra(
                            AudioPlaybackService.EXTRA_FM_ACTION_TRACK_HASH,
                            intent.getStringExtra(EXTRA_FM_TRACK_HASH)
                        )
                    }
                }
                try {
                    context.startService(serviceIntent)
                } catch (_: Exception) {}
                // 若无可用 FlutterEngine，直接拉起 app（Flutter 侧恢复状态后重推快照）
                if (!AudioPlaybackService.hasFlutterEngine()) {
                    launchApp(context, null)
                }
            }
            AudioPlaybackService.ACTION_WIDGET_FM_OPEN_PLAYER -> {
                // 封面点击：先拉起 app 到前台，再转发 Flutter 打开播放器页
                //（进程死时 startService 失败由 launchApp 兜底，降级为仅打开 app）
                launchApp(context, null)
                val serviceIntent = Intent(context, AudioPlaybackService::class.java).apply {
                    action = AudioPlaybackService.ACTION_WIDGET_FM_OPEN_PLAYER
                }
                try {
                    context.startService(serviceIntent)
                } catch (_: Exception) {}
            }
        }
    }

    // ---- 快照读取：空串视为 null（保持与 Dart 侧约定一致） ----
    private fun readSnapshot(intent: Intent) {
        lastLoggedIn = intent.getBooleanExtra(EXTRA_FM_IS_LOGGED_IN, lastLoggedIn)
        lastStationIndex = intent.getIntExtra(EXTRA_FM_STATION_INDEX, lastStationIndex)
            .coerceIn(0, 2)
        lastStationDesc = intent.getStringExtra(EXTRA_FM_STATION_DESC)
            ?.takeIf { it.isNotEmpty() } ?: lastStationDesc
        lastIsLoading = intent.getBooleanExtra(EXTRA_FM_IS_LOADING, lastIsLoading)
        lastIsPlaying = intent.getBooleanExtra(EXTRA_FM_IS_PLAYING, lastIsPlaying)
        lastIsFavorite = intent.getBooleanExtra(EXTRA_FM_IS_FAVORITE, lastIsFavorite)
        lastTitle = intent.getStringExtra(EXTRA_FM_TITLE)?.takeIf { it.isNotEmpty() } ?: lastTitle
        lastArtist = intent.getStringExtra(EXTRA_FM_ARTIST) ?: lastArtist
        lastCoverUrl = intent.getStringExtra(EXTRA_FM_COVER_URL)?.ifEmpty { null }
        lastNextHash1 = intent.getStringExtra(EXTRA_FM_NEXT_HASH + "1")?.ifEmpty { null }
        lastNextCover1 = intent.getStringExtra(EXTRA_FM_NEXT_COVER + "1")?.ifEmpty { null }
        lastNextHash2 = intent.getStringExtra(EXTRA_FM_NEXT_HASH + "2")?.ifEmpty { null }
        lastNextCover2 = intent.getStringExtra(EXTRA_FM_NEXT_COVER + "2")?.ifEmpty { null }
        lastNextHash3 = intent.getStringExtra(EXTRA_FM_NEXT_HASH + "3")?.ifEmpty { null }
        lastNextCover3 = intent.getStringExtra(EXTRA_FM_NEXT_COVER + "3")?.ifEmpty { null }
        for (key in COLOR_KEYS) {
            if (intent.hasExtra(COLOR_PREFIX + key)) {
                lastColors[key] = intent.getIntExtra(COLOR_PREFIX + key, c(key))
            }
        }
    }

    private fun launchApp(context: Context, widgetAction: String?) {
        try {
            val launchIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                if (widgetAction != null) putExtra("widget_action", widgetAction)
            }
            context.startActivity(launchIntent)
        } catch (e: Exception) {
            Log.w(TAG, "launchApp failed (action=$widgetAction)", e)
        }
    }

    // ================= 渲染 =================

    private fun renderWidget(
        context: Context,
        manager: AppWidgetManager,
        appWidgetId: Int
    ) {
        try {
            val views = RemoteViews(context.packageName, R.layout.widget_personal_fm)
            val density = context.resources.displayMetrics.density

            // 卡片底色与面板同色：宿主高度超出内容的剩余部分不露异色
            views.setInt(R.id.fm_card_bg, "setColorFilter", c("panelBg"))

            // ---- 登录引导卡（未登录）----
            views.setViewVisibility(R.id.fm_login, if (lastLoggedIn) View.GONE else View.VISIBLE)
            if (!lastLoggedIn) {
                views.setInt(R.id.fm_login_icon_bg, "setColorFilter", c("primaryContainer"))
                views.setInt(R.id.fm_login_radio, "setColorFilter", c("onPrimaryContainer"))
                views.setTextColor(R.id.fm_login_title, c("onSurface"))
                views.setTextColor(R.id.fm_login_subtitle, c("onSurfaceVariant"))
                views.setInt(R.id.fm_login_chevron, "setColorFilter", c("onSurfaceVariant"))
                // 整卡点击 → 拉起 app 进登录页
                val loginIntent = Intent(context, PersonalFmWidgetProvider::class.java).apply {
                    action = ACTION_FM_OPEN_LOGIN
                }
                views.setOnClickPendingIntent(
                    R.id.fm_login,
                    PendingIntent.getBroadcast(
                        context, 0, loginIntent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                    )
                )
            }

            // ---- 电台卡（已登录）----
            views.setViewVisibility(R.id.fm_card, if (lastLoggedIn) View.VISIBLE else View.GONE)
            if (lastLoggedIn) {
                views.setInt(R.id.fm_panel_bg, "setColorFilter", c("panelBg"))

                views.setTextViewText(R.id.fm_title, lastTitle)
                views.setTextColor(R.id.fm_title, c("onSurface"))
                if (lastArtist.isEmpty()) {
                    views.setViewVisibility(R.id.fm_artist, View.GONE)
                } else {
                    views.setViewVisibility(R.id.fm_artist, View.VISIBLE)
                    views.setTextViewText(R.id.fm_artist, lastArtist)
                }
                views.setTextColor(R.id.fm_artist, c("onSurfaceVariant"))

                // 收藏
                views.setImageViewResource(
                    R.id.fm_btn_favorite,
                    if (lastIsFavorite) R.drawable.ic_favorite_on else R.drawable.ic_favorite_off
                )
                views.setInt(
                    R.id.fm_btn_favorite, "setColorFilter",
                    if (lastIsFavorite) c("primary") else c("onSurfaceVariant")
                )

                // 播放/暂停：MD3E 圆形填充按钮（primary 圆底 + onPrimary 图标；
                // 加载中显示静态圆弧，RemoteViews 无法旋转动画）
                views.setInt(R.id.fm_btn_play_bg, "setColorFilter", c("primary"))
                views.setImageViewResource(
                    R.id.fm_btn_play_icon,
                    when {
                        lastIsLoading -> R.drawable.ic_wg_loading
                        lastIsPlaying -> R.drawable.ic_wg_pause
                        else -> R.drawable.ic_wg_play_arrow
                    }
                )
                views.setInt(R.id.fm_btn_play_icon, "setColorFilter", c("onPrimary"))

                // 封面与预告封面（位图必须按槽位显示尺寸降采样，见 decodeCover）。
                // 预告封面槽位数按实例实际宽度自适应（与发现页 LayoutBuilder 同一套公式）
                applyCover(
                    context, views, density,
                    R.id.fm_cover, R.id.fm_cover_note, R.id.fm_cover_bg,
                    lastCoverUrl, 16f, 400
                )
                val minWidthDp = manager.getAppWidgetOptions(appWidgetId)
                    .getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH)
                val maxSlots = slotCountFor(minWidthDp)
                applyNext(context, views, density, 1, lastNextHash1, lastNextCover1, maxSlots)
                applyNext(context, views, density, 2, lastNextHash2, lastNextCover2, maxSlots)
                applyNext(context, views, density, 3, lastNextHash3, lastNextCover3, maxSlots)

                // 档位按钮：显示当前档位图标（surfaceHigh 底 + onSurfaceVariant 图标，
                // 与发现页抽屉收起态一致），点击循环切换下一档位
                val stationIcons = intArrayOf(
                    R.drawable.ic_favorite_on, R.drawable.ic_wg_explore, R.drawable.ic_wg_diamond
                )
                views.setImageViewResource(R.id.fm_station_icon, stationIcons[lastStationIndex])
                views.setInt(R.id.fm_station_bg, "setColorFilter", c("surfaceHigh"))
                views.setInt(R.id.fm_station_icon, "setColorFilter", c("onSurfaceVariant"))

                bindRadioClicks(context, views)
            }

            manager.updateAppWidget(appWidgetId, views)
        } catch (e: Exception) {
            // 单实例渲染失败不影响其他实例；记日志便于排查
            Log.w(TAG, "renderWidget failed (id=$appWidgetId)", e)
        }
    }

    private fun bindRadioClicks(context: Context, views: RemoteViews) {
        val playIntent = Intent(context, PersonalFmWidgetProvider::class.java).apply {
            action = AudioPlaybackService.ACTION_WIDGET_FM_PLAY_PAUSE
        }
        views.setOnClickPendingIntent(
            R.id.fm_btn_play,
            PendingIntent.getBroadcast(
                context, 1, playIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        )

        val favIntent = Intent(context, PersonalFmWidgetProvider::class.java).apply {
            action = AudioPlaybackService.ACTION_WIDGET_FM_TOGGLE_FAVORITE
        }
        views.setOnClickPendingIntent(
            R.id.fm_btn_favorite,
            PendingIntent.getBroadcast(
                context, 2, favIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        )

        // 档位按钮：点击循环切换下一档位（extra 携带渲染时算好的下一档下标，
        // 每次状态推送都会重绑，切档完成后图标随新快照更新）
        val nextStation = (lastStationIndex + 1) % 3
        val stationIntent = Intent(context, PersonalFmWidgetProvider::class.java).apply {
            action = AudioPlaybackService.ACTION_WIDGET_FM_SELECT_STATION
            putExtra(EXTRA_FM_STATION_INDEX, nextStation)
        }
        views.setOnClickPendingIntent(
            R.id.fm_station_btn,
            PendingIntent.getBroadcast(
                context, 3, stationIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        )

        // 歌曲标题点击：打开 app 首页（直接以 Activity 为 PendingIntent；
        // CLEAR_TOP 清掉播放页等上层路由直达首页，不影响后台播放）
        val titleIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        views.setOnClickPendingIntent(
            R.id.fm_title,
            PendingIntent.getActivity(
                context, 40, titleIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        )

        // 封面点击：拉起 app 并打开播放器页
        val coverIntent = Intent(context, PersonalFmWidgetProvider::class.java).apply {
            action = AudioPlaybackService.ACTION_WIDGET_FM_OPEN_PLAYER
        }
        views.setOnClickPendingIntent(
            R.id.fm_cover_slot,
            PendingIntent.getBroadcast(
                context, 10, coverIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        )
    }

    private val nextSlotIds =
        intArrayOf(R.id.fm_next_slot1, R.id.fm_next_slot2, R.id.fm_next_slot3)
    private val nextImgIds =
        intArrayOf(R.id.fm_next_img1, R.id.fm_next_img2, R.id.fm_next_img3)
    private val nextNoteIds =
        intArrayOf(R.id.fm_next_note1, R.id.fm_next_note2, R.id.fm_next_note3)
    private val nextBgIds =
        intArrayOf(R.id.fm_next_bg1, R.id.fm_next_bg2, R.id.fm_next_bg3)

    /**
     * 按实例宽度计算预告封面槽位数。
     * 与发现页 _buildBottomRow 的 LayoutBuilder 同一套公式：
     * 右列可用宽 = 总宽 - 面板左右 padding 32 - 封面 112 - 间距 12；
     * 每槽占 56dp（封面 48 + 间距 8），另需给档位按钮留 44dp（40 + 右缩进 4）。
     * 4 格（约 347dp）→ 2 张，5 格及以上 → 3 张。
     */
    private fun slotCountFor(widthDp: Int): Int {
        val rightCol = widthDp - 32 - 112 - 12
        if (rightCol <= 44) return 0
        return ((rightCol - 44) / 56).toInt().coerceIn(0, 3)
    }

    private fun applyNext(
        context: Context,
        views: RemoteViews,
        density: Float,
        slot: Int,
        hash: String?,
        url: String?,
        maxSlots: Int
    ) {
        val idx = (slot - 1).coerceIn(0, 2)
        if (hash.isNullOrEmpty() || slot > maxSlots) {
            views.setViewVisibility(nextSlotIds[idx], View.GONE)
            return
        }
        views.setViewVisibility(nextSlotIds[idx], View.VISIBLE)
        applyCover(
            context, views, density,
            nextImgIds[idx], nextNoteIds[idx], nextBgIds[idx], url, 12f, 160
        )
        // 点击 → 后台起播该曲
        val intent = Intent(context, PersonalFmWidgetProvider::class.java).apply {
            action = AudioPlaybackService.ACTION_WIDGET_FM_OPEN_TRACK
            putExtra(EXTRA_FM_TRACK_HASH, hash)
        }
        views.setOnClickPendingIntent(
            nextSlotIds[idx],
            PendingIntent.getBroadcast(
                context, 20 + slot, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        )
    }

    /** 单个封面槽：有缓存图就取圆角结果显示，否则显示占位并触发异步下载。 */
    private fun applyCover(
        context: Context,
        views: RemoteViews,
        density: Float,
        imgId: Int,
        noteId: Int,
        bgId: Int,
        url: String?,
        radiusDp: Float,
        targetPx: Int
    ) {
        views.setInt(bgId, "setColorFilter", c("surfaceHighest"))
        views.setInt(noteId, "setColorFilter", c("onSurfaceVariant"))
        val raw = url?.let { coverCache.get(it) }
        if (raw != null) {
            try {
                val key = "$url@$radiusDp"
                var roundedBmp = roundedCache.get(key)
                if (roundedBmp == null) {
                    roundedBmp = rounded(raw, radiusDp, density)
                    roundedCache.put(key, roundedBmp)
                }
                views.setImageViewBitmap(imgId, roundedBmp)
                views.setViewVisibility(imgId, View.VISIBLE)
                views.setViewVisibility(noteId, View.GONE)
                return
            } catch (e: Exception) {
                Log.w(TAG, "applyCover bitmap failed: $url", e)
            }
        }
        views.setViewVisibility(imgId, View.GONE)
        views.setViewVisibility(noteId, View.VISIBLE)
        requestCover(context, url, targetPx)
    }

    /**
     * 异步下载封面：失败静默（60s 冷却），成功后广播重绘（照抄 notifyArtworkChanged 范式）。
     * [targetPx] 为显示侧最长边像素：解码时按它降采样（inSampleSize），
     * 否则 800×800 原图（约 2.5MB）会超过 Android 12+ 对 RemoteViews 位图内存的
     * 硬上限，导致整个小部件更新被系统拒绝。
     */
    private fun requestCover(context: Context, url: String?, targetPx: Int) {
        if (url.isNullOrEmpty()) return
        if (coverCache.get(url) != null) return
        synchronized(coverInFlight) {
            if (!coverInFlight.add(url)) return
        }
        val now = System.currentTimeMillis()
        synchronized(coverFailedUntil) {
            if ((coverFailedUntil[url] ?: 0L) > now) {
                synchronized(coverInFlight) { coverInFlight.remove(url) }
                return
            }
        }
        Thread {
            var bmp: Bitmap? = null
            try {
                val conn = URL(url).openConnection() as HttpURLConnection
                conn.connectTimeout = 8000
                conn.readTimeout = 8000
                conn.setRequestProperty("User-Agent", "Mozilla/5.0")
                if (conn.responseCode in 200..299) {
                    bmp = decodeCover(conn.inputStream, targetPx)
                }
                try {
                    conn.disconnect()
                } catch (_: Exception) {}
            } catch (e: Exception) {
                Log.w(TAG, "cover download failed: $url", e)
                bmp = null
            }
            if (bmp != null) {
                coverCache.put(url, bmp)
            } else {
                synchronized(coverFailedUntil) {
                    coverFailedUntil[url] = System.currentTimeMillis() + 60_000
                }
            }
            synchronized(coverInFlight) { coverInFlight.remove(url) }
            if (bmp != null) {
                try {
                    val intent = Intent(context, PersonalFmWidgetProvider::class.java).apply {
                        action = ACTION_FM_COVER_READY
                    }
                    context.sendBroadcast(intent)
                } catch (_: Exception) {}
            }
        }.start()
    }

    /** 按显示尺寸降采样解码：两段式 decode（先读边界算 inSampleSize，再真解码）。 */
    private fun decodeCover(input: InputStream, targetPx: Int): Bitmap? {
        return try {
            val bytes = input.use { it.readBytes() }
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= targetPx ||
                bounds.outHeight / (sample * 2) >= targetPx
            ) {
                sample *= 2
            }
            val opts = BitmapFactory.Options().apply { inSampleSize = sample }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
        } catch (e: Exception) {
            Log.w(TAG, "decodeCover failed", e)
            null
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
}
