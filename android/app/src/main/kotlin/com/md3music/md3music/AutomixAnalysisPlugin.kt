package com.md3music.md3music

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.nio.ByteOrder
import java.util.concurrent.Executors

/**
 * AutoMix 分析用的 PCM 解码器：把音源**曲首**若干秒解码为单声道 Int16 PCM，
 * 交给 Dart 侧做 BPM / 拍点 / 响度分析（DSP 放 Dart 是为了可单测）。
 *
 * 只解曲首 [DEFAULT_WINDOW_MS]：BPM 是整曲属性，且能省掉整曲下载与解码。
 */
class AutomixAnalysisPlugin : MethodChannel.MethodCallHandler {

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != METHOD_DECODE_HEAD) {
            result.notImplemented()
            return
        }
        val uri = call.argument<String>("uri")
        val windowMs = call.argument<Int>("windowMs") ?: DEFAULT_WINDOW_MS
        if (uri.isNullOrEmpty()) {
            result.error("BAD_ARGS", "uri is required", null)
            return
        }
        executor.execute {
            val out = runCatching { decodeHead(uri, windowMs) }.getOrNull()
            mainHandler.post {
                if (out == null) result.error("DECODE_FAILED", "decode failed: $uri", null)
                else result.success(out)
            }
        }
    }

    private fun decodeHead(uri: String, windowMs: Int): Map<String, Any?>? {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(uri, HashMap<String, String>())
        } catch (t: Throwable) {
            extractor.release()
            return null
        }
        var track = -1
        var format: MediaFormat? = null
        for (i in 0 until extractor.trackCount) {
            val f = extractor.getTrackFormat(i)
            if (f.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                track = i
                format = f
                break
            }
        }
        if (track < 0 || format == null) {
            extractor.release()
            return null
        }
        val mime = format.getString(MediaFormat.KEY_MIME) ?: return null
        val sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        val channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        if (sampleRate <= 0 || channels <= 0) {
            extractor.release()
            return null
        }
        extractor.selectTrack(track)

        val codec = runCatching { MediaCodec.createDecoderByType(mime) }.getOrNull()
            ?: run { extractor.release(); return null }
        try {
            codec.configure(format, null, null, 0)
            codec.start()
            // 只处理 16bit PCM 输出：float/24bit  packed 输出会让下面的取帧逻辑错位，
            // 遇到就放弃分析（Dart 侧走回退），不要猜测格式。
            val outFormat = codec.outputFormat
            if (outFormat.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                outFormat.getInteger(MediaFormat.KEY_PCM_ENCODING) !=
                AudioFormat.ENCODING_PCM_16BIT
            ) {
                return null
            }

            val info = MediaCodec.BufferInfo()
            val targetFrames = sampleRate * windowMs / 1000
            val deadline = System.currentTimeMillis() + DECODE_TIMEOUT_MS
            val bytes = ByteArrayOutputStream()
            var produced = 0
            var inputEos = false

            while (produced < targetFrames && System.currentTimeMillis() < deadline) {
                if (!inputEos) {
                    val inIdx = codec.dequeueInputBuffer(TIMEOUT_US)
                    if (inIdx >= 0) {
                        val buf = codec.getInputBuffer(inIdx) ?: break
                        val size = extractor.readSampleData(buf, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputEos = true
                        } else {
                            codec.queueInputBuffer(inIdx, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                // 注意：不能写 `when (outIdx) { >= 0 -> }`——带 subject 的 when 分支只接受
                // 表达式/常量/in/is，`>= 0` 不是合法表达式（缺左操作数），编译不过。
                val outIdx = codec.dequeueOutputBuffer(info, TIMEOUT_US)
                if (outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val f = codec.outputFormat
                    if (f.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                        f.getInteger(MediaFormat.KEY_PCM_ENCODING) != AudioFormat.ENCODING_PCM_16BIT
                    ) return null
                } else if (outIdx >= 0) {
                    val buf = codec.getOutputBuffer(outIdx)
                    if (buf != null && info.size > 0) {
                        // MediaCodec 输出的是本机字节序（Android 为小端），而 getShort() 默认大端，
                        // 不设置就会把每个样本的高低字节读反。
                        buf.order(ByteOrder.LITTLE_ENDIAN)
                        val frames = info.size / (2 * channels)
                        for (f in 0 until frames) {
                            if (produced >= targetFrames) break
                            var acc = 0
                            for (c in 0 until channels) {
                                // 有效数据从 info.offset 开始，不是缓冲区 0 位。
                                acc += buf.getShort(info.offset + (f * channels + c) * 2).toInt()
                            }
                            val mono = (acc / channels).coerceIn(-32768, 32767)
                            bytes.write(mono and 0xFF)
                            bytes.write((mono shr 8) and 0xFF)
                            produced++
                        }
                    }
                    codec.releaseOutputBuffer(outIdx, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
            }
            if (produced <= 0) return null
            return mapOf(
                "sampleRate" to sampleRate,
                "pcm" to bytes.toByteArray(),
                "decodedMs" to (produced * 1000L / sampleRate).toInt(),
            )
        } catch (t: Throwable) {
            return null
        } finally {
            runCatching { codec.stop() }
            runCatching { codec.release() }
            runCatching { extractor.release() }
        }
    }

    companion object {
        const val CHANNEL = "com.md3music.md3music/automix_analysis"
        const val METHOD_DECODE_HEAD = "decodeHead"
        const val DEFAULT_WINDOW_MS = 25000
        private const val DECODE_TIMEOUT_MS = 10_000L
        private const val TIMEOUT_US = 15_000L
    }
}
