package com.md3music.md3music

import android.app.Activity
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.provider.DocumentsContract
import android.util.Log
import java.util.ArrayDeque
import java.io.File

/** 扫描用户通过 SAF 授权的目录（包括未进入 MediaStore 索引的 U 盘）。 */
object SafAudioScanner {
    private val supportedExtensions = setOf("mp3", "flac", "m4a", "ogg", "opus", "wav", "aac")

    fun queryAudioFiles(activity: Activity, treeUriText: String): List<Map<String, Any?>> {
        val treeUri = Uri.parse(treeUriText)
        val hasGrant = activity.contentResolver.persistedUriPermissions.any {
            it.uri == treeUri && it.isReadPermission
        }
        if (!hasGrant) throw SecurityException("目录授权已失效，请重新添加文件夹")

        val rootId = DocumentsContract.getTreeDocumentId(treeUri)
        val pending = ArrayDeque<String>()
        val visited = mutableSetOf<String>()
        val songs = mutableListOf<Map<String, Any?>>()
        val siblingDocuments = mutableMapOf<String, Map<String, Uri>>()
        pending.add(rootId)
        val columns = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
        )
        while (pending.isNotEmpty()) {
            val parentId = pending.removeLast()
            if (!visited.add(parentId)) continue
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
            try {
                activity.contentResolver.query(children, columns, null, null, null)?.use { cursor ->
                    val idCol = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                    val nameCol = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                    val mimeCol = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE)
                    while (cursor.moveToNext()) {
                        val id = cursor.getString(idCol) ?: continue
                        val name = cursor.getString(nameCol) ?: continue
                        val mime = cursor.getString(mimeCol) ?: ""
                        if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                            pending.add(id)
                            continue
                        }
                        if (name.substringAfterLast('.', "").lowercase() !in supportedExtensions) continue
                        val uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, id)
                        val folder = if (parentId == rootId) treeUri else
                            DocumentsContract.buildDocumentUriUsingTree(treeUri, parentId)
                        songs.add(
                            readSong(
                                activity, uri, folder.toString(), name, id, treeUri, parentId,
                                siblingDocuments
                            )
                        )
                    }
                }
            } catch (error: Exception) {
                Log.w("LibraryScan", "SAF 目录不可读: $parentId", error)
            }
        }
        return songs
    }

    private fun readSong(
        activity: Activity,
        uri: Uri,
        folder: String,
        name: String,
        documentId: String,
        treeUri: Uri,
        parentId: String,
        siblingDocuments: MutableMap<String, Map<String, Uri>>,
    ): Map<String, Any?> {
        var title = name.substringBeforeLast('.', name)
        var artist = "未知艺术家"
        var album = "未知专辑"
        var duration = 0L
        var bitrate = 0
        var artworkUri: String? = null
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(activity, uri)
            title = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_TITLE)
                ?.takeIf { it.isNotBlank() } ?: title
            artist = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ARTIST)
                ?.takeIf { it.isNotBlank() } ?: artist
            album = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ALBUM)
                ?.takeIf { it.isNotBlank() } ?: album
            duration = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 0L
            bitrate = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)
                ?.toIntOrNull() ?: 0
            retriever.embeddedPicture?.let { artwork ->
                if (artwork.isNotEmpty() && artwork.size <= 4 * 1024 * 1024) {
                    val artworkFile = File(activity.cacheDir, "local_music_artwork/${uri.toString().hashCode()}.img")
                    artworkFile.parentFile?.mkdirs()
                    artworkFile.writeBytes(artwork)
                    artworkUri = Uri.fromFile(artworkFile).toString()
                }
            }
        } catch (error: Exception) {
            Log.w("LibraryScan", "SAF 音频元数据读取失败: $uri", error)
        } finally {
            retriever.release()
        }
        val localLyrics = readSidecarLyrics(
            activity, treeUri, parentId, name, siblingDocuments
        )
        return mapOf(
            "filePath" to uri.toString(),
            "folderPath" to folder,
            "storageKey" to documentId,
            "displayName" to name,
            "title" to title,
            "artist" to artist,
            "album" to album,
            "durationMs" to duration,
            "bitrate" to bitrate,
            "artworkUri" to artworkUri,
            "localLyrics" to localLyrics,
        )
    }

    private fun readSidecarLyrics(
        activity: Activity,
        treeUri: Uri,
        parentId: String,
        audioName: String,
        siblingDocuments: MutableMap<String, Map<String, Uri>>,
    ): String? {
        val stem = audioName.substringBeforeLast('.', audioName)
        val documents = siblingDocuments.getOrPut(parentId) {
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
            val found = mutableMapOf<String, Uri>()
            val columns = arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            )
            activity.contentResolver.query(childrenUri, columns, null, null, null)?.use { cursor ->
                val idCol = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val nameCol = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                while (cursor.moveToNext()) {
                    val id = cursor.getString(idCol) ?: continue
                    val name = cursor.getString(nameCol) ?: continue
                    if (name.substringAfterLast('.', "").lowercase() in setOf("lrc", "ttml", "txt")) {
                        found[name.lowercase()] = DocumentsContract.buildDocumentUriUsingTree(treeUri, id)
                    }
                }
            }
            found
        }
        for (extension in listOf("lrc", "ttml", "txt")) {
            val sidecar = documents["${stem.lowercase()}.$extension"] ?: continue
            return try {
                activity.contentResolver.openInputStream(sidecar)?.use { input ->
                    val bytes = input.readBytes()
                    if (bytes.size <= 2 * 1024 * 1024) bytes.toString(Charsets.UTF_8) else null
                }
            } catch (error: Exception) {
                Log.w("LibraryScan", "SAF 同目录歌词读取失败: $sidecar", error)
                null
            }
        }
        return null
    }
}
