import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/widgets/song_menu_info_badges.dart';

Song _onlineSong({String id = 'abc123HASH', String? albumId}) => Song(
      id: id,
      title: '测试歌曲',
      artist: '测试歌手',
      album: '测试专辑',
      duration: const Duration(minutes: 3, seconds: 45),
      isOnline: true,
      albumId: albumId,
    );

Song _localSong({String? quality, String? path}) => Song(
      id: 'local-1',
      title: '本地歌曲',
      artist: '歌手',
      album: '专辑',
      duration: const Duration(minutes: 2),
      localPath: path,
      quality: quality,
    );

Map<String, dynamic> _privilegeResp({
  List<Map<String, dynamic>>? relateGoods,
  List<Map<String, dynamic>>? qualityVip,
  int? privilege,
  int? payType,
  int? audioDurationMs,
}) {
  // 响应结构对齐 EchoMusic：data[0] 是歌曲记录；quality_vip 在响应顶层
  // （与 data 平级），按 hash 匹配逐音质权益。
  return {
    'status': 1,
    'data': [
      {
        'hash': 'abc123HASH',
        'privilege': ?privilege,
        'pay_type': ?payType,
        'relate_goods': ?relateGoods,
        'audio_info': {
          'duration': ?audioDurationMs,
        },
      },
    ],
    'quality_vip': ?qualityVip,
  };
}

void main() {
  group('parsePrivilegeLiteResponse', () {
    test('status 非 1 或 data 为空返回 null', () {
      expect(parsePrivilegeLiteResponse({'status': 0, 'data': []}, 'h'), isNull);
      expect(parsePrivilegeLiteResponse({'status': 1, 'data': []}, 'h'), isNull);
      expect(parsePrivilegeLiteResponse(null, 'h'), isNull);
    });

    test('歌级 privilege+pay_type：VIP / 付费 / 无版权 / 不可用', () {
      expect(
        parsePrivilegeLiteResponse(
            _privilegeResp(privilege: 10, payType: 3), 'abc123HASH')!.vipLabel,
        'VIP',
      );
      expect(
        parsePrivilegeLiteResponse(
            _privilegeResp(privilege: 10, payType: 2), 'abc123HASH')!.vipLabel,
        '付费',
      );
      expect(
        parsePrivilegeLiteResponse(_privilegeResp(privilege: 5), 'abc123HASH')!
            .vipLabel,
        '无版权',
      );
      expect(
        parsePrivilegeLiteResponse(_privilegeResp(privilege: 40), 'abc123HASH')!
            .vipLabel,
        '不可用',
      );
      // 免费歌曲（privilege=8）无 VIP 标签
      expect(
        parsePrivilegeLiteResponse(
            _privilegeResp(privilege: 8, audioDurationMs: 225000), 'abc123HASH')!
            .vipLabel,
        isNull,
      );
    });

    test('relate_goods 推最高音质档', () {
      SongMenuInfo infoOf(List<Map<String, dynamic>> goods) =>
          parsePrivilegeLiteResponse(_privilegeResp(relateGoods: goods), 'h')!;

      expect(
        infoOf([
          {'quality': '320'},
          {'quality': 'flac'},
        ]).qualityLabel,
        'SQ',
      );
      expect(
        infoOf([
          {'quality': '320'},
          {'quality': 'flac'},
          {'quality': 'high'},
        ]).qualityLabel,
        'Hi-Res',
      );
      expect(
        infoOf([
          {'quality': 'high'},
          {'quality': 'viper_tape'},
        ]).qualityLabel,
        '母带',
      );
      expect(
        infoOf([
          {'quality': '320'},
        ]).qualityLabel,
        'HQ',
      );
      // 空 relate_goods 且无其他信息时整体解析为 null（组件按失败静默处理）
      expect(
        parsePrivilegeLiteResponse(
            _privilegeResp(relateGoods: <Map<String, dynamic>>[]), 'h'),
        isNull,
      );
    });

    test('quality_vip 按 hash 匹配并取 size_text', () {
      final info = parsePrivilegeLiteResponse(
        _privilegeResp(qualityVip: [
          {
            'hash': 'OTHER',
            'qualities': [
              {'quality': 'flac', 'exists': 1, 'size_text': '9.9M'},
            ],
          },
          {
            'hash': 'abc123hash',
            'qualities': [
              {
                'quality': 'flac',
                'exists': 1,
                'obtainable': 1,
                'size_text': '31.2M',
              },
            ],
          },
        ]),
        'abc123HASH',
      )!;
      expect(info.sizeText, '31.2M');
    });

    test('可获取档位优先：高档存在但不可获取时取可获取的最高档', () {
      final info = parsePrivilegeLiteResponse(
        _privilegeResp(qualityVip: [
          {
            'hash': 'abc123HASH',
            'qualities': [
              {
                'quality': 'flac',
                'exists': 1,
                'obtainable': 0,
                'free_listen': 0,
                'size_text': '31.2M',
              },
              {
                'quality': '320',
                'exists': 1,
                'obtainable': 1,
                'size_text': '9.8M',
              },
            ],
          },
        ]),
        'abc123HASH',
      )!;
      expect(info.sizeText, '9.8M');
    });

    test('need_vip + require_vip_type 细化 VIP 等级', () {
      String? vipOf(String requireType) =>
          parsePrivilegeLiteResponse(
            _privilegeResp(qualityVip: [
              {
                'hash': 'abc123HASH',
                'qualities': [
                  {
                    'quality': 'flac',
                    'exists': 1,
                    'need_vip': 1,
                    'require_vip_type': requireType,
                  },
                ],
              },
            ]),
            'abc123HASH',
          )!.vipLabel;

      expect(vipOf('concept'), '需概念版VIP');
      expect(vipOf('suvip'), '需超级VIP');
      expect(vipOf(''), '需VIP');
    });

    test('size_text 缺失时回退 audio_info.filesize_* 换算', () {
      final resp = _privilegeResp(audioDurationMs: 225000);
      (resp['data'] as List).first['audio_info']['filesize_320'] = 5242880;
      resp['quality_vip'] = [
        {
          'hash': 'abc123HASH',
          'qualities': [
            {'quality': '320', 'exists': 1, 'obtainable': 1},
          ],
        },
      ];
      final info = parsePrivilegeLiteResponse(resp, 'abc123HASH')!;
      expect(info.sizeText, '5.0MB');
    });

    test('audio_info.duration 毫秒归一化为秒', () {
      final info =
          parsePrivilegeLiteResponse(_privilegeResp(audioDurationMs: 225000), 'h')!;
      expect(info.durationSeconds, 225);
    });
  });

  group('formatFileSize', () {
    test('分段换算', () {
      expect(formatFileSize(0), '');
      expect(formatFileSize(512 * 1024), '512KB');
      expect(formatFileSize(5 * 1024 * 1024), '5.0MB');
      expect(formatFileSize(150 * 1024 * 1024), '150MB');
      expect(formatFileSize(2 * 1024 * 1024 * 1024), '2.00GB');
    });
  });

  group('SongMenuInfoCache', () {
    test('TTL 内命中，失败结果不缓存', () {
      final cache = SongMenuInfoCache();
      final info = const SongMenuInfo(qualityLabel: 'Hi-Res');
      cache.put('h', 'a', info);
      expect(cache.get('h', 'a'), same(info));
      // 不同 key 不命中
      expect(cache.get('h', null), isNull);
      // 失败（null）不占缓存位，下次允许重试
      cache.put('h2', null, null);
      expect(cache.get('h2', null), isNull);
    });
  });

  group('SongMenuInfoBadges', () {
    Future<Map<String, dynamic>?> okFetcher(String hash, String? albumId) async {
      return _privilegeResp(
        privilege: 10,
        payType: 3,
        relateGoods: [
          {'quality': 'flac'},
        ],
        qualityVip: [
          {
            'hash': hash,
            'qualities': [
              {
                'quality': 'flac',
                'exists': 1,
                'obtainable': 1,
                'size_text': '31.2M',
              },
            ],
          },
        ],
      );
    }

    testWidgets('在线歌曲显示 时长/音质/大小/VIP 徽章', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SongMenuInfoBadges(
              song: _onlineSong(),
              fetcher: okFetcher,
              cache: SongMenuInfoCache(), // 独立缓存，避免用例间串扰
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('03:45'), findsOneWidget);
      expect(find.text('SQ'), findsOneWidget);
      expect(find.text('31.2M'), findsOneWidget);
      expect(find.text('VIP'), findsOneWidget);
    });

    testWidgets('接口失败静默：无崩溃、无 VIP 徽章', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SongMenuInfoBadges(
              song: _onlineSong(),
              fetcher: (hash, albumId) => throw Exception('boom'),
              cache: SongMenuInfoCache(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('VIP'), findsNothing);
      // 时长来自 song.duration，不受接口失败影响
      expect(find.text('03:45'), findsOneWidget);
    });

    testWidgets('缓存命中：同一 cache 下第二次构建不再触发请求', (tester) async {
      final cache = SongMenuInfoCache();
      var calls = 0;
      Future<Map<String, dynamic>?> countingFetcher(
        String hash,
        String? albumId,
      ) async {
        calls += 1;
        return okFetcher(hash, albumId);
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SongMenuInfoBadges(
              song: _onlineSong(),
              fetcher: countingFetcher,
              cache: cache,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, 1);

      // 换一棵树（模拟再次打开菜单），同 hash 命中缓存
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SongMenuInfoBadges(
              song: _onlineSong(),
              fetcher: countingFetcher,
              cache: cache,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.text('VIP'), findsOneWidget);
    });

    testWidgets('无 fetcher 时在线歌曲只显示即时数据且不发占位', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SongMenuInfoBadges(song: _onlineSong())),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('03:45'), findsOneWidget);
      expect(find.text('VIP'), findsNothing);
      expect(find.text('SQ'), findsNothing);
    });

    testWidgets('本地歌曲：时长 + 本地音质推断 + 文件大小，无 VIP', (tester) async {
      // 真实文件 IO 在 FakeAsync 区不可靠（偶发挂死），统一经 runAsync 执行
      late final Directory dir;
      late final File file;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('md3_badges_test');
        file = File('${dir.path}/test.flac');
        await file.writeAsBytes(List.filled(3 * 1024 * 1024, 0));
      });
      addTearDown(() => tester.runAsync(() => dir.delete(recursive: true)));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SongMenuInfoBadges(
              song: _localSong(quality: 'flac', path: file.path),
              fetcher: okFetcher, // 本地歌曲不应触发请求
            ),
          ),
        ),
      );
      // 留真实时间给组件内部的 File.stat 完成，再 settle 刷新徽章
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.text('02:00'), findsOneWidget);
      expect(find.text('无损'), findsOneWidget);
      expect(find.text('3.0MB'), findsOneWidget);
      expect(find.text('VIP'), findsNothing);
    });
  });
}
