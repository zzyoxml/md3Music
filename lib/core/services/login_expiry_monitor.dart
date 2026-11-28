import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../data/models/kugou_account.dart';
import '../../main.dart' show appNavigatorKey;
import '../../providers/kugou_provider.dart';
import '../../modules/user/kugou_account_expired_dialog.dart';

/// 后台登录态过期检查：每 10 分钟检查一次当前账号是否「确定已过期」，
/// 过期时复用账号切换的过期弹窗，且同一账号只弹一次。
///
/// 设计要点：
/// - 首帧 attach 后才开始计时，首次检查在 10 分钟后，刚打开 app 不检查；
/// - 定时器不随前后台切换而停止（音乐 App 常在后台播放），但弹窗只在前台显示；
///   后台期间发现过期先标记账号，回前台后再补弹一次；
/// - 无网络/未知业务结果不弹窗（由 [KugouProvider.checkCurrentTokenExpired] 保证）；
/// - 当天登录过的账号，即使随后检测到失效，当天全天也不弹窗（避免刚登录后打扰）；
/// - 不缓存 BuildContext，弹窗时实时取根 Navigator 的 context。
class LoginExpiryMonitor with WidgetsBindingObserver {
  LoginExpiryMonitor._();

  static final LoginExpiryMonitor instance = LoginExpiryMonitor._();

  static const Duration checkInterval = Duration(minutes: 10);

  Timer? _timer;
  bool _attached = false;
  bool _appForeground = true;
  bool _checking = false;

  /// 后台检查发现问题但当时不在前台，记下 userid，回前台后补弹一次。
  String? _pendingDialogUserid;

  /// 在应用首帧后调用，启动定时检查。重复调用幂等。
  void attach() {
    if (_attached) return;
    _attached = true;
    final state = WidgetsBinding.instance.lifecycleState;
    _appForeground = state == null || _isForegroundState(state);
    WidgetsBinding.instance.addObserver(this);
    // 从挂载时刻起算，首次检查在完整一个周期之后（启动瞬间不检查）。
    _timer?.cancel();
    _timer = Timer.periodic(checkInterval, (_) => unawaited(_check()));
  }

  /// 应用销毁时调用，停止定时器并注销观察者。
  void detach() {
    if (!_attached) return;
    _attached = false;
    _timer?.cancel();
    _timer = null;
    WidgetsBinding.instance.removeObserver(this);
    _pendingDialogUserid = null;
  }

  /// 当前账号当天（本地自然日）登录过就不弹过期弹窗。
  /// 场景：用户刚登录，随后 15 分钟检测到失效——当天都不应打扰用户。
  static bool _loggedInToday(KugouAccount account) {
    final loginTime = account.loginTime;
    if (loginTime <= 0) return false;
    final loginDate = DateTime.fromMillisecondsSinceEpoch(loginTime * 1000);
    final now = DateTime.now();
    return loginDate.year == now.year &&
        loginDate.month == now.month &&
        loginDate.day == now.day;
  }

  static bool _isForegroundState(AppLifecycleState state) =>
      state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = _isForegroundState(state);
    if (foreground == _appForeground) return;
    _appForeground = foreground;
    if (foreground) unawaited(_flushPendingDialog());
  }

  Future<void> _check() async {
    if (!_attached || _checking) return;
    _checking = true;
    try {
      final ctx = appNavigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      final kugou = ctx.read<KugouProvider>();

      final uid = kugou.userid;
      if (uid == null || uid.isEmpty) return;
      final account = kugou.currentAccount;
      if (account == null || account.userid != uid) return;
      // 已标记为过期的账号：此前已提示过（或用户正在处理），不再重复检查/弹窗。
      if (account.expired) return;
      // 当天登录过：即使随后检测到失效，当天全天也不弹过期弹窗。
      if (_loggedInToday(account)) {
        debugPrint('ℹ️ [Account] 当前账号当天登录过，跳过过期检查与弹窗');
        return;
      }

      final expired = await kugou.checkCurrentTokenExpired();
      if (!expired || !_attached) return;

      // 后台期间不弹窗，记下来回前台补弹；前台则立即复用原弹窗。
      if (_appForeground) {
        await _showDialogIfCurrent(uid);
      } else {
        _pendingDialogUserid = uid;
      }
    } finally {
      _checking = false;
    }
  }

  Future<void> _flushPendingDialog() async {
    final uid = _pendingDialogUserid;
    if (uid == null || !_attached || !_appForeground) return;
    _pendingDialogUserid = null;
    await _showDialogIfCurrent(uid);
  }

  Future<void> _showDialogIfCurrent(String uid) async {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    final kugou = ctx.read<KugouProvider>();
    if (kugou.userid != uid) return; // 期间已切换账号，不弹旧账号的提示
    final account = kugou.currentAccount;
    if (account == null || account.userid != uid || !account.expired) return;
    await showExpiredAccountDialog(ctx, account, kugou);
  }
}
