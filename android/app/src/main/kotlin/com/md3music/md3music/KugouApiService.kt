package com.md3music.md3music

import android.content.Context
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 嵌入式 API 服务器入口：加载 libkugou_server.so（Rust cdylib），
 * 通过 JNI 启动/停止 127.0.0.1:8080 的 HTTP 服务器（取代旧的
 * libnode.so + server_bundle.js 方案）。
 */
class KugouApiService(private val context: Context, flutterEngine: FlutterEngine) {
    companion object {
        private const val TAG = "KugouApiService"
        private const val CHANNEL = "com.md3music.md3music/kugou_api"
        private const val DEFAULT_PORT = 8080

        init {
            System.loadLibrary("kugou_server")
        }
    }

    private val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
    private external fun nativeStartNode(port: Int, dataDir: String): Int
    private external fun nativeIsNodeRunning(): Boolean
    private external fun nativeStopNode()

    init {
        Log.d(TAG, "NodeJsService init - registering MethodChannel: $CHANNEL")

        channel.setMethodCallHandler { call, result ->
            Log.d(TAG, "MethodChannel called: ${call.method}")
            when (call.method) {
                "startServer" -> {
                    Thread {
                        try {
                            startNodeServer()
                            result.success(true)
                        } catch (e: Exception) {
                            Log.e(TAG, "Failed to start server", e)
                            result.error("START_FAILED", e.message, null)
                        }
                    }.start()
                }
                "isRunning" -> {
                    result.success(nativeIsNodeRunning())
                }
                "stopServer" -> {
                    Thread {
                        try {
                            nativeStopNode()
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

    private fun startNodeServer() {
        if (nativeIsNodeRunning()) {
            Log.w(TAG, "Server already running, skipping")
            return
        }
        val dataDir = context.filesDir.absolutePath
        Log.d(TAG, "Starting kugou_server on port $DEFAULT_PORT, dataDir=$dataDir")
        val result = nativeStartNode(DEFAULT_PORT, dataDir)
        if (result != 1) {
            Log.e(TAG, "start_server returned $result (port busy or init failed)")
        } else {
            Log.d(TAG, "kugou_server started successfully")
        }
    }

    /** Activity 销毁 / onTrimMemory 时确定性关停，释放 8080 端口。 */
    fun stopServer() {
        try {
            nativeStopNode()
            Log.d(TAG, "kugou_server stop requested")
        } catch (e: Exception) {
            Log.e(TAG, "stopServer failed: ${e.message}")
        }
    }
}
