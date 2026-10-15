package com.md3music.md3music

import android.app.Activity
import android.content.ContentUris
import android.database.Cursor
import android.net.Uri
import android.provider.MediaStore
import java.io.File

/// 通过 MediaStore 查询设备上的所有音频文件。
///
/// Android 11+ 沙箱限制：直接 `File.listSync('/storage/emulated/0/...')` 只能访问
/// App 私有目录或通过 SAF 授权的目录，无法访问网易云/QQ 音乐/酷狗等其他 App 的下载目录。
/// 但只要应用持有 READ_MEDIA_AUDIO (Android 13+) 或 READ_EXTERNAL_STORAGE (Android 12-)
/// 权限，MediaStore 会自动聚合所有可见音频。
object MediaStoreScanner {

    /// P0: 分页查询每批条数。大库（上万首）一次性全量查询会导致内存峰值过高、
    /// Binder 传输卡顿，分批查询控制单次数据量，cursor 每批及时释放。
    private const val PAGE_SIZE = 500

    /// 专辑封面对应的 content URI。
    /// 通过 `ContentUris.withAppendedId("content://media/external/audio/albumart", albumId)` 构造。
    fun albumArtUri(albumId: Long): String {
        val uri = ContentUris.withAppendedId(
            Uri.parse("content://media/external/audio/albumart"),
            albumId
        )
        return uri.toString()
    }

    /// 在主线程外执行 MediaStore 同步查询。
    /// @param activity Activity
    /// @return 音频文件信息列表（title/artist/album/durationMs/filePath）
    fun queryAudioFiles(activity: Activity): List<Map<String, Any?>> {
        val results = mutableListOf<Map<String, Any?>>()
        val collection: Uri = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI

        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.DISPLAY_NAME,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.ALBUM_ID,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.SIZE,
            MediaStore.Audio.Media.MIME_TYPE,
            MediaStore.Audio.Media.RELATIVE_PATH,
            MediaStore.Audio.Media.IS_MUSIC,
            // BITRATE 列在 API 30+ 可用，低版本查询会忽略不认识的列
            "bitrate",
        )

        val selectionBase = "${'$'}{MediaStore.Audio.Media.IS_MUSIC} != 0"
        val sortOrder = "${'$'}{MediaStore.Audio.Media.DATE_ADDED} DESC"

        // P0: 分页查询（LIMIT/OFFSET），避免一次性查询全部音频。
        // 个别 ContentProvider 不支持 LIMIT 语法，第一页失败时回退为单次全量查询。
        var offset = 0
        while (true) {
            var pageCount = 0
            val selection = "$selectionBase LIMIT $PAGE_SIZE OFFSET $offset"
            try {
                val cursor: Cursor? = activity.contentResolver.query(
                    collection, projection, selection, null, sortOrder
                )
                cursor?.use { c ->
                    pageCount = collectPage(c, results, collection)
                }
            } catch (_: Exception) {
                if (offset == 0) {
                    // 分页语法不被支持：回退全量查询
                    return queryAll(activity, collection, projection, selectionBase, sortOrder)
                }
                break
            }
            if (pageCount < PAGE_SIZE) break
            offset += PAGE_SIZE
        }
        return results
    }

    /// 从单个 cursor 页中收集音频信息行。
    /// @return 该页实际读取的行数（含被 MIME 过滤跳过的行）
    private fun collectPage(
        c: Cursor,
        results: MutableList<Map<String, Any?>>,
        collection: Uri
    ): Int {
        val idCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
        val nameCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.DISPLAY_NAME)
        val titleCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
        val artistCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
        val albumCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
        val albumIdCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM_ID)
        val durationCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
        val relativePathCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.RELATIVE_PATH)
        val mimeTypeCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.MIME_TYPE)
        // bitrate 列可能不存在（API < 30），用 getColumnIndex 安全获取
        val bitrateCol = c.getColumnIndex("bitrate")

        var count = 0
        while (c.moveToNext()) {
            count++
            val id = c.getLong(idCol)
            val contentUri: Uri = ContentUris.withAppendedId(collection, id)
            val displayName = c.getString(nameCol) ?: "unknown"
            val title = c.getString(titleCol)?.takeIf { it.isNotBlank() } ?: displayName
            val artist = c.getString(artistCol)?.takeIf { it.isNotBlank() } ?: "未知艺术家"
            val album = c.getString(albumCol)?.takeIf { it.isNotBlank() } ?: "未知专辑"
            val albumId = c.getLong(albumIdCol)
            val duration = c.getLong(durationCol)
            val relativePath = c.getString(relativePathCol) ?: ""
            val mimeType = c.getString(mimeTypeCol) ?: ""

            // 二次过滤：排除非音频 MIME type（部分设备将 .m3u8/.mp4 等标记为 IS_MUSIC）
            if (!isAudioMimeType(mimeType, displayName)) continue

            results.add(
                mapOf(
                    "filePath" to contentUri.toString(),
                    "displayName" to displayName,
                    "title" to title,
                    "artist" to artist,
                    "album" to album,
                    "albumId" to albumId,
                    "albumArtUri" to albumArtUri(albumId),
                    "durationMs" to duration,
                    "relativePath" to relativePath,
                    "mimeType" to mimeType,
                    // bitrate 可能不存在（API < 30 或部分设备不填充）
                    "bitrate" to if (bitrateCol >= 0) c.getInt(bitrateCol) else 0,
                )
            )
        }
        return count
    }

    /// 不支持分页时的回退：单次全量查询（保持原有行为）
    private fun queryAll(
        activity: Activity,
        collection: Uri,
        projection: Array<String>,
        selection: String,
        sortOrder: String
    ): List<Map<String, Any?>> {
        val results = mutableListOf<Map<String, Any?>>()
        try {
            val cursor: Cursor? = activity.contentResolver.query(
                collection, projection, selection, null, sortOrder
            )
            cursor?.use { c ->
                collectPage(c, results, collection)
            }
        } catch (_: Exception) {}
        return results
    }

    /// 把 `content://` URI 解析为 just_audio 可播放的真实文件路径。
    ///
    /// **背景**：`just_audio` 的 `setUrl` 不支持 `content://` 协议（无法解析），
    /// 会导致"播放没声音"（加载失败但 UI 进度条仍在动）。本地音乐通过 MediaStore
    /// 拿到的就是 `content://media/external/audio/media/{id}`，必须先解析为路径。
    ///
    /// **策略**：
    /// 1. 优先读取 MediaStore.Audio.Media.DATA 字段（部分厂商会保留真实路径），
    ///    命中且文件存在则直接返回。
    /// 2. 兜底：将 content URI 拷贝到 App 私有缓存目录
    ///    (`filesDir/local_music_cache/<uri_hash>.<ext>`)，返回真实路径。
    ///    同一 URI 多次调用复用同一缓存。
    ///
    /// @param activity Activity（访问 ContentResolver/filesDir）
    /// @param contentUriStr `content://media/...` 形式的 URI 字符串
    /// @return 真实可读的文件路径；解析失败时返回 null
    fun resolveLocalPath(activity: Activity, contentUriStr: String): String? {
        val contentUri = try {
            Uri.parse(contentUriStr)
        } catch (_: Exception) {
            return null
        }
        if (contentUri.scheme != "content") return contentUriStr

        // 1) 尝试 MediaStore.Audio.Media.DATA
        try {
            val cursor = activity.contentResolver.query(
                contentUri,
                arrayOf(MediaStore.Audio.Media.DATA),
                null,
                null,
                null
            )
            cursor?.use { c ->
                if (c.moveToFirst()) {
                    val dataIdx = c.getColumnIndex(MediaStore.Audio.Media.DATA)
                    if (dataIdx >= 0) {
                        val data = c.getString(dataIdx)
                        if (!data.isNullOrBlank() && File(data).exists()) {
                            return data
                        }
                    }
                }
            }
        } catch (_: Exception) {
            // 部分设备上 DATA 列为空或抛 SecurityException，继续走兜底
        }

        // 2) 兜底：拷贝到 App 私有目录
        return try {
            val cacheDir = File(activity.filesDir, "local_music_cache").apply { mkdirs() }
            val ext = guessExt(activity, contentUri)
            // 用 URI 字符串的稳定 hash 作为缓存文件名，避免重复拷贝
            val cacheName = "${contentUriStr.hashCode()}.$ext"
            val cacheFile = File(cacheDir, cacheName)
            if (cacheFile.exists() && cacheFile.length() > 0) {
                return cacheFile.absolutePath
            }
            activity.contentResolver.openInputStream(contentUri).use { input ->
                if (input == null) return null
                cacheFile.outputStream().use { output ->
                    input.copyTo(output)
                }
            }
            if (cacheFile.exists() && cacheFile.length() > 0) {
                cacheFile.absolutePath
            } else {
                null
            }
        } catch (_: Exception) {
            null
        }
    }

    /// 从 ContentResolver 推断文件扩展名（用于缓存文件名）。
    private fun guessExt(activity: Activity, uri: Uri): String {
        return try {
            val mime = activity.contentResolver.getType(uri)
            when {
                mime == null -> "mp3"
                mime.contains("flac") -> "flac"
                mime.contains("mp4") || mime.contains("m4a") || mime.contains("aac") -> "m4a"
                mime.contains("ogg") || mime.contains("opus") -> "ogg"
                mime.contains("wav") -> "wav"
                else -> "mp3"
            }
        } catch (_: Exception) {
            "mp3"
        }
    }

    /// 判断 MIME type 和文件名是否为纯音频格式。
    /// 排除视频容器（mp4/mov）、播放列表（m3u8/m3u/pls）和未知格式。
    private fun isAudioMimeType(mimeType: String, displayName: String): Boolean {
        val mime = mimeType.lowercase()
        // 明确排除的 MIME type 前缀
        if (mime.startsWith("video/") ||
            mime.contains("mpegurl") ||  // application/vnd.apple.mpegurl (.m3u8)
            mime.contains("x-mpegurl") ||
            mime == "audio/x-mpegurl" ||  // 部分 .m3u8 被标记为此类型
            mime == "application/octet-stream") {
            // octet-stream 需进一步检查扩展名
            if (mime == "application/octet-stream") {
                return hasAudioExtension(displayName)
            }
            return false
        }
        // 允许的音频 MIME type
        if (mime.startsWith("audio/")) return true
        // 非 audio/ 开头的，检查扩展名兜底
        return hasAudioExtension(displayName)
    }

    /// 检查文件名是否具有纯音频扩展名。
    private fun hasAudioExtension(displayName: String): Boolean {
        val ext = displayName.substringAfterLast('.', "").lowercase()
        return ext in setOf(
            "mp3", "flac", "m4a", "ogg", "opus", "wav", "aac", "ape", "wma",
            "aif", "aiff", "aifc"
        )
    }
}
