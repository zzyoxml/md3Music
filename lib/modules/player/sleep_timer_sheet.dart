import 'dart:async';

import 'package:dpad/dpad.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';

import '../../core/build_flags.dart';
import '../../core/utils/app_text_context_menu.dart';
import '../../core/utils/app_toast.dart';
import '../../data/repositories/settings_repository.dart';
import '../../providers/player_provider.dart';
import '../../widgets/player_top_bar_actions.dart';
import 'sleep_timer_dial.dart';
import 'sleep_timer_polygon.dart';

/// 顶栏尾部胶囊的配色。
///
/// 标准版跟随主题容器色；AM 版是深色蒙版上的半透明白底。睡眠定时与一起听同处
/// 顶栏尾部，合并成一颗胶囊后共用这一组色（见 [TopBarTrailingCapsule]）。
class SleepTimerPillStyle {
  const SleepTimerPillStyle({
    required this.backgroundColor,
    required this.foregroundColor,
  });

  final Color backgroundColor;
  final Color foregroundColor;

  /// 标准（MD3E）：primaryContainer / onPrimaryContainer。
  static SleepTimerPillStyle standardOf(BuildContext context) =>
      SleepTimerPillStyle(
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
      );

  /// AM：白色 15% 底 + 纯白前景。
  ///
  /// **已知对比度欠账（本轮按决定不动配色）**：压在浅色封面或自定义壁纸上约 2.3:1，
  /// 不足图标 3:1 / 文字 4.5:1。保留是因为 AM 顶栏本来就是深色蒙版上的玻璃质感；
  /// 真要修应在文字下再压一层暗底托，单纯提 alpha 会把透底感一起丢掉。
  static SleepTimerPillStyle amOf() => SleepTimerPillStyle(
    backgroundColor: Colors.white.withValues(alpha: 0.15),
    foregroundColor: Colors.white,
  );
}

/// 睡眠定时剩余时间格式化：>=1h 显示 `XhYYm`，否则 `mm:ss`。
String formatSleepTimerRemaining(Duration d) {
  if (d.inHours >= 1) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    return '${h}h${m.toString().padLeft(2, '0')}m';
  }
  final m = d.inMinutes;
  final s = d.inSeconds.remainder(60);
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

/// 「开始计时」的 toast 文案：按小时/分钟组合成人话。
String _sleepTimerStartMessage(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  if (h == 0) return '将在 $m 分钟后自动暂停';
  if (m == 0) return '将在 $h 小时后自动暂停';
  return '将在 $h 小时 $m 分钟后自动暂停';
}

/// 顶栏尾部的「定时关闭」项。
///
/// 顶栏尾部统一由 [TopBarTrailingCapsule] 渲染（竖屏与一起听、⋯ 合成一颗胶囊，
/// 点开展开后自动收回）；本函数只把定时状态翻成那一项的数据：
///
/// - [SleepTimerMode.off] → null（未启用时**整项不占位**，不留凭空多出的间距把
///   更多菜单推歪）；
/// - [SleepTimerMode.endOfTrack]（到点等待态，无倒计时）→ 静态文案「播完本曲」；
/// - [SleepTimerMode.countdown] → 逐秒剩余时间；notifier 尚未落地时为 null，
///   同样收起（下一帧即显示真实倒计时）。
///
/// 调用方必须把它放进 `ListenableBuilder(listenable: playerProvider)` 内层再套
/// `ValueListenableBuilder(sleepTimerRemainingNotifier)`：顶栏本身不整体重建，
/// 只有这里订阅模式与剩余时间的变化。
TopBarTrailingSegment? sleepTimerTopBarSegment({
  required Duration? remaining,
  required SleepTimerMode mode,
  required VoidCallback onTap,
}) {
  final label = switch (mode) {
    SleepTimerMode.off => null,
    SleepTimerMode.endOfTrack => '播完本曲',
    SleepTimerMode.countdown => remaining == null
        ? null
        : formatSleepTimerRemaining(remaining),
  };
  if (label == null) return null;
  return TopBarTrailingSegment(
    icon: Icons.timer_outlined,
    label: label,
    semanticsLabel: '定时关闭',
    onTap: onTap,
  );
}

/// 弹出「定时关闭」面板：圆形时钟盘（拖动套圈，上限 24 小时）+
/// 分钟手动输入 + 「定时结束后播完当前歌曲」+「结束后减少待机耗电」+
/// 「关闭定时」。
///
/// 与旧版的差别：旧的 1–90 分钟 `M3ESlider` 已移除，改为调完点**中央形状**
/// 才真正提交（拖动过程不再即时改写定时）。
void showSleepTimerSheet({
  required BuildContext context,
  required PlayerProvider player,
}) {
  final rootContext = context;
  // 冷启动回读：该偏好持久化在 SettingsRepository，而 Provider 内存字段随
  // 进程生成默认 false。弹层是唯一改动入口且切换时同步内存字段，但进程重启
  // 后内存字段可能落后于持久化值，打开弹层时异步回读一次对齐；回读落地前
  // 用户已抢先切换的，以内存值为准，不用持久化旧值覆盖（比较回读前的快照）。
  final killBackgroundAtOpen = player.killBackgroundOnTimerEnd;
  unawaited(
    SettingsRepository().getSleepTimerKillBackground().then((persisted) {
      if (persisted != killBackgroundAtOpen &&
          player.killBackgroundOnTimerEnd == killBackgroundAtOpen) {
        player.setKillBackgroundOnTimerEnd(persisted);
      }
    }),
  );
  // 初始值：已有定时时显示剩余分钟数（clamp 到合法区间），否则默认 30
  final initialMinutes = (player.sleepTimerRemaining?.inMinutes ?? 30).clamp(
    kSleepTimerMinMinutes,
    kSleepTimerMaxMinutes,
  );
  showM3EModalBottomSheet(
    context: rootContext,
    isScrollControlled: true,
    showDragHandle: true,
    // 与播放页其它弹层一致：实色背景（全局 M3E 主题默认 0.97 alpha 会透出底图）。
    // 本函数只在播放页顶栏药丸与「更多」菜单里调用，改动不会波及其它页面。
    backgroundColor: Theme.of(rootContext).colorScheme.surfaceContainerLow,
    builder: (sheetCtx) {
      // 拖动中的临时值必须声明在 StatefulBuilder 之外：
      // builder 重跑会重建局部变量，声明在内部会导致拖动值被重置
      int minutes = initialMinutes;
      return SafeArea(
        child: ListenableBuilder(
          listenable: player,
          builder: (context, _) {
            final stopAfterCurrentTrack = player.stopAfterTimerEnds;
            final killBackground = player.killBackgroundOnTimerEnd;
            return StatefulBuilder(
              builder: (context, setSheetState) {
                void setMinutes(int next) => setSheetState(
                  () => minutes = next.clamp(
                    kSleepTimerMinMinutes,
                    kSleepTimerMaxMinutes,
                  ),
                );
                final textTheme = Theme.of(rootContext).textTheme;
                final onSurfaceVariant =
                    Theme.of(rootContext).colorScheme.onSurfaceVariant;
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  // 表盘最高 300dp，加上输入行与三个 tile 在横屏/小屏会超出
                  // 屏高。`isScrollControlled: true` 的弹层不限高，必须显式给
                  // 上界，否则 SingleChildScrollView 拿不到有界高度、直接溢出
                  // 而不是滚动。
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.sizeOf(rootContext).height * 0.9,
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '定时关闭',
                          textAlign: TextAlign.center,
                          style: textTheme.titleMedium,
                        ),
                        const SizedBox(height: 12),
                        Center(
                          // tv: TV 构建下圆形表盘不可拖拽，改经 DpadFocusable
                          // 提供按键等价：左右 ±5 分钟、上下 ±1 小时（消费按键，
                          // 防方向键把焦点移出表盘）、OK = 点击中央开始计时。
                          // 表盘本体不拆改，触屏拖动路径原样保留。
                          child: kTvBuild
                              ? DpadFocusable(
                                  autofocus: kTvBuild,
                                  onSelect: () {
                                    final d = Duration(minutes: minutes);
                                    player.setSleepTimer(d);
                                    showToast(
                                        _sleepTimerStartMessage(d), long: true);
                                    Navigator.pop(sheetCtx);
                                  },
                                  onDirection: (direction) {
                                    switch (direction) {
                                      case TraversalDirection.right:
                                        setMinutes(minutes + 5);
                                      case TraversalDirection.left:
                                        setMinutes(minutes - 5);
                                      case TraversalDirection.up:
                                        setMinutes(minutes + 60);
                                      case TraversalDirection.down:
                                        setMinutes(minutes - 60);
                                    }
                                    return true;
                                  },
                                  child: SleepTimerDial(
                                    minutes: minutes,
                                    onChanged: setMinutes,
                                    onStart: () {
                                      final d = Duration(minutes: minutes);
                                      player.setSleepTimer(d);
                                      showToast(
                                          _sleepTimerStartMessage(d), long: true);
                                      Navigator.pop(sheetCtx);
                                    },
                                  ),
                                )
                              : SleepTimerDial(
                                  minutes: minutes,
                                  onChanged: setMinutes,
                                  onStart: () {
                                    final d = Duration(minutes: minutes);
                                    player.setSleepTimer(d);
                                    showToast(_sleepTimerStartMessage(d), long: true);
                                    Navigator.pop(sheetCtx);
                                  },
                                ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '已套 ${minutes ~/ 60} 圈 · 上限 $kSleepTimerMaxHours 小时 · '
                          '点击中间开始计时',
                          textAlign: TextAlign.center,
                          style: textTheme.labelMedium?.copyWith(
                            color: onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 12),
                        _ManualMinuteField(minutes: minutes, onChanged: setMinutes),
                        const SizedBox(height: 4),
                        // 「定时结束后播完当前歌曲」开关：开启后定时到点不打断
                        // 播放，等当前正在播的这首自然播完再暂停；偏好到点后保留。
                        SwitchListTile(
                          secondary: const Icon(Icons.music_note_outlined),
                          title: const Text('定时结束后播完当前歌曲'),
                          value: stopAfterCurrentTrack,
                          onChanged: (next) {
                            player.setStopAfterCurrentTrack(next);
                            showToast(
                              next
                                  ? '定时结束后将播完当前歌曲再暂停'
                                  : '已取消「定时结束后播完当前歌曲」',
                              long: true,
                            );
                          },
                        ),
                        // 「结束后减少待机耗电」开关：开启后定时到点（含
                        // 「播完当前歌曲」收尾）在停播落盘后继续停本地服务并
                        // 结束任务，不驻留后台；切换即持久化并同步 Provider。
                        SwitchListTile(
                          secondary: const Icon(Icons.battery_saver_outlined),
                          title: const Text('结束后减少待机耗电'),
                          subtitle: const Text('倒计时结束后停止后台服务并退出应用'),
                          value: killBackground,
                          onChanged: (next) {
                            player.setKillBackgroundOnTimerEnd(next);
                            SettingsRepository().setSleepTimerKillBackground(
                              next,
                            );
                            showToast(
                              next
                                  ? '定时结束后将停止后台服务并退出应用'
                                  : '已取消「结束后减少待机耗电」',
                              long: true,
                            );
                          },
                        ),
                        ListTile(
                          leading: const Icon(Icons.cancel_outlined),
                          title: const Text('关闭定时'),
                          onTap: () {
                            player.setSleepTimer(null);
                            Navigator.pop(sheetCtx);
                          },
                        ),
                      ],
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      );
    },
  );
}

/// 分钟手动输入（1–1440），输入实时生效（无「应用」按钮）。
///
/// 独立成 StatefulWidget 是为了自己持有并 dispose [TextEditingController]：
/// 控制器不能声明在 `StatefulBuilder` 的 builder 里（每次重建都会丢内容），
/// 声明在外面则没人 dispose。
class _ManualMinuteField extends StatefulWidget {
  const _ManualMinuteField({required this.minutes, required this.onChanged});

  final int minutes;
  final ValueChanged<int> onChanged;

  @override
  State<_ManualMinuteField> createState() => _ManualMinuteFieldState();
}

class _ManualMinuteFieldState extends State<_ManualMinuteField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: '${widget.minutes}');
    _focusNode = FocusNode();
    // 失焦时回填当前合法值：清空/非法的中间态不写回状态，离开时收口
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) _controller.text = '${widget.minutes}';
    });
  }

  @override
  void didUpdateWidget(_ManualMinuteField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 表盘改动回写输入框；但用户正在敲字时不抢内容
    if (oldWidget.minutes != widget.minutes && !_focusNode.hasFocus) {
      _controller.text = '${widget.minutes}';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// 实时应用：每个 keystroke 都解析并上报；空/非数字是输入中间态，跳过不写。
  void _apply() {
    final parsed = int.tryParse(_controller.text);
    if (parsed == null) return;
    widget.onChanged(parsed);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      contextMenuBuilder: buildAppTextContextMenu,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: const InputDecoration(
        labelText: '手动输入',
        suffixText: '分钟',
        isDense: true,
      ),
      onChanged: (_) => _apply(),
      onSubmitted: (_) => _focusNode.unfocus(),
    );
  }
}
