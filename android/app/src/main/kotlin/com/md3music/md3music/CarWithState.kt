package com.md3music.md3music

import android.content.Context
import android.hardware.display.DisplayManager
import android.provider.Settings
import android.view.Display
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// 小米 CarWith 连接态 / 车机深浅色的原生读数。
///
/// 连接判据（两条**同时**成立才算连着）：
///   1) 手机上存在屏名含 CarWith 特征（com.miui.carlink 或 com.xiaomi.ucar.minimap）的屏；
///   2) 该屏的 Display.getType() == 5（CarWith 虚拟屏专有类型）。
///
/// 所有读数失败一律按「没连着」返回（connected=false, nightMode=-1），
/// 绝不向调用方抛异常——调用方是 Dart 心跳 / 服务歌词路径，抛错会让
/// 整条通道红掉，而这里语义上「读不到」与「没连」完全等价。
///
/// 每次取快照顺带刷新 vendored 层的门控位 AudioPlayer.sCarWithConnected：
/// 车机歌词键、MEDIA_URI 抑制、逐键 Builder 等五处生效判据全看那一位，
/// 快照取用点即门控刷新点，两条刷新路径（Dart 心跳 + 本服务歌词入口）共用本实现。
object CarWithState {

    /// 通道名逐字节锁定：Dart 侧与成品验收字符串探针都按这个名字搜。
    const val CHANNEL = "com.md3music.md3music/car_with"
    const val METHOD_GET_STATE = "getCarWithState"

    private const val UCAR_NIGHT_MODE_KEY = "ucar_night_mode"

    /// CarWith 虚拟屏的 Display.getType() 值。只判屏名不够：投屏/镜像等
    /// 其它虚拟屏也可能带特征字样，type 这层是第二个门。
    private const val CAR_WITH_DISPLAY_TYPE = 5

    /// 屏名特征。注意必须用**全名**而不是裸 "minimap"：
    /// com.autonavi.minimap 是内嵌高德的资源 ID，匹配裸串会误判成已连接。
    private val CAR_WITH_SCREEN_MARKERS = listOf(
        "com.miui.carlink",
        "com.xiaomi.ucar.minimap",
    )

    /// 取一次状态快照并刷新门控位。
    /// 返回 (connected, nightMode)：nightMode 0=车机浅色 / 1=车机深色 / -1=读不到；
    /// **没连着时恒为 -1**（见下方注释）。context 建议传 applicationContext
    /// （通道 handler 挂在引擎上会跨 Activity 存活，不能让闭包持有 Activity）。
    @JvmStatic
    fun snapshot(context: Context): Pair<Boolean, Int> {
        var connected = false
        var nightMode = -1
        try {
            val dm = context.getSystemService(DisplayManager::class.java)
            connected = dm?.displays?.any { isCarWithDisplay(it) } == true
            if (connected) {
                // ucar_night_mode 断开时**不会清零**，是残留值；
                // 所以只在连着时才采信，断开一律报 -1（Dart 侧据此不采信主题覆盖）。
                nightMode = Settings.Global.getInt(context.contentResolver, UCAR_NIGHT_MODE_KEY, -1)
            }
        } catch (_: Throwable) {
            // 任何读数失败（ ROM 改动、权限、隐藏 API 变化）都按「没连着」处理
            connected = false
            nightMode = -1
        }
        // 门控位刷新：vendored AudioPlayer 里的五处车机行为只认这一位。
        // 用 runCatching 而不是裸赋值：类缺失/链接失败（如 so 加载顺序问题）
        // 不能把快照本身拖崩。
        runCatching { com.ryanheise.just_audio.AudioPlayer.sCarWithConnected = connected }
        return connected to nightMode
    }

    /// 只要连接态的场合（服务门控判断）；同样失败即 false。
    @JvmStatic
    fun isConnected(context: Context): Boolean =
        runCatching { snapshot(context).first }.getOrDefault(false)

    /// 给引擎注册 car_with 通道。重复注册安全（setMethodCallHandler 是替换语义），
    /// 引擎复用 / headless 兜底路径可以各调各的。
    fun register(engine: FlutterEngine, context: Context) {
        try {
            MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
                .setMethodCallHandler { call, result ->
                    if (call.method == METHOD_GET_STATE) {
                        // snapshot 内部已全程兜底，这里不会抛
                        val (connected, nightMode) = snapshot(context)
                        result.success(
                            mapOf(
                                "connected" to connected,
                                "nightMode" to nightMode,
                            )
                        )
                    } else {
                        result.notImplemented()
                    }
                }
        } catch (_: Throwable) {
            // 注册失败=通道不可用，Dart 侧按「读不到=没连着」降级，与上游行为一致
        }
    }

    /// 单个 Display 是否为 CarWith 虚拟屏（屏名特征 + type==5 双判据）。
    private fun isCarWithDisplay(display: Display): Boolean {
        val name = try {
            display.name
        } catch (_: Throwable) {
            null
        } ?: return false
        if (CAR_WITH_SCREEN_MARKERS.none { name.contains(it) }) return false
        // Display.getType() 是 @hide，不在公共 android.jar 里——直接引用会编译期
        // Unresolved reference，只能反射取。反射失败按「不是 CarWith 屏」处理。
        val type = try {
            Display::class.java.getMethod("getType").invoke(display) as? Int
        } catch (_: Throwable) {
            null
        }
        return type == CAR_WITH_DISPLAY_TYPE
    }
}
