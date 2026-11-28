package com.md3music.md3music

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.SystemClock

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

    /**
     * 划掉任务时是否执行"停播 + 退进程"：开关开启 && 非 TV && 非系统触发的隐藏任务清理。
     *
     * 系统会在 App 全部任务不可见（如锁屏歌词层收走后主任务被移除）时**自行清理
     * hidden 任务**，该移除不是用户划掉后台。若误判为划掉，会把正在播放的进程当场
     * 杀掉——三星平板实测（2026-11-23）：息屏拉起锁屏歌词 → 指纹解锁 → 锁屏层销毁
     * 后 80ms 内主任务被 `remove-hidden-task` 移除 → [TaskRemovalService] 被停
     * → executeExit 自杀式退出，用户看到"App 闪退"。
     */
    fun shouldSwipeExit(context: Context): Boolean =
        isSwitchEnabled(context) && !isTv(context) && !systemTaskRemovalFromLockLayer()

    /// 锁屏歌词层结束后的判定窗口（ms）：窗口内到达的**所有**任务移除事件一律视为系统清理。
    ///
    /// 一次解锁会把移除事件连续投递到多条入口（TaskRemovalService 销毁 +
    /// AudioPlaybackService.onTaskRemoved），与锁屏层 onStop 的实测间隔约
    /// 80~370ms；取 1000ms 以覆盖两条入口的投递间隔余量。窗口内不做「命中即清」：
    /// 多条入口共享同一窗口，任一条漏网都会造成进程退出。
    private const val LOCK_TASK_REMOVE_GUARD_MS = 1_000L

    /// 锁屏层结束时刻（elapsedRealtime）。由 [LockScreenLyricActivity.onStop] 登记；
    /// onStop 可能被多次调用（熄屏瞬间拉起后立即不可见、解锁时再收层），每次刷新窗口。
    @Volatile
    private var lockLayerEndedElapsedMs = 0L

    /// 锁屏层结束时登记窗口起点。正常解锁走 onStop，无需调用方关心返回值。
    fun markLockLayerEnded(nowElapsedMs: Long = SystemClock.elapsedRealtime()) {
        lockLayerEndedElapsedMs = nowElapsedMs
    }

    /**
     * 本次任务移除是否由系统在锁屏层结束的清理流程中触发。
     *
     * 窗口内不消费：解锁事件会连续触发多条入口的移除（见
     * [LOCK_TASK_REMOVE_GUARD_MS] 上方注释），任一条漏网都会造成进程退出，
     * 故整段拦截；窗口过期或下次锁屏层结束重新登记前按正常划掉处理。
     */
    internal fun systemTaskRemovalFromLockLayer(
        nowElapsedMs: Long = SystemClock.elapsedRealtime(),
    ): Boolean {
        val endedAt = lockLayerEndedElapsedMs
        return endedAt != 0L && nowElapsedMs in endedAt until (endedAt + LOCK_TASK_REMOVE_GUARD_MS)
    }

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
