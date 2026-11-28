import 'package:dpad/dpad.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/build_flags.dart';
import 'package:md3music/core/remote/tv_scroll_region.dart';

void main() {
  testWidgets('非 TV 构建（kTvBuild=false）原样透传 child，不产生 DpadRegion', (
    tester,
  ) async {
    const marker = Key('marker');
    await tester.pumpWidget(
      const TvScrollRegion(
        memoryKey: 'tv/test-row',
        child: SizedBox(key: marker),
      ),
    );
    expect(find.byKey(marker), findsOneWidget);
    // kTvBuild 为 const false：DpadRegion 不应进入元素树
    expect(find.byType(DpadRegion), findsNothing);
    // kTvBuild 是编译期常量：本用例断言的是「非 TV」分支，带
    // --dart-define=MD3_TV=true 单跑本目录时必须跳过（同 remote_slider_test 惯例）。
  }, skip: kTvBuild);
}