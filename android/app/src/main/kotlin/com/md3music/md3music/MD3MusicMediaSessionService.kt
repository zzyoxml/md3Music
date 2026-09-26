package com.md3music.md3music

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.IBinder
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
class MD3MusicMediaSessionService : MediaSessionService() {

    override fun onCreate() {
        // 必须在 onCreate() 返回前设置（fork 源码 MediaSessionService:594 的约束）。
        // 包一层 provider 才能拿到 Media3 真正生成的那条媒体通知（含 id 与 Notification
        // 对象），把歌词贴到它的 tickerText 上 —— 另起通知会出两个播放器且 Flyme 不渲染。
        setMediaNotificationProvider(
            FlymeNotificationProvider(
                DefaultMediaNotificationProvider.Builder(applicationContext).build(),
                applicationContext
            )
        )
        super.onCreate()
        // 注册为 fork 的会话 host：fork 创建/已有活跃会话后 addSession 到本服务渲染通知
        AudioPlayer.setMediaSessionServiceHost(this)
    }

    override fun onGetSession(info: MediaSession.ControllerInfo): MediaSession? {
        // 返回 fork 当前活跃的媒体3会话；未初始化时拒绝连接
        return AudioPlayer.getActiveMediaSession()
    }

    /**
     * 委托给 media3 默认 provider，并在通知交出前把当前歌词注入 tickerText。
     *
     * fork 的 MediaSessionService 只有 onUpdateNotification(MediaSession[, boolean]) 两个
     * 重载，拿不到 Notification 对象与通知 id，所以只能在 provider 这一层挂钩。
     */
    private class FlymeNotificationProvider(
        private val delegate: MediaNotification.Provider,
        private val context: Context
    ) : MediaNotification.Provider {

        override fun createNotification(
            mediaSession: MediaSession,
            customLayout: ImmutableList<CommandButton>,
            actionFactory: MediaNotification.ActionFactory,
            onNotificationChangedCallback: MediaNotification.Provider.Callback
        ): MediaNotification {
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
        // MD3Music fork: 原子随身听（vivomusicmix）以 vivo action 绑定本服务。
        // media3 onBind 只认 media3 / android.media.browse.MediaBrowserService 两个 action，
        // vivo action 落 default 分支返回 null → 绑定失败 → 原子拿不到 session
        // （无歌词、无封面、无进度条）。把 vivo action 映射到 legacy MediaBrowserService
        // 路径（返回 legacy browser binder，原子经 MediaControllerCompat 读取）。
        if (intent?.action == "com.vivo.musicwidgetmix.support.service") {
            return super.onBind(
                Intent("android.media.browse.MediaBrowserService")
            )
        }
        return super.onBind(intent)
    }

    override fun onDestroy() {
        AudioPlayer.setMediaSessionServiceHost(null)
        super.onDestroy()
    }

    // 阶段1 暂时不接管自定义通知的停止语义；播放停止时 media3 默认会取消 now playing 通知
    // 并让本服务退回后台，无需额外处理。onTaskRemoved 使用默认实现。
}