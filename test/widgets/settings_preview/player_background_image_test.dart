import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/settings_preview/player_background_preview.dart';

void main() {
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

  testWidgets('写真开启时底层是内置壁纸图（不是纯色块）', (tester) async {
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

    expect(
      assetNamesOf(tester),
      contains('assets/images/default_wallpaper.jpg'),
      reason: '底层封面背景应为内置默认壁纸',
    );
  });

  testWidgets('写真关闭时仍有底层模糊封面（不是空/纯色）', (tester) async {
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

    // 与播放页同源：封面背景层恒存在，与「歌手写真背景轮播」开关无关，
    // 只受「播放页背景模糊」控制。故关闭写真时仍应有图可看。
    expect(
      assetNamesOf(tester),
      contains('assets/images/default_wallpaper.jpg'),
      reason: '关闭写真时底层仍应有模糊封面背景',
    );
  });

  testWidgets('写真开启时叠加的图数量多于关闭时', (tester) async {
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
    final withPhoto = assetNamesOf(tester).length;

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
    final withoutPhoto = assetNamesOf(tester).length;

    expect(
      withoutPhoto,
      lessThan(withPhoto),
      reason: '关闭写真后应少一层图',
    );
  });
}
