// DepthCoverHost 在「Windows + 已有分层缓存」下的布局/交互回归。
//
// 这条测试是为了钉死 2026-10-28 的真机卡死：
//   `RenderBox was not laid out: _RenderLayoutBuilder ... NEEDS-PAINT`
// 当时用 `LayoutBuilder` 取封面尺寸，播放页同时挂前后两张封面（淡入淡出）+
// 封面形变层离屏取用时，`LayoutBuilder` 出现「没 layout 就被 paint」→ 框架每帧
// 重试 → 整窗卡死。修法：`MouseRegion.onHover` 里用本 State 的 RenderBox 尺寸。
//
// 需要 `--dart-define=ENABLE_DEPTH_3D=true` 才会真正走到 3D 分支
// （`kDepthCoverAvailable` 是编译期常量）。运行方式：
//   flutter test test/widgets/depth_cover_host_layout_test.dart --dart-define=ENABLE_DEPTH_3D=true
// 没有该 define 时整组跳过（不把失败留给普通的 `flutter test` 全量跑）。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/depth_cover_feature.dart';
import 'package:md3music/widgets/depth_cover_host.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 最小 path_provider 替身：所有目录都指到测试临时目录。
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => root;

  /// 让 `DepthCoverCache._baseDir()` 走 "外部存储不存在 → 文档目录" 的回退分支。
  @override
  Future<String?> getExternalStoragePath() async =>
      throw UnimplementedError('测试环境无外部存储');
}

Future<void> _writePng(String path, int w, int h, Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = color,
  );
  final image = await recorder.endRecording().toImage(w, h);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  File(path).writeAsBytesSync(bytes!.buffer.asUint8List());
}

void main() {
  if (!kDepthCoverAvailable) {
    // 未带 --dart-define=ENABLE_DEPTH_3D=true：3D 分支在编译期被整段剔除，
    // 这里没有可测行为，直接跳过（而不是让普通 `flutter test` 变红）。
    return;
  }

  late Directory tmpRoot;
  late String layer0;
  late String layer1;
  late String layer2;

  setUp(() async {
    tmpRoot = Directory.systemTemp.createTempSync('depth_host_layout');
    PathProviderPlatform.instance = _FakePathProvider(tmpRoot.path);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'settings_depth_cover_enabled': true,
      'settings_depth_cover_strength': 9.0,
    });

    // 预置分层缓存，让宿主挂载即命中 layers（不触发真实推理）。
    const uri = 'test://cover';
    final key = md5.convert(uri.codeUnits).toString();
    final dir = Directory(
        '${tmpRoot.path}${Platform.pathSeparator}stream_cache${Platform.pathSeparator}depth_cover${Platform.pathSeparator}$key');
    dir.createSync(recursive: true);
    layer0 = '${dir.path}${Platform.pathSeparator}layer0.png';
    layer1 = '${dir.path}${Platform.pathSeparator}layer1.png';
    layer2 = '${dir.path}${Platform.pathSeparator}layer2.png';
    await _writePng(layer0, 32, 32, const Color(0xFF102030));
    await _writePng(layer1, 32, 32, const Color(0xFF203040));
    await _writePng(layer2, 32, 32, const Color(0xFF304050));

  });

  tearDown(() {
    try {
      tmpRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  // Windows 口径用 variant 表达（不能在 setUp 里改 debugDefaultTargetPlatformOverride：
  // flutter_test 会在 tearDown 之前检查「debug 变量已复位」，手工设置会直接报
  // debugAssertAllFoundationVarsUnset）。
  final windowsVariant = TargetPlatformVariant.only(TargetPlatform.windows);

  Widget _host() => MaterialApp(
        home: Scaffold(
          body: Center(
            // 复刻播放页：两个 host 叠着做淡入淡出 + Opacity 图层，
            // 这正是当年 LayoutBuilder 出问题的环境。
            child: SizedBox(
              width: 200,
              height: 200,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Opacity(
                    opacity: 0.0,
                    child: DepthCoverHost(
                      artworkUri: 'test://previous',
                      fit: BoxFit.cover,
                      iconSize: 32,
                      backgroundColor: Colors.black,
                      iconColor: Colors.white,
                    ),
                  ),
                  Positioned.fill(
                    child: Opacity(
                      opacity: 0.5,
                      child: DepthCoverHost(
                        artworkUri: 'test://cover',
                        fit: BoxFit.cover,
                        iconSize: 32,
                        backgroundColor: Colors.black,
                        iconColor: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  testWidgets('Windows 命中分层缓存后挂载：不得出现「was not laid out」类异常',
      (tester) async {
    await tester.pumpWidget(_host());
    // 让 _init 的异步设置读取 + 缓存命中跑完
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);

    // 关键路径：这张图必须真的画出来了（多层 = 3 张 Image.file）
    expect(find.byType(DepthCoverHost), findsNWidgets(2));
    expect(find.byType(Image), findsWidgets, reason: '分层图应已渲染');
  }, variant: windowsVariant);

  testWidgets('鼠标 hover 不抛异常（size 从 RenderBox 读取）', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(100, 100));
    addTearDown(mouse.removePointer);
    final center = tester.getCenter(find.byType(DepthCoverHost).last);
    await mouse.moveTo(center);
    await tester.pump(const Duration(milliseconds: 16));
    await mouse.moveTo(center + const Offset(60, 40));
    await tester.pump(const Duration(milliseconds: 16));
    await mouse.moveTo(const Offset(-50, -50)); // 移出 → handleExit
    await tester.pump(const Duration(milliseconds: 32));

    expect(tester.takeException(), isNull);
  }, variant: windowsVariant);
}
