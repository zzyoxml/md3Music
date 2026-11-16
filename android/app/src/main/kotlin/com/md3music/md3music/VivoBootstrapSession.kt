package com.md3music.md3music

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Looper
import android.util.Log
import androidx.annotation.OptIn
import androidx.core.content.ContextCompat
import androidx.media3.common.Player
import androidx.media3.common.Rating
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaSession
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionResult
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.ryanheise.just_audio.AudioPlayer

/**
 * 原子随身听冷绑定入口：只提供 token，不加载音源、不获取音频焦点、不自动播放。
 * legacy browser 会缓存首次返回的 Binder，真实播放器出现后必须在原 token 上换 player，
 * 不能 release 后指望组件重连。回调复用活跃会话的实现，避免收藏/循环模式与正常播放分叉。
 */
@OptIn(UnstableApi::class)
internal class VivoBootstrapSession(context: Context) {
    private val appContext = context.applicationContext
    private val idlePlayer = object : SimpleBasePlayer(Looper.getMainLooper()) {
        override fun getState(): State = State.Builder()
            .setAvailableCommands(Player.Commands.Builder()
                .add(Player.COMMAND_PLAY_PAUSE)
                .add(Player.COMMAND_GET_CURRENT_MEDIA_ITEM)
                .add(Player.COMMAND_GET_METADATA)
                .add(Player.COMMAND_GET_TIMELINE)
                .build())
            .build()

        override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> {
            // prepare / bind / pause 都不能隐式续播；只有明确 play 才拉起既有唤醒链。
            if (playWhenReady) {
                val intent = Intent(appContext, AudioPlaybackService::class.java)
                    .setAction(AudioPlaybackService.ACTION_MEDIA_BUTTON)
                    .putExtra(AudioPlaybackService.EXTRA_MEDIA_COMMAND, "play")
                    .putExtra(AudioPlaybackService.EXTRA_WAKE_ORIGIN, "car")
                try {
                    ContextCompat.startForegroundService(appContext, intent)
                } catch (e: RuntimeException) {
                    Log.w("CarAutoResume", "vivo bootstrap play wake failed", e)
                    return Futures.immediateFailedFuture<Void>(e)
                }
            }
            return Futures.immediateVoidFuture()
        }
    }

    val session: MediaSession = MediaSession.Builder(appContext, idlePlayer)
        .setId("md3-vivo-bootstrap")
        .setCallback(object : MediaSession.Callback {
            override fun onConnect(s: MediaSession, c: MediaSession.ControllerInfo): MediaSession.ConnectionResult {
                // 绑定时还没有活跃会话也要预先授权，之后无需组件重新 connect。
                val commands = MediaSession.ConnectionResult.DEFAULT_SESSION_COMMANDS.buildUpon()
                    .add(SessionCommand.COMMAND_CODE_SESSION_SET_RATING)
                    .add(SessionCommand(AudioPlayer.VMM_ACTION_PLAY_MODE, Bundle()))
                    .build()
                return MediaSession.ConnectionResult.AcceptedResultBuilder(s)
                    .setAvailableSessionCommands(commands).build()
            }

            override fun onPlayerCommandRequest(s: MediaSession, c: MediaSession.ControllerInfo, command: Int): Int {
                val active = AudioPlayer.getActiveMediaSession()
                return if (active != null) {
                    AudioPlayer.getActiveMediaSessionCallback()?.onPlayerCommandRequest(active, c, command)
                        ?: SessionResult.RESULT_SUCCESS
                } else SessionResult.RESULT_SUCCESS
            }

            override fun onCustomCommand(s: MediaSession, c: MediaSession.ControllerInfo,
                                         command: SessionCommand, args: Bundle): ListenableFuture<SessionResult> {
                val active = AudioPlayer.getActiveMediaSession()
                return if (active != null) {
                    AudioPlayer.getActiveMediaSessionCallback()?.onCustomCommand(active, c, command, args)
                        ?: unsupported()
                } else unsupported()
            }

            override fun onSetRating(s: MediaSession, c: MediaSession.ControllerInfo,
                                     mediaId: String, rating: Rating): ListenableFuture<SessionResult> {
                val active = AudioPlayer.getActiveMediaSession()
                return if (active != null) {
                    AudioPlayer.getActiveMediaSessionCallback()?.onSetRating(active, c, mediaId, rating)
                        ?: unsupported()
                } else unsupported()
            }
        }).build()

    fun follow(active: MediaSession?) {
        val player = active?.player ?: idlePlayer
        if (session.player !== player) session.setPlayer(player)
    }

    fun release() {
        session.release()
        // 真实播放器归 just_audio 管理，只释放自己拥有的无音源待机 player。
        idlePlayer.release()
    }

    private fun unsupported(): ListenableFuture<SessionResult> =
        Futures.immediateFuture(SessionResult(SessionResult.RESULT_ERROR_NOT_SUPPORTED))
}
