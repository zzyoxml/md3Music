package com.md3music.md3music

import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 蝰蛇母带处理链控制插件（MD3Music）。
 *
 * 把 Dart 侧的母带开关与 10 段 EQ 增益转发给 just_audio fork 里的
 * `ViperMasterProcessor` 静态广播表——与音量均衡
 * `NormalizationGainAudioSink.setGlobalGainDb` 完全同一模式。
 * 主引擎（MainActivity）与 headless 播放引擎（AudioPlaybackService）
 * 各注册一次，UI isolate 与播放 isolate 都能调到。
 */
class ViperDspPlugin {

    fun register(engine: FlutterEngine) {
        try {
            MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL_NAME)
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "setEnabled" -> {
                            com.ryanheise.just_audio.ViperMasterProcessor.setGlobalEnabled(
                                call.argument<Boolean>("enabled") ?: false,
                            )
                            result.success(null)
                        }

                        "setEqGains" -> {
                            val gains = call.argument<List<Double>>("gains")
                            val bandCount =
                                com.ryanheise.just_audio.ViperMasterProcessor.BAND_COUNT
                            if (gains == null || gains.size != bandCount) {
                                result.error("bad_args", "gains 必须是 $bandCount 个 dB 值", null)
                            } else {
                                com.ryanheise.just_audio.ViperMasterProcessor.setGlobalEqGains(
                                    FloatArray(gains.size) { gains[it].toFloat() },
                                )
                                result.success(null)
                            }
                        }

                        else -> result.notImplemented()
                    }
                }
        } catch (t: Throwable) {
            Log.e(TAG, "register viper_dsp failed", t)
        }
    }

    companion object {
        private const val TAG = "ViperDspPlugin"
        const val CHANNEL_NAME = "com.md3music.md3music/viper_dsp"
    }
}
