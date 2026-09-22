import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../../services/kugou_api/kugou_api_client.dart';
import 'playback_duration_tracker.dart';

/// CSCC 真实播放事件上报（`/user/listen/report`）。
///
/// 与 [ListeningGradeService] 的分工：
/// - 本服务：**真实播放事件**（`start`/`end`），由 [PlayerProvider] 在播放状态
///   边沿驱动，携带扣除暂停/拖动后的实际播放毫秒数 → 对应官方「真实播放统计」记账。
/// - `ListeningGradeService`：仍负责 30s 心跳式 `d_sec`/`diff_sec` **差量上报**。
///
/// 设计要点（对照参考实现 `module/user_listen_report.js`）：
/// 1. **不重试**。上游超时也可能已记账，重试会造成重复上报，故只发一次；
/// 2. **start/end 配对**由 [PlaybackDurationTracker] 保证（切歌时先补发前一首 end）；
/// 3. 过短播放（默认 < 15s）**只发 start 不发 end**，避免噪声（无 end 即不入账）；
/// 4. 开关复用 `settings_upload_listening_duration`（与差量链路同一开关，
///    默认关闭，每次上报前重读 → 设置页切换即时生效）。
class ListenReportService {
  ListenReportService._();

  static final ListenReportService instance = ListenReportService._();

  /// 「上传听歌时长」开关的 prefs key（与 SettingsRepository 保持一致）。
  static const String _uploadEnabledPrefsKey = 'settings_upload_listening_duration';

  /// end 事件的最小上报时长（毫秒）。低于此值视为无效播放，不发 end。
  static const int minReportableMs = 15000;

  /// 时间源可注入，便于测试。
  PlaybackDurationTracker tracker = PlaybackDurationTracker();

  /// 设备参数（同一次播放的 start/end 必须一致）。
  String? _deviceModel;
  String? _systemVersion;

  /// 当前计时段**所属的账号**（`onSongStarted` 时记下）。
  ///
  /// 用途：上报前校验账号是否已变 —— `onSongEnded` 取的是**上报那一刻**的账号凭据，
  /// 若用户在收听中途切换了账号（`logout()` 在有其他账号时会自动切过去），
  /// 该段就会带着新账号的 token 上报，把时长记到错误的账号上。
  /// 在 `_sendEnd` 这个**唯一出口**上校验，可覆盖所有切号路径，无需在每个入口打补丁。
  String? _segmentUserid;

  /// 设备参数的异步供给方（由 [PlayerProvider] 注入，内部缓存一次性结果）。
  /// start/end 会先 await 它，避免同一个播放段的前后两次请求参数不一致 ——
  /// Rust 侧的会话缓存 key 含机型，参数漂移会导致重复建会话。
  Future<void> Function()? _deviceInfoLoader;

  bool _started = false;

  void init() {
    if (_started) return;
    _started = true;
  }

  /// 由启动流程注入设备参数（机型/系统版本）。
  /// 缺省时 Rust 侧按项目 dev 配置与 `system_version=9` 兜底。
  void setDeviceInfo({String? deviceModel, String? systemVersion}) {
    _deviceModel = deviceModel;
    _systemVersion = systemVersion;
  }

  /// 注入设备参数懒加载器，供 [onSongStarted]/[onSongEnded] 在取参前 await。
  void setDeviceInfoLoader(Future<void> Function() loader) {
    _deviceInfoLoader = loader;
  }

  /// 补齐设备参数（一次性；失败静默，交给 Rust 兜底）。
  Future<void> _awaitDeviceInfo() async {
    final loader = _deviceInfoLoader;
    if (loader == null) return;
    try {
      await loader();
    } catch (_) {
      // 设备信息取不到不影响上报：Rust 侧有 dev 配置与默认系统版本兜底
    }
  }

  /// 歌曲开始播放（切歌时由 PlayerProvider 调用）。
  ///
  /// [songId] 数据层歌曲 id；[mixsongid] CSCC 必填的 mixsongid。
  /// [playing] 此刻是否真的在出声。切歌瞬间播放器常处于「已换曲但还在缓冲」
  ///   状态（playingStream 尚未翻 true），必须如实透传给 tracker，
  ///   否则会把缓冲等待计入 `duration`（真机首测 `duration` 偏大的根因）。
  Future<void> onSongStarted({
    required String songId,
    required String mixsongid,
    bool playing = true,
  }) async {
    if (!await _enabled()) return;
    if (!KugouApiClient().isLoggedIn) return;
    await _awaitDeviceInfo();
    // 顺序：先结账并上报上一段 `end`，再开启新段并上报 `start`。
    // 不可先 start：本类两次上报之间隔着 await（网络往返），若先重置累计值，
    // 期间到达的 `onSongEnded` 会拿到错误的段。
    final superseded = tracker.snapshot(reason: PlaybackEndReason.switched);
    if (superseded != null) {
      await _sendEnd(superseded);
    }
    tracker.start(songId: songId, mixsongid: mixsongid, playing: playing);
    // 记下本段所属账号，供 _sendEnd 在上报前校验（防切号把时长记到新账号）
    _segmentUserid = KugouApiClient().userid;
    await _sendStart(mixsongid);
  }

  /// 播放/暂停状态变化（转发给计时器）。
  void onPlayingChanged(bool playing) {
    tracker.setPlaying(playing);
  }

  /// 用户拖动进度条。
  void onSeek() {
    tracker.onSeek();
  }

  /// 歌曲结束/被停止：上报 `end`。
  Future<void> onSongEnded({
    PlaybackEndReason reason = PlaybackEndReason.completed,
  }) async {
    final segment = tracker.end(reason: reason);
    if (segment == null) return;
    if (!await _enabled()) return;
    if (!KugouApiClient().isLoggedIn) return;
    await _awaitDeviceInfo();
    await _sendEnd(segment);
  }

  /// 关闭开关/退出登录时丢弃当前段，不上报。
  void discard() {
    tracker.discard();
    _segmentUserid = null;
  }

  Future<void> _sendStart(String mixsongid) async {
    try {
      final resp = await KugouApiClient().reportListenEvent(
        event: 'start',
        mixsongid: mixsongid,
        deviceModel: _deviceModel,
        systemVersion: _systemVersion,
      );
      // ignore: avoid_print
      print('[CSCC] start 上报 mixsongid=$mixsongid resp=$resp');
    } catch (e) {
      // 事件不重试：失败即放弃，等下一次 start 重新建会话
      // ignore: avoid_print
      print('[CSCC] start 上报失败 mixsongid=$mixsongid err=$e');
    }
  }

  Future<void> _sendEnd(PlaybackSegment segment) async {
    // 账号校验（唯一出口，覆盖所有上报路径：onSongEnded 与 onSongStarted 的顶替结算）：
    // 本段开始时所属账号若与当前账号不一致，说明收听途中切了号，
    // 直接丢弃 —— 否则会带着新账号的 token 上报，把时长记到错误的账号上。
    final segmentUid = _segmentUserid;
    final currentUid = KugouApiClient().userid;
    if (segmentUid != null && segmentUid != currentUid) {
      // ignore: avoid_print
      print(
        '[CSCC] 丢弃 end（账号已切换）$segment '
        '段账号=$segmentUid 当前账号=$currentUid',
      );
      return;
    }
    if (!segment.reachesThreshold(minReportableMs)) {
      // ignore: avoid_print
      print('[CSCC] 跳过 end（时长不足）${segment.durationMs}ms < $minReportableMs');
      return;
    }
    try {
      final resp = await KugouApiClient().reportListenEvent(
        event: 'end',
        mixsongid: segment.mixsongid,
        duration: segment.durationMs,
        state: segment.reason.state,
        deviceModel: _deviceModel,
        systemVersion: _systemVersion,
      );
      // ignore: avoid_print
      print('[CSCC] end 上报 $segment resp=$resp');
    } catch (e) {
      // ignore: avoid_print
      print('[CSCC] end 上报失败 $segment err=$e');
    }
  }

  /// 开关是否开启（默认关闭）；每次上报前重读，设置页切换即时生效。
  Future<bool> _enabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_uploadEnabledPrefsKey) ?? false;
  }
}
