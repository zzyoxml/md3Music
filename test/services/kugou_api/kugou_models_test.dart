import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

/// KugouLyric.fromJson 双格式歌词（LRC + KRC）解析与 getter 降级行为测试
void main() {
  group('KugouLyric.fromJson', () {
    test('同时有 decodeContent 与 decodeKrcContent 时，displayLyric 优先返回 KRC', () {
      const lrcText = '[00:01.00]Hello LRC';
      const krcText = '[1000,2000]<0,1000,0>Hello';
      final lyric = KugouLyric.fromJson({
        'content': 'BASE64_RAW',
        'decodeContent': lrcText,
        'decodeKrcContent': krcText,
      });

      expect(lyric.content, 'BASE64_RAW');
      expect(lyric.decodedContent, lrcText);
      expect(lyric.decodedKrcContent, krcText);

      // 优先返回 KRC
      expect(lyric.displayLyric, krcText);
      // 单独 getter
      expect(lyric.displayLrcLyric, lrcText);
      expect(lyric.displayKrcLyric, krcText);
    });

    test('仅 decodeContent 时，displayLyric 返回 LRC，displayKrcLyric 为 null', () {
      const lrcText = '[00:01.00]Hello LRC';
      final lyric = KugouLyric.fromJson({
        'content': 'BASE64_RAW',
        'decodeContent': lrcText,
      });

      expect(lyric.decodedContent, lrcText);
      expect(lyric.decodedKrcContent, isNull);

      // 无 KRC 时降级到 LRC
      expect(lyric.displayLyric, lrcText);
      expect(lyric.displayLrcLyric, lrcText);
      expect(lyric.displayKrcLyric, isNull);
    });

    test('两者都无，只有 content 时，displayLyric 返回原始 content', () {
      final lyric = KugouLyric.fromJson({
        'content': 'BASE64_RAW',
      });

      expect(lyric.content, 'BASE64_RAW');
      expect(lyric.decodedContent, isNull);
      expect(lyric.decodedKrcContent, isNull);

      // KRC、LRC 均无，最终降级到原始 content
      expect(lyric.displayLyric, 'BASE64_RAW');
      expect(lyric.displayLrcLyric, isNull);
      expect(lyric.displayKrcLyric, isNull);
    });

    test('KRC 字段名降级：decoded_krc_content 与 krcContent 也能被解析', () {
      const krcSnake = '[1000,2000]<0,1000,0>snake';
      const krcCamel = '[2000,2000]<0,1000,0>camel';

      final lyricSnake = KugouLyric.fromJson({
        'decoded_krc_content': krcSnake,
      });
      expect(lyricSnake.decodedKrcContent, krcSnake);
      expect(lyricSnake.displayKrcLyric, krcSnake);
      expect(lyricSnake.displayLrcLyric, isNull);

      final lyricCamel = KugouLyric.fromJson({
        'krcContent': krcCamel,
      });
      expect(lyricCamel.decodedKrcContent, krcCamel);
      expect(lyricCamel.displayKrcLyric, krcCamel);
    });

    test('空 JSON 时 content 为空字符串，所有 getter 均降级为空/null', () {
      final lyric = KugouLyric.fromJson(<String, dynamic>{});

      expect(lyric.content, '');
      expect(lyric.decodedContent, isNull);
      expect(lyric.decodedKrcContent, isNull);
      expect(lyric.displayLyric, '');
      expect(lyric.displayLrcLyric, isNull);
      expect(lyric.displayKrcLyric, isNull);
    });
  });

  group('KugouLoginAccount.fromJson', () {
    test('解析 user_list 字段名兼容', () {
      // 酷狗接口返回的多种字段名
      final a1 = KugouLoginAccount.fromJson({
        'userid': '123', 'nickname': '测试用户', 'avatar': 'https://example.com/avatar.jpg',
      });
      expect(a1.userid, '123');
      expect(a1.nickname, '测试用户');
      expect(a1.avatar, 'https://example.com/avatar.jpg');

      // 驼峰字段名
      final a2 = KugouLoginAccount.fromJson({
        'userId': '456', 'user_name': '用户B', 'pic': 'http://example.com/pic.jpg',
      });
      expect(a2.userid, '456');
      expect(a2.nickname, '用户B');
      expect(a2.avatar, 'http://example.com/pic.jpg');

      // 空字段
      final a3 = KugouLoginAccount.fromJson({'id': '789'});
      expect(a3.userid, '789');
      expect(a3.nickname, isNull);
      expect(a3.avatar, isNull);
    });
  });

  /// /search 接口返回的是「搜索形态」记录：SingerId 为数组、歌手在 Singers
  /// 数组里、封面在 Image / trans_param.union_cover、专辑在 AlbumID/AlbumName。
  /// 这些用例的字段形状取自真机实测响应（tmp/search.json），不是构造的。
  group('KugouSongDetail.fromJson 搜索形态', () {
    test('SingerId 为数组时取首个 id 作为 artistId', () {
      final d = KugouSongDetail.fromJson({
        'FileHash': 'FF3BA0A7AD50D5BEBB2ED7907F15608C',
        'SongName': '桃花诺',
        'SingerName': 'G.E.M.邓紫棋',
        'SingerId': [4490],
        'Singers': [
          {'name': 'G.E.M.邓紫棋', 'id': 4490, 'ip_id': 0},
        ],
        'AlbumID': '2681514',
        'AlbumName': '桃花诺',
      });

      expect(d.artistId, '4490');
      expect(d.artistName, 'G.E.M.邓紫棋');
      expect(d.albumId, '2681514');
      expect(d.albumName, '桃花诺');
    });

    test('合唱曲目 SingerId 多元素时取首个 id（与 Singers 顺序一致）', () {
      final d = KugouSongDetail.fromJson({
        'FileHash': '6BDE4FD59A63A21F5DA182C29FBA25B4',
        'SongName': '桃花诺 (Live)',
        'SingerName': '罗云熙、黄霄雲',
        'SingerId': [184908, 194052],
        'Singers': [
          {'name': '罗云熙', 'id': 184908, 'ip_id': 0},
          {'name': '黄霄雲', 'id': 194052, 'ip_id': 0},
        ],
        'AlbumID': '198053621',
        'AlbumName': '天赐的声音第七季 第4期',
      });

      expect(d.artistId, '184908');
      expect(d.artistName, '罗云熙、黄霄雲');
      expect(d.albumId, '198053621');
    });

    test('SingerId 为标量字符串时仍能解析（不回归其他接口形态）', () {
      final d = KugouSongDetail.fromJson({
        'hash': 'ABC',
        'songname': '某歌',
        'SingerId': '4490',
      });

      expect(d.artistId, '4490');
    });

    test('SingerId 为空数组时回退到其他候选键，不返回空串 id', () {
      final d = KugouSongDetail.fromJson({
        'hash': 'ABC',
        'songname': '某歌',
        'SingerId': <dynamic>[],
        'artist_id': '777',
      });

      expect(d.artistId, '777');
    });

    test('Image 作为封面来源，{size} 占位符替换为 400', () {
      final d = KugouSongDetail.fromJson({
        'FileHash': 'FF3BA0A7AD50D5BEBB2ED7907F15608C',
        'SongName': '桃花诺',
        'Image':
            'http://imge.kugou.com/stdmusic/{size}/20200909/20200909124212131553.jpg',
      });

      expect(
        d.artworkUri,
        'http://imge.kugou.com/stdmusic/400/20200909/20200909124212131553.jpg',
      );
    });

    test('trans_param.union_cover 作为封面兜底来源', () {
      final d = KugouSongDetail.fromJson({
        'FileHash': 'FF3BA0A7AD50D5BEBB2ED7907F15608C',
        'SongName': '桃花诺',
        'trans_param': {
          'union_cover':
              'http://imge.kugou.com/stdmusic/{size}/20230226/20230226114315528773.jpg',
        },
      });

      expect(
        d.artworkUri,
        'http://imge.kugou.com/stdmusic/400/20230226/20230226114315528773.jpg',
      );
    });

    test('toSong() 带出 artistId/albumId/封面，供详情页跳转使用', () {
      final d = KugouSongDetail.fromJson({
        'FileHash': 'FF3BA0A7AD50D5BEBB2ED7907F15608C',
        'FileName': 'G.E.M.邓紫棋 - 桃花诺',
        'SongName': '桃花诺',
        'SingerName': 'G.E.M.邓紫棋',
        'SingerId': [4490],
        'Singers': [
          {'name': 'G.E.M.邓紫棋', 'id': 4490, 'ip_id': 0},
        ],
        'AlbumID': '2681514',
        'AlbumName': '桃花诺',
        'Image':
            'http://imge.kugou.com/stdmusic/{size}/20200909/20200909124212131553.jpg',
      });

      final song = d.toSong();
      expect(song.artistId, '4490');
      expect(song.albumId, '2681514');
      expect(song.artist, 'G.E.M.邓紫棋');
      expect(song.title, '桃花诺');
      expect(
        song.artworkUri,
        'http://imge.kugou.com/stdmusic/400/20200909/20200909124212131553.jpg',
      );
    });
  });

  group('KugouComment.fromJson userId 字段名降级', () {
    test('user_id / userid / kugouid 三种字段名都能解析', () {
      expect(KugouComment.fromJson({'id': 'c', 'user_id': '1'}).userId, '1');
      expect(KugouComment.fromJson({'id': 'c', 'userid': '2'}).userId, '2');
      expect(KugouComment.fromJson({'id': 'c', 'kugouid': '3'}).userId, '3');
      // 全缺时为 null（isOwnComment 对 null 一律 false，不出删除入口）
      expect(KugouComment.fromJson({'id': 'c'}).userId, isNull);
    });
  });

  group('KugouSongRanking.fromJson 歌曲成绩单', () {
    test('真实响应结构解析（platform_logo / title1 / title2）', () {
      final ranking = KugouSongRanking.fromJson({
        'errcode': 0,
        'errmsg': '',
        'status': 1,
        'data': {
          'album_audio_id': 32155307,
          'info': [
            {
              'platform': 1,
              'platform_name': '酷狗音乐',
              'platform_logo': 'http://example.com/kg.png',
              'last_time': '2026-10-10',
              'ranking_num': 13,
              'ranking_times': 5059,
            },
          ],
          'platform_num': 4,
          'platform_total': 17,
          'title1': '已上榜 4/17',
          'title2': '收录全球海内外17个音乐平台上榜信息，该歌曲上榜4个',
        },
      });

      // title 字段缺席时回落 title1；title2 为平台总述文案
      expect(ranking.title, '已上榜 4/17');
      expect(ranking.title2, '收录全球海内外17个音乐平台上榜信息，该歌曲上榜4个');
      expect(ranking.info, hasLength(1));
      final card = ranking.info.first;
      expect(card.platform, 1);
      expect(card.platformName, '酷狗音乐');
      expect(card.rankingNum, 13);
      expect(card.rankingTimes, 5059);
      expect(card.lastTime, '2026-10-10');
      expect(card.logoPic, 'http://example.com/kg.png');
    });

    test('camelCase 字段降级与 info 脏元素跳过', () {
      final ranking = KugouSongRanking.fromJson({
        'data': {
          'info': [
            'dirty',
            {
              'platform': '2',
              'platformName': '酷狗概念版',
              'rankingNum': '5',
              'rankingTimes': '7',
              'lastTime': '2026-09-30',
              'logo': 'http://example.com/logo2.png',
            },
          ],
        },
      });

      expect(ranking.info, hasLength(1));
      final card = ranking.info.first;
      expect(card.platform, 2);
      expect(card.platformName, '酷狗概念版');
      expect(card.rankingNum, 5);
      expect(card.rankingTimes, 7);
      expect(card.logoPic, 'http://example.com/logo2.png');
    });

    test('无 data 信封时解析顶层；info 缺失/非列表时空列表不抛异常', () {
      expect(KugouSongRanking.fromJson({'title2': '只有总述'}).info, isEmpty);
      expect(
        KugouSongRanking.fromJson({'title2': 'x', 'data': null}).title2,
        'x',
      );
      expect(KugouSongRanking.fromJson({}).info, isEmpty);
    });
  });

  group('KugouSongRankingFilterItem.fromJson 成绩单明细', () {
    test('snake_case 与 camelCase 双格式解析', () {
      final snake = KugouSongRankingFilterItem.fromJson({
        'area': 1,
        'name': '酷狗飙升榜',
        'count': 8,
        'top_ranking': 2,
        'platform': 1,
        'platform_name': '酷狗音乐',
        'platform_logo': 'http://example.com/a.png',
        'logo_pic': 'http://example.com/old.png',
        'share_pic': 'http://example.com/s.png',
      });
      expect(snake.area, 1);
      expect(snake.name, '酷狗飙升榜');
      expect(snake.count, 8);
      expect(snake.topRanking, 2);
      expect(snake.platform, 1);
      expect(snake.platformName, '酷狗音乐');
      // platform_logo 优先于旧口径 logo_pic
      expect(snake.logoPic, 'http://example.com/a.png');
      expect(snake.sharePic, 'http://example.com/s.png');

      final camel = KugouSongRankingFilterItem.fromJson({
        'name': 'TOP500',
        'topRanking': '1',
        'platformName': '酷狗音乐',
      });
      expect(camel.topRanking, 1);
      expect(camel.platformName, '酷狗音乐');
      // 缺席字段为 null（count/area 缺失 → UI 显示「未知/暂无排名」）
      expect(camel.count, isNull);
      expect(camel.area, isNull);
    });

    test('top_ranking 为 0 时保留原值（<=0 由 UI 判「暂无排名」）', () {
      expect(
        KugouSongRankingFilterItem.fromJson({'name': 'x', 'top_ranking': 0})
            .topRanking,
        0,
      );
    });
  });

    group('KugouLoginDevice / 登录设备快照解析', () {
    // 用本地时区构造时间戳，断言与机器时区无关
    final tSecs =
        (DateTime(2024, 1, 2, 3, 4).millisecondsSinceEpoch ~/ 1000).toString();
    final tMs = DateTime(2024, 1, 2, 3, 4).millisecondsSinceEpoch.toString();

    KugouLoginDevice parseDevice(
      Map<String, dynamic> raw, {
      String localMid = '',
      String localDfid = '',
      int index = 0,
    }) {
      return KugouLoginDevice.fromJson(
        raw,
        localMid: localMid,
        localDfid: localDfid,
        index: index,
      );
    }

    test('字段全部字符串化，isCurrent 按 local_device.mid 比对', () {
      final d = parseDevice(
        {
          'mid': 'MID-A',
          'mt': 'DFID-A',
          'dev': 'Xiaomi 15',
          'app': '酷狗概念版',
          'loc': '广东省深圳市 联通',
          't': tSecs,
          'ver': '10597',
          'appid': '3116',
          'new': '0',
          'login_type': 1,
        },
        localMid: 'MID-A',
        localDfid: 'DFID-A',
      );
      expect(d.mid, 'MID-A');
      expect(d.dfid, 'DFID-A');
      expect(d.model, 'Xiaomi 15');
      expect(d.platform, '酷狗概念版');
      expect(d.t, tSecs);
      expect(d.isCurrent, isTrue);
      expect(d.canKick, isFalse); // 本机不可踢
      expect(d.loginTypeLabel, '手机');
    });

    test('local_device 缺 mid 时回退 dfid 比对；都不匹配则非本机', () {
      final raw = {'mid': '', 'mt': 'DFID-A', 't': '100', 'ver': '1', 'appid': '1'};
      expect(
        parseDevice(raw, localMid: '', localDfid: 'DFID-A').isCurrent,
        isTrue,
      );
      expect(
        parseDevice(raw, localMid: 'MID-B', localDfid: 'DFID-B').isCurrent,
        isFalse,
      );
      // 本机标识全缺（响应未注入 local_device）时不判定任何本机
      expect(parseDevice(raw).isCurrent, isFalse);
    });

    test('标题兜底链：机型 → 安卓平台 → 平台 → 登录设备 N', () {
      expect(
        parseDevice({'dev': 'marble', 'app': 'iOS', 't': '1'}).title,
        'marble',
      );
      expect(
        parseDevice({'app': 'Android客户端', 't': '1'}).title,
        '酷狗Android客户端',
      );
      expect(parseDevice({'app': '酷狗概念版', 't': '1'}).title, '酷狗概念版');
      expect(
        parseDevice({'t': '1'}, index: 3).title,
        '登录设备 3',
      );
    });

    test('isNew：new===t 且非 0；canKick 要求非本机且四元组齐全', () {
      final base = {
        'mid': 'MID-B',
        't': '1728000000000',
        'ver': '10597',
        'appid': '3116',
      };
      expect(
        parseDevice({...base, 'new': '1728000000000'}, localMid: 'MID-A').isNew,
        isTrue,
      );
      expect(parseDevice({...base, 'new': '0'}, localMid: 'MID-A').isNew, isFalse);
      expect(parseDevice(base, localMid: 'MID-A').canKick, isTrue);
      // 缺 ver → 四元组不全 → 不可踢
      expect(
        parseDevice({
          'mid': 'MID-B',
          't': '1728000000000',
          'appid': '3116',
        }, localMid: 'MID-A').canKick,
        isFalse,
      );
      // mid 缺失（无法回传 t_mid）→ 不可踢
      expect(
        parseDevice({
          'mid': '',
          't': '1728000000000',
          'ver': '10597',
          'appid': '3116',
        }, localMid: 'MID-A').canKick,
        isFalse,
      );
    });

    test('loginTypeLabel 映射与未知值', () {
      expect(parseDevice({'t': '1', 'login_type': 6}).loginTypeLabel, '扫码');
      expect(parseDevice({'t': '1', 'login_type': 0}).loginTypeLabel, '账号密码');
      expect(parseDevice({'t': '1', 'login_type': 9}).loginTypeLabel, '未知(9)');
      expect(parseDevice({'t': '1'}).loginTypeLabel, '未知');
    });

    test('locationLabel 取最后一段；activeTimeText 秒/毫秒/空值', () {
      expect(
        parseDevice({'t': tSecs, 'loc': '广东省深圳市 联通'}).locationLabel,
        '联通',
      );
      expect(
        parseDevice({'t': tSecs, 'loc': '广东,深圳/南山'}).locationLabel,
        '南山',
      );
      expect(parseDevice({'t': tSecs}).locationLabel, '');
      final secsText = parseDevice({'t': tSecs}).activeTimeText;
      final msText = parseDevice({'t': tMs}).activeTimeText;
      expect(secsText, '2024-01-02 03:04');
      expect(msText, secsText); // 秒与毫秒换算后同一时刻
      expect(parseDevice({'t': ''}).activeTimeText, '');
      expect(parseDevice({'t': 'not-a-date'}).activeTimeText, 'not-a-date');
    });

    test('快照排序：本机优先，其余按活跃时间降序；业务失败 ok=false', () {
      final snap = KugouLoginDeviceSnapshot.fromJson({
        'status': 1,
        'local_device': {'mid': 'MID-A', 'dfid': 'DFID-A'},
        'data': {
          'li': [
            {'mid': 'MID-B', 't': '100', 'ver': '1', 'appid': '1'},
            {'mid': 'MID-A', 't': '50', 'ver': '1', 'appid': '1'},
            {'mid': 'MID-C', 't': '300', 'ver': '1', 'appid': '1'},
          ],
        },
      });
      expect(snap.ok, isTrue);
      expect(snap.localMid, 'MID-A');
      expect(snap.devices.map((d) => d.mid).toList(), [
        'MID-A',
        'MID-C',
        'MID-B',
      ]);
      expect(snap.devices.first.isCurrent, isTrue);

      final bad = KugouLoginDeviceSnapshot.fromJson(
        {'status': 0, 'error_code': 20010, 'data': {'li': []}},
      );
      expect(bad.ok, isFalse);
      expect(bad.devices, isEmpty);

      // data.li 缺失/形状不符 → 空列表，不抛异常
      final empty = KugouLoginDeviceSnapshot.fromJson({'status': 1});
      expect(empty.ok, isTrue);
      expect(empty.devices, isEmpty);
    });
  });

  group('KugouAccompany.fromJson 伴奏匹配', () {
    test('真实响应结构解析（探针捕获：字符串数字/伴奏 hash/songid）', () {
      final accompany = KugouAccompany.fromJson({
        'data': {
          'singername': '希林娜依高',
          'accompanySongId': '43522508',
          'view_singername': '希林娜依高',
          'song_type': '0',
          'remark': '伴奏',
          'bitrate': '128',
          'filesize': '3457210',
          'songname': 'Shine Brighter (愈加璀璨)',
          'duration': '216000',
          'is_file_head': '100',
          'is_recommend': '1',
          'suffix_audio_name': '',
          'songid': '43522508',
          'extname': 'mp3',
          'scid': '358253291',
          'hash': '8153F7E7BF0B2EFB4F8FF1B7E79A0E2C',
          'libSongId': '424738725',
          'showMic': true,
          'ksongMID': '001oQWjK2cvmMZ',
        },
        'error_code': 0,
        'status': 1,
      });

      expect(accompany.status, 1);
      expect(accompany.errorCode, 0);
      expect(accompany.hasMatch, isTrue);
      expect(accompany.hash, '8153F7E7BF0B2EFB4F8FF1B7E79A0E2C');
      expect(accompany.songName, 'Shine Brighter (愈加璀璨)');
      expect(accompany.singerName, '希林娜依高');
      // 上游时长/码率/文件大小均为字符串数字
      expect(accompany.durationMs, 216000);
      expect(accompany.bitrate, 128);
      expect(accompany.extName, 'mp3');
      expect(accompany.fileSize, 3457210);
      expect(accompany.remark, '伴奏');
      expect(accompany.songId, '43522508');
    });

    test('songid 缺失时回落 accompanySongId；camelCase 兜底', () {
      final accompany = KugouAccompany.fromJson({
        'data': {
          'songName': 'Test Song',
          'singerName': '测试歌手',
          'extName': 'flac',
          'fileSize': '1024',
          'accompanySongId': '111',
          'hash': 'HASH1',
        },
        'status': 1,
      });
      expect(accompany.songName, 'Test Song');
      expect(accompany.singerName, '测试歌手');
      expect(accompany.extName, 'flac');
      expect(accompany.fileSize, 1024);
      expect(accompany.songId, '111');
      expect(accompany.hasMatch, isTrue);
    });

    test('匹配失败（status!=1）与空入参不抛异常', () {
      final failed = KugouAccompany.fromJson({'status': 0, 'error_code': 1});
      expect(failed.hasMatch, isFalse);
      expect(failed.hash, isNull);

      final bare = KugouAccompany.fromJson({});
      expect(bare.hasMatch, isFalse);
      expect(bare.status, isNull);
    });
  });

  group('KugouAudioKtvTotal.fromJson K 歌数量', () {
    test('真实响应结构解析（data.totalOpusNum 字符串数字）', () {
      final total = KugouAudioKtvTotal.fromJson({
        'code': 0,
        'msg': '',
        'times': 1791655959976,
        'data': {'totalOpusNum': '248'},
      });
      expect(total.totalOpusNum, 248);
    });

    test('snake_case 兜底与缺失字段不抛异常', () {
      expect(
        KugouAudioKtvTotal.fromJson({
          'data': {'total_opus_num': 7},
        }).totalOpusNum,
        7,
      );
      expect(KugouAudioKtvTotal.fromJson({}).totalOpusNum, isNull);
      expect(KugouAudioKtvTotal.fromJson({'data': null}).totalOpusNum, isNull);
    });
  });
}
