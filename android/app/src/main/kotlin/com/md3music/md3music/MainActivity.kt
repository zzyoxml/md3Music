package com.md3music.md3music

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
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
    private var mediaSession: MediaSessionCompat? = null

    private fun sendFlutterCommand(method: String) {
        val engine = flutterEngine ?: return
        MethodChannel(engine.dartExecutor.binaryMessenger, FLOATING_CHANNEL)
            .invokeMethod(method, null)
    }

    private fun sendFlutterCommandWithArg(method: String, arg: Long) {
        val engine = flutterEngine ?: return
        MethodChannel(engine.dartExecutor.binaryMessenger, FLOATING_CHANNEL)
            .invokeMethod(method, arg.toInt())
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        createNotificationChannel()
        initMediaSession()

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FLOATING_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startFloatingLyric" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
                            val intent = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName"))
                            startActivity(intent)
                            result.error("PERMISSION_DENIED", "需要悬浮窗权限", null)
                        } else {
                            val intent = Intent(this, FloatingLyricService::class.java).apply {
                                action = FloatingLyricService.ACTION_UPDATE_LYRIC
                                putExtra(FloatingLyricService.EXTRA_LYRIC, call.argument<String>("lyric") ?: "")
                                putExtra(FloatingLyricService.EXTRA_TITLE, call.argument<String>("title") ?: "")
                            }
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
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
                        val intent = Intent(this, FloatingLyricService::class.java).apply { action = FloatingLyricService.ACTION_STOP }
                        startService(intent)
                        result.success(true)
                    }
                    "hasOverlayPermission" -> {
                        result.success(if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) Settings.canDrawOverlays(this) else true)
                    }
                    "showNotification", "updateNotification" -> {
                        showMediaNotification(
                            title = call.argument<String>("title") ?: "",
                            artist = call.argument<String>("artist") ?: "",
                            artUrl = call.argument<String>("artUrl"),
                            isPlaying = call.argument<Boolean>("isPlaying") ?: false,
                            position = call.argument<Number>("position")?.toLong() ?: 0L,
                            duration = call.argument<Number>("duration")?.toLong() ?: 0L,
                        )
                        result.success(true)
                    }
                    "hideNotification" -> {
                        notificationManager?.cancel(NOTIFICATION_ID)
                        mediaSession?.isActive = false
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun initMediaSession() {
        mediaSession = MediaSessionCompat(this, "MD3Music").apply {
            setFlags(
                MediaSessionCompat.FLAG_HANDLES_MEDIA_BUTTONS or
                        MediaSessionCompat.FLAG_HANDLES_TRANSPORT_CONTROLS
            )
            setCallback(object : MediaSessionCompat.Callback() {
                override fun onPlay() {
                    sendFlutterCommand("togglePlayPause")
                }

                override fun onPause() {
                    sendFlutterCommand("togglePlayPause")
                }

                override fun onSkipToNext() {
                    sendFlutterCommand("next")
                }

                override fun onSkipToPrevious() {
                    sendFlutterCommand("previous")
                }

                override fun onStop() {
                    sendFlutterCommand("togglePlayPause")
                }

                override fun onSeekTo(pos: Long) {
                    sendFlutterCommandWithArg("seekTo", pos)
                }
            })
            isActive = true
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(NOTIFICATION_CHANNEL, "音乐播放", NotificationManager.IMPORTANCE_LOW).apply {
                description = "音乐播放控制"
                setShowBadge(false)
                lockscreenVisibility = NotificationCompat.VISIBILITY_PUBLIC
            }
            notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager?.createNotificationChannel(channel)
        } else {
            notificationManager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        }
    }

    private fun showMediaNotification(title: String, artist: String, artUrl: String?, isPlaying: Boolean, position: Long = 0L, duration: Long = 0L) {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(this, 0, launchIntent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        val prevIntent = PendingIntent.getBroadcast(this, 1, Intent("com.md3music.md3music.PREV"), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val playPauseIntent = PendingIntent.getBroadcast(this, 2, Intent("com.md3music.md3music.PLAY_PAUSE"), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val nextIntent = PendingIntent.getBroadcast(this, 3, Intent("com.md3music.md3music.NEXT"), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        val playPauseIcon = if (isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play

        val builder = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(title)
            .setContentText(artist)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .addAction(android.R.drawable.ic_media_previous, "上一首", prevIntent)
            .addAction(playPauseIcon, if (isPlaying) "暂停" else "播放", playPauseIntent)
            .addAction(android.R.drawable.ic_media_next, "下一首", nextIntent)
            .setLargeIcon(BitmapFactory.decodeResource(resources, android.R.drawable.ic_menu_myplaces))
            .setStyle(
                androidx.media.app.NotificationCompat.MediaStyle()
                    .setMediaSession(mediaSession?.sessionToken)
                    .setShowActionsInCompactView(0, 1, 2)
            )

        if (!artUrl.isNullOrEmpty()) {
            Thread {
                try {
                    val bitmap = BitmapFactory.decodeStream(URL(artUrl).openStream())
                    if (bitmap != null) builder.setLargeIcon(bitmap)
                } catch (_: Exception) {}
                notificationManager?.notify(NOTIFICATION_ID, builder.build())
            }.start()
        } else {
            notificationManager?.notify(NOTIFICATION_ID, builder.build())
        }

        mediaSession?.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setState(
                    if (isPlaying) PlaybackStateCompat.STATE_PLAYING else PlaybackStateCompat.STATE_PAUSED,
                    position, 1f
                )
                .setActions(
                    PlaybackStateCompat.ACTION_PLAY or
                            PlaybackStateCompat.ACTION_PAUSE or
                            PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
                            PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS or
                            PlaybackStateCompat.ACTION_STOP or
                            PlaybackStateCompat.ACTION_SEEK_TO
                )
                .build()
        )

        mediaSession?.setMetadata(
            MediaMetadataCompat.Builder()
                .putString(MediaMetadataCompat.METADATA_KEY_TITLE, title)
                .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, artist)
                .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, duration)
                .build()
        )
    }

    override fun onDestroy() {
        super.onDestroy()
        mediaSession?.release()
    }
}
