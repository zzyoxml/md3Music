import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/widgets/song_menu_header.dart';

void main() {
  testWidgets('SongMenuHeader 显示歌名/歌手/专辑与封面', (tester) async {
    const song = Song(
      id: 'hash1',
      title: '牡丹亭',
      artist: '浅影阿',
      album: '牡丹亭',
      duration: Duration(minutes: 3, seconds: 12),
      isOnline: true,
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SongMenuHeader(song: song)),
      ),
    );
    await tester.pumpAndSettle();

    // 歌名与专辑同名 → 各出现一次，共 2 次
    expect(find.text('牡丹亭'), findsNWidgets(2));
    expect(find.text('浅影阿'), findsOneWidget);
  });

  testWidgets('专辑为空时显示「未知专辑」', (tester) async {
    const song = Song(
      id: 'hash2',
      title: '测试歌',
      artist: '测试歌手',
      album: '',
      duration: Duration(minutes: 1),
      isOnline: false,
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SongMenuHeader(song: song)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('测试歌'), findsOneWidget);
    expect(find.text('未知专辑'), findsOneWidget);
  });
}
