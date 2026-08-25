/*
 * Copyright (C) 2018 The Android Open Source Project
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
package androidx.media3.exoplayer;

import static androidx.media3.common.util.Assertions.checkNotNull;
import static java.lang.annotation.ElementType.TYPE_USE;

import android.content.Context;
import android.media.AudioManager;
import android.os.Handler;
import androidx.annotation.IntDef;
import androidx.annotation.Nullable;
import androidx.annotation.RequiresApi;
import androidx.annotation.VisibleForTesting;
import androidx.media.AudioAttributesCompat;
import androidx.media.AudioFocusRequestCompat;
import androidx.media.AudioManagerCompat;
import androidx.media3.common.AudioAttributes;
import androidx.media3.common.C;
import androidx.media3.common.Player;
import androidx.media3.common.util.Assertions;
import androidx.media3.common.util.Log;
import androidx.media3.common.util.Util;
import java.lang.annotation.Documented;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;
import org.checkerframework.checker.nullness.qual.MonotonicNonNull;

/** Manages requesting and responding to changes in audio focus. */
// MD3Music fork: 由 package-private 改为 public，供 just_audio 注册焦点事件监听。
public final class AudioFocusManager {

  /** Interface to allow AudioFocusManager to give commands to a player. */
  public interface PlayerControl {
    /**
     * Called when the volume multiplier on the player should be changed.
     *
     * @param volumeMultiplier The new volume multiplier.
     */
    void setVolumeMultiplier(float volumeMultiplier);

    /**
     * Called when a command must be executed on the player.
     *
     * @param playerCommand The command that must be executed.
     */
    void executePlayerCommand(@PlayerCommand int playerCommand);
  }

  /**
   * Player commands. One of {@link #PLAYER_COMMAND_DO_NOT_PLAY}, {@link
   * #PLAYER_COMMAND_WAIT_FOR_CALLBACK} or {@link #PLAYER_COMMAND_PLAY_WHEN_READY}.
   */
  @Documented
  @Retention(RetentionPolicy.SOURCE)
  @Target(TYPE_USE)
  @IntDef({
    PLAYER_COMMAND_DO_NOT_PLAY,
    PLAYER_COMMAND_WAIT_FOR_CALLBACK,
    PLAYER_COMMAND_PLAY_WHEN_READY,
  })
  public @interface PlayerCommand {}

  /** Do not play, because audio focus is lost or denied. */
  public static final int PLAYER_COMMAND_DO_NOT_PLAY = -1;

  /** Do not play now, because of a transient focus loss. */
  public static final int PLAYER_COMMAND_WAIT_FOR_CALLBACK = 0;

  /** Play freely, because audio focus is granted or not applicable. */
  public static final int PLAYER_COMMAND_PLAY_WHEN_READY = 1;

  /** Audio focus state. */
  @Documented
  @Retention(RetentionPolicy.SOURCE)
  @Target(TYPE_USE)
  @IntDef({
    AUDIO_FOCUS_STATE_NOT_REQUESTED,
    AUDIO_FOCUS_STATE_NO_FOCUS,
    AUDIO_FOCUS_STATE_HAVE_FOCUS,
    AUDIO_FOCUS_STATE_LOSS_TRANSIENT,
    AUDIO_FOCUS_STATE_LOSS_TRANSIENT_DUCK
  })
  private @interface AudioFocusState {}

  /** Audio focus has not been requested yet. */
  private static final int AUDIO_FOCUS_STATE_NOT_REQUESTED = 0;

  /** No audio focus is currently being held. */
  private static final int AUDIO_FOCUS_STATE_NO_FOCUS = 1;

  /** The requested audio focus is currently held. */
  private static final int AUDIO_FOCUS_STATE_HAVE_FOCUS = 2;

  /** Audio focus has been temporarily lost. */
  private static final int AUDIO_FOCUS_STATE_LOSS_TRANSIENT = 3;

  /** Audio focus has been temporarily lost, but playback may continue with reduced volume. */
  private static final int AUDIO_FOCUS_STATE_LOSS_TRANSIENT_DUCK = 4;

  /**
   * Audio focus types. One of {@link #AUDIOFOCUS_NONE}, {@link #AUDIOFOCUS_GAIN}, {@link
   * #AUDIOFOCUS_GAIN_TRANSIENT}, {@link #AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK} or {@link
   * #AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE}.
   */
  @Documented
  @Retention(RetentionPolicy.SOURCE)
  @Target(TYPE_USE)
  @IntDef({
    AUDIOFOCUS_NONE,
    AUDIOFOCUS_GAIN,
    AUDIOFOCUS_GAIN_TRANSIENT,
    AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK,
    AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE
  })
  private @interface AudioFocusGain {}

  /**
   * @see AudioManager#AUDIOFOCUS_NONE
   */
  @SuppressWarnings("InlinedApi")
  private static final int AUDIOFOCUS_NONE = AudioManager.AUDIOFOCUS_NONE;

  /**
   * @see AudioManager#AUDIOFOCUS_GAIN
   */
  private static final int AUDIOFOCUS_GAIN = AudioManager.AUDIOFOCUS_GAIN;

  /**
   * @see AudioManager#AUDIOFOCUS_GAIN_TRANSIENT
   */
  private static final int AUDIOFOCUS_GAIN_TRANSIENT = AudioManager.AUDIOFOCUS_GAIN_TRANSIENT;

  /**
   * @see AudioManager#AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
   */
  private static final int AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK =
      AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK;

  /**
   * @see AudioManager#AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE
   */
  @SuppressWarnings("InlinedApi")
  private static final int AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE =
      AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE;

  private static final String TAG = "AudioFocusManager";

  private static final float VOLUME_MULTIPLIER_DUCK = 0.2f;
  private static final float VOLUME_MULTIPLIER_DEFAULT = 1.0f;

  /** MD3Music fork: 原始音频焦点变化事件监听（真实系统事件，含 duck/pause/gain）。 */
  public interface AudioFocusEventListener {
    void onAudioFocusChanged(int focusChange);
  }

  /** MD3Music fork: 全局焦点事件监听器（支持多播放器，各自转发到自己的 Dart 通道）。 */
  private static final java.util.List<AudioFocusEventListener> audioFocusEventListeners =
      new java.util.concurrent.CopyOnWriteArrayList<>();

  /** MD3Music fork: 注册焦点事件监听。 */
  public static void addAudioFocusEventListener(AudioFocusEventListener listener) {
    if (listener != null && !audioFocusEventListeners.contains(listener)) {
      audioFocusEventListeners.add(listener);
    }
  }

  /** MD3Music fork: 注销焦点事件监听。 */
  public static void removeAudioFocusEventListener(AudioFocusEventListener listener) {
    audioFocusEventListeners.remove(listener);
  }

  /** MD3Music fork: 强制 willPauseWhenDucked 的值；null 恢复默认（按 contentType 判断）。 */
  @Nullable private static volatile Boolean forcedWillPauseWhenDucked;

  /** MD3Music fork: 设置强制 willPauseWhenDucked；传 null 恢复默认。 */
  public static void setForcedWillPauseWhenDucked(@Nullable Boolean force) {
    forcedWillPauseWhenDucked = force;
  }

  /** MD3Music fork: 全局忽略音频焦点标志（「允许与其他应用同时播放音频」）。 */
  private static volatile boolean ignoreAudioFocus = false;

  /** MD3Music fork: 设置忽略模式：true 时跳过 Media3 内置焦点处理（仅转发事件，不
   *  duck / 不暂停 / 不 abandon），播放与音量完全由 Dart 层保持。 */
  public static void setIgnoreAudioFocus(boolean ignore) {
    ignoreAudioFocus = ignore;
  }

  /** MD3Music fork: 「保持播放与音量」模式标志：同样跳过 Media3 内置处理。 */
  private static volatile boolean forceKeepPlaying = false;

  /** MD3Music fork: 设置保持播放模式：true 时跳过 Media3 内置焦点处理（仅转发事件）。 */
  public static void setForceKeepPlaying(boolean keepPlaying) {
    forceKeepPlaying = keepPlaying;
  }

  /** MD3Music fork: 是否跳过 Media3 内置焦点处理（仅转发事件、不响应）。 */
  private static boolean shouldSkipFocusHandling(int focusChange) {
    if (ignoreAudioFocus) {
      // 忽略模式（「允许与其他应用同时播放音频」）：完全跳过（含独占型 LOSS），
      // 所有中断下播放与音量完全保持。
      return true;
    }
    if (forceKeepPlaying) {
      // 「保持播放与音量」：短暂中断（导航等 LOSS_TRANSIENT/CAN_DUCK）保持播放；
      // 独占型 LOSS（B 站视频 / 来电）正常让路暂停——否则对方 app 拿不到焦点。
      return focusChange == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT
          || focusChange == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK;
    }
    return false;
  }

  private final AudioManager audioManager;
  private final AudioFocusListener focusListener;
  @Nullable private PlayerControl playerControl;
  @Nullable private AudioAttributes audioAttributes;

  private @AudioFocusState int audioFocusState;
  private @AudioFocusGain int focusGainToRequest;
  private float volumeMultiplier = VOLUME_MULTIPLIER_DEFAULT;

  // MD3Music fork: 改用 AudioFocusRequestCompat（自动携带 ACCEPTS_DUCKING）
  private @MonotonicNonNull AudioFocusRequestCompat audioFocusRequestCompat;
  private boolean rebuildAudioFocusRequest;

  /**
   * Constructs an AudioFocusManager to automatically handle audio focus for a player.
   *
   * @param context The current context.
   * @param eventHandler A {@link Handler} to for the thread on which the player is used.
   * @param playerControl A {@link PlayerControl} to handle commands from this instance.
   */
  public AudioFocusManager(Context context, Handler eventHandler, PlayerControl playerControl) {
    this.audioManager =
        checkNotNull(
            (AudioManager) context.getApplicationContext().getSystemService(Context.AUDIO_SERVICE));
    this.playerControl = playerControl;
    this.focusListener = new AudioFocusListener(eventHandler);
    this.audioFocusState = AUDIO_FOCUS_STATE_NOT_REQUESTED;
  }

  /** Gets the current player volume multiplier. */
  public float getVolumeMultiplier() {
    return volumeMultiplier;
  }

  /**
   * Sets audio attributes that should be used to manage audio focus.
   *
   * <p>Call {@link #updateAudioFocus(boolean, int)} to update the audio focus based on these
   * attributes.
   *
   * @param audioAttributes The audio attributes or {@code null} if audio focus should not be
   *     managed automatically.
   */
  public void setAudioAttributes(@Nullable AudioAttributes audioAttributes) {
    if (!Util.areEqual(this.audioAttributes, audioAttributes)) {
      this.audioAttributes = audioAttributes;
      focusGainToRequest = convertAudioAttributesToFocusGain(audioAttributes);
      Assertions.checkArgument(
          focusGainToRequest == AUDIOFOCUS_GAIN || focusGainToRequest == AUDIOFOCUS_NONE,
          "Automatic handling of audio focus is only available for USAGE_MEDIA and USAGE_GAME.");
    }
  }

  /**
   * Called by the player to abandon or request audio focus based on the desired player state.
   *
   * @param playWhenReady The desired value of playWhenReady.
   * @param playbackState The desired playback state.
   * @return A {@link PlayerCommand} to execute on the player.
   */
  public @PlayerCommand int updateAudioFocus(
      boolean playWhenReady, @Player.State int playbackState) {
    if (!shouldHandleAudioFocus(playbackState)) {
      abandonAudioFocusIfHeld();
      setAudioFocusState(AUDIO_FOCUS_STATE_NOT_REQUESTED);
      return PLAYER_COMMAND_PLAY_WHEN_READY;
    }
    if (playWhenReady) {
      return requestAudioFocus();
    }
    switch (audioFocusState) {
      case AUDIO_FOCUS_STATE_NO_FOCUS:
        return PLAYER_COMMAND_DO_NOT_PLAY;
      case AUDIO_FOCUS_STATE_LOSS_TRANSIENT:
        return PLAYER_COMMAND_WAIT_FOR_CALLBACK;
      default:
        return PLAYER_COMMAND_PLAY_WHEN_READY;
    }
  }

  /**
   * Called when the manager is no longer required. Audio focus will be released without making any
   * calls to the {@link PlayerControl}.
   */
  public void release() {
    playerControl = null;
    abandonAudioFocusIfHeld();
    setAudioFocusState(AUDIO_FOCUS_STATE_NOT_REQUESTED);
  }

  // Internal methods.

  @VisibleForTesting
  /* package */ AudioManager.OnAudioFocusChangeListener getFocusListener() {
    return focusListener;
  }

  private boolean shouldHandleAudioFocus(@Player.State int playbackState) {
    return playbackState != Player.STATE_IDLE && focusGainToRequest == AUDIOFOCUS_GAIN;
  }

  private @PlayerCommand int requestAudioFocus() {
    if (audioFocusState == AUDIO_FOCUS_STATE_HAVE_FOCUS) {
      return PLAYER_COMMAND_PLAY_WHEN_READY;
    }
    int requestResult = Util.SDK_INT >= 26 ? requestAudioFocusV26() : requestAudioFocusDefault();
    if (requestResult == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
      setAudioFocusState(AUDIO_FOCUS_STATE_HAVE_FOCUS);
      return PLAYER_COMMAND_PLAY_WHEN_READY;
    } else {
      setAudioFocusState(AUDIO_FOCUS_STATE_NO_FOCUS);
      return PLAYER_COMMAND_DO_NOT_PLAY;
    }
  }

  private void abandonAudioFocusIfHeld() {
    if (audioFocusState == AUDIO_FOCUS_STATE_NO_FOCUS
        || audioFocusState == AUDIO_FOCUS_STATE_NOT_REQUESTED) {
      return;
    }
    if (Util.SDK_INT >= 26) {
      abandonAudioFocusV26();
    } else {
      abandonAudioFocusDefault();
    }
  }

  private int requestAudioFocusDefault() {
    return audioManager.requestAudioFocus(
        focusListener,
        Util.getStreamTypeForAudioUsage(checkNotNull(audioAttributes).usage),
        focusGainToRequest);
  }

  @RequiresApi(26)
  private int requestAudioFocusV26() {
    if (audioFocusRequestCompat == null || rebuildAudioFocusRequest) {
      // MD3Music fork: willPauseWhenDucked 跟随 forced（Dart 三模式）：
      // - forced=true（保持/暂停）：true → 系统对 MAY_DUCK 请求发 LOSS_TRANSIENT
      //   （pause 语义）而非系统级自动 duck（VolumeShaper）。事件可达 Media3
      //   AudioFocusManager → Dart 三模式（keepPlaying 对抗 / pauseAndResume 暂停恢复）。
      // - forced=false（降音量恢复）：false → 系统级自动 duck（0.2→恢复），无需事件。
      // Android 15+ 对 willPauseWhenDucked=false 的持有者直接 applyVolumeShaper，
      // 不派发任何焦点事件——故「降音量后自动恢复」完全依赖系统行为。
      boolean willPauseWhenDucked = willPauseWhenDucked();
      AudioFocusRequestCompat.Builder builder =
          new AudioFocusRequestCompat.Builder(focusGainToRequest);
      builder.setAudioAttributes(AudioAttributesCompat.wrap(
          checkNotNull(audioAttributes).getAudioAttributesV21().audioAttributes));
      builder.setOnAudioFocusChangeListener(focusListener);
      builder.setWillPauseWhenDucked(willPauseWhenDucked);
      AudioFocusRequestCompat compat = builder.build();
      audioFocusRequestCompat = compat;
      rebuildAudioFocusRequest = false;
      return AudioManagerCompat.requestAudioFocus(audioManager, compat);
    }
    return AudioManagerCompat.requestAudioFocus(audioManager, audioFocusRequestCompat);
  }

  private void abandonAudioFocusDefault() {
    audioManager.abandonAudioFocus(focusListener);
  }

  @RequiresApi(26)
  private void abandonAudioFocusV26() {
    if (audioFocusRequestCompat != null) {
      AudioManagerCompat.abandonAudioFocusRequest(audioManager, audioFocusRequestCompat);
    }
  }

  private boolean willPauseWhenDucked() {
    // MD3Music fork: 支持外部强制（Dart 三模式「保持播放与音量」将 duck 转为 pause 语义，
    // 由 Dart 侧对抗自动 pause，实现音量不变）。
    Boolean force = forcedWillPauseWhenDucked;
    if (force != null) {
      return force;
    }
    return audioAttributes != null && audioAttributes.contentType == C.AUDIO_CONTENT_TYPE_SPEECH;
  }

  /**
   * Converts {@link AudioAttributes} to one of the audio focus request.
   *
   * <p>This follows the class Javadoc of {@link AudioFocusRequest}.
   *
   * @param audioAttributes The audio attributes associated with this focus request.
   * @return The type of audio focus gain that should be requested.
   */
  private static @AudioFocusGain int convertAudioAttributesToFocusGain(
      @Nullable AudioAttributes audioAttributes) {
    if (audioAttributes == null) {
      // Don't handle audio focus. It may be either video only contents or developers
      // want to have more finer grained control. (e.g. adding audio focus listener)
      return AUDIOFOCUS_NONE;
    }

    switch (audioAttributes.usage) {
        // USAGE_VOICE_COMMUNICATION_SIGNALLING is for DTMF that may happen multiple times
        // during the phone call when AUDIOFOCUS_GAIN_TRANSIENT is requested for that.
        // Don't request audio focus here.
      case C.USAGE_VOICE_COMMUNICATION_SIGNALLING:
        return AUDIOFOCUS_NONE;

        // Javadoc says 'AUDIOFOCUS_GAIN: Examples of uses of this focus gain are for music
        // playback, for a game or a video player'
      case C.USAGE_GAME:
      case C.USAGE_MEDIA:
        return AUDIOFOCUS_GAIN;

        // Special usages: USAGE_UNKNOWN shouldn't be used. Request audio focus to prevent
        // multiple media playback happen at the same time.
      case C.USAGE_UNKNOWN:
        Log.w(
            TAG,
            "Specify a proper usage in the audio attributes for audio focus"
                + " handling. Using AUDIOFOCUS_GAIN by default.");
        return AUDIOFOCUS_GAIN;

        // Javadoc says 'AUDIOFOCUS_GAIN_TRANSIENT: An example is for playing an alarm, or
        // during a VoIP call'
      case C.USAGE_ALARM:
      case C.USAGE_VOICE_COMMUNICATION:
        return AUDIOFOCUS_GAIN_TRANSIENT;

        // Javadoc says 'AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK: Examples are when playing
        // driving directions or notifications'
      case C.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE:
      case C.USAGE_ASSISTANCE_SONIFICATION:
      case C.USAGE_NOTIFICATION:
      case C.USAGE_NOTIFICATION_COMMUNICATION_DELAYED:
      case C.USAGE_NOTIFICATION_COMMUNICATION_INSTANT:
      case C.USAGE_NOTIFICATION_COMMUNICATION_REQUEST:
      case C.USAGE_NOTIFICATION_EVENT:
      case C.USAGE_NOTIFICATION_RINGTONE:
        return AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK;

        // Javadoc says 'AUDIOFOCUS_GAIN_EXCLUSIVE: This is typically used if you are doing
        // audio recording or speech recognition'.
        // Assistant is considered as both recording and notifying developer
      case C.USAGE_ASSISTANT:
        return AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE;

        // Special usages:
      case C.USAGE_ASSISTANCE_ACCESSIBILITY:
        if (audioAttributes.contentType == C.AUDIO_CONTENT_TYPE_SPEECH) {
          // Voice shouldn't be interrupted by other playback.
          return AUDIOFOCUS_GAIN_TRANSIENT;
        }
        return AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK;
      default:
        Log.w(TAG, "Unidentified audio usage: " + audioAttributes.usage);
        return AUDIOFOCUS_NONE;
    }
  }

  private void setAudioFocusState(@AudioFocusState int audioFocusState) {
    if (this.audioFocusState == audioFocusState) {
      return;
    }
    this.audioFocusState = audioFocusState;

    float volumeMultiplier =
        (audioFocusState == AUDIO_FOCUS_STATE_LOSS_TRANSIENT_DUCK)
            ? AudioFocusManager.VOLUME_MULTIPLIER_DUCK
            : AudioFocusManager.VOLUME_MULTIPLIER_DEFAULT;
    if (this.volumeMultiplier == volumeMultiplier) {
      return;
    }
    this.volumeMultiplier = volumeMultiplier;
    if (playerControl != null) {
      playerControl.setVolumeMultiplier(volumeMultiplier);
    }
  }

  private void handlePlatformAudioFocusChange(int focusChange) {
    // MD3Music fork: 先把原始焦点事件转发给外部（just_audio 的 Dart 层做三模式决策），
    // 再继续 Media3 内置的自动处理（duck/pause）。事件与自动处理并存：
    // Dart 层可据此覆盖 Media3 的默认行为（如「保持播放与音量」对抗 duck）。
    for (AudioFocusEventListener listener : audioFocusEventListeners) {
      listener.onAudioFocusChanged(focusChange);
    }
    // MD3Music fork: 忽略模式 / 保持播放模式（短暂中断）跳过 Media3 内置自动处理——
    // 不 duck、不暂停、不 abandon 焦点（「允许与其他应用同时播放音频」/
    // 「保持播放与音量」：系统事件到达但播放完全保持，进度与 MediaSession 一致）。
    // 独占型中断（B 站视频 GAIN → 本端 LOSS）在保持播放模式下仍正常让路暂停。
    if (shouldSkipFocusHandling(focusChange)) {
      return;
    }
    // MD3Music fork: 排障日志
    android.util.Log.i("AudioFocusMgr",
        "focusChange=" + focusChange + " willPauseWhenDucked=" + willPauseWhenDucked()
            + " state=" + audioFocusState);
    switch (focusChange) {
      case AudioManager.AUDIOFOCUS_GAIN:
        setAudioFocusState(AUDIO_FOCUS_STATE_HAVE_FOCUS);
        executePlayerCommand(PLAYER_COMMAND_PLAY_WHEN_READY);
        return;
      case AudioManager.AUDIOFOCUS_LOSS:
        executePlayerCommand(PLAYER_COMMAND_DO_NOT_PLAY);
        abandonAudioFocusIfHeld();
        setAudioFocusState(AUDIO_FOCUS_STATE_NO_FOCUS);
        return;
      case AudioManager.AUDIOFOCUS_LOSS_TRANSIENT:
      case AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK:
        if (focusChange == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT || willPauseWhenDucked()) {
          executePlayerCommand(PLAYER_COMMAND_WAIT_FOR_CALLBACK);
          setAudioFocusState(AUDIO_FOCUS_STATE_LOSS_TRANSIENT);
        } else {
          setAudioFocusState(AUDIO_FOCUS_STATE_LOSS_TRANSIENT_DUCK);
        }
        return;
      default:
        Log.w(TAG, "Unknown focus change type: " + focusChange);
    }
  }

  private void executePlayerCommand(@PlayerCommand int playerCommand) {
    if (playerControl != null) {
      playerControl.executePlayerCommand(playerCommand);
    }
  }

  // Internal audio focus listener.

  private class AudioFocusListener implements AudioManager.OnAudioFocusChangeListener {
    private final Handler eventHandler;

    public AudioFocusListener(Handler eventHandler) {
      this.eventHandler = eventHandler;
    }

    @Override
    public void onAudioFocusChange(int focusChange) {
      eventHandler.post(() -> handlePlatformAudioFocusChange(focusChange));
    }
  }
}
