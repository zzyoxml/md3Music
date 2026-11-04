package com.md3music.md3music

import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

/**
 * 图片保存插件：MethodChannel "com.md3music.md3music/image_saver"
 *
 * Dart 侧先把图片下载到应用临时目录，再调 saveImage(path, fileName)：
 * - API 29+（Android 10，分区存储）：写入 MediaStore.Images，
 *   RELATIVE_PATH = Pictures/MD3Music，**不需要任何运行时权限**；
 *   先 IS_PENDING=1 写完再置 0，避免相册扫到半张图；写失败必须 delete 占位行。
 * - API < 29：写入 Environment.getExternalStoragePublicDirectory(Pictures)/MD3Music。
 *   WRITE_EXTERNAL_STORAGE 在 API 28 及以下是安装期 normal 权限（manifest 已声明），
 *   无需运行时申请，这里只做防御性校验。
 *
 * 复制是重 IO（几 MB 图片），放子线程执行，结果回主线程回调 Flutter。
 */
class ImageSaverPlugin(private val context: Context) {

    companion object {
        private const val CHANNEL_NAME = "com.md3music.md3music/image_saver"
        private const val ALBUM_NAME = "MD3Music"
        private const val FALLBACK_NAME = "image.jpg"
        private const val MAX_NAME_LENGTH = 60

        /** 净化文件名：只保留字母数字与 . - _，裁掉首尾杂字符，过长截断且保留扩展名。 */
        internal fun sanitizeFileName(raw: String): String {
            val cleaned = raw
                .map { if (it.isLetterOrDigit() || it == '.' || it == '-' || it == '_') it else '_' }
                .joinToString("")
                .trim('_', '.', ' ')
            if (cleaned.isEmpty()) return FALLBACK_NAME
            if (cleaned.length <= MAX_NAME_LENGTH) return cleaned
            val dot = cleaned.lastIndexOf('.')
            if (dot <= 0) return cleaned.substring(0, MAX_NAME_LENGTH)
            val ext = cleaned.substring(dot)
            val stem = cleaned.substring(0, dot)
            return stem.take((MAX_NAME_LENGTH - ext.length).coerceAtLeast(1)) + ext
        }

        /** 同名时追加 -2 / -3 … 直到 [exists] 返回 false。 */
        internal fun dedupeFileName(base: String, exists: (String) -> Boolean): String {
            if (!exists(base)) return base
            val dot = base.lastIndexOf('.')
            val stem = if (dot > 0) base.substring(0, dot) else base
            val ext = if (dot > 0) base.substring(dot) else ""
            var i = 2
            while (exists("$stem-$i$ext")) i++
            return "$stem-$i$ext"
        }

        private fun mimeOf(fileName: String): String =
            when (fileName.substringAfterLast('.', "").lowercase()) {
                "png" -> "image/png"
                "gif" -> "image/gif"
                "webp" -> "image/webp"
                "bmp" -> "image/bmp"
                else -> "image/jpeg"
            }
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveImage" -> handleSaveImage(call, result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun handleSaveImage(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path.isNullOrEmpty()) {
            result.error("INVALID_ARGUMENT", "path is required", null)
            return
        }
        val src = File(path)
        if (!src.isFile) {
            result.error("FILE_NOT_FOUND", "源文件不存在: $path", null)
            return
        }
        val fileName = sanitizeFileName(call.argument<String>("fileName") ?: src.name)
        Thread {
            try {
                val saved = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    saveViaMediaStore(src, fileName)
                } else {
                    saveViaPublicDir(src, fileName)
                }
                android.util.Log.i("ImageSaver", "saved=$saved fileName=$fileName")
                mainHandler.post { result.success(saved) }
            } catch (e: SecurityException) {
                android.util.Log.e("ImageSaver", "PERMISSION_DENIED", e)
                mainHandler.post {
                    result.error("PERMISSION_DENIED", "缺少存储写入权限", null)
                }
            } catch (e: Exception) {
                android.util.Log.e("ImageSaver", "SAVE_FAILED", e)
                mainHandler.post {
                    result.error(
                        "SAVE_FAILED",
                        "${e.javaClass.simpleName}: ${e.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    /** API 29+：MediaStore 分区存储，免权限。 */
    private fun saveViaMediaStore(src: File, fileName: String): String {
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, fileName)
            put(MediaStore.Images.Media.MIME_TYPE, mimeOf(fileName))
            put(
                MediaStore.Images.Media.RELATIVE_PATH,
                Environment.DIRECTORY_PICTURES + "/" + ALBUM_NAME,
            )
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("MediaStore insert 返回 null")
        try {
            val out = resolver.openOutputStream(uri)
                ?: throw IllegalStateException("openOutputStream 返回 null")
            out.use { output -> FileInputStream(src).use { it.copyTo(output) } }
        } catch (e: Exception) {
            // 写失败必须删掉占位行，否则相册里会留一张 0 字节坏图
            runCatching { resolver.delete(uri, null, null) }
            throw e
        }
        values.clear()
        values.put(MediaStore.Images.Media.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
        return uri.toString()
    }

    /** API < 29：公共 Pictures 目录。 */
    private fun saveViaPublicDir(src: File, fileName: String): String {
        val granted = ContextCompat.checkSelfPermission(
            context,
            android.Manifest.permission.WRITE_EXTERNAL_STORAGE,
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) throw SecurityException("WRITE_EXTERNAL_STORAGE 未授予")

        val dir = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
            ALBUM_NAME,
        )
        if (!dir.isDirectory && !dir.mkdirs()) {
            throw IllegalStateException("创建目录失败: $dir")
        }
        val target = File(dir, dedupeFileName(fileName) { File(dir, it).exists() })
        FileInputStream(src).use { input -> target.outputStream().use { input.copyTo(it) } }
        return target.absolutePath
    }
}
