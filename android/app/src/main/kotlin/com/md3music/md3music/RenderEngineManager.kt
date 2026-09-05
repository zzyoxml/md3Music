package com.md3music.md3music

import android.content.Context
import android.content.SharedPreferences

/**
 * 渲染引擎（Skia / Impeller）选择与崩溃自动回退管理。
 *
 * 引擎在 FlutterEngine 创建（冷启动早期）时由 shell 参数决定，无法运行中热切换。
 * 本类只负责：
 *  1. 依据持久化偏好决定本次启动用 Skia 还是 Impeller（通过注入
 *     --enable-impeller= 覆盖 manifest 静态开关，命令行优先级高于 manifest）。
 *  2. 用「是否成功渲染首帧」作为启动探针：若上次 Impeller 启动未到首帧即退出
 *     （崩溃/强杀），下次启动累计失败次数。
 *  3. 连续 [kFallbackThreshold] 次失败后自动回退 Skia、持久化，并向 UI 暴露
 *     本次是否发生回退（用于弹原生 Toast）。
 *
 * 持久化与 Dart 端 shared_preferences 插件共用同名文件/键约定（键带 "flutter." 前缀），
 * 原生回退写 skia 后，Dart 设置页下次冷启动读到的即回退后的真实值。
 */
object RenderEngineManager {
    // 与 shared_preferences Android 插件默认文件/键约定保持一致
    private const val PLUGIN_PREFS = "FlutterSharedPreferences"
    // 用户引擎偏好（Dart 端 SettingsRepository 的 key 为 settings_render_engine，
    // shared_preferences Android 插件会给键加 "flutter." 前缀，故此处为 flutter.settings_render_engine），
    // 值 "skia" | "impeller"
    private const val KEY_ENGINE = "flutter.settings_render_engine"
    // 探针：本次 Impeller 启动是否仍在途（尚未渲染首帧）
    private const val KEY_PENDING = "flutter.render_pending_start"
    // 探针：连续启动失败次数
    private const val KEY_CRASH_COUNT = "flutter.render_crash_count"

    private const val ENGINE_SKIA = "skia"
    private const val ENGINE_IMPELLER = "impeller"

    /** 连续多少次 Impeller 启动失败后自动回退 Skia */
    const val kFallbackThreshold = 2

    // 引擎 shell 开关：启用/禁用 Impeller。必须用原生 bool 开关形式
    //（`--enable-impeller` / `--no-enable-impeller`）；`--enable-impeller=false` 这类
    // "=" 形式在引擎解析里不被识别，会导致无法覆盖默认后端。
    const val ARG_ENABLE_IMPELLER = "--enable-impeller"
    const val ARG_DISABLE_IMPELLER = "--no-enable-impeller"

    /**\r\n     * 当前构建是否启用了 Impeller。
     * 渲染引擎由构建期 flavor 决定，运行时不可切换；此处读 manifest 合并后的静态值。
     */
    fun isImpellerBuild(context: Context): Boolean {
        return try {
            val ai = context.packageManager.getApplicationInfo(
                context.packageName, android.content.pm.PackageManager.GET_META_DATA)
            ai.metaData?.getBoolean("io.flutter.embedding.android.EnableImpeller", false) ?: false
        } catch (_: Exception) { false }
    }

    /** 本次启动是否发生自动回退（供 MainActivity 在 UI 就绪后弹 Toast） */
    @Volatile
    var fellBackToSkiaThisLaunch = false
        private set

    private fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(PLUGIN_PREFS, Context.MODE_PRIVATE)

    /** 用户手动设置引擎（Dart 设置页切换时经 SettingsRepository 写入，原生不直接调用此方法）。 */
    fun setUserEngine(context: Context, engine: String) {
        prefs(context).edit()
            .putString(KEY_ENGINE, if (engine == ENGINE_IMPELLER) ENGINE_IMPELLER else ENGINE_SKIA)
            // 手动切换后清零计数，给新引擎干净的重试机会
            .putInt(KEY_CRASH_COUNT, 0)
            .putBoolean(KEY_PENDING, false)
            .apply()
    }

    /**
     * 在 getFlutterShellArgs() 中调用：先结算上一次启动结果，再决定本次是否用 Impeller。
     * @return true=本次启用 Impeller；false=用 Skia（含自动回退）。
     */
    fun resolveUseImpeller(context: Context): Boolean {
        val p = prefs(context)
        val editor = p.edit()

        // ① 结算上次启动：pending 残留 = 上次 Impeller 启动未到首帧即退出 → 记一次失败。
        //    （Skia 启动不写 pending，因此只有 Impeller 失败才累计。）
        var crashCount = p.getInt(KEY_CRASH_COUNT, 0)
        if (p.getBoolean(KEY_PENDING, false)) {
            crashCount += 1
            editor.putInt(KEY_CRASH_COUNT, crashCount)
        }
        editor.putBoolean(KEY_PENDING, false)

        val wantImpeller = p.getString(KEY_ENGINE, ENGINE_SKIA) == ENGINE_IMPELLER
        val useImpeller = wantImpeller && crashCount < kFallbackThreshold

        fellBackToSkiaThisLaunch = wantImpeller && !useImpeller
        if (useImpeller) {
            // ② 标记本次 Impeller 启动在途；到首帧后由 firstFrameConfirmed 清除。
            editor.putBoolean(KEY_PENDING, true)
        } else {
            // Skia 或本次回退：清零计数（下次手动开 Impeller 时重新从 0 计数）。
            editor.putInt(KEY_CRASH_COUNT, 0)
        }
        editor.apply()

        // ③ 一旦判定回退，偏好持久化为 skia，让设置页开关显示回退后的真实状态。
        if (fellBackToSkiaThisLaunch) {
            prefs(context).edit().putString(KEY_ENGINE, ENGINE_SKIA).apply()
        }
        return useImpeller
    }

    /** 首帧成功渲染（仅当本次是 Impeller 启动时注册监听）：证明启动未崩溃，清零计数。 */
    fun firstFrameConfirmed(context: Context) {
        prefs(context).edit()
            .putBoolean(KEY_PENDING, false)
            .putInt(KEY_CRASH_COUNT, 0)
            .apply()
    }
}