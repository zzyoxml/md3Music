import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

/// 一条「标准酷狗歌曲」：顶层带 hash / 歌名 / 专辑 / 歌手标量，
/// 与 `KugouSongDetail.fromJson` 的首选键一一对应。
Map<String, dynamic> standardSong({
  String hash = 'HASH_STD_1',
  String songName = '标准歌曲',
  String albumName = '标准专辑',
}) {
  return <String, dynamic>{
    'hash': hash,
    'songname': songName,
    'album_name': albumName,
    'album_id': 1001,
    'SingerName': '标准歌手',
    'timelength': 210000,
  };
}

void main() {
  group('parseHomeDiscoverSongs', () {
    test('标准信封：{"status":1,"data":{"song_list":[...]}} 解析出歌曲', () {
      // 防的形状：酷狗最常见的 `{status, data:{...}}` 双层信封，歌曲在 data.song_list。
      final songs = parseHomeDiscoverSongs(<String, dynamic>{
        'status': 1,
        'data': <String, dynamic>{
          'song_list': <dynamic>[standardSong()],
        },
      });

      expect(songs, hasLength(1));
      expect(songs.first.hash, 'HASH_STD_1');
      expect(songs.first.songName, '标准歌曲');
      expect(songs.first.albumName, '标准专辑');
    });

    test('无 data 信封：歌曲键直接挂在根对象上也能解析', () {
      // 防的形状：上游偶发不带 `data` 包装（这正是 getRecommendDaily 里
      // `json['data'] as Map? ?? json` 要处理的情形），此时 `body` 回退到根对象。
      final songs = parseHomeDiscoverSongs(<String, dynamic>{
        'status': 1,
        'song_list': <dynamic>[standardSong()],
      });

      expect(songs, hasLength(1));
      expect(songs.first.hash, 'HASH_STD_1');
    });

    test('data 直接是数组：信封本身就是列表时直接当歌曲列表用', () {
      // 防的形状：`data` 键时而是指纹信封、时而直接是数组。数组形态下若仍去
      // 根对象按候选键找，会因根上无任何候选键而返回空。
      final songs = parseHomeDiscoverSongs(<String, dynamic>{
        'status': 1,
        'data': <dynamic>[standardSong()],
      });

      expect(songs, hasLength(1));
      expect(songs.first.hash, 'HASH_STD_1');
    });

    test('data 是数组时优先于根对象上的其它候选键（信封分支先命中）', () {
      // 防的形状：根上同时存在 `data`（数组）与 `song_list`。按契约，`data`
      // 是数组就直接当列表，不该再让 `song_list` 抢走优先级。
      final songs = parseHomeDiscoverSongs(<String, dynamic>{
        'data': <dynamic>[standardSong(hash: 'HASH_FROM_DATA')],
        'song_list': <dynamic>[standardSong(hash: 'HASH_FROM_SONG_LIST')],
      });

      expect(songs, hasLength(1));
      expect(songs.first.hash, 'HASH_FROM_DATA');
    });

    test('根就是数组的形态走不到，签名固定为 Map，用 data 数组形态覆盖', () {
      // 函数签名是 `Map<String, dynamic>`，`[...]` 这样的根数组传不进来，
      // 无从在此用例中直接构造；与「data 是数组」等价的那条路径由上一条覆盖。
      // 这里只断言空 Map 不会抛，作为根数组缺失时的最弱形态。
      final songs = parseHomeDiscoverSongs(<String, dynamic>{});
      expect(songs, isEmpty);
    });

    test('别名兜底：songs / list / info / items 各自都能取到歌曲', () {
      // 防的形状：同一接口不同端点（或上游灰度）用不同键名塞数组。四个别名
      // 逐一单独验证，任一漏掉都会在这里变成空列表。
      final aliases = <String>['songs', 'list', 'info', 'items'];
      for (final key in aliases) {
        final songs = parseHomeDiscoverSongs(<String, dynamic>{
          'data': <String, dynamic>{
            key: <dynamic>[standardSong(hash: 'HASH_$key')],
          },
        });
        expect(songs, hasLength(1), reason: '候选键 $key 应能命中');
        expect(songs.first.hash, 'HASH_$key');
      }
    });

    test('嵌套歌曲形态：album_info / audio_info / Singers 的浅展开生效', () {
      // 防的形状：`/audio` 系接口把 hash、时长塞在 audio_info，专辑塞在
      // album_info，歌手是 Singers 数组。KugouSongDetail.fromJson 内部会把这
      // 几个嵌套对象浅展开到顶层，若解析器在这里自己另起一套映射就会丢字段。
      final songs = parseHomeDiscoverSongs(<String, dynamic>{
        'data': <String, dynamic>{
          'song_list': <dynamic>[
            <String, dynamic>{
              'songname': '嵌套歌曲',
              'album_info': <String, dynamic>{
                'album_name': '嵌套专辑',
                'album_id': 2002,
              },
              'audio_info': <String, dynamic>{
                'hash': 'HASH_NESTED',
                'timelength': 185000,
              },
              'Singers': <dynamic>[
                <String, dynamic>{'name': '嵌套歌手', 'id': 4490},
              ],
            },
          ],
        },
      });

      expect(songs, hasLength(1));
      final song = songs.first;
      // album_info.album_name 浅展开到顶层后被 albumName 命中
      expect(song.albumName, '嵌套专辑');
      // audio_info.hash 浅展开后被 hash 命中
      expect(song.hash, 'HASH_NESTED');
      // Singers[{name,id}] 形态被 artistName / artistId 命中
      expect(song.artistName, '嵌套歌手');
      expect(song.artistId, '4490');
      // audio_info.timelength（毫秒）归一化为秒
      expect(song.duration, 185);
    });

    test('Singers 元素为 {author_name} 形态时退回顶层 SingerName 标量', () {
      // 防的形状：Singers 数组里塞的是 kmr 系的 {author_name, singer_id}，
      // fromJson 只认 Singers 里的 name/id，认不出 author_name，artistName 会
      // 为 null。真实响应同时带顶层 SingerName，故靠它兜住歌手名。
      final songs = parseHomeDiscoverSongs(<String, dynamic>{
        'data': <String, dynamic>{
          'song_list': <dynamic>[
            <String, dynamic>{
              'songname': 'author_name 形态',
              'SingerName': '顶层歌手',
              'Singers': <dynamic>[
                <String, dynamic>{
                  'author_name': '数组内歌手',
                  'singer_id': 4490,
                },
              ],
            },
          ],
        },
      });

      expect(songs, hasLength(1));
      // Singers 内 author_name 未被识别，最终取顶层 SingerName
      expect(songs.first.artistName, '顶层歌手');
    });

    test('空与异常输入全部返回空列表且不抛异常', () {
      // 逐个防的形状：
      // - {}：既无信封也无候选键
      // - {"data":{}}：有信封但信封里没有任何候选键
      // - {"data":{"song_list":[]}}：键命中但数组为空
      // - {"data":{"song_list":"不是数组"}}：键命中但值类型错（硬转会抛）
      // - {"data":{"song_list":[1,2,3]}}：元素全是标量，非 Map 必须跳过
      // - {"data":{"song_list":[null]}}：元素为 null
      final cases = <Map<String, dynamic>>[
        <String, dynamic>{},
        <String, dynamic>{
          'data': <String, dynamic>{},
        },
        <String, dynamic>{
          'data': <String, dynamic>{'song_list': <dynamic>[]},
        },
        <String, dynamic>{
          'data': <String, dynamic>{'song_list': '不是数组'},
        },
        <String, dynamic>{
          'data': <String, dynamic>{
            'song_list': <dynamic>[1, 2, 3],
          },
        },
        <String, dynamic>{
          'data': <String, dynamic>{
            'song_list': <dynamic>[null],
          },
        },
      ];

      for (final json in cases) {
        expect(
          () => parseHomeDiscoverSongs(json),
          returnsNormally,
          reason: '输入 $json 不应抛异常',
        );
        expect(parseHomeDiscoverSongs(json), isEmpty, reason: '输入 $json 应为空');
      }
    });

    test('混合脏数据：只解析出正常歌曲，null/字符串/数字被跳过', () {
      // 防的形状：真实推荐数组里混着占位项（null、错误提示字符串、分页统计
      // 数字）。这些不能整批丢弃，也不能让解析抛异常中断后面正常歌曲。
      final songs = parseHomeDiscoverSongs(<String, dynamic>{
        'data': <String, dynamic>{
          'song_list': <dynamic>[
            null,
            'error: something',
            12345,
            standardSong(hash: 'HASH_VALID'),
            <String, dynamic>{},
          ],
        },
      });

      // 只有真正映射成功的那条留下；空 Map 会映射成各字段为空的歌曲对象，
      // 但它确实是 Map 元素，故保留（fromJson 不抛，也不做语义校验）。
      expect(songs.map((s) => s.hash), contains('HASH_VALID'));
      expect(songs.first.hash, 'HASH_VALID');
    });

    test('候选键优先级：song_list 胜过 songs / list / info / data / items', () {
      // 防的形状：上游同时给多个候选键（常见于信封里既放推荐又放计数/其它分组）。
      // 优先级一旦写错就会取到错误分组，故逐位确认 song_list 最高。
      final songs = parseHomeDiscoverSongs(<String, dynamic>{
        'data': <String, dynamic>{
          'song_list': <dynamic>[standardSong(hash: 'HASH_1')],
          'songs': <dynamic>[standardSong(hash: 'HASH_2')],
          'list': <dynamic>[standardSong(hash: 'HASH_3')],
          'info': <dynamic>[standardSong(hash: 'HASH_4')],
          'data': <dynamic>[standardSong(hash: 'HASH_5')],
          'items': <dynamic>[standardSong(hash: 'HASH_6')],
        },
      });

      expect(songs, hasLength(1));
      expect(songs.first.hash, 'HASH_1');
    });

    test('候选键优先级：songs 胜过 list / info / data / items', () {
      final songs = parseHomeDiscoverSongs(<String, dynamic>{
        'data': <String, dynamic>{
          'songs': <dynamic>[standardSong(hash: 'HASH_2')],
          'list': <dynamic>[standardSong(hash: 'HASH_3')],
          'info': <dynamic>[standardSong(hash: 'HASH_4')],
          'data': <dynamic>[standardSong(hash: 'HASH_5')],
          'items': <dynamic>[standardSong(hash: 'HASH_6')],
        },
      });

      expect(songs.first.hash, 'HASH_2');
    });

    test('候选键优先级：list 胜过 info / data / items', () {
      final songs = parseHomeDiscoverSongs(<String, dynamic>{
        'data': <String, dynamic>{
          'list': <dynamic>[standardSong(hash: 'HASH_3')],
          'info': <dynamic>[standardSong(hash: 'HASH_4')],
          'data': <dynamic>[standardSong(hash: 'HASH_5')],
          'items': <dynamic>[standardSong(hash: 'HASH_6')],
        },
      });

      expect(songs.first.hash, 'HASH_3');
    });

    test('候选键优先级：info 胜过 data / items', () {
      final songs = parseHomeDiscoverSongs(<String, dynamic>{
        'data': <String, dynamic>{
          'info': <dynamic>[standardSong(hash: 'HASH_4')],
          'data': <dynamic>[standardSong(hash: 'HASH_5')],
          'items': <dynamic>[standardSong(hash: 'HASH_6')],
        },
      });

      expect(songs.first.hash, 'HASH_4');
    });

    test('候选键优先级：data 胜过 items（信封内再套一层 data）', () {
      // 防的形状：`{data:{data:[...]}}` 双层 data。前一层是信封、后一层才是
      // 数组，`data` 作为候选键必须排在 `items` 之前。
      final songs = parseHomeDiscoverSongs(<String, dynamic>{
        'data': <String, dynamic>{
          'data': <dynamic>[standardSong(hash: 'HASH_5')],
          'items': <dynamic>[standardSong(hash: 'HASH_6')],
        },
      });

      expect(songs.first.hash, 'HASH_5');
    });

    test('候选键优先级：只有 items 时兜底命中（末位候选键）', () {
      final songs = parseHomeDiscoverSongs(<String, dynamic>{
        'data': <String, dynamic>{
          'items': <dynamic>[standardSong(hash: 'HASH_6')],
        },
      });

      expect(songs.first.hash, 'HASH_6');
    });
  });
}
