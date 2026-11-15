// TvPlayerBackInterceptor / TvPlayerChromeScope 行为契约测试。
//
// AGENTS §12 惯例：可测组件不带 kTvBuild 门控，普通 flutter test 可钉住行为；
// 调用侧（full_player.dart / full_player_am.dart）的 kTvBuild 接线由真机验收。
//
// 传播机制依据：拦截器是 `Focus(canRequestFocus:false, skipTraversal:true)`，
// 只挂在按键传播路径上（FocusManager 从 primaryFocus 逐级向上调 onKeyEvent），
// 自身不是焦点停点。dpad 的返回键集合含 escape / goBack / gameButtonB，
// 经 `Dpad.keySetOf(context).isBack` 判定。
//
// 两条作用域的分工（2026-10-20 真机问题定案）：
//   * TvPlayerChromeScope   —— 播放控制 chrome 区（传输键 / 模式 / 收藏 /
//                             进度尺 / 音量 / 顶栏）。焦点在这里 → 返回键放行。
//   * TvPlayerTabContentScope —— tab 内容区（列表 / 歌词 / 评论）。焦点在这里
//                             → 返回键交还播放键。
//   * 两者都不在（遥控 TabBar / 封面区）→ 同样交还播放键。判据是「非 chrome」，
//     因为 tab 栏是 pager 的兄弟节点、不在内容区作用域内。

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/remote/tv_player_back_focus.dart';

/// 播放键节点替身：登记到移交桥，验证「焦点被交回播放键」。
///
/// 桥是**进程级单例**（同真实拓扑：多个播放页实例共享一份登记），故每条用例
/// 结束必须 unregister，否则后一条用例会读到前一条留下的节点——「桥里无可用
/// 节点」那条会被污染成「有节点」而假失败。
FocusNode _registerProbePlayNode(String label) {
  final node = FocusNode(debugLabel: label);
  TvPlayerPlayFocusBridge.instance.register(node);
  addTearDown(() {
    TvPlayerPlayFocusBridge.instance.unregister(node);
    node.dispose();
  });
  return node;
}

/// 页面包装：Dpad（返回键计数）+ 拦截层 + 内容。
Widget _page({
  required List<FocusNode> playNodes,
  required List<Widget> children,
  bool Function()? onBack,
}) {
  return MaterialApp(
    builder: Dpad.wrap(onBack: onBack),
    home: TvPlayerBackInterceptor(
      child: Row(children: children),
    ),
  );
}

void main() {
  group('焦点在控制 chrome 区 → 返回键放行给 dpad', () {
    testWidgets('chrome 作用域内的焦点：BACK 交给 onBack，播放键不抢焦点', (
      tester,
    ) async {
      final play = _registerProbePlayNode('probe_play_chrome');
      var backCount = 0;

      await tester.pumpWidget(
        _page(
          playNodes: [play],
          onBack: () {
            backCount++;
            return true;
          },
          children: [
            // 左：chrome 区（播放键就在里面，但焦点不落在它上面）
            Expanded(
              child: TvPlayerChromeScope(
                child: DpadRegion(
                  memoryKey: 'probe_chrome',
                  child: Column(
                    children: [
                      DpadFocusable(
                        focusNode: play,
                        child: const SizedBox(
                          key: Key('play'),
                          height: 48,
                          width: 200,
                        ),
                      ),
                      DpadFocusable(
                        key: const Key('mode'),
                        autofocus: true,
                        child: const SizedBox(height: 48, width: 200),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
      await tester.pump();

      expect(
        FocusManager.instance.primaryFocus,
        isNotNull,
        reason: '前提：首帧焦点落在 chrome 区的第二个停点',
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(backCount, 1, reason: 'chrome 区内返回键必须放行给 dpad');
      expect(play.hasFocus, isFalse, reason: '不得把焦点抢到播放键');
    });
  });

  group('焦点不在控制 chrome 区 → 返回键交还播放键并消费', () {
    testWidgets('遥控 TabBar（两个作用域之外）：BACK 交还播放键', (tester) async {
      final play = _registerProbePlayNode('probe_play_tabbar');
      var backCount = 0;

      await tester.pumpWidget(
        _page(
          playNodes: [play],
          onBack: () {
            backCount++;
            return true;
          },
          children: [
            // 左：chrome 区（播放键）
            Expanded(
              child: TvPlayerChromeScope(
                child: DpadRegion(
                  memoryKey: 'probe_tabbar_chrome',
                  child: DpadFocusable(
                    focusNode: play,
                    child: const SizedBox(
                      key: Key('play'),
                      height: 48,
                      width: 200,
                    ),
                  ),
                ),
              ),
            ),
            // 右：遥控 TabBar —— pager 的兄弟节点，不在内容区作用域内
            Expanded(
              child: DpadRegion(
                memoryKey: 'probe_tabbar',
                child: DpadFocusable(
                  key: const Key('segment'),
                  autofocus: true,
                  child: const SizedBox(height: 48, width: 200),
                ),
              ),
            ),
          ],
        ),
      );
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(play.hasFocus, isTrue, reason: 'tab 栏段上的返回键应把焦点交回播放键');
      expect(backCount, 0, reason: '该次返回必须被消费，不得放行给 dpad');

      // 第二次返回键：焦点现已在 chrome 区 → 放行（收起播放页）。
      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(backCount, 1, reason: '第二次返回放行：焦点已在播放键');
    });

    testWidgets('tab 内容区：BACK 交还播放键（既有行为回归）', (tester) async {
      final play = _registerProbePlayNode('probe_play_content');
      var backCount = 0;

      await tester.pumpWidget(
        _page(
          playNodes: [play],
          onBack: () {
            backCount++;
            return true;
          },
          children: [
            Expanded(
              child: TvPlayerChromeScope(
                child: DpadRegion(
                  memoryKey: 'probe_content_chrome',
                  child: DpadFocusable(
                    focusNode: play,
                    child: const SizedBox(
                      key: Key('play'),
                      height: 48,
                      width: 200,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: TvPlayerTabContentScope(
                child: DpadRegion(
                  memoryKey: 'probe_content_page',
                  child: DpadFocusable(
                    key: const Key('row'),
                    autofocus: true,
                    child: const SizedBox(height: 48, width: 200),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(play.hasFocus, isTrue, reason: '内容区返回键应把焦点交回播放键');
      expect(backCount, 0, reason: '该次返回必须被消费');
    });
  });

  group('失败模式与键码口径', () {
    testWidgets('桥里无可用播放键节点：BACK 放行（不造死键）', (tester) async {
      // 不登记任何播放键节点。
      var backCount = 0;
      await tester.pumpWidget(
        _page(
          playNodes: const [],
          onBack: () {
            backCount++;
            return true;
          },
          children: [
            Expanded(
              child: DpadRegion(
                memoryKey: 'probe_empty_bridge',
                child: DpadFocusable(
                  key: const Key('row'),
                  autofocus: true,
                  child: const SizedBox(height: 48, width: 200),
                ),
              ),
            ),
          ],
        ),
      );
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(backCount, 1, reason: '无播放键可交还时放行，宁可退出也不做死键');
    });

    testWidgets('方向键 / OK 一律放行，不干扰遍历', (tester) async {
      final play = _registerProbePlayNode('probe_play_keys');
      var backCount = 0;

      await tester.pumpWidget(
        _page(
          playNodes: [play],
          onBack: () {
            backCount++;
            return true;
          },
          children: [
            Expanded(
              child: DpadRegion(
                memoryKey: 'probe_keys',
                child: DpadFocusable(
                  key: const Key('row'),
                  autofocus: true,
                  child: const SizedBox(height: 48, width: 200),
                ),
              ),
            ),
          ],
        ),
      );
      await tester.pump();

      for (final key in <LogicalKeyboardKey>[
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.select,
        LogicalKeyboardKey.contextMenu,
      ]) {
        await tester.sendKeyDownEvent(key);
        await tester.pump();
        await tester.sendKeyUpEvent(key);
        await tester.pump();
      }

      expect(backCount, 0, reason: '非返回键不得触发 onBack');
      expect(play.hasFocus, isFalse, reason: '非返回键不得把焦点交到播放键');
    });

    testWidgets('gameButtonB 也认（键码口径对齐 dpad DpadKeySet）', (tester) async {
      final play = _registerProbePlayNode('probe_play_gamepad');
      var backCount = 0;

      await tester.pumpWidget(
        _page(
          playNodes: [play],
          onBack: () {
            backCount++;
            return true;
          },
          children: [
            // 左：播放键（挂在 chrome 作用域内，且**真的进焦点树**——
            // focusPlay() 请求的节点必须已 attach，否则 hasFocus 恒 false）。
            Expanded(
              child: TvPlayerChromeScope(
                child: DpadRegion(
                  memoryKey: 'probe_gamepad_chrome',
                  child: DpadFocusable(
                    focusNode: play,
                    child: const SizedBox(
                      key: Key('play'),
                      height: 48,
                      width: 200,
                    ),
                  ),
                ),
              ),
            ),
            // 右：起点焦点（两个作用域之外的遥控 TabBar 位）。
            Expanded(
              child: DpadRegion(
                memoryKey: 'probe_gamepad',
                child: DpadFocusable(
                  key: const Key('row'),
                  autofocus: true,
                  child: const SizedBox(height: 48, width: 200),
                ),
              ),
            ),
          ],
        ),
      );
      await tester.pump();

      // gameButtonB 只在 **android** 物理键表里，而 flutter_test 的模拟器默认按
      // `defaultTargetPlatform` 选键表、按 debugName 反查物理键。显式指定平台
      // 与物理键即可正常投递（与手柄在 Android TV 上的真实链路一致）。
      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.gameButtonB,
        platform: 'android',
        physicalKey: PhysicalKeyboardKey.gameButtonB,
      );
      await tester.pump();
      await tester.sendKeyUpEvent(
        LogicalKeyboardKey.gameButtonB,
        platform: 'android',
        physicalKey: PhysicalKeyboardKey.gameButtonB,
      );
      await tester.pump();

      expect(play.hasFocus, isTrue, reason: '手柄 B 键应等效返回键');
      expect(backCount, 0, reason: '手柄 B 键该次返回应被消费');
    });

    testWidgets('KeyUp 不重复触发（只在 KeyDown 判定）', (tester) async {
      final play = _registerProbePlayNode('probe_play_keyup');
      var backCount = 0;

      await tester.pumpWidget(
        _page(
          playNodes: [play],
          onBack: () {
            backCount++;
            return true;
          },
          children: [
            Expanded(
              child: TvPlayerChromeScope(
                child: DpadRegion(
                  memoryKey: 'probe_keyup',
                  child: DpadFocusable(
                    key: const Key('row'),
                    autofocus: true,
                    child: const SizedBox(height: 48, width: 200),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
      await tester.pump();

      // 只发 KeyUp（不配套的 KeyDown）：不得触发任何分支。
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(backCount, 0, reason: '裸 KeyUp 不得触发放行');
      expect(play.hasFocus, isFalse, reason: '裸 KeyUp 不得触发交还');
    });

    testWidgets('弹层（独立路由）内的焦点不触发页面级交还', (tester) async {
      final play = _registerProbePlayNode('probe_play_sheet');
      var backCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          builder: Dpad.wrap(
            onBack: () {
              backCount++;
              return true;
            },
          ),
          home: TvPlayerBackInterceptor(
            child: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => showModalBottomSheet<void>(
                      context: context,
                      builder: (_) => Focus(
                        autofocus: true,
                        child: const SizedBox(height: 100),
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // 焦点在 sheet 路由子树内（非本页子孙）：按返回键不得被页面级拦截器
      // 交还到播放键（那会把焦点从弹层里抢走）。
      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(
        play.hasFocus,
        isFalse,
        reason: '弹层内焦点不得被页面级交还抢到播放键',
      );
      // 该次返回也应原样落到弹层的路由上（由 dpad / Navigator 关闭弹层），
      // 页面级拦截器不得把它算作自己的「交还」而吞掉。
      expect(backCount, 1, reason: '弹层内的返回键应放行给 dpad 关闭弹层');
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  // 2026-10-20 真机（SM-T870）补的一组：真机上返回键的实际收口点是
  // `PopScope.onPopInvokedWithResult`，**不是** dpad 的 onBack、也常常不是
  // 页内拦截器（焦点丢失到路由 FocusScope 时拦不到）。这组用例钉住
  // `tvPlayerTryFocusPlay` 这个共用判据与该收口点的组合行为。
  // ─────────────────────────────────────────────────────────────────────
  group('真机收口点（PopScope 路径）', () {
    /// 复刻播放页的返回键收口：先咨询交还判据，再决定是否「收起」。
    Widget backPage({
      required List<FocusNode> playNodes,
      required VoidCallback onCollapse,
      required Widget body,
    }) {
      return MaterialApp(
        builder: Dpad.wrap(),
        home: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (tvPlayerTryFocusPlay()) return;
            onCollapse();
          },
          child: Scaffold(body: body),
        ),
      );
    }

    testWidgets('焦点在内容区：收口判据交还焦点、不收起播放页', (tester) async {
      final play = _registerProbePlayNode('pop_play');
      var collapsed = 0;

      await tester.pumpWidget(
        backPage(
          playNodes: [play],
          onCollapse: () => collapsed++,
          body: Row(
            children: [
              Expanded(
                child: TvPlayerChromeScope(
                  child: DpadFocusable(
                    focusNode: play,
                    child: const SizedBox(key: Key('play'), height: 400),
                  ),
                ),
              ),
              Expanded(
                child: TvPlayerTabContentScope(
                  child: DpadFocusable(
                    key: const Key('row'),
                    autofocus: true,
                    child: const SizedBox(height: 400),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pump();

      // 直接调用真机 `PopScope.onPopInvokedWithResult` 里用的那条判据
      //（`escape` 键本身不会触发 PopScope 回调——那由 Navigator 的 pop 流程
      // 驱动，框架侧语义，不是本改动能控制的）。
      final bool consumed = tvPlayerTryFocusPlay();
      if (!consumed) collapsed++;
      await tester.pump();

      expect(consumed, isTrue, reason: '内容区焦点应收口交还播放键');
      expect(play.hasFocus, isTrue, reason: '焦点应落到播放键');
      expect(collapsed, 0, reason: '第一次返回不得收起播放页');
    });

    testWidgets('焦点已在控制 chrome 区：收口判据放行、收起播放页', (tester) async {
      final play = _registerProbePlayNode('pop_play2');
      var collapsed = 0;

      await tester.pumpWidget(
        backPage(
          playNodes: [play],
          onCollapse: () => collapsed++,
          body: TvPlayerChromeScope(
            child: DpadFocusable(
              focusNode: play,
              autofocus: true,
              child: const SizedBox(key: Key('play'), height: 400),
            ),
          ),
        ),
      );
      await tester.pump();

      final bool consumed = tvPlayerTryFocusPlay();
      if (!consumed) collapsed++;
      await tester.pump();

      expect(consumed, isFalse, reason: '焦点已在控制区时判据应放行');
      expect(collapsed, 1, reason: '焦点已在控制区时返回键应放行收起播放页');
    });

    testWidgets('全局兜底：焦点丢到路由 FocusScope 时仍能交还播放键', (tester) async {
      final play = _registerProbePlayNode('pop_play3');
      var handled = 0;

      // 播放页把「兜底处理器」注册进 TvPlayerBackFallback，模拟
      // full_player*.dart 在 initState 里的接线。
      bool handler() {
        if (tvPlayerTryFocusPlay()) {
          handled++;
          return true;
        }
        return false;
      }

      TvPlayerBackFallback.instance.register(handler);
      addTearDown(() => TvPlayerBackFallback.instance.unregister(handler));

      await tester.pumpWidget(
        MaterialApp(
          builder: Dpad.wrap(),
          home: Row(
            children: [
              Expanded(
                child: TvPlayerChromeScope(
                  child: DpadFocusable(
                    focusNode: play,
                    child: const SizedBox(key: Key('play'), height: 400),
                  ),
                ),
              ),
              Expanded(
                child: DpadFocusable(
                  key: const Key('row'),
                  autofocus: true,
                  child: const SizedBox(height: 400),
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pump();

      // 模拟真机上「焦点丢失到路由 FocusScope」的状态。
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus is FocusScopeNode,
        isTrue,
        reason: '前提：焦点丢到 Scope 上',
      );

      // 此时页内拦截器不是该 Scope 的后代、收不到按键；只能靠全局兜底。
      expect(
        TvPlayerBackFallback.instance.requestPlayFocus(),
        isTrue,
        reason: '兜底处理器应接手并交还焦点',
      );
      await tester.pump();
      expect(play.hasFocus, isTrue, reason: '焦点应落到播放键');
      expect(handled, 1);
    });

    testWidgets('全局兜底：没有播放页注册时返回 false（主壳层行为不变）', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox.expand()));
      expect(
        TvPlayerBackFallback.instance.requestPlayFocus(),
        isFalse,
        reason: '无播放页时兜底必须放行，不能吞掉主壳层的返回键',
      );
    });
  });
}
