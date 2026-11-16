import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';

/// 构造测试用歌曲（必填项之外的字段全部走默认值）。
Song _song({
  required String title,
  String artist = '',
  String album = '',
}) =>
    Song(
      id: 'test-id',
      title: title,
      artist: artist,
      album: album,
      duration: const Duration(seconds: 254),
    );

void main() {
  group('formatSongFullCopyText（播放页长按复制：歌名 歌手-专辑）', () {
    test('标准三段：晴天 周杰伦-叶惠美', () {
      final song = _song(title: '晴天', artist: '周杰伦', album: '叶惠美');
      expect(formatSongFullCopyText(song), '晴天 周杰伦-叶惠美');
    });

    test('本地文件名歌名剥离扩展名后缀', () {
      final song = _song(title: '晴天.mp3', artist: '周杰伦', album: '叶惠美');
      expect(formatSongFullCopyText(song), '晴天 周杰伦-叶惠美');
    });

    test('专辑空串 → 省略专辑段，不留孤立横线', () {
      final song = _song(title: '晴天', artist: '周杰伦', album: '');
      expect(formatSongFullCopyText(song), '晴天 周杰伦');
    });

    test('专辑为「未知专辑」占位 → 省略专辑段', () {
      final song = _song(title: '晴天', artist: '周杰伦', album: '未知专辑');
      expect(formatSongFullCopyText(song), '晴天 周杰伦');
    });

    test('歌手空串 → 省略歌手段，直接拼专辑', () {
      final song = _song(title: '晴天', artist: '', album: '叶惠美');
      expect(formatSongFullCopyText(song), '晴天 叶惠美');
    });

    test('歌手「未知歌手」/「未知艺术家」占位 → 均省略', () {
      expect(
        formatSongFullCopyText(
            _song(title: '晴天', artist: '未知歌手', album: '叶惠美')),
        '晴天 叶惠美',
      );
      expect(
        formatSongFullCopyText(
            _song(title: '晴天', artist: '未知艺术家', album: '叶惠美')),
        '晴天 叶惠美',
      );
    });

    test('多歌手连写原样保留（不拆分）', () {
      final song =
          _song(title: '珊瑚海', artist: '周杰伦、Lara', album: '依然范特西');
      expect(formatSongFullCopyText(song), '珊瑚海 周杰伦、Lara-依然范特西');
    });

    test('仅有歌名：无歌手无专辑', () {
      final song = _song(title: '晴天');
      expect(formatSongFullCopyText(song), '晴天');
    });

    test('歌名缺失：退化拼可用段', () {
      expect(
        formatSongFullCopyText(_song(title: '', artist: '周杰伦', album: '叶惠美')),
        '周杰伦-叶惠美',
      );
      expect(
        formatSongFullCopyText(_song(title: '', artist: '周杰伦')),
        '周杰伦',
      );
    });

    test('三段全缺 → 空串（调用方不写剪贴板）', () {
      final song = _song(title: '', artist: '未知歌手', album: '');
      expect(formatSongFullCopyText(song), isEmpty);
    });

    test('各段首尾空白被裁剪', () {
      final song = _song(title: ' 晴天 ', artist: ' 周杰伦 ', album: ' 叶惠美 ');
      expect(formatSongFullCopyText(song), '晴天 周杰伦-叶惠美');
    });
  });

  group('isUnknownAlbum', () {
    test('null / 空串 / 未知专辑 判为未知', () {
      expect(isUnknownAlbum(null), isTrue);
      expect(isUnknownAlbum(''), isTrue);
      expect(isUnknownAlbum('  '), isTrue);
      expect(isUnknownAlbum('未知专辑'), isTrue);
    });

    test('正常专辑名不为未知', () {
      expect(isUnknownAlbum('叶惠美'), isFalse);
    });
  });
}
