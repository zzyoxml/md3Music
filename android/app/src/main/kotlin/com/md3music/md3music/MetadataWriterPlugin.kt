package com.md3music.md3music

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.jaudiotagger.audio.AudioFileIO
import org.jaudiotagger.tag.FieldKey
import java.io.File
import java.util.logging.Level
import java.util.logging.Logger

/**
 * 元数据写入插件：通过 MethodChannel "com.md3music.md3music/metadata" 暴露 writeMetadata
 *
 * Dart 端在下载完成后调用，将以下信息嵌入音频文件：
 * - 标题 / 艺术家 / 专辑（写入 ID3v2 TIT2/TPE1/TALB 或 FLAC VorbisComment）
 * - 专辑封面（写入 ID3v2 APIC 或 FLAC METADATA_BLOCK_PICTURE）
 * - 歌词（写入 ID3v2 USLT 或 FLAC LYRICS）
 *
 * 使用 JAudioTagger 社区分叉（com.github.AdrienPoupa:jaudiotagger），
 * 原生支持 MP3 / FLAC / OGG / M4A 等格式的标签读写。
 *
 * 任何异常都吞掉返回 error，不阻断下载流程。
 */
class MetadataWriterPlugin {

    companion object {
        private const val CHANNEL_NAME = "com.md3music.md3music/metadata"
    }

    /**
     * 在 FlutterEngine 上注册 MethodChannel。
     * 应在 MainActivity.configureFlutterEngine 中调用。
     */
    fun register(flutterEngine: FlutterEngine) {
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME
        )
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "writeMetadata" -> handleWriteMetadata(call, result)
                else -> result.notImplemented()
            }
        }
    }

    /**
     * 处理 writeMetadata 调用：读取音频文件 → 写入标签 → commit。
     *
     * 参数（通过 call.argument 读取）：
     * - filePath: String (必填)
     * - title:    String (默认 "")
     * - artist:   String (默认 "")
     * - album:    String (默认 "")
     * - artworkPath: String? (可选，封面图本地路径)
     * - lyrics:   String? (可选，LRC 文本)
     */
    private fun handleWriteMetadata(
        call: io.flutter.plugin.common.MethodCall,
        result: io.flutter.plugin.common.MethodChannel.Result,
    ) {
        val filePath = call.argument<String>("filePath")
        if (filePath.isNullOrEmpty()) {
            result.error("INVALID_ARGUMENT", "filePath is required", null)
            return
        }

        val title = call.argument<String>("title") ?: ""
        val artist = call.argument<String>("artist") ?: ""
        val album = call.argument<String>("album") ?: ""
        val artworkPath = call.argument<String>("artworkPath")
        val lyrics = call.argument<String>("lyrics")

        val file = File(filePath)
        android.util.Log.d("MetadataWriter", "▶ writeMetadata filePath=$filePath exists=${file.exists()} size=${file.length()}")
        android.util.Log.d("MetadataWriter", "  title=$title artist=$artist album=$album")
        android.util.Log.d("MetadataWriter", "  artworkPath=$artworkPath lyricsLen=${lyrics?.length ?: 0}")

        if (!file.exists()) {
            android.util.Log.e("MetadataWriter", "❌ FILE_NOT_FOUND: $filePath")
            result.error("FILE_NOT_FOUND", "audio file not found: $filePath", null)
            return
        }

        try {
            // 静音 JAudioTagger 内部日志，避免污染 logcat
            try {
                Logger.getLogger("org.jaudiotagger").level = Level.OFF
            } catch (_: Throwable) {
                // 不同版本 API 略有差异，吞掉
            }

            android.util.Log.d("MetadataWriter", "  reading audio file...")
            val audioFile = AudioFileIO.read(file)
            android.util.Log.d("MetadataWriter", "  audioFile type=${audioFile.javaClass.simpleName} audioHeader=${audioFile.audioHeader}")
            val tag = audioFile.tagOrCreateAndSetDefault
            android.util.Log.d("MetadataWriter", "  tag type=${tag.javaClass.simpleName}")

            if (title.isNotEmpty()) {
                tag.setField(FieldKey.TITLE, title)
            }
            if (artist.isNotEmpty()) {
                tag.setField(FieldKey.ARTIST, artist)
            }
            if (album.isNotEmpty()) {
                tag.setField(FieldKey.ALBUM, album)
            }

            // 写入专辑封面（MP3 → APIC，FLAC → METADATA_BLOCK_PICTURE）
            if (!artworkPath.isNullOrEmpty()) {
                val artFile = File(artworkPath)
                android.util.Log.d("MetadataWriter", "  artwork exists=${artFile.exists()} size=${artFile.length()}")
                if (artFile.exists()) {
                    // 使用 FixedAndroidArtwork 绕过 AndroidArtwork.setImageFromData()
                    // 中的 UnsupportedOperationException（Android 缺少 ImageIO）
                    val artwork = FixedAndroidArtwork.createFromFile(artFile)
                    // 先删除旧封面避免重复（部分格式 createField 会叠加）
                    try { tag.deleteArtworkField() } catch (_: Throwable) {}
                    tag.setField(artwork)
                    android.util.Log.d("MetadataWriter", "  artwork set OK")
                }
            }

            // 写入歌词（MP3 → USLT，FLAC → LYRICS）
            if (!lyrics.isNullOrEmpty()) {
                tag.setField(FieldKey.LYRICS, lyrics)
                android.util.Log.d("MetadataWriter", "  lyrics set OK")
            }

            android.util.Log.d("MetadataWriter", "  committing...")
            audioFile.commit()
            android.util.Log.d("MetadataWriter", "✅ commit success")
            result.success(true)
        } catch (e: Exception) {
            android.util.Log.e("MetadataWriter", "❌ WRITE_FAILED", e)
            // 写入失败不阻断下载流程，Dart 端 fallback 处理
            result.error("WRITE_FAILED", "${e.javaClass.simpleName}: ${e.message}", e.stackTraceToString())
        }
    }
}
