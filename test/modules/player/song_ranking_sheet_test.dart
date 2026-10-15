import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/player/song_ranking_sheet.dart';

/// 歌曲成绩单视图（SongRankingView）的基础渲染测试。
void main() {
  testWidgets('无 albumAudioId 的歌曲显示空态且不进入加载', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SongRankingView(
            song: Song(
              id: 'hash1',
              title: '测试歌曲',
              artist: '测试歌手',
              album: '测试专辑',
              duration: const Duration(seconds: 60),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('该歌曲暂无成绩单数据'), findsOneWidget);
    // 空态不触网：无加载指示器、无成就卡
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
