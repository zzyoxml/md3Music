import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/utils/audio_scanner.dart';
import 'package:md3music/core/utils/local_lyric_loader.dart';

/// #251：本地音乐未匹配在线信息时，用本地信息（标签 → 目录结构）组织专辑。
void main() {
  group('inferAlbumFromPath（文件路径 → 专辑）', () {
    test('专辑/曲目 布局：取父目录', () {
      expect(inferAlbumFromPath('/music/叶惠美/01 以父之名.mp3'), '叶惠美');
      expect(inferAlbumFromPath(r'D:\Music\叶惠美\01.mp3'), '叶惠美');
    });

    test('艺术家/专辑/曲目 布局：仍取父目录（专辑），不是艺术家', () {
      expect(inferAlbumFromPath('/music/周杰伦/叶惠美/01.mp3'), '叶惠美');
    });

    test('文件直接放在通用音乐根目录下：不把根目录当专辑', () {
      expect(inferAlbumFromPath('/music/01.mp3'), isNull);
      expect(inferAlbumFromPath(r'D:\Music\song.mp3'), isNull);
      expect(inferAlbumFromPath('/storage/emulated/0/Download/a.mp3'), isNull);
      expect(inferAlbumFromPath('/我的音乐/a.flac'), isNull);
    });

    test('盘符根目录 / 只有文件名：返回 null', () {
      expect(inferAlbumFromPath(r'D:\a.mp3'), isNull);
      expect(inferAlbumFromPath('a.mp3'), isNull);
    });
  });

  group('inferAlbumFromDir（SAF 目录路径 → 专辑）', () {
    test('取目录最后一级（不是父级）', () {
      expect(inferAlbumFromDir('/storage/emulated/0/Music/叶惠美'), '叶惠美');
      expect(inferAlbumFromDir(r'D:\Music\周杰伦\范特西'), '范特西');
    });

    test('通用根目录返回 null', () {
      expect(inferAlbumFromDir('/storage/emulated/0/Music'), isNull);
      expect(inferAlbumFromDir(r'D:\Download'), isNull);
    });
  });

  group('inferArtistFromPath（文件路径 → 艺术家）', () {
    test('艺术家/专辑/曲目 布局：取祖父目录', () {
      expect(inferArtistFromPath('/music/周杰伦/叶惠美/01.mp3'), '周杰伦');
    });

    test('层级不足或祖父是通用目录：返回 null', () {
      expect(inferArtistFromPath('/music/叶惠美/01.mp3'), isNull);
      expect(inferArtistFromPath('/music/01.mp3'), isNull);
    });
  });

  group('#250 loadForSongAsync 不再无条件信任扫描快照', () {
    test('无本地路径但有快照：沿用快照（SAF/云盘场景）', () async {
      final got = await LocalLyricLoader.loadForSongAsync(
        localPath: null,
        cachedLyrics: '[00:01]旧歌词',
      );
      expect(got, '[00:01]旧歌词');
    });

    test('content:// 且无文件可读：沿用快照', () async {
      final got = await LocalLyricLoader.loadForSongAsync(
        localPath: 'content://media/external/audio/media/1',
        cachedLyrics: '[00:01]旧歌词',
      );
      expect(got, '[00:01]旧歌词');
    });

    test('文件不存在时回退快照，不把已有歌词弄丢', () async {
      final got = await LocalLyricLoader.loadForSongAsync(
        localPath: '/nonexistent/path/a.mp3',
        cachedLyrics: '[00:01]旧歌词',
      );
      expect(got, '[00:01]旧歌词');
    });
  });
}
