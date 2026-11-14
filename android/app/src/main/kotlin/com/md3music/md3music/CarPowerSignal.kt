package com.md3music.md3music

/**
 * 车机下电类信号的判定与命令映射。
 *
 * 纯函数 + 常量表：不 import 任何 Android 类型（action 用字符串字面量），
 * 因此可以直接跑 JVM 单测，也能被 [AudioPlaybackService] 与
 * [MD3MusicMediaSessionService] 共用。
 *
 * 新增车机厂商只需往 [ACTIONS] 里加 action —— 接收器是动态注册的，
 * 不需要动 AndroidManifest.xml。
 */
object CarPowerSignal {

    /**
     * 已确证：路畅（RoadRover）roados 在 ACC OFF / 关门下电流程里广播的暂停命令。
     * 证据：QQ音乐车机版 com.tencent.qqmusiccar 3.0.1.8 的
     * BroadcastReceiverCenterForThird#BC_QQ_MUSIC_PAUSE_FOR_ROADROVER。
     */
    const val ACTION_ROADROVER_QQ_MUSIC_PAUSE = "com.roadrover.roados.action.qq_music_pause"

    /**
     * 标准关机广播。API 28 起系统只发给 registerReceiver 注册的接收器，
     * 这是本实现必须动态注册的原因之一。
     */
    const val ACTION_DEVICE_SHUTDOWN = "android.intent.action.ACTION_SHUTDOWN"

    /** 触发暂停的 action 全集。 */
    val ACTIONS: List<String> = listOf(
        ACTION_ROADROVER_QQ_MUSIC_PAUSE,
        ACTION_DEVICE_SHUTDOWN,
    )

    /**
     * 仅观测、绝不动作的 action。
     *
     * 用途：在无法现场取证时，用「熄火瞬间屏幕是否关闭」这条弱信号反推车机下电时序
     * （日志里只有 SCREEN_OFF、没有任何 [ACTIONS] → 厂商走的是定向广播或无线索）。
     * 手机端息屏听歌是核心场景，这些 action 永远不得映射成播放命令。
     */
    val OBSERVE_ONLY_ACTIONS: List<String> = listOf(
        "android.intent.action.SCREEN_OFF",
        "android.intent.action.SCREEN_ON",
    )

    /** 需要注册进 IntentFilter 的全集（动作组 + 观测组）。 */
    val ALL_ACTIONS: List<String> = ACTIONS + OBSERVE_ONLY_ACTIONS

    /**
     * 该 action 在当前开关状态下应下发的播放命令；null 表示不动作。
     *
     * 恒为 "pause"：下车场景选暂停而非退出 —— 退出会让车机下次上电必须冷启动 + 恢复队列，
     * 并与既有「连车自动续播」链路冲突；QQ音乐车机版同样只暂停。
     *
     * @param enabled 设置项 settings_car_mode_power_off_pause（默认 false）
     */
    fun commandFor(action: String?, enabled: Boolean): String? {
        if (!enabled || action == null) return null
        return if (ACTIONS.contains(action)) "pause" else null
    }

    /** 是否属于「只观测不动作」的信号（用于写诊断日志）。 */
    fun shouldObserve(action: String?): Boolean =
        action != null && OBSERVE_ONLY_ACTIONS.contains(action)
}
