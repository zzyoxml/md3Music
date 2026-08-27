import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/kugou_api/kugou_api_client.dart';

/// 听歌等级：本地听歌时长累计 + 自动上报（/user/grade/info，v2/lite 协议）。
///
/// - [PlayerProvider] 通过 [setListeningOnline] 推送「正在播放在线歌曲」状态
/// - 每 30s 心跳：在线播放则累计秒数；累计达 60s 上报一次
///   （d_sec=本地累计总秒数，diff_sec=本次增量，服务器按 diff_sec 记账）
/// - 按 userid 隔离持久化，切换账号自动重载；未登录不累计
/// - 上报失败重试，连续 3 次失败则调查询重同步服务器值并丢弃 pending，防死循环
class ListeningGradeService {
  ListeningGradeService._();

  static final ListeningGradeService instance = ListeningGradeService._();

  static const Duration _interval = Duration(seconds: 30);

  /// 累计达该秒数后触发一次上报
  static const int _reportThresholdSeconds = 60;

  /// 连续上报失败上限：超过后重同步并丢弃 pending
  static const int _maxFailedReports = 3;

  Timer? _timer;
  bool _started = false;

  /// 当前是否正在播放在线歌曲（由 PlayerProvider 推送）
  bool _onlinePlaying = false;

  /// 已同步到服务器的累计听歌秒数（本地基准）
  int _syncedDsec = 0;

  /// 最近一次服务器返回的累计听歌秒数（用于计算未上报时长）
  int _serverDsec = 0;

  /// 尚未上报的增量秒数（diff_sec）
  int _pendingDiff = 0;

  int _failedReports = 0;

  /// 当前服务针对的 userid（用于账号切换重载）
  String? _userid;

  /// 启动 30s 心跳（仅 Android 主 isolate 生效）。
  ///
  /// 关键：audio_service 的后台 headless isolate 也会执行 main() 并调用 init()。
  /// 若不区分，会在后台再创建一个 Timer，两个实例并发累计/上报并互相覆盖
  /// SharedPreferences 里的 synced 基准，导致上报 d_sec 与服务器不一致被拒。
  /// 主 isolate 才有 UI view（`PlatformDispatcher.instance.views` 非空），据此区分。
  void init() {
    if (_started) return;
    _started = true;
    if (kIsWeb || !Platform.isAndroid) return;
    _ensureTimerScheduled();
  }

  /// 确保在主 isolate 启动心跳定时器（view 就绪后再真正创建 Timer）。
  ///
  /// 修复：`init()` 在 `runApp` 之前调用，冷启动时 UI view 可能还没挂载，
  /// 此时 `PlatformDispatcher.instance.views` 为空。若在 `init()` 里直接
  /// `return`，`_started` 已置 true，主 isolate 的定时器就永远无法启动，
  /// 表现为"听歌时长经常不累计/不上报"。故 view 未就绪时推迟到下一帧再
  /// 重试；后台 headless isolate 没有 view 也不渲染帧，addPostFrameCallback
  /// 不会回调，因此天然不会创建第二个定时器（与原有并发保护意图一致）。
  void _ensureTimerScheduled() {
    if (_timer != null) return;
    if (PlatformDispatcher.instance.views.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureTimerScheduled());
      return;
    }
    _timer = Timer.periodic(_interval, (_) => _onTick());
  }

  /// PlayerProvider 推送：当前是否正在播放在线歌曲。
  void setListeningOnline(bool value) {
    _onlinePlaying = value;
  }

  /// 未上报（服务器未记账）的听歌时长（秒）：
  /// 本地累计基准 - 服务器累计值。仅当已知服务器值且本地高于服务器时非 0。
  int get unreportedSeconds {
    if (_serverDsec <= 0) return 0;
    final d = _syncedDsec - _serverDsec;
    return d > 0 ? d : 0;
  }

  /// 查询到服务器 d_sec 后调用：记录服务器值，本地基准只升不降，避免上报被拒。
  Future<void> resyncFromServer(int serverDsec) async {
    _serverDsec = serverDsec;
    if (serverDsec > _syncedDsec) {
      _syncedDsec = serverDsec;
      await _save();
    }
  }

  Future<void> _onTick() async {
    try {
      await _onTickInner();
    } catch (e, s) {
      // Timer 回调内任何异常都不能外泄（否则未处理异常可能导致 App 崩溃）
      // ignore: avoid_print
      print('[GradeTick] 异常: $e\n$s');
    }
  }

  Future<void> _onTickInner() async {
    final userid = KugouApiClient().userid;
    if (userid == null || userid.isEmpty) return; // 未登录不累计
    if (_userid != userid) {
      // 账号切换（或首次登录）→ 重载该账号的持久化数据
      _userid = userid;
      await _load(userid);
    }
    var dirty = false;
    if (_onlinePlaying) {
      _pendingDiff += _interval.inSeconds;
      dirty = true;
    }
    // 调试日志：确认累计是否发生（听歌时长不生效排查用）
    if (dirty || _pendingDiff > 0 || _syncedDsec > 0) {
      // ignore: avoid_print
      print(
        '[GradeTick] online=$_onlinePlaying pending=$_pendingDiff synced=$_syncedDsec userid=$userid',
      );
    }
    if (_pendingDiff >= _reportThresholdSeconds) {
      await _report();
    } else if (dirty) {
      // 未达上报阈值但有累计 → 持久化增量，防止进程被杀丢失
      await _save();
    }
  }

  /// 上报本地累计时长；成功则推进基准，失败计数并重试。
  Future<void> _report() async {
    if (_pendingDiff <= 0) return;
    // 本地基准从未同步过（如用户未打开过「我的」页）时，先查询服务器当前值，
    // 否则 d_sec 远小于服务器值会被拒（v2 要求 d_sec >= 服务器当前值）。
    if (_syncedDsec == 0) {
      await _syncBaselineFromServer();
    }
    final dSec = _syncedDsec + _pendingDiff;
    final diff = _pendingDiff;
    final resp = await KugouApiClient().getGradeInfo(
      dSec: dSec,
      diffSec: diff,
    );
    // 兼容 status 为数字或字符串（上游偶发返回字符串）
    final status = resp?['status'];
    final rawError = resp?['error_code'];
    // error_code 兼容数字/字符串，缺失视为 0
    final errorCode = rawError is num
        ? rawError.toInt()
        : rawError is String
            ? (int.tryParse(rawError) ?? -1)
            : 0;
    // 判定"是否真的被服务器记账"：status==1 且 error_code==0。
    // 只认 status 时，若上游返回 status=1 但 error_code!=0（本次上报未被记账），
    // 会误判成功并清零 pending，导致服务器时长/等级一直不长——这正是听歌时长
    // 上报排查的关键（[GradeReport] 日志据此区分"记账成功"与"未记账"）。
    final ok = (status == 1 || status == '1') && errorCode == 0;
    if (ok) {
      _syncedDsec = dSec;
      _pendingDiff = 0;
      _failedReports = 0;
      _serverDsec = _parseServerDsec(resp); // 记录服务器返回的 d_sec（未上报时长用）
      await _save();
      // 打印服务器完整返回（含 error_code 与 data.d_sec），用于确认服务器是否真的记账
      // ignore: avoid_print
      print(
        '[GradeReport] 上报记账成功 d_sec=$dSec diff=$diff error_code=$errorCode synced=$_syncedDsec resp=$resp',
      );
    } else {
      _failedReports++;
      // ignore: avoid_print
      print(
        '[GradeReport] 上报未记账 d_sec=$dSec diff=$diff status=$status error_code=$errorCode synced=$_syncedDsec serverDsec=$_serverDsec resp=$resp failed=$_failedReports',
      );
      if (_failedReports >= _maxFailedReports) {
        // 连续失败（多为服务器值已领先本地）→ 查询重同步并丢弃 pending，防死循环
        await _resyncAndDrop();
      }
    }
  }

  /// 查询服务器当前累计时长，把本地基准抬升到服务器值（只升不降）。
  Future<void> _syncBaselineFromServer() async {
    final resp = await KugouApiClient().getGradeInfo();
    final serverDsec = _parseServerDsec(resp);
    // 打印查询结果（含 status/error_code / data.d_sec），排查查询是否被拒或异常
    // ignore: avoid_print
    print(
      '[GradeQuery] resp_status=${resp?['status']} error_code=${resp?['error_code']} serverDsec=$serverDsec',
    );
    if (serverDsec > 0) _serverDsec = serverDsec;
    if (serverDsec > _syncedDsec) {
      _syncedDsec = serverDsec;
      await _save();
      // ignore: avoid_print
      print('[GradeReport] 重同步基准 synced=$_syncedDsec');
    }
  }

  /// 查询服务器当前值，抬升本地基准并丢弃 pending。
  Future<void> _resyncAndDrop() async {
    _failedReports = 0;
    final resp = await KugouApiClient().getGradeInfo();
    final serverDsec = _parseServerDsec(resp);
    if (serverDsec > 0) _serverDsec = serverDsec;
    if (serverDsec > _syncedDsec) {
      _syncedDsec = serverDsec;
    }
    // ignore: avoid_print
    print(
      '[GradeReport] 连续失败重同步：丢弃 pending=$_pendingDiff，抬升 synced=$_syncedDsec（serverDsec=$serverDsec resp=${resp?['status']}/${resp?['error_code']}）',
    );
    _pendingDiff = 0;
    await _save();
  }

  /// 从 grade 响应中安全提取服务器 d_sec（不存在/类型不符返回 0）。
  int _parseServerDsec(Map<String, dynamic>? resp) {
    final data = resp?['data'];
    final v = data is Map ? data['d_sec'] : null;
    return v is num ? v.toInt() : 0;
  }

  Future<void> _load(String userid) async {
    final prefs = await SharedPreferences.getInstance();
    _syncedDsec = prefs.getInt(_key('synced', userid)) ?? 0;
    _serverDsec = prefs.getInt(_key('server', userid)) ?? 0;
    _pendingDiff = prefs.getInt(_key('pending', userid)) ?? 0;
  }

  Future<void> _save() async {
    final userid = _userid;
    if (userid == null || userid.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key('synced', userid), _syncedDsec);
    await prefs.setInt(_key('server', userid), _serverDsec);
    await prefs.setInt(_key('pending', userid), _pendingDiff);
  }

  String _key(String kind, String userid) => 'grade_${kind}_$userid';

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _started = false;
  }
}
