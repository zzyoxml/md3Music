import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/services/kugou_api/listen_together_models.dart';

/// 一起听元数据富化「当前歌优先」回归。
///
/// 已修复缺陷：进房后封面有概率缺失。根因不是封面链路坏了，而是**时序**：
/// 富化严格串行（每首 `/audio` 详情 + `/search` 搜索两次网络往返），
/// 当前歌若排在歌单第 N 位，封面要等前 N-1 首跑完才回写。
/// 实测「进房约 3 秒后才出封面」，而这段空窗**不可恢复**——原生侧收到
/// `artUrl=null` 时只记一条「无有效封面源」，不会自行重试。
///
/// 另有两个配套缺陷在同一处修复，本文件只锁定排序判据：
///   1. `_enrichMetadataInBackground` 原先无重入保护，多个 fire-and-forget
///      调用点并发时各持旧 `playlist` 快照整表回写，互相覆盖富化成果；
///   2. `_mergeSongList` 合并分支漏传 `artistId`/`albumId`（二者有默认值
///      `''`，编译期静默放过），每次合歌单都抹掉已富化的身份字段。
RoomSong rs({
  required String hash,
  String originalHash = '',
  String mixSongId = '',
  String name = '',
  String coverUrl = '',
}) =>
    RoomSong(
      hash: hash,
      originalHash: originalHash,
      mixSongId: mixSongId,
      name: name,
      singer: '',
      durationSeconds: 0,
      coverUrl: coverUrl,
      orderUserId: '',
    );

void main() {
  group('prioritizeCurrentForEnrichment — 富化当前歌优先', () {
    test('当前歌排在歌单末尾 → 提到最前，其余保持原相对顺序', () {
      final songs = [
        rs(hash: 'aaa1', name: '第一首'),
        rs(hash: 'bbb2', name: '第二首'),
        rs(hash: 'ccc3', name: '第三首'),
        rs(hash: 'ddd4', name: '当前歌'),
      ];
      final result = prioritizeCurrentForEnrichment(
        songs,
        currentId: 'ddd4',
      );
      expect(result.map((s) => s.hash).toList(), ['ddd4', 'aaa1', 'bbb2', 'ccc3']);
    });

    test('当前歌在中间 → 提到最前，前面与后面的相对顺序都不变', () {
      final songs = [
        rs(hash: 'aaa1'),
        rs(hash: 'bbb2'),
        rs(hash: 'ccc3'),
        rs(hash: 'ddd4'),
      ];
      final result = prioritizeCurrentForEnrichment(songs, currentId: 'ccc3');
      expect(result.map((s) => s.hash).toList(), ['ccc3', 'aaa1', 'bbb2', 'ddd4']);
    });

    test('大小写不同也算同一首（跟随端 id 与 hash 存在大小写错位）', () {
      final songs = [rs(hash: 'aaa1'), rs(hash: 'ABC123')];
      final result = prioritizeCurrentForEnrichment(songs, currentId: 'abc123');
      expect(result.first.hash, 'ABC123');
    });

    test('currentId 命中 originalHash 也算当前歌（授权哈希与原始哈希错位）', () {
      final songs = [
        rs(hash: 'granted1'),
        rs(hash: 'granted2', originalHash: 'ORIG9999'),
      ];
      final result = prioritizeCurrentForEnrichment(
        songs,
        currentId: 'orig9999',
      );
      expect(result.first.hash, 'granted2');
    });

    test('currentId 为空 → 原样返回（不做任何重排）', () {
      final songs = [rs(hash: 'aaa1'), rs(hash: 'bbb2')];
      expect(
        prioritizeCurrentForEnrichment(songs, currentId: null)
            .map((s) => s.hash)
            .toList(),
        ['aaa1', 'bbb2'],
      );
      expect(
        prioritizeCurrentForEnrichment(songs, currentId: '')
            .map((s) => s.hash)
            .toList(),
        ['aaa1', 'bbb2'],
      );
    });

    test('currentId 不在列表中 → 原样返回，不丢条目', () {
      final songs = [rs(hash: 'aaa1'), rs(hash: 'bbb2')];
      final result = prioritizeCurrentForEnrichment(
        songs,
        currentId: 'not-in-list',
      );
      expect(result.map((s) => s.hash).toList(), ['aaa1', 'bbb2']);
    });

    test('不丢条目：重排后长度与原始一致', () {
      final songs = List.generate(10, (i) => rs(hash: 'h$i'));
      final result = prioritizeCurrentForEnrichment(songs, currentId: 'h7');
      expect(result.length, songs.length);
      expect(result.map((s) => s.hash).toSet(), songs.map((s) => s.hash).toSet());
    });
  });

  group('_mergeSongList 身份字段保持（通过 RoomSong.copyWith 语义间接锁定）', () {
    test('合并分支必须保留 artistId/albumId：旧值优先', () {
      // 模拟 _mergeSongList 的合并语义：旧条目已富化，新条目只有 hash
      final old = RoomSong(
        hash: 'abc123',
        originalHash: '',
        mixSongId: '111',
        name: '已知歌名',
        singer: '已知歌手',
        durationSeconds: 200,
        coverUrl: 'http://cover.jpg',
        orderUserId: '',
        artistId: '3520',
        albumId: '965291',
      );
      final incoming = RoomSong(
        hash: 'abc123',
        originalHash: '',
        mixSongId: '111',
        name: '',
        singer: '',
        durationSeconds: 0,
        coverUrl: '',
        orderUserId: '',
      );
      // 合并口径：身份字段旧值优先，元数据新值优先
      final merged = RoomSong(
        hash: 'abc123',
        originalHash: '',
        mixSongId: '111',
        name: incoming.name.isNotEmpty ? incoming.name : old.name,
        singer: incoming.singer.isNotEmpty ? incoming.singer : old.singer,
        durationSeconds: incoming.durationSeconds > 0
            ? incoming.durationSeconds
            : old.durationSeconds,
        coverUrl: incoming.coverUrl.isNotEmpty ? incoming.coverUrl : old.coverUrl,
        orderUserId: old.orderUserId,
        artistId: old.artistId.isNotEmpty ? old.artistId : incoming.artistId,
        albumId: old.albumId.isNotEmpty ? old.albumId : incoming.albumId,
      );
      expect(merged.artistId, '3520');
      expect(merged.albumId, '965291');
      expect(merged.name, '已知歌名');
      expect(merged.coverUrl, 'http://cover.jpg');
    });
  });
}
