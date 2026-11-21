import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/listen_together_provider.dart';
import 'package:md3music/services/kugou_api/listen_together_models.dart';

/// 房间曲目构造（与 listen_together_sync_test.dart 同款）。
RoomSong _roomSong(String hash, {String mixSongId = ''}) => RoomSong(
      hash: hash,
      originalHash: '',
      mixSongId: mixSongId,
      name: '房间歌',
      singer: '歌手',
      durationSeconds: 1,
      coverUrl: '',
      orderUserId: '',
    );

const _online = Song(
  id: 'HASH1',
  title: '在线歌',
  artist: '歌手',
  album: '',
  duration: Duration(seconds: 60),
  isOnline: true,
  albumAudioId: 'MIX1',
);

const _local = Song(
  id: 'local_/a.mp3',
  title: '本地歌',
  artist: '歌手',
  album: '',
  duration: Duration(seconds: 60),
  isOnline: false,
  localPath: '/a.mp3',
);

/// 在线歌曲在播放中被回写本地缓存路径后的形态（RoomSong.fromSong 同样不给 hash）。
const _onlineWithLocalPath = Song(
  id: 'HASH1',
  title: '在线歌',
  artist: '歌手',
  album: '',
  duration: Duration(seconds: 60),
  isOnline: true,
  albumAudioId: 'MIX1',
  localPath: '/cache/a.mp3',
);

void main() {
  group('canOrderSongIntoRoom（房间可上报身份）', () {
    test('在线歌曲有 hash → 可点歌', () {
      expect(canOrderSongIntoRoom(_online), isTrue);
    });

    test('本地文件无 hash → 不可点歌', () {
      expect(canOrderSongIntoRoom(_local), isFalse);
    });

    test('在线但已回写 localPath → 不可点歌', () {
      expect(canOrderSongIntoRoom(_onlineWithLocalPath), isFalse);
    });
  });

  group('shouldPromptGuestPlay（真值表）', () {
    bool call({
      bool inRoom = true,
      bool isOwner = false,
      bool isTakeoverTarget = false,
      bool canOrder = true,
    }) =>
        shouldPromptGuestPlay(
          inRoom: inRoom,
          isOwner: isOwner,
          isTakeoverTarget: isTakeoverTarget,
          canOrder: canOrder,
        );

    test('四个前置条件全部满足 → 弹窗', () {
      expect(call(), isTrue);
    });

    test('不在房间（含会话已关闭）→ 不弹窗', () {
      expect(call(inRoom: false), isFalse);
    });

    test('自己是房主 → 不弹窗（房主有自己的播放守卫）', () {
      expect(call(isOwner: true), isFalse);
    });

    test('目标曲目是房间正在装载的接管曲目 → 不弹窗', () {
      expect(call(isTakeoverTarget: true), isFalse);
    });

    test('本地歌曲不可点歌 → 不弹窗（维持既有直接脱离）', () {
      expect(call(canOrder: false), isFalse);
    });

    test('「是否已脱离」不参与判定 —— 已脱离态同样弹窗', () {
      // 该参数刻意不存在：一旦引入，已脱离的听众会永久失去「申请点歌」入口。
      // 这里用 isTakeoverTarget=false + canOrder=true 的组合锁住「已脱离态仍弹窗」
      // 所依赖的两个条件（playbackDetached 未出现在入参里）。
      expect(call(), isTrue);
    });
  });

  group('isTakeoverTargetSong（身份判定，与装载时长无关）', () {
    test('takeover 为 null → 不是接管目标', () {
      expect(
        isTakeoverTargetSong(takeover: null, song: _online),
        isFalse,
      );
    });

    test('hash 命中 → 是接管目标', () {
      expect(
        isTakeoverTargetSong(takeover: _roomSong('HASH1'), song: _online),
        isTrue,
      );
    });

    test('hash 大小写不同仍命中（上游身份错位兜底）', () {
      expect(
        isTakeoverTargetSong(takeover: _roomSong('hash1'), song: _online),
        isTrue,
      );
    });

    test('mixSongId 命中 → 是接管目标', () {
      // 用 hash 完全不同的条目，只靠 mixSongId 命中
      final takeover = RoomSong(
        hash: 'OTHER',
        originalHash: '',
        mixSongId: 'MIX1',
        name: '',
        singer: '',
        durationSeconds: 0,
        coverUrl: '',
        orderUserId: '',
      );
      expect(isTakeoverTargetSong(takeover: takeover, song: _online), isTrue);
    });

    test('本地歌曲永远不会命中任何房间曲目', () {
      expect(
        isTakeoverTargetSong(takeover: _roomSong('HASH1'), song: _local),
        isFalse,
      );
    });
  });
}
