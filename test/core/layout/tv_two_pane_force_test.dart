import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/build_flags.dart';
import 'package:md3music/core/layout/adaptive_navigator.dart';
import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/widgets/resizable_splitter.dart';

/// tv: TV 构建强制双栏（不随分辨率/DPI 自适应退化单栏）。
///
/// 背景（2026-10-25 真机问题）：我的收藏页在单栏视图下焦点无法移动到歌单上、
/// 无法进入详情；双栏正常。TV 焦点体系（两层顶栏、TvNavFocusBridge、挂在
/// 详情面板 Navigator 上的焦点校正观察者）全部以双栏 master-detail 为前提，
/// 故按 fallback 决策强制 TV 恒双栏，而非补全单栏焦点路径。
///
/// 后续（2026-10-26）：窄视口（<kTwoPaneForcedMinWidth=812dp）已由壳层
/// 绕过 DesktopTwoPane 改走中央栈整屏详情（见 tv_single_pane_bypass_test），
/// 本文件覆盖的是 ≥812dp 的强制双栏不塌缩。
///
/// 本用例在 `MD3_TV=true` 下运行（`kTvBuild` 为 const，强制分支整段树摇剔除）：
/// `flutter test --dart-define=MD3_TV=true test/core/layout/tv_two_pane_force_test.dart`
void main() {
  // TV 播种恒 true（main.dart），这里再显式关掉开关验证「强制」优先于开关。
  setUp(() {
    kWindowsTwoPaneEnabled.value = false;
  });
  tearDown(() => kWindowsTwoPaneEnabled.value = false);

  for (final entry in [
    (label: '720p TV 视口（1280×720）', size: const Size(1280, 720)),
    (label: 'tv_1080p AVD 逻辑尺寸（960×540，低于 1000dp 断点但高于 812 强制下限）', size: const Size(960, 540)),
  ]) {
    testWidgets('TV ${entry.label}：开关关闭仍强制双栏', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = entry.size;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopTwoPane(
            responsive: true,
            master: const SizedBox.expand(key: Key('tv-master')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byType(ResizableSplitter),
        findsOneWidget,
        reason: '强制双栏：分隔条必须在场',
      );
      expect(
        tester.getSize(find.byKey(const Key('tv-master'))).width,
        lessThan(entry.size.width),
        reason: 'master 列只占左侧，不是单栏整宽',
      );
      expect(tester.takeException(), isNull);
    }, skip: !kTvBuild);
  }
}
