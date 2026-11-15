import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/mv_models.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';

/// MV 音频兜底的纯逻辑单测：MV 候选解析 / 最佳曲库 MV 筛选 / 播放地址提取。
///
/// 用例集对齐 EchoMusic `tests/mv-audio-fallback.test.mjs`。
/// 说明：项目未引入 mock 框架，`getMvCandidates` / `getVideoUrls` /
/// `resolveMvAudioUrls` 内部的 `_get` 不可注入，故只断言抽出的静态纯函数。
void main() {
  Map<String, dynamic> official({
    Object? videoId = 1,
    Object? isRecommend = 0,
    Object? duration = 200,
    Map<String, dynamic>? h264,
    Map<String, dynamic>? h265,
    Map<String, dynamic>? mkv,
  }) => <String, dynamic>{
    'video_id': videoId,
    'is_publish': 1,
    'is_ugc': 0,
    'is_short': 0,
    'is_other': 0,
    'is_recommend': isRecommend,
    'duration': duration,
    'h264': h264 ?? {'hd_hash': 'H264A', 'hd_filesize': 300},
    'h265': h265 ?? {'hd_hash': 'H265A', 'hd_filesize': 200},
    'mkv': ?mkv,
  };

  Map<String, dynamic> payload(List<Map<String, dynamic>> records) =>
      <String, dynamic>{'status': 1, 'data': [records]};

  group('parseMvCandidates', () {
    test('二维数组取 data[0] 的记录数组，全部解析', () {
      final candidates = KugouApiClient.parseMvCandidates(
        payload([official(videoId: 1), official(videoId: 2)]),
      );
      expect(candidates.map((c) => c.videoId), ['1', '2']);
    });

    test('兼容一维数组与单对象形态', () {
      final oneDim = KugouApiClient.parseMvCandidates(
        <String, dynamic>{
          'data': [official(videoId: 9)],
        },
      );
      expect(oneDim.single.videoId, '9');

      final single = KugouApiClient.parseMvCandidates(
        <String, dynamic>{'data': official(videoId: 8)},
      );
      expect(single.single.videoId, '8');
    });

    test('duration > 1000 视为毫秒，归一为秒', () {
      final candidates = KugouApiClient.parseMvCandidates(
        payload([official(duration: 200000)]),
      );
      expect(candidates.single.durationSeconds, 200);
    });

    test('片源按 fhd/hd/qhd/sd/ld 收集 h264/h265/mkv 的 hash 与 filesize', () {
      final candidates = KugouApiClient.parseMvCandidates(
        payload([
          official(
            h264: {'hd_hash': 'H264HD', 'hd_filesize': 300},
            h265: {'fhd_hash': 'H265FHD', 'fhd_filesize': 500},
            mkv: {'sd_hash': 'MKVSD', 'sd_filesize': 100},
          ),
        ]),
      );
      final sources = candidates.single.sources;
      expect(sources.map((s) => s.hash).toSet(), {'H264HD', 'H265FHD', 'MKVSD'});
      final h264 = sources.firstWhere((s) => s.hash == 'H264HD');
      expect(h264.codec, 'H.264');
      expect(h264.label, '720P');
      expect(h264.size, 300);
      expect(sources.firstWhere((s) => s.hash == 'H265FHD').label, '1080P');
      expect(sources.firstWhere((s) => s.hash == 'MKVSD').codec, 'MKV');
    });

    test('不同编码映射里的同 hash 片源去重', () {
      final candidates = KugouApiClient.parseMvCandidates(
        payload([
          official(
            h264: {'hd_hash': 'SAME', 'hd_filesize': 10},
            h265: {'hd_hash': 'SAME', 'hd_filesize': 20},
          ),
        ]),
      );
      expect(candidates.single.sources.map((s) => s.hash.toLowerCase()).toSet(), {
        'same',
      });
    });

    test('无数据返回空列表', () {
      expect(KugouApiClient.parseMvCandidates(<String, dynamic>{}), isEmpty);
    });
  });

  group('pickCatalogMv', () {
    test('排除 UGC / 平台短视频 / 其他版本 / 未发布 / 0 时长 / 无片源 / 标记缺失', () {
      final invalid = <Map<String, dynamic>>[
        {...official(), 'is_ugc': 1},
        {...official(), 'is_short': 4},
        {...official(), 'is_other': 1},
        {...official(), 'is_publish': 0},
        {...official(), 'duration': 0},
        {...official(), '__status': 0},
        {...official(), 'is_ugc': null},
        {...official(), 'is_short': null},
        {...official(), 'is_other': null},
        (official()..remove('is_ugc')),
        (official()..remove('is_short')),
        (official()..remove('is_other')),
        (official()..remove('h264')..remove('h265')),
      ];
      for (final record in invalid) {
        final candidates = KugouApiClient.parseMvCandidates(payload([record]));
        expect(
          KugouApiClient.pickCatalogMv(candidates),
          isNull,
          reason: 'record=$record',
        );
      }
    });

    test('合法集合按 is_recommend 降序取首个', () {
      final picked = KugouApiClient.pickCatalogMv(
        KugouApiClient.parseMvCandidates(
          payload([
            official(videoId: 1, isRecommend: 0),
            official(videoId: 2, isRecommend: 1),
            {...official(videoId: 3), 'is_ugc': 1},
          ]),
        ),
      );
      expect(picked?.videoId, '2');
    });

    test('空候选返回 null', () {
      expect(KugouApiClient.pickCatalogMv(const <MvCandidate>[]), isNull);
    });
  });

  group('extractVideoUrls', () {
    test('收集 downurl/url/play_url/backupdownurl，丢弃非 http 条目并去重', () {
      final json = <String, dynamic>{
        'status': 1,
        'data': <String, dynamic>{
          'abcd': <String, dynamic>{
            'downurl': 'https://mv.test/a.mp4',
            'url': 'http://mv.test/b.mp4',
            'play_url': 'http://mv.test/c.mp4',
            'backupdownurl': <dynamic>[
              'http://backup.test/d.mp4',
              'https://mv.test/a.mp4',
              'file:///bad',
              null,
            ],
          },
        },
      };
      expect(KugouApiClient.extractVideoUrls(json, 'ABCD'), <String>[
        'https://mv.test/a.mp4',
        'http://mv.test/b.mp4',
        'http://mv.test/c.mp4',
        'http://backup.test/d.mp4',
      ]);
    });

    test('hash 未命中时回落 data 首项', () {
      final json = <String, dynamic>{
        'data': <String, dynamic>{
          'zzzz': <String, dynamic>{'downurl': 'http://mv.test/first.mp4'},
        },
      };
      expect(KugouApiClient.extractVideoUrls(json, 'nope'), <String>[
        'http://mv.test/first.mp4',
      ]);
    });

    test('data 非 Map 返回空', () {
      expect(
        KugouApiClient.extractVideoUrls(<String, dynamic>{'data': <dynamic>[]}, 'x'),
        isEmpty,
      );
      expect(
        KugouApiClient.extractVideoUrls(<String, dynamic>{}, 'x'),
        isEmpty,
      );
    });
  });
}
