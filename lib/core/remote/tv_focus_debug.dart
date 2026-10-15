import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../build_flags.dart';

/// tv: 焦点诊断日志（**仅 TV debug 构建**生效）。
///
/// 遥控焦点问题的现场很难靠读代码定位——`primaryFocus` 的变化、时序（转场期间
/// 焦点仍有效、动画结束后才变 null）都只能实测。本类在每次 `primaryFocus`
/// 变化时打一行日志，供 `adb logcat` 取证（判定以日志为准，AGENTS.md §0.1）。
///
/// 只在 `kTvBuild && kDebugMode` 时安装：release 包里 `kDebugMode` 为 const
/// false，整段随树摇剔除，用户侧零影响。
class TvFocusDebug {
  TvFocusDebug._();

  static FocusNode? _last;

  /// 安装监听（幂等：重复调用直接返回）。
  static void install() {
    if (!kTvBuild || !kDebugMode) return;
    FocusManager.instance.addListener(_onFocusChanged);
    _onFocusChanged();
  }

  static void _onFocusChanged() {
    final focus = FocusManager.instance.primaryFocus;
    if (identical(focus, _last)) return;
    _last = focus;
    // ignore: avoid_print
    print(
      '[TvFocus] ${_describe(focus)}',
    );
  }

  static String _describe(FocusNode? node) =>
      'primaryFocus=${describe(node)}';

  /// 把焦点节点描述成一行可读文本（供其它调试点复用）。
  static String describe(FocusNode? node) {
    if (node == null) return 'null（无任何节点持有焦点）';
    final kind = node is FocusScopeNode ? 'Scope' : 'Node';
    final label = node.debugLabel ?? '(无标签)';
    return '$kind label=$label '
        'canRequestFocus=${node.canRequestFocus} '
        'skipTraversal=${node.skipTraversal} '
        'hasFocus=${node.hasFocus}';
  }

  /// 打一条校正决策日志（仅 debug 构建实际输出）。
  static void logHandoff(String stage, String detail) {
    if (!kTvBuild || !kDebugMode) return;
    // ignore: avoid_print
    print('[TvFocusHandoff] $stage $detail');
  }
}
