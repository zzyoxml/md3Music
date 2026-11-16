import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Windows 播放页窗口语义的接线契约（Discussion #180）。
///
/// **背景**：播放页没有 32dp 标题栏（`WindowsWindowFrame` 在 `expansion > 0`
/// 时隐藏它，保持播放页满客户区与坐标空间一致）。桌面端的窗口可达性因此必须
/// 落在播放页自己的 UI 上：
///
/// 1. 顶栏竖向拖动 → 原生窗口移动（`WindowsWindowControls.startDrag`），
///    双击 → 最大化/还原；
/// 2. **顶栏**的「下拉收起」在 Windows 上必须关闭（顶栏是窗口拖动区）；
///    封面下拉收起保留原行为（`_coverPullToCollapseEnabled`，全平台含 Windows）；
/// 3. 最小化 / 最大化 / 关闭：顶栏右上角常驻三键 +「更多」菜单兜底。
///
/// 用源码结构断言而不是 widget 测试：两套播放页依赖整串 Provider / 路由 /
/// 音频服务，构造成本高；本条的实质是「这些接线不得被挪走或漏掉」。
void main() {
  final files = [
    'lib/modules/player/full_player.dart',
    'lib/modules/player/full_player_am.dart',
  ];

  String codeOf(String path) => File(path)
      .readAsStringSync()
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');

  test('两套播放页都走窗口服务与下拉禁用开关', () {
    for (final path in files) {
      final code = codeOf(path);
      expect(code.contains('WindowsWindowControls.startDrag'),
          isTrue, reason: '$path：顶栏拖动必须交给原生窗口');
      expect(code.contains('WindowsWindowControls.toggleMaximize'),
          isTrue, reason: '$path：双击顶栏 / 菜单需要最大化入口');
      expect(code.contains('WindowsWindowControls.minimize'),
          isTrue, reason: '$path：更多菜单需要最小化入口');
      expect(code.contains('WindowsWindowControls.closeWindow'),
          isTrue, reason: '$path：更多菜单需要关闭入口');
      expect(
        code.contains(
          'bool get _pullToCollapseEnabled => !widget.dockMode && !isWindowsDesktop;',
        ),
        isTrue,
        reason: '$path：顶栏下拉收起必须在 Windows 关闭',
      );
      // 封面拖动收起恢复原有全平台行为（Windows 的窗口拖动只在顶栏中段）。
      expect(
        code.contains('bool get _coverPullToCollapseEnabled => !widget.dockMode;'),
        isTrue,
        reason: '$path：封面下拉收起必须恢复（含 Windows）',
      );
      expect(
        RegExp(r'_coverPullToCollapseEnabled\s*\n?\s*\?').allMatches(code).length,
        greaterThanOrEqualTo(4),
        reason: '$path：封面拖动必须接在封面手势上',
      );
      // 播放页右上角常驻窗口三键（与系统标题栏同一套组件）。
      expect(
        code.contains('WindowsCaptionButtonRow('),
        isTrue,
        reason: '$path：Windows 顶栏缺少窗口三键',
      );
      expect(
        code.contains("keyPrefix: 'player_window'"),
        isTrue,
        reason: '$path：窗口三键需要独立 key 前缀（标题栏那组在 Frame 里）',
      );
      // 窗口拖动只挂中段空白区：整条顶栏接管会吞掉收起键 / 三键的点击，
      // 最大化时还会把窗口从最大化态还原，收起键看起来「点不到」。
      expect(
        code.contains(
          'onWindowDrag: desktopWindowDrag ? _startWindowDrag : null',
        ),
        isTrue,
        reason: '$path：窗口拖动必须挂在中段空白区',
      );
      expect(
        code.contains('onPanStart: desktopWindowDrag ? _startWindowDrag : null'),
        isFalse,
        reason: '$path：不得再让整条顶栏接管窗口拖动',
      );
      // Windows 顶栏左右贴边：左上收起键 / 右上三键的命中区顶到窗口角落。
      expect(
        code.contains('left: desktopWindowDrag ? 0 : 8'),
        isTrue,
        reason: '$path：Windows 顶栏左侧必须不内缩',
      );
      expect(
        RegExp(r'right: desktopWindowDrag\s*\?\s*0').hasMatch(code),
        isTrue,
        reason: '$path：Windows 顶栏右侧必须不内缩',
      );
      expect(
        RegExp(r'SizedBox\(\s*width: kPlayerTopBarDragZoneHeight')
            .hasMatch(code),
        isTrue,
        reason: '$path：收起键需要 48dp 固定命中盒',
      );
      expect(
        code.contains('height: kPlayerTopBarDragZoneHeight'),
        isTrue,
        reason: '$path：窗口三键必须填满顶栏行高',
      );
    }
  });

  /// 右键封面 → 「沉浸但不全屏」的接线契约。
  ///
  /// 三条都必须存在且互相配套：
  /// 1. 封面层挂 `onSecondaryTap`（`SecondaryTapGestureRecognizer` 会进手势竞技场，
  ///    能顶掉外层竖向拖拽的 sweep；换成 `Listener` 收 buttons 位就压不住
  ///    「右键点封面 → 播放页闪回收起」）；
  /// 2. 右键进入时 `windowFullscreen: false`（否则会调 `WindowsFullscreen.enterZen()`
  ///    把窗口撑成全屏，与「保留原窗口大小」相悖）；
  /// 3. peek 4s 自动回 Zen 必须沿用本趟取值（否则右键进的沉浸会在 4 秒后突然全屏）。
  test('两套播放页都接右键沉浸且不持窗口全屏', () {
    for (final path in files) {
      final code = codeOf(path);
      expect(
        code.contains('onSecondaryTap: _toggleZenBySecondaryClick'),
        isTrue,
        reason: '$path：封面必须接鼠标右键切换沉浸',
      );
      expect(
        code.contains('_enterZenMode(windowFullscreen: false)'),
        isTrue,
        reason: '$path：右键进入的沉浸不得持窗口全屏',
      );
      expect(
        code.contains('_enterZenMode(windowFullscreen: _zenWindowFullscreen)'),
        isTrue,
        reason: '$path：peek 回 Zen 必须沿用本趟的窗口全屏取值',
      );
      // 长按入口保持历史语义（连带全屏）：默认参数不得被改成 false。
      expect(
        code.contains('void _enterZenMode({bool windowFullscreen = true})'),
        isTrue,
        reason: '$path：长按 / F11 进 Zen 仍要连带窗口全屏',
      );
    }
  });

  /// 窗口模式 Zen（右键封面进入）的窗口拖拽带契约。
  ///
  /// Zen 把顶栏（唯一拖动区）折叠掉后，右键进入的沉浸窗口仍是普通窗口，
  /// 必须有一条补位拖拽带，且只在「Windows + 非 dockMode + Zen 中 + 未持
  /// 窗口全屏」渲染（全屏无可移动；peek 期间 _zenMode 已翻回 false）。
  test('两套播放页都带窗口模式 Zen 的补位拖拽带', () {
    for (final path in files) {
      final code = codeOf(path);
      expect(
        code.contains(
          'isWindowsDesktop && !widget.dockMode && _zenMode && !_zenWindowFullscreen',
        ),
        isTrue,
        reason: '$path：拖拽带必须按「窗口模式 Zen」四条件门控',
      );
      expect(
        code.contains('onPanStart: _startWindowDrag'),
        isTrue,
        reason: '$path：拖拽带必须走同一条原生 startDrag 通道',
      );
      expect(
        code.contains('if (_zenWindowDragStripVisible)'),
        isTrue,
        reason: '$path：拖拽带必须条件渲染（非 Windows / 非 Zen 零布局变化）',
      );
    }
  });

  test('每个竖向拖拽接线要么禁用、要么是窗口拖动/封面收起', () {
    for (final path in files) {
      final lines = codeOf(path).split('\n');
      var count = 0;
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].contains('onVerticalDragStart')) continue;
        count++;
        final block = lines.skip(i).take(4).join('\n');
        expect(
          block.contains('_pullToCollapseEnabled') ||
              block.contains('_coverPullToCollapseEnabled') ||
              block.contains('desktopWindowDrag'),
          isTrue,
          reason: '$path:${i + 1} 的竖向拖拽未按平台门控',
        );
      }
      expect(count, greaterThan(0), reason: '$path：未找到任何竖向拖拽接线');
    }
  });
}
