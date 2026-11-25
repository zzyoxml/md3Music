import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/player_provider.dart';

void main() {
  test('已知播放错误映射为可操作的本地化文案', () {
    expect(safePlaybackErrorMessage('无法获取播放链接'), '无法获取播放链接，请重试');
    expect(safePlaybackErrorMessage('该章节为 听书VIP单独付费内容'), '该听书章节需要单独购买');
  });

  test('原始异常、签名URL和未知平台错误不会进入用户界面', () {
    expect(
      safePlaybackErrorMessage(
        'DioException: https://media.example/song?signature=secret',
      ),
      '播放失败，请重试',
    );
    expect(safePlaybackErrorMessage(null), isNull);
  });

  test('在线歌曲可以明确移除失效URL，同时保留歌曲身份和元数据', () {
    final song = Song(
      id: 'online-1',
      title: '在线曲',
      artist: '歌手',
      album: '专辑',
      duration: const Duration(minutes: 3),
      url: 'https://media.example/expired?signature=secret',
      isOnline: true,
    );

    final retried = song.copyWith(clearUrl: true);

    expect(retried.url, isNull);
    expect(retried.id, song.id);
    expect(retried.title, song.title);
    expect(retried.isOnline, isTrue);
  });
}
