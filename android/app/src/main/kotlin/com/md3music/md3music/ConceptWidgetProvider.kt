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
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.os.Bundle
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import androidx.palette.graphics.Palette

/**
 * 概念版 4×1 桌面小组件（参考讨论 #160 的酷狗概念版卡片）。
 *
 * 视觉：圆形封面 + 外圈彩色圆环、单行「歌名 - 歌手」、右上收藏爱心、
 * 底部「播放模式 / 上一首 / 播放暂停 / 下一首」四个纯图标按钮；无进度条。
 * 卡片底由封面主色烤入对角渐变 + 20dp 圆角位图。
 *
 * 数据流与异常处理完全沿用既有小部件范式：
 * - Flutter（PlayerProvider / HomeWidgetService）经 MethodChannel
 *   `com.md3music.md3music/home_widget` → [HomeWidgetChannel] → 本类广播
 *   [ACTION_UPDATE_WIDGET] → 遍历实例重绘 RemoteViews。
 * - 主题色走 `color_*` extras（与 [MusicWidgetProvider] 同一套协议）；
 *   封面由 [AudioPlaybackService] 加载通知封面后写入 [cachedArtwork]（400px）。
 * - 按钮 → PendingIntent 广播 → try-catch startService 转发
 *   [AudioPlaybackService] → MethodChannel 调 Flutter；无可用引擎时拉起 app 兜底。
 *
 * 取色三级兜底：封面 Palette 主色 → Flutter 推送的 color_* 主题色 →
 * Material 3 基准紫。圆环/爱心的可读性护栏见 [ConceptWidgetColors]。
 *
 * 兼容性约束与既有三个小部件一致：不用负 margin、不用裸 <View>；
 * 播放/暂停、收藏、播放模式全部「叠放多图标 + setViewVisibility」，
 * 不用 setImageViewResource 换资源（MIUI 桌面跨版本会忽略资源切换）。
 */
class ConceptWidgetProvider : AppWidgetProvider() {

    companion object {
        private const val TAG = "ConceptWidget"

        const val ACTION_UPDATE_WIDGET = "com.md3music.md3music.ACTION_CONCEPT_WIDGET_UPDATE"

        // 按钮动作直接复用 AudioPlaybackService 既有 action（其 onStartCommand /
        // handleAction 已映射到 Flutter 命令）；模式键为本组件新增。
        private const val ACTION_PREV = "com.md3music.md3music.ACTION_PREV"
        private const val ACTION_PLAY_PAUSE = "com.md3music.md3music.ACTION_WIDGET_PLAY_PAUSE"
        private const val ACTION_NEXT = "com.md3music.md3music.ACTION_WIDGET_NEXT"
        private const val ACTION_TOGGLE_FAVORITE = "com.md3music.md3music.ACTION_TOGGLE_FAVORITE"
        private const val ACTION_CYCLE_PLAY_MODE =
            AudioPlaybackService.ACTION_WIDGET_CYCLE_PLAY_MODE

        const val EXTRA_TITLE = "widget_title"
        const val EXTRA_ARTIST = "widget_artist"
        const val EXTRA_IS_PLAYING = "widget_is_playing"
        const val EXTRA_LOOP_MODE = "widget_loop_mode"
        const val EXTRA_SHUFFLE = "widget_shuffle"
        const val EXTRA_IS_FAVORITED = "widget_is_favorited"

        /// 文本随行标志：updateAllWidgets(true) 携带最新文本/状态；
        /// notifyArtworkChanged(false) 不携带——处理时现读 companion 缓存，
        /// 消除「后台线程烤入过期播放态后到覆盖」的竞态（暂停后图标回退）
        const val EXTRA_HAS_TEXT = "widget_has_text"

        // 动态取色 extras（与既有小部件同一套 color_ 前缀协议）
        private const val COLOR_PREFIX = "color_"
        private val COLOR_KEYS = arrayOf(
            "panelBg", "primary", "onPrimary", "surfaceHigh",
            "onSurface", "onSurfaceVariant", "outlineVariant",
        )

        // Material 3 基准紫（浅色）兜底：app 从未推送过主题色且无封面时使用
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

        /// 全局封面缓存：由 AudioPlaybackService 加载通知封面时写入（400px）。
        @Volatile
        var cachedArtwork: Bitmap? = null

        /** 从 Flutter 侧调用：更新所有已放置的 widget 实例。 */
        fun updateAllWidgets(
            context: Context,
            title: String,
            artist: String,
            isPlaying: Boolean,
            loopMode: String,
            shuffleEnabled: Boolean,
            isFavorited: Boolean
        ) {
            val intent = Intent(context, ConceptWidgetProvider::class.java).apply {
                action = ACTION_UPDATE_WIDGET
                putExtra(EXTRA_HAS_TEXT, true)
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_ARTIST, artist)
                putExtra(EXTRA_IS_PLAYING, isPlaying)
                putExtra(EXTRA_LOOP_MODE, loopMode)
                putExtra(EXTRA_SHUFFLE, shuffleEnabled)
                putExtra(EXTRA_IS_FAVORITED, isFavorited)
            }
            try {
                context.sendBroadcast(intent)
            } catch (e: Exception) {
                Log.w(TAG, "updateAllWidgets broadcast failed", e)
            }
        }

        /** 由 AudioPlaybackService 加载封面后调用：复用缓存状态，仅刷新封面。 */
        fun notifyArtworkChanged(context: Context) {
            val intent = Intent(context, ConceptWidgetProvider::class.java).apply {
                action = ACTION_UPDATE_WIDGET
                // 不携带文本/状态：处理时现读 companion 缓存（主线程按序处理，
                // 拿到的是已处理完文本广播后的最新值）
                putExtra(EXTRA_HAS_TEXT, false)
            }
            try {
                context.sendBroadcast(intent)
            } catch (_: Exception) {}
        }

        /** 由 Flutter 侧调用：仅推送主题色，文本走缓存。 */
        fun updateTheme(context: Context, colors: Map<String, Number>) {
            val intent = Intent(context, ConceptWidgetProvider::class.java).apply {
                action = ACTION_UPDATE_WIDGET
                for ((key, value) in colors) {
                    putExtra(COLOR_PREFIX + key, value.toInt())
                }
            }
            try {
                context.sendBroadcast(intent)
            } catch (_: Exception) {}
        }

        // 缓存最近一次的状态，供封面更新时复用
        private var lastTitle = "MD3Music"
        private var lastArtist = "未在播放"
        private var lastPlaying = false
        private var lastLoopMode = "off"
        private var lastShuffle = false
        private var lastFavorite = false
        private val lastColors = mutableMapOf<String, Int>()

        // 圆形封面结果缓存：记录源指纹 + 目标直径，避免切歌后同尺寸新封面误命中
        private var circleCover: Bitmap? = null
        private var circleCoverSource: Int = 0
        private var circleCoverTarget: Int = 0

        // Palette 取色缓存：随封面指纹失效（400px 位图同步 generate，毫秒级）
        private var accentColor: Int? = null
        private var dominantColor: Int? = null
        private var paletteFingerprint: Int = 0

        /// 33dp 而非 32dp：与 48dp 圆环的 8dp 内孔（内径 32dp）留 0.5dp 重叠，
        /// 盖住圆形蒙版与 shape 描边的抗锯齿缝隙（参考图里封面与圆环紧贴）。
        private const val COVER_DIAMETER_DP = 33f

        private const val TEXT_COLOR = 0xF2FFFFFF.toInt()
        private const val MODE_INACTIVE_COLOR = 0x8AFFFFFF.toInt()
        private const val MODE_ACTIVE_COLOR = 0xFFFFFFFF.toInt()
        private const val HEART_OFF_COLOR = 0x99FFFFFF.toInt()
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
        // 横向拉伸后按新宽度重烤卡片底位图
        updateWidget(context, appWidgetManager, appWidgetId, null)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)

        when (intent.action) {
            ACTION_UPDATE_WIDGET -> {
                // color_* extras 存在时先读主题色（与既有小部件同一推送协议）
                for (key in COLOR_KEYS) {
                    if (intent.hasExtra(COLOR_PREFIX + key)) {
                        lastColors[key] = intent.getIntExtra(COLOR_PREFIX + key, c(key))
                    }
                }
                val manager = AppWidgetManager.getInstance(context)
                val ids = manager.getAppWidgetIds(
                    ComponentName(context, ConceptWidgetProvider::class.java)
                )
                for (id in ids) {
                    updateWidget(context, manager, id, intent)
                }
            }
            ACTION_PREV, ACTION_PLAY_PAUSE, ACTION_NEXT,
            ACTION_TOGGLE_FAVORITE, ACTION_CYCLE_PLAY_MODE ->
                forwardToService(context, intent.action!!)
        }
    }

    /** 转发到 AudioPlaybackService（其 onStartCommand 已处理这些 action）；
     *  app 进程无可用 FlutterEngine 时直接拉起 app 恢复状态。 */
    private fun forwardToService(context: Context, action: String) {
        val serviceIntent = Intent(context, AudioPlaybackService::class.java).apply {
            this.action = action
        }
        try {
            context.startService(serviceIntent)
        } catch (_: Exception) {}
        if (!AudioPlaybackService.hasFlutterEngine()) {
            launchApp(context)
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
            val views = RemoteViews(context.packageName, R.layout.widget_concept_player)
            val density = context.resources.displayMetrics.density

            // 状态来源：文本广播（has_text=true）用 Intent 值；封面广播现读
            // companion 缓存（主线程按序处理，必为已处理的最新值）
            val fromIntent = dataIntent?.getBooleanExtra(EXTRA_HAS_TEXT, true) ?: true
            val title = if (fromIntent) dataIntent?.getStringExtra(EXTRA_TITLE) ?: lastTitle
                        else lastTitle
            val artist = if (fromIntent) dataIntent?.getStringExtra(EXTRA_ARTIST) ?: lastArtist
                         else lastArtist
            val isPlaying = if (fromIntent)
                dataIntent?.getBooleanExtra(EXTRA_IS_PLAYING, lastPlaying) ?: lastPlaying
            else lastPlaying
            val loopMode = if (fromIntent)
                dataIntent?.getStringExtra(EXTRA_LOOP_MODE) ?: lastLoopMode
            else lastLoopMode
            val shuffle = if (fromIntent)
                dataIntent?.getBooleanExtra(EXTRA_SHUFFLE, lastShuffle) ?: lastShuffle
            else lastShuffle
            val isFavorited = if (fromIntent)
                dataIntent?.getBooleanExtra(EXTRA_IS_FAVORITED, lastFavorite) ?: lastFavorite
            else lastFavorite

            lastTitle = title
            lastArtist = artist
            lastPlaying = isPlaying
            lastLoopMode = loopMode
            lastShuffle = shuffle
            lastFavorite = isFavorited

            // 取色：封面 Palette → 主题色兜底（三级链末端为 M3 基准紫）
            val art = cachedArtwork
            val accent: Int
            val cardTop: Int
            val cardBottom: Int
            if (art != null) {
                ensurePalette(art)
                val dominant = dominantColor
                if (dominant != null) {
                    val card = ConceptWidgetColors.cardColors(dominant)
                    cardTop = card.first
                    cardBottom = card.second
                    accent = ConceptWidgetColors.readableAccent(
                        accentColor ?: c("primary"), cardTop, cardBottom
                    )
                } else {
                    // 封面在但取色失败：退回主题色（同样要压暗，见下）
                    val card = ConceptWidgetColors.cardColors(c("primary"))
                    cardTop = card.first
                    cardBottom = card.second
                    accent = ConceptWidgetColors.readableAccent(
                        c("primary"), cardTop, cardBottom
                    )
                }
            } else {
                // 无封面：用主题 primary 压暗成深色卡片。不能用 panelBg——
                // 浅色主题下它接近白，白字/白图标压上去完全读不出来（实测）。
                val card = ConceptWidgetColors.cardColors(c("primary"))
                cardTop = card.first
                cardBottom = card.second
                accent = ConceptWidgetColors.readableAccent(c("primary"), cardTop, cardBottom)
            }

            // 卡片底：单层 shape 圆角 + setColorFilter 上色。
            // 不烤位图：位图经 fitXY 会被启动器给的宽高拉伸，圆角随之变成椭圆，
            // 正是「圆角过渡被裁切」的成因。也不叠渐变层：GradientDrawable 的
            // 渐变 shader 再叠 PorterDuffColorFilter 后渲染不可控（实测会在圆角
            // 区域画出一圈椭圆色块），单色底 + 20dp 圆角最稳。
            views.setInt(R.id.concept_card_bg, "setColorFilter", cardBottom)

            // 圆环 + 封面：圆环恒显示（无封面时也用主题 accent 撑住卡片轮廓）
            views.setInt(R.id.concept_cover_ring, "setColorFilter", accent)
            if (art != null) {
                try {
                    val diameter = (COVER_DIAMETER_DP * density).toInt().coerceAtLeast(24)
                    val bitmap = circularCover(art, diameter)
                    views.setImageViewBitmap(R.id.concept_cover, bitmap)
                    views.setViewVisibility(R.id.concept_cover, View.VISIBLE)
                    views.setViewVisibility(R.id.concept_cover_placeholder, View.GONE)
                } catch (e: Exception) {
                    Log.w(TAG, "circular cover failed", e)
                    views.setViewVisibility(R.id.concept_cover, View.GONE)
                    views.setViewVisibility(R.id.concept_cover_placeholder, View.VISIBLE)
                }
            } else {
                views.setViewVisibility(R.id.concept_cover, View.GONE)
                views.setViewVisibility(R.id.concept_cover_placeholder, View.VISIBLE)
            }
            views.setInt(R.id.concept_cover_placeholder, "setColorFilter", c("surfaceHigh"))

            // 标题：「歌名 - 歌手」单行省略
            views.setTextViewText(
                R.id.concept_title,
                ConceptWidgetColors.displayTitle(title, artist)
            )
            views.setTextColor(R.id.concept_title, TEXT_COLOR)

            // 收藏：双图标叠放 + 可见性切换（规避 MIUI 换资源失效）
            val heartOn = ConceptWidgetColors.favoriteColor(accent, cardTop, cardBottom)
            views.setInt(R.id.concept_heart_on, "setColorFilter", heartOn)
            views.setInt(R.id.concept_heart_off, "setColorFilter", HEART_OFF_COLOR)
            views.setViewVisibility(
                R.id.concept_heart_on, if (isFavorited) View.VISIBLE else View.GONE
            )
            views.setViewVisibility(
                R.id.concept_heart_off, if (isFavorited) View.GONE else View.VISIBLE
            )

            // 播放/暂停：双图标叠放
            views.setInt(R.id.concept_ic_play, "setColorFilter", TEXT_COLOR)
            views.setInt(R.id.concept_ic_pause, "setColorFilter", TEXT_COLOR)
            views.setViewVisibility(
                R.id.concept_ic_pause, if (isPlaying) View.VISIBLE else View.GONE
            )
            views.setViewVisibility(
                R.id.concept_ic_play, if (isPlaying) View.GONE else View.VISIBLE
            )

            // 上一首/下一首
            views.setInt(R.id.concept_ic_prev, "setColorFilter", TEXT_COLOR)
            views.setInt(R.id.concept_ic_next, "setColorFilter", TEXT_COLOR)

            // 播放模式：四图标叠放，按 顺序/列表/单曲/随机 显示对应一个；
            // 顺序态（无循环）用暗色图标表示「未启用循环」，其余用亮色。
            val modeIndex = ConceptWidgetColors.modeIconIndex(loopMode, shuffle)
            val modeIds = intArrayOf(
                R.id.concept_mode_off, R.id.concept_mode_all,
                R.id.concept_mode_one, R.id.concept_mode_shuffle
            )
            val modeColor =
                if (modeIndex == ConceptWidgetColors.MODE_OFF) MODE_INACTIVE_COLOR
                else MODE_ACTIVE_COLOR
            for ((index, viewId) in modeIds.withIndex()) {
                views.setInt(viewId, "setColorFilter", modeColor)
                views.setViewVisibility(
                    viewId, if (index == modeIndex) View.VISIBLE else View.GONE
                )
            }

            // 点击：整卡打开 app；四键 + 爱心各走广播
            val openIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            val openPending = PendingIntent.getActivity(
                context, 20, openIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.concept_root, openPending)

            // requestCode 20-25 避开既有三个小部件的 0-13，防止 PendingIntent 串台
            views.setOnClickPendingIntent(
                R.id.concept_btn_mode, broadcastPending(context, 21, ACTION_CYCLE_PLAY_MODE)
            )
            views.setOnClickPendingIntent(
                R.id.concept_btn_prev, broadcastPending(context, 22, ACTION_PREV)
            )
            views.setOnClickPendingIntent(
                R.id.concept_btn_play, broadcastPending(context, 23, ACTION_PLAY_PAUSE)
            )
            views.setOnClickPendingIntent(
                R.id.concept_btn_next, broadcastPending(context, 24, ACTION_NEXT)
            )
            views.setOnClickPendingIntent(
                R.id.concept_btn_favorite, broadcastPending(context, 25, ACTION_TOGGLE_FAVORITE)
            )

            manager.updateAppWidget(appWidgetId, views)
        } catch (e: Exception) {
            Log.w(TAG, "updateWidget failed (id=$appWidgetId)", e)
        }
    }

    private fun broadcastPending(context: Context, requestCode: Int, action: String): PendingIntent {
        val intent = Intent(context, ConceptWidgetProvider::class.java).apply {
            this.action = action
        }
        return PendingIntent.getBroadcast(
            context, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    /** 封面 Palette 提取（按封面指纹缓存）：vibrant 系作 accent，dominant 派生卡片底。 */
    private fun ensurePalette(art: Bitmap) {
        val fingerprint = System.identityHashCode(art) + art.width * 31 + art.height
        if (fingerprint == paletteFingerprint) return
        paletteFingerprint = fingerprint
        accentColor = null
        dominantColor = null
        try {
            val palette = Palette.from(art).maximumColorCount(16).generate()
            val accentSwatch = palette.vibrantSwatch ?: palette.lightVibrantSwatch
                ?: palette.darkVibrantSwatch ?: palette.dominantSwatch
            accentColor = accentSwatch?.rgb
            val dominantSwatch = palette.dominantSwatch ?: palette.mutedSwatch
                ?: palette.darkMutedSwatch ?: accentSwatch
            dominantColor = dominantSwatch?.rgb
        } catch (e: Exception) {
            Log.w(TAG, "palette extract failed", e)
        }
    }

    /**
     * 圆形封面：先按目标直径 center-crop 成正方形，再用 EVEN_ODD + DST_OUT
     * 擦掉圆外像素（位图自带圆形蒙版，交给 RemoteViews 的 fitXY 直接贴，
     * 不依赖 ImageView 的圆角能力）。
     * 缓存指纹含源引用与目标直径，切歌后同尺寸新封面不会误命中。
     */
    private fun circularCover(src: Bitmap, diameter: Int): Bitmap {
        val fingerprint = System.identityHashCode(src) + src.width * 31 + src.height
        val cached = circleCover
        if (cached != null && fingerprint == circleCoverSource && diameter == circleCoverTarget) {
            return cached
        }
        val out = Bitmap.createBitmap(diameter, diameter, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        // center-crop：取 max(scale)，居中裁掉多余部分
        val scale = maxOf(diameter / src.width.toFloat(), diameter / src.height.toFloat())
        val dx = (diameter - src.width * scale) / 2f
        val dy = (diameter - src.height * scale) / 2f
        val fill = Paint(Paint.FILTER_BITMAP_FLAG)
        canvas.save()
        canvas.translate(dx, dy)
        canvas.scale(scale, scale)
        canvas.drawBitmap(src, 0f, 0f, fill)
        canvas.restore()
        // 圆形蒙版：EVEN_ODD 外框 + 内圆，DST_OUT 擦掉圆外
        val eraser = Paint(Paint.ANTI_ALIAS_FLAG)
        eraser.xfermode = PorterDuffXfermode(PorterDuff.Mode.DST_OUT)
        val inverse = Path().apply {
            addRect(0f, 0f, diameter.toFloat(), diameter.toFloat(), Path.Direction.CW)
            addCircle(
                diameter / 2f, diameter / 2f, diameter / 2f,
                Path.Direction.CCW
            )
            fillType = Path.FillType.EVEN_ODD
        }
        canvas.drawPath(inverse, eraser)
        circleCover = out
        circleCoverSource = fingerprint
        circleCoverTarget = diameter
        return out
    }
}
