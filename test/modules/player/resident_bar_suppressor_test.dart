import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/modules/player/secondary_mini_player.dart';

/// 二级路由形态设置页的「无播放栏」保障：[ResidentBarSuppressor] 挂载期间置位
/// [kSuppressResidentMiniPlayer]，`_MainLayout` 据此（与当前 tab 二级态合取）隐藏
/// 底部常驻 MiniPlayer。这里钉住包装件的引用计数语义——消费端的合取逻辑在
/// `_MainLayout._buildBody`（私有，无法直接测），真机验收走 profile 包。
void main() {
  tearDown(() {
    // 防止用例异常退出时置位泄漏到后续用例（引用计数由框架卸载正常归零）。
    kSuppressResidentMiniPlayer.value = false;
  });

  testWidgets('挂载置位，卸载复位', (tester) async {
    expect(kSuppressResidentMiniPlayer.value, isFalse);

    await tester.pumpWidget(
      const ResidentBarSuppressor(child: SizedBox.expand()),
    );
    expect(
      kSuppressResidentMiniPlayer.value,
      isTrue,
      reason: 'push 出该路由（构建即挂载）就应隐藏常驻条',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    expect(
      kSuppressResidentMiniPlayer.value,
      isFalse,
      reason: 'pop 动画结束路由销毁后常驻条要恢复',
    );
  });

  testWidgets('child 换建（父组件重建）不误清置位', (tester) async {
    await tester.pumpWidget(
      const ResidentBarSuppressor(child: SizedBox.expand()),
    );
    expect(kSuppressResidentMiniPlayer.value, isTrue);

    // 同一包装件换了 child：State 保留，不触发 dispose/initState 往返。
    await tester.pumpWidget(
      const ResidentBarSuppressor(child: SizedBox.shrink()),
    );
    expect(kSuppressResidentMiniPlayer.value, isTrue);
  });

  testWidgets('多实例按引用计数，最后一个卸载才复位', (tester) async {
    await tester.pumpWidget(
      const Column(
        children: [
          ResidentBarSuppressor(child: SizedBox.shrink()),
          ResidentBarSuppressor(child: SizedBox.shrink()),
        ],
      ),
    );
    expect(kSuppressResidentMiniPlayer.value, isTrue);

    // 只卸载一个（另一个 tab 还停着该页）：置位必须保持。
    await tester.pumpWidget(
      const Column(
        children: [ResidentBarSuppressor(child: SizedBox.shrink())],
      ),
    );
    expect(
      kSuppressResidentMiniPlayer.value,
      isTrue,
      reason: '两个 tab 各停着一个该页时，先 pop 的那个不能清掉置位',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    expect(kSuppressResidentMiniPlayer.value, isFalse);
  });
}
