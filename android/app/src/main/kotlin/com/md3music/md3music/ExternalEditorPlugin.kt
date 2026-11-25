package com.md3music.md3music

import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 用 Lyrico 外部编辑本地歌曲插件：通过 MethodChannel "com.md3music.md3music/external_editor"
 * 暴露 launchLyricoEdit，把本地音频文件经 FileProvider 授权交给 Lyrico（EDIT_TAG intent）
 * 编辑元数据/歌词。
 *
 * 双引擎架构下 MainActivity 与 AudioPlaybackService（headless 引擎）都会注册本插件，
 * 保证无论 UI 运行在哪个 FlutterEngine 上 Dart 端都能命中 handler。
 *
 * 返回结果给 Dart 端：
 * - 成功拉起 → mapOf("installed" to true)
 * - Lyrico 未安装（或无法处理）→ mapOf("installed" to false)，不抛错，由 Dart 提示
 * - 参数错误/启动异常 → result.error(...)
 */
class ExternalEditorPlugin(private val context: Context) {

    companion object {
        private const val CHANNEL_NAME = "com.md3music.md3music/external_editor"
        private const val LYRICO_PACKAGE = "com.lonx.lyrico"
    }

    fun register(flutterEngine: FlutterEngine) {
        Log.i(
            "ExternalEditorPlugin",
            "register on engine messenger=${flutterEngine.dartExecutor.binaryMessenger} " +
                "executingDart=${flutterEngine.dartExecutor.isExecutingDart()}",
        )
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME,
        )
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "launchLyricoEdit" -> handleLaunchLyricoEdit(call, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun handleLaunchLyricoEdit(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val filePath = call.argument<String>("filePath")
        if (filePath.isNullOrEmpty()) {
            result.error("INVALID_ARGUMENT", "filePath is required", null)
            return
        }
        val file = File(filePath)
        if (!file.exists()) {
            result.error("FILE_NOT_FOUND", "audio file not found: $filePath", null)
            return
        }

        // Lyrico 未安装时直接返回 installed=false，由 Dart 端提示，不抛错
        val lyricoInstalled = try {
            context.packageManager.getPackageInfo(LYRICO_PACKAGE, 0) != null
        } catch (_: Exception) {
            false
        }
        if (!lyricoInstalled) {
            result.success(mapOf("installed" to false))
            return
        }

        try {
            // FileProvider 生成 content:// URI 并授权读写，Lyrico 编辑后可直接保存回写
            val contentUri = FileProvider.getUriForFile(
                context,
                "${context.packageName}.fileprovider",
                file,
            )
            val intent = Intent("com.lonx.lyrico.action.EDIT_TAG").apply {
                setDataAndType(contentUri, "audio/*")
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        // headless 场景无 Activity，必须用 NEW_TASK 从 application context 拉起
                        Intent.FLAG_ACTIVITY_NEW_TASK
                )
            }
            if (intent.resolveActivity(context.packageManager) == null) {
                result.success(mapOf("installed" to false))
                return
            }
            context.startActivity(intent)
            result.success(mapOf("installed" to true))
        } catch (e: Exception) {
            Log.e("ExternalEditorPlugin", "launchLyricoEdit failed", e)
            result.error("LAUNCH_FAILED", "${e.javaClass.simpleName}: ${e.message}", null)
        }
    }
}
