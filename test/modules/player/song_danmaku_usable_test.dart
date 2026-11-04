import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/player/widgets/song_danmaku_host.dart';

/// 歌曲弹幕的准入判定：只有「在线 + 有真 hash」的歌曲才有弹幕池。
///
/// 这是弹幕层与「评论/弹幕」档位切换唯一的开关来源，判错会让本地歌曲去请求
/// 一个不存在的池（取数空、发送必然失败）。
Song _song({required String id, bool isOnline = true}) => Song(
      id: id,
      title: '标题',
      artist: '歌手',
      album: '专辑',
      duration: const Duration(seconds: 200),
      isOnline: isOnline,
    );

void main() {
  test('在线歌曲：Song.id 就是酷狗 hash，可用', () {
    expect(songDanmakuUsable(_song(id: '043C4DA61870CD55C1240F0FA6744C94')), isTrue);
  });

  test('本地歌曲（含未匹配的 local_ 占位 id）与空 id：不可用', () {
    expect(songDanmakuUsable(_song(id: 'ABC', isOnline: false)), isFalse);
    expect(songDanmakuUsable(_song(id: 'local_/sd/a.mp3')), isFalse);
    expect(songDanmakuUsable(_song(id: '')), isFalse);
  });

  test('null 歌曲：不可用', () {
    expect(songDanmakuUsable(null), isFalse);
  });
}
