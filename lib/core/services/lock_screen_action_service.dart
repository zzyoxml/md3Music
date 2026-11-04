import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../main.dart' show appNavigatorKey;
import '../../modules/player/dlna_cast_sheet.dart';
import '../../modules/player/full_player_route.dart';
import 'media_notification_service.dart';

/// 锁屏歌词卡片「投屏 / 队列」按钮的落地服务。
///
/// 锁屏卡片是原生 Activity 画的，点投屏/队列时原生只做两件事：把动作存进
/// pending 并拉起 App。真正的面板（`DlnaCastSheet` / 播放页「播放列表」tab）
/// 是 Flutter 页面，由这里在 Navigator 就绪后打开。
///
/// 两个入口：
/// - 热启动：原生 `widgetAction` 通道 → [MediaNotificationService.onWidgetAction]；
/// - 冷启动：引擎就绪前原生只能暂存动作，[attach] 时主动拉一次 pending 补投
///   （与 `ExternalMediaIntentService` 同一套兜底模式）。
class LockScreenActionService {
  LockScreenActionService._();

  static final LockScreenActionService instance = LockScreenActionService._();

  /// 是否已装配回调。重复 attach 会重复注册回调并重复拉取 pending，故只做一次。
  bool _attached = false;

  /// App 首帧后调用（此时 provider 与 Navigator 均已就绪）。
  ///
  /// 幂等：内部按 [_attached] 直接返回。
  Future<void> attach() async {
    if (_attached) return;
    _attached = true;
    MediaNotificationService.onWidgetAction = _handle;
    // 冷启动兜底：引擎未就绪时原生只能暂存动作，这里取走并补投一次。
    // 通道未注册（非 Android / 原生尚未实现）时 takePendingWidgetAction
    // 自身吞异常返回 null，这里不会抛。
    final pending = await MediaNotificationService.takePendingWidgetAction();
    if (pending == null || pending.isEmpty) return;
    _handle(pending);
  }

  /// 动作落地。未知动作静默丢弃（原生后续新增动作时 Dart 旧版本不应崩）。
  void _handle(String action) {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) return;
    switch (action) {
      case 'openCast':
        // ignore: discarded_futures
        showM3EModalBottomSheet(
          context: ctx,
          isScrollControlled: true,
          backgroundColor: Theme.of(ctx).colorScheme.surfaceContainerLow,
          builder: (_) => const DlnaCastSheet(),
        );
        break;
      case 'openQueue':
        // 播放列表恒为 tab 0（见 player_tab_layout.dart 的 tabKinds 顺序：
        // [播放列表][封面?][控制?][歌词][评论?]）。
        playerTabIndex.value = 0;
        openFullPlayer(ctx);
        break;
    }
  }
}
