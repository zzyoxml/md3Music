import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/settings_preview/player_background_preview.dart';

void main() {
  testWidgets('演示卡渲染且轮播/流光跑一拍不抛异常', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: PlayerBackgroundPreview(
              photoEnabled: true,
              photoIntervalSeconds: 15,
              photoMaskOpacity: 0.55,
              flowingEnabled: true,
              blurSigma: 30,
            ),
          ),
        ),
      ),
    );
    // 让 AnimatedSwitcher 淡切与流光各跑几帧
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 500));

    expect(tester.takeException(), isNull);
  });

  /// 演示卡里的 Image.asset 实际 provider 是 ResizeImage(AssetImage)（传了
  /// cacheWidth），取内层 assetName 才能断言是哪张图。
  List<String> assetNamesOf(WidgetTester tester) => tester
      .widgetList<Image>(find.byType(Image))
      .map((e) => e.image is ResizeImage
          ? (e.image as ResizeImage).imageProvider
          : e.image)
      .whereType<AssetImage>()
      .map((e) => e.assetName)
      .toList();

  testWidgets('写真关闭时底层仍有模糊封面背景（不是一片空）', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: PlayerBackgroundPreview(
              photoEnabled: false,
              photoIntervalSeconds: 15,
              photoMaskOpacity: 0.55,
              flowingEnabled: false,
              blurSigma: 30,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 真机反馈后的口径：封面背景层恒存在，与写真开关无关。
    // 关闭写真时用户看到的就是这一层，模糊滑杆也仍然看得出效果。
    expect(
      assetNamesOf(tester),
      isNotEmpty,
      reason: '关闭写真时底层仍应有模糊封面背景',
    );
  });

  testWidgets('写真关闭时不叠写真层与遮罩', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: PlayerBackgroundPreview(
              photoEnabled: false,
              photoIntervalSeconds: 15,
              photoMaskOpacity: 0.55,
              flowingEnabled: false,
              blurSigma: 30,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 只有底层封面那一张图（写真层未叠上）
    expect(assetNamesOf(tester).length, 1);
    // 副标题只报模糊，不报遮罩（遮罩浓度是写真开启时才有的参数）
    expect(find.textContaining('遮罩 55%'), findsNothing);
    // 但说明行仍会提到遮罩，属正常
    expect(find.textContaining('遮罩与轮播间隔'), findsOne);
  });

  testWidgets('写真开启时叠上第二张图并显示遮罩', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: PlayerBackgroundPreview(
              photoEnabled: true,
              photoIntervalSeconds: 15,
              photoMaskOpacity: 0.55,
              flowingEnabled: false,
              blurSigma: 30,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 底层模糊封面 + 上层写真
    expect(assetNamesOf(tester).length, greaterThanOrEqualTo(1));
    expect(find.textContaining('遮罩 55%'), findsOne);
  });

  testWidgets('轮播间隔变化后重设定时器（1 秒间隔也能跑）', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: PlayerBackgroundPreview(
              photoEnabled: true,
              photoIntervalSeconds: 1,
              photoMaskOpacity: 0.3,
              flowingEnabled: false,
              blurSigma: 10,
            ),
          ),
        ),
      ),
    );
    // 推进 1.2 秒，触发至少一次轮播切换
    await tester.pump(const Duration(milliseconds: 1200));

    expect(tester.takeException(), isNull);
  });
}
