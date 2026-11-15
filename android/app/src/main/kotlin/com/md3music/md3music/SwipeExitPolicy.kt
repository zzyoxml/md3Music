package com.md3music.md3music

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager

/**
 * 「划掉后台自动退出」策略（2026-11-12 三星/类原生适配专项）。
 *
 * 目标（用户拍板）：**所有 Android 手机，划掉最近任务 = 立即停播并销毁进程，零延迟**。
 *
 * 触发点有两条，互为补充：
 *
 * 1. **onTaskRemoved 回调**：支持及时投递的 ROM 在回调到达时立即销毁；
 * 2. **stopWithTask 任务移除监听**：独立 [TaskRemovalService] 由系统在任务移除时
 *    直接停止，其 onDestroy 统一执行销毁，不依赖 onTaskRemoved 的投递时机。
 *
 * TV 无"划掉后台"语义，一律排除；用户可在 设置 → 播放 → 播放行为 →
 * 「划掉后台自动退出」关闭（默认开启），关闭后所有系统都走现状逻辑。
 *
 * 开关每次现读 SP（与 `AudioPlaybackService.isCarPowerOffPauseEnabled` 同款：
 * 设置页改完即时生效），不持有任何可变状态。
 */
object SwipeExitPolicy {

    /** Dart 侧对应 `SettingsRepository._keySwipeExitOnTaskRemoved`（默认 true），
     *  Flutter 插件写入时自动加 `flutter.` 前缀。 */
    private const val PREF_SWIPE_EXIT = "flutter.settings_swipe_exit_on_task_removed"

    /** TV 无"划掉后台"语义，一律排除。 */
    private fun isTv(context: Context): Boolean = try {
        context.packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
    } catch (_: Exception) {
        false
    }

    /** 开关现读：默认 **true**（读不到、类型不符、取 SP 异常一律按开启处理）。 */
    fun isSwitchEnabled(context: Context): Boolean = try {
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getBoolean(PREF_SWIPE_EXIT, true)
    } catch (_: Exception) {
        true
    }

    /** 划掉任务时是否执行"停播 + 退进程"：开关开启 && 非 TV（所有手机）。 */
    fun shouldSwipeExit(context: Context): Boolean =
        isSwitchEnabled(context) && !isTv(context)

    /**
     * 启动系统任务移除监听。服务本身始终运行，开关在销毁时现读，
     * 因此播放过程中切换设置也能在下一次划掉任务时生效。
     */
    fun startTaskRemovalService(context: Context) {
        val app = context.applicationContext
        if (isTv(app)) return
        try {
            app.startService(Intent(app, TaskRemovalService::class.java))
        } catch (t: Throwable) {
            RingLog.e("SwipeExit", "start task-removal service failed", t)
        }
    }

    /**
     * 统一销毁入口：停播 → 停两个前台服务 → 杀进程（幂等终点）。
     * onTaskRemoved 回调与 stopWithTask 服务销毁两条路径共用，谁先到谁执行。
     */
    fun executeExit(context: Context) {
        val app = context.applicationContext
        RingLog.i("SwipeExit", "stop playback and kill process")
        // 先优雅停播（fork 播放在 AudioPlaybackService 侧，经 UI action 暂停）
        AudioPlaybackService.dispatchUiAction(
            app,
            AudioPlaybackService.ACTION_PAUSE
        )
        try {
            app.stopService(Intent(app, AudioPlaybackService::class.java))
        } catch (_: Throwable) {
        }
        try {
            app.stopService(Intent(app, MD3MusicMediaSessionService::class.java))
        } catch (_: Throwable) {
        }
        // 与国内 ROM 的 SIGKILL 等效：进程灭即 Rust 本地服务器灭
        android.os.Process.killProcess(android.os.Process.myPid())
        java.lang.System.exit(0)
    }
}
