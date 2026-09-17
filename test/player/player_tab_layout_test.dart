import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/modules/player/player_tab_layout.dart';

void main() {
  group('resolvePlayerTabLayout 结构推导', () {
    test('窄屏在线歌曲：含封面与评论 tab，共 4 个，歌词下标 2', () {
      final layout = resolvePlayerTabLayout(
        isWideLayout: false,
        isLocalSong: false,
        closeLocalMusicComments: true,
      );
      expect(layout.hasCover, isTrue);
      expect(layout.hasComments, isTrue);
      expect(layout.length, 4);
      expect(layout.lyricsIndex, 2);
    });

    test('窄屏本地歌曲且开启「关闭本地音乐评论区」：无评论 tab，共 3 个', () {
      final layout = resolvePlayerTabLayout(
        isWideLayout: false,
        isLocalSong: true,
        closeLocalMusicComments: true,
      );
      expect(layout.hasCover, isTrue);
      expect(layout.hasComments, isFalse);
      expect(layout.length, 3);
      expect(layout.lyricsIndex, 2);
    });

    test('窄屏本地歌曲但关闭该开关：恢复评论 tab，共 4 个', () {
      final layout = resolvePlayerTabLayout(
        isWideLayout: false,
        isLocalSong: true,
        closeLocalMusicComments: false,
      );
      expect(layout.hasComments, isTrue);
      expect(layout.length, 4);
    });

    test('宽屏在线歌曲：无封面 tab，共 3 个，歌词下标 1', () {
      final layout = resolvePlayerTabLayout(
        isWideLayout: true,
        isLocalSong: false,
        closeLocalMusicComments: true,
      );
      expect(layout.hasCover, isFalse);
      expect(layout.hasComments, isTrue);
      expect(layout.length, 3);
      expect(layout.lyricsIndex, 1);
    });

    test('宽屏本地歌曲且开启该开关：无封面无评论，共 2 个', () {
      final layout = resolvePlayerTabLayout(
        isWideLayout: true,
        isLocalSong: true,
        closeLocalMusicComments: true,
      );
      expect(layout.hasCover, isFalse);
      expect(layout.hasComments, isFalse);
      expect(layout.length, 2);
      expect(layout.lyricsIndex, 1);
    });

    test('该开关只作用于本地歌：在线歌曲开启开关时仍有评论 tab', () {
      final layout = resolvePlayerTabLayout(
        isWideLayout: false,
        isLocalSong: false,
        closeLocalMusicComments: true,
      );
      expect(layout.hasComments, isTrue);
    });
  });

  group('indexAfterChangeFrom 结构变化后的下标', () {
    test('进入宽屏（封面 tab 消失）一律落到歌词 tab', () {
      const next = (hasCover: false, hasComments: true);
      expect(next.indexAfterChangeFrom(0), 1);
      expect(next.indexAfterChangeFrom(1), 1);
      expect(next.indexAfterChangeFrom(2), 1);
    });

    test('窄屏隐藏评论 tab：评论下标 3 钳制到歌词 2', () {
      const next = (hasCover: true, hasComments: false);
      expect(next.indexAfterChangeFrom(0), 0);
      expect(next.indexAfterChangeFrom(1), 1);
      expect(next.indexAfterChangeFrom(3), 2);
    });

    test('宽屏隐藏评论 tab：无封面 tab 仍一律落到歌词 tab', () {
      const next = (hasCover: false, hasComments: false);
      expect(next.indexAfterChangeFrom(0), 1);
      expect(next.indexAfterChangeFrom(1), 1);
      expect(next.indexAfterChangeFrom(2), 1);
    });

    test('结构不变时保持原下标', () {
      const same = (hasCover: true, hasComments: true);
      expect(same.indexAfterChangeFrom(0), 0);
      expect(same.indexAfterChangeFrom(3), 3);
    });
  });
}
