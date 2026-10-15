import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/user/cloud_upload_queue_sheet.dart';
import 'package:md3music/providers/cloud_upload_provider.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 云盘上传队列面板：真实渲染回归（复现真机「此处内容加载出错」）。
/// 注意：m3e 面板内进度指示器有常驻动画，禁止 pumpAndSettle（永不收敛），
/// 一律用固定 pump + tester.takeException() 捕获构建异常。
void main() {
  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // ensureMatchLoaded 读设置（SharedPreferences），测试环境必须 mock
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('queue_sheet_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  CloudUploadProvider seededProvider(File file, {bool matched = true}) {
    final provider = CloudUploadProvider(
      isLoggedInFn: () => true,
      uploadFn: (body,
          {required extendname,
          name,
          authorName,
          timelen,
          required matchUpload,
          onProgress,
          onStage}) async {
        return {
          'status': 1,
          'matchInfo': {'matched': matched},
        };
      },
    );
    provider.enqueueSongs([
      Song(
        id: 'local_${file.path}',
        title: '测试歌曲',
        artist: '测试歌手',
        album: '',
        duration: const Duration(seconds: 3),
        localPath: file.path,
      ),
    ]);
    return provider;
  }

  Future<CloudUploadProvider> waitIdle(CloudUploadProvider provider) async {
    for (var i = 0; i < 100 && provider.isRunning; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return provider;
  }

  /// testWidgets 运行在 FakeAsync 区：Provider 上传管线用真实文件 IO，
  /// 必须经 [tester.runAsync] 在真实异步区完成种子与等待，否则永不收敛。
  Future<CloudUploadProvider> seedAndSettle(
    WidgetTester tester,
    File file, {
    bool matched = true,
  }) async {
    return (await tester.runAsync(() async {
      final provider = seededProvider(file, matched: matched);
      await waitIdle(provider);
      return provider;
    }))!;
  }

  testWidgets('队列面板渲染成功任务行不抛异常', (tester) async {
    final file = File('${tempDir.path}/测试歌曲.mp3')
      ..writeAsBytesSync(List.generate(64, (i) => i));
    final provider = await seedAndSettle(tester, file);
    expect(provider.successCount, 1);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<CloudUploadProvider>.value(value: provider),
        ],
        child: const MaterialApp(home: Scaffold(body: SizedBox.expand())),
      ),
    );
    final context = tester.element(find.byType(Scaffold));

    showCloudUploadQueueSheet(context);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final e1 = tester.takeException();
    await tester.pump(const Duration(seconds: 1));
    final e2 = tester.takeException();

    if (e1 != null || e2 != null) {
      fail('面板构建抛异常: e1=$e1\n\ne2=$e2');
    }
    // 任务行真实渲染出来（行抛异常时文本会被 ErrorWidget 替代）
    expect(find.text('测试歌曲'), findsOneWidget);
    expect(find.text('已匹配官方曲库'), findsOneWidget);
  });

  testWidgets('横幅在队列非空时渲染且可点击开面板', (tester) async {
    final file = File('${tempDir.path}/b.mp3')
      ..writeAsBytesSync(List.generate(64, (i) => i));
    final provider = await seedAndSettle(tester, file, matched: false);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<CloudUploadProvider>.value(value: provider),
        ],
        child: const MaterialApp(home: Scaffold(body: CloudUploadBanner())),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    final e = tester.takeException();
    if (e != null) fail('横幅构建抛异常: $e');

    // 横幅文本可见（InkWell 是 flutter/material 类型，与本测试导入的
    // material_ui 同名不同型，故按文本定位而非类型）
    final bannerText = find.textContaining('上传队列 1/1');
    expect(bannerText, findsOneWidget);

    await tester.tap(bannerText);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final e2 = tester.takeException();
    if (e2 != null) fail('面板打开抛异常: $e2');
    expect(find.text('测试歌曲'), findsOneWidget);
  });
}
