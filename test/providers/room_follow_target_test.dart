import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/providers/room_follow_target.dart';
import 'package:md3music/services/kugou_api/listen_together_models.dart';

RoomSong _song({String hash = 'AAA', String original = '', String mix = '9'}) => RoomSong(
      hash: hash,
      originalHash: original,
      mixSongId: mix,
      name: 'n',
      singer: 's',
      durationSeconds: 1,
      coverUrl: '',
      orderUserId: '',
    );

PlayerSyncState _remote({String hash = 'AAA', String original = '', String mix = '9'}) =>
    PlayerSyncState(
      hash: hash,
      originalHash: original,
      mixSongId: mix,
      isPlaying: true,
      progressMs: 0,
      durationMs: 0,
      listVersion: '',
      updatedAtMs: 0,
    );

void main() {
  group('resolveFollowTarget', () {
    test('命中歌单 → 返回歌单条目并标记 fromPlaylist', () {
      final t = resolveFollowTarget(playlist: [_song()], remote: _remote());
      expect(t.fromPlaylist, isTrue);
      expect(t.song.name, 'n');
    });

    test('未命中 → 占位条目（身份来自远端、元数据为空），不修改入参歌单', () {
      final playlist = <RoomSong>[];
      final t = resolveFollowTarget(playlist: playlist, remote: _remote(hash: 'ZZZ'));
      expect(t.fromPlaylist, isFalse);
      expect(t.song.hash, 'ZZZ');
      expect(t.song.name, isEmpty);
      expect(playlist, isEmpty, reason: '权威歌单不得被本地占位条目污染');
    });
  });

  group('splitEnriched', () {
    test('有占位条目时首项归占位，其余归歌单', () {
      final r = splitEnriched(enriched: [_song(hash: 'P'), _song(hash: 'A')], hasPending: true);
      expect(r.pending!.hash, 'P');
      expect(r.playlist.map((s) => s.hash), ['A']);
    });

    test('无占位条目时整表归歌单', () {
      final r = splitEnriched(enriched: [_song(hash: 'A')], hasPending: false);
      expect(r.pending, isNull);
      expect(r.playlist.map((s) => s.hash), ['A']);
      expect(r.extra, isEmpty);
    });

    test('带附加组（房主待处理点歌）→ 三组各自归位，点歌不混进歌单', () {
      final r = splitEnriched(
        enriched: [_song(hash: 'P'), _song(hash: 'A'), _song(hash: 'O')],
        hasPending: true,
        extraCount: 1,
      );
      expect(r.pending!.hash, 'P');
      expect(r.playlist.map((s) => s.hash), ['A']);
      expect(r.extra.map((s) => s.hash), ['O']);
    });

    test('无占位 + 附加组 → 仅歌单与附加组', () {
      final r = splitEnriched(
        enriched: [_song(hash: 'A'), _song(hash: 'O')],
        hasPending: false,
        extraCount: 1,
      );
      expect(r.pending, isNull);
      expect(r.playlist.map((s) => s.hash), ['A']);
      expect(r.extra.map((s) => s.hash), ['O']);
    });

    test('extraCount 超长时钳制，不抛 RangeError', () {
      final r = splitEnriched(
        enriched: [_song(hash: 'A')],
        hasPending: false,
        extraCount: 5,
      );
      expect(r.playlist, isEmpty);
      expect(r.extra.map((s) => s.hash), ['A']);
    });

    test('空入参 → 三组皆空', () {
      final r = splitEnriched(enriched: const [], hasPending: true, extraCount: 1);
      expect(r.pending, isNull);
      expect(r.playlist, isEmpty);
      expect(r.extra, isEmpty);
    });
  });

  group('OrderSongEntry.copyWithSong', () {
    test('替换歌曲保留请求人身份字段', () {
      final entry = OrderSongEntry(
        song: _song(hash: 'AAA'),
        orderUserId: '1001',
        orderNickname: '点歌的人',
      );
      final enriched = _song(hash: 'AAA');
      final next = entry.copyWithSong(enriched);
      expect(identical(next.song, enriched), isTrue);
      expect(next.orderUserId, '1001');
      expect(next.orderNickname, '点歌的人');
    });
  });
}
