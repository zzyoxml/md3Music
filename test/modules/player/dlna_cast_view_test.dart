// DlnaCastSheet 抽壳回归：原调用点（锁屏深链 / MV 页 / AM 页）必须一字不变，
// 面板嵌入时标题要让给面板自己的头，避免"播放与输出 / 投屏到设备"两层标题。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import 'package:md3music/modules/player/dlna_cast_sheet.dart';
import 'package:md3music/providers/dlna_provider.dart';

/// 只把 SSDP 搜索换成空实现：单测没有局域网，验的是布局不是发现协议。
class _QuietDlnaProvider extends DlnaProvider {
  @override
  Future<void> startSearch() async {}
}

/// 停在「搜索中」：真实 startSearch 会建 socket 与内部定时器，单测里留下
/// pending timer；用 debug 口子切状态即可验指示器常驻。
class _SearchingDlnaProvider extends DlnaProvider {
  @override
  Future<void> startSearch() async => debugEnterSearching();
}

Widget _host(Widget child, {DlnaProvider? dlna}) {
  return MaterialApp(
    home: ChangeNotifierProvider<DlnaProvider>.value(
      value: dlna ?? _QuietDlnaProvider(),
      child: Scaffold(body: child),
    ),
  );
}

void main() {
  testWidgets('DlnaCastSheet 仍是一个完整的投屏面板', (tester) async {
    await tester.pumpWidget(_host(const DlnaCastSheet()));
    await tester.pumpAndSettle();
    expect(find.byType(DlnaCastView), findsOneWidget);
    expect(find.text('投屏到设备'), findsOneWidget);
  });

  testWidgets('嵌入模式（showHeader: false）不画自己的标题行', (tester) async {
    await tester.pumpWidget(_host(const DlnaCastView(showHeader: false)));
    await tester.pumpAndSettle();
    expect(find.text('投屏到设备'), findsNothing);
    expect(
      find.text('未发现设备\n请确保设备已连接同一 WiFi 并支持 DLNA'),
      findsOneWidget,
    );
  });

  testWidgets('搜索中：嵌入模式（标题行整块隐藏）也显示 M3E loading 指示器', (
    tester,
  ) async {
    // 指示器必须**不挂在标题行里**：嵌入「播放与输出」面板时标题行整块隐藏
    // （showHeader=false），挂在标题右侧的 spinner 会跟着消失，用户对着
    // 「未发现设备」干等。
    // 不 pumpAndSettle：M3ELoadingIndicator 是无限动画，settle 会超时；
    // 一帧足够让 initState 的 post-frame startSearch 跑完。
    await tester.pumpWidget(
      _host(const DlnaCastView(showHeader: false), dlna: _SearchingDlnaProvider()),
    );
    await tester.pump();
    expect(find.byType(M3ELoadingIndicator), findsOneWidget);
    expect(find.text('正在搜索设备...\n请确保设备已连接同一 WiFi'), findsOneWidget);
  });
}
