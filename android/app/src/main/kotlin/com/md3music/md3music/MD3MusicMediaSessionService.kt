package com.md3music.md3music

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.hardware.display.DisplayManager
import android.os.Bundle
import android.os.IBinder
import android.util.Log
import android.view.Display
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.MediaNotification
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import androidx.media3.session.CommandButton
import com.google.common.collect.ImmutableList
import com.ryanheise.just_audio.AudioPlayer

/**
 * 媒体3 会话承载服务（方案 B 阶段1：媒体3 通知栏上线）。
 *
 * 职责：把 just_audio fork 自建的 androidx.media3.session.MediaSession 归入本服务，
 * 由 media3 的 MediaNotificationManager + DefaultMediaNotificationProvider 生成系统
 * now playing 通知（通知栏可见、可控制播放）。仅作会话承载，不承担播放/焦点逻辑。
 */
@OptIn(UnstableApi::class)
@SuppressLint("UnsafeOptInUsageError")
class MD3MusicMediaSessionService : MediaSessionService(), AudioPlayer.ActiveMediaSessionHost {

    private var vivoBootstrapSession: VivoBootstrapSession? = null

    override fun onActiveMediaSessionChanged(session: MediaSession?) {
        vivoBootstrapSession?.follow(session)
        // 冷绑定 token 留给已经连接的原子组件，但不再参与宿主的通知竞争。
        if (session != null) {
            vivoBootstrapSession?.session?.let { if (isSessionAdded(it)) removeSession(it) }
        }
    }


    /** 连车唤醒：外部 bind 且无活跃会话时自动拉起+续播（咪咕式），默认开 */
    private var autoWakeEnabled = true
    /** 上次触发连车唤醒的时刻（elapsedRealtime，节流防重试风暴）。哨值 -15s：
     *  "从未唤醒过"不等于"刚唤醒过"——冷开机 15 秒内到达的首个外部绑定期，
     *  lastCarWakeAt=0 会让 now-0<15000 恒真，把开机即 bind 的车机全程错过。 */
    private var lastCarWakeAt = -15_000L

    override fun onCreate() {
        // 「划掉后台自动退出」：独立 stopWithTask 服务监听系统任务移除。
        SwipeExitPolicy.startTaskRemovalService(applicationContext)
        // 所有机型都安装本 App 的媒体通知 Provider：底层仍是 media3 默认实现，额外做两件事
        // —— 统一设单色小图标（所有机型保留）；仅 Flyme 系把歌词写进媒体通知的 tickerText。
        // 必须在 onCreate() 返回前设置（fork 源码 MediaSessionService:594 的约束）。
        setMediaNotificationProvider(
            Md3MediaNotificationProvider(
                DefaultMediaNotificationProvider.Builder(applicationContext).build(),
                applicationContext
            )
        )
        super.onCreate()
        // MD3Music fork v39：vivo 原子随身听（vivomusicmix）的三棵列表树。
        // 岛在能力位放行后会经 MediaBrowserServiceCompat 绑定来取列表（真机实证：
        // external bind action=android.media.browse.MediaBrowserService），而我们
        // legacy stub 的默认实现是 sendResult(null)（恒空）——这里注入真实内容：
        // 当前播放列表 / 云端收藏 / 本地音乐（岛面板标签为「播放列表 / 收藏 /
        // 下载列表」，分页键 vivomusicmix_key_media_page）。
        // 数据由 Dart 主动推送（VivoMixLibrary 内存快照），不在 binder 回调里回拉。
        setLegacyBrowseChildrenProvider { parentId, options ->
            VivoMixLibrary.buildChildren(parentId, options)
        }
        // MD3Music fork v40：列表项点播——岛按 media id 回播。拦截成"转交
        // AudioPlaybackService → Dart 按 <来源>:<songId> 找歌再播"，避免默认实现把
        // 无 URI 的 item 塞进 ExoPlayer（播不出且污染 media3 时间线）。
        // v43：提成字段，onDestroy 按 identity 清理（静态钩子不得滞留旧实例）。
        // v58 破案：岛点播在 stub 到达（v57 环观测实证）而 hook 面包屑为零——
        // 本服务某次销毁时按 identity 把静态钩子清成 null，之后岛连着的 media3
        // 会话还在主进程，stub 继续收命令 → 全部漏过。修复：钩子改用
        // applicationContext（进程级常驻，无旧实例滞留语义）且 onDestroy 不再
        // 清理——静态钩子常驻贯通服务生命周期。
        val hookAppContext = applicationContext
        vivoMixPlayHook =
            androidx.media3.session.MediaSessionService.PlayFromMediaIdHook { mediaId ->
                when {
                    mediaId.isNullOrEmpty() -> false
                    // v67：legacy 搜索候选回播。mediaId 形如 `md3srch:<序号>`（不透明，
                    // 桥接端只应原样回传）。查不到（进程重启 / TTL 过期）也**必须消费**：
                    // 默认实现会把 md3srch: 当 mediaId 塞进 ExoPlayer，播不出且污染
                    // media3 时间线；失效提示交给 Dart 侧 toast。
                    mediaId.startsWith(BrowseSearchRegistry.MEDIA_ID_PREFIX) -> {
                        val payload = BrowseSearchRegistry.payloadOf(mediaId)
                        val intent = Intent(hookAppContext, AudioPlaybackService::class.java)
                            .setAction(AudioPlaybackService.ACTION_SEARCH_ITEM_PLAY)
                        if (payload != null) {
                            intent.putExtra(
                                AudioPlaybackService.EXTRA_SEARCH_ITEM_PAYLOAD,
                                payloadToBundle(payload),
                            )
                        } else {
                            intent.putExtra(
                                AudioPlaybackService.EXTRA_SEARCH_ITEM_EXPIRED,
                                true,
                            )
                        }
                        try {
                            hookAppContext.startService(intent)
                        } catch (t: Throwable) {
                            Log.w("CarAutoResume", "search item play forward failed", t)
                        }
                        true
                    }
                    else -> {
                        // v41：当前播放树的 mediaId 是 `title|artist` 口径（与岛高亮
                        // 匹配一致），不带来源前缀——含 '|' 的也一并拦截；其余按前缀。
                        val starts = mediaId.startsWith(VivoMixLibrary.SOURCE_CURRENT + ":") ||
                            mediaId.startsWith(VivoMixLibrary.SOURCE_FAVORITE + ":") ||
                            mediaId.startsWith(VivoMixLibrary.SOURCE_LOCAL + ":") ||
                            mediaId.contains('|')
                        if (starts) {
                            val intent = Intent(hookAppContext, AudioPlaybackService::class.java)
                                .setAction(AudioPlaybackService.ACTION_VIVO_MIX_PLAY)
                                .putExtra(AudioPlaybackService.EXTRA_VIVO_MIX_MEDIA_ID, mediaId)
                            try {
                                hookAppContext.startService(intent)
                            } catch (t: Throwable) {
                                Log.w("CarAutoResume", "vivo mix play forward failed", t)
                            }
                            true
                        } else {
                            false
                        }
                    }
                }
            }
        // 注册为 fork 的会话 host：fork 创建/已有活跃会话后 addSession 到本服务渲染通知
        AudioPlayer.setMediaSessionServiceHost(this)
        // MD3Music fork v60 破案补链：上面的 `vivoMixPlayHook =` 装的是**本服务的
        // 成员字段**，而 stub（MediaSessionLegacyStub）读取的是**静态字段**
        // MediaSessionService.playFromMediaIdHook——v43"提成字段"那轮把静态赋值
        // 改成了成员赋值，两者从未连通，钩子一直 null（岛点播 never 通过门）。
        // 这里把静态字段同步接上。
        androidx.media3.session.MediaSessionService.playFromMediaIdHook =
            vivoMixPlayHook
        // MD3Music fork v66：车机语音点歌。framework
        // MediaController.TransportControls.playFromSearch() 在 media3 1.4.1 只能经
        // legacy stub 到达（MediaSession.Callback 根本没有该方法），这里接管为
        // 「转交 AudioPlaybackService → Dart 按关键词搜索并起播」。
        // query 为空（框架语义是"随便播点音乐"）不接管，交回默认实现。
        androidx.media3.session.MediaSessionService.playFromSearchHook =
            androidx.media3.session.MediaSessionService.PlayFromSearchHook { query, extras ->
                if (query.isNullOrBlank()) {
                    false
                } else {
                    Log.i(
                        "CarAutoResume",
                        "playFromSearch q=$query extras=${extras?.keySet()?.joinToString(",")}",
                    )
                    val intent = Intent(hookAppContext, AudioPlaybackService::class.java)
                        .setAction(AudioPlaybackService.ACTION_PLAY_FROM_SEARCH)
                        .putExtra(AudioPlaybackService.EXTRA_SEARCH_QUERY, query)
                    try {
                        hookAppContext.startService(intent)
                        true
                    } catch (t: Throwable) {
                        Log.w("CarAutoResume", "playFromSearch forward failed", t)
                        false
                    }
                }
            }
        // MD3Music fork v67：legacy browse 搜索（MediaBrowserCompat.search）——
        // 返回候选列表给桥接端自绘。必须同步 detach（由 registry 内的 register 完成），
        // 否则基类 performSearch 断言崩溃；结果由 AudioPlaybackService 在 Dart 回包后
        // 负责结算，超时 8s 兜底回空列表。
        androidx.media3.session.MediaSessionService.searchProvider =
            androidx.media3.session.MediaSessionService.SearchProvider { query, _, result ->
                if (query.isNullOrBlank()) {
                    false
                } else {
                    Log.i("CarAutoResume", "browseSearch q=$query")
                    val requestId = BrowseSearchRegistry.newRequestId()
                    BrowseSearchRegistry.register(requestId, result)
                    val intent = Intent(hookAppContext, AudioPlaybackService::class.java)
                        .setAction(AudioPlaybackService.ACTION_BROWSE_SEARCH)
                        .putExtra(AudioPlaybackService.EXTRA_SEARCH_QUERY, query)
                        .putExtra(AudioPlaybackService.EXTRA_SEARCH_REQUEST_ID, requestId)
                    try {
                        hookAppContext.startService(intent)
                        true
                    } catch (t: Throwable) {
                        Log.w("CarAutoResume", "browse search forward failed", t)
                        // 已 detach，必须自行结算，否则桥接端永久等待。
                        BrowseSearchRegistry.settleEmpty(requestId)
                        true
                    }
                }
            }
        // MD3Music fork v48：列表内容变化通知——Dart 推新快照后通知已订阅的岛端
        // 刷新（melodist 参考实现同款；不通知则岛一直显示推送前的旧列表/空列表）。
        // notifyLegacyChildrenChanged 内部投主线程，任意线程调用安全。
        VivoMixLibrary.childrenChangedNotifier = { parentId ->
            notifyLegacyChildrenChanged(parentId)
        }
        // MD3Music fork v21（连车拉起）：读取外部绑定时自动拉起+续播的开关
        autoWakeEnabled = try {
            getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .getBoolean("flutter.settings_autoplay_on_car_connect", true)
        } catch (_: Exception) { true }
    }

    override fun onGetSession(info: MediaSession.ControllerInfo): MediaSession? {
        // MD3Music fork v28 诊断：记录连接方包名。连车判据现状只靠"投屏虚拟屏"
        // 与 action 排除，拿不到调用方身份；真机采集到车机端/系统框架各自的
        // 包名后，可把唤醒判据收紧成车机端包名白名单（bind 早于投屏的时序
        // 风险也随之消除）。每连接方一行，量级可忽略。
        Log.i("CarAutoResume", "onGetSession controller=${info.packageName}")
        AudioPlayer.getActiveMediaSession()?.let { return it }
        // vivo 首次 bind 可能早于 Dart 创建/激活播放器；返回 null 会让原子组件
        // 永久握不到 token。仅 vivo/iQOO 补待机会话，不在 bind 时启动引擎或播放。
        if (!AudioPlayer.isShadowPlaybackMirrorEnabled()) return null
        return (vivoBootstrapSession ?: VivoBootstrapSession(applicationContext).also {
            vivoBootstrapSession = it
        }).session
    }

    /**
     * 本 App 的媒体通知 Provider：委托给 media3 默认实现，额外做两件事 ——
     * 1) 统一设置单色小图标（所有机型）；
     * 2) 仅 Flyme 系（FlymeLyricBridge.isSupported()）把当前歌词原地写进媒体通知的
     *    tickerText 并置 Flyme 私有 flag 位。非 Flyme 机型（vivo/iQOO 等）走纯透传，
     *    不接触 Notification 对象，避免打断原子随身听对媒体通知的读取
     *    （表现为卡片出现但无封面/无歌词/无进度）。
     *
     * fork 的 MediaSessionService 只有 onUpdateNotification(MediaSession[, boolean]) 两个
     * 重载，拿不到 Notification 对象与通知 id，所以只能在 provider 这一层挂钩。
     */
    private class Md3MediaNotificationProvider(
        private val delegate: DefaultMediaNotificationProvider,
        private val context: Context
    ) : MediaNotification.Provider {

        override fun createNotification(
            mediaSession: MediaSession,
            customLayout: ImmutableList<CommandButton>,
            actionFactory: MediaNotification.ActionFactory,
            onNotificationChangedCallback: MediaNotification.Provider.Callback
        ): MediaNotification {
            delegate.setSmallIcon(R.drawable.ic_launcher_monochrome)
            // 按机型选择：非 Flyme 机型直接原样透传 Callback，语义与 media3 默认 Provider
            // 完全一致（只多了上面那行小图标），绝不包装/改写通知对象。
            if (!FlymeLyricBridge.isSupported()) {
                return delegate.createNotification(
                    mediaSession, customLayout, actionFactory, onNotificationChangedCallback
                )
            }
            // fork 的 MediaNotificationManager 会把这个 Callback 直接交给 delegate，
            // 封面图异步加载完成后它会被触发并绕过本包装层直接重发通知（见
            // MediaNotificationManager:167-176 → onNotificationUpdated → updateNotificationInternal）。
            // 若不拦这一道，每次 artwork 刷新都会把 tickerText 与 Flyme flags 冲掉。
            val wrapped = MediaNotification.Provider.Callback { mediaNotification ->
                // 只贴歌词、不缓存：这条路径受 Media3 序列号守卫约束，对象可能被丢弃。
                // 若在此 attach()，会缓存一个 Media3 已经扔掉的旧 Notification，
                // 之后每句歌词都把它重发出来 —— 状态栏翻回上一首且永不自愈。
                FlymeLyricBridge.decorateOnly(mediaNotification.notification)
                onNotificationChangedCallback.onNotificationChanged(mediaNotification)
            }
            val result = delegate.createNotification(
                mediaSession, customLayout, actionFactory, wrapped
            )
            FlymeLyricBridge.attach(context, result.notificationId, result.notification)
            return result
        }

        override fun handleCustomCommand(
            session: MediaSession,
            action: String,
            extras: Bundle
        ): Boolean = delegate.handleCustomCommand(session, action, extras)
    }

    override fun onBind(intent: Intent?): IBinder? {
        // MD3Music fork v32：本进程自绑定（AudioPlaybackService onCreate 的媒体3
        // 通知承载装配）走专用内部 action，不参与连车唤醒判定——onBind 回调语境
        // 不在入向 Binder 事务内，getCallingUid 只会返回本进程 uid，任何按调用方
        // 身份做的甄别在这里都不可靠；自绑定从源头换成内部 action，其他绑定路径
        // （系统媒体框架/车机）照常进判定。
        if (intent?.action == ACTION_INTERNAL_MEDIA_HOST_BIND) {
            // v33：代解析用行长常量（与字符字面量逐字等价），避免漂移。
            return super.onBind(Intent(MediaSessionService.SERVICE_INTERFACE))
        }
        // MD3Music fork: 原子随身听（vivomusicmix）以 vivo action 绑定本服务。
        // media3 onBind 只认 media3 / android.media.browse.MediaBrowserService 两个 action，
        // vivo action 落 default 分支返回 null → 绑定失败 → 原子拿不到 session
        // （无歌词、无封面、无进度条）。把 vivo action 映射到 legacy MediaBrowserService
        // 路径（返回 legacy browser binder，原子经 MediaControllerCompat 读取）。
        maybeWakeForCarConnect(intent?.action)
        if (intent?.action == "com.vivo.musicwidgetmix.support.service") {
            return super.onBind(
                Intent("android.media.browse.MediaBrowserService")
            )
        }
        return super.onBind(intent)
    }

    companion object {
        /** 本进程自绑定专用 action：不进连车唤醒判定（v32）。 */
        const val ACTION_INTERNAL_MEDIA_HOST_BIND =
            "com.md3music.md3music.internal.MEDIA_HOST_BIND"
    }

    /**
     * MD3Music fork v21（连车拉起，咪咕式）：外部 bind 且当前没有任何活跃媒体会话，
     * 等价于"车机来了但 App 还什么都没有"——走既有线控唤醒链拉起进程并自动续播。
     * 排除项：原子随身听的 vivo 专用 action（进程活着时它常驻绑定，放行会变成变相
     * 开机自播）、本进程自绑定（专用 action，见 onBind）。15s 节流防重试风暴；
     * flutter.settings_autoplay_on_car_connect 默认开可关。拉起链：
     * startForegroundService(AudioPlaybackService, ACTION_MEDIA_BUTTON,
     * command="play", wakeOrigin=car) → ensureForeground → headless 引擎恢复 →
     * playerReady 后派发 play（同时头侧按 wakeOrigin 放开媒体会话创建，车机卡片
     * 才有内容）。
     */
    private fun maybeWakeForCarConnect(action: String?) {
        if (action == ACTION_INTERNAL_MEDIA_HOST_BIND) return
        // MD3Music fork v40：标准 browse action = 原子随身听取列表的绑定路径，属
        // 常规查询而非"连车"，一并排除（否则有投屏虚拟屏时岛的常驻绑定会触发
        // 连车自动续播误判）。
        if (action == "android.media.browse.MediaBrowserService") return
        if (action == "com.vivo.musicwidgetmix.support.service") return
        if (!autoWakeEnabled) return
        // MD3Music fork v26：标准 MediaSessionService 绑定在手机本地也会发生
        // （系统媒体框架每次进程冷启动都会常规 bind 一次），单靠排除 vivo action
        // 会把普通打开 App 误判成连车——自动拉起恢复后撞上凭证加载窗口，误弹
        // 「请先登录」。改与卡片深链同一判据：存在投屏虚拟屏才算真连车。车机
        // 端绑定若早于投屏建立会错过首次，由车机重连再触发；留下跳过原因便于核对。
        val dm = getSystemService(DisplayManager::class.java)
        if (dm == null || dm.displays.none { it.displayId != Display.DEFAULT_DISPLAY }) {
            Log.i(
                "CarAutoResume",
                "external bind action=$action skipped: no projected display yet"
            )
            return
        }
        val now = android.os.SystemClock.elapsedRealtime()
        if (now - lastCarWakeAt < 15_000L) return
        if (AudioPlayer.getActiveMediaSession() != null) return
        lastCarWakeAt = now
        Log.i(
            "CarAutoResume",
            "external bind action=$action without active session → wake & auto play"
        )
        val svc = Intent(this, AudioPlaybackService::class.java).apply {
            this.action = AudioPlaybackService.ACTION_MEDIA_BUTTON
            putExtra(AudioPlaybackService.EXTRA_MEDIA_COMMAND, "play")
            putExtra(AudioPlaybackService.EXTRA_WAKE_ORIGIN, "car")
        }
        try {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                startForegroundService(svc)
            } else {
                startService(svc)
            }
        } catch (t: Throwable) {
            Log.w("CarAutoResume", "wake dispatch failed", t)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // MD3Music fork v45：原子随身听循环模式——岛若以 service intent 直发
        // PLAY_MODE（部分 ROM 路径），这里转发 APS（正常路径走 media3
        // onCustomCommand，已在 AudioPlayer 侧拦截）。
        // v48：协议 extras 用 Long 装 LOOP_MODE——getIntExtra 读 Long 拿默认值，
        // 按 Number 容忍两种类型。
        if (intent?.action == AudioPlayer.VMM_ACTION_PLAY_MODE) {
            val modeRaw = intent.extras?.get(AudioPlayer.VMM_KEY_LOOP_MODE)
            val mode = (modeRaw as? Number)?.toInt() ?: 1
            val forward = Intent(this, AudioPlaybackService::class.java)
                .setAction(AudioPlaybackService.ACTION_VIVO_MIX_PLAY_MODE)
                .putExtra(AudioPlaybackService.EXTRA_VIVO_MIX_PLAY_MODE, mode)
            try {
                startService(forward)
            } catch (t: Throwable) {
                Log.w("CarAutoResume", "vivo mix play-mode forward failed", t)
            }
            return START_NOT_STICKY
        }
        // MD3Music fork v34：vendored MediaSessionService.onStartCommand 死分支的
        // FGS 5 秒死线兜底。通知栏"播放"按钮（未播放态）经 PendingIntent.
        // getForegroundService 拉起本服务，系统强制 5 秒内 startForeground；恰逢
        // 会话 release 与通知取消的竞态窗（uri 查不到已注销会话 + app 侧无活跃
        // 会话）时，vendored 死分支直接 return START_STICKY 且无人调
        // startForeground —— ForegroundServiceDidNotStartInTimeException。
        // 判据收窄到 FGS 型入口（keycode==PLAY 那一路才用 getForegroundService，
        // 暂停/切歌走普通 startService 无死线）。兜底：占位 startForeground
        // 护住死线；super 归来仍无会话则立即收敛 stopForeground+stopSelf（原先
        // 也只是空转 START_STICKY，收敛只提前退出）；若 super 正常路径挂出真实
        // 通知，占位被同 id（1001）覆盖，无感知。intent=null 的 sticky 重启无
        // fgRequired 死线，不干预。
        val uri = intent?.data
        val fgsDeadBranch = intent != null &&
            Intent.ACTION_MEDIA_BUTTON == intent.action &&
            uri != null &&
            AudioPlayer.getActiveMediaSession() == null &&
            (intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT)
                as? android.view.KeyEvent)?.keyCode == android.view.KeyEvent.KEYCODE_MEDIA_PLAY
        var guarded = false
        if (fgsDeadBranch) {
            try {
                val nm = getSystemService(android.app.NotificationManager::class.java)
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                    if (nm?.getNotificationChannel(
                            DefaultMediaNotificationProvider.DEFAULT_CHANNEL_ID
                        ) == null
                    ) {
                        nm?.createNotificationChannel(
                            android.app.NotificationChannel(
                                DefaultMediaNotificationProvider.DEFAULT_CHANNEL_ID,
                                "MD3Music",
                                android.app.NotificationManager.IMPORTANCE_MIN,
                            )
                        )
                    }
                }
                startForeground(
                    DefaultMediaNotificationProvider.DEFAULT_NOTIFICATION_ID,
                    androidx.core.app.NotificationCompat.Builder(
                        this,
                        DefaultMediaNotificationProvider.DEFAULT_CHANNEL_ID
                    )
                        .setSmallIcon(R.drawable.ic_launcher_monochrome)
                        .setContentTitle("MD3Music")
                        .setShowWhen(false)
                        .build()
                )
                guarded = true
                Log.i(
                    "CarAutoResume",
                    "onStartCommand dead-branch: FGS guard started"
                )
            } catch (t: Throwable) {
                // 占位被 ROM 拒绝属极端（原触发场景本身极窄），尽力而为：
                // 起不来就自停，至少不给无意义的空转实例。
                Log.w("CarAutoResume", "onStartCommand FGS guard failed", t)
                stopSelf()
                return START_STICKY
            }
        }
        val result = super.onStartCommand(intent, flags, startId)
        if (guarded && AudioPlayer.getActiveMediaSession() == null) {
            // super 走的就是死分支（vendored 对该 intent 必然静默返回），收敛退出。
            try {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } catch (t: Throwable) {
                Log.w("CarAutoResume", "onStartCommand guard converge fail", t)
            }
            stopSelf()
            Log.i("CarAutoResume", "onStartCommand dead-branch: converged to stop")
        }
        return result
    }

    /** v43：点播钩子字段（静态字段由其持有，onDestroy 不清）。 */
    private var vivoMixPlayHook: androidx.media3.session.MediaSessionService.PlayFromMediaIdHook? =
        null

    override fun onDestroy() {
        AudioPlayer.setMediaSessionServiceHost(null)
        vivoBootstrapSession?.release()
        vivoBootstrapSession = null
        // v58：playFromMediaIdHook **不按 identity 清理**——钩子内部只捕获
        // applicationContext（进程级），滞留无泄漏语义；且 island 及系统级 stub
        // 在服务销毁后仍会经 stub 走点播链，清掉即"hook null"漏命令。服务重建
        // 时 onCreate 会覆盖为新闭包。
        // v48：列表变化通知回调按 identity 清理（静态引用不得滞留旧实例）。
        if (VivoMixLibrary.childrenChangedNotifier != null) {
            VivoMixLibrary.childrenChangedNotifier = null
        }
        // v67：把未结算的 legacy 搜索回包收口（回空列表）。不清会留下 Handler 回调
        // 持有已死服务的 Result；桥接端也永远等不到 onSearchResult。
        BrowseSearchRegistry.clearPending()
        super.onDestroy()
    }

    /** v67：把 Dart 回传的搜索结果 payload 转成 Bundle（只支持基本类型）。 */
    private fun payloadToBundle(payload: Map<String, Any?>): Bundle {
        val bundle = Bundle()
        for ((key, value) in payload) {
            when (value) {
                is String -> bundle.putString(key, value)
                is Int -> bundle.putInt(key, value)
                is Long -> bundle.putLong(key, value)
                is Double -> bundle.putDouble(key, value)
                is Boolean -> bundle.putBoolean(key, value)
                else -> Unit
            }
        }
        return bundle
    }

    // 阶段1 暂时不接管自定义通知的停止语义；播放停止时 media3 默认会取消 now playing 通知
    // 并让本服务退回后台，无需额外处理。

    /**
     * 车机以「清理任务」收场时（部分机型的下电流程就是清任务），若正在播先暂停。
     *
     * 与下电广播正交：广播是"告知要断电"，清任务是"把界面/任务收掉"，
     * 两条路径都可能发生，任一条漏掉都会出现"车都锁了喇叭还在响"。
     *
     * 受同一个开关约束（settings_car_mode_power_off_pause，默认关闭）：
     * 手机端「上划清后台仍继续播」是既有体验，不得因为本功能被顺带改掉。
     * 只暂停不 stopSelf —— 是否收服务交回 media3 默认实现。
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        if (AudioPlaybackService.isNowPlaying &&
            AudioPlaybackService.isCarPowerOffPauseEnabled(applicationContext)
        ) {
            RingLog.i("CarPower", "onTaskRemoved: pause before task cleanup")
            // 落盘留证：清任务路径同样可能紧接断电，环形缓冲随进程灭失不可依赖
            CarPowerLogFile.write(
                applicationContext,
                "onTaskRemoved: pause before task cleanup"
            )
            AudioPlaybackService.dispatchUiAction(
                applicationContext,
                AudioPlaybackService.ACTION_PAUSE
            )
        }
        // 「划掉后台自动退出」（所有手机）：onTaskRemoved 及时投递时立即销毁；
        // 未投递或延迟时由独立 stopWithTask 服务的 onDestroy 兜底。
        if (SwipeExitPolicy.shouldSwipeExit(applicationContext)) {
            RingLog.i("SwipeExit", "onTaskRemoved entered")
            SwipeExitPolicy.executeExit(applicationContext)
            return
        }
        super.onTaskRemoved(rootIntent)
    }
}
