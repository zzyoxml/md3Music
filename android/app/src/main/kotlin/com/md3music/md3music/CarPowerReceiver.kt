package com.md3music.md3music

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 车机下电 / 息屏信号接收器（动态注册，随 [AudioPlaybackService] 生命周期存活）。
 *
 * 只做一件事：把 action 原样交给持有者。**不做任何判断**——
 * 开关是否开启、是否在播、要不要派发，全部由服务侧决定，
 * 这样本类保持无状态、无 Android 依赖逻辑，行为可被纯函数单测覆盖。
 *
 * 为什么不写进 AndroidManifest.xml：
 * targetSdk ≥ 26 时 manifest 接收器收不到隐式广播（Android 8.0 背景限制），
 * 且 ACTION_SHUTDOWN 自 API 28 起只发给 registerReceiver 注册的接收器；
 * 我们只关心「正在播时下电」，而播放期服务必然存活，动态注册覆盖面足够。
 */
class CarPowerReceiver(
    private val onSignal: (action: String) -> Unit
) : BroadcastReceiver() {

    override fun onReceive(context: Context?, intent: Intent?) {
        val action = intent?.action ?: return
        onSignal(action)
    }
}
