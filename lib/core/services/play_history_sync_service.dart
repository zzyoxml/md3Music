import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../data/repositories/history_repository.dart';
import '../../data/models/song.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import 'playback_duration_tracker.dart';

/// 云端播放历史上传（`/playhistory/upload`）——「听歌历史云端统一」的写入口。
///
/// 与同开关下另外两条链路的分工（酷狗官方协议本来就是多条并存，互不重复记账）：
/// - 本服务：**播放历史列表 + 次数**（mxid/ot/pc）→ `/user/history`（跨设备
///   最近听歌历史）与 `/user/listen`（听歌排行）的数据来源；
/// - `ListenReportService`：CSCC 真实播放事件对（start/end，真实时长记账）；
/// - `ListeningGradeService`：30s 心跳 d_sec/diff_sec 等级差量。
///
/// 设计要点：
/// 1. **阈值结账**：实际播放 ≥ [minUploadMs]（15s，对齐 EchoMusic）才上传，
///    快速切歌扫过不刷历史；
/// 2. **ot** = 播放开始时间（秒级，服务端要求，传毫秒会报错）；失败重试时
///    保留原始开始时间（历史记录的是「什么时候播的」）；
/// 3. **pc** = 本地 [HistoryRepository] 的播放次数（上游保持 max(服务器, 传入)，
///    本地与云端计数天然对齐、互不回退）；
/// 4. **失败不丢**：入 pending 持久化队列（按 userid 隔离，上限截断），
///    启动与每次成功上传后重试；重试仍失败则保留队列停止（不阻塞播放）；
/// 5. 开关 = 「听歌数据云同步」`settings_upload_listening_duration`（默认开，
///    每次上报前重读 → 设置页切换即时生效）；未登录不上传不入队；
/// 6. 结账出口统一校验段所属账号，防切号把历史记到别的账号。
class PlayHistorySyncService {
  PlayHistorySyncService._();

  static final PlayHistorySyncService instance = PlayHistorySyncService._();

  /// 「听歌数据云同步」开关的 prefs key（与 SettingsRepository 保持一致）。
  static const String _uploadEnabledPrefsKey = 'settings_upload_listening_duration';

  /// pending 队列的 prefs key 前缀（实际键带 userid 后缀，按账号隔离）。
  static const String _pendingPrefsKeyPrefix = 'play_history_pending_uploads';

  /// 上传的最小实际播放时长（毫秒）。低于此值不写入云端历史。
  static const int minUploadMs = 15000;

  /// 单账号 pending 上限（防无限膨胀；超出丢最旧）。
  static const int _maxPending = 200;

  /// 时间源可注入，便于测试。
  PlaybackDurationTracker tracker = PlaybackDurationTracker();

  /// 当前计时段开始时间（秒级；= 上传的 ot）。
  int? _segmentStartedAtSec;

  /// 当前计时段所属账号（`onSongStarted` 时记下，结账时校验防切号错记）。
  String? _segmentUserid;

  bool _flushing = false;

  void init() {
    // 启动时把上次没传出去的补上（登录态/开关由 flush 内部判定）
    // ignore: discarded_futures
    unawaited(flushPending());
  }

  /// 歌曲开始播放（切歌时由 PlayerProvider 调用，时序与 CSCC 同一边沿）。
  ///
  /// 先结账上一段（[PlaybackEndReason.switched]），再登记新段：
  /// 仅「在线且带 albumAudioId」的歌曲开段——纯本地文件无云端身份，不上传。
  Future<void> onSongStarted({
    required Song song,
    bool playing = true,
  }) async {
    final superseded = tracker.snapshot(reason: PlaybackEndReason.switched);
    if (superseded != null) {
      await _settleSegment(superseded);
    }
    final mxid = song.albumAudioId;
    if (mxid == null || mxid.isEmpty) {
      // 无云端身份（纯本地文件）：不开段不计时，本段不存在可上传的东西
      _segmentStartedAtSec = null;
      _segmentUserid = null;
      return;
    }
    // 段的归属在开段时就锁定（结账时账号可能已变）
    _segmentUserid = KugouApiClient().userid;
    _segmentStartedAtSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    tracker.start(songId: song.id, mixsongid: mxid, playing: playing);
  }

  /// 播放/暂停状态变化（转发给计时器，暂停期间不累计时长）。
  void onPlayingChanged(bool playing) {
    tracker.setPlaying(playing);
  }

  /// 拖动进度（转发给计时器，seek 跳变不计入时长）。
  void onSeek() {
    tracker.onSeek();
  }

  /// 播放结束/被停止：结账当前段并尝试上传。
  Future<void> onSongEnded({
    PlaybackEndReason reason = PlaybackEndReason.completed,
  }) async {
    final segment = tracker.end(reason: reason);
    if (segment == null) return;
    await _settleSegment(segment);
  }

  /// 关闭开关/退出登录时丢弃当前段（设置页与登录态联动调用）。
  void discard() {
    tracker.discard();
    _segmentStartedAtSec = null;
    _segmentUserid = null;
  }

  /// 结账一个播放段：阈值/账号/开关/登录全过才真正上传。
  Future<void> _settleSegment(PlaybackSegment segment) async {
    final startedAtSec = _segmentStartedAtSec;
    final segmentUid = _segmentUserid;
    _segmentStartedAtSec = null;
    _segmentUserid = null;
    if (!segment.reachesThreshold(minUploadMs)) return;
    // 切号保护：段开始时所属账号与当前账号不一致 → 丢弃（宁少记不错记）
    final currentUid = KugouApiClient().userid;
    if (segmentUid != null && segmentUid != currentUid) return;
    if (!await _enabled()) return;
    if (!KugouApiClient().isLoggedIn) return;
    // pc 取本地计数（含本次播放——addHistory 在播放开始边沿 +1）；
    // 云端保持 max(服务器, pc)，取不到时不上传 pc 只追加一条记录。
    int? pc;
    try {
      pc = (await HistoryRepository().getPlayCounts())[segment.songId];
    } catch (_) {
      // 计数读取失败不阻断上传
    }
    await _upload(
      segment.mixsongid,
      otSec: startedAtSec ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
      pc: pc,
    );
    // 刚传成功说明网络可用，顺手把滞留的补上
    await flushPending();
  }

  Future<void> _upload(
    String mxid, {
    required int otSec,
    int? pc,
  }) async {
    // client._get 失败时通常**返回 null**（内部吞异常打日志）而非抛出，
    // 业务失败（error_code 非 0）也是正常返回 —— 两者都必须走入队重试。
    Map<String, dynamic>? resp;
    var threw = false;
    try {
      resp = await KugouApiClient().uploadPlayHistory(
        mxid,
        playCount: pc,
        ot: otSec,
      );
    } catch (e) {
      threw = true;
      // ignore: avoid_print
      print('[PlayHistorySync] 上传异常 mxid=$mxid ot=$otSec err=$e');
    }
    if (threw || resp == null || !KugouApiClient.isBizOk(resp)) {
      // ignore: avoid_print
      print(
        '[PlayHistorySync] 上传失败，入队重试 mxid=$mxid ot=$otSec '
        'resp=${resp == null ? 'null' : 'biz-failed'}',
      );
      await _enqueue(mxid, otSec: otSec, pc: pc);
      return;
    }
    // ignore: avoid_print
    print('[PlayHistorySync] 上传成功 mxid=$mxid ot=$otSec pc=$pc');
  }

  /// 开关是否开启（默认开启）；每次上报前重读，设置页切换即时生效。
  Future<bool> _enabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_uploadEnabledPrefsKey) ?? true;
  }

  // ---- pending 队列（按账号隔离的 JSON 列表）----

  Future<String> _pendingKey() async {
    final uid = KugouApiClient().userid ?? '';
    return '$_pendingPrefsKeyPrefix${uid.isEmpty ? '' : '_$uid'}';
  }

  Future<void> _enqueue(String mxid, {required int otSec, int? pc}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = await _pendingKey();
      final list = _readPending(prefs.getString(key));
      // 同一首歌同一次 ot 的重复入队去重（快速连续失败时防膨胀）
      list.removeWhere(
        (e) => e['mxid'] == mxid && e['ot'] == otSec,
      );
      list.add({'mxid': mxid, 'ot': otSec, ?'pc': pc});
      while (list.length > _maxPending) {
        list.removeAt(0);
      }
      await prefs.setString(key, jsonEncode(list));
    } catch (_) {
      // 持久化失败只影响本次重试，不向上抛
    }
  }

  /// 补传滞留队列（启动/成功后触发）。逐条尝试，失败即停（保留队列，
  /// 等下次触发）；开关关闭或未登录直接跳过。
  Future<void> flushPending() async {
    if (_flushing) return;
    _flushing = true;
    try {
      if (!await _enabled()) return;
      if (!KugouApiClient().isLoggedIn) return;
      final prefs = await SharedPreferences.getInstance();
      final key = await _pendingKey();
      final list = _readPending(prefs.getString(key));
      if (list.isEmpty) return;
      final remaining = <Map<String, dynamic>>[];
      for (final entry in list) {
        final mxid = entry['mxid']?.toString();
        if (mxid == null || mxid.isEmpty) continue;
        final ot = entry['ot'] is num
            ? (entry['ot'] as num).toInt()
            : int.tryParse('${entry['ot']}') ?? 0;
        final pc = entry['pc'] is num ? (entry['pc'] as num).toInt() : null;
        try {
          final resp = await KugouApiClient().uploadPlayHistory(
            mxid,
            playCount: pc,
            ot: ot > 0 ? ot : null,
          );
          if (resp == null || !KugouApiClient.isBizOk(resp)) {
            throw Exception('补传失败（resp=${resp == null ? 'null' : 'biz-failed'}）');
          }
          // ignore: avoid_print
          print('[PlayHistorySync] 补传成功 mxid=$mxid ot=$ot');
        } catch (_) {
          // 重试条目保留原始 ot（历史记录「什么时候播的」，不是重试时间）
          remaining.add(entry);
          break;
        }
      }
      await prefs.setString(key, jsonEncode(remaining));
    } catch (_) {
      // 队列维护失败不向上抛
    } finally {
      _flushing = false;
    }
  }

  List<Map<String, dynamic>> _readPending(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return [];
    }
  }
}
