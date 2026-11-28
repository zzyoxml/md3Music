import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/controlled_audio_service.dart';

/// R1：completed 误报防护的装载窗曾经**全平台套用**，吞掉 Android 上
/// 「曲尾附近重载后短时间内真实播完」的合法 completed —— completed **事件**
/// 与位置**兜底**两条检测路径共用同一时间戳，被吞后同时失效：平台停在
/// completed、位置冻结在 duration，再无任何自愈，即偶发「播完当前歌曲
/// 不自动续播下一首」的死区。修复按平台分流（Android 事件零窗口、
/// 兜底短窗；Windows 长窗保持原修复），本组钉住该行为。
///
/// 复现手法（与真机同源）：播放装载在途时暂停（本次装载被判作废）→
/// 恢复播放以当前位置重载（[_setUrlAndPlay] 打新时间戳）→ 重载很快完成，
/// 曲尾残留自然播完，落在旧实现 3s 防护窗内。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 假想时长：真实 ExoPlayer 在时长就绪后会推一次 durationStream。
  const shortMp3 = Duration(seconds: 60);

  void installConnectivityMocks() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (call) async => call.method == 'check' ? <String>['wifi'] : null,
    );
    messenger.setMockStreamHandler(
      const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
      MockStreamHandler.inline(
        onListen: (_, events) => events.success(<String>['wifi']),
      ),
    );
  }

  Song song(String id) => Song(
        id: id,
        title: id,
        artist: 'Artist',
        album: 'Album',
        duration: shortMp3,
        url: 'https://media.example/$id.mp3',
        isOnline: true,
      );

  /// 三首歌曲单：曲尾播完后自动续播的观测点是「第二首 b 是否被装载」。
  final songs = [song('a'), song('b'), song('c')];

  Future<void> startPlaylist(
    PlayerProvider player,
    ControlledAudioService audio,
  ) async {
    final play = player.playPlaylist(songs, 0);
    await audio.waitForPlaylistLoads(1);
    await audio.completeSourceLoad(0);
    await play;
    audio.emitPlaying(true);
    await Future<void>.delayed(Duration.zero);
  }

  group('R1 completed 误报防护的平台分流', () {
    test('Android：曲尾重载后 3s 内真实播完，completed 必须切歌', () async {
      SharedPreferences.setMockInitialValues({});
      installConnectivityMocks();
      final audio = ControlledAudioService();
      AudioServiceLoader.setTestOverride(() async => audio);
      late final PlayerProvider player;
      try {
        // Android 口径：注入平台标志（宿主为 Linux，显式钉住语义）。
        player = PlayerProvider(
          isAndroidForTest: true,
          isWindowsForTest: false,
        );
        await player.audioReady.timeout(const Duration(seconds: 10));

        // 起播装载在途时暂停：作废本次请求并记「装载已被取消」。
        unawaited(player.playPlaylist(songs, 0));
        await audio.waitForPlaylistLoads(1);
        await player.pause();

        // 恢复播放以当前位置重载（_setUrlAndPlay 打新时间戳）。
        // 不等待其整体完成——装载结果由本用例驱动（同既有 startPlaylist 手法）。
        unawaited(player.resume());
        await audio.waitForPlaylistLoads(2);
        await audio.completeSourceLoad(1);

        // 让重载链收尾（登记 completionReady=当前请求）。
        audio.emitPlaying(true);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // 距重载不足 1s：Android 的位置兜底仍处短窗内（不触发），
        // 只验证 completed **事件**路径不受旧 3s 窗拦截。
        audio.emitCompleted();

        // 旧实现在此把合法 completed 当 Windows 误报吞掉 → 下一首永不安载。
        await audio.waitForPlaylistLoads(3).timeout(const Duration(seconds: 5));
        await audio.completeSourceLoad(2);
        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(
          player.currentSong?.id,
          'b',
          reason: '重载后短时间内真实播完必须自动续播（completed 事件路径）',
        );
      } finally {
        player.dispose();
        await audio.dispose();
        AudioServiceLoader.setTestOverride(null);
      }
    });

    test('Android：位置兜底仅在装载短窗内让位，窗口外仍可切歌', () async {
      SharedPreferences.setMockInitialValues({});
      installConnectivityMocks();
      final audio = ControlledAudioService();
      AudioServiceLoader.setTestOverride(() async => audio);
      late final PlayerProvider player;
      try {
        player = PlayerProvider(
          isAndroidForTest: true,
          isWindowsForTest: false,
        );
        await player.audioReady.timeout(const Duration(seconds: 10));
        await startPlaylist(player, audio);

        // 等过 Android 短窗（1s）：换源后旧时长残留的瞬态已被排除，
        // completed 事件缺失时兜底是最后一条检测路径，必须留活路。
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        audio.emitDuration(shortMp3);
        audio.emitPosition(shortMp3);
        await Future<void>.delayed(Duration.zero);

        // 旧实现的 3s 窗会把这次兜底也挡住 → 第二首永不安载。
        await audio.waitForPlaylistLoads(2).timeout(const Duration(seconds: 5));
        await audio.completeSourceLoad(1);
        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(
          player.currentSong?.id,
          'b',
          reason: '装载窗过后位置兜底应能触发切歌（Android 短窗生效）',
        );
      } finally {
        player.dispose();
        await audio.dispose();
        AudioServiceLoader.setTestOverride(null);
      }
    });

    test('Windows：点歌后 3s 内的 spurious completed 仍须被忽略', () async {
      SharedPreferences.setMockInitialValues({});
      installConnectivityMocks();
      final audio = ControlledAudioService();
      AudioServiceLoader.setTestOverride(() async => audio);
      late final PlayerProvider player;
      try {
        // 复用点歌总跳下一首的原修复场景：原 3s 窗不得被回退。
        player = PlayerProvider(
          isAndroidForTest: false,
          isWindowsForTest: true,
        );
        await player.audioReady.timeout(const Duration(seconds: 10));

        // 复用点歌总跳下一首的原修复场景：原 3s 窗不得被回退。
        unawaited(player.playPlaylist(songs, 0));
        await audio.waitForPlaylistLoads(1);
        await player.pause();
        unawaited(player.resume());
        await audio.waitForPlaylistLoads(2);
        await audio.completeSourceLoad(1);

        audio.emitPlaying(true);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // 全流程毫秒级完成，远小于 3s 窗：误报判定必须生效。
        audio.emitCompleted();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(
          player.currentSong?.id,
          'a',
          reason: 'Windows 点歌后的 spurious completed 不得切歌',
        );
        expect(
          audio.playlistLoads.length,
          2,
          reason: '不得为误报 completed 发起 next() 的下一首装载',
        );
      } finally {
        player.dispose();
        await audio.dispose();
        AudioServiceLoader.setTestOverride(null);
      }
    });
  });
}