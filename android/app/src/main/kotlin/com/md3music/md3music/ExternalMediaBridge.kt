package com.md3music.md3music

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 外部调用（ACTION_VIEW 打开音频）桥接：文件管理器「用其他应用打开」→ 进播放器页自动播放。
 *
 * 流程：
 * 1. MainActivity 的 onCreate/onNewIntent 把 intent 交给 [onIntent]；
 * 2. 校验 action/MIME/扩展名，命中后存 pending 并立即在后台线程解析
 *    （MediaStore DATA 命中或拷贝到私有目录）——外部 URI 的临时读权限
 *    只在 Activity 存活期间可靠，拷贝必须尽早完成，不能等 Dart 就绪；
 * 3. 解析完成后推送给 Dart（onExternalMedia）；引擎未就绪（冷启动早期）
 *    则静默失败并保留 pending，由 Dart 通过 takePendingMedia 拉取。
 *
 * 防重复交付：推送不清除 pending，仅 takePendingMedia 清除；Dart 侧另有
 * key + 时间窗去重兜底。
 */
object ExternalMediaBridge {
    private const val TAG = "ExternalMediaBridge"
    const val CHANNEL_NAME = "com.md3music.md3music/external_media"

    // 部分文件管理器对 ogg/opus 使用非 audio/* 的 MIME
    private val EXTRA_AUDIO_MIMES = setOf(
        "application/ogg",
        "application/x-ogg",
        "application/opus",
    )

    // MIME 缺失时按扩展名兜底判定（与 lib/core/utils/audio_scanner.dart 的
    // audioExtensions 保持同步，新增格式时两处都要改）
    private val AUDIO_EXTENSIONS = setOf(
        "mp3", "flac", "m4a", "ogg", "opus", "wav", "aac", "ape",
        "wma", "aif", "aiff", "aifc",
    )

    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var pendingUri: String? = null

    @Volatile
    private var pendingPath: String? = null

    private var channel: MethodChannel? = null

    /** MainActivity.configureFlutterEngine 调用：注册通道，若已有解析完的 pending 补推一次。 */
    fun registerChannel(flutterEngine: FlutterEngine) {
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "takePendingMedia" -> {
                    val uri = pendingUri
                    val path = pendingPath
                    if (uri != null && path != null) {
                        clearPending()
                        result.success(mapOf("uri" to uri, "path" to path))
                    } else {
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        channel = ch
        // 冷启动时解析可能先于 Dart 就绪完成：此时补推一次
        pushPending()
    }

    /** MainActivity.onCreate/onNewIntent 调用；仅处理 ACTION_VIEW + 音频。 */
    fun onIntent(activity: Activity, intent: Intent?) {
        if (intent == null || intent.action != Intent.ACTION_VIEW) return
        val uri = intent.data ?: return
        if (!isAudioIntent(activity, intent.type, uri)) {
            Log.i(TAG, "忽略非音频 VIEW intent: $uri")
            return
        }
        Log.i(TAG, "收到外部音频: $uri")
        pendingUri = uri.toString()
        pendingPath = null
        Thread {
            // resolveLocalPath 内部含流拷贝（大文件可能耗时数百毫秒），必须在后台线程
            val resolved = try {
                MediaStoreScanner.resolveLocalPath(activity, uri.toString())
            } catch (t: Throwable) {
                Log.e(TAG, "resolveLocalPath 失败: ${t.message}")
                null
            }
            if (resolved == null) {
                Log.e(TAG, "外部音频无法解析，丢弃: $uri")
                clearPending()
                return@Thread
            }
            pendingPath = resolved
            pushPending()
        }.start()
    }

    /** 主线程推送；通道未就绪时静默放弃（保留 pending，等 Dart takePendingMedia 拉取）。 */
    private fun pushPending() {
        mainHandler.post {
            val uri = pendingUri ?: return@post
            val path = pendingPath ?: return@post
            val ch = channel ?: return@post
            try {
                ch.invokeMethod("onExternalMedia", mapOf("uri" to uri, "path" to path))
                Log.i(TAG, "已推送外部音频给 Dart: $path")
            } catch (t: Throwable) {
                Log.w(TAG, "推送失败，等待 Dart takePendingMedia: ${t.message}")
            }
        }
    }

    private fun clearPending() {
        pendingUri = null
        pendingPath = null
    }

    /** MIME 命中（intent.type 或 ContentResolver 推断）或文件名扩展名命中 → 判为音频调用。 */
    private fun isAudioIntent(activity: Activity, mimeType: String?, uri: Uri): Boolean {
        val mime = mimeType ?: try {
            activity.contentResolver.getType(uri)
        } catch (_: Throwable) {
            null
        }
        if (mime != null) {
            val lower = mime.lowercase()
            if (lower.startsWith("audio/") || lower in EXTRA_AUDIO_MIMES) return true
        }
        val name = uri.lastPathSegment ?: return false
        val ext = name.substringAfterLast('.', "").lowercase()
        return ext.isNotEmpty() && ext in AUDIO_EXTENSIONS
    }
}
