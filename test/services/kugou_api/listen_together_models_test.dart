import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/listen_together_provider.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:md3music/services/kugou_api/listen_together_models.dart';

void main() {
  group('KugouSongDetail /audio 基础结构', () {
    test('audio_name 合并格式拆出歌手与歌名（众乐房歌单富化路径）', () {
      // 真机抓包：/audio 只返回 audio_name（「歌手 - 歌名」合并格式），
      // 无 singerinfo/authors/封面字段
      final detail = KugouSongDetail.fromJson({
        'hash': 'EE6A8624BFACD6A029F6AD12842A4635',
        'audio_name': 'HOYO-MiX - 远山笼宿雾 Mountains of Mist',
        'timelength': '127843',
        'audio_id': '340306098',
      });
      expect(detail.songName, '远山笼宿雾 Mountains of Mist');
      expect(detail.artistName, 'HOYO-MiX');
      expect(detail.artworkUri, isNull);
    });
  });

  group('unwrap / extract 纯函数', () {
    test('unwrapListenPayload 递归解 data 包裹与 JSON 字符串', () {
      // data 直接是 JSON 字符串数组 → 解开为 List
      final v = unwrapListenPayload({'data': '[{"hash": "H"}]'});
      expect(v, isA<List<dynamic>>());
      // 多层 data 包裹 → 全部解开后交给 extractList 取数组
      final nested = unwrapListenPayload({'data': '{"data": {"list": [{"hash": "H"}]}}'});
      expect(extractList(nested), hasLength(1));
    });

    test('extractList 支持多种候选键与嵌套 data', () {
      final a = extractList({
        'data': {
          'members': [
            {'userid': '1'},
          ],
        },
      });
      expect(a, hasLength(1));
      final b = extractList({'rooms': <dynamic>[]});
      expect(b, isEmpty);
      // 嵌套 info 系再探
      final c = extractList({
        'data': {
          'room_info': {
            'list': [
              {'hash': 'X'},
            ],
          },
        },
      });
      expect(c, hasLength(1));
    });

    test('extractRoomId 顶层直取、嵌套递归、数值兜底仅限顶层', () {
      expect(extractRoomId({
        'data': {'groupid': 'G1'},
      }), 'G1');
      expect(extractRoomId({
        'data': {
          'room': {'room_id': 'G2'},
        },
      }), 'G2');
      expect(extractRoomId('G3'), 'G3');
      // 嵌套数值（join_time 等）不能被当房间号
      expect(extractRoomId({
        'data': {'join_time': 1700000000},
      }), '');
    });

    test('readNestedString / readNestedInt / readNestedFlag 支持任意深度与数组', () {
      final payload = {
        'data': {
          'list': [
            {
              'list_version': 'v9',
              'quantity': 42,
              'room_state': 1,
            },
          ],
        },
      };
      expect(readNestedString(payload, 'list_version'), 'v9');
      expect(readNestedInt(payload, 'quantity'), 42);
      expect(readNestedFlag(payload, 'room_state'), isTrue);
      expect(readNestedFlag(payload, 'missing'), isFalse);
      // 嵌套数值（时间戳）不会被 readNestedInt 误认为是缺失字段的兜底
      expect(readNestedInt({'data': {'join_time': 0}}, 'quantity'), 0);
    });

    test('toMs 秒与毫秒归一', () {
      // <=10000 视为秒，>10000 视为毫秒（与上游 duration/position 归一一致）
      expect(toMs(30), 30000);
      expect(toMs(10000), 10000000);
      expect(toMs(10001), 10001);
      expect(toMs(30000), 30000);
    });
  });

  group('MusicRoomBrief', () {
    test('多候选字段解析广场房间，ownerId 用于房主判定', () {
      final room = MusicRoomBrief.fromJson({
        'room_id': 'r1',
        'room_name': '深夜电台',
        'room_notice': '一起熬夜',
        'bg_img': 'https://x/bg.jpg',
        'online_user_count': 12,
        'member_limit': 20,
        'user_info': {'userid': 'U9', 'nick_name': '房主A'},
        'current_audio': {'song_name': '晴天', 'author_name': '周杰伦'},
      });
      expect(room.roomId, 'r1');
      expect(room.name, '深夜电台');
      expect(room.notice, '一起熬夜');
      expect(room.backgroundUrl, 'https://x/bg.jpg');
      expect(room.memberCount, 12);
      expect(room.capacity, 20);
      expect(room.ownerId, 'U9');
      expect(room.ownerName, '房主A');
      expect(room.currentSongName, '晴天');
      expect(room.currentArtistName, '周杰伦');
      expect(room.closed, isFalse);
    });

    test('字段全缺时安全兜底', () {
      final room = MusicRoomBrief.fromJson({});
      expect(room.roomId, '');
      expect(room.name, '房主的众乐房');
      expect(room.memberCount, 0);
      // 上游无可靠容量字段时 capacity 为 0（未知），展示端只显示在线人数
      expect(room.capacity, 0);
      expect(room.ownerName, '房主');
    });

    test('上游无 room_name 时用「{房主名}的众乐房」兜底', () {
      final room = MusicRoomBrief.fromJson({
        'room_id': 'r2',
        'user_info': {'userid': 'U1', 'nick_name': '小明'},
      });
      expect(room.name, '小明的众乐房');
    });

    test('is_hide=1 或 room_status=0 视为已关闭', () {
      expect(MusicRoomBrief.fromJson({'room_id': 'a', 'is_hide': 1}).closed, isTrue);
      expect(MusicRoomBrief.fromJson({'room_id': 'b', 'room_status': 0}).closed, isTrue);
      expect(MusicRoomBrief.fromJson({'room_id': 'c', 'room_status': 1}).closed, isFalse);
    });

    test('解析广场真实结构：room_info.pic 房间图与 album_info 专辑封面', () {
      final room = MusicRoomBrief.fromJson({
        'song_info': {
          'song_name': '割心',
          'mixsongid': '32080908',
          'album_info': {
            'album_name': '用心良苦',
            // 上游封面地址带 {size} 占位符，须替换为 400
            'sizable_cover':
                'http://imge.kugou.com/stdmusic/{size}/20241206/20241206175557508526.jpg',
          },
          'authors': [
            {'author_name': '张宇'},
          ],
        },
        'room_info': {
          'room_theme': '',
          'member_count': 2,
          'pic': 'https://youthimgbssdl.kugou.com/f03da9cccc2d56529252aa317a86640e.webp',
          'roomid': '1554083409834407307',
        },
        'user_info': {'userid': 2366194698, 'nick_name': 'Amaterasu'},
      });

      expect(room.roomId, '1554083409834407307');
      // room_theme 为空 → 回落到房主名的众乐房
      expect(room.name, 'Amaterasu的众乐房');
      expect(room.memberCount, 2);
      // userid 为数字也要能读成字符串
      expect(room.ownerId, '2366194698');
      expect(room.ownerName, 'Amaterasu');
      expect(room.currentSongName, '割心');
      expect(room.backgroundUrl,
          'https://youthimgbssdl.kugou.com/f03da9cccc2d56529252aa317a86640e.webp');
      expect(room.currentSongCover,
          'http://imge.kugou.com/stdmusic/400/20241206/20241206175557508526.jpg');
      // 缩略图优先歌曲封面
      expect(room.thumbnailUrl, room.currentSongCover);
    });

    test('无歌曲封面时缩略图回落房间背景图', () {
      final room = MusicRoomBrief.fromJson({
        'room_id': 'r9',
        'room_info': {'pic': 'https://x/room.webp'},
      });
      expect(room.currentSongCover, isEmpty);
      expect(room.thumbnailUrl, 'https://x/room.webp');
    });

    test('byRoomId 生成可用占位对象', () {
      final room = MusicRoomBrief.byRoomId('123');
      expect(room.roomId, '123');
      expect(room.name, '一起听房间');
      expect(room.thumbnailUrl, isEmpty);
    });
  });

  group('RoomSong', () {
    test('解析歌曲并转 Song', () {
      final rs = RoomSong.fromJson({
        'hash': 'HASH1',
        'mixsongid': '9001',
        'songname': '晴天',
        'singername': '周杰伦',
        'duration': 269,
        'album_img': 'https://x/c.jpg',
      });
      expect(rs.hash, 'HASH1');
      expect(rs.mixSongId, '9001');
      expect(rs.durationSeconds, 269);
      expect(rs.coverUrl, 'https://x/c.jpg');

      final Song s = rs.toSong(playUrl: 'https://x/play.m4a');
      expect(s.id, 'HASH1');
      expect(s.isOnline, isTrue);
      expect(s.albumAudioId, '9001');
      expect(s.url, 'https://x/play.m4a');
      expect(s.title, '晴天');
      expect(s.artist, '周杰伦');
      expect(s.duration.inSeconds, 269);
    });

    test('duration 为毫秒时归一为秒', () {
      expect(RoomSong.fromJson({'hash': 'H', 'duration': 269000}).durationSeconds, 269);
    });

    test('genting_hash 作为备用身份，hash 缺失时顶替', () {
      final rs = RoomSong.fromJson({'genting_hash': 'GH', 'songname': 'x'});
      expect(rs.originalHash, 'GH');
      expect(rs.hash, 'GH');
    });

    test('sameAs 按 hash、genting_hash、mixSongId 全键比对', () {
      const a = RoomSong(
        hash: 'A', originalHash: 'GA', mixSongId: '1', name: '', singer: '',
        durationSeconds: 0, coverUrl: '', orderUserId: '',
      );
      const b = RoomSong(
        hash: 'B', originalHash: 'GA', mixSongId: '2', name: '', singer: '',
        durationSeconds: 0, coverUrl: '', orderUserId: '',
      );
      const c = RoomSong(
        hash: 'C', originalHash: '', mixSongId: '1', name: '', singer: '',
        durationSeconds: 0, coverUrl: '', orderUserId: '',
      );
      const d = RoomSong(
        hash: 'D', originalHash: '', mixSongId: '9', name: '', singer: '',
        durationSeconds: 0, coverUrl: '', orderUserId: '',
      );
      expect(a.sameAs(b), isTrue); // 共享 genting_hash
      expect(a.sameAs(c), isTrue); // 共享 mixSongId
      expect(a.sameAs(d), isFalse);
      // 大小写不敏感
      expect(a.sameAs(const RoomSong(
        hash: 'a', originalHash: '', mixSongId: '', name: '', singer: '',
        durationSeconds: 0, coverUrl: '', orderUserId: '',
      )), isTrue);
    });
  });

  group('PlayerSyncState（快照归一）', () {
    test('pause 语义：1 = 正在播放，2 = 已暂停（与上报口径同源）', () {
      expect(PlayerSyncState.fromJson({'pause': 1}).isPlaying, isTrue);
      expect(PlayerSyncState.fromJson({'pause': 2}).isPlaying, isFalse);
      // 上游实际下发的是字符串
      expect(PlayerSyncState.fromJson({'pause': '1'}).isPlaying, isTrue);
      expect(PlayerSyncState.fromJson({'pause': '2'}).isPlaying, isFalse);
      // 无 pause 时回落状态串 / is_playing
      expect(PlayerSyncState.fromJson({'play_status': 'pause'}).isPlaying, isFalse);
      expect(PlayerSyncState.fromJson({'play_status': 'playing'}).isPlaying, isTrue);
      expect(PlayerSyncState.fromJson({'is_playing': true}).isPlaying, isTrue);
    });

    test('解析 sync_player 真实结构（data.progress_info + 字符串 pause）', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final state = PlayerSyncState.fromJson({
        'error_msg': '',
        'data': {
          'timestamp': (now / 1000).floor(),
          'play_mode': '1',
          'list_version': '65',
          'progress_info': {
            'cur_song': 'da730299a806d0410ed1494d0ffef616',
            'progress': 11,
            'album_audio_id': '937333852',
          },
          'song_info': [
            {'hash': 'da730299a806d0410ed1494d0ffef616', 'album_audio_id': '937333852'},
          ],
          'pause': '1',
        },
        'status': 1,
        'error_code': 0,
      });

      // 歌曲身份来自 progress_info.cur_song
      expect(state.hash, 'da730299a806d0410ed1494d0ffef616');
      expect(state.mixSongId, '937333852');
      // pause 为 "1" → 正在播放
      expect(state.isPlaying, isTrue);
      // progress 为秒，需转为毫秒
      expect(state.progressMs, 11000);
      expect(state.listVersion, '65');
      expect((state.updatedAtMs - now).abs(), lessThan(5000));
    });

    test('歌曲身份可从嵌套 audio 对象读取', () {
      final s = PlayerSyncState.fromJson({
        'audio': {'hash': 'H1', 'mixsongid': '77'},
      });
      expect(s.hash, 'H1');
      expect(s.mixSongId, '77');
    });

    test('进度秒/毫秒归一：>10000 视为毫秒', () {
      expect(PlayerSyncState.fromJson({'hash': 'H', 'progress': 30000}).progressMs, 30000);
      expect(PlayerSyncState.fromJson({'hash': 'H', 'progress': 30}).progressMs, 30000);
      expect(PlayerSyncState.fromJson({'hash': 'H', 'progress': 0}).progressMs, 0);
    });

    test('快照时间戳：秒转毫秒；与当前时间差超 60s 的可疑值回退为解析时刻', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final ok = PlayerSyncState.fromJson({
        'hash': 'H',
        'timestamp': (now / 1000).floor(), // 秒级当前时间
      });
      expect((ok.updatedAtMs - now).abs(), lessThan(5000));

      final stale = PlayerSyncState.fromJson({
        'hash': 'H',
        'timestamp': 1000000000, // 1970 年代秒值，换算后远超 60s 差
      });
      expect((stale.updatedAtMs - now).abs(), lessThan(5000));
    });

    test('list_version 可从嵌套结构读取', () {
      final s = PlayerSyncState.fromJson({
        'hash': 'H',
        'data': {
          'list_version': 'v12',
        },
      });
      expect(s.listVersion, 'v12');
    });

    test('extractList 支持 sync/歌单响应的 song_info 数组', () {
      final list = extractList({
        'data': {
          'song_info': [
            {'hash': 'A'},
            {'hash': 'B'},
          ],
        },
      });
      expect(list, hasLength(2));
    });

    test('extractList 识别 recent_list 的 songs_info 数组与前置空数组', () {
      // recent_list 真实响应形态：data.songs_info 在 data.source_details（空数组）
      // 之后出现。songs_info 不在候选键里时 extractList 返回 0，
      // 听众端歌单会退化成 sync_player 的三首同步窗口（2026-09-19 线上问题）。
      final list = extractList({
        'data': {
          'source_details': <dynamic>[],
          'list_version': '14',
          'songs_info': [
            {'hash': 'H1', 'songname': '最寂寞的时候', 'singername': '卢广仲'},
            {'hash': 'H2'},
          ],
        },
      });
      expect(list, hasLength(2));
      // RoomSong 条目解析：genting_hash / songname / singername / 毫秒 duration
      final song = RoomSong.fromJson(list.first);
      expect(song.hash, 'H1');
      expect(song.originalHash, isEmpty);
      expect(song.displayName, '最寂寞的时候');
      expect(song.singer, '卢广仲');
      // mixSongId 候选键含 genting_album_audio_id（recent_list 直给该键）
      final withGentingId = RoomSong.fromJson({
        'hash': 'H3',
        'genting_album_audio_id': '32129330',
      });
      expect(withGentingId.mixSongId, '32129330');
    });
  });

  group('ChatMessage 与系统消息文案', () {
    test('801 普通消息取 alert；系统消息按码表生成文案', () {
      final m = ChatMessage.fromJson({
        'id': 'm1',
        'msg': {'msgtype': 801, 'alert': '你好', 'nickname': 'A', 'img': 'https://x/a.jpg'},
        'addtime': 1700000000,
      });
      expect(m.isSystem, isFalse);
      expect(m.text, '你好');
      expect(m.nickname, 'A');
      expect(m.avatar, 'https://x/a.jpg');

      final sys = ChatMessage.fromJson({
        'msgid': 'm2',
        'msg': {'msgtype': 3004, 'songname': '晴天', 'nickname': '房主'},
      });
      expect(sys.isSystem, isTrue);
      expect(sys.text, '已切换至《晴天》');

      final enter = ChatMessage.fromJson({
        'msgid': 'm3',
        'msg': {'msgtype': 4001, 'nickname': '小明'},
      });
      expect(enter.text, '小明已加入一起听');

      final order = ChatMessage.fromJson({
        'msgid': 'm4',
        'msg': {'msgtype': 5100, 'songname': '夜曲', 'nickname': '小李'},
      });
      expect(order.text, '小李 点播了《夜曲》');
    });

    test('秒级 addtime 归一为毫秒', () {
      final m = ChatMessage.fromJson({
        'msgid': 'x',
        'msg': {'msgtype': 801, 'alert': 'hi'},
        'addtime': 1700000000,
      });
      expect(m.timestampMs, 1700000000000);
    });

    test('上游已给 alert 的系统消息优先保留原文', () {
      final m = ChatMessage.fromJson({
        'msgid': 'y',
        'msg': {'msgtype': 2008, 'alert': '房间信息已更新（原文）'},
      });
      expect(m.text, '房间信息已更新（原文）');
    });

    test('解析上游真实消息结构并取出房间标签', () {
      // 与 sync/chat 接口实际下发一致：addtime 为秒、message 嵌套、附带 tag
      final m = ChatMessage.fromJson({
        'addtime': 1789648996,
        'msgid': '7506331945100211255',
        'message': {
          'nickname': 'Amaterasu',
          'img': 'http://imge.kugou.com/kugouicon/165/x.jpg',
          'alert': '拜拜',
          'msgtype': 801,
        },
        'is_online': 1,
        'uid': 2366194698,
        'tag': 'rm_1009:1554083409834407307',
        'type': 0,
      });
      expect(m.text, '拜拜');
      expect(m.nickname, 'Amaterasu');
      expect(m.userId, '2366194698');
      expect(m.timestampMs, 1789648996000);
      expect(m.isSystem, isFalse);
      expect(m.roomTag, 'rm_1009:1554083409834407307');
      // 标签末尾即房间号
      expect(m.tagRoomId, '1554083409834407307');
    });

    test('标签缺失时 tagRoomId 为空（本地合成消息无标签）', () {
      final m = ChatMessage.fromJson({'msgid': 'z', 'msg': {'msgtype': 4001, 'nickname': 'A'}});
      expect(m.roomTag, isEmpty);
      expect(m.tagRoomId, isEmpty);
    });
  });

  group('scopeMessagesToRoom（跨房间聊天隔离）', () {
    ChatMessage msg(String id, {String tag = ''}) => ChatMessage(
          id: id,
          userId: 'u',
          text: 'x',
          nickname: 'n',
          avatar: '',
          type: 801,
          timestampMs: 1,
          isSystem: false,
          roomTag: tag,
        );

    test('只保留当前房间与本地的消息', () {
      final list = [
        msg('a', tag: 'rm_1009:ROOM_A'),
        msg('b', tag: 'rm_1009:ROOM_B'),
        msg('c'), // 本地合成（无标签）→ 保留
      ];
      expect(
        scopeMessagesToRoom(list, 'ROOM_B').map((m) => m.id).toList(),
        ['b', 'c'],
      );
      expect(
        scopeMessagesToRoom(list, 'ROOM_A').map((m) => m.id).toList(),
        ['a', 'c'],
      );
    });

    test('房间号为空时原样返回', () {
      final list = [msg('a', tag: 'rm_1009:ROOM_A')];
      expect(scopeMessagesToRoom(list, ''), list);
    });
  });

  group('projectRemotePosition（快照投影）', () {
    test('播放中按 updatedAt 推进；暂停则保持', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      const dur = 200000;
      final playing = PlayerSyncState(
        hash: 'H', originalHash: '', mixSongId: '1', isPlaying: true,
        progressMs: 10000, durationMs: dur, listVersion: 'v', updatedAtMs: now - 2000,
      );
      expect(projectRemotePosition(playing, now), 12000);

      final paused = PlayerSyncState(
        hash: 'H', originalHash: '', mixSongId: '1', isPlaying: false,
        progressMs: 10000, durationMs: dur, listVersion: 'v', updatedAtMs: now - 2000,
      );
      expect(projectRemotePosition(paused, now), 10000);
    });
  });

  group('isKugouPrivateAudioUrl', () {
    test('识别酷狗私有格式（含 URL 编码变体）', () {
      expect(isKugouPrivateAudioUrl('https://x/a.kgs'), isTrue);
      expect(isKugouPrivateAudioUrl('https://x/a.kgm?x=1'), isTrue);
      expect(isKugouPrivateAudioUrl('https://x/sig?name=%2Ekgs'), isTrue);
      expect(isKugouPrivateAudioUrl('https://x/a.m4a'), isFalse);
      expect(isKugouPrivateAudioUrl(''), isFalse);
    });
  });

  group('OrderSongEntry', () {
    test('从 song_info / user_info 嵌套结构解析点歌条目', () {
      final e = OrderSongEntry.fromJson({
        'song_info': {'hash': 'H1', 'mixsongid': '5', 'songname': '夜曲'},
        'user_info': {'userid': 'U1', 'nick_name': '小李'},
      });
      expect(e.song.hash, 'H1');
      expect(e.song.name, '夜曲');
      expect(e.orderUserId, 'U1');
      expect(e.orderNickname, '小李');
    });

    test('user_info 缺失时昵称兜底', () {
      final e = OrderSongEntry.fromJson({
        'song_info': {'hash': 'H2'},
      });
      expect(e.orderNickname, '房间成员');
      expect(e.orderUserId, '');
    });
  });

  group('RoomSong.fromSong（播放器歌曲 → 房间曲目身份）', () {
    Song online({String id = 'HASH1', String? albumAudioId = '9001'}) => Song(
          id: id,
          title: '晴天.mp3',
          artist: '周杰伦',
          album: '叶惠美',
          duration: const Duration(seconds: 269),
          isOnline: true,
          albumAudioId: albumAudioId,
          artworkUri: 'https://x/c.jpg',
        );

    test('在线歌曲映射出 hash / mixSongId 与展示用歌名', () {
      final rs = RoomSong.fromSong(online());
      expect(rs.hash, 'HASH1');
      expect(rs.mixSongId, '9001');
      // 与 Song.displayName 同口径：剥离扩展名
      expect(rs.name, '晴天');
      expect(rs.singer, '周杰伦');
      expect(rs.durationSeconds, 269);
      expect(rs.coverUrl, 'https://x/c.jpg');
    });

    test('本地文件不给 hash —— 调用方据此拒绝入房', () {
      // 本地音乐 id 形如 local_/storage/...，上报上游会变成成员端无法解析的曲目
      final rs = RoomSong.fromSong(Song(
        id: 'local_/storage/emulated/0/Music/a.mp3',
        title: '本地歌',
        artist: '未知艺术家',
        album: '',
        duration: const Duration(seconds: 100),
        localPath: '/storage/emulated/0/Music/a.mp3',
        isOnline: false,
      ));
      expect(rs.hash, isEmpty);
    });

    test('isOnline 为真但带回本地路径（播放中已回写）同样不给 hash', () {
      final song = online().copyWith(localPath: '/cache/a.mp3');
      expect(RoomSong.fromSong(song).hash, isEmpty);
    });
  });

  group('roomAudiosFromPlaylist（建房初始歌单过滤）', () {
    Song local(String path) => Song(
          id: 'local_$path',
          title: '本地歌.mp3',
          artist: '未知',
          album: '',
          duration: const Duration(seconds: 1),
          localPath: path,
          isOnline: false,
        );
    Song remote(String hash) => Song(
          id: hash,
          title: '在线歌',
          artist: '歌手',
          album: '',
          duration: const Duration(seconds: 1),
          isOnline: true,
        );

    test('剔除本地音乐，只保留在线曲目', () {
      final list = roomAudiosFromPlaylist([
        remote('H1'),
        local('/a.mp3'),
        remote('H2'),
      ]);
      expect(list.map((e) => e.hash), ['H1', 'H2']);
    });

    test('按 hash 去重且保持队列顺序', () {
      final list = roomAudiosFromPlaylist([
        remote('H1'),
        remote('h1'),
        remote('H2'),
      ]);
      expect(list.map((e) => e.hash), ['H1', 'H2']);
    });

    test('全部为本地音乐时返回空表（建房据此提前拦截）', () {
      expect(roomAudiosFromPlaylist([local('/a.mp3'), local('/b.mp3')]), isEmpty);
    });

    test('limit 限制上报条数（上游单批上限）', () {
      final many = List.generate(40, (i) => remote('H$i'));
      expect(roomAudiosFromPlaylist(many, limit: 30).length, 30);
    });
  });

  group('RoomSong 歌曲身份字段（歌手/专辑详情跳转依赖）', () {
    test('fromJson 解析 artist_id / album_id 的多种候选键', () {
      final song = RoomSong.fromJson(const {
        'hash': 'abc',
        'audio_name': '某首歌',
        'singer_name': '某歌手',
        'artist_id': 12345,
        'album_id': '67890',
      });
      expect(song.artistId, '12345');
      expect(song.albumId, '67890');
    });

    test('fromJson 缺字段时 artistId/albumId 为空串而非 null', () {
      final song = RoomSong.fromJson(const {'hash': 'abc'});
      expect(song.artistId, '');
      expect(song.albumId, '');
    });

    test('fromJson 兼容 author_id / albumid 变体', () {
      final song = RoomSong.fromJson(const {
        'hash': 'abc',
        'author_id': '111',
        'albumid': '222',
      });
      expect(song.artistId, '111');
      expect(song.albumId, '222');
    });

    test('toSong 把身份字段带进 Song（详情页入口的条件）', () {
      const room = RoomSong(
        hash: 'abc',
        originalHash: '',
        mixSongId: 'mix',
        name: '某首歌',
        singer: '某歌手',
        durationSeconds: 200,
        coverUrl: 'https://img/x.jpg',
        orderUserId: '',
        artistId: '12345',
        albumId: '67890',
      );
      final song = room.toSong();
      expect(song.artistId, '12345');
      expect(song.albumId, '67890');
      expect(song.isOnline, isTrue);
    });

    test('toSong 身份为空串时给 null（避免详情页拿到空串又走一遍分支）', () {
      const room = RoomSong(
        hash: 'abc',
        originalHash: '',
        mixSongId: '',
        name: '某首歌',
        singer: '某歌手',
        durationSeconds: 0,
        coverUrl: '',
        orderUserId: '',
        artistId: '',
        albumId: '',
      );
      final song = room.toSong();
      expect(song.artistId, isNull);
      expect(song.albumId, isNull);
    });

    test('toSong 的空 playUrl 必须归一成 null（音源从未被替换的根因）', () {
      // PlayerProvider.playSong 用 `song.url == null` 决定是否走在线解析；
      // 授权地址不可用时 _playRoomSong 传的是空串，若 Song.url == '' 则
      // playSong 跳过解析 → _resolvePlaybackUrl 对在线歌曲原样返回 '' →
      // 判定「解析失败」返回：UI 已切到房主歌曲，音频源却从未替换。
      const room = RoomSong(
        hash: 'abc',
        originalHash: '',
        mixSongId: 'mix',
        name: '某首歌',
        singer: '某歌手',
        durationSeconds: 200,
        coverUrl: '',
        orderUserId: '',
      );
      expect(room.toSong(playUrl: '').url, isNull);
      expect(room.toSong(playUrl: '  ').url, isNull);
      expect(room.toSong(playUrl: null).url, isNull);
      expect(room.toSong(playUrl: 'https://x/play.m4a').url, 'https://x/play.m4a');
    });

    test('fromSong 从播放器歌曲带出 artistId/albumId', () {
      final song = Song(
        id: 'abc',
        title: '某首歌',
        artist: '某歌手',
        album: '某专辑',
        duration: const Duration(seconds: 200),
        isOnline: true,
        artistId: '12345',
        albumId: '67890',
      );
      final room = RoomSong.fromSong(song);
      expect(room.artistId, '12345');
      expect(room.albumId, '67890');
    });
  });

  group('富化写入身份字段的口径', () {
    test('KugouSongDetail.toSong 保留 artistId/albumId 供富化读取', () {
      final detail = KugouSongDetail(
        hash: 'abc',
        songName: '某首歌',
        artistName: '某歌手',
        artistId: '12345',
        albumId: '67890',
        albumName: '某专辑',
        duration: 200,
      );
      final song = detail.toSong();
      expect(song.artistId, '12345');
      expect(song.albumId, '67890');
    });

    test('RoomSong.copyWith 可写 artistId/albumId 且不影响身份字段', () {
      const room = RoomSong(
        hash: 'abc',
        originalHash: 'orig',
        mixSongId: 'mix',
        name: '',
        singer: '',
        durationSeconds: 0,
        coverUrl: '',
        orderUserId: 'u1',
        artistId: '',
        albumId: '',
      );
      final enriched = room.copyWith(
        name: '某首歌',
        singer: '某歌手',
        artistId: '12345',
        albumId: '67890',
      );
      expect(enriched.hash, 'abc');
      expect(enriched.originalHash, 'orig');
      expect(enriched.mixSongId, 'mix');
      expect(enriched.orderUserId, 'u1');
      expect(enriched.artistId, '12345');
      expect(enriched.albumId, '67890');
    });

    test('copyWith 不传 name 时保留原值（空串不被覆盖为空）', () {
      const room = RoomSong(
        hash: 'abc',
        originalHash: '',
        mixSongId: '',
        name: '原名',
        singer: '原歌手',
        durationSeconds: 100,
        coverUrl: 'https://img/a.jpg',
        orderUserId: '',
        artistId: '1',
        albumId: '2',
      );
      final same = room.copyWith(artistId: '9');
      expect(same.name, '原名');
      expect(same.singer, '原歌手');
      expect(same.coverUrl, 'https://img/a.jpg');
      expect(same.durationSeconds, 100);
      expect(same.artistId, '9');
    });
  });

  group('当前歌回写覆盖范围（详情页入口依赖）', () {
    test('从 RoomSong 回写时，空身份字段被补齐', () {
      // 模拟跟随起播后的薄 Song：只有 hash/mixSongId，无身份、无封面
      final current = Song(
        id: 'abc',
        title: '未知歌曲',
        artist: '未知歌手',
        album: '',
        duration: Duration.zero,
        isOnline: true,
        albumAudioId: 'mix',
      );
      const room = RoomSong(
        hash: 'abc',
        originalHash: '',
        mixSongId: 'mix',
        name: '某首歌',
        singer: '某歌手',
        durationSeconds: 200,
        coverUrl: 'https://img/x.jpg',
        orderUserId: '',
        artistId: '12345',
        albumId: '67890',
      );
      final patched = current.copyWith(
        title: room.name,
        artist: room.singer,
        artworkUri: room.coverUrl,
        artistId: room.artistId.isEmpty ? null : room.artistId,
        albumId: room.albumId.isEmpty ? null : room.albumId,
      );
      expect(patched.title, '某首歌');
      expect(patched.artist, '某歌手');
      expect(patched.artworkUri, 'https://img/x.jpg');
      expect(patched.artistId, '12345');
      expect(patched.albumId, '67890');
      // 身份字段回写不得影响曲目身份
      expect(patched.id, 'abc');
      expect(patched.albumAudioId, 'mix');
    });
  });

  /// 一起听跟随端的核心陷阱：房间侧 hash 与搜索索引的标准版权 hash
  /// **值不相等**。富化的搜索反查必须用 /audio 回包的标准 hash 去匹配，
  /// 用房间 hash 匹配必然零命中。
  ///
  /// 本组数值全部取自真机实测（tmp/audio_raw.json + tmp/search.json），
  /// 是「匹配维度错位」根因的回归护栏。
  group('hash 别名：搜索匹配维度', () {
    // 房间侧 OGG 授权哈希（歌单接口给的）
    const roomHash = 'c01c9be16c6c08ceef72d401398301f4';
    // /audio 回包的标准版权哈希
    const standardHash = 'FF3BA0A7AD50D5BEBB2ED7907F15608C';

    test('/audio 回包的 hash 与房间 hash 不同值（别名现象）', () {
      final detail = KugouSongDetail.fromJson({
        'hash': standardHash,
        'hash_128': standardHash,
        'hash_320': 'D0B0C4D83D770240983BF651284195AC',
        'hash_flac': '64A1CB6884B980188D340A1C571DCA2D',
        'audio_name': 'G.E.M.邓紫棋 - 桃花诺',
      });

      expect(detail.hash.toLowerCase(), isNot(roomHash));
      // 标准 hash 落在 FileHash 位置，供搜索匹配
      expect(detail.hash.toLowerCase(), standardHash.toLowerCase());
    });

    test('用 /audio 标准 hash 能命中搜索结果（含各音质别名）', () {
      final detail = KugouSongDetail.fromJson({
        'hash': standardHash,
        'hash_320': 'D0B0C4D83D770240983BF651284195AC',
        'hash_flac': '64A1CB6884B980188D340A1C571DCA2D',
      });
      // 富化路径构造的匹配集合：标准 hash + 各音质 hash，全部小写
      final matchHashes = <String>{
        detail.hash.toLowerCase(),
        if (detail.hash128 != null) detail.hash128!.toLowerCase(),
        if (detail.hash320 != null) detail.hash320!.toLowerCase(),
        if (detail.hqHash != null) detail.hqHash!.toLowerCase(),
        if (detail.sqHash != null) detail.sqHash!.toLowerCase(),
      }..removeWhere((h) => h.isEmpty);

      // 搜索结果候选（真机抓包的首条）
      final candidate = KugouSongDetail.fromJson({
        'FileHash': 'FF3BA0A7AD50D5BEBB2ED7907F15608C',
        'HQFileHash': '830D9E31134D59052AC461DEB30F9C55',
        'SQFileHash': '9A77E892E392E865CCDB969521777BB1',
        'SongName': '桃花诺',
      });
      final candidateHashes = [
        candidate.hash,
        candidate.hash128 ?? '',
        candidate.hash320 ?? '',
        candidate.hqHash ?? '',
        candidate.sqHash ?? '',
      ];

      final matched = candidateHashes.any(
        (h) => h.isNotEmpty && matchHashes.contains(h.toLowerCase()),
      );
      expect(matched, isTrue, reason: '标准 hash 应命中搜索候选的 FileHash');
    });

    test('用房间 hash 匹配搜索结果零命中（旧逻辑失效的护栏）', () {
      final matchHashes = <String>{roomHash.toLowerCase()};
      final candidateHashes = [
        'FF3BA0A7AD50D5BEBB2ED7907F15608C',
        '830D9E31134D59052AC461DEB30F9C55',
        '9A77E892E392E865CCDB969521777BB1',
        '433AE4411CEF0B02A1017D9500F93CD0',
        '6BDE4FD59A63A21F5DA182C29FBA25B4',
        '789D3F4751868ABE35BD748A233CA6F5',
        'E7C2BC319F88ADED06EC7C65366C28DA',
      ].map((h) => h.toLowerCase());

      final matched = candidateHashes.any(matchHashes.contains);
      expect(matched, isFalse, reason: '房间 hash 不在搜索索引中，必然落空');
    });

    test('命中后能取到详情页跳转所需的身份与封面字段', () {
      final hit = KugouSongDetail.fromJson({
        'FileHash': 'FF3BA0A7AD50D5BEBB2ED7907F15608C',
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

      final song = hit.toSong();
      expect(song.artistId, '4490');
      expect(song.albumId, '2681514');
      expect(song.album, '桃花诺');
      expect(song.artworkUri, contains('/400/'));
      expect(song.artworkUri, isNot(contains('{size}')));
    });
  });

  group('RoomSong.matchesRemote', () {
    RoomSong song({String hash = 'AAA', String original = '', String mix = '9'}) =>
        RoomSong(
          hash: hash,
          originalHash: original,
          mixSongId: mix,
          name: '',
          singer: '',
          durationSeconds: 0,
          coverUrl: '',
          orderUserId: '',
        );

    PlayerSyncState remote({String hash = 'AAA', String mix = '9'}) => PlayerSyncState(
          hash: hash,
          originalHash: '',
          mixSongId: mix,
          isPlaying: true,
          progressMs: 0,
          durationMs: 0,
          listVersion: '',
          updatedAtMs: 0,
        );

    test('hash 忽略大小写命中', () {
      expect(song(hash: 'aaa').matchesRemote(remote(hash: 'AAA')), isTrue);
    });

    test('genting_hash（originalHash）命中', () {
      expect(song(hash: 'X', original: 'BBB').matchesRemote(remote(hash: 'bbb')), isTrue);
    });

    test('mixSongId 命中', () {
      expect(song(hash: 'X', mix: '12345').matchesRemote(remote(hash: 'Y', mix: '12345')), isTrue);
    });

    test('mixSongId 为 0 或空时不参与匹配', () {
      expect(song(hash: 'X', mix: '0').matchesRemote(remote(hash: 'Y', mix: '0')), isFalse);
      expect(song(hash: 'X', mix: '').matchesRemote(remote(hash: 'Y', mix: '')), isFalse);
    });
  });

  group('mergeRoomSongPreferRicher（元数据评分择优）', () {
    RoomSong s({
      String name = '',
      String singer = '',
      String cover = '',
      int duration = 0,
      String hash = 'AAA',
      String mix = '9',
    }) =>
        RoomSong(
          hash: hash,
          originalHash: '',
          mixSongId: mix,
          name: name,
          singer: singer,
          durationSeconds: duration,
          coverUrl: cover,
          orderUserId: '',
        );

    test('原始文件名不算「有用歌名」，不得覆盖已富化的干净歌名', () {
      final cached = s(name: '晴天', singer: '周杰伦', cover: 'http://c.jpg', duration: 269);
      final incoming = s(name: '周杰伦 - 晴天.mp3');
      final merged = mergeRoomSongPreferRicher(cached, incoming);
      expect(merged.name, '晴天');
      expect(merged.singer, '周杰伦');
      expect(merged.coverUrl, 'http://c.jpg');
      expect(merged.durationSeconds, 269);
    });

    test('「未知歌曲」占位值不算有用歌名', () {
      expect(isUsefulRoomSongName('未知歌曲'), isFalse);
      expect(isUsefulRoomSongName('  '), isFalse);
      expect(isUsefulRoomSongName('晴天'), isTrue);
    });

    test('新值更完整时采用新值', () {
      final cached = s(name: '晴天');
      final incoming = s(name: '晴天', singer: '周杰伦', cover: 'http://c.jpg');
      final merged = mergeRoomSongPreferRicher(cached, incoming);
      expect(merged.singer, '周杰伦');
      expect(merged.coverUrl, 'http://c.jpg');
    });

    test('身份字段非空优先，不被合并改写', () {
      final cached = s(hash: 'CACHED', mix: '111');
      final incoming = s(hash: 'INCOMING', mix: '222', name: '晴天', singer: '周杰伦');
      final merged = mergeRoomSongPreferRicher(cached, incoming);
      expect(merged.hash, 'CACHED');
      expect(merged.mixSongId, '111');
    });

    test('mixSongId 为 0 视为无效，采用新值', () {
      final merged = mergeRoomSongPreferRicher(s(mix: '0'), s(mix: '222'));
      expect(merged.mixSongId, '222');
    });
  });

  group('mergeMyRooms（多源合并）', () {
    MusicRoomBrief room(String id, {String owner = 'me', String name = ''}) =>
        MusicRoomBrief(
          roomId: id,
          name: name.isEmpty ? 'room-$id' : name,
          notice: '',
          backgroundUrl: '',
          currentSongCover: '',
          memberCount: 0,
          capacity: 0,
          ownerId: owner,
          ownerName: 'owner',
          currentSongName: '',
          currentArtistName: '',
          closed: false,
        );

    test('按房间号去重，详情覆盖历史，created 覆盖详情', () {
      final r = mergeMyRooms(
        created: [room('a', name: 'created-a')],
        detailed: [room('a', name: 'detail-a'), room('b')],
        history: [room('a', name: 'history-a'), room('c')],
        selfUserId: 'me',
      );
      final byId = {for (final e in r) e.roomId: e};
      expect(r.length, 3);
      expect(byId['a']!.name, 'created-a');
      expect(byId['b']!.name, 'room-b');
      expect(byId['c']!.name, 'room-c');
    });

    test('history / detailed 只保留自己名下的房间，created 不过滤', () {
      final r = mergeMyRooms(
        created: [room('x', owner: '')],
        detailed: [room('y', owner: 'other')],
        history: [room('z', owner: 'other')],
        selfUserId: 'me',
      );
      expect(r.map((e) => e.roomId), ['x']);
    });

    test('解散房间一律剔除', () {
      final closed = MusicRoomBrief(
        roomId: 'gone',
        name: 'gone',
        notice: '',
        backgroundUrl: '',
        currentSongCover: '',
        memberCount: 0,
        capacity: 0,
        ownerId: 'me',
        ownerName: 'owner',
        currentSongName: '',
        currentArtistName: '',
        closed: true,
      );
      final r = mergeMyRooms(
        created: [closed],
        detailed: const [],
        history: const [],
        selfUserId: 'me',
      );
      expect(r, isEmpty);
    });

    test('全部源为空时返回空列表（不抛异常）', () {
      expect(
        mergeMyRooms(created: const [], detailed: const [], history: const [], selfUserId: 'me'),
        isEmpty,
      );
    });
  });
}
