import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/db/listen_stats_db.dart';
import '../../data/models/song.dart';
import 'playback_duration_tracker.dart';

/// 听歌统计播放记录服务：把每次真实收听（扣除暂停/拖动后的净播放时长）落库到
/// [ListenStatsDb]，供「听歌统计」按账号查询聚合。
///
/// 与同一切歌边沿驱动的另外两条链路的分工：
/// - `ListenReportService`：CSCC 真实播放事件上报（仅在线歌，需登录，走网络）；
/// - `PlayHistorySyncService`：云端播放历史上传（仅在线歌，需登录，走网络）；
/// - 本服务：**本地库记账**，不区分在线/本地歌、不要求登录（未登录落空
///   `user_id`），纯本地写入无网络依赖，失败仅日志不影响播放。
///
/// 设计要点：
/// 1. 单例，内部自持独立的 [PlaybackDurationTracker]（三条链路口径一致——
///    暂停不计时、seek 不产生时长——但各自独立计段，互不干扰）；
/// 2. **幂等**：同一首歌（同 songId）上一段尚未结算时重复 start 不重置计段，
///    避免同一段收听被清零或重复；正常路径下切歌边沿都先显式 end，
///    此守卫只兜底重复边沿；
/// 3. 入库 fire-and-forget：调用方无需 await，异常只打日志不上抛；
/// 4. 受「听歌统计记录」开关总控（默认开启，阶段G 接入）：镜像读法见
///    [recordingEnabled] —— 播放边沿同步读镜像不等 SharedPreferences，
///    首次使用时异步播种一次；
/// 5. 单曲循环/自然播完不在此服务单独结算：段持续累计到切歌边沿或退出结算
///    为止（净时长口径不变），end_reason 记为 `switched`/`stopped`。
class ListenStatsRecordService {
  ListenStatsRecordService({ListenStatsDb? db, PlaybackDurationTracker? tracker})
      : _dbOverride = db,
        tracker = tracker ?? PlaybackDurationTracker();

  static final ListenStatsRecordService instance = ListenStatsRecordService();

  /// 「听歌统计记录」开关镜像（默认开启）。
  ///
  /// 播放边沿（每首歌一次）同步读此镜像，**不**逐次 await SharedPreferences；
  /// 真实持久值由 [ListenStatsRecordService.syncRecordingEnabledFromPrefs]
  /// 在首次使用时播种一次，设置页的 setter（SettingsRepository.
  /// setListenStatsRecordingEnabled）写盘前同步更新镜像，开关操作即时生效。
  static final ValueNotifier<bool> recordingEnabled = ValueNotifier<bool>(true);

  /// 开关的 prefs key。与 SettingsRepository._keyListenStatsRecordingEnabled
  /// 逐字一致（本服务不反向 import 数据层，沿用 ListenReportService 各持一份
  /// 常量的先例），任一侧改名需同步。
  static const String _recordingEnabledPrefsKey =
      'settings_listen_stats_recording_enabled';

  /// 镜像是否已从持久层播种过（每进程一次）。
  bool _recordingEnabledSeeded = false;

  /// 首次使用时从 SharedPreferences 播种开关镜像（之后同步读镜像）。
  /// 失败静默：保持默认开启，不影响播放链路。
  Future<void> syncRecordingEnabledFromPrefs() async {
    if (_recordingEnabledSeeded) return;
    _recordingEnabledSeeded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      recordingEnabled.value =
          prefs.getBool(_recordingEnabledPrefsKey) ?? true;
    } catch (_) {
      // 读不到持久值不阻塞记账：镜像维持当前值（默认开启）
    }
  }

  /// 测试注入的库；null 时使用默认路径库（应用支持目录/listen_stats.db）。
  final ListenStatsDb? _dbOverride;

  /// 默认库：进程内共享一个实例即可（写入方只有本服务），
  /// [ListenStatsDb] 懒开库，构造无 IO。
  static final ListenStatsDb _defaultDb = ListenStatsDb();

  /// 时间源可注入，便于测试（同 PlayHistorySyncService 暴露 tracker 的做法）。
  PlaybackDurationTracker tracker;

  /// 当前计时段的歌曲元数据（与 tracker 当前段一一对应）。
  ///
  /// 结算入库时必须用**该段开始时**登记的那首歌——切歌瞬间先取段再覆盖，
  /// 避免 A 段的时长写到 B 的元数据上。
  Song? _currentMeta;

  ListenStatsDb get _db => _dbOverride ?? _defaultDb;

  /// 歌曲开始播放（切歌边沿，由 PlayerProvider 调用；本地歌同样记录）。
  ///
  /// [playing] 此刻是否真的在出声：切歌瞬间常处于「已换曲但还在缓冲」
  /// （playingStream 尚未翻 true），必须如实透传给 tracker，否则会把缓冲
  /// 等待计入时长（口径与 ListenReportService 一致）。
  Future<void> onSongStarted({
    required Song song,
    bool playing = true,
  }) async {
    // 开关关闭：不记账。清掉可能残留的段与元数据，避免重新打开后把
    // 「关闭期间」的收听补记入库（用户关闭开关的意图优先）。
    await syncRecordingEnabledFromPrefs();
    if (!recordingEnabled.value) {
      discard();
      return;
    }
    final songId = song.id;
    if (songId.isEmpty) return;
    // 幂等：同曲且上一段尚未结算时不重置（重复 start 不应重复计段）。
    if (tracker.isTracking && tracker.songId == songId) return;
    // 先按「切换下一首」结算上一段（正常由切歌边沿显式 end，此处兜底），
    // 再登记新段。结算用的元数据必须是上一首的，故先取快照再覆盖。
    final superseded = tracker.end(reason: PlaybackEndReason.switched);
    final prevMeta = _currentMeta;
    _currentMeta = song;
    tracker.start(
      songId: songId,
      // 本地歌无 albumAudioId：tracker 只把它当作段的附属标识，不参与统计
      mixsongid: song.albumAudioId ?? '',
      playing: playing,
    );
    if (superseded != null) {
      await _persist(superseded, prevMeta);
    }
  }

  /// 播放/暂停状态变化（转发给计时器，暂停期间不累计时长）。
  void onPlayingChanged(bool playing) {
    tracker.setPlaying(playing);
  }

  /// 拖动进度（转发给计时器，seek 跳变不计入时长）。
  void onSeek() {
    tracker.onSeek();
  }

  /// 歌曲结束/被停止：结算当前段并入库（幂等：无活动段时直接返回）。
  Future<void> onSongEnded({
    PlaybackEndReason reason = PlaybackEndReason.completed,
  }) async {
    // 先结算段再判开关：与 ListenReportService 同序——无论开关状态，
    // tracker 都不能留着未结算的段（否则重开后会把关闭期间的时长补记）。
    final segment = tracker.end(reason: reason);
    if (segment == null) return;
    final meta = _currentMeta;
    _currentMeta = null;
    await syncRecordingEnabledFromPrefs();
    if (!recordingEnabled.value) return; // 关闭期间：段已结算但不入库
    await _persist(segment, meta);
  }

  /// 丢弃当前计时段（测试/异常路径兜底，不入库）。
  void discard() {
    tracker.discard();
    _currentMeta = null;
  }

  /// 结算一个播放段入库（fire-and-forget：异常仅日志，不影响播放链路）。
  Future<void> _persist(PlaybackSegment segment, Song? meta) async {
    try {
      final playedMs = segment.durationMs;
      if (playedMs <= 0) return; // 无净播放不落库（纯噪声）
      final rawDurationMs = meta?.duration.inMilliseconds ?? 0;
      final durationMs = rawDurationMs > 0 ? rawDurationMs : null;
      final title = meta?.title;
      await _db.insertRecord(
        songId: segment.songId,
        mixsongid: segment.mixsongid.isEmpty ? null : segment.mixsongid,
        // title 列 NOT NULL：元数据缺失/为空时退回 songId 兜底
        title: (title == null || title.isEmpty) ? segment.songId : title,
        artist: meta?.artist,
        album: meta?.album,
        durationMs: durationMs,
        playedMs: playedMs,
        endReason: segment.reason.name,
        valid: ListenStatsDb.isValidPlay(playedMs, durationMs),
      );
    } catch (e) {
      // ignore: avoid_print
      print('[ListenStats] 播放记录入库失败 song=${segment.songId} err=$e');
    }
  }
}
