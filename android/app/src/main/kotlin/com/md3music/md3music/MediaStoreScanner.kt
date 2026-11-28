package com.md3music.md3music

import android.app.Activity
import android.content.ContentResolver
import android.os.Build
import android.os.Bundle
import android.util.Log
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
        // Android 10+ 的 VOLUME_EXTERNAL 是所有已挂载外部卷的合并视图，
        // EXTERNAL_CONTENT_URI 只覆盖主卷，会漏掉已索引的 U 盘音乐。
        val collection: Uri = if (Build.VERSION.SDK_INT >= 29) {
            MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        } else {
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        }

        val projection = mutableListOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.DISPLAY_NAME,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.ALBUM_ID,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.SIZE,
            MediaStore.Audio.Media.MIME_TYPE,
            MediaStore.Audio.Media.IS_MUSIC,
        )

        if (Build.VERSION.SDK_INT >= 29) projection.add(MediaStore.Audio.Media.RELATIVE_PATH)
        if (Build.VERSION.SDK_INT >= 29) projection.add(MediaStore.Audio.Media.VOLUME_NAME)
        if (Build.VERSION.SDK_INT >= 30) projection.add("bitrate")
        val columns = projection.toTypedArray()

        val selectionBase = "${MediaStore.Audio.Media.IS_MUSIC} != 0"
        val sortOrder = "${MediaStore.Audio.Media.DATE_ADDED} DESC"

        // P0: 分页查询（LIMIT/OFFSET），避免一次性查询全部音频。
        // 个别 ContentProvider 不支持 LIMIT 语法，第一页失败时回退为单次全量查询。
        if (Build.VERSION.SDK_INT < 26) {
            return queryAll(activity, collection, columns, selectionBase, sortOrder)
        }
        val seenIds = mutableSetOf<Long>()
        var offset = 0
        while (true) {
            var pageCount = 0
            val before = seenIds.size
            val args = Bundle().apply {
                putString(ContentResolver.QUERY_ARG_SQL_SELECTION, selectionBase)
                putString(ContentResolver.QUERY_ARG_SQL_SORT_ORDER, sortOrder)
                putInt(ContentResolver.QUERY_ARG_LIMIT, PAGE_SIZE)
                putInt(ContentResolver.QUERY_ARG_OFFSET, offset)
            }
            try {
                val cursor: Cursor? = activity.contentResolver.query(
                    collection, columns, args, null
                )
                cursor?.use { c ->
                    pageCount = collectPage(c, results, collection, seenIds)
                }
            } catch (e: Exception) {
                Log.w("LibraryScan", "分页查询失败，offset=$offset", e)
                if (offset == 0) {
                    // 分页语法不被支持：回退全量查询
                    return queryAll(activity, collection, columns, selectionBase, sortOrder)
                }
                break
            }
            // 某些厂商忽略 OFFSET。没有新 ID 时终止，不能反复追加同页直到 OOM。
            if (pageCount < PAGE_SIZE || seenIds.size == before) break
            offset += PAGE_SIZE
        }
        return results
    }

    /// 从单个 cursor 页中收集音频信息行。
    /// @return 该页实际读取的行数（含被 MIME 过滤跳过的行）
    private fun collectPage(
        c: Cursor,
        results: MutableList<Map<String, Any?>>,
        collection: Uri,
        seenIds: MutableSet<Long> = mutableSetOf()
    ): Int {
        val idCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
        val nameCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.DISPLAY_NAME)
        val titleCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
        val artistCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
        val albumCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
        val albumIdCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM_ID)
        val durationCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
        val relativePathCol = c.getColumnIndex(MediaStore.Audio.Media.RELATIVE_PATH)
        val volumeNameCol = c.getColumnIndex(MediaStore.Audio.Media.VOLUME_NAME)
        val mimeTypeCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.MIME_TYPE)
        // bitrate 列可能不存在（API < 30），用 getColumnIndex 安全获取
        val bitrateCol = c.getColumnIndex("bitrate")

        var count = 0
        while (c.moveToNext()) {
            count++
            try {
                val id = c.getLong(idCol)
                if (!seenIds.add(id)) continue
                val contentUri: Uri = ContentUris.withAppendedId(collection, id)
                val displayName = c.getString(nameCol) ?: "unknown"
                val title = c.getString(titleCol)?.takeIf { it.isNotBlank() } ?: displayName
                val artist = c.getString(artistCol)?.takeIf { it.isNotBlank() } ?: "未知艺术家"
                val album = c.getString(albumCol)?.takeIf { it.isNotBlank() } ?: "未知专辑"
                val albumId = c.getLong(albumIdCol)
                val duration = c.getLong(durationCol)
                val relativePath = if (relativePathCol >= 0) c.getString(relativePathCol) ?: "" else ""
                val volumeName = if (volumeNameCol >= 0) c.getString(volumeNameCol) ?: "" else ""
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
                        "volumeName" to volumeName,
                        "mimeType" to mimeType,
                        // bitrate 可能不存在（API < 30 或部分设备不填充）
                        "bitrate" to if (bitrateCol >= 0) c.getInt(bitrateCol) else 0,
                    )
                )
            } catch (e: Exception) {
                Log.w("LibraryScan", "跳过异常 MediaStore 行", e)
            }
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
        } catch (e: Exception) {
            Log.w("LibraryScan", "MediaStore 全量查询失败", e)
        }
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
            val (displayName, expectedSize) = queryNameAndSize(activity, contentUri)
            val ext = guessExt(activity, contentUri, displayName)
            // 用 URI 字符串的稳定 hash 作为缓存文件名，避免重复拷贝
            val cacheName = "${contentUriStr.hashCode()}.$ext"
            val cacheFile = File(cacheDir, cacheName)
            // 命中缓存时必须识别「比源文件更小」的截断文件：旧实现只判 length>0，
            // 拷贝被中断（进程被杀/空间不足）留下的截断文件会被永久复用 ——
            // m4a 的 moov box 常在文件尾部，截断即无法解析，表现为「这首歌永远打不开」。
            if (isCacheUsable(cacheFile, expectedSize)) {
                return cacheFile.absolutePath
            }
            // 先写临时文件再原子改名：任何中途失败都不会留下「非空但残缺」的正式缓存。
            val tempFile = File(cacheDir, "$cacheName.part")
            try {
                activity.contentResolver.openInputStream(contentUri).use { input ->
                    if (input == null) return null
                    tempFile.outputStream().use { output ->
                        input.copyTo(output)
                    }
                }
                // 刚拷完的临时文件只校验非空：copyTo 未抛异常即代表读到了流尾，
                // 此时再用 MediaStore 的 SIZE 判等，遇到 SIZE 偏高反而会误删完整文件。
                if (!tempFile.exists() || tempFile.length() <= 0) {
                    tempFile.delete()
                    return null
                }
                // 拷贝完成后再改名。顺序上的关键点：不先删旧缓存 ——
                // 万一 rename 失败，旧文件（可能仍可用）不会被一并毁掉；
                // renameTo 在 POSIX 上本来就覆盖目标，Android 私有目录同一文件系统内即为原子操作。
                if (!tempFile.renameTo(cacheFile)) {
                    tempFile.delete()
                    // 改名失败但旧缓存可用时，退回旧缓存（比让整首歌失败更好）
                    return if (isCacheUsable(cacheFile, expectedSize)) cacheFile.absolutePath else null
                }
                cacheFile.absolutePath
            } catch (t: Exception) {
                tempFile.delete()
                throw t
            }
        } catch (_: Exception) {
            null
        }
    }

    /// 判断缓存文件是否可用。
    ///
    /// [expectedSize] 只用来识别「比源文件更小」的截断缓存（旧版本会留下这种文件）。
    /// **不能用等值判定**：MediaStore 的 SIZE 在部分设备上过时或不准，等值校验会把
    /// 本来能播的缓存判成损坏、每次播放都重拷整首；缓存反而更大时也说明 SIZE 不可信。
    /// 真实拷贝的完整性由 `.part` + 原子改名保证（中断的拷贝永远不会成为正式缓存）。
    private fun isCacheUsable(file: File, expectedSize: Long?): Boolean =
        isCachedFileComplete(file.exists(), file.length(), expectedSize)

    /// 从 ContentResolver 推断文件扩展名（用于缓存文件名）。
    ///
    /// **不能一律兜底 "mp3"**：部分设备对 m4a/flac 返回空 MIME 或
    /// `application/octet-stream`，旧实现会把这类文件命名成 `<hash>.mp3`。
    /// 字节流不变（Media3 靠嗅探选解复用器，仍能解码），但音质标签/编码显示
    /// 与所有按扩展名判断的逻辑都会被误导（实测 m4a 被标成 MP3 音质）。
    /// 因此 MIME 缺失或不认识时，回退到 [displayName] 的真实扩展名。
    private fun guessExt(activity: Activity, uri: Uri, displayName: String?): String {
        val mime = try {
            activity.contentResolver.getType(uri)
        } catch (_: Exception) {
            null
        }
        return extensionFor(mime, displayName)
    }

    /// MIME + 文件名 → 缓存扩展名（纯函数，便于单测）。
    ///
    /// MIME 优先：它来自系统解码器注册表，比扩展名可信。MIME 缺失或不认识时
    /// 才回退文件名，最后兜底 "mp3"（保持与旧行为一致的最后一级）。
    internal fun extensionFor(mime: String?, displayName: String?): String {
        if (mime != null) {
            val m = mime.lowercase()
            when {
                m.contains("flac") -> return "flac"
                m.contains("mp4") || m.contains("m4a") || m.contains("aac") -> return "m4a"
                m.contains("ogg") || m.contains("opus") -> return "ogg"
                m.contains("wav") -> return "wav"
                m.contains("mpeg") || m.contains("mp3") -> return "mp3"
            }
        }
        val fromName = displayName?.substringAfterLast('.', "")?.lowercase()
        if (!fromName.isNullOrBlank() && hasAudioExtension(displayName)) return fromName
        return "mp3"
    }

    /// 缓存文件是否可用（纯函数，便于单测）。
    ///
    /// 只用「小于」判截断，不用等值：见 [isCacheUsable] 的说明。
    internal fun isCachedFileComplete(
        exists: Boolean,
        actualLength: Long,
        expectedSize: Long?,
    ): Boolean {
        if (!exists || actualLength <= 0) return false
        if (expectedSize != null && expectedSize > 0 && actualLength < expectedSize) {
            return false
        }
        return true
    }

    /// 一次查询取回 DISPLAY_NAME 与 SIZE：前者用于扩展名兜底，后者用于校验拷贝完整性。
    /// 任一列不可用或查询失败时对应项为 null。
    private fun queryNameAndSize(activity: Activity, uri: Uri): Pair<String?, Long?> {
        var name: String? = null
        var size: Long? = null
        try {
            activity.contentResolver.query(
                uri,
                arrayOf(MediaStore.Audio.Media.DISPLAY_NAME, MediaStore.Audio.Media.SIZE),
                null,
                null,
                null
            )?.use { c ->
                if (c.moveToFirst()) {
                    val nameIdx = c.getColumnIndex(MediaStore.Audio.Media.DISPLAY_NAME)
                    if (nameIdx >= 0 && !c.isNull(nameIdx)) name = c.getString(nameIdx)
                    val sizeIdx = c.getColumnIndex(MediaStore.Audio.Media.SIZE)
                    if (sizeIdx >= 0 && !c.isNull(sizeIdx)) {
                        val value = c.getLong(sizeIdx)
                        if (value > 0) size = value
                    }
                }
            }
        } catch (_: Exception) {
            // 个别 provider 不支持这两列：都按「未知」处理，不阻塞播放
        }
        return name to size
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
