import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart' as services;
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/history_repository.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/widgets/player_artwork_image.dart';
import 'package:md3music/widgets/player_playlist_view.dart';
import '../support/controlled_audio_service.dart';

/// 队列面板的编辑 / 删除 / 排序：与歌单详情页同一套模型。
void main() {
  Song song(String id, String title, {int seconds = 60}) => Song(
    id: id,
    title: title,
    artist: 'artist',
    album: 'album',
    duration: Duration(seconds: seconds),
  );

  Widget host(PlayerProvider player) {
    // 滚动归属由宿主持有（真实宿主是 FullPlayer 的 State）。测试里一用例一份，
    // 随 TearDown 释放，免得 TrackingScrollController 泄漏。
    final anchor = PlaylistScrollAnchor();
    addTearDown(anchor.dispose);
    return ChangeNotifierProvider<PlayerProvider>.value(
      value: player,
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 640,
            child: PlayerPlaylistView(
              scrollAnchor: anchor,
              useAmColors: false,
            ),
          ),
        ),
      ),
    );
  }

  /// 与 [host] 同构，但滚动归属由调用方给定：要看「面板销毁重建后位置还在不在」，
  /// 就必须让 anchor 活得比面板 State 久——那正是真实宿主 FullPlayer 的做法。
  Widget hostWith(PlayerProvider player, PlaylistScrollAnchor anchor) =>
      ChangeNotifierProvider<PlayerProvider>.value(
        value: player,
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 640,
              child: PlayerPlaylistView(
                scrollAnchor: anchor,
                useAmColors: false,
              ),
            ),
          ),
        ),
      );

  Widget bareTree(PlayerProvider player) =>
      ChangeNotifierProvider<PlayerProvider>.value(
        value: player,
        child: const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
      );

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

  Future<(PlayerProvider, _ImmediateAudioService)> createPlayer(
    WidgetTester tester,
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
    return (player, audio);
  }

  Future<void> disposePlayer(
    WidgetTester tester,
    PlayerProvider player,
    _ImmediateAudioService audio,
  ) async {
    player.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => HistoryRepository().flush());
    await tester.runAsync(audio.dispose);
    AudioServiceLoader.setTestOverride(null);
  }

  testWidgets('长按进入编辑模式：出现已选计数 / 全选 / 删除', (tester) async {
    final (player, audio) = await createPlayer(tester);
    try {
      await player.playPlaylist([
        song('s0', 'C'),
        song('s1', 'A'),
        song('s2', 'B'),
      ], 0);
      await tester.pumpWidget(host(player));
      await tester.pumpAndSettle();

      // 常态：标题 + 排序 + 编辑，没有多选顶栏
      expect(find.text('播放列表'), findsOneWidget);
      expect(find.byIcon(Icons.swap_vert), findsOneWidget);
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
      expect(find.textContaining('已选'), findsNothing);

      await tester.longPress(find.text('B'));
      await tester.pumpAndSettle();

      expect(find.text('已选 1 首'), findsOneWidget);
      expect(find.text('全选'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
      // 编辑模式下出现拖拽把手，复选框与封面并排（封面不消失）
      expect(find.byIcon(Icons.drag_handle), findsNWidgets(3));
      expect(find.byType(PlayerArtworkImage), findsNWidgets(3));
    } finally {
      await disposePlayer(tester, player, audio);
    }
  });

  testWidgets('全选后再点取消全选', (tester) async {
    final (player, audio) = await createPlayer(tester);
    try {
      await player.playPlaylist([
        song('s0', 'C'),
        song('s1', 'A'),
        song('s2', 'B'),
      ], 0);
      await tester.pumpWidget(host(player));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('B'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 3 首'), findsOneWidget);

      await tester.tap(find.text('取消全选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 0 首'), findsOneWidget);
    } finally {
      await disposePlayer(tester, player, audio);
    }
  });

  testWidgets('1000首队列只构建视口内歌曲行', (tester) async {
    final (player, audio) = await createPlayer(tester);
    try {
      final songs = List.generate(
        1000,
        (index) => song('scale_$index', 'Scale $index'),
      );
      await player.playPlaylist(songs, 0);
      await tester.pumpWidget(host(player));
      await tester.pumpAndSettle();

      expect(find.text('Scale 0'), findsOneWidget);
      expect(find.text('Scale 999'), findsNothing);
      expect(find.byType(ListTile).evaluate().length, lessThan(20));
    } finally {
      await disposePlayer(tester, player, audio);
    }
  });

  testWidgets('5000首队列只构建视口内歌曲行', (tester) async {
    final (player, audio) = await createPlayer(tester);
    try {
      final songs = List.generate(
        5000,
        (index) => song('large_scale_$index', 'Large scale $index'),
      );
      await player.playPlaylist(songs, 0);
      await tester.pumpWidget(host(player));
      await tester.pumpAndSettle();

      expect(find.text('Large scale 0'), findsOneWidget);
      expect(find.text('Large scale 4999'), findsNothing);
      expect(find.byType(ListTile).evaluate().length, lessThan(20));
    } finally {
      await disposePlayer(tester, player, audio);
    }
  });

  testWidgets('按标题排序会真实重排队列', (tester) async {
    final (player, audio) = await createPlayer(tester);
    try {
      await player.playPlaylist([
        song('s0', 'C'),
        song('s1', 'A'),
        song('s2', 'B'),
      ], 0);
      await tester.pumpWidget(host(player));
      await tester.pumpAndSettle();

      // 点排序触发器（图标即 M3ESortButton 的字段），面板在 Overlay 中就展开
      await tester.tap(find.byIcon(Icons.swap_vert));
      await tester.pumpAndSettle();
      // 面板条目与旧菜单逐字相同，且界面别处没有同名文字，直接按文本点
      await tester.ensureVisible(find.text('标题'));
      await tester.tap(find.text('标题'));
      await tester.pumpAndSettle();

      expect(player.playlist.map((s) => s.title).toList(), [
        'A',
        'B',
        'C',
      ], reason: '排序写回队列本身，下一首也按新顺序走');
      expect(player.currentSong?.title, 'C', reason: '当前播放的歌不中断，只是索引跟到新位置');
      expect(player.playlist[player.currentIndex].title, 'C');
    } finally {
      await disposePlayer(tester, player, audio);
    }
  });

  testWidgets('删除选中歌曲：二次确认后从队列移除并退出编辑模式', (tester) async {
    final (player, audio) = await createPlayer(tester);
    try {
      await player.playPlaylist([
        song('s0', 'C'),
        song('s1', 'A'),
        song('s2', 'B'),
      ], 0);
      await tester.pumpWidget(host(player));
      await tester.pumpAndSettle();

      // 选中非当前播放的 'B'
      await tester.longPress(find.text('B'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('确定从播放列表中删除选中的 1 首歌曲吗？'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('删除'),
        ),
      );
      await tester.pumpAndSettle();

      expect(player.playlist.map((s) => s.title).toList(), ['C', 'A']);
      // 删除后退出编辑模式
      expect(find.textContaining('已选'), findsNothing);
      expect(find.text('播放列表'), findsOneWidget);
    } finally {
      await disposePlayer(tester, player, audio);
    }
  });

  // ── 播放列表记住滚动位置 ────────────────────────────────────────────────
  //
  // 面板挂在 PageView(cacheExtent=0) 上，切到歌词/评论页签时**整棵子树被销毁**；
  // 旧实现有两个问题叠在一起：
  //   ① ScrollController 是面板 State 内部的 → 重建后新 position 从 0 起步
  //      （`ScrollController.initialScrollOffset` 是构造期定死的字段）；
  //   ② initState 无条件「滚到当前播放曲」→ 即便位置带回来了也会被盖掉，
  //      当前曲靠前时目标还被 clamp 成 0，用户看到的就是「回到顶部」。
  // 现在：控制器由宿主持有（用 TrackingScrollController，重建时在创建当下就带回
  // 偏移，不必事后 jumpTo）+ 只有歌变了才定位。
  testWidgets('面板销毁重建后保持滚动位置；只有切歌才重新定位', (tester) async {
    final (player, audio) = await createPlayer(tester);
    final anchor = PlaylistScrollAnchor();
    addTearDown(anchor.dispose);
    try {
      await player.playPlaylist([
        for (var i = 0; i < 30; i++) song('s$i', 'S$i'),
      ], 0);
      await tester.pumpWidget(hostWith(player, anchor));
      await tester.pumpAndSettle();

      // 用户自己滚到中段（当前曲仍在第 0 首，位置与「当前曲居中」毫无关系）。
      // 用真实拖拽而不是 jumpTo：要验的就是「手指滚动过的偏移能不能带回来」。
      await tester.drag(find.byType(Scrollable), const Offset(0, -900));
      await tester.pumpAndSettle();
      final scrolled = anchor.controller.offset;
      expect(
        scrolled,
        greaterThan(300),
        reason: '确实滚离了顶部（当前曲是第 0 首，自动定位的目标恒为 0，'
            '所以只要还停在这儿就证明偏移带回来了）',
      );

      // 模拟 PageView 销毁离屏页再重建：面板 State 全新，只有 anchor 活下来。
      await tester.pumpWidget(bareTree(player));
      await tester.pump();
      await tester.pumpWidget(hostWith(player, anchor));
      await tester.pumpAndSettle();
      expect(
        anchor.controller.offset,
        closeTo(scrolled, 1),
        reason: '同一首歌内切走再回来，必须停在用户留下的位置（旧实现会被拉回当前曲）',
      );

      // 换了歌才跟到新曲：第 20 首
      await player.playPlaylist([
        for (var i = 0; i < 30; i++) song('s$i', 'S$i'),
      ], 20);
      await tester.pumpAndSettle();
      expect(
        anchor.controller.offset,
        greaterThan(1000),
        reason: '当前曲变了，列表要跟到新曲（Q2=A 的语义）',
      );

      // 而且要跟**准**：目标行必须在视口里且大致居中。旧实现按写死的 72dp 算行高，
      // 误差随下标线性累积；真机行高一旦不等于 72（显示大小缩放、编辑模式行内
      // 差异），第 20 首的落点就不是那一行。现在用实测行高
      // （(maxScrollExtent + viewport) / itemCount）定位。
      final rowRect = tester.getRect(find.text('S20'));
      final paneRect = tester.getRect(find.byType(Scrollable));
      expect(
        rowRect.top,
        greaterThanOrEqualTo(paneRect.top - 1),
        reason: '目标行必须在视口内（上沿 ${rowRect.top} vs 视口 ${paneRect.top}）',
      );
      expect(
        rowRect.bottom,
        lessThanOrEqualTo(paneRect.bottom + 1),
        reason: '目标行必须在视口内（下沿 ${rowRect.bottom} vs 视口 ${paneRect.bottom}）',
      );
      expect(
        (rowRect.center.dy - paneRect.center.dy).abs(),
        lessThan(paneRect.height * 0.25),
        reason: '目标行应大致居中（需求写的是「滚动到当前播放的歌曲并居中显示」）',
      );
    } finally {
      await disposePlayer(tester, player, audio);
    }
  });
}

class _ImmediateAudioService extends ControlledAudioService {
  @override
  Future<void> setPlaylist(
    List<just_audio.UriAudioSource> sources, {
    int startIndex = 0,
    Duration? initialPosition,
  }) async {}
}
