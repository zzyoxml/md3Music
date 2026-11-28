// Windows「鼠标点暂停整窗卡一下」回归：传输簇的按压/水波/形变动画必须自带重绘边界。
//
// **背景**：空格走 `DesktopInputLayer` 直接 `player.pause()`，不产生任何按压动画；
// 鼠标点击会额外触发 200~600ms 的满帧水波/按压/形变。这些动画的 `markNeedsPaint`
// 会冒泡到最近的重绘边界 —— 传输簇外层没有边界时，一次点击会把整页（流光背景、
// 歌词、写真）连坐重绘，Windows 上就是「整窗掉帧，换成空格就不卡」。
//
// 本文件两段：
// 1) AM 传输簇：用兄弟哨兵渲染对象统计重绘次数。先用裸 `IconButton` 证明
//    「无边界 = 逐帧连坐兄弟」的机制，再断言真实传输簇只剩一次性的非动画重绘；
// 2) MD3 传输行 / 迷你条传输簇：结构断言（组件内部自带 RepaintBoundary）；
// 3) 桌面底栏：源码结构断言（子块包边界 + Windows 回退 InkSparkle 水波）。
import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/modules/player/am_transport_controls.dart';
import 'package:md3music/modules/player/bottom_bar_morph_overlay.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/widgets/md3e_transport_row.dart';

/// 只统计自身被重绘次数的哨兵渲染对象（传输簇的兄弟节点）。
class _PaintSpy extends SingleChildRenderObjectWidget {
  const _PaintSpy({super.key});

  @override
  _RenderPaintSpy createRenderObject(BuildContext context) => _RenderPaintSpy();
}

class _RenderPaintSpy extends RenderProxyBox {
  int paints = 0;

  @override
  void paint(PaintingContext context, Offset offset) {
    paints += 1;
    super.paint(context, offset);
  }
}

/// 只覆写播放态 getter 的假 provider（与本目录既有测试同款）。
class _FakePlayer extends PlayerProvider {
  @override
  bool get isPlaying => true;
}

void main() {
  const ValueKey<String> spyKey = ValueKey<String>('transport-paint-spy');

  /// 同构 harness：哨兵在上、被测控件在下（同属一个非边界父节点）。
  Widget host(Widget control) => MaterialApp(
    home: Scaffold(
      body: Column(
        children: <Widget>[
          const SizedBox(height: 120, child: _PaintSpy(key: spyKey)),
          Center(child: control),
        ],
      ),
    ),
  );

  /// 点一次并逐帧推进 12 帧（≈ 涟漪动画的可见段），返回哨兵重绘次数。
  Future<int> tapsAndCount(WidgetTester tester, Finder target) async {
    final _RenderPaintSpy spy = tester.renderObject<_RenderPaintSpy>(
      find.byKey(spyKey),
    );
    spy.paints = 0;
    await tester.tap(target);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    return spy.paints;
  }

  testWidgets('对照组：裸 IconButton 的水波会逐帧连坐兄弟节点', (tester) async {
    await tester.pumpWidget(
      host(IconButton(onPressed: () {}, icon: const Icon(Icons.play_arrow))),
    );

    final int paints = await tapsAndCount(tester, find.byType(IconButton));

    // 机制自证：没有本层重绘边界时，涟漪的每一帧都会重绘兄弟/整页。
    expect(
      paints,
      greaterThanOrEqualTo(5),
      reason: '对照组必须复现「无边界 → 逐帧连坐」，否则本测试失去意义',
    );
  });

  testWidgets('AM 传输簇：点击播放键的涟漪不再连坐同页兄弟重绘', (tester) async {
    await tester.pumpWidget(
      host(
        AMTransportControls(
          isPlaying: true,
          onPrevious: () {},
          onPlayPause: () {},
          onNext: () {},
        ),
      ),
    );

    // 中央播放键（第 2 个 IconButton）。
    final int paints = await tapsAndCount(
      tester,
      find.byType(IconButton).at(1),
    );

    // 允许一次性的按压/焦点状态重绘；不允许逐帧连坐（对照组是 12 次）。
    expect(
      paints,
      lessThanOrEqualTo(1),
      reason: '按压水波必须锁在传输簇自己的重绘边界内，不能连坐整页',
    );
  });

  testWidgets('MD3 传输行自带重绘边界', (tester) async {
    await tester.pumpWidget(
      host(
        MD3ETransportRow(
          isPlaying: true,
          onPrevious: () {},
          onPlayPause: () {},
          onNext: () {},
        ),
      ),
    );

    expect(
      find.descendant(
        of: find.byType(MD3ETransportRow),
        matching: find.byType(RepaintBoundary),
      ),
      findsWidgets,
    );
  });

  testWidgets('迷你条传输簇自带重绘边界', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final _FakePlayer player = _FakePlayer();
    addTearDown(player.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<PlayerProvider>.value(
        value: player,
        child: MaterialApp(
          home: Scaffold(
            body: Center(child: PlayerBarTransport(player: player)),
          ),
        ),
      ),
    );

    expect(
      find.descendant(
        of: find.byType(PlayerBarTransport),
        matching: find.byType(RepaintBoundary),
      ),
      findsWidgets,
    );
  });

  test('桌面底栏：传输子块包重绘边界 + Windows 回退 InkSparkle 水波', () {
    final String source = File(
      'lib/modules/player/now_playing_bar.dart',
    ).readAsStringSync();
    // 剔行注释，避免注释文字冒充实现。
    final String code = source
        .split('\n')
        .where((String line) => !line.trimLeft().startsWith('//'))
        .join('\n');

    expect(code.contains('child: _NowPlayingControls('), isTrue);
    expect(
      code.contains('RepaintBoundary('),
      isTrue,
      reason: '底栏传输子块必须自带重绘边界，否则一次点击重绘整条底栏之外的内容',
    );
    expect(
      code.contains(
        'splashFactory: isWindowsDesktop ? InkRipple.splashFactory : null',
      ),
      isTrue,
      reason: 'Windows 桌面端必须回退 m3e 默认的 InkSparkle 运行时着色器水波',
    );
  });
}
