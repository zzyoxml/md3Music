import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/widgets/player_artwork_image.dart';
import 'package:md3music/widgets/player_playlist_view.dart';

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
    return ChangeNotifierProvider<PlayerProvider>.value(
      value: player,
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 640,
            child: PlayerPlaylistView(useAmColors: false),
          ),
        ),
      ),
    );
  }

  testWidgets('长按进入编辑模式：出现已选计数 / 全选 / 删除', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final player = PlayerProvider();
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
      player.dispose();
      await tester.pump(const Duration(seconds: 5));
    }
  });

  testWidgets('全选后再点取消全选', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final player = PlayerProvider();
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
      player.dispose();
      await tester.pump(const Duration(seconds: 5));
    }
  });

  testWidgets('按标题排序会真实重排队列', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final player = PlayerProvider();
    try {
      await player.playPlaylist([
        song('s0', 'C'),
        song('s1', 'A'),
        song('s2', 'B'),
      ], 0);
      await tester.pumpWidget(host(player));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.swap_vert));
      await tester.pumpAndSettle();
      // 直接点菜单项本身，避免命中弹层里同名文字的其它位置
      await tester.tap(
        find.byWidgetPredicate(
          (w) =>
              w is CheckedPopupMenuItem<PlaylistSortBy> &&
              w.value == PlaylistSortBy.title,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        player.playlist.map((s) => s.title).toList(),
        ['A', 'B', 'C'],
        reason: '排序写回队列本身，下一首也按新顺序走',
      );
      expect(
        player.currentSong?.title,
        'C',
        reason: '当前播放的歌不中断，只是索引跟到新位置',
      );
      expect(player.playlist[player.currentIndex].title, 'C');
    } finally {
      player.dispose();
      await tester.pump(const Duration(seconds: 5));
    }
  });

  testWidgets('删除选中歌曲：二次确认后从队列移除并退出编辑模式', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final player = PlayerProvider();
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
      player.dispose();
      await tester.pump(const Duration(seconds: 5));
    }
  });
}
