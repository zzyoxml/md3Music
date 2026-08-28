package com.ryanheise.just_audio;

import android.content.Context;
import androidx.annotation.NonNull;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import java.util.HashMap;
import java.util.List;
import java.util.ArrayList;
import java.util.Map;

public class MainMethodCallHandler implements MethodCallHandler {

    private final Context applicationContext;
    private final BinaryMessenger messenger;

    private final Map<String, AudioPlayer> players = new HashMap<>();

    public MainMethodCallHandler(Context applicationContext,
            BinaryMessenger messenger) {
        this.applicationContext = applicationContext;
        this.messenger = messenger;
    }

    @Override
    public void onMethodCall(MethodCall call, @NonNull Result result) {
        switch (call.method) {
        case "init": {
            String id = call.argument("id");
            if (players.containsKey(id)) {
                result.error("Platform player " + id + " already exists", null, null);
                break;
            }
            List<Object> rawAudioEffects = call.argument("androidAudioEffects");
            // MD3Music fork（方案B·双播放器轮换）：所有播放器（含 crossfade 辅播放器）都创建
            // 媒体3会话。跨fade 时 aux 播放新歌，其 play() 经 fork 的 syncSingleSessionToHost
            // 把 aux 会话设为唯一 host 会话（移除主会话），使媒体卡片/封面跟随当前播放的
            // 新歌，且不迁移播放主体（避免收敛回主播放器的重新加载停顿）。会话收敛由
            // AudioPlayer.play() 权威执行，系统任意时刻只暴露一个活跃媒体会话。
            boolean createMediaSession = true;
            players.put(
                id,
                new AudioPlayer(
                    applicationContext,
                    messenger,
                    id,
                    call.argument("audioLoadConfiguration"),
                    rawAudioEffects,
                    call.argument("androidAudioOffloadPreferences"),
                    call.argument("androidOffloadSchedulingEnabled"),
                    call.argument("useLazyPreparation"),
                    createMediaSession
                )
            );
            result.success(null);
            break;
        }
        case "disposePlayer": {
            String id = call.argument("id");
            AudioPlayer player = players.get(id);
            if (player != null) {
                player.dispose();
                players.remove(id);
            }
            result.success(new HashMap<String, Object>());
            break;
        }
        case "disposeAllPlayers": {
            dispose();
            result.success(new HashMap<String, Object>());
            break;
        }
        default:
            result.notImplemented();
            break;
        }
    }

    void dispose() {
        for (AudioPlayer player : new ArrayList<AudioPlayer>(players.values())) {
            player.dispose();
        }
        players.clear();
    }
}
