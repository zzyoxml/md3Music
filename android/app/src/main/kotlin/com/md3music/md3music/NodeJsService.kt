package com.md3music.md3music

import android.content.Context
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class NodeJsService(private val context: Context, flutterEngine: FlutterEngine) {
    companion object {
        private const val TAG = "NodeJsService"
        private const val CHANNEL = "com.md3music.md3music/nodejs"
        private const val NODEJS_PROJECT_DIR = "nodejs-project"

        init {
            System.loadLibrary("nodejs_bridge")
        }
    }

    private val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
    private external fun nativeStartNode(args: Array<String>, modulesPath: String): Int
    private external fun nativeIsNodeRunning(): Boolean
    private external fun nativeStopNode()

    private var nodeProjectPath: String = ""

    init {
        nodeProjectPath = "${context.filesDir.absolutePath}/$NODEJS_PROJECT_DIR"
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
                            Log.e(TAG, "Failed to start Node.js", e)
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
                            stopServer()
                            result.success(true)
                        } catch (e: Exception) {
                            Log.e(TAG, "Failed to stop Node.js", e)
                            result.error("STOP_FAILED", e.message, null)
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startNodeServer() {
        killOldNodeProcesses()

        val projectDir = File(nodeProjectPath)
        if (!projectDir.exists()) {
            projectDir.mkdirs()
        }

        val bundleFile = File(projectDir, "server_bundle.js")
        copyAssetFile("assets/nodejs-project/server_bundle.js", bundleFile.absolutePath)
        Log.d(TAG, "Copied server_bundle.js to ${bundleFile.absolutePath}")

        if (!bundleFile.exists()) {
            Log.e(TAG, "server_bundle.js not found after copy!")
            return
        }

        try {
            android.system.Os.setenv("TMPDIR", context.cacheDir.absolutePath, true)
            android.system.Os.setenv("NODE_SERVER_DIR", nodeProjectPath, true)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to set env vars", e)
        }

        val args = arrayOf(bundleFile.absolutePath)
        val modulesPath = nodeProjectPath
        Log.d(TAG, "Starting Node.js with script: ${bundleFile.absolutePath}")
        nativeStartNode(args, modulesPath)
    }

    private fun copyAssetFile(assetPath: String, targetPath: String) {
        val possiblePaths = listOf(
            "flutter_assets/$assetPath",
            assetPath,
            "assets/$assetPath"
        )
        
        for (path in possiblePaths) {
            try {
                context.assets.open(path).use { input ->
                    File(targetPath).parentFile?.mkdirs()
                    FileOutputStream(File(targetPath)).use { output ->
                        input.copyTo(output)
                    }
                }
                Log.d(TAG, "Copied asset: $path -> $targetPath")
                return
            } catch (e: Exception) {
                Log.d(TAG, "Path not found: $path")
            }
        }
        Log.e(TAG, "Failed to copy asset, tried paths: $possiblePaths")
    }

    fun stopServer() {
        Log.d(TAG, "Stopping Node.js server...")
        nativeStopNode()
    }

    private fun killOldNodeProcesses() {
        try {
            Runtime.getRuntime().exec(arrayOf("sh", "-c", "killall -9 node 2>/dev/null || true"))
            Log.d(TAG, "Killed old node processes")
            Thread.sleep(500)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to kill old processes: ${e.message}")
        }
    }
}
