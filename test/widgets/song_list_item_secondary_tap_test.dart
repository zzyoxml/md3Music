// Windows 鼠标右键 → 歌曲行「更多菜单」的接线校验。
//
// 关注点：右键走的是与行尾三个点**同一个** `_showMoreMenu`（底部弹层），
// 且不误触播放 / 长按 / 多选切换；三重门控（TV、平台、_hasMoreMenu）逐条钉住。
//
// flutter_test 里发次键事件必须显式给 `kind: mouse` + `buttons: kSecondaryMouseButton`：
// 默认的 touch + kPrimaryButton 根本不会进 SecondaryTapGestureRecognizer。
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart' as services;
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/blacklist_provider.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/widgets/song_list_item.dart';
import '../support/controlled_audio_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final song = Song(
    id: 'secondary-tap-target',
    title: '右键测试曲目',
    artist: '歌手',
    album: '专辑',
    duration: const Duration(minutes: 3),
    url: 'https://audio.invalid/secondary-tap-target.mp3',
    isOnline: true,
  );

  Future<_Env> boot() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const services.EventChannel(
            'dev.fluttercommunity.plus/connectivity_status',
          ),
          MockStreamHandler.inline(
            onListen: (_, events) => events.success(<String>['wifi']),
          ),
        );
    final audio = _ImmediateAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = _TestPlayerProvider();
    await player.audioReady.timeout(const Duration(seconds: 10));
    return _Env(
      player: player,
      favorites: FavoritesProvider(syncOnStart: false),
      localFavorites: LocalFavoritesProvider(),
      audio: audio,
    );
  }

  /// 平台覆盖必须在测试体内设置、测试体内复位。
  ///
  /// 框架在测试体结束时校验 foundation 的 debug 覆盖变量，放 setUp/tearDown
  /// 或 addTearDown 都会变成「测试通过但框架判定失败」，报错位置极具迷惑性。
  Future<void> onWindows(Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  /// 在歌曲行上按下并抬起次键（鼠标右键）。[dragBy] 非空时先拖动再抬起。
  Future<void> secondaryClick(
    WidgetTester tester,
    Finder target, {
    Offset? dragBy,
  }) async {
    final gesture = await tester.startGesture(
      tester.getCenter(target),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    if (dragBy != null) {
      await gesture.moveBy(dragBy);
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('Windows：右键行弹出与三点相同的更多菜单', (tester) async {
    await onWindows(() async {
      final env = (await tester.runAsync(boot))!;
      try {
        var taps = 0;
        var longPresses = 0;
        await tester.pumpWidget(
          env.host(
            SongListItem(
              song: song,
              onTap: () => taps++,
              onLongPress: () => longPresses++,
            ),
          ),
        );
        await tester.pump();

        await secondaryClick(tester, find.text(song.displayName));

        // 与三点用例同一组文案：证明走的是同一个 _showMoreMenu。
        expect(find.text('下一首播放'), findsOneWidget);
        expect(find.text('添加到歌单'), findsOneWidget);
        // 次键不进 TapGestureRecognizer / LongPressGestureRecognizer 的候选集。
        expect(taps, 0);
        expect(longPresses, 0);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await env.dispose(tester);
      }
    });
  });

  testWidgets('Windows：多选模式右键不弹菜单、不切换选中', (tester) async {
    await onWindows(() async {
      final env = (await tester.runAsync(boot))!;
      try {
        var toggles = 0;
        await tester.pumpWidget(
          env.host(
            SongListItem(
              song: song,
              isSelectMode: true,
              onSelectToggle: () => toggles++,
            ),
          ),
        );
        await tester.pump();

        await secondaryClick(tester, find.text(song.displayName));

        expect(find.text('下一首播放'), findsNothing);
        expect(toggles, 0);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await env.dispose(tester);
      }
    });
  });

  testWidgets('Windows：favoriteOnly 档右键不弹菜单（本就无三点）', (tester) async {
    await onWindows(() async {
      final env = (await tester.runAsync(boot))!;
      try {
        await tester.pumpWidget(
          env.host(
            SongListItem(
              song: song,
              trailingActions: SongTrailingActions.favoriteOnly,
            ),
          ),
        );
        await tester.pump();

        await secondaryClick(tester, find.text(song.displayName));

        expect(find.text('下一首播放'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await env.dispose(tester);
      }
    });
  });

  testWidgets('非 Windows：右键不弹菜单（门控里的平台项）', (tester) async {
    // 不设平台覆盖 = 默认 android，即 Android 真机语义。
    final env = (await tester.runAsync(boot))!;
    try {
      await tester.pumpWidget(env.host(SongListItem(song: song)));
      await tester.pump();

      await secondaryClick(tester, find.text(song.displayName));

      expect(find.text('下一首播放'), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await env.dispose(tester);
    }
  });

  testWidgets('Windows：主键单击仍只走 onTap（不弹菜单）', (tester) async {
    await onWindows(() async {
      final env = (await tester.runAsync(boot))!;
      try {
        var taps = 0;
        await tester.pumpWidget(
          env.host(SongListItem(song: song, onTap: () => taps++)),
        );
        await tester.pump();

        await tester.tap(find.text(song.displayName));
        await tester.pumpAndSettle();

        expect(taps, 1);
        expect(find.text('下一首播放'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await env.dispose(tester);
      }
    });
  });

  testWidgets('Windows：右键按住拖动只滑动，不弹菜单', (tester) async {
    await onWindows(() async {
      final env = (await tester.runAsync(boot))!;
      try {
        await tester.pumpWidget(env.host(SongListItem(song: song)));
        await tester.pump();

        // 拖动超过手势 slop → SecondaryTapGestureRecognizer 出局（用 Down 就会误弹）。
        await secondaryClick(
          tester,
          find.text(song.displayName),
          dragBy: const Offset(0, 60),
        );

        expect(find.text('下一首播放'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await env.dispose(tester);
      }
    });
  });
}

class _Env {
  _Env({
    required this.player,
    required this.favorites,
    required this.localFavorites,
    required this.audio,
  });

  final PlayerProvider player;
  final FavoritesProvider favorites;
  final LocalFavoritesProvider localFavorites;
  final _ImmediateAudioService audio;

  Future<void> dispose(WidgetTester tester) async {
    player.dispose();
    await tester.runAsync(audio.dispose);
    AudioServiceLoader.setTestOverride(null);
  }

  Widget host(Widget child) => MultiProvider(
    providers: [
      ChangeNotifierProvider<PlayerProvider>.value(value: player),
      ChangeNotifierProvider<FavoritesProvider>.value(value: favorites),
      ChangeNotifierProvider<LocalFavoritesProvider>.value(
        value: localFavorites,
      ),
      // 更多菜单内的「不感兴趣」tile 读黑名单状态（不拉取、不发请求）
      ChangeNotifierProvider<BlacklistProvider>(
        create: (_) => BlacklistProvider(),
      ),
    ],
    child: MaterialApp(
      // 弹出的更多菜单是 modal bottom sheet，需要有可用的 Scaffold 与 Overlay。
      home: Scaffold(body: child),
    ),
  );
}

class _TestPlayerProvider extends PlayerProvider {
  @override
  Song? get currentSong => null;

  @override
  bool get isPlaying => false;
}

class _ImmediateAudioService extends ControlledAudioService {
  @override
  Future<void> setPlaylist(
    List<just_audio.UriAudioSource> sources, {
    int startIndex = 0,
    Duration? initialPosition,
  }) async {}
}
