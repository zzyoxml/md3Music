package com.md3music.md3music

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.URL

class MainActivity : FlutterActivity() {
    private val FLOATING_CHANNEL = "com.md3music.md3music/floating_lyric"
    private val NOTIFICATION_CHANNEL = "com.md3music.md3music.channel.audio"
    private val NOTIFICATION_ID = 1002
    private var notificationManager: NotificationManager? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        createNotificationChannel()

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FLOATING_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startFloatingLyric" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
                            val intent = Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:$packageName")
                            )
                            startActivity(intent)
                            result.error("PERMISSION_DENIED", "需要悬浮窗权限", null)
                        } else {
                            val intent = Intent(this, FloatingLyricService::class.java).apply {
                                action = FloatingLyricService.ACTION_UPDATE_LYRIC
                                putExtra(FloatingLyricService.EXTRA_LYRIC, call.argument<String>("lyric") ?: "")
                                putExtra(FloatingLyricService.EXTRA_TITLE, call.argument<String>("title") ?: "")
                            }
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(true)
                        }
                    }
                    "updateLyric" -> {
                        val intent = Intent(this, FloatingLyricService::class.java).apply {
                            action = FloatingLyricService.ACTION_UPDATE_LYRIC
                            putExtra(FloatingLyricService.EXTRA_LYRIC, call.argument<String>("lyric") ?: "")
                        }
                        startService(intent)
                        result.success(true)
                    }
                    "updateTitle" -> {
                        val intent = Intent(this, FloatingLyricService::class.java).apply {
                            action = FloatingLyricService.ACTION_UPDATE_TITLE
                            putExtra(FloatingLyricService.EXTRA_TITLE, call.argument<String>("title") ?: "")
                        }
                        startService(intent)
                        result.success(true)
                    }
                    "stopFloatingLyric" -> {
                        val intent = Intent(this, FloatingLyricService::class.java).apply {
                            action = FloatingLyricService.ACTION_STOP
                        }
                        startService(intent)
                        result.success(true)
                    }
                    "hasOverlayPermission" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            result.success(Settings.canDrawOverlays(this))
                        } else {
                            result.success(true)
                        }
                    }
                    "showNotification" -> {
                        showMediaNotification(
                            title = call.argument<String>("title") ?: "",
                            artist = call.argument<String>("artist") ?: "",
                            artUrl = call.argument<String>("artUrl"),
                            isPlaying = call.argument<Boolean>("isPlaying") ?: false,
                        )
                        result.success(true)
                    }
                    "updateNotification" -> {
                        updateNotification(
                            title = call.argument<String>("title") ?: "",
                            artist = call.argument<String>("artist") ?: "",
                            artUrl = call.argument<String>("artUrl"),
                            isPlaying = call.argument<Boolean>("isPlaying") ?: false,
                        )
                        result.success(true)
                    }
                    "hideNotification" -> {
                        notificationManager?.cancel(NOTIFICATION_ID)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL,
                "音乐播放",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "音乐播放控制"
                setShowBadge(false)
            }
            notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager?.createNotificationChannel(channel)
        } else {
            notificationManager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        }
    }

    private fun showMediaNotification(
        title: String,
        artist: String,
        artUrl: String?,
        isPlaying: Boolean,
    ) {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(title)
            .setContentText(artist)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)

        if (artUrl != null && artUrl.isNotEmpty()) {
            Thread {
                try {
                    val url = URL(artUrl)
                    val bitmap = BitmapFactory.decodeStream(url.openStream())
                    if (bitmap != null) {
                        builder.setLargeIcon(bitmap)
                        builder.setStyle(
                            NotificationCompat.BigPictureStyle()
                                .bigPicture(bitmap)
                                .bigLargeIcon(null as Bitmap?)
                        )
                    }
                } catch (_: Exception) {}
                notificationManager?.notify(NOTIFICATION_ID, builder.build())
            }.start()
        } else {
            notificationManager?.notify(NOTIFICATION_ID, builder.build())
        }
    }

    private fun updateNotification(
        title: String,
        artist: String,
        artUrl: String?,
        isPlaying: Boolean,
    ) {
        showMediaNotification(title, artist, artUrl, isPlaying)
    }
}
