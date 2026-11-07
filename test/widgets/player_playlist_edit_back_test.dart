import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' as services;
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/history_repository.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/widgets/player_playlist_view.dart';

import '../support/controlled_audio_service.dart';

/// 播放列表编辑模式与宿主返回键的契约回归测试。
///
/// 背景（bug）：手机端播放页停在「播放列表」页签、列表处于编辑模式时，
/// 按系统返回键会**直接收起播放页**，而不是先退出编辑模式。编辑模式是面板
/// State 的内部状态，宿主（FullPlayer）的 `PopScope` 拿不到它，于是返回键
/// 直接走到了 `_collapseByButton()`。
///
/// 修法：面板 State 公开 [PlayerPlaylistViewState.exitEditModeIfActive]，
/// 宿主用 `GlobalKey<PlayerPlaylistViewState>` 询问并优先消费返回键。
/// 本文件锁死这条契约，防止面板再次把编辑状态藏成私有字段。
/// 装载立即完成的服务：本文件不关心装载时序，只关心编辑模式状态机。
/// 用默认 [ControlledAudioService] 会让 `playPlaylist` 卡在等
/// `completeSourceLoad` 上（超时失败）。
class _ImmediateAudioService extends ControlledAudioService {
  @override
  Future<void> setPlaylist(
    List<just_audio.UriAudioSource> sources, {
    int startIndex = 0,
    Duration? initialPosition,
  }) async {}
}

void main() {
  Song song(String id, String title) => Song(
    id: id,
    title: title,
    artist: 'artist',
    album: 'album',
    duration: const Duration(seconds: 60),
  );

  /// 装载立即完成的服务：本文件不关心装载时序，只关心编辑模式状态机。
  /// 用默认 [ControlledAudioService] 会让 `playPlaylist` 卡在等
  /// `completeSourceLoad` 上（超时失败）。
  void mockConnectivityStream() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const services.EventChannel(
            'dev.fluttercommunity.plus/connectivity_status',
          ),
          MockStreamHandler.inline(
            onListen: (_, events) => events.success(<String>['wifi']),
          ),
        );
  }

  Widget host(PlayerProvider player, GlobalKey<PlayerPlaylistViewState> key) =>
      ChangeNotifierProvider<PlayerProvider>.value(
        value: player,
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 640,
              child: PlayerPlaylistView(
                key: key,
                scrollAnchor: PlaylistScrollAnchor(),
                useAmColors: false,
              ),
            ),
          ),
        ),
      );

  /// 起播放器 + 装一首（或几首）歌，返回 player/audio 由调用方负责清理。
  Future<(PlayerProvider, ControlledAudioService)> createPlayer(
    WidgetTester tester,
    List<Song> songs,
  ) async {
    SharedPreferences.setMockInitialValues({});
    mockConnectivityStream();
    final audio = _ImmediateAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    late final PlayerProvider player;
    await tester.runAsync(() async {
      player = PlayerProvider();
      await player.audioReady.timeout(const Duration(seconds: 10));
    });
    await player.playPlaylist(songs, 0);
    return (player, audio);
  }

  Future<void> disposePlayer(
    WidgetTester tester,
    PlayerProvider player,
    ControlledAudioService audio,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    player.dispose();
    await tester.runAsync(() => HistoryRepository().flush());
    await tester.runAsync(audio.dispose);
    AudioServiceLoader.setTestOverride(null);
  }

  testWidgets('非编辑模式下 exitEditModeIfActive 不消费返回', (tester) async {
    final (player, audio) = await createPlayer(tester, [song('s0', 'A')]);
    final key = GlobalKey<PlayerPlaylistViewState>();
    try {
      await tester.pumpWidget(host(player, key));
      await tester.pumpAndSettle();

      expect(key.currentState, isNotNull);
      expect(key.currentState!.editMode, isFalse);
      expect(
        key.currentState!.exitEditModeIfActive(),
        isFalse,
        reason: '常态下必须放行返回键，否则播放页永远收不起来',
      );
    } finally {
      await disposePlayer(tester, player, audio);
    }
  });

  testWidgets('编辑模式下 exitEditModeIfActive 退出编辑并消费返回', (tester) async {
    final (player, audio) = await createPlayer(tester, [
      song('s0', 'A'),
      song('s1', 'B'),
    ]);
    final key = GlobalKey<PlayerPlaylistViewState>();
    try {
      await tester.pumpWidget(host(player, key));
      await tester.pumpAndSettle();

      // 长按进入编辑模式
      await tester.longPress(find.text('B'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 首'), findsOneWidget);
      expect(key.currentState!.editMode, isTrue);

      // 第一次返回：退出编辑模式并返回 true（宿主据此不收起播放页）
      expect(key.currentState!.exitEditModeIfActive(), isTrue);
      await tester.pumpAndSettle();
      expect(find.textContaining('已选'), findsNothing);
      expect(find.text('播放列表'), findsOneWidget);
      expect(key.currentState!.editMode, isFalse);

      // 第二次返回：已在常态，放行收起
      expect(key.currentState!.exitEditModeIfActive(), isFalse);
    } finally {
      await disposePlayer(tester, player, audio);
    }
  });
}
