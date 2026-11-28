import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/player_provider.dart';

/// Lyricon 推送去重签名。
///
/// 回归背景：一起听跟随端起播时只有 hash 身份，`RoomSong.toSong()` 把空标题
/// 兜底成「未知歌曲」先推给 Lyricon；真实元数据由后台富化补齐后经
/// `updateCurrentSongMetadata` 回写，而该回写**刻意保持 id 不变**。
/// 若去重只看 id，这次回写会被判为「无变化」拦掉，Lyricon 整首歌停在占位标题。
///
/// 因此这里的核心不变量是：**id 相同但元数据变化，签名必须不同**。
void main() {
  Song build({
    String id = 'HASH_A',
    String title = '桃花诺',
    String artist = 'G.E.M.邓紫棋',
    String? artworkUri = 'https://img/cover.jpg',
  }) {
    return Song(
      id: id,
      title: title,
      artist: artist,
      album: '专辑',
      duration: const Duration(seconds: 219),
      artworkUri: artworkUri,
      isOnline: true,
    );
  }

  group('buildLyriconSongSignature', () {
    test('null 歌曲返回 null 签名', () {
      expect(buildLyriconSongSignature(null), isNull);
    });

    test('完全相同元数据 → 签名相同（保留原有防抖语义）', () {
      final a = buildLyriconSongSignature(build());
      final b = buildLyriconSongSignature(build());
      expect(a, b);
    });

    test('一起听核心场景：id 不变但标题从占位变真实 → 签名不同', () {
      final placeholder = buildLyriconSongSignature(
        build(title: '未知歌曲', artist: '未知歌手', artworkUri: null),
      );
      final enriched = buildLyriconSongSignature(build());

      expect(
        placeholder,
        isNot(enriched),
        reason: 'id 相同、仅元数据变化时必须重推，否则 Lyricon 永远停在占位标题',
      );
    });

    test('仅歌手变化 → 签名不同', () {
      final before = buildLyriconSongSignature(build(artist: '未知歌手'));
      final after = buildLyriconSongSignature(build());
      expect(before, isNot(after));
    });

    test('仅封面变化（含 null → 有值）→ 签名不同', () {
      final noCover = buildLyriconSongSignature(build(artworkUri: null));
      final withCover = buildLyriconSongSignature(build());
      expect(noCover, isNot(withCover));
    });

    test('仅 id 变化 → 签名不同（切歌必须推送）', () {
      final a = buildLyriconSongSignature(build(id: 'HASH_A'));
      final b = buildLyriconSongSignature(build(id: 'HASH_B'));
      expect(a, isNot(b));
    });

    test('元数据内含分隔符时会碰撞（已知局限，真实数据不会触发）', () {
      // 诚实记录局限：分隔符拼接法无法区分「字段内的分隔符」与「字段边界」。
      // 这两组元数据会得到同一签名：
      //   标题 'A\u0000B' + 歌手 'C'  ==  标题 'A' + 歌手 'B\u0000C'
      // 之所以不影响实际功能：歌曲元数据来自酷狗接口，标题/歌手是普通文本，
      // 不会包含 U+0000 这个控制字符。
      final forged = buildLyriconSongSignature(
        build(title: 'A\u0000B', artist: 'C'),
      );
      final genuine = buildLyriconSongSignature(
        build(title: 'A', artist: 'B\u0000C'),
      );
      expect(forged, genuine);

      // 正常元数据（无控制字符）不会因此误判：字段边界始终可区分
      expect(
        buildLyriconSongSignature(build(title: 'AB', artist: 'C')),
        isNot(buildLyriconSongSignature(build(title: 'A', artist: 'BC'))),
      );
    });

    test('position tick 场景：同一首歌重复构造签名恒定', () {
      final first = buildLyriconSongSignature(build());
      for (var i = 0; i < 5; i++) {
        expect(buildLyriconSongSignature(build()), first);
      }
    });
  });
}
