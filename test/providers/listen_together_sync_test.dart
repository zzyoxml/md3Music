import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/listen_together_provider.dart';
import 'package:md3music/services/kugou_api/listen_together_models.dart';

PlayerSyncState _remote({
  String hash = 'H1',
  bool playing = true,
  int progressMs = 10000,
  int updatedAtMs = 0,
  String listVersion = 'v1',
}) =>
    PlayerSyncState(
      hash: hash,
      originalHash: '',
      mixSongId: '1',
      isPlaying: playing,
      progressMs: progressMs,
      durationMs: 200000,
      listVersion: listVersion,
      updatedAtMs: updatedAtMs,
    );

void main() {
  group('enrichSearchArtist（搜索词歌手归一）', () {
    test('多歌手「、」连接取首位', () {
      expect(enrichSearchArtist('Jonas Blue、RANI'), 'Jonas Blue');
      expect(enrichSearchArtist('The Midnight、Nikki Flores'), 'The Midnight');
    });

    test('单歌手与空串', () {
      expect(enrichSearchArtist('Adele'), 'Adele');
      expect(enrichSearchArtist(' Adele '), 'Adele');
      expect(enrichSearchArtist(''), '');
    });
  });

  group('isSameSongTitle（搜索兜底歌名判定）', () {
    test('精确相等（忽略大小写/空白/全角括号）', () {
      expect(isSameSongTitle('Jason', 'Jason'), isTrue);
      expect(isSameSongTitle('jason', 'Jason'), isTrue);
      expect(isSameSongTitle('Go (Explicit)', 'Go（Explicit）'), isTrue);
      expect(isSameSongTitle('Go(Explicit)', 'Go ( Explicit )'), isTrue);
    });

    test('搜索结果带「歌手 - 」前缀时剥离后比较', () {
      expect(isSameSongTitle('The Midnight - Jason', 'Jason'), isTrue);
    });

    test('不同歌/空串为 false', () {
      expect(isSameSongTitle('Jason', 'Jasou'), isFalse);
      expect(isSameSongTitle('Jason (Live)', 'Jason'), isFalse);
      expect(isSameSongTitle('', 'Jason'), isFalse);
    });
  });

  group('decideSync（成员跟随远端）', () {
    test('远端换歌 → switchSong', () {
      final d = decideSync(
        localHash: 'OLD',
        localPlaying: true,
        localPositionMs: 5000,
        remote: _remote(hash: 'NEW'),
        nowMs: 0,
      );
      expect(d.action, SyncAction.switchSong);
      expect(d.targetHash, 'NEW');
    });

    test('hash 大小写不同视为同一首歌（不误判换歌）', () {
      final d = decideSync(
        localHash: 'h1',
        localPlaying: true,
        localPositionMs: 9000,
        remote: _remote(hash: 'H1'),
        nowMs: 0,
      );
      expect(d.action, SyncAction.none);
    });

    test('hash 不同但 mixSongId 相同 → 同歌不换', () {
      // 上游 cur_song 身份与本地歌曲 id 形式错位时的兜底：
      // 房主刚建完房不应被无元数据的歌单条目覆盖当前歌
      final d = decideSync(
        localHash: 'OLD',
        localMixSongId: '1',
        localPlaying: true,
        localPositionMs: 9000,
        remote: _remote(hash: 'NEW'),
        nowMs: 0,
      );
      expect(d.action, SyncAction.none);
    });

    test('mixSongId 不同且 hash 不同 → 仍是换歌', () {
      final d = decideSync(
        localHash: 'OLD',
        localMixSongId: '999',
        localPlaying: true,
        localPositionMs: 5000,
        remote: _remote(hash: 'NEW'),
        nowMs: 0,
      );
      expect(d.action, SyncAction.switchSong);
    });

    test('远端 hash 为空（房间暂无歌曲）→ none', () {
      final d = decideSync(
        localHash: 'H1',
        localPlaying: true,
        localPositionMs: 1000,
        remote: _remote(hash: ''),
        nowMs: 0,
      );
      expect(d.action, SyncAction.none);
    });

    test('本地无歌（首次入房）→ switchSong', () {
      final d = decideSync(
        localHash: null,
        localPlaying: false,
        localPositionMs: 0,
        remote: _remote(hash: 'H1'),
        nowMs: 0,
      );
      expect(d.action, SyncAction.switchSong);
      expect(d.targetHash, 'H1');
    });

    test('同歌、远端暂停、本地播放 → pause', () {
      final d = decideSync(
        localHash: 'H1',
        localPlaying: true,
        localPositionMs: 9000,
        remote: _remote(playing: false),
        nowMs: 0,
      );
      expect(d.action, SyncAction.pause);
    });

    test('听众本地暂停优先：远端播放也不自动 resume', () {
      final d = decideSync(
        localHash: 'H1',
        localPlaying: false,
        localPositionMs: 9000,
        remote: _remote(playing: true),
        nowMs: 0,
        guestLocallyPaused: true,
      );
      expect(d.action, SyncAction.none);
    });

    test('同歌、远端播放、本地暂停（未本地暂停）→ resume', () {
      final d = decideSync(
        localHash: 'H1',
        localPlaying: false,
        localPositionMs: 9000,
        remote: _remote(playing: true),
        nowMs: 0,
      );
      expect(d.action, SyncAction.resume);
    });

    test('播放态进度差超容差 → seek 到投影位置（含快照时间推进）', () {
      const now = 1000000;
      final d = decideSync(
        localHash: 'H1',
        localPlaying: true,
        localPositionMs: 2000,
        remote: _remote(progressMs: 10000, updatedAtMs: now - 3000),
        nowMs: now,
      );
      expect(d.action, SyncAction.seek);
      expect(d.targetPositionMs, 13000); // 10000 + 3 秒投影
    });

    test('播放态进度差小于容差 → none', () {
      final d = decideSync(
        localHash: 'H1',
        localPlaying: true,
        localPositionMs: 8000,
        remote: _remote(progressMs: 10000, updatedAtMs: 0),
        nowMs: 0,
      );
      expect(d.action, SyncAction.none);
    });

    test('双击换歌与进度同时偏差时换歌优先', () {
      const now = 1000000;
      final d = decideSync(
        localHash: 'OLD',
        localPlaying: true,
        localPositionMs: 0,
        remote: _remote(hash: 'NEW', progressMs: 30000, updatedAtMs: now - 1000),
        nowMs: now,
      );
      expect(d.action, SyncAction.switchSong);
      expect(d.targetHash, 'NEW');
    });

    test('听众本地暂停时远端换歌仍判定为 switchSong（不得因暂停而停在旧歌）', () {
      final d = decideSync(
        localHash: 'OLD',
        localPlaying: false,
        localPositionMs: 0,
        remote: _remote(hash: 'NEW'),
        nowMs: 0,
        guestLocallyPaused: true,
      );
      expect(d.action, SyncAction.switchSong);
      expect(d.targetHash, 'NEW');
    });

    test('听众本地暂停时同歌远端在播 → none（不自动恢复播放）', () {
      final d = decideSync(
        localHash: 'H1',
        localPlaying: false,
        localPositionMs: 3000,
        remote: _remote(hash: 'H1', progressMs: 30000),
        nowMs: 0,
        guestLocallyPaused: true,
      );
      expect(d.action, SyncAction.none);
    });

    test('豁免标记置位但本机实际在播 → 仍走漂移校准（实测恢复播放后被迟到'
        'pause 通告重新置豁免，一刀切 none 会让听众永远停在自己的进度）', () {
      final d = decideSync(
        localHash: 'H1',
        localPlaying: true,
        localPositionMs: 3000,
        remote: _remote(hash: 'H1', progressMs: 30000),
        nowMs: 0,
        guestLocallyPaused: true,
      );
      expect(d.action, SyncAction.seek);
      expect(d.targetPositionMs, 30000);
    });
  });

  group('跟随装载完成后的播放态决策（切歌续播）', () {
    test('听众自己暂停的（startPaused）→ 装载完保持暂停', () {
      expect(
        resolveFollowLoadPlayback(
          startPaused: true,
          latestIsPlaying: true,
          localPlaying: false,
        ),
        FollowLoadAction.pause,
      );
    });

    test('最新快照在播、本机暂停 → 立即续播（装载完成即刻纠正）', () {
      expect(
        resolveFollowLoadPlayback(
          startPaused: false,
          latestIsPlaying: true,
          localPlaying: false,
        ),
        FollowLoadAction.play,
      );
    });

    test('最新快照在播、本机已在播 → 不动作', () {
      expect(
        resolveFollowLoadPlayback(
          startPaused: false,
          latestIsPlaying: true,
          localPlaying: true,
        ),
        FollowLoadAction.none,
      );
    });

    test('最新快照暂停、本机在播 → 纠偏暂停', () {
      expect(
        resolveFollowLoadPlayback(
          startPaused: false,
          latestIsPlaying: false,
          localPlaying: true,
        ),
        FollowLoadAction.pause,
      );
    });

    test('无匹配快照（null）→ 不动作（旧行为把 null 当暂停，无条件杀掉新歌）', () {
      expect(
        resolveFollowLoadPlayback(
          startPaused: false,
          latestIsPlaying: null,
          localPlaying: false,
        ),
        FollowLoadAction.none,
      );
      expect(
        resolveFollowLoadPlayback(
          startPaused: false,
          latestIsPlaying: null,
          localPlaying: true,
        ),
        FollowLoadAction.none,
      );
    });
  });

  group('房主播放态权威（暂停后不被快照回声拉起）', () {
    test('房主本地有歌 → 不采纳远端播放态', () {
      // 复现链：房主暂停并上报 → 报告完成时立刻同步，读回的是上报前的旧快照
      // （pause=1）→ 若按快照纠偏就会 resume，表现为「暂停后又自己播起来」
      expect(shouldOwnerFollowRemotePlaying(localHasSong: true), isFalse);
    });

    test('房主本地无歌（跨设备恢复会话）→ 必须按远端起播', () {
      expect(shouldOwnerFollowRemotePlaying(localHasSong: false), isTrue);
    });

    test('该判定只影响播放态：decideSync 仍给出 resume，由调用方决定是否采纳', () {
      // decideSync 保持纯函数语义（听众端与房主端共用），房主端单独过滤
      final d = decideSync(
        localHash: 'H1',
        localPlaying: false,
        localPositionMs: 9000,
        remote: _remote(playing: true),
        nowMs: 0,
      );
      expect(d.action, SyncAction.resume);
      expect(shouldOwnerFollowRemotePlaying(localHasSong: true), isFalse);
    });
  });

  group('buildSeekKey（seek 幂等）', () {
    test('同一快照同一位置生成相同键，快照或位置变化则不同', () {
      final k1 = buildSeekKey(roomId: 'R', hash: 'H', updatedAtMs: 5, positionMs: 1000);
      final k2 = buildSeekKey(roomId: 'R', hash: 'H', updatedAtMs: 5, positionMs: 1000);
      final k3 = buildSeekKey(roomId: 'R', hash: 'H', updatedAtMs: 6, positionMs: 1000);
      final k4 = buildSeekKey(roomId: 'R', hash: 'H', updatedAtMs: 5, positionMs: 2000);
      final k5 = buildSeekKey(roomId: 'R2', hash: 'H', updatedAtMs: 5, positionMs: 1000);
      expect(k1, k2);
      expect(k1, isNot(k3));
      expect(k1, isNot(k4));
      expect(k1, isNot(k5));
    });

    test('hash 大小写不敏感', () {
      expect(
        buildSeekKey(roomId: 'R', hash: 'AbC', updatedAtMs: 1, positionMs: 2),
        buildSeekKey(roomId: 'R', hash: 'abc', updatedAtMs: 1, positionMs: 2),
      );
    });
  });

  group('ensureSelfInMembers（听众接口不含房主本人）', () {
    RoomMember member(String userId) => RoomMember(
          userId: userId, nickname: '用户$userId', avatar: '', studyStatus: 0,
        );

    test('缺失时把本地账号补到最前', () {
      final merged = ensureSelfInMembers(
        [member('u1'), member('u2')],
        'SELF',
        nickname: '果冻',
        avatar: 'http://x/a.jpg',
      );
      expect(merged, hasLength(3));
      expect(merged.first.userId, 'SELF');
      expect(merged.first.nickname, '果冻');
      expect(merged.first.avatar, 'http://x/a.jpg');
    });

    test('已在列表中时原样返回（不重复、不换位）', () {
      final original = [member('SELF'), member('u1')];
      final merged = ensureSelfInMembers(original, 'SELF', nickname: '果冻');
      expect(identical(merged, original), isTrue);
      expect(merged, hasLength(2));
    });

    test('本地 userid 为空（未登录兜底）时不注入', () {
      final original = [member('u1')];
      expect(ensureSelfInMembers(original, ''), same(original));
    });

    test('昵称缺失时兜底为「我」', () {
      final merged = ensureSelfInMembers(const [], 'SELF');
      expect(merged.single.nickname, '我');
    });

    test('房主缺失时注入并带上头像（来源 room/detail 的 user_pic）', () {
      final merged = ensureSelfInMembers(
        [member('u1')],
        'SELF',
        ownerUserId: 'OWNER',
        ownerName: '尾鳍',
        ownerAvatar: 'http://imge.kugou.com/kugouicon/165/x.jpg',
      );
      // 实现是「先注入房主、再注入自己」，自己必然在最前
      expect(merged.map((m) => m.userId).toList(), ['SELF', 'OWNER', 'u1']);
      expect(merged[1].avatar, 'http://imge.kugou.com/kugouicon/165/x.jpg');
      expect(merged[1].nickname, '尾鳍');
    });

    test('房主头像缺省时留空（由 UI 回退占位图）', () {
      final merged = ensureSelfInMembers(
        [member('u1')],
        'SELF',
        ownerUserId: 'OWNER',
        ownerName: '尾鳍',
      );
      expect(merged[1].avatar, isEmpty);
    });

    test('自己就是房主时不重复注入', () {
      final original = [member('SELF'), member('u1')];
      final merged = ensureSelfInMembers(
        original,
        'SELF',
        ownerUserId: 'SELF',
        ownerAvatar: 'http://x/a.jpg',
      );
      expect(identical(merged, original), isTrue);
    });

    test('房主已存在时不追加（头像回填由 _backfillOwnerAvatar 负责）', () {
      final original = [member('OWNER'), member('u1')];
      final merged = ensureSelfInMembers(
        original,
        'SELF',
        ownerUserId: 'OWNER',
        ownerAvatar: 'http://x/a.jpg',
      );
      // ensureSelfInMembers 只补 SELF，不碰已存在的房主条目
      expect(merged.map((m) => m.userId).toList(), ['SELF', 'OWNER', 'u1']);
      expect(merged[1].avatar, isEmpty);
    });
  });

  group('轮询节奏常量（与实测安全值一致）', () {
    test('心跳 55 秒、快轮询 5 秒、慢轮询 15 秒', () {
      expect(kHeartbeatInterval.inSeconds, 55);
      expect(kFastPollInterval.inSeconds, 5);
      expect(kSlowPollInterval.inSeconds, 15);
    });

    test('纠偏容差与房主宽限', () {
      expect(kPlayingSyncDriftToleranceMs, 8000);
      expect(kPausedSyncDriftToleranceMs, 1500);
      expect(kOwnerControlGrace.inSeconds, 3);
      expect(kPlaybackRetryBackoff.inSeconds, 30);
      expect(kPlaylistCursorBackoff.inSeconds, 60);
    });
  });

  group('房主播放拦截口径（房间歌单内的曲目判定）', () {
    // RoomSession.ownerPlaySong 的命中判定依赖 RoomSong.sameAs，
    // 这里锁住「什么算房间曲目」以免后续改动把本地歌判成可播。
    RoomSong roomSong(String hash, {String mixSongId = ''}) => RoomSong(
          hash: hash,
          originalHash: '',
          mixSongId: mixSongId,
          name: '房间歌',
          singer: '歌手',
          durationSeconds: 1,
          coverUrl: '',
          orderUserId: '',
        );

    test('hash 大小写不同仍算命中（上游身份错位的兜底）', () {
      final target = RoomSong.fromSong(const Song(
        id: 'ABC123',
        title: 'x',
        artist: 'y',
        album: '',
        duration: Duration.zero,
        isOnline: true,
      ));
      expect(roomSong('abc123').sameAs(target), isTrue);
    });

    test('mixSongId 相同视为同一首', () {
      final target = RoomSong.fromSong(const Song(
        id: 'OTHER',
        title: 'x',
        artist: 'y',
        album: '',
        duration: Duration.zero,
        isOnline: true,
        albumAudioId: '9001',
      ));
      expect(roomSong('H1', mixSongId: '9001').sameAs(target), isTrue);
    });

    test('本地音乐无 hash，不可能命中任何房间曲目', () {
      final local = RoomSong.fromSong(const Song(
        id: 'local_/a.mp3',
        title: 'x',
        artist: 'y',
        album: '',
        duration: Duration.zero,
        isOnline: false,
        localPath: '/a.mp3',
      ));
      expect(local.hash, isEmpty);
      expect(roomSong('H1').sameAs(local), isFalse);
    });

    test('三个拒绝分支语义互斥（守卫按分支决定是否放行）', () {
      // handledByRoom：房间会话已起播，调用方必须停手（否则同一首播两遍）
      // noRoom：会话失效，调用方按普通播放放行
      // notInRoom：房间歌单外的曲目，拒绝并提示
      expect(OwnerPlayRejection.values, hasLength(3));
      expect(
        OwnerPlayRejection.values.toSet(),
        {
          OwnerPlayRejection.handledByRoom,
          OwnerPlayRejection.noRoom,
          OwnerPlayRejection.notInRoom,
        },
      );
    });
  });

  group('shouldApplyRemoteSeek（纠偏 seek 前置守卫）', () {
    bool call({
      int targetMs = 12000,
      bool playbackReady = true,
      String seekKey = 'k1',
      String? lastSeekKey,
      int nowMs = 100000,
      int lastSeekAtMs = 0,
    }) =>
        shouldApplyRemoteSeek(
          targetMs: targetMs,
          playbackReady: playbackReady,
          seekKey: seekKey,
          lastSeekKey: lastSeekKey,
          nowMs: nowMs,
          lastSeekAtMs: lastSeekAtMs,
        );

    test('目标位置无效时不 seek', () {
      expect(call(targetMs: 0), isFalse);
      expect(call(targetMs: -1), isFalse);
    });

    test('播放器未就绪时不 seek（loading 期 seek 会被静默丢弃）', () {
      expect(call(playbackReady: false), isFalse);
    });

    test('同一快照同一目标在幂等窗口内不重复 seek', () {
      expect(call(lastSeekKey: 'k1', lastSeekAtMs: 99000), isFalse);
    });

    test('窗口外可再次 seek；新目标立即允许', () {
      expect(call(lastSeekKey: 'k1', lastSeekAtMs: 90000), isTrue);
      expect(call(seekKey: 'k2', lastSeekKey: 'k1', lastSeekAtMs: 99000), isTrue);
    });
  });

  group('shouldReapplyAfterApply（动作后复查）', () {
    test('动作期间远端换歌 → 需要立即再应用一次', () {
      expect(
        shouldReapplyAfterApply(
          applied: _remote(hash: 'A', updatedAtMs: 1000),
          latest: _remote(hash: 'B', updatedAtMs: 1000),
        ),
        isTrue,
      );
    });

    test('动作期间收到更新的同歌快照 → 需要立即再应用一次', () {
      expect(
        shouldReapplyAfterApply(
          applied: _remote(hash: 'A', updatedAtMs: 1000),
          latest: _remote(hash: 'A', updatedAtMs: 6000),
        ),
        isTrue,
      );
    });

    test('远端未变 → 不再应用（否则自激循环）', () {
      expect(
        shouldReapplyAfterApply(
          applied: _remote(hash: 'A', updatedAtMs: 1000),
          latest: _remote(hash: 'A', updatedAtMs: 1000),
        ),
        isFalse,
      );
    });

    test('无最新快照 → 不再应用', () {
      expect(
        shouldReapplyAfterApply(applied: _remote(hash: 'A'), latest: null),
        isFalse,
      );
    });
  });

  group('shouldReloadUnavailableRoomSource（音源不可用重装载）', () {
    bool call({
      bool remotePlaying = true,
      bool sameSong = true,
      String? resolveError = '播放失败，请检查网络',
      int nowMs = 100000,
      int retryAfterMs = 0,
    }) =>
        shouldReloadUnavailableRoomSource(
          remotePlaying: remotePlaying,
          sameSong: sameSong,
          resolveError: resolveError,
          nowMs: nowMs,
          retryAfterMs: retryAfterMs,
        );

    test('远端在播 + 同歌 + 解析失败 + 已过退避 → 重装载', () {
      expect(call(), isTrue);
    });

    test('无失败标记 → 不重装载（正常播放不打扰）', () {
      expect(call(resolveError: null), isFalse);
      expect(call(resolveError: ''), isFalse);
    });

    test('非同一首 / 远端未在播 → 不重装载（交给换歌与暂停分支）', () {
      expect(call(sameSong: false), isFalse);
      expect(call(remotePlaying: false), isFalse);
    });

    test('退避未到点 → 不重装载（防请求风暴）', () {
      expect(call(nowMs: 100000, retryAfterMs: 100001), isFalse);
      expect(call(nowMs: 100001, retryAfterMs: 100001), isTrue);
    });
  });

  group('needsStartAlignmentFixup（起播对齐兜底）', () {
    bool call({
      Duration? requested = const Duration(seconds: 287),
      Duration actual = const Duration(seconds: 22),
      bool playbackReady = true,
    }) =>
        needsStartAlignmentFixup(
          requested: requested,
          actual: actual,
          playbackReady: playbackReady,
        );

    test('initialPosition 未落地（偏差远超容差）→ 需要补 seek', () {
      // 真机实测：请求 287s，起播返回时平台实际停在 22s
      expect(call(), isTrue);
    });

    test('已对齐（容差内）→ 不补 seek', () {
      expect(
        call(requested: const Duration(seconds: 287), actual: const Duration(seconds: 285)),
        isFalse,
      );
      expect(
        call(requested: const Duration(seconds: 287), actual: const Duration(seconds: 289)),
        isFalse,
      );
    });

    test('无起播位置（从头播）→ 兜底不适用', () {
      expect(call(requested: null), isFalse);
      expect(call(requested: Duration.zero), isFalse);
      expect(call(requested: const Duration(seconds: -3)), isFalse);
    });

    test('源尚未就绪 → 不补（等下一轮轮询）', () {
      expect(call(playbackReady: false), isFalse);
    });
  });

  group('pickPlayableRoomAudioUrl（房间授权地址挑选）', () {
    test('首条是私有格式、后面有可解码的 → 救回可解码那条', () {
      // 旧行为只取第一条 url，是 .kgs 就整条放弃、回退常规解析链；
      // 而常规解析链对大偏移 seek 极慢（实测起播卡 24s）。
      expect(
        pickPlayableRoomAudioUrl([
          'http://a.kugou.com/x.kgs',
          'http://a.kugou.com/x.flac',
        ]),
        'http://a.kugou.com/x.flac',
      );
    });

    test('全是私有格式 → 空串（回退常规解析链）', () {
      expect(pickPlayableRoomAudioUrl(['http://a/x.kgs', 'http://a/x.kgm']), '');
    });

    test('非 http 开头视为不可用', () {
      expect(
        pickPlayableRoomAudioUrl(['ftp://a/x.mp3', 'http://a/x.mp3']),
        'http://a/x.mp3',
      );
      expect(pickPlayableRoomAudioUrl(const []), '');
    });
  });

  group('collectNestedStringValues（多候选收集）', () {
    test('data.url 为字符串数组时全部收集', () {
      expect(
        collectNestedStringValues({
          'data': {'url': ['http://a/1.mp3', 'http://a/1.kgs'], 'other': 1},
        }, 'url'),
        ['http://a/1.mp3', 'http://a/1.kgs'],
      );
    });

    test('嵌套对象直给字符串也收集（与 readNestedString 同口径）', () {
      expect(
        collectNestedStringValues({
          'data': {'url': 'http://a/1.mp3'},
        }, 'url'),
        ['http://a/1.mp3'],
      );
    });

    test('缺失 / 无关 payload → 空', () {
      expect(collectNestedStringValues(null, 'url'), isEmpty);
      expect(collectNestedStringValues({'a': 1}, 'url'), isEmpty);
    });
  });

  group('decideSync force / 暂停态纠偏', () {
    // 构造方式与文件内既有用例一致（PlayerSyncState 全字段 required）
    PlayerSyncState snap({
      required String hash,
      required bool playing,
      required int progressMs,
      required int updatedAtMs,
    }) =>
        PlayerSyncState(
          hash: hash,
          originalHash: '',
          mixSongId: '100',
          isPlaying: playing,
          progressMs: progressMs,
          durationMs: 300000,
          listVersion: '',
          updatedAtMs: updatedAtMs,
        );

    test('force 时播放中容差收紧到 750ms', () {
      // updatedAtMs 与 now 相同：投影无推进，投影位置 = progressMs = 100000
      // （计划原稿 updatedAtMs: 0 会使投影外推到 200400，与注释意图不符）
      final remote = snap(hash: 'h1', playing: true, progressMs: 100000, updatedAtMs: 100400);
      final now = 100400;
      // 偏差 500ms：普通容差(8s)内不纠偏，force(750ms)内也不纠偏
      expect(
        decideSync(
          localHash: 'h1', localPlaying: true, localPositionMs: 100500,
          remote: remote, nowMs: now,
        ).action, SyncAction.none,
      );
      // 偏差 1200ms：普通容差内不纠偏，force 下纠偏
      expect(
        decideSync(
          localHash: 'h1', localPlaying: true, localPositionMs: 101200,
          remote: remote, nowMs: now,
        ).action, SyncAction.none,
      );
      expect(
        decideSync(
          localHash: 'h1', localPlaying: true, localPositionMs: 101200,
          remote: remote, nowMs: now, force: true,
        ).action, SyncAction.seek,
      );
    });

    test('双方暂停时按暂停态容差做静止纠偏', () {
      final remote = snap(hash: 'h1', playing: false, progressMs: 60000, updatedAtMs: 0);
      // 偏差 1s：暂停容差 1.5s 内不纠偏
      expect(
        decideSync(
          localHash: 'h1', localPlaying: false, localPositionMs: 61000,
          remote: remote, nowMs: 1000,
        ).action, SyncAction.none,
      );
      // 偏差 3s：纠偏目标为远端静止进度（无投影）
      final d = decideSync(
        localHash: 'h1', localPlaying: false, localPositionMs: 63000,
        remote: remote, nowMs: 1000,
      );
      expect(d.action, SyncAction.seek);
      expect(d.targetPositionMs, 60000);
    });

    test('听众本地暂停：豁免只挡自动起播，双方静止时仍静默校准位置'
        '（无声 seek 不打扰，恢复播放即在房主位置）', () {
      final remote = snap(hash: 'h1', playing: false, progressMs: 60000, updatedAtMs: 0);
      final d = decideSync(
        localHash: 'h1', localPlaying: false, localPositionMs: 63000,
        remote: remote, nowMs: 1000, guestLocallyPaused: true,
      );
      expect(d.action, SyncAction.seek);
      expect(d.targetPositionMs, 60000);
    });

    test('seekLatencyLeadMs 与 updateSeekLatencyEwma', () {
      expect(seekLatencyLeadMs(0), 0);
      expect(seekLatencyLeadMs(500), 500);
      expect(seekLatencyLeadMs(20000), 10000); // 上限 10s
      expect(updateSeekLatencyEwma(0, 100), 0); // 样本 <250ms 不采样
      expect(updateSeekLatencyEwma(0, 300), 300); // 首个样本直接采信
      expect(updateSeekLatencyEwma(300, 100), 300); // 不采样
      expect(updateSeekLatencyEwma(1000, 500), 850); // 1000*0.7 + 500*0.3
    });
  });
}
