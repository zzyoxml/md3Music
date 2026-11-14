/*
 * Copyright 2019 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package androidx.media3.session;

import static androidx.media3.common.Player.COMMAND_CHANGE_MEDIA_ITEMS;
import static androidx.media3.common.Player.COMMAND_PLAY_PAUSE;
import static androidx.media3.common.Player.COMMAND_PREPARE;
import static androidx.media3.common.Player.COMMAND_SEEK_BACK;
import static androidx.media3.common.Player.COMMAND_SEEK_FORWARD;
import static androidx.media3.common.Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM;
import static androidx.media3.common.Player.COMMAND_SEEK_TO_MEDIA_ITEM;
import static androidx.media3.common.Player.COMMAND_SEEK_TO_NEXT;
import static androidx.media3.common.Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM;
import static androidx.media3.common.Player.COMMAND_SEEK_TO_PREVIOUS;
import static androidx.media3.common.Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM;
import static androidx.media3.common.Player.COMMAND_SET_MEDIA_ITEM;
import static androidx.media3.common.Player.COMMAND_SET_REPEAT_MODE;
import static androidx.media3.common.Player.COMMAND_SET_SHUFFLE_MODE;
import static androidx.media3.common.Player.COMMAND_SET_SPEED_AND_PITCH;
import static androidx.media3.common.Player.COMMAND_STOP;
import static androidx.media3.common.util.Assertions.checkNotNull;
import static androidx.media3.common.util.Assertions.checkStateNotNull;
import static androidx.media3.common.util.Util.castNonNull;
import static androidx.media3.common.util.Util.postOrRun;
import static androidx.media3.session.MediaUtils.TRANSACTION_SIZE_LIMIT_IN_BYTES;
import static androidx.media3.session.SessionCommand.COMMAND_CODE_CUSTOM;
import static androidx.media3.session.SessionError.ERROR_UNKNOWN;
import static androidx.media3.session.SessionResult.RESULT_INFO_SKIPPED;
import static androidx.media3.session.SessionResult.RESULT_SUCCESS;

import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.Bitmap;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.Message;
import android.os.RemoteException;
import android.os.ResultReceiver;
import android.text.TextUtils;
import android.view.KeyEvent;
import androidx.annotation.DoNotInline;
import androidx.annotation.Nullable;
import androidx.annotation.RequiresApi;
import androidx.core.util.ObjectsCompat;
import androidx.media3.common.AudioAttributes;
import androidx.media3.common.C;
import androidx.media3.common.DeviceInfo;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MediaMetadata;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.PlaybackParameters;
import androidx.media3.common.Player;
import androidx.media3.common.Player.DiscontinuityReason;
import androidx.media3.common.Player.PositionInfo;
import androidx.media3.common.Player.RepeatMode;
import androidx.media3.common.Rating;
import androidx.media3.common.Timeline;
import androidx.media3.common.util.Log;
import androidx.media3.common.util.NullableType;
import androidx.media3.common.util.Util;
import androidx.media3.session.MediaSession.ControllerCb;
import androidx.media3.session.MediaSession.ControllerInfo;
import androidx.media3.session.MediaSession.MediaItemsWithStartPosition;
import androidx.media3.session.SessionCommand.CommandCode;
import androidx.media3.session.legacy.MediaDescriptionCompat;
import androidx.media3.session.legacy.MediaMetadataCompat;
import androidx.media3.session.legacy.MediaSessionCompat;
import androidx.media3.session.legacy.MediaSessionCompat.QueueItem;
import androidx.media3.session.legacy.MediaSessionManager;
import androidx.media3.session.legacy.MediaSessionManager.RemoteUserInfo;
import androidx.media3.session.legacy.PlaybackStateCompat;
import androidx.media3.session.legacy.RatingCompat;
import androidx.media3.session.legacy.VolumeProviderCompat;
import com.google.common.collect.ImmutableList;
import com.google.common.util.concurrent.FutureCallback;
import com.google.common.util.concurrent.Futures;
import com.google.common.util.concurrent.ListenableFuture;
import com.google.common.util.concurrent.MoreExecutors;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import java.util.concurrent.CancellationException;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicInteger;
import org.checkerframework.checker.initialization.qual.Initialized;

// Getting the commands from MediaControllerCompat'
/* package */ class MediaSessionLegacyStub extends MediaSessionCompat.Callback {

  private static final String TAG = "MediaSessionLegacyStub";

  private static final int PENDING_INTENT_FLAG_MUTABLE =
      Util.SDK_INT >= 31 ? PendingIntent.FLAG_MUTABLE : 0;
  private static final String DEFAULT_MEDIA_SESSION_TAG_PREFIX = "androidx.media3.session.id";
  private static final String DEFAULT_MEDIA_SESSION_TAG_DELIM = ".";

  // Used to call onDisconnected() after the timeout.
  private static final int DEFAULT_CONNECTION_TIMEOUT_MS = 300_000; // 5 min.

  private final ConnectedControllersManager<RemoteUserInfo> connectedControllersManager;

  private final MediaSessionImpl sessionImpl;
  private final MediaSessionManager sessionManager;
  private final ControllerLegacyCbForBroadcast controllerLegacyCbForBroadcast;
  private final ConnectionTimeoutHandler connectionTimeoutHandler;
  private final MediaSessionCompat sessionCompat;
  @Nullable private final MediaButtonReceiver runtimeBroadcastReceiver;
  @Nullable private final ComponentName broadcastReceiverComponentName;
  @Nullable private VolumeProviderCompat volumeProviderCompat;

  private volatile long connectionTimeoutMs;
  @Nullable private FutureCallback<Bitmap> pendingBitmapLoadCallback;
  private int sessionFlags;

  @SuppressWarnings("PendingIntentMutability") // We can't use SaferPendingIntent
  public MediaSessionLegacyStub(MediaSessionImpl session, Uri sessionUri, Handler handler) {
    sessionImpl = session;
    Context context = sessionImpl.getContext();
    sessionManager = MediaSessionManager.getSessionManager(context);
    controllerLegacyCbForBroadcast = new ControllerLegacyCbForBroadcast();
    connectedControllersManager = new ConnectedControllersManager<>(session);
    connectionTimeoutMs = DEFAULT_CONNECTION_TIMEOUT_MS;
    connectionTimeoutHandler =
        new ConnectionTimeoutHandler(
            session.getApplicationHandler().getLooper(), connectedControllersManager);

    // Assume an app that intentionally puts a `MediaButtonReceiver` into the manifest has
    // implemented some kind of resumption of the last recently played media item.
    broadcastReceiverComponentName = queryPackageManagerForMediaButtonReceiver(context);
    @Nullable ComponentName receiverComponentName = broadcastReceiverComponentName;
    boolean isReceiverComponentAService = false;
    if (receiverComponentName == null || Util.SDK_INT < 31) {
      // Below API 26, media button events are sent to the receiver at runtime also. We always want
      // these to arrive at the service at runtime. release() then set the receiver for restart if
      // available.
      receiverComponentName =
          getServiceComponentByAction(context, MediaLibraryService.SERVICE_INTERFACE);
      if (receiverComponentName == null) {
        receiverComponentName =
            getServiceComponentByAction(context, MediaSessionService.SERVICE_INTERFACE);
      }
      isReceiverComponentAService =
          receiverComponentName != null
              && !Objects.equals(receiverComponentName, broadcastReceiverComponentName);
    }
    Intent intent = new Intent(Intent.ACTION_MEDIA_BUTTON, sessionUri);
    PendingIntent mediaButtonIntent;
    if (receiverComponentName == null) {
      // Neither a media button receiver from the app manifest nor a service available that could
      // handle media button events. Create a runtime receiver and a pending intent for it.
      runtimeBroadcastReceiver = new MediaButtonReceiver();
      IntentFilter filter = new IntentFilter(Intent.ACTION_MEDIA_BUTTON);
      filter.addDataScheme(castNonNull(sessionUri.getScheme()));
      Util.registerReceiverNotExported(context, runtimeBroadcastReceiver, filter);
      // Create a pending intent to be broadcast to the receiver.
      intent.setPackage(context.getPackageName());
      mediaButtonIntent =
          PendingIntent.getBroadcast(
              context, /* requestCode= */ 0, intent, PENDING_INTENT_FLAG_MUTABLE);
      // Creates a fake ComponentName for MediaSessionCompat in pre-L or without a service.
      receiverComponentName = new ComponentName(context, context.getClass());
    } else {
      intent.setComponent(receiverComponentName);
      mediaButtonIntent =
          isReceiverComponentAService
              ? (Util.SDK_INT >= 26
                  ? PendingIntent.getForegroundService(
                      context, /* requestCode= */ 0, intent, PENDING_INTENT_FLAG_MUTABLE)
                  : PendingIntent.getService(
                      context, /* requestCode= */ 0, intent, PENDING_INTENT_FLAG_MUTABLE))
              : PendingIntent.getBroadcast(
                  context, /* requestCode= */ 0, intent, PENDING_INTENT_FLAG_MUTABLE);
      runtimeBroadcastReceiver = null;
    }

    String sessionCompatId =
        TextUtils.join(
            DEFAULT_MEDIA_SESSION_TAG_DELIM,
            new String[] {DEFAULT_MEDIA_SESSION_TAG_PREFIX, session.getId()});
    sessionCompat =
        new MediaSessionCompat(
            context,
            sessionCompatId,
            Util.SDK_INT < 31 ? receiverComponentName : null,
            Util.SDK_INT < 31 ? mediaButtonIntent : null,
            session.getToken().getExtras());
    if (Util.SDK_INT >= 31 && broadcastReceiverComponentName != null) {
      Api31.setMediaButtonBroadcastReceiver(sessionCompat, broadcastReceiverComponentName);
    }

    @Nullable PendingIntent sessionActivity = session.getSessionActivity();
    if (sessionActivity != null) {
      sessionCompat.setSessionActivity(sessionActivity);
    }

    @SuppressWarnings("nullness:assignment")
    @Initialized
    MediaSessionLegacyStub thisRef = this;
    sessionCompat.setCallback(thisRef, handler);
  }

  @Nullable
  @SuppressWarnings("QueryPermissionsNeeded") // Needs to be provided in the app manifest.
  private static ComponentName queryPackageManagerForMediaButtonReceiver(Context context) {
    PackageManager pm = context.getPackageManager();
    Intent queryIntent = new Intent(Intent.ACTION_MEDIA_BUTTON);
    queryIntent.setPackage(context.getPackageName());
    List<ResolveInfo> resolveInfos = pm.queryBroadcastReceivers(queryIntent, /* flags= */ 0);
    if (resolveInfos.size() == 1) {
      ResolveInfo resolveInfo = resolveInfos.get(0);
      return new ComponentName(resolveInfo.activityInfo.packageName, resolveInfo.activityInfo.name);
    } else if (resolveInfos.isEmpty()) {
      return null;
    } else {
      throw new IllegalStateException(
          "Expected 1 broadcast receiver that handles "
              + Intent.ACTION_MEDIA_BUTTON
              + ", found "
              + resolveInfos.size());
    }
  }

  /** Starts to receive commands. */
  public void start() {
    sessionCompat.setActive(true);
  }

  // MD3Music fork v22（车机歌词对轴）：车机（ucar/JoviCar）拿到整段 LRC 后自己按
  // PlaybackState 进度滚动，播放进度就是它的时钟基准。而 legacy 会话的 PlaybackState
  // 此前只在离散事件（切歌/暂停/seek/换播放器）时才刷新，播放中一路冻结 —— 车机拿着
  // 一个不动的进度去滚 LRC，歌词与歌声自然对不上（手机端用自己的 position 逐行算，
  // 所以手机同步、车机不同步）。
  // 这里在播放中按固定节奏补刷 legacy 播放态：进度由 createPlaybackStateCompat()
  // 现取，position 带 lastPositionUpdateTime，外推后车机拿到的就是当前进度。
  private static final long LEGACY_PROGRESS_REFRESH_INTERVAL_MS = 500;

  private final Runnable legacyProgressRefreshRunnable =
      this::refreshLegacyProgressWhilePlaying;

  private void refreshLegacyProgressWhilePlaying() {
    // MD3Music fork v25：补一道 isReleased 门禁，与
    // MediaSessionImpl#notifyPeriodicSessionPositionInfoChangesOnHandler 的 closed
    // 检查同源（closed 在 release() 落位）。removeCallbacksAndMessages 只摘已入队
    // 回调，跨线程交错时正在执行的实例会在摘除后自行 postDelayed 重启；有这道门，
    // 下一轮直接自熄。
    if (sessionImpl.isReleased() || !sessionImpl.getPlayerWrapper().isPlaying()) {
      return;
    }
    updateLegacySessionPlaybackState(sessionImpl.getPlayerWrapper());
    // MD3Music fork v22（诊断）：车机滚 LRC 的时钟基准就是这条进度。下轮实测抓
    // logcat 过滤 MD3CarLyrics，能直接看出「车机看到的进度」是否在走、走得对不对。
    PlaybackStateCompat state = sessionImpl.getPlayerWrapper().createPlaybackStateCompat();
    android.util.Log.i(
        "MD3CarLyrics",
        "legacy progress refresh: state=" + state.getState()
            + " pos=" + state.getPosition()
            + " speed=" + state.getPlaybackSpeed());
    sessionImpl
        .getApplicationHandler()
        .postDelayed(legacyProgressRefreshRunnable, LEGACY_PROGRESS_REFRESH_INTERVAL_MS);
  }

  /**
   * MD3Music fork v22：启动/停止播放中的 legacy 进度补刷。
   *
   * <p>与 {@link #onIsPlayingChanged} 的离散刷新互补：那个只在开始/结束时触发，这里
   * 保证播放期间进度持续更新（车机滚 LRC 的时钟基准）。
   */
  private void startLegacyProgressRefresh() {
    sessionImpl.getApplicationHandler().removeCallbacks(legacyProgressRefreshRunnable);
    if (sessionImpl.getPlayerWrapper().isPlaying()) {
      sessionImpl
          .getApplicationHandler()
          .postDelayed(legacyProgressRefreshRunnable, LEGACY_PROGRESS_REFRESH_INTERVAL_MS);
    }
  }

  private void stopLegacyProgressRefresh() {
    sessionImpl.getApplicationHandler().removeCallbacks(legacyProgressRefreshRunnable);
  }

  @SuppressWarnings("PendingIntentMutability") // We can't use SaferPendingIntent.
  public void release() {
    // MD3Music fork v22：会话释放时停掉进度补刷，避免 handler 回调悬空。
    stopLegacyProgressRefresh();
    if (Util.SDK_INT < 31) {
      if (broadcastReceiverComponentName == null) {
        // No broadcast receiver available. Playback resumption not supported.
        setMediaButtonReceiver(sessionCompat, /* mediaButtonReceiverIntent= */ null);
      } else {
        // Override the runtime receiver with the broadcast receiver for playback resumption.
        Intent intent = new Intent(Intent.ACTION_MEDIA_BUTTON, sessionImpl.getUri());
        intent.setComponent(broadcastReceiverComponentName);
        PendingIntent mediaButtonReceiverIntent =
            PendingIntent.getBroadcast(
                sessionImpl.getContext(),
                /* requestCode= */ 0,
                intent,
                PENDING_INTENT_FLAG_MUTABLE);
        setMediaButtonReceiver(sessionCompat, mediaButtonReceiverIntent);
      }
    }
    if (runtimeBroadcastReceiver != null) {
      sessionImpl.getContext().unregisterReceiver(runtimeBroadcastReceiver);
    }
    // No check for COMMAND_RELEASE needed as MediaControllers can always be released.
    sessionCompat.release();
  }

  public MediaSessionCompat getSessionCompat() {
    return sessionCompat;
  }

  @Override
  public void onCommand(String commandName, @Nullable Bundle args, @Nullable ResultReceiver cb) {
    checkStateNotNull(commandName);
    if (TextUtils.equals(MediaConstants.SESSION_COMMAND_REQUEST_SESSION3_TOKEN, commandName)
        && cb != null) {
      cb.send(RESULT_SUCCESS, sessionImpl.getToken().toBundle());
      return;
    }
    SessionCommand command = new SessionCommand(commandName, /* extras= */ Bundle.EMPTY);
    dispatchSessionTaskWithSessionCommand(
        command,
        controller -> {
          ListenableFuture<SessionResult> future =
              sessionImpl.onCustomCommandOnHandler(
                  controller, command, args == null ? Bundle.EMPTY : args);
          if (cb != null) {
            sendCustomCommandResultWhenReady(cb, future);
          } else {
            ignoreFuture(future);
          }
        });
  }

  @Override
  public void onCustomAction(String action, @Nullable Bundle args) {
    SessionCommand command = new SessionCommand(action, /* extras= */ Bundle.EMPTY);
    dispatchSessionTaskWithSessionCommand(
        command,
        controller ->
            ignoreFuture(
                sessionImpl.onCustomCommandOnHandler(
                    controller, command, args != null ? args : Bundle.EMPTY)));
  }

  @Override
  public boolean onMediaButtonEvent(Intent intent) {
    return sessionImpl.onMediaButtonEvent(
        new ControllerInfo(
            checkNotNull(sessionCompat.getCurrentControllerInfo()),
            ControllerInfo.LEGACY_CONTROLLER_VERSION,
            ControllerInfo.LEGACY_CONTROLLER_INTERFACE_VERSION,
            /* trusted= */ false,
            /* cb= */ null,
            /* connectionHints= */ Bundle.EMPTY),
        intent);
  }

  private void maybeUpdateFlags(PlayerWrapper playerWrapper) {
    int newFlags =
        playerWrapper.isCommandAvailable(COMMAND_CHANGE_MEDIA_ITEMS)
            ? MediaSessionCompat.FLAG_HANDLES_QUEUE_COMMANDS
            : 0;
    if (sessionFlags != newFlags) {
      sessionFlags = newFlags;
      sessionCompat.setFlags(sessionFlags);
    }
  }

  /* package */ void handleMediaPlayPauseOnHandler(RemoteUserInfo remoteUserInfo) {
    dispatchSessionTaskWithPlayerCommand(
        COMMAND_PLAY_PAUSE,
        controller ->
            Util.handlePlayPauseButtonAction(
                sessionImpl.getPlayerWrapper(), sessionImpl.shouldPlayIfSuppressed()),
        remoteUserInfo,
        /* callOnPlayerInteractionFinished= */ true);
  }

  @Override
  public void onPrepare() {
    dispatchSessionTaskWithPlayerCommand(
        COMMAND_PREPARE,
        controller -> sessionImpl.getPlayerWrapper().prepare(),
        sessionCompat.getCurrentControllerInfo(),
        /* callOnPlayerInteractionFinished= */ true);
  }

  @Override
  public void onPrepareFromMediaId(@Nullable String mediaId, @Nullable Bundle extras) {
    handleMediaRequest(
        createMediaItemForMediaRequest(
            mediaId, /* mediaUri= */ null, /* searchQuery= */ null, extras),
        /* play= */ false);
  }

  @Override
  public void onPrepareFromSearch(@Nullable String query, @Nullable Bundle extras) {
    handleMediaRequest(
        createMediaItemForMediaRequest(/* mediaId= */ null, /* mediaUri= */ null, query, extras),
        /* play= */ false);
  }

  @Override
  public void onPrepareFromUri(@Nullable Uri mediaUri, @Nullable Bundle extras) {
    handleMediaRequest(
        createMediaItemForMediaRequest(
            /* mediaId= */ null, mediaUri, /* searchQuery= */ null, extras),
        /* play= */ false);
  }

  @Override
  public void onPlay() {
    dispatchSessionTaskWithPlayerCommand(
        COMMAND_PLAY_PAUSE,
        controller ->
            sessionImpl.handleMediaControllerPlayRequest(
                controller, /* callOnPlayerInteractionFinished= */ true),
        sessionCompat.getCurrentControllerInfo(),
        /* callOnPlayerInteractionFinished= */ false);
  }

  @Override
  public void onPlayFromMediaId(@Nullable String mediaId, @Nullable Bundle extras) {
    // MD3Music fork v40：App 可注入点播钩子——vivo 原子随身听按 media id 回播列表项，
    // 默认实现会把"只有 mediaId、没有 URI"的 item 塞进 ExoPlayer（播不出且污染
    // media3 时间线，App 队列是 Dart 自维护的）。钩子返回 true 表示已消费。
    // 钩子声明在 MediaSessionService（public）——本类包私有，App 侧引用不到。
    MediaSessionService.PlayFromMediaIdHook hook = MediaSessionService.playFromMediaIdHook;
    if (hook != null && hook.onPlayFromMediaId(mediaId)) {
      return;
    }
    handleMediaRequest(
        createMediaItemForMediaRequest(
            mediaId, /* mediaUri= */ null, /* searchQuery= */ null, extras),
        /* play= */ true);
  }

  @Override
  public void onPlayFromSearch(@Nullable String query, @Nullable Bundle extras) {
    // MD3Music fork v66：车机语音点歌。App 队列由 Dart 自维护，默认实现会把
    // 「只有 searchQuery、没有 URI」的 item 塞进 ExoPlayer（播不出且污染
    // media3 时间线）。钩子返回 true 表示已消费（App 侧自行搜索后起播）。
    MediaSessionService.PlayFromSearchHook hook = MediaSessionService.playFromSearchHook;
    if (hook != null && hook.onPlayFromSearch(query, extras)) {
      return;
    }
    handleMediaRequest(
        createMediaItemForMediaRequest(/* mediaId= */ null, /* mediaUri= */ null, query, extras),
        /* play= */ true);
  }

  @Override
  public void onPlayFromUri(@Nullable Uri mediaUri, @Nullable Bundle extras) {
    handleMediaRequest(
        createMediaItemForMediaRequest(
            /* mediaId= */ null, mediaUri, /* searchQuery= */ null, extras),
        /* play= */ true);
  }

  @Override
  public void onPause() {
    dispatchSessionTaskWithPlayerCommand(
        COMMAND_PLAY_PAUSE,
        controller -> Util.handlePauseButtonAction(sessionImpl.getPlayerWrapper()),
        sessionCompat.getCurrentControllerInfo(),
        /* callOnPlayerInteractionFinished= */ true);
  }

  @Override
  public void onStop() {
    dispatchSessionTaskWithPlayerCommand(
        COMMAND_STOP,
        controller -> sessionImpl.getPlayerWrapper().stop(),
        sessionCompat.getCurrentControllerInfo(),
        /* callOnPlayerInteractionFinished= */ true);
  }

  @Override
  public void onSeekTo(long pos) {
    dispatchSessionTaskWithPlayerCommand(
        COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM,
        controller -> sessionImpl.getPlayerWrapper().seekTo(pos),
        sessionCompat.getCurrentControllerInfo(),
        /* callOnPlayerInteractionFinished= */ true);
  }

  @Override
  public void onSkipToNext() {
    if (sessionImpl.getPlayerWrapper().isCommandAvailable(COMMAND_SEEK_TO_NEXT)) {
      dispatchSessionTaskWithPlayerCommand(
          COMMAND_SEEK_TO_NEXT,
          controller -> sessionImpl.getPlayerWrapper().seekToNext(),
          sessionCompat.getCurrentControllerInfo(),
          /* callOnPlayerInteractionFinished= */ true);
    } else {
      dispatchSessionTaskWithPlayerCommand(
          COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
          controller -> sessionImpl.getPlayerWrapper().seekToNextMediaItem(),
          sessionCompat.getCurrentControllerInfo(),
          /* callOnPlayerInteractionFinished= */ true);
    }
  }

  @Override
  public void onSkipToPrevious() {
    if (sessionImpl.getPlayerWrapper().isCommandAvailable(COMMAND_SEEK_TO_PREVIOUS)) {
      dispatchSessionTaskWithPlayerCommand(
          COMMAND_SEEK_TO_PREVIOUS,
          controller -> sessionImpl.getPlayerWrapper().seekToPrevious(),
          sessionCompat.getCurrentControllerInfo(),
          /* callOnPlayerInteractionFinished= */ true);
    } else {
      dispatchSessionTaskWithPlayerCommand(
          COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
          controller -> sessionImpl.getPlayerWrapper().seekToPreviousMediaItem(),
          sessionCompat.getCurrentControllerInfo(),
          /* callOnPlayerInteractionFinished= */ true);
    }
  }

  @Override
  public void onSetPlaybackSpeed(float speed) {
    if (!(speed > 0f)) {
      return;
    }
    dispatchSessionTaskWithPlayerCommand(
        COMMAND_SET_SPEED_AND_PITCH,
        controller -> sessionImpl.getPlayerWrapper().setPlaybackSpeed(speed),
        sessionCompat.getCurrentControllerInfo(),
        /* callOnPlayerInteractionFinished= */ true);
  }

  @Override
  public void onSkipToQueueItem(long queueId) {
    if (queueId < 0) {
      return;
    }
    dispatchSessionTaskWithPlayerCommand(
        COMMAND_SEEK_TO_MEDIA_ITEM,
        controller -> {
          PlayerWrapper playerWrapper = sessionImpl.getPlayerWrapper();
          // Use queueId as an index as we've published {@link QueueItem} as so.
          // see: {@link MediaUtils#convertToQueueItem}.
          playerWrapper.seekToDefaultPosition((int) queueId);
        },
        sessionCompat.getCurrentControllerInfo(),
        /* callOnPlayerInteractionFinished= */ true);
  }

  @Override
  public void onFastForward() {
    dispatchSessionTaskWithPlayerCommand(
        COMMAND_SEEK_FORWARD,
        controller -> sessionImpl.getPlayerWrapper().seekForward(),
        sessionCompat.getCurrentControllerInfo(),
        /* callOnPlayerInteractionFinished= */ true);
  }

  @Override
  public void onRewind() {
    dispatchSessionTaskWithPlayerCommand(
        COMMAND_SEEK_BACK,
        controller -> sessionImpl.getPlayerWrapper().seekBack(),
        sessionCompat.getCurrentControllerInfo(),
        /* callOnPlayerInteractionFinished= */ true);
  }

  @Override
  public void onSetRating(@Nullable RatingCompat ratingCompat) {
    onSetRating(ratingCompat, null);
  }

  @Override
  public void onSetRating(@Nullable RatingCompat ratingCompat, @Nullable Bundle unusedExtras) {
    @Nullable Rating rating = LegacyConversions.convertToRating(ratingCompat);
    if (rating == null) {
      Log.w(TAG, "Ignoring invalid RatingCompat " + ratingCompat);
      return;
    }
    dispatchSessionTaskWithSessionCommand(
        SessionCommand.COMMAND_CODE_SESSION_SET_RATING,
        controller -> {
          @Nullable
          MediaItem currentItem =
              sessionImpl.getPlayerWrapper().getCurrentMediaItemWithCommandCheck();
          if (currentItem == null) {
            return;
          }
          // MediaControllerCompat#setRating doesn't return a value.
          ignoreFuture(sessionImpl.onSetRatingOnHandler(controller, currentItem.mediaId, rating));
        });
  }

  @Override
  public void onSetCaptioningEnabled(boolean enabled) {
    // no-op
  }

  @Override
  public void onSetRepeatMode(@PlaybackStateCompat.RepeatMode int playbackStateCompatRepeatMode) {
    dispatchSessionTaskWithPlayerCommand(
        COMMAND_SET_REPEAT_MODE,
        controller ->
            sessionImpl
                .getPlayerWrapper()
                .setRepeatMode(
                    LegacyConversions.convertToRepeatMode(playbackStateCompatRepeatMode)),
        sessionCompat.getCurrentControllerInfo(),
        /* callOnPlayerInteractionFinished= */ true);
  }

  @Override
  public void onSetShuffleMode(@PlaybackStateCompat.ShuffleMode int shuffleMode) {
    dispatchSessionTaskWithPlayerCommand(
        COMMAND_SET_SHUFFLE_MODE,
        controller ->
            sessionImpl
                .getPlayerWrapper()
                .setShuffleModeEnabled(LegacyConversions.convertToShuffleModeEnabled(shuffleMode)),
        sessionCompat.getCurrentControllerInfo(),
        /* callOnPlayerInteractionFinished= */ true);
  }

  @Override
  public void onAddQueueItem(@Nullable MediaDescriptionCompat description) {
    handleOnAddQueueItem(description, /* index= */ C.INDEX_UNSET);
  }

  @Override
  public void onAddQueueItem(@Nullable MediaDescriptionCompat description, int index) {
    handleOnAddQueueItem(description, index);
  }

  @Override
  public void onRemoveQueueItem(@Nullable MediaDescriptionCompat description) {
    if (description == null) {
      return;
    }
    dispatchSessionTaskWithPlayerCommand(
        COMMAND_CHANGE_MEDIA_ITEMS,
        controller -> {
          @Nullable String mediaId = description.getMediaId();
          if (TextUtils.isEmpty(mediaId)) {
            Log.w(TAG, "onRemoveQueueItem(): Media ID shouldn't be null");
            return;
          }
          PlayerWrapper player = sessionImpl.getPlayerWrapper();
          if (!player.isCommandAvailable(Player.COMMAND_GET_TIMELINE)) {
            Log.w(TAG, "Can't remove item by ID without COMMAND_GET_TIMELINE being available");
            return;
          }
          Timeline timeline = player.getCurrentTimeline();
          Timeline.Window window = new Timeline.Window();
          for (int i = 0; i < timeline.getWindowCount(); i++) {
            MediaItem mediaItem = timeline.getWindow(i, window).mediaItem;
            if (TextUtils.equals(mediaItem.mediaId, mediaId)) {
              player.removeMediaItem(i);
              return;
            }
          }
        },
        sessionCompat.getCurrentControllerInfo(),
        /* callOnPlayerInteractionFinished= */ true);
  }

  public ControllerCb getControllerLegacyCbForBroadcast() {
    return controllerLegacyCbForBroadcast;
  }

  public ConnectedControllersManager<RemoteUserInfo> getConnectedControllersManager() {
    return connectedControllersManager;
  }

  /* package */ boolean canResumePlaybackOnStart() {
    return broadcastReceiverComponentName != null;
  }

  private void dispatchSessionTaskWithPlayerCommand(
      @Player.Command int command,
      SessionTask task,
      @Nullable RemoteUserInfo remoteUserInfo,
      boolean callOnPlayerInteractionFinished) {
    if (sessionImpl.isReleased()) {
      return;
    }
    if (remoteUserInfo == null) {
      Log.d(TAG, "RemoteUserInfo is null, ignoring command=" + command);
      return;
    }
    postOrRun(
        sessionImpl.getApplicationHandler(),
        () -> {
          if (sessionImpl.isReleased()) {
            return;
          }
          if (!sessionCompat.isActive()) {
            Log.w(
                TAG,
                "Ignore incoming player command before initialization. command="
                    + command
                    + ", pid="
                    + remoteUserInfo.getPid());
            return;
          }
          @Nullable ControllerInfo controller = tryGetController(remoteUserInfo);
          if (controller == null) {
            // Failed to get controller since connection was rejected.
            return;
          }
          if (!connectedControllersManager.isPlayerCommandAvailable(controller, command)) {
            if (command == COMMAND_PLAY_PAUSE
                && !sessionImpl.getPlayerWrapper().getPlayWhenReady()) {
              Log.w(
                  TAG,
                  "Calling play() omitted due to COMMAND_PLAY_PAUSE not being available. If this"
                      + " play command has started the service for instance for playback"
                      + " resumption, this may prevent the service from being started into the"
                      + " foreground.");
            }
            return;
          }
          int resultCode = sessionImpl.onPlayerCommandRequestOnHandler(controller, command);
          if (resultCode != RESULT_SUCCESS) {
            // Don't run rejected command.
            return;
          }

          sessionImpl
              .callWithControllerForCurrentRequestSet(
                  controller,
                  () -> {
                    try {
                      task.run(controller);
                    } catch (RemoteException e) {
                      // Currently it's TransactionTooLargeException or DeadSystemException.
                      // We'd better to leave log for those cases because
                      //   - TransactionTooLargeException means that we may need to fix our code.
                      //     (e.g. add pagination or special way to deliver Bitmap)
                      //   - DeadSystemException means that errors around it can be ignored.
                      Log.w(TAG, "Exception in " + controller, e);
                    }
                  })
              .run();
          if (callOnPlayerInteractionFinished) {
            sessionImpl.onPlayerInteractionFinishedOnHandler(
                controller, new Player.Commands.Builder().add(command).build());
          }
        });
  }

  private void dispatchSessionTaskWithSessionCommand(
      @CommandCode int commandCode, SessionTask task) {
    dispatchSessionTaskWithSessionCommandInternal(
        null, commandCode, task, sessionCompat.getCurrentControllerInfo());
  }

  private void dispatchSessionTaskWithSessionCommand(
      SessionCommand sessionCommand, SessionTask task) {
    dispatchSessionTaskWithSessionCommandInternal(
        sessionCommand, COMMAND_CODE_CUSTOM, task, sessionCompat.getCurrentControllerInfo());
  }

  private void dispatchSessionTaskWithSessionCommandInternal(
      @Nullable SessionCommand sessionCommand,
      @CommandCode int commandCode,
      SessionTask task,
      @Nullable RemoteUserInfo remoteUserInfo) {
    if (remoteUserInfo == null) {
      Log.d(
          TAG,
          "RemoteUserInfo is null, ignoring command="
              + (sessionCommand == null ? commandCode : sessionCommand));
      return;
    }
    postOrRun(
        sessionImpl.getApplicationHandler(),
        () -> {
          if (sessionImpl.isReleased()) {
            return;
          }
          if (!sessionCompat.isActive()) {
            Log.w(
                TAG,
                "Ignore incoming session command before initialization. command="
                    + (sessionCommand == null ? commandCode : sessionCommand.customAction)
                    + ", pid="
                    + remoteUserInfo.getPid());
            return;
          }
          @Nullable ControllerInfo controller = tryGetController(remoteUserInfo);
          if (controller == null) {
            // Failed to get controller since connection was rejected.
            return;
          }
          if (sessionCommand != null) {
            if (!connectedControllersManager.isSessionCommandAvailable(
                controller, sessionCommand)) {
              return;
            }
          } else {
            if (!connectedControllersManager.isSessionCommandAvailable(controller, commandCode)) {
              return;
            }
          }
          try {
            task.run(controller);
          } catch (RemoteException e) {
            // Currently it's TransactionTooLargeException or DeadSystemException.
            // We'd better to leave log for those cases because
            //   - TransactionTooLargeException means that we may need to fix our code.
            //     (e.g. add pagination or special way to deliver Bitmap)
            //   - DeadSystemException means that errors around it can be ignored.
            Log.w(TAG, "Exception in " + controller, e);
          }
        });
  }

  @Nullable
  private ControllerInfo tryGetController(RemoteUserInfo remoteUserInfo) {
    @Nullable ControllerInfo controller = connectedControllersManager.getController(remoteUserInfo);
    if (controller == null) {
      // Try connect.
      ControllerCb controllerCb = new ControllerLegacyCb(remoteUserInfo);
      controller =
          new ControllerInfo(
              remoteUserInfo,
              ControllerInfo.LEGACY_CONTROLLER_VERSION,
              ControllerInfo.LEGACY_CONTROLLER_INTERFACE_VERSION,
              sessionManager.isTrustedForMediaControl(remoteUserInfo),
              controllerCb,
              /* connectionHints= */ Bundle.EMPTY);
      MediaSession.ConnectionResult connectionResult = sessionImpl.onConnectOnHandler(controller);
      if (!connectionResult.isAccepted) {
        try {
          controllerCb.onDisconnected(/* seq= */ 0);
        } catch (RemoteException e) {
          // Controller may have died prematurely.
        }
        return null;
      }
      connectedControllersManager.addController(
          controller.getRemoteUserInfo(),
          controller,
          connectionResult.availableSessionCommands,
          connectionResult.availablePlayerCommands);
    }
    // Reset disconnect timeout.
    connectionTimeoutHandler.disconnectControllerAfterTimeout(controller, connectionTimeoutMs);

    return controller;
  }

  public void setLegacyControllerDisconnectTimeoutMs(long timeoutMs) {
    connectionTimeoutMs = timeoutMs;
  }

  public void updateLegacySessionPlaybackState(PlayerWrapper playerWrapper) {
    postOrRun(
        sessionImpl.getApplicationHandler(),
        () -> {
          PlaybackStateCompat playbackState = playerWrapper.createPlaybackStateCompat();
          sessionCompat.setPlaybackState(playbackState);
          // MD3Music fork（方向3·shadow 播放态镜像）：活跃会话发布后同步给 shadow。
          mirrorPlaybackStateToShadowSessionsIfActive(playbackState);
        });
  }

  public void updateLegacySessionPlaybackStateAndQueue(PlayerWrapper playerWrapper) {
    postOrRun(
        sessionImpl.getApplicationHandler(),
        () -> {
          PlaybackStateCompat playbackState = playerWrapper.createPlaybackStateCompat();
          sessionCompat.setPlaybackState(playbackState);
          // MD3Music fork（方向3·shadow 播放态镜像）：与 updateLegacySessionPlaybackState 同源。
          mirrorPlaybackStateToShadowSessionsIfActive(playbackState);
          controllerLegacyCbForBroadcast.updateQueue(
              playerWrapper.getAvailableCommands().contains(Player.COMMAND_GET_TIMELINE)
                  ? playerWrapper.getCurrentTimeline()
                  : Timeline.EMPTY);
        });
  }

  /// MD3Music fork（CarWith·逐句歌词强制重发，2026-11）：让 legacy 控制器立刻重读
  /// 一次当前 metadata（清掉「上一帧」去重缓存后重跑转换+下发），三层口子：
  /// MediaSession → 本方法、MediaSessionImpl → 转发、本类 ControllerLegacyCbForBroadcast
  /// .forceMetadataBroadcast 落实现。
  /// 背景：只改 extras 里的歌词键（media3 的 MediaMetadata.equals **不比较 extras**，
  /// updateMetadataIfChanged 里补 legacyLyricInfo 专门对比就是为此）时，
  /// onMediaMetadataChanged 不派发/被同一处去重吞掉，legacy 控制器（CarWith 主机读
  /// framework MediaSessionCompat）因此永远不重读 —— 每换一句歌词必须强制重发一次，
  /// 否则键写了也到不了车机。断开翻转时同样依赖这一次把 framework 顶层残留的
  /// ucar 键冲掉。
  public void forceLegacyMetadataBroadcast() {
    postOrRun(
        sessionImpl.getApplicationHandler(),
        () -> {
          // 与 v25 的进度补刷同口径：release 后回调可能已入队，这里自熄。
          if (sessionImpl.isReleased()) {
            return;
          }
          controllerLegacyCbForBroadcast.forceMetadataBroadcast();
        });
  }

  /// MD3Music fork（方向3·shadow 播放态镜像）：
  /// 仅当【本会话正是当前活跃会话】时，把刚发布的 PlaybackState 同步进
  /// 其它存活（shadow）会话；shadow 自己的发布（paused/旧态）不广播，
  /// 避免用旧态覆盖刚镜像的新态。会话身份经 sessionImpl 的内部引用比较，
  /// 开关门控在 AudioPlayer.SHADOW_SESSION_MODE（vivo/iQOO）。
  private void mirrorPlaybackStateToShadowSessionsIfActive(PlaybackStateCompat state) {
    MediaSession activeSession = com.ryanheise.just_audio.AudioPlayer.getActiveMediaSession();
    if (activeSession == null) return;
    if (!com.ryanheise.just_audio.AudioPlayer.isShadowPlaybackMirrorEnabled()) return;
    if (sessionImpl.getInstanceForShadowMirrorIdentity() != activeSession) return;
    MediaSessionCompat.mirrorPlaybackStateToShadows(state, sessionCompat);
    com.ryanheise.just_audio.AudioPlayer.logShadowPlaybackSync(state);
  }

  /// MD3Music fork（方向3·队列镜像，v36）：活跃会话每次发布队列（含清空）时同步
  /// 影子——原子岛钉的是首个会话（shadow），收敛保活后影子自身时间线已清空，列
  /// 表面板块因此空到底。快照时序问题（岛先连、队列后发）也由每次活跃发布刷新覆盖。
  /// 队列条目复用本会话已转换好的一批（封面按既有异步链携带），不重复解码。
  private void mirrorQueueToShadowSessionsIfActive(@Nullable List<QueueItem> queue) {
    MediaSession activeSession = com.ryanheise.just_audio.AudioPlayer.getActiveMediaSession();
    if (activeSession == null) return;
    if (!com.ryanheise.just_audio.AudioPlayer.isShadowPlaybackMirrorEnabled()) return;
    if (sessionImpl.getInstanceForShadowMirrorIdentity() != activeSession) return;
    @Nullable CharSequence title = null;
    try {
      title = sessionCompat.getController().getQueueTitle();
    } catch (Throwable t) {
      // 标题快照失败仅影响列表标题，不阻断队列镜像
    }
    MediaSessionCompat.mirrorQueueToShadows(queue, title, sessionCompat);
    Log.i(
        "AudioFocusFork",
        "shadow queue mirror: items=" + (queue == null ? -1 : queue.size()));
  }

  private void handleMediaRequest(MediaItem mediaItem, boolean play) {
    dispatchSessionTaskWithPlayerCommand(
        COMMAND_SET_MEDIA_ITEM,
        controller -> {
          ListenableFuture<MediaItemsWithStartPosition> mediaItemsFuture =
              sessionImpl.onSetMediaItemsOnHandler(
                  controller, ImmutableList.of(mediaItem), C.INDEX_UNSET, C.TIME_UNSET);
          Futures.addCallback(
              mediaItemsFuture,
              new FutureCallback<MediaItemsWithStartPosition>() {
                @Override
                public void onSuccess(MediaItemsWithStartPosition mediaItemsWithStartPosition) {
                  postOrRun(
                      sessionImpl.getApplicationHandler(),
                      sessionImpl.callWithControllerForCurrentRequestSet(
                          controller,
                          () -> {
                            PlayerWrapper player = sessionImpl.getPlayerWrapper();
                            MediaUtils.setMediaItemsWithStartIndexAndPosition(
                                player, mediaItemsWithStartPosition);
                            @Player.State int playbackState = player.getPlaybackState();
                            if (playbackState == Player.STATE_IDLE) {
                              player.prepareIfCommandAvailable();
                            } else if (playbackState == Player.STATE_ENDED) {
                              player.seekToDefaultPositionIfCommandAvailable();
                            }
                            if (play) {
                              player.playIfCommandAvailable();
                            }
                            sessionImpl.onPlayerInteractionFinishedOnHandler(
                                controller,
                                new Player.Commands.Builder()
                                    .addAll(COMMAND_SET_MEDIA_ITEM, COMMAND_PREPARE)
                                    .addIf(COMMAND_PLAY_PAUSE, play)
                                    .build());
                          }));
                }

                @Override
                public void onFailure(Throwable t) {
                  // Do nothing, the session is free to ignore these requests.
                }
              },
              MoreExecutors.directExecutor());
        },
        sessionCompat.getCurrentControllerInfo(),
        /* callOnPlayerInteractionFinished= */ false);
  }

  private void handleOnAddQueueItem(@Nullable MediaDescriptionCompat description, int index) {
    if (description == null || (index != C.INDEX_UNSET && index < 0)) {
      return;
    }
    dispatchSessionTaskWithPlayerCommand(
        COMMAND_CHANGE_MEDIA_ITEMS,
        controller -> {
          @Nullable String mediaId = description.getMediaId();
          if (TextUtils.isEmpty(mediaId)) {
            Log.w(TAG, "onAddQueueItem(): Media ID shouldn't be empty");
            return;
          }
          MediaItem mediaItem = LegacyConversions.convertToMediaItem(description);
          ListenableFuture<List<MediaItem>> mediaItemsFuture =
              sessionImpl.onAddMediaItemsOnHandler(controller, ImmutableList.of(mediaItem));
          Futures.addCallback(
              mediaItemsFuture,
              new FutureCallback<List<MediaItem>>() {
                @Override
                public void onSuccess(List<MediaItem> mediaItems) {
                  postOrRun(
                      sessionImpl.getApplicationHandler(),
                      sessionImpl.callWithControllerForCurrentRequestSet(
                          controller,
                          () -> {
                            if (index == C.INDEX_UNSET) {
                              sessionImpl.getPlayerWrapper().addMediaItems(mediaItems);
                            } else {
                              sessionImpl.getPlayerWrapper().addMediaItems(index, mediaItems);
                            }
                            sessionImpl.onPlayerInteractionFinishedOnHandler(
                                controller,
                                new Player.Commands.Builder()
                                    .add(COMMAND_CHANGE_MEDIA_ITEMS)
                                    .build());
                          }));
                }

                @Override
                public void onFailure(Throwable t) {
                  // Do nothing, the session is free to ignore these requests.
                }
              },
              MoreExecutors.directExecutor());
        },
        sessionCompat.getCurrentControllerInfo(),
        /* callOnPlayerInteractionFinished= */ false);
  }

  private static void sendCustomCommandResultWhenReady(
      ResultReceiver receiver, ListenableFuture<SessionResult> future) {
    future.addListener(
        () -> {
          SessionResult result;
          try {
            result = checkNotNull(future.get(), "SessionResult must not be null");
          } catch (CancellationException e) {
            Log.w(TAG, "Custom command cancelled", e);
            result = new SessionResult(RESULT_INFO_SKIPPED);
          } catch (ExecutionException | InterruptedException e) {
            Log.w(TAG, "Custom command failed", e);
            result = new SessionResult(ERROR_UNKNOWN);
          }
          receiver.send(result.resultCode, result.extras);
        },
        MoreExecutors.directExecutor());
  }

  private static <T> void ignoreFuture(Future<T> unused) {
    // no-op
  }

  @SuppressWarnings("nullness:argument") // MediaSessionCompat didn't annotate @Nullable.
  private static void setMetadata(
      MediaSessionCompat sessionCompat, @Nullable MediaMetadataCompat metadataCompat) {
    sessionCompat.setMetadata(metadataCompat);
  }

  @SuppressWarnings("nullness:argument") // MediaSessionCompat didn't annotate @Nullable.
  private static void setMediaButtonReceiver(
      MediaSessionCompat sessionCompat, @Nullable PendingIntent mediaButtonReceiverIntent) {
    sessionCompat.setMediaButtonReceiver(mediaButtonReceiverIntent);
  }

  @SuppressWarnings("nullness:argument") // MediaSessionCompat didn't annotate @Nullable.
  private static void setQueue(MediaSessionCompat sessionCompat, @Nullable List<QueueItem> queue) {
    sessionCompat.setQueue(queue);
  }

  @SuppressWarnings("nullness:argument") // MediaSessionCompat didn't annotate @Nullable.
  private void setQueueTitle(MediaSessionCompat sessionCompat, @Nullable CharSequence title) {
    sessionCompat.setQueueTitle(isQueueEnabled() ? title : null);
  }

  private boolean isQueueEnabled() {
    PlayerWrapper playerWrapper = sessionImpl.getPlayerWrapper();
    return playerWrapper.getAvailablePlayerCommands().contains(Player.COMMAND_GET_TIMELINE)
        && playerWrapper.getAvailableCommands().contains(Player.COMMAND_GET_TIMELINE);
  }

  private static MediaItem createMediaItemForMediaRequest(
      @Nullable String mediaId,
      @Nullable Uri mediaUri,
      @Nullable String searchQuery,
      @Nullable Bundle extras) {
    return new MediaItem.Builder()
        .setMediaId(mediaId == null ? MediaItem.DEFAULT_MEDIA_ID : mediaId)
        .setRequestMetadata(
            new MediaItem.RequestMetadata.Builder()
                .setMediaUri(mediaUri)
                .setSearchQuery(searchQuery)
                .setExtras(extras)
                .build())
        .build();
  }

  /* @FunctionalInterface */
  private interface SessionTask {

    void run(ControllerInfo controller) throws RemoteException;
  }

  private static final class ControllerLegacyCb implements ControllerCb {

    private final RemoteUserInfo remoteUserInfo;

    public ControllerLegacyCb(RemoteUserInfo remoteUserInfo) {
      this.remoteUserInfo = remoteUserInfo;
    }

    @Override
    public int hashCode() {
      return ObjectsCompat.hash(remoteUserInfo);
    }

    @Override
    public boolean equals(@Nullable Object obj) {
      if (this == obj) {
        return true;
      }
      if (obj == null || obj.getClass() != ControllerLegacyCb.class) {
        return false;
      }
      ControllerLegacyCb other = (ControllerLegacyCb) obj;
      return Util.areEqual(remoteUserInfo, other.remoteUserInfo);
    }
  }

  private final class ControllerLegacyCbForBroadcast implements ControllerCb {

    private MediaMetadata lastMediaMetadata;
    private String lastMediaId;
    @Nullable private Uri lastMediaUri;
    private long lastDurationMs;

    public ControllerLegacyCbForBroadcast() {
      lastMediaMetadata = MediaMetadata.EMPTY;
      lastMediaId = MediaItem.DEFAULT_MEDIA_ID;
      lastDurationMs = C.TIME_UNSET;
    }

    @Override
    public void onAvailableCommandsChangedFromPlayer(int seq, Player.Commands availableCommands) {
      PlayerWrapper playerWrapper = sessionImpl.getPlayerWrapper();
      maybeUpdateFlags(playerWrapper);
      updateLegacySessionPlaybackState(playerWrapper);
    }

    @Override
    public void onDisconnected(int seq) throws RemoteException {
      // Calling MediaSessionCompat#release() is already done in release().
    }

    @Override
    public void onPlayerChanged(
        int seq, @Nullable PlayerWrapper oldPlayerWrapper, PlayerWrapper newPlayerWrapper)
        throws RemoteException {
      // Tells the playlist change first, so current media item index change notification
      // can point to the valid current media item in the playlist.
      Timeline newTimeline = newPlayerWrapper.getCurrentTimelineWithCommandCheck();
      if (oldPlayerWrapper == null
          || !Util.areEqual(oldPlayerWrapper.getCurrentTimelineWithCommandCheck(), newTimeline)) {
        onTimelineChanged(seq, newTimeline, Player.TIMELINE_CHANGE_REASON_PLAYLIST_CHANGED);
      }
      MediaMetadata newPlaylistMetadata = newPlayerWrapper.getPlaylistMetadataWithCommandCheck();
      if (oldPlayerWrapper == null
          || !Util.areEqual(
              oldPlayerWrapper.getPlaylistMetadataWithCommandCheck(), newPlaylistMetadata)) {
        onPlaylistMetadataChanged(seq, newPlaylistMetadata);
      }
      MediaMetadata newMediaMetadata = newPlayerWrapper.getMediaMetadataWithCommandCheck();
      if (oldPlayerWrapper == null
          || !Util.areEqual(
              oldPlayerWrapper.getMediaMetadataWithCommandCheck(), newMediaMetadata)) {
        onMediaMetadataChanged(seq, newMediaMetadata);
      }
      if (oldPlayerWrapper == null
          || oldPlayerWrapper.getShuffleModeEnabled() != newPlayerWrapper.getShuffleModeEnabled()) {
        onShuffleModeEnabledChanged(seq, newPlayerWrapper.getShuffleModeEnabled());
      }
      if (oldPlayerWrapper == null
          || oldPlayerWrapper.getRepeatMode() != newPlayerWrapper.getRepeatMode()) {
        onRepeatModeChanged(seq, newPlayerWrapper.getRepeatMode());
      }

      // Forcefully update playback info to update VolumeProviderCompat attached to the
      // old player.
      onDeviceInfoChanged(seq, newPlayerWrapper.getDeviceInfo());

      // Rest of changes are all notified via PlaybackStateCompat.
      maybeUpdateFlags(newPlayerWrapper);
      @Nullable MediaItem newMediaItem = newPlayerWrapper.getCurrentMediaItemWithCommandCheck();
      if (oldPlayerWrapper == null
          || !Util.areEqual(oldPlayerWrapper.getCurrentMediaItemWithCommandCheck(), newMediaItem)) {
        // Note: This will update both PlaybackStateCompat and metadata.
        onMediaItemTransition(
            seq, newMediaItem, Player.MEDIA_ITEM_TRANSITION_REASON_PLAYLIST_CHANGED);
      } else {
        // If PlaybackStateCompat isn't updated by above if-statement, forcefully update
        // PlaybackStateCompat to tell the latest position and its event
        // time. This would also update playback speed, buffering state, player state, and error.
        updateLegacySessionPlaybackState(newPlayerWrapper);
      }
    }

    @Override
    public void onPlayerError(int seq, @Nullable PlaybackException playerError) {
      updateLegacySessionPlaybackState(sessionImpl.getPlayerWrapper());
    }

    @Override
    public void setCustomLayout(int seq, List<CommandButton> layout) {
      updateLegacySessionPlaybackState(sessionImpl.getPlayerWrapper());
    }

    @Override
    public void onSessionExtrasChanged(int seq, Bundle sessionExtras) {
      sessionCompat.setExtras(sessionExtras);
      sessionImpl.getPlayerWrapper().setLegacyExtras(sessionExtras);
      sessionCompat.setPlaybackState(sessionImpl.getPlayerWrapper().createPlaybackStateCompat());
    }

    @Override
    public void onSessionActivityChanged(int seq, PendingIntent sessionActivity) {
      sessionCompat.setSessionActivity(sessionActivity);
    }

    @Override
    public void onError(int seq, SessionError sessionError) {
      PlayerWrapper playerWrapper = sessionImpl.getPlayerWrapper();
      playerWrapper.setLegacyError(
          /* isFatal= */ false,
          LegacyConversions.convertToLegacyErrorCode(sessionError.code),
          sessionError.message,
          sessionError.extras);
      sessionCompat.setPlaybackState(playerWrapper.createPlaybackStateCompat());
      playerWrapper.clearLegacyErrorStatus();
      sessionCompat.setPlaybackState(playerWrapper.createPlaybackStateCompat());
    }

    @Override
    public void sendCustomCommand(int seq, SessionCommand command, Bundle args) {
      sessionCompat.sendSessionEvent(command.customAction, args);
    }

    @Override
    public void onPlayWhenReadyChanged(
        int seq, boolean playWhenReady, @Player.PlaybackSuppressionReason int reason)
        throws RemoteException {
      // Note: This method does not use any of the given arguments.
      updateLegacySessionPlaybackState(sessionImpl.getPlayerWrapper());
      // MD3Music fork v22：开播瞬间就起进度补刷（isPlaying 的翻转可能稍晚到达，
      // playWhenReady 更早，覆盖「连车自动续播」这类冷启动场景）。
      if (playWhenReady) {
        startLegacyProgressRefresh();
      }
    }


    @Override
    public void onPlaybackSuppressionReasonChanged(
        int seq, @Player.PlaybackSuppressionReason int reason) throws RemoteException {
      updateLegacySessionPlaybackState(sessionImpl.getPlayerWrapper());
    }

    @Override
    public void onPlaybackStateChanged(
        int seq, @Player.State int state, @Nullable PlaybackException playerError)
        throws RemoteException {
      // Note: This method does not use any of the given arguments.
      updateLegacySessionPlaybackState(sessionImpl.getPlayerWrapper());
    }

    @Override
    public void onIsPlayingChanged(int seq, boolean isPlaying) throws RemoteException {
      updateLegacySessionPlaybackState(sessionImpl.getPlayerWrapper());
      // MD3Music fork v22：播放开始/结束决定进度补刷的开关（车机歌词对轴用）。
      if (isPlaying) {
        startLegacyProgressRefresh();
      } else {
        stopLegacyProgressRefresh();
      }
    }

    @Override
    public void onPositionDiscontinuity(
        int seq,
        PositionInfo oldPosition,
        PositionInfo newPosition,
        @DiscontinuityReason int reason)
        throws RemoteException {
      // Note: This method does not use any of the given arguments.
      updateLegacySessionPlaybackState(sessionImpl.getPlayerWrapper());
    }

    @Override
    public void onPlaybackParametersChanged(int seq, PlaybackParameters playbackParameters)
        throws RemoteException {
      // Note: This method does not use any of the given arguments.
      updateLegacySessionPlaybackState(sessionImpl.getPlayerWrapper());
    }

    @Override
    public void onMediaItemTransition(
        int seq, @Nullable MediaItem mediaItem, @Player.MediaItemTransitionReason int reason)
        throws RemoteException {
      // MediaMetadataCompat needs to be updated when the media ID or URI of the media item changes.
      updateMetadataIfChanged();
      if (mediaItem == null) {
        sessionCompat.setRatingType(RatingCompat.RATING_NONE);
      } else {
        sessionCompat.setRatingType(
            LegacyConversions.getRatingCompatStyle(mediaItem.mediaMetadata.userRating));
      }
      updateLegacySessionPlaybackState(sessionImpl.getPlayerWrapper());
    }

    @Override
    public void onMediaMetadataChanged(int seq, MediaMetadata mediaMetadata) {
      updateMetadataIfChanged();
    }

    /// MD3Music fork（CarWith）：把上一帧 metadata 缓存重置为构造期同款的 EMPTY
    /// 哨兵（不能用 null——updateMetadataIfChanged 对 lastMediaMetadata 直接取
    /// .extras，null 会 NPE），让「这一次」必然穿过 Objects.equals 去重、把当前
    /// 这份（含四个 ucar 歌词键）强制下发给 legacy 控制器；方法内随即重新赋值，
    /// 不影响后续正常事件的判重。只由 forceLegacyMetadataBroadcast 在门控后调用。
    public void forceMetadataBroadcast() {
      lastMediaMetadata = MediaMetadata.EMPTY;
      updateMetadataIfChanged();
    }

    @Override
    public void onTimelineChanged(
        int seq, Timeline timeline, @Player.TimelineChangeReason int reason)
        throws RemoteException {
      updateQueue(timeline);
      // Duration might be unknown at onMediaItemTransition and become available afterward.
      updateMetadataIfChanged();
    }

    private void updateQueue(Timeline timeline) {
      if (!isQueueEnabled() || timeline.isEmpty()) {
        setQueue(sessionCompat, /* queue= */ null);
        // MD3Music fork（方向3·队列镜像）：活跃会话的队列清空也要同步影子
        // （播放列表清空/引擎收敛后影子不得残留旧列表）；非活跃影子的自身
        // 清空事件经 IfActive 门自然跳过，不会抹掉已镜像的队列。
        mirrorQueueToShadowSessionsIfActive(null);
        return;
      }
      List<MediaItem> mediaItemList = LegacyConversions.convertToMediaItemList(timeline);
      List<@NullableType ListenableFuture<Bitmap>> bitmapFutures = new ArrayList<>();
      final AtomicInteger resultCount = new AtomicInteger(0);
      Runnable handleBitmapFuturesTask =
          () -> {
            int completedBitmapFutureCount = resultCount.incrementAndGet();
            if (completedBitmapFutureCount == mediaItemList.size()) {
              handleBitmapFuturesAllCompletedAndSetQueue(bitmapFutures, timeline, mediaItemList);
            }
          };

      for (int i = 0; i < mediaItemList.size(); i++) {
        MediaItem mediaItem = mediaItemList.get(i);
        MediaMetadata metadata = mediaItem.mediaMetadata;
        if (metadata.artworkData == null) {
          bitmapFutures.add(null);
          handleBitmapFuturesTask.run();
        } else {
          ListenableFuture<Bitmap> bitmapFuture =
              sessionImpl.getBitmapLoader().decodeBitmap(metadata.artworkData);
          bitmapFutures.add(bitmapFuture);
          bitmapFuture.addListener(
              handleBitmapFuturesTask, sessionImpl.getApplicationHandler()::post);
        }
      }
    }

    private void handleBitmapFuturesAllCompletedAndSetQueue(
        List<@NullableType ListenableFuture<Bitmap>> bitmapFutures,
        Timeline timeline,
        List<MediaItem> mediaItems) {
      List<QueueItem> queueItemList = new ArrayList<>();
      for (int i = 0; i < bitmapFutures.size(); i++) {
        @Nullable ListenableFuture<Bitmap> future = bitmapFutures.get(i);
        @Nullable Bitmap bitmap = null;
        if (future != null) {
          try {
            bitmap = Futures.getDone(future);
          } catch (CancellationException | ExecutionException e) {
            Log.d(TAG, "Failed to get bitmap", e);
          }
        }
        queueItemList.add(LegacyConversions.convertToQueueItem(mediaItems.get(i), i, bitmap));
      }

      if (Util.SDK_INT < 21) {
        // In order to avoid TransactionTooLargeException for below API 21, we need to
        // cut the list so that it doesn't exceed the binder transaction limit.
        List<QueueItem> truncatedList =
            MediaUtils.truncateListBySize(queueItemList, TRANSACTION_SIZE_LIMIT_IN_BYTES);
        if (truncatedList.size() != timeline.getWindowCount()) {
          Log.i(
              TAG,
              "Sending " + truncatedList.size() + " items out of " + timeline.getWindowCount());
        }
        setQueue(sessionCompat, truncatedList);
      } else {
        // Framework MediaSession#setQueue() uses ParceledListSlice,
        // which means we can safely send long lists.
        setQueue(sessionCompat, queueItemList);
      }
      // MD3Music fork（方向3·队列镜像）：活跃队列发布即同步影子。
      mirrorQueueToShadowSessionsIfActive(queueItemList);
    }

    @Override
    public void onPlaylistMetadataChanged(int seq, MediaMetadata playlistMetadata)
        throws RemoteException {
      // Since there is no 'queue metadata', only set title of the queue.
      @Nullable CharSequence queueTitle = sessionCompat.getController().getQueueTitle();
      @Nullable CharSequence newTitle = playlistMetadata.title;
      if (!TextUtils.equals(queueTitle, newTitle)) {
        setQueueTitle(sessionCompat, newTitle);
      }
    }

    @Override
    public void onShuffleModeEnabledChanged(int seq, boolean shuffleModeEnabled)
        throws RemoteException {
      sessionCompat.setShuffleMode(
          LegacyConversions.convertToPlaybackStateCompatShuffleMode(shuffleModeEnabled));
    }

    @Override
    public void onRepeatModeChanged(int seq, @RepeatMode int repeatMode) throws RemoteException {
      sessionCompat.setRepeatMode(
          LegacyConversions.convertToPlaybackStateCompatRepeatMode(repeatMode));
    }

    @Override
    public void onAudioAttributesChanged(int seq, AudioAttributes audioAttributes) {
      @DeviceInfo.PlaybackType
      int playbackType = sessionImpl.getPlayerWrapper().getDeviceInfo().playbackType;
      if (playbackType == DeviceInfo.PLAYBACK_TYPE_LOCAL) {
        int legacyStreamType = LegacyConversions.getLegacyStreamType(audioAttributes);
        sessionCompat.setPlaybackToLocal(legacyStreamType);
      }
    }

    @Override
    public void onDeviceInfoChanged(int seq, DeviceInfo deviceInfo) {
      PlayerWrapper player = sessionImpl.getPlayerWrapper();
      volumeProviderCompat = player.createVolumeProviderCompat();
      if (volumeProviderCompat == null) {
        int streamType =
            LegacyConversions.getLegacyStreamType(player.getAudioAttributesWithCommandCheck());
        sessionCompat.setPlaybackToLocal(streamType);
      } else {
        sessionCompat.setPlaybackToRemote(volumeProviderCompat);
      }
    }

    @Override
    public void onDeviceVolumeChanged(int seq, int volume, boolean muted) {
      if (volumeProviderCompat != null) {
        volumeProviderCompat.setCurrentVolume(muted ? 0 : volume);
      }
    }

    @Override
    public void onPeriodicSessionPositionInfoChanged(
        int unusedSeq,
        SessionPositionInfo unusedSessionPositionInfo,
        boolean unusedCanAccessCurrentMediaItem,
        boolean unusedCanAccessTimeline,
        int controllerInterfaceVersion)
        throws RemoteException {
      updateLegacySessionPlaybackState(sessionImpl.getPlayerWrapper());
    }

    @Nullable
    private static String legacyLyricInfo(MediaMetadata metadata) {
      return metadata.extras == null ? null : metadata.extras.getString("lyricInfo");
    }

    private void updateMetadataIfChanged() {
      PlayerWrapper player = sessionImpl.getPlayerWrapper();
      @Nullable MediaItem currentMediaItem = player.getCurrentMediaItemWithCommandCheck();
      MediaMetadata newMediaMetadata = player.getMediaMetadataWithCommandCheck();
      long newDurationMs =
          player.isCurrentMediaItemLiveWithCommandCheck()
              ? C.TIME_UNSET
              : player.getDurationWithCommandCheck();
      String newMediaId =
          currentMediaItem != null ? currentMediaItem.mediaId : MediaItem.DEFAULT_MEDIA_ID;
      @Nullable
      Uri newMediaUri =
          currentMediaItem != null && currentMediaItem.localConfiguration != null
              ? currentMediaItem.localConfiguration.uri
              : null;

      if (Objects.equals(lastMediaMetadata, newMediaMetadata)
          && Objects.equals(legacyLyricInfo(lastMediaMetadata), legacyLyricInfo(newMediaMetadata))
          && Objects.equals(lastMediaId, newMediaId)
          && Objects.equals(lastMediaUri, newMediaUri)
          && lastDurationMs == newDurationMs) {
        return;
      }

      lastMediaId = newMediaId;
      lastMediaUri = newMediaUri;
      lastMediaMetadata = newMediaMetadata;
      lastDurationMs = newDurationMs;

      @Nullable Bitmap artworkBitmap = null;
      ListenableFuture<Bitmap> bitmapFuture =
          sessionImpl.getBitmapLoader().loadBitmapFromMetadata(newMediaMetadata);
      // MD3Music fork: 诊断日志（封面链路，Log.i：vivo 屏蔽 D 级）
      android.util.Log.i("MD3CarLyrics", "updateMetadataIfChanged: loader="
          + (bitmapFuture == null ? "null(无artworkData/artworkUri)" : "future")
          + " artData=" + (newMediaMetadata.artworkData != null)
          + " artUri=" + (newMediaMetadata.artworkUri != null));
      if (bitmapFuture != null) {
        pendingBitmapLoadCallback = null;
        if (bitmapFuture.isDone()) {
          try {
            artworkBitmap = Futures.getDone(bitmapFuture);
          } catch (CancellationException | ExecutionException e) {
            Log.w(TAG, getBitmapLoadErrorMessage(e));
          }
        } else {
          pendingBitmapLoadCallback =
              new FutureCallback<Bitmap>() {
                @Override
                public void onSuccess(Bitmap result) {
                  if (this != pendingBitmapLoadCallback) {
                    return;
                  }
                  setMetadata(
                      sessionCompat,
                      LegacyConversions.convertToMediaMetadataCompat(
                          newMediaMetadata,
                          newMediaId,
                          newMediaUri,
                          newDurationMs,
                          /* artworkBitmap= */ result));
                  sessionImpl.onNotificationRefreshRequired();
                }

                @Override
                public void onFailure(Throwable t) {
                  if (this != pendingBitmapLoadCallback) {
                    return;
                  }
                  Log.w(TAG, getBitmapLoadErrorMessage(t));
                }
              };
          Futures.addCallback(
              bitmapFuture,
              pendingBitmapLoadCallback,
              /* executor= */ sessionImpl.getApplicationHandler()::post);
        }
      }
      setMetadata(
          sessionCompat,
          LegacyConversions.convertToMediaMetadataCompat(
              newMediaMetadata, newMediaId, newMediaUri, newDurationMs, artworkBitmap));
    }
  }

  private static class ConnectionTimeoutHandler extends Handler {

    private static final int MSG_CONNECTION_TIMED_OUT = 1001;

    private final ConnectedControllersManager<RemoteUserInfo> connectedControllersManager;

    public ConnectionTimeoutHandler(
        Looper looper, ConnectedControllersManager<RemoteUserInfo> connectedControllersManager) {
      super(looper);
      this.connectedControllersManager = connectedControllersManager;
    }

    @Override
    public void handleMessage(Message msg) {
      ControllerInfo controller = (ControllerInfo) msg.obj;
      if (connectedControllersManager.isConnected(controller)) {
        try {
          checkStateNotNull(controller.getControllerCb()).onDisconnected(/* seq= */ 0);
        } catch (RemoteException e) {
          // Controller may have died prematurely.
        }
        connectedControllersManager.removeController(controller);
      }
    }

    public void disconnectControllerAfterTimeout(
        ControllerInfo controller, long disconnectTimeoutMs) {
      removeMessages(MSG_CONNECTION_TIMED_OUT, controller);
      Message msg = obtainMessage(MSG_CONNECTION_TIMED_OUT, controller);
      sendMessageDelayed(msg, disconnectTimeoutMs);
    }
  }

  private static String getBitmapLoadErrorMessage(Throwable throwable) {
    return "Failed to load bitmap: " + throwable.getMessage();
  }

  @Nullable
  @SuppressWarnings("QueryPermissionsNeeded") // Needs to be provided in the app manifest.
  private static ComponentName getServiceComponentByAction(Context context, String action) {
    PackageManager pm = context.getPackageManager();
    Intent queryIntent = new Intent(action);
    queryIntent.setPackage(context.getPackageName());
    List<ResolveInfo> resolveInfos = pm.queryIntentServices(queryIntent, /* flags= */ 0);
    if (resolveInfos == null || resolveInfos.isEmpty()) {
      return null;
    }
    ResolveInfo resolveInfo = resolveInfos.get(0);
    return new ComponentName(resolveInfo.serviceInfo.packageName, resolveInfo.serviceInfo.name);
  }

  private final class MediaButtonReceiver extends BroadcastReceiver {

    @Override
    public void onReceive(Context context, Intent intent) {
      if (!Util.areEqual(intent.getAction(), Intent.ACTION_MEDIA_BUTTON)) {
        return;
      }
      Uri sessionUri = intent.getData();
      // MD3Music fork v28d：守卫补实——此前写成了 sessionUri 自比较恒等，
      // 判空逻辑从未生效。正确口径是与本会话自身的 URI 比较。
      if (!Util.areEqual(sessionUri, sessionImpl.getUri())) {
        return;
      }
      KeyEvent keyEvent = intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT);
      if (keyEvent == null) {
        return;
      }
      sessionCompat.getController().dispatchMediaButtonEvent(keyEvent);
    }
  }

  @RequiresApi(31)
  private static final class Api31 {
    @DoNotInline
    public static void setMediaButtonBroadcastReceiver(
        MediaSessionCompat mediaSessionCompat, ComponentName broadcastReceiver) {
      ((android.media.session.MediaSession) checkNotNull(mediaSessionCompat.getMediaSession()))
          .setMediaButtonBroadcastReceiver(broadcastReceiver);
    }
  }
}
