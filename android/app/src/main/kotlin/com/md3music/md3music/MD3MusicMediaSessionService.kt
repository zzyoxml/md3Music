package com.md3music.md3music

import android.annotation.SuppressLint
import android.content.Intent
import android.os.IBinder
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
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
        super.onCreate()
        // 注册为 fork 的会话 host：fork 创建/已有活跃会话后 addSession 到本服务渲染通知
        AudioPlayer.setMediaSessionServiceHost(this)
    }

    override fun onGetSession(info: MediaSession.ControllerInfo): MediaSession? {
        // 返回 fork 当前活跃的媒体3会话；未初始化时拒绝连接
        return AudioPlayer.getActiveMediaSession()
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