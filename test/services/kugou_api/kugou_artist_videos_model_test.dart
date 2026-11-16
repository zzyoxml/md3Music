// KugouMvBrief / KugouArtistVideos 纯 fromJson 单测（不碰网络）。
// 钉住实现里的兼容分支：data 数组/对象双口径、list/info/videos/items 别名、
// total 根节点与 data 内双口径、{size} 封面替换、hash 清晰度回落链、
// textOf「空串当 null」，以及解析异常「打印后 rethrow」的真实口径
// （注意：data 是字符串时实现走 else 分支安全返回空，并不抛；
//  真正会抛的是列表字段被上游塞了非 List 值）。
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('KugouArtistVideos.fromJson 列表定位', () {
    test('data 是数组：直接当列表，total 取根节点', () {
      final v = KugouArtistVideos.fromJson({
        'data': [
          {'video_id': 'v1', 'video_name': 'MV1'},
        ],
        'total': 7,
      });
      expect(v.mvs, hasLength(1));
      expect(v.mvs.single.videoId, 'v1');
      expect(v.mvs.single.name, 'MV1');
      expect(v.total, 7);
    });

    test('data 是 Map 且列表在 list', () {
      final v = KugouArtistVideos.fromJson({
        'data': {
          'list': [
            {'video_id': 'v2', 'video_name': 'MV2'},
          ],
        },
        'total': 3,
      });
      expect(v.mvs, hasLength(1));
      expect(v.mvs.single.videoId, 'v2');
      expect(v.total, 3);
    });

    test('data 是 Map 时 info / videos / items 别名都能定位列表', () {
      for (final key in ['info', 'videos', 'items']) {
        final v = KugouArtistVideos.fromJson({
          'data': {
            key: [
              {'video_id': 'v-$key'},
            ],
          },
        });
        expect(v.mvs, hasLength(1), reason: 'list key: $key');
        expect(v.mvs.single.videoId, 'v-$key');
      }
    });
  });

  group('KugouArtistVideos.fromJson total 双口径', () {
    test('total 在根节点', () {
      final v = KugouArtistVideos.fromJson({
        'data': <Object>[],
        'total': 21,
      });
      expect(v.total, 21);
    });

    test('cur_total 也在根节点口径内', () {
      final v = KugouArtistVideos.fromJson({
        'data': <Object>[],
        'cur_total': 5,
      });
      expect(v.total, 5);
    });

    test('total 只在 data Map 里（total / total_count 都认）', () {
      final v1 = KugouArtistVideos.fromJson({
        'data': {
          'list': <Object>[],
          'total': 9,
        },
      });
      expect(v1.total, 9);
      final v2 = KugouArtistVideos.fromJson({
        'data': {
          'list': <Object>[],
          'total_count': 12,
        },
      });
      expect(v2.total, 12);
    });
  });

  group('封面与 hash 解析', () {
    test('{size} 占位符替换为 400', () {
      final mv = KugouMvBrief.fromJson({
        'video_id': 'v1',
        'hdpic': 'http://a/{size}.jpg',
      });
      expect(mv.coverUrl, 'http://a/400.jpg');
      expect(mv.coverUrl, isNot(contains('{size}')));
    });

    test('hdpic 为空串时跳到下一个候选（cover）', () {
      final mv = KugouMvBrief.fromJson({
        'video_id': 'v1',
        'hdpic': '',
        'cover': 'http://b.png',
      });
      expect(mv.coverUrl, 'http://b.png');
    });

    test('hash 回落链：mkv_qhd_hash 优先', () {
      final mv = KugouMvBrief.fromJson({
        'video_id': 'v1',
        'mkv_qhd_hash': 'A',
        'sd_hash': 'B',
        'hash': 'C',
      });
      expect(mv.hash, 'A');
    });

    test('hash 回落链：只有 sd_hash 取 sd_hash', () {
      final mv = KugouMvBrief.fromJson({
        'video_id': 'v1',
        'sd_hash': 'B',
      });
      expect(mv.hash, 'B');
    });

    test('hash 回落链：只有 hash 取 hash', () {
      final mv = KugouMvBrief.fromJson({
        'video_id': 'v1',
        'hash': 'C',
      });
      expect(mv.hash, 'C');
    });

    test('hash 全缺失时为 null', () {
      final mv = KugouMvBrief.fromJson({'video_id': 'v1'});
      expect(mv.hash, isNull);
    });
  });

  group('缺字段 / 脏数据容错', () {
    test('元素缺 video_id 时不抛，且被过滤（mvs 为空）', () {
      final v = KugouArtistVideos.fromJson({
        'data': [<String, dynamic>{}],
      });
      expect(v.mvs, isEmpty);
      expect(v.total, 0);
    });

    test('列表里的非 Map 元素直接跳过', () {
      final v = KugouArtistVideos.fromJson({
        'data': ['x', 3, null],
      });
      expect(v.mvs, isEmpty);
    });
  });

  group('KugouMvBrief 基础字段', () {
    test('timelength 毫秒原样落到 timelengthMs', () {
      final mv = KugouMvBrief.fromJson({
        'video_id': 'v1',
        'timelength': 245000,
      });
      expect(mv.timelengthMs, 245000);
    });

    test('timelength 缺失时回落 duration，再缺省 0', () {
      expect(
        KugouMvBrief.fromJson({
          'video_id': 'v1',
          'duration': 180000,
        }).timelengthMs,
        180000,
      );
      expect(
        KugouMvBrief.fromJson({'video_id': 'v1'}).timelengthMs,
        0,
      );
    });

    test('authorName 别名与「空串当 null」（textOf 闭包）', () {
      expect(
        KugouMvBrief.fromJson({
          'video_id': 'v1',
          'singer_name': '歌手',
        }).authorName,
        '歌手',
      );
      expect(
        KugouMvBrief.fromJson({
          'video_id': 'v1',
          'author_name': '歌手',
        }).authorName,
        '歌手',
      );
      // 钉住空串转 null：上游缺字段常返回 ''，textOf 必须归一成 null
      expect(
        KugouMvBrief.fromJson({
          'video_id': 'v1',
          'author_name': '',
        }).authorName,
        isNull,
      );
    });

    test('publishDate / albumAudioId 别名与空串归一', () {
      final mv = KugouMvBrief.fromJson({
        'video_id': 'v1',
        'publishtime': '2026-01-01',
        'albumaudio_id': 'aa-1',
      });
      expect(mv.publishDate, '2026-01-01');
      expect(mv.albumAudioId, 'aa-1');

      final empty = KugouMvBrief.fromJson({
        'video_id': 'v1',
        'publish_date': '',
        'album_audio_id': '',
      });
      expect(empty.publishDate, isNull);
      expect(empty.albumAudioId, isNull);
    });
  });

  group('解析异常口径（catch 后打印并 rethrow）', () {
    test('data 是字符串：实现走 else 分支安全返回空，不抛', () {
      // 与说明的假设不同：真实实现里 data 为字符串不会炸，
      // rawData 既非 List 也非 Map → list = []，total = 0。
      final v = KugouArtistVideos.fromJson({'data': 'oops'});
      expect(v.mvs, isEmpty);
      expect(v.total, 0);
    });

    test('列表字段是非 List 值时 TypeError 被 rethrow', () {
      expect(
        () => KugouArtistVideos.fromJson({
          'data': {'list': 'not-a-list'},
        }),
        throwsA(isA<TypeError>()),
      );
    });
  });
}
