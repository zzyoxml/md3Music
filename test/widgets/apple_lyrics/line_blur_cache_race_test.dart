import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/apple_lyrics_view.dart';
import 'package:md3music/widgets/apple_lyrics/layout/duet_layout.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:shared_preferences/shared_preferences.dart';

ui.Image makeImage() {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawPaint(ui.Paint());
  final picture = recorder.endRecording();
  final image = picture.toImageSync(2, 2);
  picture.dispose();
  return image;
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LyricPreferences.instance.setUseGaussianBlur(false);
  });

  Future<dynamic> mount(WidgetTester tester, {String text = '旧歌词'}) async {
    await tester.pumpWidget(MaterialApp(home: AppleLyricsView(
      lines: [LyricLine(startTime: 0, duration: 4000, text: text)],
      currentTimeMs: 0,
    )));
    return tester.state(find.byType(AppleLyricsView));
  }

  testWidgets('同签名请求去重，后发结果先完成时旧图不能覆盖', (tester) async {
    final state = await mount(tester);
    final requests = <Completer<ui.Image?>>[];
    state.lineBlurRendererForTest = (int i, int level, DuetAlignment align) {
      final request = Completer<ui.Image?>();
      requests.add(request);
      return request.future;
    };
    state.updateLineBlurCacheForTest(<int, int>{0: 1});
    state.updateLineBlurCacheForTest(<int, int>{0: 1});
    expect(requests.length, 1);
    state.updateLineBlurCacheForTest(<int, int>{0: 2});
    final newest = makeImage();
    requests[1].complete(newest);
    await tester.pump();
    final stale = makeImage();
    requests[0].complete(stale);
    await tester.pump();
    expect(state.lineBlurImageForTest(0), same(newest));
    expect(stale.debugDisposed, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(newest.debugDisposed, isTrue);
  });

  testWidgets('切歌后相同行索引的旧结果必须释放', (tester) async {
    final state = await mount(tester);
    final request = Completer<ui.Image?>();
    state.lineBlurRendererForTest = (int i, int level, DuetAlignment align) => request.future;
    state.updateLineBlurCacheForTest(<int, int>{0: 1});
    await mount(tester, text: '新歌词');
    final stale = makeImage();
    request.complete(stale);
    await tester.pump();
    expect(state.lineBlurImageForTest(0), isNull);
    expect(stale.debugDisposed, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('旧请求先完成不能取消新请求的去重状态', (tester) async {
    final state = await mount(tester);
    final requests = <Completer<ui.Image?>>[];
    state.lineBlurRendererForTest = (int i, int level, DuetAlignment align) {
      final request = Completer<ui.Image?>();
      requests.add(request);
      return request.future;
    };
    state.updateLineBlurCacheForTest(<int, int>{0: 1});
    state.updateLineBlurCacheForTest(<int, int>{0: 2});
    final stale = makeImage();
    requests[0].complete(stale);
    await tester.pump();
    state.updateLineBlurCacheForTest(<int, int>{0: 2});
    expect(requests.length, 2);
    expect(stale.debugDisposed, isTrue);
    requests[1].complete(null);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('字号改变后未完成的旧几何图片不能写回', (tester) async {
    final state = await mount(tester);
    final originalSize = LyricPreferences.instance.fontSize;
    final request = Completer<ui.Image?>();
    state.lineBlurRendererForTest = (int i, int level, DuetAlignment align) => request.future;
    state.updateLineBlurCacheForTest(<int, int>{0: 1});
    await LyricPreferences.instance.setFontSize(originalSize == 30 ? 28 : 30);
    await tester.pump();
    final stale = makeImage();
    request.complete(stale);
    await tester.pump();
    expect(state.lineBlurImageForTest(0), isNull);
    expect(stale.debugDisposed, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await LyricPreferences.instance.setFontSize(originalSize);
  });

  testWidgets('退出页面后迟到的图片不能写回并且必须释放', (tester) async {
    final state = await mount(tester);
    final request = Completer<ui.Image?>();
    state.lineBlurRendererForTest = (int i, int level, DuetAlignment align) => request.future;
    state.updateLineBlurCacheForTest(<int, int>{0: 1});
    await tester.pumpWidget(const SizedBox.shrink());
    final stale = makeImage();
    request.complete(stale);
    await tester.pump();
    expect(state.lineBlurImageForTest(0), isNull);
    expect(stale.debugDisposed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('行离开模糊范围后未完成请求失效', (tester) async {
    final state = await mount(tester);
    final request = Completer<ui.Image?>();
    state.lineBlurRendererForTest = (int i, int level, DuetAlignment align) => request.future;
    state.updateLineBlurCacheForTest(<int, int>{0: 1});
    state.updateLineBlurCacheForTest(<int, int>{});
    final stale = makeImage();
    request.complete(stale);
    await tester.pump();
    expect(state.lineBlurImageForTest(0), isNull);
    expect(stale.debugDisposed, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('失败的请求不阻止再次渲染', (tester) async {
    final state = await mount(tester);
    var count = 0;
    state.lineBlurRendererForTest = (int i, int level, DuetAlignment align) async {
      count++;
      return null;
    };
    state.updateLineBlurCacheForTest(<int, int>{0: 1});
    await tester.pump();
    state.updateLineBlurCacheForTest(<int, int>{0: 1});
    await tester.pump();
    expect(count, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
