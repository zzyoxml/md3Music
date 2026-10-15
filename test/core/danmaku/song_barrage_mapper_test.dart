import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/danmaku/danmaku_entry.dart';
import 'package:md3music/core/danmaku/song_barrage_mapper.dart';

void main() {
  const duration = Duration(seconds: 100);

  // 本机实测的真实形态：条目在顶层 list，like 是对象，childrenid 是 JSON 数字，
  // 且条目里没有任何播放位置字段（addtime 是发表墙上时间）。
  Map<String, dynamic> realShape(List<Map<String, dynamic>> list, {dynamic childrenId = 100285259}) => {
        'list': list,
        'count': list.length,
        'status': 1,
        'err_code': 0,
        'msg': 'success',
        'childrenid': childrenId,
        'current_page': 1,
        'weightList': [],
      };

  setUp(clearSongBarrageCache);

  group('mapSongBarrage', () {
    test('无时间字段 → 按点赞降序均匀铺开：首条 duration/2n、末条 (n-0.5)/n', () {
      final raw = realShape([
        {'id': 1, 'content': '低赞', 'like': {'likenum': 0}, 'addtime': '2026-09-08 20:18:57'},
        {'id': 2, 'content': '高赞', 'like': {'likenum': 232, 'count': 232, 'haslike': false}},
        {'id': 3, 'content': '中赞', 'like': {'likenum': 5}},
        {'id': 4, 'content': '零赞', 'like': {'likenum': 0}},
      ]);
      final entries = mapSongBarrage(raw, songDuration: duration);
      expect(entries, hasLength(4));
      expect(entries.map((e) => e.text).toList(), ['高赞', '中赞', '低赞', '零赞']);
      expect(entries.first.time, const Duration(milliseconds: 12500));
      expect(entries.last.time, const Duration(milliseconds: 87500));
      for (final e in entries) {
        expect(e.mode, DanmakuMode.scroll);
        expect(e.colorValue, 0xFFFFFF);
      }
    });

    test('同赞数用 id 升序兜底（低赞两条不因 map 顺序抖动）', () {
      final entries = mapSongBarrage(
        realShape([
          {'id': 4, 'content': '零赞b'},
          {'id': 3, 'content': '零赞a'},
        ]),
        songDuration: duration,
      );
      expect(entries.map((e) => e.text).toList(), ['零赞a', '零赞b']);
    });

    test('池仅 1 条 → 落在中段（50s）', () {
      final entries = mapSongBarrage(
        realShape([
          {'id': 1, 'content': '独一条'}
        ]),
        songDuration: duration,
      );
      expect(entries.single.time, const Duration(seconds: 50));
    });

    test('上游将来带播放位置字段 → 原生分支自动生效（3s 而非 50s）', () {
      final raw = realShape([
        {'id': 1, 'content': '带原生时间', 'timepoint': 3000},
      ]);
      final entries = mapSongBarrage(raw, songDuration: duration);
      expect(entries.single.time, const Duration(seconds: 3));
    });

    test('空文本条目被过滤；空池（count=0 / list=[]）返回空', () {
      final filtered = mapSongBarrage(
        realShape([
          {'id': 1, 'content': '  '},
          {'id': 2, 'content': '有效'},
        ]),
        songDuration: duration,
      );
      expect(filtered, hasLength(1));
      expect(filtered.single.text, '有效');

      final emptyPool = mapSongBarrage(
        {'status': 1, 'count': 0, 'list': [], 'childrenid': ''},
        songDuration: duration,
      );
      expect(emptyPool, isEmpty);
    });

    test('songDuration <= 0 → 空列表', () {
      final raw = realShape([
        {'id': 1, 'content': 'x'}
      ]);
      expect(mapSongBarrage(raw, songDuration: Duration.zero), isEmpty);
      expect(
        mapSongBarrage(raw, songDuration: const Duration(seconds: -1)),
        isEmpty,
      );
    });

    test('maxCount 生效', () {
      final raw = realShape([
        for (var i = 1; i <= 5; i++) {'id': i, 'content': 'c$i'}
      ]);
      expect(mapSongBarrage(raw, songDuration: duration, maxCount: 2), hasLength(2));
    });
  });

  group('songBarrageSpecialId', () {
    test('childrenid 是 JSON 数字 → 转 String', () {
      expect(songBarrageSpecialId(realShape([])), '100285259');
    });

    test('childrenid 是字符串 → 原样返回', () {
      expect(songBarrageSpecialId({'childrenid': '100285259'}), '100285259');
    });

    test('空池 childrenid="" 与缺字段 → 空串，不抛异常', () {
      expect(songBarrageSpecialId({'childrenid': ''}), '');
      expect(songBarrageSpecialId({'status': 1}), '');
      expect(songBarrageSpecialId(null), '');
      expect(songBarrageSpecialId('nonsense'), '');
    });
  });

  test('songDanmakuKey：用 songbarrage: 前缀，避开 MV 直链场景已占用的 song:<Song.id>', () {
    // mv_player_page.dart:279 的直链场景本地弹幕 key 是 `song:${Song.id}`，
    // 而在线歌曲的 Song.id 就是酷狗 hash —— 若这里也用 `song:` 会撞进同一个文件。
    expect(songDanmakuKey('043C4DA61870CD55C1240F0FA6744C94'),
        'songbarrage:043C4DA61870CD55C1240F0FA6744C94');
  });

  group('fetchSongBarragePages', () {
    test('上游 pagesize 硬上限 50：每页按 50 请求，串行翻页', () async {
      final requested = <List<int>>[];
      await fetchSongBarragePages(
        hash: 'H_PAGES',
        songDuration: duration,
        fetchPage: (page, pagesize) async {
          requested.add([page, pagesize]);
          return realShape([
            {'id': page, 'content': 'p$page'}
          ]);
        },
      );
      expect(requested, [
        [1, 50],
        [2, 50],
        [3, 50],
      ]);
    });

    test('第 2 页返回 null → 停止翻页并保留第 1 页数据（降级不抛）', () async {
      final pages = <int>[];
      final entries = await fetchSongBarragePages(
        hash: 'H_DEGRADE',
        songDuration: duration,
        fetchPage: (page, pagesize) async {
          pages.add(page);
          if (page == 1) {
            return realShape([
              {'id': 1, 'content': '第一条'},
              {'id': 2, 'content': '第二条'},
            ]);
          }
          return null;
        },
      );
      expect(entries, hasLength(2));
      expect(pages, [1, 2]); // 失败即停，不再打第 3 页
      expect(entries.first.time, const Duration(seconds: 25));
      expect(entries.last.time, const Duration(seconds: 75));
    });

    test('某页空 list 同样停止翻页', () async {
      final pages = <int>[];
      final entries = await fetchSongBarragePages(
        hash: 'H_EMPTY_PAGE',
        songDuration: duration,
        fetchPage: (page, pagesize) async {
          pages.add(page);
          if (page == 1) {
            return realShape([
              {'id': 1, 'content': '第一条'}
            ]);
          }
          return {'status': 1, 'count': 1, 'list': []};
        },
      );
      expect(entries, hasLength(1));
      expect(pages, [1, 2]);
    });

    test('跨页按弹幕 id 去重，聚合后只铺一次时间轴', () async {
      final entries = await fetchSongBarragePages(
        hash: 'H_DEDUP',
        songDuration: duration,
        fetchPage: (page, pagesize) async {
          if (page == 1) {
            return realShape([
              {'id': 1, 'content': 'a'},
              {'id': 2, 'content': 'b'},
            ]);
          }
          if (page == 2) {
            return realShape([
              {'id': 2, 'content': 'b（重复）'},
              {'id': 3, 'content': 'c'},
            ]);
          }
          return realShape([
            {'id': 3, 'content': 'c（重复）'},
          ]);
        },
      );
      expect(entries, hasLength(3));
      expect(entries.map((e) => e.id).toSet(), {'barrage-1', 'barrage-2', 'barrage-3'});
      // 3 条聚合铺开：1/6、3/6、5/6 处
      expect(entries.map((e) => e.time.inMilliseconds).toList(),
          [16667, 50000, 83333]);
    });

    test('同一 hash 命中缓存不重复请求；不同 hash 各自拉取', () async {
      var fetchCount = 0;
      Future<Map<String, dynamic>?> fetch(int page, int pagesize) async {
        fetchCount++;
        return realShape([
          {'id': page, 'content': 'c$page'}
        ]);
      }

      final first = await fetchSongBarragePages(
        hash: 'H_CACHE',
        songDuration: duration,
        fetchPage: fetch,
      );
      expect(fetchCount, 3);

      final again = await fetchSongBarragePages(
        hash: 'H_CACHE',
        songDuration: duration,
        fetchPage: fetch,
      );
      expect(fetchCount, 3); // 转屏/切布局重建 widget 时不再重拉
      expect(again.length, first.length);

      await fetchSongBarragePages(
        hash: 'H_OTHER',
        songDuration: duration,
        fetchPage: fetch,
      );
      expect(fetchCount, 6);

      clearSongBarrageCache();
      await fetchSongBarragePages(
        hash: 'H_CACHE',
        songDuration: duration,
        fetchPage: fetch,
      );
      expect(fetchCount, 9);
    });

    test('空池不写缓存（登录态/网络抖动造成的空结果不该钉住 10 分钟）', () async {
      var fetchCount = 0;
      Future<Map<String, dynamic>?> empty(int page, int pagesize) async {
        fetchCount++;
        return {'status': 1, 'count': 0, 'list': [], 'childrenid': ''};
      }

      expect(
        await fetchSongBarragePages(
            hash: 'H_NOPOOLS', songDuration: duration, fetchPage: empty),
        isEmpty,
      );
      expect(fetchCount, 1);
      expect(
        await fetchSongBarragePages(
            hash: 'H_NOPOOLS', songDuration: duration, fetchPage: empty),
        isEmpty,
      );
      expect(fetchCount, 2);
    });

    test('hash 为空 或 时长未知 → 直接返回空，一个请求都不发', () async {
      var fetchCount = 0;
      Future<Map<String, dynamic>?> fetch(int page, int pagesize) async {
        fetchCount++;
        return realShape([
          {'id': 1, 'content': 'x'}
        ]);
      }

      expect(
        await fetchSongBarragePages(
            hash: '', songDuration: duration, fetchPage: fetch),
        isEmpty,
      );
      expect(
        await fetchSongBarragePages(
            hash: 'H_NO_DUR', songDuration: Duration.zero, fetchPage: fetch),
        isEmpty,
      );
      expect(fetchCount, 0);
    });
  });
}
