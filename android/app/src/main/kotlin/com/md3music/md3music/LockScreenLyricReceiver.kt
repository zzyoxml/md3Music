package com.md3music.md3music

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/// 锁屏歌词启动广播：屏幕熄灭（锁屏）时，若「锁屏歌词」开关开启且
/// 正在播放，则拉起 LockScreenLyricActivity 覆盖在锁屏上方。
///
/// 注意：本 App 已申请 SYSTEM_ALERT_WINDOW 权限（悬浮窗），
/// 在 Android 10+ 后台启动 Activity 限制下仍可正常拉起。
class LockScreenLyricReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action
        // 熄屏（准备锁屏）或亮屏（在锁屏上显示）都触发，双保险
        if (action != Intent.ACTION_SCREEN_OFF && action != Intent.ACTION_SCREEN_ON) return
        android.util.Log.i("LockScreenLyric",
            "$action received, isNowPlaying=${AudioPlaybackService.isNowPlaying}")
        if (!AudioPlaybackService.isNowPlaying) return

        // 读 FlutterSharedPreferences 中的 flutter.settings_lock_screen_lyric_enabled
        //（SharedPreferences 写入在 Flutter 端，key 带 flutter. 前缀）
        val enabled = try {
            context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .getBoolean("flutter.settings_lock_screen_lyric_enabled", false)
        } catch (_: Exception) {
            false
        }
        android.util.Log.i("LockScreenLyric", "$action: lockScreenLyricEnabled=$enabled")
        if (enabled) {
            LockScreenLyricActivity.start(context)
        }
    }
}
