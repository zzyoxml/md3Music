package com.md3music.md3music

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Flutter 播放引擎与桌面音乐小组件之间的共享通道。 */
internal object HomeWidgetChannel {
    private const val CHANNEL = "com.md3music.md3music/home_widget"

    fun register(context: Context, messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "updateWidget" -> {
                    val title = call.argument<String>("title") ?: ""
                    val artist = call.argument<String>("artist") ?: ""
                    val isPlaying = call.argument<Boolean>("isPlaying") ?: false
                    val position = call.argument<Number>("position")?.toLong() ?: 0L
                    val duration = call.argument<Number>("duration")?.toLong() ?: 0L
                    MusicWidgetProvider.updateAllWidgets(
                        context, title, artist, isPlaying, position, duration
                    )
                    CoverPlayerWidgetProvider.updateAllWidgets(context, title, artist, isPlaying)
                    // 概念版 4×1 小部件额外需要播放模式与收藏态（旧两个组件不消费这些字段）
                    ConceptWidgetProvider.updateAllWidgets(
                        context, title, artist, isPlaying,
                        call.argument<String>("loopMode") ?: "off",
                        call.argument<Boolean>("shuffleEnabled") ?: false,
                        call.argument<Boolean>("isFavorited") ?: false
                    )
                    result.success(true)
                }
                "updateFmWidget" -> {
                    @Suppress("UNCHECKED_CAST")
                    val data = call.arguments as? Map<String, Any?> ?: emptyMap()
                    PersonalFmWidgetProvider.updateAllWidgets(context, data)
                    result.success(true)
                }
                "updateMusicWidgetTheme" -> {
                    @Suppress("UNCHECKED_CAST")
                    val colors = call.arguments as? Map<String, Number> ?: emptyMap()
                    MusicWidgetProvider.updateTheme(context, colors)
                    CoverPlayerWidgetProvider.updateTheme(context, colors)
                    ConceptWidgetProvider.updateTheme(context, colors)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
}
