package com.md3music.md3music

import android.content.Context
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 嵌入式 API 服务器入口：加载 libkugou_server.so（Rust cdylib），
 * 通过 JNI 启动/停止 127.0.0.1 上随机端口的 HTTP 服务器（取代旧的
 * libnode.so + server_bundle.js 方案），并把实际端口回传给 Dart。
 *
 * 注意：JNI 符号名含包名（Java_com_md3music_md3music_KugouApiService_*），
 * 如果 .so 是旧包名编译的，JNI 会找不到符号。此时 MethodChannel 返回错误，
 * Dart 端会走 dart:ffi 兜底路径（纯 C 函数 start_server 等不含包名）。
 */
class KugouApiService(private val context: Context, flutterEngine: FlutterEngine) {
    companion object {
        private const val TAG = "KugouApiService"
        private const val CHANNEL = "com.md3music.md3music/kugou_api"

        // 延迟加载 + 捕获异常，避免 JNI 符号不匹配时类加载直接崩溃
        private var libLoaded = false

        private fun ensureLibLoaded(): Boolean {
            if (libLoaded) return true
            return try {
                System.loadLibrary("kugou_server")
                libLoaded = true
                true
            } catch (e: UnsatisfiedLinkError) {
                Log.e(TAG, "Failed to load kugou_server: ${e.message}")
                false
            }
        }
    }

    private val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
    // external 方法保留，但调用前必须先 ensureLibLoaded() 且捕获 UnsatisfiedLinkError
    private external fun nativeStartNode(port: Int, dataDir: String): Int
    private external fun nativeIsNodeRunning(): Boolean
    private external fun nativeStopNode()

    init {
        Log.d(TAG, "KugouApiService init - registering MethodChannel: $CHANNEL")

        channel.setMethodCallHandler { call, result ->
            Log.d(TAG, "MethodChannel called: ${call.method}")
            when (call.method) {
                "startServer" -> {
                    Thread {
                        try {
                            if (!ensureLibLoaded()) {
                                result.error("LIB_LOAD_FAILED", "kugou_server library not loaded", null)
                                return@Thread
                            }
                            // 返回实际监听端口（随机端口模式），Dart 端据此设置 baseUrl
                            val port = startNodeServer()
                            if (port > 0) {
                                result.success(port)
                            } else {
                                result.error("START_FAILED", "No free port after 10 attempts", null)
                            }
                        } catch (e: UnsatisfiedLinkError) {
                            Log.e(TAG, "JNI symbol not found: ${e.message}")
                            result.error("JNI_NOT_FOUND", e.message, null)
                        } catch (e: Exception) {
                            Log.e(TAG, "Failed to start server", e)
                            result.error("START_FAILED", e.message, null)
                        }
                    }.start()
                }
                "isRunning" -> {
                    try {
                        if (!ensureLibLoaded()) {
                            result.success(false)
                        } else {
                            result.success(nativeIsNodeRunning())
                        }
                    } catch (e: UnsatisfiedLinkError) {
                        result.success(false)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "stopServer" -> {
                    Thread {
                        try {
                            if (ensureLibLoaded()) {
                                nativeStopNode()
                            }
                            result.success(true)
                        } catch (e: UnsatisfiedLinkError) {
                            result.success(true)
                        } catch (e: Exception) {
                            Log.e(TAG, "Failed to stop server", e)
                            result.error("STOP_FAILED", e.message, null)
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * 启动本地 API 服务器。port 传 0 由 Rust 侧随机选择（被占用则 1s 后换下一个，
     * 最多 10 次）。返回实际监听端口，失败返回 0。
     */
    private fun startNodeServer(): Int {
        if (nativeIsNodeRunning()) {
            // 已在运行：nativeStartNode 会返回当前端口
            return nativeStartNode(0, context.filesDir.absolutePath)
        }
        val dataDir = context.filesDir.absolutePath
        Log.d(TAG, "Starting kugou_server with random port, dataDir=$dataDir")
        val port = nativeStartNode(0, dataDir)
        if (port <= 0) {
            Log.e(TAG, "start_server returned $port (no free port after retries)")
        } else {
            Log.d(TAG, "kugou_server started successfully on port $port")
        }
        return port
    }

    /** Activity 销毁 / onTrimMemory 时确定性关停，释放本地 API 服务器端口。 */
    fun stopServer() {
        try {
            if (libLoaded) {
                nativeStopNode()
                Log.d(TAG, "kugou_server stop requested")
            }
        } catch (e: Exception) {
            Log.e(TAG, "stopServer failed: ${e.message}")
        } catch (e: UnsatisfiedLinkError) {
            // ignore
        }
    }
}
