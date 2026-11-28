// 钉住「新歌速递」`/top/song` 的真实响应形态，防止日后重构解析器时静默打空。
//
// 已核实的事实（EchoMusic 实测 + 本仓 Rust `kugou_api_server/rust/src/modules/top.rs:182-195`
// 的 `handle_song` 原样透传上游 `/musicadservice/container/v1/newsong_publish`）：
//   响应是 `{status, error_code, data: [ <song>... ]}`——**data 本身就是歌曲数组**，
//   不是 `data.list` / `data.song_list`。因此命中的是 parseHomeDiscoverSongs 的
//   「信封即列表」第一条分支（`if (envelope is List) return take(envelope);`）。
//
// 这里只断言代码**实际**做的事（键优先级、`{size}` 替换、时长归一化），
// 不写"上游大概长这样"的推测；每条都注了依据的源码位置。
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

/// 一条「新歌速递榜面歌曲」：按该接口实测的键名拼写
/// （`songname` / `singername` / `album_sizable_cover` / `time_length` + `timelength`），
/// 与 `KugouSongDetail.fromJson` 的候选键链一一对应。
Map<String, dynamic> newsongSong({
  String hash = 'HASH_NEWSONG_1',
  String songName = '新歌一',
  String singerName = '歌手一',
}) {
  return <String, dynamic>{
    'hash': hash,
    'songname': songName,
    'singername': singerName,
    'album_name': '专辑一',
    'album_id': 3001,
    'songid': 90001,
    'album_sizable_cover': 'http://imge.kugou.com/stdmusic/{size}/cover.jpg',
    // 同一首歌同时给秒（time_length）与毫秒（timelength）两种时长
    'time_length': 210,
    'timelength': 210000,
  };
}

/// 只带最小字段的一条，用于形状（而非字段）用例。
Map<String, dynamic> minimalSong(String hash) {
  return <String, dynamic>{
    'hash': hash,
    'songname': '歌 $hash',
  };
}

void main() {
  group('新歌速递 /top/song 响应形态（parseHomeDiscoverSongs）', () {
    test('data 直接是数组：{status,error_code,data:[歌,歌]} 解析出 2 首', () {
      // 防的形状：本接口的核心形态。**没有** data.list 这一层，若解析器只按
      // 候选键下钻（song_list/songs/list/...）就会在这里取到空列表。
      final songs = parseHomeDiscoverSongs(<String, dynamic>{
        'status': 1,
        'error_code': 0,
        'data': <dynamic>[
          newsongSong(hash: 'HASH_NS_1'),
          newsongSong(hash: 'HASH_NS_2'),
        ],
      });

      expect(songs, hasLength(2));
      expect(songs.map((s) => s.hash), ['HASH_NS_1', 'HASH_NS_2']);
    });

    test('榜面键名拼写：songname / singername 落成 songName / artistName', () {
      // 依据 fromJson：歌名候选链首位是 `songname`；歌手走
      // author_name → SingerName → artist_name → **singername**（末位兜底），
      // 全小写的 `singername` 是新歌榜实际拼写，必须命中。
      final songs = parseHomeDiscoverSongs(<String, dynamic>{
        'data': <dynamic>[newsongSong()],
      });

      expect(songs, hasLength(1));
      final song = songs.first;
      expect(song.songName, '新歌一');
      expect(song.artistName, '歌手一');
      expect(song.albumName, '专辑一');
      expect(song.songId, '90001');
    });

    test('album_sizable_cover 的 {size} 被替换成 400（不保留占位符）', () {
      // 依据 `_resolveArtworkUri`（kugou_models.dart:1832-1837）：
      // 唯一的处理是 `s.replaceAll('{size}', '400')`——**固定 400**，
      // 不是按请求尺寸变化，也不做 URL 校验；空串则整体返回 null。
      final songs = parseHomeDiscoverSongs(<String, dynamic>{
        'data': <dynamic>[newsongSong()],
      });

      final cover = songs.first.artworkUri;
      expect(cover, 'http://imge.kugou.com/stdmusic/400/cover.jpg');
      expect(cover, isNot(contains('{size}')));
    });

    test('album_sizable_cover 为空串时 artworkUri 为 null（不是空字符串）', () {
      // 依据 `_resolveArtworkUri`：`s.isEmpty → null`。UI 侧靠 null 判断
      // 「无封面」，返回 '' 会让 SmartArtworkImage 走空 URL 请求。
      final song = newsongSong();
      song['album_sizable_cover'] = '';
      final songs = parseHomeDiscoverSongs(<String, dynamic>{
        'data': <dynamic>[song],
      });

      expect(songs, hasLength(1));
      expect(songs.first.artworkUri, isNull);
    });

    test('时长：time_length（秒）优先于 timelength（毫秒），两者都归一为秒', () {
      // 依据 fromJson 的时长候选链顺序（kugou_models.dart:632-665）：
      // `time_length` 排在 `timelength` **之前**，故两者同时存在时取 time_length；
      // `_normalizeDuration`（:60-64）只在原值 >10000 时按毫秒除 1000。
      final songs = parseHomeDiscoverSongs(<String, dynamic>{
        'data': <dynamic>[newsongSong()],
      });
      expect(songs.first.duration, 210, reason: 'time_length=210 应先命中');

      // 只给毫秒形态的 timelength：>10000 被判定为毫秒并除以 1000 → 210 秒。
      final msOnly = newsongSong()..remove('time_length');
      final msSongs = parseHomeDiscoverSongs(<String, dynamic>{
        'data': <dynamic>[msOnly],
      });
      expect(msSongs.first.duration, 210);

      // 反证优先级：把 time_length 改成与 timelength 换算后不同的值，
      // 结果必须跟随 time_length（若哪天候选链顺序被调换，这里会红）。
      final conflict = newsongSong()..['time_length'] = 100;
      final conflictSongs = parseHomeDiscoverSongs(<String, dynamic>{
        'data': <dynamic>[conflict],
      });
      expect(conflictSongs.first.duration, 100);
    });

    test('空榜：{status:1} 缺 data / data 为空数组都返回空列表且不抛', () {
      // 防的形状：榜单下线或上游返空时不该让发现页整块崩掉。
      // `{status:1}` —— 无 data，且根上也没有任何候选键。
      // `{status:1,data:[]}` —— data 是空数组，走信封分支取到空。
      for (final json in <Map<String, dynamic>>[
        <String, dynamic>{'status': 1},
        <String, dynamic>{
          'status': 1,
          'data': <dynamic>[],
        },
      ]) {
        expect(
          () => parseHomeDiscoverSongs(json),
          returnsNormally,
          reason: '输入 $json 不应抛异常',
        );
        expect(
          parseHomeDiscoverSongs(json),
          isEmpty,
          reason: '输入 $json 应为空列表',
        );
      }
    });

    test('data 数组里混入非 Map 元素：只跳过它，不牵连同批其余歌曲', () {
      // 依据 `take`：`if (element is! Map<String, dynamic>) continue;`。
      // 上游偶尔在数组里塞占位字符串/null，整批丢弃会让榜面凭空变空。
      final songs = parseHomeDiscoverSongs(<String, dynamic>{
        'data': <dynamic>[
          null,
          'error: something',
          12345,
          minimalSong('HASH_A'),
          minimalSong('HASH_B'),
        ],
      });

      expect(songs, hasLength(2));
      expect(songs.map((s) => s.hash), ['HASH_A', 'HASH_B']);
    });
  });
}
