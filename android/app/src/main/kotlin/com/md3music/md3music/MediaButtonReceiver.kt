package com.md3music.md3music

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.KeyEvent

/**
 * 线控耳机媒体键接收器（「唤醒播放」核心入口）。
 *
 * 当系统内没有活跃的 MediaSession 时（例如 App 进程被杀、从未开始播放），
 * 线控耳机的媒体键会以 `android.intent.action.MEDIA_BUTTON` 广播形式下发，
 * 且该广播可以拉起已被杀死的 App 进程。本接收器负责把按键映射为播放命令，
 * 并启动 [AudioPlaybackService] 完成「唤醒播放」。
 *
 * 有活跃 MediaSession 时（正常播放中 / 后台暂停），媒体键由
 * [AudioPlaybackService] 持有的 MediaSession 回调处理，不会走到这里。
 *
 * 按键映射（有线耳机常规逻辑）：
 * - 单击 KEYCODE_HEADSETHOOK / KEYCODE_MEDIA_PLAY_PAUSE → 播放（唤醒）
 * - 快速双击 → 下一首（先播放当前歌曲，随后立即切下一首）
 * - 快速三击 → 上一首
 * - 独立的 MEDIA_PLAY / MEDIA_PAUSE / MEDIA_NEXT / MEDIA_PREVIOUS / MEDIA_STOP
 *
 * 说明：单击立即下发「播放」，确保按键动作发生在广播处理窗口内（Android 12+
 * 允许收到媒体键广播的应用启动前台服务）；双击/三击在单击之后补发切歌命令，
 * 此时服务已作为前台服务运行，不再受后台启动前台服务限制。
 */
class MediaButtonReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "MediaButtonReceiver"
        private const val MULTI_CLICK_TIMEOUT = 350L
        private val mainHandler = Handler(Looper.getMainLooper())
        private var clickCount = 0
        private var pendingAction: Runnable? = null
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_MEDIA_BUTTON) return
        val event = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT, KeyEvent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra<KeyEvent>(Intent.EXTRA_KEY_EVENT)
        } ?: return
        // 只处理按下事件，避免 ACTION_UP 重复触发
        if (event.action != KeyEvent.ACTION_DOWN) return

        when (event.keyCode) {
            KeyEvent.KEYCODE_HEADSETHOOK,
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> handleMultiClickPlay(context.applicationContext)
            KeyEvent.KEYCODE_MEDIA_PLAY -> dispatch(context.applicationContext, "play")
            KeyEvent.KEYCODE_MEDIA_PAUSE -> dispatch(context.applicationContext, "pause")
            KeyEvent.KEYCODE_MEDIA_NEXT -> dispatch(context.applicationContext, "next")
            KeyEvent.KEYCODE_MEDIA_PREVIOUS -> dispatch(context.applicationContext, "previous")
            KeyEvent.KEYCODE_MEDIA_STOP -> dispatch(context.applicationContext, "pause")
        }
    }

    /// 单击播放 / 双击下一首 / 三击上一首。
    /// 第一击立即下发「播放」，避免错过广播处理窗口；后续按点击次数补发切歌命令。
    private fun handleMultiClickPlay(context: Context) {
        clickCount++
        pendingAction?.let { mainHandler.removeCallbacks(it) }
        if (clickCount == 1) {
            dispatch(context, "play")
        }
        pendingAction = Runnable {
            val count = clickCount
            clickCount = 0
            when (count) {
                2 -> dispatch(context, "next")
                3 -> dispatch(context, "previous")
            }
        }
        mainHandler.postDelayed(pendingAction!!, MULTI_CLICK_TIMEOUT)
    }

    private fun dispatch(context: Context, command: String) {
        val intent = Intent(context, AudioPlaybackService::class.java).apply {
            action = AudioPlaybackService.ACTION_MEDIA_BUTTON
            putExtra(AudioPlaybackService.EXTRA_MEDIA_COMMAND, command)
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        } catch (e: Exception) {
            Log.w(TAG, "dispatch failed: $command", e)
        }
    }
}
