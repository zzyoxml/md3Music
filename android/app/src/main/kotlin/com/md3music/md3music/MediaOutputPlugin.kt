package com.md3music.md3music

import android.content.Context
import android.media.MediaRouter2
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 系统输出切换通道。
 *
 * 「更多设备」要唤起的是**系统**的输出面板：小米 HyperOS / MIUI 把它做成了
 * 「妙播」（`miui.systemui`），所以这里只需要调
 * [MediaRouter2.showSystemOutputSwitcher] —— 不猜私有 Intent，也不跳蓝牙设置
 * （那是"配对"的入口，回答不了"现在从哪放"）。
 *
 * 该 API 是 **API 34** 引入的（Android 14）。低于此版本没有等价能力，一律返回
 * false，由 Dart 侧隐藏入口：宁可少一个按钮，也不留"点了没反应"的假入口。
 *
 * **不提供"当前输出设备名"**：`AudioManager.getDevices` 只给可用列表（不说明
 * 选中哪个、顺序也不保证），`MediaRouter2` 的系统路由在部分 ROM 上又滞后，
 * 两版试下来都会出现"连着蓝牙却显示本机"。面板因此只展示确定能操作的东西
 * （音量 + 系统面板入口），真实输出由系统面板如实呈现。
 *
 * 方法都只读且幂等：重复注册同一引擎只是替换 handler，Activity 重建无需显式 cleanup。
 */
class MediaOutputPlugin(private val context: Context) {

    private var channel: MethodChannel? = null

    fun register(engine: FlutterEngine) {
        channel = MethodChannel(
            engine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "isSwitcherSupported" -> result.success(Build.VERSION.SDK_INT >= 34)
                    "showSystemOutputSwitcher" -> result.success(showSwitcher())
                    else -> result.notImplemented()
                }
            }
        }
    }

    /**
     * 弹出系统输出切换器。
     *
     * 返回 false 的两种真实原因：系统版本 < 14（没有该 API）；或 App 不在前台
     * （系统明确忽略这次调用，官方文档写明只在前台有效）。两者都不该静默，
     * Dart 侧会据此提示。
     */
    private fun showSwitcher(): Boolean {
        if (Build.VERSION.SDK_INT < 34) return false
        return try {
            MediaRouter2.getInstance(context).showSystemOutputSwitcher()
        } catch (e: Exception) {
            Log.w(TAG, "showSystemOutputSwitcher 失败：$e")
            false
        }
    }

    private companion object {
        const val CHANNEL = "com.md3music.md3music/media_output"
        const val TAG = "MediaOutput"
    }
}
