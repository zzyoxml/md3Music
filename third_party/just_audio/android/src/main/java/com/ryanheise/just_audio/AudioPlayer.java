package com.ryanheise.just_audio;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.media.AudioManager;
import android.media.audiofx.AudioEffect;
import android.media.audiofx.Equalizer;
import android.media.audiofx.LoudnessEnhancer;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import androidx.media3.common.C;
import androidx.media3.exoplayer.AudioFocusManager;
import androidx.media3.exoplayer.DefaultLivePlaybackSpeedControl;import androidx.media3.exoplayer.DefaultLoadControl;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.ExoPlaybackException;
import androidx.media3.exoplayer.LivePlaybackSpeedControl;
import androidx.media3.exoplayer.LoadControl;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MediaMetadata;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.PlaybackParameters;
import androidx.media3.common.Player;
import androidx.media3.common.Player.PositionInfo;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.common.Timeline;
import androidx.media3.common.Tracks;
import androidx.media3.common.TrackSelectionParameters;
import androidx.media3.common.TrackSelectionParameters.AudioOffloadPreferences;
import androidx.media3.common.AudioAttributes;
import androidx.media3.exoplayer.audio.AudioSink;
import androidx.media3.exoplayer.NoSampleRenderer;
import androidx.media3.exoplayer.Renderer;
import androidx.media3.exoplayer.RenderersFactory;
import androidx.media3.session.MediaSession;
import androidx.media3.session.MediaSessionService;
import androidx.media3.session.CommandButton;
import androidx.media3.session.SessionCommand;
import androidx.media3.session.SessionResult;
import com.google.common.util.concurrent.Futures;
import com.google.common.util.concurrent.ListenableFuture;
import androidx.media3.extractor.DefaultExtractorsFactory;
import androidx.media3.common.Metadata;
import androidx.media3.common.Format;
import androidx.media3.exoplayer.metadata.MetadataOutput;
import androidx.media3.extractor.metadata.icy.IcyHeaders;
import androidx.media3.extractor.metadata.icy.IcyInfo;
import androidx.media3.exoplayer.source.ClippingMediaSource; // Deprecated
// For some reason, this import triggers the [deprecation] warning, despite the
// warnings being suppressed at each use.
// import androidx.media3.exoplayer.source.ConcatenatingMediaSource; // Deprecated
import androidx.media3.exoplayer.source.MediaSource; // Deprecated
import androidx.media3.exoplayer.source.ProgressiveMediaSource; // Deprecated
import androidx.media3.exoplayer.source.ShuffleOrder;
import androidx.media3.exoplayer.source.ShuffleOrder.DefaultShuffleOrder;
import androidx.media3.exoplayer.source.SilenceMediaSource; // Deprecated
import androidx.media3.common.TrackGroup;
import androidx.media3.exoplayer.dash.DashMediaSource; // Deprecated
import androidx.media3.exoplayer.hls.HlsMediaSource; // Deprecated
import androidx.media3.exoplayer.trackselection.TrackSelectionArray;
import androidx.media3.datasource.DataSource;
import androidx.media3.datasource.DataSpec;
import androidx.media3.datasource.TransferListener;
import androidx.media3.datasource.DefaultDataSource;
import androidx.media3.datasource.DefaultHttpDataSource;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.util.Util;
import io.flutter.Log;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.EventChannel.EventSink;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.Random;

public class AudioPlayer implements MethodCallHandler, Player.Listener, MetadataOutput {
    public static final int ERROR_ABORT = 10000000;

    static final String TAG = "AudioPlayer";

    private static Random random = new Random();

    private final Context context;
    private final MethodChannel methodChannel;
    private final BetterEventChannel eventChannel;
    private final BetterEventChannel dataEventChannel;
    // MD3Music fork: 音频焦点原始事件通道（Media3 AudioFocusManager 转发）
    private final BetterEventChannel focusEventChannel;
    // MD3Music fork: 焦点事件监听引用（dispose 时按同一引用注销）
    private AudioFocusManager.AudioFocusEventListener focusEventListener;

    private ProcessingState processingState;
    private long updatePosition;
    private long updateTime;
    private long bufferedPosition;
    private Long seekPos;
    private Result prepareResult;
    private Result playResult;
    private Result seekResult;
    private Map<String, MediaSource> mediaSources = new HashMap<String, MediaSource>();
    private IcyInfo icyInfo;
    private IcyHeaders icyHeaders;
    private AudioAttributes pendingAudioAttributes;
    private LoadControl loadControl;
    private boolean offloadSchedulingEnabled;
    private AudioOffloadPreferences audioOffloadPreferences;
    private boolean useLazyPreparation;
    private LivePlaybackSpeedControl livePlaybackSpeedControl;
    private List<Object> rawAudioEffects;
    private List<AudioEffect> audioEffects = new ArrayList<AudioEffect>();
    private Map<String, AudioEffect> audioEffectsMap = new HashMap<String, AudioEffect>();
    private int lastPlaylistLength = 0;
    private Map<String, Object> pendingPlaybackEvent;

    private ExoPlayer player;
    private volatile long latestExternalMetadataGeneration;
    // MD3Music fork: 音量均衡（响度归一）增益装饰器。在 buildAudioSink 时创建，
    // 通过 setNormalizationGain(gainDb) 对当前曲目设固定线性增益（可放大/衰减）。
    private NormalizationGainAudioSink normalizationGainSink;
    private Integer audioSessionId;
    private Integer errorCode;
    private String errorMessage;
    private Integer currentIndex;
    private final Handler handler = new Handler(Looper.getMainLooper());

    /** 本曲累计下载/读取的音频数据字节（歌曲信息页实时码率用）。换歌时重置。 */
    private long transferredBytes = 0;
    private final TransferListener transferListener = new TransferListener() {
        @Override
        public void onTransferInitializing(DataSource dataSource, DataSpec dataSpec, boolean isNetwork) {}
        @Override
        public void onTransferStart(DataSource dataSource, DataSpec dataSpec, boolean isNetwork) {}
        @Override
        public void onBytesTransferred(DataSource dataSource, DataSpec dataSpec, boolean isNetwork, int bytesTransferred) {
            transferredBytes += bytesTransferred;
        }
        @Override
        public void onTransferEnd(DataSource dataSource, DataSpec dataSpec, boolean isNetwork) {}
    };
    private final Runnable bufferWatcher = new Runnable() {
        @Override
        public void run() {
            if (player == null) {
                return;
            }

            long newBufferedPosition = player.getBufferedPosition();
            if (newBufferedPosition != bufferedPosition) {
                // This method updates bufferedPosition.
                broadcastImmediatePlaybackEvent();
            }
            switch (player.getPlaybackState()) {
            case Player.STATE_BUFFERING:
                handler.postDelayed(this, 200);
                break;
            case Player.STATE_READY:
                if (player.getPlayWhenReady()) {
                    handler.postDelayed(this, 500);
                } else {
                    handler.postDelayed(this, 1000);
                }
                break;
            default:
                // Stop watching buffer
            }
        }
    };

    public AudioPlayer(
        final Context applicationContext,
        final BinaryMessenger messenger,
        final String id,
        Map<?, ?> audioLoadConfiguration,
        List<Object> rawAudioEffects,
        Map<?, ?> audioOffloadPreferences,
        Boolean offloadSchedulingEnabled,
        boolean useLazyPreparation
    ) {
        this(applicationContext, messenger, id, audioLoadConfiguration, rawAudioEffects,
                audioOffloadPreferences, offloadSchedulingEnabled, useLazyPreparation, true);
    }

    /// MD3Music fork（方向1·单一媒体会话）：新增 [createMediaSession] 开关。
    /// 默认 true：正常播放器创建媒体3会话。后台 headless 引擎的播放器传 false，
    /// 不创建 media3 会话，使系统仅暴露「前台 UI 播放器」一个会话，
    /// 杜绝「媒体卡片暂停/播放与 app 内 UI 状态不同步」（跨引擎双播放器）。
    public AudioPlayer(
        final Context applicationContext,
        final BinaryMessenger messenger,
        final String id,
        Map<?, ?> audioLoadConfiguration,
        List<Object> rawAudioEffects,
        Map<?, ?> audioOffloadPreferences,
        Boolean offloadSchedulingEnabled,
        boolean useLazyPreparation,
        boolean createMediaSession
    ) {
        this.createMediaSession = createMediaSession;
        // MD3Music fork（诊断·方向1）：打印每个播放器实例构造，定位"第二个播放器"来源
        Log.i("AudioFocusFork", "AudioPlayer ctor id=" + id
                + " createMediaSession=" + createMediaSession
                + " sMediaSessionEnabled=" + sMediaSessionEnabled
                + " stack=" + (new Throwable().getStackTrace().length > 5
                    ? new Throwable().getStackTrace()[4].getClassName() + "." + new Throwable().getStackTrace()[4].getMethodName()
                    : "?"));
        this.context = applicationContext;
        this.rawAudioEffects = rawAudioEffects;
        this.offloadSchedulingEnabled = offloadSchedulingEnabled != null ? offloadSchedulingEnabled : false;
        this.useLazyPreparation = useLazyPreparation;
        // MD3Music fork: 媒体3会话 ID 用唯一值（默认空串会被 SESSION_ID_TO_SESSION_MAP
        // 判重冲突）。基于 Flutter 传入的 player id 加全局递增序号，保证同进程多播放器不撞。
        sessionId = "md3music-" + id + "-" + (SESSION_ID_COUNTER.incrementAndGet());

        if (audioOffloadPreferences != null) {
            this.audioOffloadPreferences = new AudioOffloadPreferences.Builder()
                .setIsGaplessSupportRequired((Boolean)audioOffloadPreferences.get("isGaplessSupportRequired"))
                .setIsSpeedChangeSupportRequired((Boolean)audioOffloadPreferences.get("isSpeedChangeSupportRequired"))
                .setAudioOffloadMode((Integer)audioOffloadPreferences.get("audioOffloadMode"))
                .build();
        } else {
            final int offloadMode = offloadSchedulingEnabled
                ? AudioOffloadPreferences.AUDIO_OFFLOAD_MODE_ENABLED
                : AudioOffloadPreferences.AUDIO_OFFLOAD_MODE_DISABLED;
            this.audioOffloadPreferences = new AudioOffloadPreferences.Builder()
                .setIsGaplessSupportRequired(!offloadSchedulingEnabled)
                .setIsSpeedChangeSupportRequired(!offloadSchedulingEnabled)
                .setAudioOffloadMode(offloadMode)
                .build();
        }

        methodChannel = new MethodChannel(messenger, "com.ryanheise.just_audio.methods." + id);
        methodChannel.setMethodCallHandler(this);
        eventChannel = new BetterEventChannel(messenger, "com.ryanheise.just_audio.events." + id);
        dataEventChannel = new BetterEventChannel(messenger, "com.ryanheise.just_audio.data." + id);
        // MD3Music fork: 订阅 Media3 的原始音频焦点事件（duck/pause/gain 均由
        // AudioFocusManager.handlePlatformAudioFocusChange 转发，先于自动处理发出），
        // 供 Dart 层做三模式决策（保持音量 / 降音量恢复 / 暂停恢复）。
        focusEventChannel = new BetterEventChannel(
                messenger, "com.ryanheise.just_audio.focus_events." + id);
        focusEventListener = focusChange -> focusEventChannel.success(focusChange);
        AudioFocusManager.addAudioFocusEventListener(focusEventListener);
        processingState = ProcessingState.idle;
        if (audioLoadConfiguration != null) {
            Map<?, ?> loadControlMap = (Map<?, ?>)audioLoadConfiguration.get("androidLoadControl");
            if (loadControlMap != null) {
                DefaultLoadControl.Builder builder = new DefaultLoadControl.Builder()
                    .setBufferDurationsMs(
                        (int)((getLong(loadControlMap.get("minBufferDuration")))/1000),
                        (int)((getLong(loadControlMap.get("maxBufferDuration")))/1000),
                        (int)((getLong(loadControlMap.get("bufferForPlaybackDuration")))/1000),
                        (int)((getLong(loadControlMap.get("bufferForPlaybackAfterRebufferDuration")))/1000)
                    )
                    .setPrioritizeTimeOverSizeThresholds((Boolean)loadControlMap.get("prioritizeTimeOverSizeThresholds"))
                    .setBackBuffer((int)((getLong(loadControlMap.get("backBufferDuration")))/1000), false);
                if (loadControlMap.get("targetBufferBytes") != null) {
                    builder.setTargetBufferBytes((Integer)loadControlMap.get("targetBufferBytes"));
                }
                loadControl = builder.build();
            }
            Map<?, ?> livePlaybackSpeedControlMap = (Map<?, ?>)audioLoadConfiguration.get("androidLivePlaybackSpeedControl");
            if (livePlaybackSpeedControlMap != null) {
                DefaultLivePlaybackSpeedControl.Builder builder = new DefaultLivePlaybackSpeedControl.Builder()
                    .setFallbackMinPlaybackSpeed((float)((double)((Double)livePlaybackSpeedControlMap.get("fallbackMinPlaybackSpeed"))))
                    .setFallbackMaxPlaybackSpeed((float)((double)((Double)livePlaybackSpeedControlMap.get("fallbackMaxPlaybackSpeed"))))
                    .setMinUpdateIntervalMs(((getLong(livePlaybackSpeedControlMap.get("minUpdateInterval")))/1000))
                    .setProportionalControlFactor((float)((double)((Double)livePlaybackSpeedControlMap.get("proportionalControlFactor"))))
                    .setMaxLiveOffsetErrorMsForUnitSpeed(((getLong(livePlaybackSpeedControlMap.get("maxLiveOffsetErrorForUnitSpeed")))/1000))
                    .setTargetLiveOffsetIncrementOnRebufferMs(((getLong(livePlaybackSpeedControlMap.get("targetLiveOffsetIncrementOnRebuffer")))/1000))
                    .setMinPossibleLiveOffsetSmoothingFactor((float)((double)((Double)livePlaybackSpeedControlMap.get("minPossibleLiveOffsetSmoothingFactor"))));
                livePlaybackSpeedControl = builder.build();
            }
        }
    }

    private void startWatchingBuffer() {
        handler.removeCallbacks(bufferWatcher);
        handler.post(bufferWatcher);
    }

    private void setAudioSessionId(int audioSessionId) {
        if (audioSessionId == C.AUDIO_SESSION_ID_UNSET) {
            this.audioSessionId = null;
        } else {
            this.audioSessionId = audioSessionId;
        }
        clearAudioEffects();
        if (this.audioSessionId != null) {
            for (Object rawAudioEffect : rawAudioEffects) {
                Map<?, ?> json = (Map<?, ?>)rawAudioEffect;
                AudioEffect audioEffect = decodeAudioEffect(rawAudioEffect, this.audioSessionId);
                if ((Boolean)json.get("enabled")) {
                    audioEffect.setEnabled(true);
                }
                audioEffects.add(audioEffect);
                audioEffectsMap.put((String)json.get("type"), audioEffect);
            }
        }
        enqueuePlaybackEvent();
    }

    @Override
    public void onAudioSessionIdChanged(int audioSessionId) {
        setAudioSessionId(audioSessionId);
        broadcastPendingPlaybackEvent();
    }

    @Override
    public void onMetadata(Metadata metadata) {
        for (int i = 0; i < metadata.length(); i++) {
            final Metadata.Entry entry = metadata.get(i);
            if (entry instanceof IcyInfo) {
                icyInfo = (IcyInfo) entry;
                broadcastImmediatePlaybackEvent();
            }
        }
    }

    @Override
    public void onTracksChanged(Tracks tracks) {
        for (int i = 0; i < tracks.getGroups().size(); i++) {
            TrackGroup trackGroup = tracks.getGroups().get(i).getMediaTrackGroup();

            for (int j = 0; j < trackGroup.length; j++) {
                Metadata metadata = trackGroup.getFormat(j).metadata;

                if (metadata != null) {
                    for (int k = 0; k < metadata.length(); k++) {
                        final Metadata.Entry entry = metadata.get(k);
                        if (entry instanceof IcyHeaders) {
                            icyHeaders = (IcyHeaders) entry;
                            broadcastImmediatePlaybackEvent();
                        }
                    }
                }
            }
        }
    }

    private boolean updatePositionIfChanged() {
        if (player == null) return false;
        if (!player.getPlayWhenReady() || processingState != ProcessingState.ready) {
            if (getCurrentPosition() == updatePosition) return false;
        }
        updatePosition = getCurrentPosition();
        updateTime = System.currentTimeMillis();
        return true;
    }

    private void updatePosition() {
        updatePosition = getCurrentPosition();
        updateTime = System.currentTimeMillis();
    }

    @Override
    public void onPositionDiscontinuity(PositionInfo oldPosition, PositionInfo newPosition, int reason) {
        updatePosition();
        switch (reason) {
        case Player.DISCONTINUITY_REASON_AUTO_TRANSITION:
        case Player.DISCONTINUITY_REASON_SEEK:
            updateCurrentIndex();
            break;
        }
        broadcastImmediatePlaybackEvent();
    }

    @Override
    public void onTimelineChanged(Timeline timeline, int reason) {
        if (updateCurrentIndex()) {
            broadcastImmediatePlaybackEvent();
        }
        if (player.getPlaybackState() == Player.STATE_ENDED) {
            try {
                if (player.getPlayWhenReady()) {
                    if (lastPlaylistLength == 0 && player.getMediaItemCount() > 0) {
                        player.seekTo(0, 0L);
                    } else if (player.hasNextMediaItem()) {
                        player.seekToNextMediaItem();
                    }
                } else {
                    if (player.getCurrentMediaItemIndex() < player.getMediaItemCount()) {
                        player.seekTo(player.getCurrentMediaItemIndex(), 0L);
                    }
                }
            } catch (Exception e) {
                e.printStackTrace();
            }
        }
        lastPlaylistLength = player.getMediaItemCount();
    }

    private boolean updateCurrentIndex() {
        Integer newIndex = player.getCurrentMediaItemIndex();
        // newIndex is never null.
        // currentIndex is sometimes null.
        if (!newIndex.equals(currentIndex)) {
            currentIndex = newIndex;
            return true;
        }
        return false;
    }

    @Override
    public void onPlaybackStateChanged(int playbackState) {
        switch (playbackState) {
        case Player.STATE_READY:
            if (player.getPlayWhenReady())
                updatePosition();
            processingState = ProcessingState.ready;
            errorCode = null;
            errorMessage = null;
            broadcastImmediatePlaybackEvent();
            if (prepareResult != null) {
                Map<String, Object> response = new HashMap<>();
                response.put("duration", getDuration() == C.TIME_UNSET ? null : (1000 * getDuration()));
                prepareResult.success(response);
                prepareResult = null;
                if (pendingAudioAttributes != null) {
                    player.setAudioAttributes(pendingAudioAttributes, false);
                    pendingAudioAttributes = null;
                }
            }
            if (seekResult != null) {
                completeSeek();
            }
            break;
        case Player.STATE_BUFFERING:
            updatePositionIfChanged();
            if (processingState != ProcessingState.buffering && processingState != ProcessingState.loading) {
                processingState = ProcessingState.buffering;
                errorCode = null;
                errorMessage = null;
                broadcastImmediatePlaybackEvent();
            }
            startWatchingBuffer();
            break;
        case Player.STATE_ENDED:
            if (processingState != ProcessingState.completed) {
                updatePosition();
                processingState = ProcessingState.completed;
                errorCode = null;
                errorMessage = null;
                broadcastImmediatePlaybackEvent();
            }
            if (prepareResult != null) {
                Map<String, Object> response = new HashMap<>();
                response.put("duration", getDuration() == C.TIME_UNSET ? null : (1000 * getDuration()));
                prepareResult.success(response);
                prepareResult = null;
                if (pendingAudioAttributes != null) {
                    player.setAudioAttributes(pendingAudioAttributes, false);
                    pendingAudioAttributes = null;
                }
            }
            if (playResult != null) {
                playResult.success(new HashMap<String, Object>());
                playResult = null;
            }
            break;
        }
    }

    /// MD3Music fork（阶段6·修复「媒体卡片暂停/播放 vs app 内 UI 不同步」）：
    /// 系统媒体卡片/线控按钮经媒体3会话直接驱动 ExoPlayer 的 playWhenReady，
    /// 不经过 onMethodCall，原有 enqueuePlaybackEvent 链路不会触发，
    /// 导致 Dart 端 playing 状态停留在旧值 → 音频已停、app 内进度仍在假走
    /// （反之媒体卡片播放时 app 内仍显示暂停）。
    /// 此处监听 playWhenReady/isPlaying 变化：
    /// 1) 广播播放事件（位置/缓冲等）；
    /// 2) 关键：把 playing 状态经 data 通道推给 Dart。Dart 端
    ///    playerDataMessageStream 解析 map['playing'] 才会更新
    ///    _playerEventSubject.playing —— 仅广播 event 通道不会改 playing 标志。
    @Override
    public void onEvents(Player player, Player.Events events) {
        if (events.contains(Player.EVENT_PLAY_WHEN_READY_CHANGED)
                || events.contains(Player.EVENT_IS_PLAYING_CHANGED)) {
            updatePosition();
            broadcastImmediatePlaybackEvent();
            try {
                java.util.Map<String, Object> data = new java.util.HashMap<>();
                data.put("playing", player.getPlayWhenReady());
                dataEventChannel.success(data);
                Log.i("AudioFocusFork", "onEvents push playing=" + player.getPlayWhenReady()
                        + " sessionId=" + sessionId);
            } catch (Exception e) {
                Log.w("AudioFocusFork", "onEvents push playing failed: " + e);
            }
        }
    }

    @Override
    public void onPlayerError(PlaybackException error) {
        if (error instanceof ExoPlaybackException) {
            final ExoPlaybackException exoError = (ExoPlaybackException)error;
            switch (exoError.type) {
            case ExoPlaybackException.TYPE_SOURCE:
                Log.e(TAG, "TYPE_SOURCE: " + exoError.getSourceException().getMessage());
                break;

            case ExoPlaybackException.TYPE_RENDERER:
                Log.e(TAG, "TYPE_RENDERER: " + exoError.getRendererException().getMessage());
                break;

            case ExoPlaybackException.TYPE_UNEXPECTED:
                Log.e(TAG, "TYPE_UNEXPECTED: " + exoError.getUnexpectedException().getMessage());
                break;

            default:
                Log.e(TAG, "default ExoPlaybackException: " + exoError.getUnexpectedException().getMessage());
            }
            // TODO: send both errorCode and type
            sendError(exoError.type, exoError.getMessage(), mapOf("index", currentIndex));
        } else {
            Log.e(TAG, "default PlaybackException: " + error.getMessage());
            sendError(error.errorCode, error.getMessage(), mapOf("index", currentIndex));
        }
    }

    private void completeSeek() {
        seekPos = null;
        seekResult.success(new HashMap<String, Object>());
        seekResult = null;
    }

    @Override
    public void onMethodCall(final MethodCall call, final Result result) {
        ensurePlayerInitialized();

        try {
            switch (call.method) {
            case "load":
                Long initialPosition = getLong(call.argument("initialPosition"));
                Integer initialIndex = call.argument("initialIndex");
                Map<?, ?> audioSourceMap = call.argument("audioSource");
                MediaSource[] children = getAudioSourcesArray(audioSourceMap.get("children"));
                ShuffleOrder shuffleOrder = decodeShuffleOrder(mapGet(audioSourceMap, "shuffleOrder"));
                load(Arrays.asList(children), shuffleOrder,
                        initialPosition == null ? C.TIME_UNSET : initialPosition / 1000,
                        initialIndex, result);
                break;
            case "play":
                play(result);
                break;
            case "pause":
                pause();
                result.success(new HashMap<String, Object>());
                break;
            case "setVolume":
                setVolume((float) ((double) ((Double) call.argument("volume"))));
                result.success(new HashMap<String, Object>());
                break;
            case "setForceWillPauseWhenDucked":
                // MD3Music fork: 三模式「保持播放与音量」时把 duck 事件转为 pause 语义，
                // 由 Dart 侧对抗自动 pause，保持音量不变。
                Boolean force = (Boolean) call.argument("force");
                android.util.Log.i("AudioFocusFork", "setForcedWillPauseWhenDucked=" + force);
                AudioFocusManager.setForcedWillPauseWhenDucked(force);
                result.success(new HashMap<String, Object>());
                break;
            case "setIgnoreAudioFocus":
                // MD3Music fork: 「允许与其他应用同时播放音频」——跳过 Media3 内置
                // 焦点处理（不 duck/不暂停/不 abandon），播放与音量完全保持。
                Boolean ignore = (Boolean) call.argument("ignore");
                android.util.Log.i("AudioFocusFork", "setIgnoreAudioFocus=" + ignore);
                AudioFocusManager.setIgnoreAudioFocus(ignore);
                result.success(new HashMap<String, Object>());
                break;
            case "setForceKeepPlaying":
                // MD3Music fork: 「保持播放与音量」模式——同样跳过 Media3 内置焦点
                // 处理（不 duck/不暂停），播放与进度完全保持。
                Boolean keepPlaying = (Boolean) call.argument("keepPlaying");
                android.util.Log.i("AudioFocusFork", "setForceKeepPlaying=" + keepPlaying);
                AudioFocusManager.setForceKeepPlaying(keepPlaying);
                result.success(new HashMap<String, Object>());
                break;
            case "getSourceFormat":
                result.success(getSourceFormat());
                break;
            case "getTransferStats": {
                Map<String, Object> s = new HashMap<>();
                s.put("totalBytes", transferredBytes);
                s.put("positionMs", player.getCurrentPosition());
                result.success(s);
                break;
            }
            case "setSpeed":
                setSpeed((float) ((double) ((Double) call.argument("speed"))));
                result.success(new HashMap<String, Object>());
                break;
            case "setPitch":
                setPitch((float) ((double) ((Double) call.argument("pitch"))));
                result.success(new HashMap<String, Object>());
                break;
            case "setSkipSilence":
                setSkipSilenceEnabled((Boolean) call.argument("enabled"));
                result.success(new HashMap<String, Object>());
                break;
            case "setLoopMode":
                setLoopMode((Integer) call.argument("loopMode"));
                result.success(new HashMap<String, Object>());
                break;
            case "setShuffleMode":
                setShuffleModeEnabled((Integer) call.argument("shuffleMode") == 1);
                result.success(new HashMap<String, Object>());
                break;
            case "setShuffleOrder":
                setShuffleOrder(call.argument("audioSource"));
                result.success(new HashMap<String, Object>());
                break;
            case "setAutomaticallyWaitsToMinimizeStalling":
                result.success(new HashMap<String, Object>());
                break;
            case "setCanUseNetworkResourcesForLiveStreamingWhilePaused":
                result.success(new HashMap<String, Object>());
                break;
            case "setPreferredPeakBitRate":
                result.success(new HashMap<String, Object>());
                break;
            case "seek":
                Long position = getLong(call.argument("position"));
                Integer index = call.argument("index");
                seek(position == null ? C.TIME_UNSET : position / 1000, index, result);
                break;
            case "concatenatingInsertAll":
                if (((String)call.argument("id")).length() == 0) {
                    player.addMediaSources(call.argument("index"), getAudioSources(call.argument("children"))); 
                    player.setShuffleOrder(decodeShuffleOrder(call.argument("shuffleOrder")));
                    result.success(new HashMap<String, Object>());
                } else {
                    concatenating(call.argument("id"))
                        .addMediaSources(call.argument("index"), getAudioSources(call.argument("children")), handler, () -> result.success(new HashMap<String, Object>()));
                    concatenating(call.argument("id"))
                        .setShuffleOrder(decodeShuffleOrder(call.argument("shuffleOrder")));
                }
                break;
            case "concatenatingRemoveRange":
                if (((String)call.argument("id")).length() == 0) {
                    player.removeMediaItems(call.argument("startIndex"), call.argument("endIndex"));
                    player.setShuffleOrder(decodeShuffleOrder(call.argument("shuffleOrder")));
                    result.success(new HashMap<String, Object>());
                } else {
                    concatenating(call.argument("id"))
                        .removeMediaSourceRange(call.argument("startIndex"), call.argument("endIndex"), handler, () -> result.success(new HashMap<String, Object>()));
                    concatenating(call.argument("id"))
                        .setShuffleOrder(decodeShuffleOrder(call.argument("shuffleOrder")));
                }
                break;
            case "concatenatingMove":
                if (((String)call.argument("id")).length() == 0) {
                    player.moveMediaItem(call.argument("currentIndex"), call.argument("newIndex"));
                    player.setShuffleOrder(decodeShuffleOrder(call.argument("shuffleOrder")));
                    result.success(new HashMap<String, Object>());
                } else {
                    concatenating(call.argument("id"))
                        .moveMediaSource(call.argument("currentIndex"), call.argument("newIndex"), handler, () -> result.success(new HashMap<String, Object>()));
                    concatenating(call.argument("id"))
                        .setShuffleOrder(decodeShuffleOrder(call.argument("shuffleOrder")));
                }
                break;
            case "setAndroidAudioAttributes":
                setAudioAttributes(call.argument("contentType"), call.argument("flags"), call.argument("usage"));
                result.success(new HashMap<String, Object>());
                break;
            case "audioEffectSetEnabled":
                audioEffectSetEnabled(call.argument("type"), call.argument("enabled"));
                result.success(new HashMap<String, Object>());
                break;
            case "androidLoudnessEnhancerSetTargetGain":
                loudnessEnhancerSetTargetGain(call.argument("targetGain"));
                result.success(new HashMap<String, Object>());
                break;
            case "androidEqualizerGetParameters":
                result.success(equalizerAudioEffectGetParameters());
                break;
            case "androidEqualizerBandSetGain":
                equalizerBandSetGain(call.argument("bandIndex"), call.argument("gain"));
                result.success(new HashMap<String, Object>());
                break;
            default:
                result.notImplemented();
                break;
            }
        } catch (IllegalStateException e) {
            e.printStackTrace();
            result.error("Illegal state: " + e.getMessage(), e.toString(), null);
        } catch (Exception e) {
            e.printStackTrace();
            result.error("Error: " + e, e.toString(), null);
        } finally {
            broadcastPendingPlaybackEvent();
        }
    }

    private ShuffleOrder decodeShuffleOrder(List<Integer> indexList) {
        int[] shuffleIndices = new int[indexList.size()];
        for (int i = 0; i < shuffleIndices.length; i++) {
            shuffleIndices[i] = indexList.get(i);
        }
        return new DefaultShuffleOrder(shuffleIndices, random.nextLong());
    }

    @SuppressWarnings("deprecation")
    private androidx.media3.exoplayer.source.ConcatenatingMediaSource concatenating(final Object index) {
        return (androidx.media3.exoplayer.source.ConcatenatingMediaSource)mediaSources.get((String)index);
    }

    @SuppressWarnings("deprecation")
    private void setShuffleOrder(final Object json) {
        Map<?, ?> map = (Map<?, ?>)json;
        String id = mapGet(map, "id");
        MediaSource mediaSource = mediaSources.get(id);
        if (mediaSource == null) return;
        switch ((String)mapGet(map, "type")) {
        case "concatenating":
            androidx.media3.exoplayer.source.ConcatenatingMediaSource concatenatingMediaSource = (androidx.media3.exoplayer.source.ConcatenatingMediaSource)mediaSource;
            concatenatingMediaSource.setShuffleOrder(decodeShuffleOrder(mapGet(map, "shuffleOrder")));
            List<Object> children = mapGet(map, "children");
            for (Object child : children) {
                setShuffleOrder(child);
            }
            break;
        case "looping":
            setShuffleOrder(mapGet(map, "child"));
            break;
        }
    }

    private MediaSource getAudioSource(final Object json) {
        Map<?, ?> map = (Map<?, ?>)json;
        String id = (String)map.get("id");
        MediaSource mediaSource = mediaSources.get(id);
        if (mediaSource == null) {
            mediaSource = decodeAudioSource(map);
            mediaSources.put(id, mediaSource);
        }
        return mediaSource;
    }

    private DefaultExtractorsFactory buildExtractorsFactory(Map<?, ?> options) {
        DefaultExtractorsFactory extractorsFactory = new DefaultExtractorsFactory();
        boolean constantBitrateSeekingEnabled = true;
        boolean constantBitrateSeekingAlwaysEnabled = false;
        int mp3Flags = 0;
        if (options != null) {
            Map<?, ?> androidExtractorOptions = (Map<?, ?>)options.get("androidExtractorOptions");
            if (androidExtractorOptions != null) {
                constantBitrateSeekingEnabled = (Boolean)androidExtractorOptions.get("constantBitrateSeekingEnabled");
                constantBitrateSeekingAlwaysEnabled = (Boolean)androidExtractorOptions.get("constantBitrateSeekingAlwaysEnabled");
                mp3Flags = (Integer)androidExtractorOptions.get("mp3Flags");
            }
        }
        extractorsFactory.setConstantBitrateSeekingEnabled(constantBitrateSeekingEnabled);
        extractorsFactory.setConstantBitrateSeekingAlwaysEnabled(constantBitrateSeekingAlwaysEnabled);
        extractorsFactory.setMp3ExtractorFlags(mp3Flags);
        return extractorsFactory;
    }

    @SuppressWarnings("deprecation")
    private MediaSource decodeAudioSource(final Object json) {
        Map<?, ?> map = (Map<?, ?>)json;
        String id = (String)map.get("id");
        switch ((String)map.get("type")) {
        case "progressive":
            MediaItem.Builder mediaItemBuilder = new MediaItem.Builder()
                    .setUri(Uri.parse((String)map.get("uri")))
                    .setTag(id);
            // MD3Music fork：把 AudioSource.uri tag 里的 title/artist/album/artUri
            // 映射进 MediaItem.mediaMetadata（原实现只 setTag(id)，mediaMetadata 为空），
            // 使媒体会话（Lyricon autoSync / SystemUI 通知栏）能读到封面 artUri。
            applyPlayerTag(mediaItemBuilder, map.get("tag"));
            return new ProgressiveMediaSource.Factory(buildDataSourceFactory(mapGet(map, "headers")), buildExtractorsFactory(mapGet(map, "options")))
                    .createMediaSource(mediaItemBuilder.build());
        case "dash":
            MediaItem.Builder dashItemBuilder = new MediaItem.Builder()
                    .setUri(Uri.parse((String)map.get("uri")))
                    .setMimeType(MimeTypes.APPLICATION_MPD)
                    .setTag(id);
            applyPlayerTag(dashItemBuilder, map.get("tag"));
            return new DashMediaSource.Factory(buildDataSourceFactory(mapGet(map, "headers")))
                    .createMediaSource(dashItemBuilder.build());
        case "hls":
            MediaItem.Builder hlsItemBuilder = new MediaItem.Builder()
                    .setUri(Uri.parse((String)map.get("uri")))
                    .setMimeType(MimeTypes.APPLICATION_M3U8)
                    .setTag(id);
            applyPlayerTag(hlsItemBuilder, map.get("tag"));
            return new HlsMediaSource.Factory(buildDataSourceFactory(mapGet(map, "headers")))
                    .createMediaSource(hlsItemBuilder.build());
        case "silence":
            return new SilenceMediaSource.Factory()
                    .setDurationUs(getLong(map.get("duration")))
                    .setTag(id)
                    .createMediaSource();
        case "concatenating":
            return new androidx.media3.exoplayer.source.ConcatenatingMediaSource(
                    false, // isAtomic
                    (Boolean)map.get("useLazyPreparation"),
                    decodeShuffleOrder(mapGet(map, "shuffleOrder")),
                    getAudioSourcesArray(map.get("children")));
        case "clipping":
            Long start = getLong(map.get("start"));
            Long end = getLong(map.get("end"));
            return new ClippingMediaSource(getAudioSource(map.get("child")),
                    start != null ? start : 0,
                    end != null ? end : C.TIME_END_OF_SOURCE);
        case "looping":
            Integer count = (Integer)map.get("count");
            MediaSource looperChild = getAudioSource(map.get("child"));
            MediaSource[] looperChildren = new MediaSource[count];
            for (int i = 0; i < looperChildren.length; i++) {
                looperChildren[i] = looperChild;
            }
            return new androidx.media3.exoplayer.source.ConcatenatingMediaSource(looperChildren);
        default:
            throw new IllegalArgumentException("Unknown AudioSource type: " + map.get("type"));
        }
    }

    private static void applyPlayerTag(MediaItem.Builder builder, Object tagObj) {
        if (!(tagObj instanceof Map<?, ?>)) return;
        Map<?, ?> tagMap = (Map<?, ?>)tagObj;
        // just_audio 顶层 map.id 是 AudioSource 的内部实例 ID，不是歌曲 ID。
        // 播放器传入的稳定 Song.id 位于 tag.id。
        String tagMediaId = (String)tagMap.get("id");
        if (tagMediaId != null && !tagMediaId.isEmpty()) {
            builder.setMediaId(tagMediaId);
        }
        MediaMetadata.Builder metadata = new MediaMetadata.Builder();
        String title = (String)tagMap.get("title");
        if (title != null && !title.isEmpty()) metadata.setTitle(title);
        String artist = (String)tagMap.get("artist");
        if (artist != null && !artist.isEmpty()) metadata.setArtist(artist);
        String album = (String)tagMap.get("album");
        if (album != null && !album.isEmpty()) metadata.setAlbumTitle(album);
        builder.setMediaMetadata(metadata.build());
    }

    private MediaSource[] getAudioSourcesArray(final Object json) {
        List<MediaSource> mediaSources = getAudioSources(json);
        MediaSource[] mediaSourcesArray = new MediaSource[mediaSources.size()];
        mediaSources.toArray(mediaSourcesArray);
        return mediaSourcesArray;
    }

    private List<MediaSource> getAudioSources(final Object json) {
        if (!(json instanceof List)) throw new RuntimeException("List expected: " + json);
        List<?> audioSources = (List<?>)json;
        List<MediaSource> mediaSources = new ArrayList<MediaSource>();
        for (int i = 0 ; i < audioSources.size(); i++) {
            mediaSources.add(getAudioSource(audioSources.get(i)));
        }
        return mediaSources;
    }

    private AudioEffect decodeAudioEffect(final Object json, int audioSessionId) {
        Map<?, ?> map = (Map<?, ?>)json;
        String type = (String)map.get("type");
        switch (type) {
        case "AndroidLoudnessEnhancer":
            if (Build.VERSION.SDK_INT < 19)
                throw new RuntimeException("AndroidLoudnessEnhancer requires minSdkVersion >= 19");
            int targetGain = (int)Math.round((((Double)map.get("targetGain")) * 100.0)); // target gain needs to be provided in milliBel, the user provides the value in deciBel
            LoudnessEnhancer loudnessEnhancer = new LoudnessEnhancer(audioSessionId);
            loudnessEnhancer.setTargetGain(targetGain);
            return loudnessEnhancer;
        case "AndroidEqualizer":
            Equalizer equalizer = new Equalizer(0, audioSessionId);
            return equalizer;
        default:
            throw new IllegalArgumentException("Unknown AudioEffect type: " + map.get("type"));
        }
    }

    private void clearAudioEffects() {
        for (Iterator<AudioEffect> it = audioEffects.iterator(); it.hasNext();) {
            AudioEffect audioEffect = it.next();
            audioEffect.release();
            it.remove();
        }
        audioEffectsMap.clear();
    }

    private DataSource.Factory buildDataSourceFactory(Map<?, ?> headers) {
        final Map<String, String> stringHeaders = castToStringMap(headers);
        String userAgent = null;
        if (stringHeaders != null) {
            userAgent = stringHeaders.remove("User-Agent");
            if (userAgent == null) {
                userAgent = stringHeaders.remove("user-agent");
            }
        }
        if (userAgent == null) {
            userAgent = Util.getUserAgent(context, "just_audio");
        }
        DefaultHttpDataSource.Factory httpDataSourceFactory = new DefaultHttpDataSource.Factory()
            .setUserAgent(userAgent)
            .setAllowCrossProtocolRedirects(true)
            .setTransferListener(transferListener);
        if (stringHeaders != null && stringHeaders.size() > 0) {
            httpDataSourceFactory.setDefaultRequestProperties(stringHeaders);
        }
        return new DefaultDataSource.Factory(context, httpDataSourceFactory);
    }

    private void load(final List<MediaSource> mediaSources, ShuffleOrder shuffleOrder, final long initialPosition, final Integer initialIndex, final Result result) {
        currentIndex = initialIndex != null ? initialIndex : 0;
        transferredBytes = 0;  // 换歌重置传输统计（歌曲信息页实时码率）
        switch (processingState) {
        case idle:
            break;
        case loading:
            abortExistingConnection(false);
            player.stop();
            break;
        default:
            player.stop();
            break;
        }
        prepareResult = result;
        updatePosition();
        processingState = ProcessingState.loading;
        errorCode = null;
        errorMessage = null;
        enqueuePlaybackEvent();
        int windowIndex = initialIndex != null ? initialIndex : 0;
        player.setMediaSources(mediaSources, windowIndex, initialPosition);
        player.setShuffleOrder(shuffleOrder);
        player.prepare();
    }

    private void ensurePlayerInitialized() {
        if (player == null) {
            // MD3Music fork: 子类化 DefaultRenderersFactory 并 override buildAudioSink()，
            // 注入 USB 独占输出拦截层（UsbAudioSinkController.wrap）。
            // 包装器始终存在（未开启独占时完全透传），因此运行时开关无需重建 ExoPlayer。
            // 注意：本机 Media3 为 1.4.1，buildAudioSink 签名只有 3 个参数（无 enableOffload）。
            DefaultRenderersFactory drf = new DefaultRenderersFactory(context) {
                @Override
                public AudioSink buildAudioSink(
                        Context ctx, boolean enableFloatOutput, boolean enableAudioTrackPlaybackParams) {
                    AudioSink defaultSink = super.buildAudioSink(
                            ctx, enableFloatOutput, enableAudioTrackPlaybackParams);
                    return UsbAudioSinkController.wrap(defaultSink, ctx);
                }
            };
            // MD3Music fork: float 输出曾用于让 24/32bit 高规格音频走高解析，
            // 但实测部分设备 stereo float 播放异常（速度加快/音高变高）。
            // 结论：统一关闭 float 输出，由 ExoPlayer 默认把 24/32bit 整数 PCM 降为 16bit
            // （ToInt16PcmAudioProcessor），任何设备都能正确播放。
            drf.setEnableAudioFloatOutput(false);
            RenderersFactory renderersFactory = (eventHandler, videoListener, audioListener, textOutput, metadataOutput) -> {
                Renderer[] defaultRenderers = drf.createRenderers(
                        eventHandler, videoListener, audioListener, textOutput, metadataOutput);
                Renderer[] allRenderers = Arrays.copyOf(defaultRenderers, defaultRenderers.length + 1);
                allRenderers[defaultRenderers.length] = new ObserverRenderer();
                return allRenderers;
            };
            ExoPlayer.Builder builder = new ExoPlayer.Builder(context, renderersFactory);
            builder.setUseLazyPreparation(useLazyPreparation);
            if (loadControl != null) {
                builder.setLoadControl(loadControl);
            }
            if (livePlaybackSpeedControl != null) {
                builder.setLivePlaybackSpeedControl(livePlaybackSpeedControl);
            }
            player = builder.build();
            // MD3Music fork: 固定 audioSessionId，使 Media3 MediaSession 与 AudioTrack
            // 关联。系统（小米等）按「AudioTrack 的 audioSessionId 是否与 MediaSession
            // 关联」判定播放器可识别性（hasUid）：未关联时独占型中断（如 B 站视频
            // GAIN）会对本播放器强制 interruptMusicPlayback 直接暂停，忽略开关与
            // 三模式均无法阻止。固定 id 须在 AudioTrack 创建前设置（此时尚未播放），
            // MediaSession（下方创建）自动同步该 id 到系统。
            try {
                AudioManager am = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
                if (am != null && android.os.Build.VERSION.SDK_INT >= 21) {
                    player.setAudioSessionId(am.generateAudioSessionId());
                }
            } catch (Exception e) {
                android.util.Log.w("AudioFocusFork", "setAudioSessionId failed: " + e);
            }
            player.setTrackSelectionParameters(
                player.getTrackSelectionParameters()
                    .buildUpon()
                    .setAudioOffloadPreferences(audioOffloadPreferences)
                    .build()
            );
            setAudioSessionId(player.getAudioSessionId());
            player.addListener(this);
            // MD3Music fork（阶段6·收敛单一会话）：登记本实例，供跨实例释放非活跃会话
            registerPlayer(this);
            // MD3Music fork: 创建 Media3 MediaSession 关联 ExoPlayer。
            // 小米等系统按「播放器是否关联 MediaSession」判定是否自动 duck
            // （hasUid=false → 系统绕过 app 直接 VolumeShaper duck，三模式收不到事件）。
            // 关联后系统识别播放器、不自动 duck，焦点事件正常进入 AudioFocusManager。
            // 焦点仍由 ExoPlayer 的 AudioFocusManager 管理（handleAudioFocus=true），
            // MediaSession 仅作关联标识（不请求焦点、不绑定通知栏）。
            // MD3Music fork（方向1）：createMediaSession=false（headless 播放器）或进程级
            // 媒体会话开关关闭时，整体跳过建会话，使系统只暴露前台 UI 播放器的一个媒体会话，
            // 杜绝跨引擎播放/暂停不同步。
            if (createMediaSession && sMediaSessionEnabled) {
                buildAndHostMediaSession();
            }
        }
    }

    /// MD3Music fork（方向1）：构建并接线媒体3会话（ID / sessionActivity / 自定义命令 callback），
    /// 归入 host 服务，并把本实例设为活跃播放器。仅在 createMediaSession==true 时由
    /// ensurePlayerInitialized 调用；headless 播放器不建会话，保持 mediaSession=null。
    private void buildAndHostMediaSession() {
        MediaSession.Builder sessionBuilder = new MediaSession.Builder(context, player);
            // MD3Music fork（阶段6修复）：点击媒体3 now-playing 通知卡片回到 App。
            // 用 App 的 launch intent 作为 sessionActivity，使通知 contentIntent 有效。
            try {
                android.content.Intent launch =
                        context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
                if (launch != null) {
                    android.app.PendingIntent activityIntent = android.app.PendingIntent.getActivity(
                            context, 0, launch,
                            android.app.PendingIntent.FLAG_UPDATE_CURRENT
                                    | android.app.PendingIntent.FLAG_IMMUTABLE);
                    sessionBuilder.setSessionActivity(activityIntent);
                }
            } catch (Exception e) {
                Log.w("AudioFocusFork", "setSessionActivity failed: " + e);
            }
            // MD3Music fork: 用唯一会话 ID，避免默认空串被 SESSION_ID_TO_SESSION_MAP 判重冲突
            sessionBuilder.setId(sessionId);
            // MD3Music fork: 处理媒体3自定义命令（阶段4，自研交互迁往媒体3）。
            // 通知栏自定义按钮（桌面歌词/收藏）经 onCustomCommand 到达，转发给 App 处理。
            sessionBuilder.setCallback(new MediaSession.Callback() {
                @Override
                public MediaSession.ConnectionResult onConnect(
                        MediaSession session, MediaSession.ControllerInfo controller) {
                    // MD3Music fork: 让自定义命令（桌面歌词/收藏）对所有 controller 可用，
                    // 否则内部媒体通知 controller 的 customLayout 会把它们过滤成禁用/移除，
                    // 通知栏自定义按钮无法渲染（阶段4）。
                    MediaSession.ConnectionResult.AcceptedResultBuilder builder =
                            new MediaSession.ConnectionResult.AcceptedResultBuilder(session);
                    androidx.media3.session.SessionCommands.Builder cmdBuilder =
                            new androidx.media3.session.SessionCommands.Builder();
                    cmdBuilder.add(CMD_TOGGLE_DESKTOP_LYRIC);
                    cmdBuilder.add(CMD_TOGGLE_FAVORITE);
                    cmdBuilder.add(CMD_TOGGLE_TRANSLATION);
                    builder.setAvailableSessionCommands(cmdBuilder.build());
                    return builder.build();
                }
                // MD3Music fork（阶段6·修复媒体卡片上一首/下一首）：
                // App 队列为自维护（不走 media3 时间线），原生 seekToNext/seekToPrevious
                // 直接驱动 ExoPlayer 时间线会与 App 队列脱节（上一首变成「从头重播」当前曲）。
                // 这里拦截原生 PREVIOUS/NEXT 命令，转发给 App 的上一首/下一首逻辑，
                // 并返回 RESULT_INFO_SKIPPED 阻止 media3 默认 seek（info 级非 error，SystemUI 静默）。
                @Override
                public @SessionResult.Code int onPlayerCommandRequest(
                        MediaSession session, MediaSession.ControllerInfo controller,
                        @Player.Command int playerCommand) {
                    final CustomActionListener listener = sCustomActionListener;
                    if (listener == null) {
                        // 默认实现即返回 RESULT_SUCCESS，此处直接返回等价
                        return SessionResult.RESULT_SUCCESS;
                    }
                    switch (playerCommand) {
                        case Player.COMMAND_SEEK_TO_NEXT:
                        case Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM:
                            Log.i("AudioFocusFork", "onPlayerCommandRequest SEEK_TO_NEXT -> App next");
                            listener.onNext();
                            return SessionResult.RESULT_INFO_SKIPPED;
                        case Player.COMMAND_SEEK_TO_PREVIOUS:
                        case Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM:
                            Log.i("AudioFocusFork", "onPlayerCommandRequest SEEK_TO_PREVIOUS -> App previous");
                            listener.onPrevious();
                            return SessionResult.RESULT_INFO_SKIPPED;
                        default:
                            // 默认实现即返回 RESULT_SUCCESS，此处直接返回等价
                            return SessionResult.RESULT_SUCCESS;
                    }
                }
                @Override
                public ListenableFuture<SessionResult> onCustomCommand(
                        MediaSession session, final MediaSession.ControllerInfo controller,
                        SessionCommand customCommand, android.os.Bundle args) {
                    final CustomActionListener listener = sCustomActionListener;
                    if (customCommand != null && listener != null) {
                        String action = customCommand.customAction;
                        if (CMD_TOGGLE_DESKTOP_LYRIC.customAction.equals(action)) {
                            listener.onToggleDesktopLyric();
                        } else if (CMD_TOGGLE_FAVORITE.customAction.equals(action)) {
                            listener.onToggleFavorite();
                        }
                    }
                    return Futures.immediateFuture(new SessionResult(SessionResult.RESULT_SUCCESS));
                }
            });
            mediaSession = sessionBuilder.build();
            // MD3Music fork: 记录活跃播放器，供 AudioPlaybackService 注入封面到媒体3会话
            sActivePlayer = this;
            // MD3Music fork: 若已注册 MediaSessionService host，把本会话归入服务以渲染 now playing 通知
            ensureSessionHosted();
    }

    // MD3Music fork: 关联系统的 MediaSession（见 ensurePlayerInitialized）
    private MediaSession mediaSession;

    // MD3Music fork（方向1）：是否创建媒体3会话。后台 headless 引擎播放器为 false → 不建会话
    private final boolean createMediaSession;

    // MD3Music fork（方向1）：进程级「媒体3会话总开关」。headless 引擎创建时由原生置 false，
    // 前台 UI 引擎置 true；配合 createMediaSession 双条件，确保系统只暴露前台 UI 播放器的一个会话。
    private static volatile boolean sMediaSessionEnabled = true;

    /// 由 App 设置：headless 引擎传 false（禁用媒体会话），前台 UI 引擎传 true。
    public static void setMediaSessionEnabled(boolean enabled) {
        sMediaSessionEnabled = enabled;
    }

    // MD3Music fork: 媒体3会话唯一 ID（构造时生成）与全局递增计数器（避免 SESSION_ID 判重冲突）
    private final String sessionId;
    private static final java.util.concurrent.atomic.AtomicInteger SESSION_ID_COUNTER =
            new java.util.concurrent.atomic.AtomicInteger(0);

    // ==== MD3Music fork: 运行时给媒体3会话注入封面/元数据 ====
    // 媒体3 会话自身无元数据，播放中会被 SystemUI 提为控制中心顶层 → 无封面/无标题。
    // 这里用官方正规 API `Player.replaceMediaItem(index, newItem)`（同 uri 仅更新 metadata、
    // 不打断播放），把 App 下载好的封面+标题写进当前 MediaItem，供 AudioPlaybackService 调用。
    private static volatile AudioPlayer sActivePlayer;

    // ==== MD3Music fork: 媒体3会话归属 MediaSessionService（渲染 now playing 通知） ====
    // 原生 App 的 MD3MusicMediaSessionService 创建后注册为本 host；fork 自建的媒体3
    // 会话随后加入该服务，由 media3 的 MediaNotificationManager + DefaultMediaNotificationProvider
    // 生成系统 now playing 通知（阶段1「媒体3 通知栏上线」）。
    private static volatile MediaSessionService sSessionHost;

    /// 由 App 的 MediaSessionService 在 onCreate 注册 / onDestroy 注销。
    /// 注册时若有已创建的会话立即补入（服务晚于会话创建的情况）。
    // MD3Music fork（阶段6·收敛单一会话）：进程内所有 AudioPlayer 实例清单，
    // 用于确保任意时刻只保留「当前活跃播放器」的一个媒体3会话，其余实例的会话被释放，
    // 杜绝 SystemUI 在多个 media3 会话间竞争顶层导致「卡片不更新/标题封面丢失」。
    private static final java.util.List<AudioPlayer> sPlayers =
            java.util.Collections.synchronizedList(new java.util.ArrayList<AudioPlayer>());

    private static void registerPlayer(AudioPlayer p) {
        synchronized (sPlayers) { if (!sPlayers.contains(p)) sPlayers.add(p); }
    }

    private static void unregisterPlayer(AudioPlayer p) {
        synchronized (sPlayers) { sPlayers.remove(p); }
    }

    /// 由 App 的 MediaSessionService 在 onCreate 注册 / onDestroy 注销。
    /// 注册时若有已创建的会话立即补入（服务晚于会话创建的情况）。
    public static void setMediaSessionServiceHost(MediaSessionService host) {
        sSessionHost = host;
        ensureActiveSessionHosted();
    }

    /// 供 MediaSessionService.onGetSession 返回当前活跃（或任一）媒体3会话。
    public static MediaSession getActiveMediaSession() {
        AudioPlayer p = sActivePlayer;
        return p != null ? p.mediaSession : null;
    }

    /// 幂等地把活跃会话加入已注册的 host（重复加入会抛 IllegalArgumentException）。
    /// MD3Music fork（方向1·安全收敛）：再把「非活跃播放器」的会话从 host 移除（不 release
    /// 播放器、不置 null），使系统仅暴露当前活跃播放器的一个会话。调用方保证 sActivePlayer
    /// 是真正在播放的播放器（play/ensurePlayerInitialized 后），避免误移除。
    private static void ensureActiveSessionHosted() {
        AudioPlayer p = sActivePlayer;
        MediaSessionService host = sSessionHost;
        if (host == null || p == null || p.mediaSession == null) return;
        try {
            if (!host.isSessionAdded(p.mediaSession)) {
                host.addSession(p.mediaSession);
            }
        } catch (Exception e) {
            Log.w("AudioFocusFork", "ensureActiveSessionHosted addSession failed: " + e);
        }
        // 移除其他实例的会话（仅 remove，不 release）：系统卡片/媒体键只跟随活跃会话
        synchronized (sPlayers) {
            for (AudioPlayer other : sPlayers) {
                if (other == null || other == p) continue;
                MediaSession ms = other.mediaSession;
                if (ms == null) continue;
                try {
                    if (host.isSessionAdded(ms)) host.removeSession(ms);
                    // MD3Music fork：彻底 release 非活跃会话，从系统 Sessions Stack 注销，
                    // 使 SystemUI/媒体卡片只跟随当前活跃播放器的一个会话（避免旧歌会话
                    // 干扰导致封面不更新/显示旧歌）。
                    try { ms.release(); } catch (Exception ignore) {}
                    other.mediaSession = null;
                } catch (Exception ignore) {}
            }
        }
    }

    /// MD3Music fork（方向1）：play() 权威收敛点。把本实例会话设为唯一 host 会话，
    /// 其余实例的会话仅从 host 移除（不 release 播放器/会话对象），使系统只跟随本播放器。
    /// 由 play() 在 sActivePlayer=this 之后调用。
    private void syncSingleSessionToHost() {
        MediaSessionService host = sSessionHost;
        if (host == null || mediaSession == null) return;
        try {
            if (!host.isSessionAdded(mediaSession)) host.addSession(mediaSession);
        } catch (Exception e) {
            Log.w("AudioFocusFork", "syncSingleSessionToHost addSession failed: " + e);
        }
        synchronized (sPlayers) {
            for (AudioPlayer other : sPlayers) {
                if (other == null || other == this) continue;
                MediaSession ms = other.mediaSession;
                if (ms == null) continue;
                try {
                    if (host.isSessionAdded(ms)) host.removeSession(ms);
                    // MD3Music fork：play() 收敛时同样彻底 release 非活跃会话，从系统
                    // Sessions Stack 注销，避免跨fade 角色互换后多个 md3music 会话残留在
                    // 系统栈里干扰 SystemUI/媒体卡片（显示旧歌封面）。该播放器下次 play()
                    // 时会按 createMediaSession 重建会话（见 play()）。
                    try { ms.release(); } catch (Exception ignore) {}
                    other.mediaSession = null;
                } catch (Exception ignore) {}
            }
        }
    }

    /// 实例方法：会话创建后调用，把当前播放器加入 host（若已注册）。
    /// MD3Music fork（方向1）：仅当本实例是「活跃播放器」时才把会话加入 host；
    /// 非活跃播放器不加入（且确保其已被 host 移除），保证系统只暴露活跃播放器的一个会话。
    private void ensureSessionHosted() {
        if (this == sActivePlayer) {
            ensureActiveSessionHosted();
        } else {
            // 非活跃：确保从 host 移除，避免重新加入造成多会话
            MediaSessionService host = sSessionHost;
            if (host != null && mediaSession != null) {
                try { if (host.isSessionAdded(mediaSession)) host.removeSession(mediaSession); }
                catch (Exception ignore) {}
            }
        }
    }

    /// 由 AudioPlaybackService 封面加载成功后调用（同进程），把封面/标题注入媒体3会话。
    public static void updateActiveSessionMetadata(
            String expectedMediaId,
            long generation,
            String title,
            String artist,
            Bitmap art,
            String artUri) {
        AudioPlayer p = sActivePlayer;
        if (p != null) {
            p.applySessionMetadata(
                    expectedMediaId, generation, title, artist, art, artUri);
        } else {
            Log.w("AudioFocusFork", "updateActiveSessionMetadata: no active AudioPlayer");
        }
    }

    /// 仅更新媒体3会话稳定标题/艺术家（不重压缩封面）。
    public static void updateActiveSessionTitleArtist(
            String expectedMediaId, long generation, String title, String artist) {
        AudioPlayer p = sActivePlayer;
        if (p != null) {
            p.applySessionTitleArtist(expectedMediaId, generation, title, artist);
        } else {
            Log.w("AudioFocusFork", "updateActiveSessionTitleArtist: no active AudioPlayer");
        }
    }

    /// 写媒体3 MediaItem 的 MediaMetadata（标题/艺术家/内嵌封面位图）。
    /// 位图转 JPEG 字节经 setArtworkData 下发，使其成为系统 MEDIA_KEY_ART；异常静默。
    /// ExoPlayer 必须在创建它的 Looper 线程访问，因此先派发到 player 所在线程执行。
    private void applySessionMetadata(
            final String expectedMediaId,
            final long generation,
            final String title,
            final String artist,
            final Bitmap art,
            final String artUri) {
        try {
            final androidx.media3.common.Player p = player;
            if (p == null) return;
            Handler handler = new Handler(p.getApplicationLooper());
            if (!registerExternalMetadataGeneration(generation)) return;
            handler.post(() -> doApplySessionMetadata(
                    expectedMediaId, generation, title, artist, art, artUri));
        } catch (Exception e) {
            Log.w("AudioFocusFork", "applySessionMetadata dispatch failed: " + e);
        }
    }

    /// 阶段3：仅更新媒体3会话 标题/艺术家（不重压缩封面）。
    /// ExoPlayer 必须在创建它的 Looper 线程访问，先派发到 player 所在线程执行。
    private void applySessionTitleArtist(
            final String expectedMediaId,
            final long generation,
            final String title,
            final String artist) {
        try {
            final androidx.media3.common.Player p = player;
            if (p == null) return;
            Handler handler = new Handler(p.getApplicationLooper());
            if (!registerExternalMetadataGeneration(generation)) return;
            handler.post(() ->
                    doApplySessionTitleArtist(expectedMediaId, generation, title, artist));
        } catch (Exception e) {
            Log.w("AudioFocusFork", "applySessionTitleArtist dispatch failed: " + e);
        }
    }

    /// 在 player 线程只更新 Title/Artist；与现有值相同则跳过，避免无谓的 MediaItem 替换事件。
    private void doApplySessionTitleArtist(
            String expectedMediaId, long generation, String title, String artist) {
        try {
            if (!isExternalMetadataGenerationCurrent(generation)) return;
            MediaItem cur = player.getCurrentMediaItem();
            if (cur == null) return;
            if (!matchesExpectedMediaItem(cur, expectedMediaId, title, artist)) {
                logDiscardedIdentity("title/artist", cur, expectedMediaId);
                return;
            }
            MediaMetadata m = cur.mediaMetadata;
            String curTitle = m.title != null ? m.title.toString() : null;
            String curArtist = m.artist != null ? m.artist.toString() : null;
            if (equalsOrBothNull(curTitle, title) && equalsOrBothNull(curArtist, artist)) return;
            MediaMetadata.Builder mb = m.buildUpon();
            if (title != null && !title.isEmpty()) mb.setTitle(title);
            if (artist != null && !artist.isEmpty()) mb.setArtist(artist);
            player.replaceMediaItem(
                    player.getCurrentMediaItemIndex(),
                    cur.buildUpon().setMediaMetadata(mb.build()).build());
        } catch (Exception e) {
            Log.w("AudioFocusFork", "doApplySessionTitleArtist failed: " + e);
        }
    }

    private static boolean equalsOrBothNull(String a, String b) {
        return a == null ? b == null : a.equals(b);
    }

    private synchronized boolean registerExternalMetadataGeneration(long generation) {
        if (generation <= 0) return true;
        if (generation < latestExternalMetadataGeneration) return false;
        latestExternalMetadataGeneration = generation;
        return true;
    }

    private boolean isExternalMetadataGenerationCurrent(long generation) {
        return generation <= 0 || generation == latestExternalMetadataGeneration;
    }

    private static boolean matchesExpectedMediaItem(
            MediaItem item, String expectedMediaId, String expectedTitle, String expectedArtist) {
        if (expectedMediaId == null || expectedMediaId.isEmpty()
                || expectedMediaId.equals(item.mediaId)) {
            return true;
        }
        // just_audio / ExoPlayer may retain an internal MediaItem.mediaId even when the player
        // tag carries the business Song.id. The public protocol permits title+artist fallback.
        MediaMetadata metadata = item.mediaMetadata;
        String currentTitle = metadata.title != null ? metadata.title.toString() : "";
        String currentArtist = metadata.artist != null ? metadata.artist.toString() : "";
        if (item.mediaId.isEmpty() && currentTitle.isEmpty() && currentArtist.isEmpty()) {
            // A freshly loaded just_audio MediaItem has no platform identity until this bridge
            // writes it for the first time. Generation ownership above still rejects old songs.
            return true;
        }
        return expectedTitle != null
                && !expectedTitle.isEmpty()
                && expectedTitle.equals(currentTitle)
                && (expectedArtist == null
                        || expectedArtist.isEmpty()
                        || expectedArtist.equals(currentArtist));
    }

    private static void logDiscardedIdentity(
            String role, MediaItem item, String expectedMediaId) {
        Log.i("AudioFocusFork", "Discard stale " + role
                + " expectedMediaIdHash="
                + (expectedMediaId == null ? 0 : expectedMediaId.hashCode())
                + " actualMediaIdHash="
                + (item.mediaId == null ? 0 : item.mediaId.hashCode()));
    }

    // ==== MD3Music fork: 给媒体3会话下发 LyricInfo extras（阶段3b） ====
    // 自定义会话把整首歌词 JSON 写进 MediaSession 元数据 extras.lyricInfo，供
    // ColorOS 桌面歌词 / LyricInfo 模块等第三方系统读取。这里让媒体3会话的
    // MediaItem.mediaMetadata.extras 同样携带该字段，为后续移除自定义会话做准备。
    private static final String SESSION_LYRIC_INFO_KEY = "lyricInfo";

    /// 根因3修复：一次 replaceMediaItem 同时更新 标题/艺术家 与 extras.lyricInfo，
    /// 消除 performMetadataRefresh 的两次紧邻提交（OPlus 防抖窗口会丢弃第二次，
    /// 日志表现为 "within debounce period, ignore"，导致首曲 hasLyric=false）。
    public static void updateActiveSessionTitleArtistAndLyricInfo(
            String expectedMediaId,
            long generation,
            String title,
            String artist,
            String lyricInfo) {
        AudioPlayer p = sActivePlayer;
        if (p != null) {
            p.applySessionTitleArtistAndLyricInfo(
                    expectedMediaId, generation, title, artist, lyricInfo);
        } else {
            Log.w("AudioFocusFork", "updateActiveSessionTitleArtistAndLyricInfo: no active AudioPlayer");
        }
    }

    // ==== MD3Music fork: 媒体3自定义命令（阶段4，自研 action 迁往媒体3） ====
    // 桌面歌词开关、收藏以 media3 自定义 Command 承载：App 把状态/图标推给
    // setActiveSessionCustomActions，渲染为通知栏按钮；点击经 onCustomCommand 回传 App。
    // 上一首/下一首不再用自定义按钮：改由拦截原生 seekToPrevious/seekToNext 命令
    // （onPlayerCommandRequest）转发 App 队列逻辑，见 buildAndHostMediaSession。
    public interface CustomActionListener {
        void onToggleDesktopLyric();
        void onToggleFavorite();
        // MD3Music fork（阶段6·修复媒体卡片上一首/下一首）：
        // 原生 PREVIOUS/NEXT 命令拦截后回调，走 App 自有切歌逻辑。
        void onPrevious();
        void onNext();
    }

    private static volatile CustomActionListener sCustomActionListener;
    // 用 new Bundle() 而非 Bundle.EMPTY：后者要求 API 26+，本项目 minSdk 为 24/25。
    private static final SessionCommand CMD_TOGGLE_DESKTOP_LYRIC =
            new SessionCommand("com.md3music.toggle_desktop_lyric", new android.os.Bundle());
    private static final SessionCommand CMD_TOGGLE_FAVORITE =
            new SessionCommand("com.md3music.toggle_favorite", new android.os.Bundle());
    // MD3Music fork: ColorOS-Live-Lyrics-Bridge 公开翻译切换动作（LYRIC_INFO 协议）。
    // Bridge 在 SystemUI 侧按该 action 定位 OPlus 锁屏翻译按钮并接管点击；未安装 Bridge
    // 时点击经 onCustomCommand 到达，default 分支返回 RESULT_SUCCESS 安全忽略。
    private static final SessionCommand CMD_TOGGLE_TRANSLATION =
            new SessionCommand(
                    "io.github.andrealtb.lockscreenlyrics.action.TOGGLE_TRANSLATION",
                    new android.os.Bundle());

    /// 由 App 注册，接收媒体3通知按钮触发的自定义命令。
    public static void setCustomActionListener(CustomActionListener listener) {
        sCustomActionListener = listener;
    }

    /// 由 App 在元数据/开关变化时推送媒体3通知栏的自定义按钮（图标按开/关态切换）。
    /// 阶段6：下一首已改回原生按钮，这里只保留桌面歌词/收藏两个自定义按钮。
    /// hasTranslation=true 时在自定义布局首位插入 ColorOS 翻译切换按钮（仅 Bridge
    /// 消费，播放器不处理其回调）；翻译图标缺省用模块自带（未新增 ic_translation）。
    public static void setActiveSessionCustomActions(
            boolean desktopLyricEnabled,
            boolean isFavorited,
            boolean hasTranslation,
            int translationIconResId,
            int desktopLyricOnIcon,
            int desktopLyricOffIcon,
            int favoriteOnIcon,
            int favoriteOffIcon) {
        AudioPlayer p = sActivePlayer;
        if (p != null) {
            p.applySessionCustomActions(
                    desktopLyricEnabled, isFavorited, hasTranslation, translationIconResId,
                    desktopLyricOnIcon, desktopLyricOffIcon, favoriteOnIcon, favoriteOffIcon);
        } else {
            Log.w("AudioFocusFork", "setActiveSessionCustomActions: no active AudioPlayer");
        }
    }

    private void applySessionCustomActions(
            final boolean desktopLyricEnabled,
            final boolean isFavorited,
            final boolean hasTranslation,
            final int translationIconResId,
            final int desktopLyricOnIcon,
            final int desktopLyricOffIcon,
            final int favoriteOnIcon,
            final int favoriteOffIcon) {
        try {
            final androidx.media3.common.Player p = player;
            if (p == null || mediaSession == null) return;
            Handler handler = new Handler(p.getApplicationLooper());
            handler.post(() -> {
                try {
                    // MD3Music fork（阶段6）：下一首改回 media3 原生按钮（自动渲染），
                    // 这里保留 翻译(可选)/桌面歌词/收藏 自定义按钮。翻译按钮放首位，
                    // Bridge 识别后会在 OPlus Rule0 中 promote 并接管点击。
                    java.util.List<CommandButton> layout = new java.util.ArrayList<>(3);
                    if (hasTranslation) {
                        layout.add(new CommandButton.Builder()
                                .setSessionCommand(CMD_TOGGLE_TRANSLATION)
                                .setDisplayName("歌词翻译")
                                .setIconResId(translationIconResId)
                                .setEnabled(true)
                                .build());
                    }
                    layout.add(new CommandButton.Builder()
                            .setSessionCommand(CMD_TOGGLE_DESKTOP_LYRIC)
                            .setDisplayName("桌面歌词")
                            .setIconResId(desktopLyricEnabled ? desktopLyricOnIcon : desktopLyricOffIcon)
                            .setEnabled(true)
                            .build());
                    layout.add(new CommandButton.Builder()
                            .setSessionCommand(CMD_TOGGLE_FAVORITE)
                            .setDisplayName("收藏")
                            .setIconResId(isFavorited ? favoriteOnIcon : favoriteOffIcon)
                            .setEnabled(true)
                            .build());
                    mediaSession.setCustomLayout(layout);
                    // MD3Music fork: 自定义按钮 layout 变化不会自动重渲染 now playing 通知，
                    // 需让承载服务按最新 layout 强制刷新一次（见 MediaSessionService.refreshNotification）。
                    MediaSessionService host = sSessionHost;
                    if (host != null) {
                        host.refreshNotification(mediaSession);
                    }
                } catch (Exception e) {
                    Log.w("AudioFocusFork", "applySessionCustomActions failed: " + e);
                }
            });
        } catch (Exception e) {
            Log.w("AudioFocusFork", "applySessionCustomActions dispatch failed: " + e);
        }
    }

    /// ExoPlayer 必须在创建它的 Looper 线程访问，先派发到 player 所在线程执行。
    private void applySessionTitleArtistAndLyricInfo(
            final String expectedMediaId,
            final long generation,
            final String title,
            final String artist,
            final String lyricInfo) {
        try {
            final androidx.media3.common.Player p = player;
            if (p == null) return;
            Handler handler = new Handler(p.getApplicationLooper());
            if (!registerExternalMetadataGeneration(generation)) return;
            handler.post(() -> doApplySessionTitleArtistAndLyricInfo(
                    expectedMediaId, generation, title, artist, lyricInfo));
        } catch (Exception e) {
            Log.w("AudioFocusFork", "applySessionTitleArtistAndLyricInfo dispatch failed: " + e);
        }
    }

    /// 在 player 线程一次性提交 title/artist + extras.lyricInfo。
    /// 跳过逻辑：仅当稳定 title/artist 与 lyricInfo 均未变化才 return。
    private void doApplySessionTitleArtistAndLyricInfo(
            String expectedMediaId,
            long generation,
            String title,
            String artist,
            String lyricInfo) {
        try {
            if (!isExternalMetadataGenerationCurrent(generation)) return;
            MediaItem cur = player.getCurrentMediaItem();
            if (cur == null) return;
            if (!matchesExpectedMediaItem(cur, expectedMediaId, title, artist)) {
                logDiscardedIdentity("lyricInfo", cur, expectedMediaId);
                return;
            }
            MediaMetadata m = cur.mediaMetadata;
            String curTitle = m.title != null ? m.title.toString() : null;
            String curArtist = m.artist != null ? m.artist.toString() : null;
            android.os.Bundle currentExtras = m.extras;
            String currentLyric = currentExtras != null
                    ? currentExtras.getString(SESSION_LYRIC_INFO_KEY) : null;
            String incomingLyric = (lyricInfo == null || lyricInfo.isEmpty()) ? null : lyricInfo;

            boolean titleChanged =
                    !(equalsOrBothNull(curTitle, title) && equalsOrBothNull(curArtist, artist));
            boolean lyricChanged = !((incomingLyric == null && currentLyric == null)
                    || (incomingLyric != null && incomingLyric.equals(currentLyric)));
            if (!titleChanged && !lyricChanged) return;

            MediaMetadata.Builder mb = m.buildUpon();
            if (title != null && !title.isEmpty()) mb.setTitle(title);
            if (artist != null && !artist.isEmpty()) mb.setArtist(artist);
            android.os.Bundle newExtras = currentExtras != null
                    ? new android.os.Bundle(currentExtras)
                    : new android.os.Bundle();
            if (incomingLyric == null) {
                newExtras.remove(SESSION_LYRIC_INFO_KEY);
            } else {
                newExtras.putString(SESSION_LYRIC_INFO_KEY, incomingLyric);
            }
            MediaMetadata updated = mb.setExtras(newExtras).build();
            player.replaceMediaItem(
                    player.getCurrentMediaItemIndex(),
                    cur.buildUpon().setMediaMetadata(updated).build());
            Log.d("AudioFocusFork", "doApplySessionTitleArtistAndLyricInfo OK hasLyricInfo="
                    + (incomingLyric != null)
                    + " titleChanged=" + titleChanged + " lyricChanged=" + lyricChanged);
        } catch (Exception e) {
            Log.w("AudioFocusFork", "doApplySessionTitleArtistAndLyricInfo failed: " + e);
        }
    }

    /// 在 player 所在线程执行「替换当前 MediaItem 的 MediaMetadata」。
    private void doApplySessionMetadata(
            String expectedMediaId,
            long generation,
            String title,
            String artist,
            Bitmap art,
            String artUri) {
        try {
            if (!isExternalMetadataGenerationCurrent(generation)) return;
            MediaItem cur = player.getCurrentMediaItem();
            if (cur == null) return;
            if (!matchesExpectedMediaItem(cur, expectedMediaId, title, artist)) {
                logDiscardedIdentity("artwork", cur, expectedMediaId);
                return;
            }
            int index = player.getCurrentMediaItemIndex();
            MediaMetadata.Builder mb = cur.mediaMetadata.buildUpon();
            if (title != null && !title.isEmpty()) mb.setTitle(title);
            if (artist != null && !artist.isEmpty()) mb.setArtist(artist);
            // MD3Music fork：注入 artworkUri（Lyricon autoSync / 外部读取封面用），
            // 通知栏封面仍用 artworkData（bitmap，稳定，避免 artUri 异步加载闪烁）。
            if (artUri != null && !artUri.isEmpty()) {
                mb.setArtworkUri(android.net.Uri.parse(artUri));
            }
            if (art != null) {
                // MD3Music fork：bitmap 可能已被 AudioPlaybackService.onDestroy 回收
                // （服务被拒自停重建），此时跳过封面位图，仅保留 title/artist，避免
                // "Can't compress a recycled bitmap" 异常导致整次注入失败。
                if (art.isRecycled()) {
                    Log.w("AudioFocusFork", "applySessionMetadata: art recycled, skip artwork");
                } else {
                ByteArrayOutputStream baos = new ByteArrayOutputStream();
                art.compress(Bitmap.CompressFormat.JPEG, 90, baos);
                mb.setArtworkData(baos.toByteArray(), MediaMetadata.PICTURE_TYPE_FRONT_COVER);
                }
            }
            MediaItem updated = cur.buildUpon().setMediaMetadata(mb.build()).build();
            // 官方推荐：同 uri 替换 → 只更新 metadata，不打断播放
            player.replaceMediaItem(index, updated);
            Log.d("AudioFocusFork", "applySessionMetadata OK title=" + title + " art=" + (art != null)
                    + " onMainThread=" + (Thread.currentThread() == Looper.getMainLooper().getThread()));
        } catch (Exception e) {
            Log.w("AudioFocusFork", "applySessionMetadata failed: " + e);
        }
    }

    private void setAudioAttributes(int contentType, int flags, int usage) {
        AudioAttributes.Builder builder = new AudioAttributes.Builder();
        builder.setContentType(contentType);
        builder.setFlags(flags);
        builder.setUsage(usage);
        //builder.setAllowedCapturePolicy((Integer)json.get("allowedCapturePolicy"));
        AudioAttributes audioAttributes = builder.build();
        if (processingState == ProcessingState.loading) {
            // audio attributes should be set either before or after loading to
            // avoid an ExoPlayer glitch.
            pendingAudioAttributes = audioAttributes;
        } else {
            // MD3Music fork: handleAudioFocus=true 让 Media3 请求音频焦点。
            // 系统自动 duck（VolumeShaper）只发生在无焦点管理的播放器上；
            // Media3 接管后原始焦点事件经 AudioFocusManager 转发给 Dart 三模式决策。
            player.setAudioAttributes(audioAttributes, true);
        }
    }

    private void audioEffectSetEnabled(String type, boolean enabled) {
        audioEffectsMap.get(type).setEnabled(enabled);
    }

    private void loudnessEnhancerSetTargetGain(double targetGain) {
        int targetGainMillibels = (int)Math.round(targetGain * 100.0); // target gain needs to be provided in milliBel, the user provides the value in deciBel
        ((LoudnessEnhancer)audioEffectsMap.get("AndroidLoudnessEnhancer")).setTargetGain(targetGainMillibels);
    }

    private Map<String, Object> equalizerAudioEffectGetParameters() {
        Equalizer equalizer = (Equalizer)audioEffectsMap.get("AndroidEqualizer");
        ArrayList<Object> rawBands = new ArrayList<>();
        for (short i = 0; i < equalizer.getNumberOfBands(); i++) {
            rawBands.add(mapOf(
                "index", i,
                "lowerFrequency", (double)equalizer.getBandFreqRange(i)[0] / 1000.0, // returns a value in milliHertz, we want Hertz
                "upperFrequency", (double)equalizer.getBandFreqRange(i)[1] / 1000.0, // returns a value in milliHertz, we want Hertz
                "centerFrequency", (double)equalizer.getCenterFreq(i) / 1000.0, // returns a value in milliHertz, we want Hertz
                "gain", equalizer.getBandLevel(i) / 100.0 // returns a value in milliBel, we want deciBel
            ));
        }
        return mapOf(
            "parameters", mapOf(
                "minDecibels", equalizer.getBandLevelRange()[0] / 100.0, // returns a value in milliBel, we want deciBel
                "maxDecibels", equalizer.getBandLevelRange()[1] / 100.0, // returns a value in milliBel, we want deciBel
                "bands", rawBands
            )
        );
    }

    private void equalizerBandSetGain(int bandIndex, double gain) {
        ((Equalizer)audioEffectsMap.get("AndroidEqualizer")).setBandLevel((short)bandIndex, (short)(Math.round(gain * 100.0))); // target gain needs to be provided in milliBel, the user provides the value in deciBel
    }

    /// Creates an event based on the current state.
    private Map<String, Object> createPlaybackEvent() {
        final Map<String, Object> event = new HashMap<String, Object>();
        Long duration = getDuration() == C.TIME_UNSET ? null : (1000 * getDuration());
        bufferedPosition = player != null ? player.getBufferedPosition() : 0L;
        event.put("processingState", processingState.ordinal());
        event.put("updatePosition", 1000 * updatePosition);
        event.put("updateTime", updateTime);
        event.put("bufferedPosition", 1000 * Math.max(updatePosition, bufferedPosition));
        event.put("icyMetadata", collectIcyMetadata());
        event.put("duration", duration);
        event.put("currentIndex", currentIndex);
        event.put("androidAudioSessionId", audioSessionId);
        event.put("errorCode", errorCode);
        event.put("errorMessage", errorMessage);
        return event;
    }

    // Broadcast the pending playback event if it was set.
    private void broadcastPendingPlaybackEvent() {
        if (pendingPlaybackEvent != null) {
            eventChannel.success(pendingPlaybackEvent);
            pendingPlaybackEvent = null;
        }
    }

    // Set a pending playback event that should be broadcast at
    // a later time. If we're in a Flutter method call, it will
    // be broadcast just before that method call returns. If
    // we're in an asynchronous callback, it is up to the caller
    // to eventually broadcast that event via
    // broadcastPendingPlaybackEvent.
    //
    // If this is called multiple times before
    // broadcastPendingPlaybackEvent, only the last event is
    // broadcast.
    private void enqueuePlaybackEvent() {
        pendingPlaybackEvent = createPlaybackEvent();
    }

    // Broadcasts a new event immediately.
    private void broadcastImmediatePlaybackEvent() {
        enqueuePlaybackEvent();
        broadcastPendingPlaybackEvent();
    }

    private Map<String, Object> collectIcyMetadata() {
        final Map<String, Object> icyData = new HashMap<>();
        if (icyInfo != null) {
            final Map<String, String> info = new HashMap<>();
            info.put("title", icyInfo.title);
            info.put("url", icyInfo.url);
            icyData.put("info", info);
        }
        if (icyHeaders != null) {
            final Map<String, Object> headers = new HashMap<>();
            headers.put("bitrate", icyHeaders.bitrate);
            headers.put("genre", icyHeaders.genre);
            headers.put("name", icyHeaders.name);
            headers.put("metadataInterval", icyHeaders.metadataInterval);
            headers.put("url", icyHeaders.url);
            headers.put("isPublic", icyHeaders.isPublic);
            icyData.put("headers", headers);
        }
        return icyData;
    }

    private long getCurrentPosition() {
        if (processingState == ProcessingState.idle || processingState == ProcessingState.loading) {
            long pos = player.getCurrentPosition();
            if (pos < 0) pos = 0;
            return pos;
        } else if (seekPos != null && seekPos != C.TIME_UNSET) {
            return seekPos;
        } else {
            return player.getCurrentPosition();
        }
    }

    private long getDuration() {
        if (processingState == ProcessingState.idle || processingState == ProcessingState.loading || player == null) {
            return C.TIME_UNSET;
        } else {
            return player.getDuration();
        }
    }

    private void sendError(int errorCode, String errorMsg, Object details) {
        sendError(errorCode, errorMsg, details, true);
    }

    private void sendError(int errorCode, String errorMsg, Object details, boolean switchToIdle) {
        eventChannel.error(String.valueOf(errorCode), errorMsg, details);
        this.errorCode = errorCode;
        this.errorMessage = errorMsg;
        if (switchToIdle) {
            processingState = ProcessingState.idle;
        }
        broadcastImmediatePlaybackEvent();
        if (prepareResult != null) {
            prepareResult.error(String.valueOf(errorCode), errorMsg, details);
            prepareResult = null;
        }
    }

    private String getLowerCaseExtension(Uri uri) {
        // Until ExoPlayer provides automatic detection of media source types, we
        // rely on the file extension. When this is absent, as a temporary
        // workaround we allow the app to supply a fake extension in the URL
        // fragment. e.g.  https://somewhere.com/somestream?x=etc#.m3u8
        String fragment = uri.getFragment();
        String filename = fragment != null && fragment.contains(".") ? fragment : uri.getPath();
        return filename.replaceAll("^.*\\.", "").toLowerCase();
    }

    public void play(Result result) {
        if (player.getPlayWhenReady()) {
            result.success(new HashMap<String, Object>());
            return;
        }
        // MD3Music fork: 真正开始播放时把当前实例设为活跃播放器，
        // 使封面/歌词/自定义按钮注入（updateActiveSessionMetadata 等）落到真正播放的会话，
        // 避免多播放器并存时 sActivePlayer 指向占位/最后一个创建的播放器。
        sActivePlayer = this;
        // MD3Music fork：跨fade 角色互换时本播放器的会话可能已被 syncSingleSessionToHost
        // release（从系统注销），play 时若已释放则重建，保证系统始终有当前活跃播放器的会话。
        if (createMediaSession && mediaSession == null) {
            buildAndHostMediaSession();
        }
        // MD3Music fork（方向1）：play 是权威收敛点——把本实例会话设为唯一 host 会话，
        // 其余实例的会话仅从 host 移除（不 release 播放器/会话对象），使系统只跟随本播放器。
        syncSingleSessionToHost();
        if (playResult != null) {
            playResult.success(new HashMap<String, Object>());
        }
        playResult = result;
        player.setPlayWhenReady(true);
        updatePosition();
        if (processingState == ProcessingState.completed && playResult != null) {
            playResult.success(new HashMap<String, Object>());
            playResult = null;
        }
    }

    public void pause() {
        if (!player.getPlayWhenReady()) return;
        player.setPlayWhenReady(false);
        updatePosition();
        enqueuePlaybackEvent();
        if (playResult != null) {
            playResult.success(new HashMap<String, Object>());
            playResult = null;
        }
    }

    public void setVolume(final float volume) {
        player.setVolume(volume);
    }

    /**
     * 读取当前曲目的「源格式」（TrackGroup 中媒体轨道本身的 Format），用于歌曲信息页。
     * 与解码输出格式（AudioSink.configure 的 inputFormat）不同：源格式保留歌曲原始位深
     * （如 FLAC 24bit → bitsPerSample=24），而解码输出可能被降为 16bit。
     */
    public Map<String, Object> getSourceFormat() {
        Map<String, Object> m = new HashMap<>();
        m.put("hasData", false);
        try {
            Tracks tracks = player.getCurrentTracks();
            if (tracks != null && !tracks.getGroups().isEmpty()) {
                for (Tracks.Group group : tracks.getGroups()) {
                    if (group.getType() != C.TRACK_TYPE_AUDIO) continue;
                    Format f = group.getMediaTrackGroup().getFormat(0);
                    if (f == null) continue;
                    m.put("hasData", true);
                    m.put("sampleRate", f.sampleRate > 0 ? f.sampleRate : 0);
                    m.put("channelCount", f.channelCount > 0 ? f.channelCount : 0);
                    m.put("bitrate", f.bitrate > 0 ? f.bitrate : 0);
                    m.put("pcmEncoding", f.pcmEncoding);
                    Log.i(TAG, "getSourceFormat: rate=" + f.sampleRate + " ch=" + f.channelCount
                            + " bitrate=" + f.bitrate + " pcmEnc=" + f.pcmEncoding
                            + " mime=" + f.sampleMimeType);
                    break;
                }
            }
        } catch (Exception e) {
            Log.e(TAG, "getSourceFormat failed: " + e.getMessage());
        }
        return m;
    }

    public void setSpeed(final float speed) {
        PlaybackParameters params = player.getPlaybackParameters();
        if (params.speed == speed) return;
        player.setPlaybackParameters(new PlaybackParameters(speed, params.pitch));
        if (player.getPlayWhenReady())
            updatePosition();
        enqueuePlaybackEvent();
    }

    public void setPitch(final float pitch) {
        PlaybackParameters params = player.getPlaybackParameters();
        if (params.pitch == pitch) return;
        player.setPlaybackParameters(new PlaybackParameters(params.speed, pitch));
        enqueuePlaybackEvent();
    }

    public void setSkipSilenceEnabled(final boolean enabled) {
        player.setSkipSilenceEnabled(enabled);
    }

    public void setLoopMode(final int mode) {
        player.setRepeatMode(mode);
    }

    public void setShuffleModeEnabled(final boolean enabled) {
        player.setShuffleModeEnabled(enabled);
    }

    public void seek(final long position, final Integer index, final Result result) {
        if (processingState == ProcessingState.idle || processingState == ProcessingState.loading) {
            result.success(new HashMap<String, Object>());
            return;
        }
        abortSeek();
        seekPos = position;
        seekResult = result;
        try {
            int windowIndex = index != null ? index : player.getCurrentMediaItemIndex();
            player.seekTo(windowIndex, position);
        } catch (RuntimeException e) {
            seekResult = null;
            seekPos = null;
            throw e;
        }
    }

    public void dispose() {
        if (processingState == ProcessingState.loading) {
            abortExistingConnection(true);
        }
        if (playResult != null) {
            playResult.success(new HashMap<String, Object>());
            playResult = null;
        }
        mediaSources.clear();
        clearAudioEffects();
        if (player != null) {
            player.release();
            player = null;
            processingState = ProcessingState.idle;
            broadcastImmediatePlaybackEvent();
        }
        eventChannel.endOfStream();
        dataEventChannel.endOfStream();
        // MD3Music fork: 注销焦点事件监听并关闭通道
        if (focusEventListener != null) {
            AudioFocusManager.removeAudioFocusEventListener(focusEventListener);
            focusEventListener = null;
        }
        // MD3Music fork: 复位忽略/保持标志（避免影响其他播放器实例）
        AudioFocusManager.setIgnoreAudioFocus(false);
        AudioFocusManager.setForceKeepPlaying(false);
        focusEventChannel.endOfStream();
        // MD3Music fork: 释放 MediaSession（与 player 关联）
        if (mediaSession != null) {
            mediaSession.release();
            mediaSession = null;
        }
        // MD3Music fork（阶段6·收敛单一会话）：注销实例登记
        unregisterPlayer(this);
        // MD3Music fork: 本播放器销毁后清空活跃引用，避免注入至过期会话
        if (sActivePlayer == this) {
            sActivePlayer = null;
        }
    }

    private void abortSeek() {
        if (seekResult != null) {
            try {
                seekResult.success(new HashMap<String, Object>());
            } catch (RuntimeException e) {
                // Result already sent
            }
            seekResult = null;
            seekPos = null;
        }
    }

    private void abortExistingConnection(boolean switchToIdle) {
        sendError(ERROR_ABORT, "Connection aborted", null, switchToIdle);
    }

    // Dart can't distinguish between int sizes so
    // Flutter may send us a Long or an Integer
    // depending on the number of bits required to
    // represent it.
    public static Long getLong(Object o) {
        return (o == null || o instanceof Long) ? (Long)o : Long.valueOf(((Integer)o).intValue());
    }

    @SuppressWarnings("unchecked")
    static <T> T mapGet(Object o, String key) {
        if (o instanceof Map) {
            return (T) ((Map<?, ?>)o).get(key);
        } else {
            return null;
        }
    }

    static Map<String, Object> mapOf(Object... args) {
        Map<String, Object> map = new HashMap<>();
        for (int i = 0; i < args.length; i += 2) {
            map.put((String)args[i], args[i + 1]);
        }
        return map;
    }

    static Map<String, String> castToStringMap(Map<?, ?> map) {
        if (map == null) return null;
        Map<String, String> map2 = new HashMap<>();
        for (Object key : map.keySet()) {
            map2.put((String)key, (String)map.get(key));
        }
        return map2;
    }

    enum ProcessingState {
        idle,
        loading,
        buffering,
        ready,
        completed
    }

    public class ObserverRenderer extends NoSampleRenderer {
        private long lastPosUs = 0L;
        private int consecutivePosCount = 0;

        @Override
        public void render(long positionUs, long elapsedRealtimeUs) {
            if (positionUs == lastPosUs) {
                consecutivePosCount++;
            } else {
                if (consecutivePosCount >= 3) {
                    handler.post(() -> {
                        if (updatePositionIfChanged()) {
                            broadcastImmediatePlaybackEvent();
                        }
                    });
                }
                consecutivePosCount = 0;
            }
            lastPosUs = positionUs;
        }

        @Override
        public String getName() {
            return "ObserverRenderer";
        }
    }
}
