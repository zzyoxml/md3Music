/// TvFocusHighlight 的停帧约定（AGENTS.md §10.4.6：画面静止必须停帧）。
///
/// 旧的「Ticker 常驻 + 每帧 setState」会让 TV 包在任何静止画面上持续产帧，
/// 120Hz 盒子上整页被顶满。本用例以 `hasScheduledFrame` 为观测点：
/// 焦点不动时不得再排帧；焦点变化后必须重新进入逐帧跟随。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/remote/tv_focus_highlight.dart';

void main() {
  testWidgets('焦点静止时停帧，焦点变化后恢复跟随', (tester) async {
    final first = FocusNode();
    final second = FocusNode();
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Focus(
                    focusNode: first,
                    autofocus: true,
                    child: const SizedBox(width: 40, height: 40),
                  ),
                  Focus(
                    focusNode: second,
                    child: const SizedBox(width: 40, height: 40),
                  ),
                ],
              ),
            ),
            const Positioned.fill(child: TvFocusHighlight()),
          ],
        ),
      ),
    );

    // 跟随若干拍后（静止判定阈值 10 拍）应静音 Ticker。
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      tester.binding.hasScheduledFrame,
      isFalse,
      reason: '焦点矩形静止后不得继续产帧（§10.4.6）',
    );

    // 焦点变化 → 唤醒，必须重新逐帧跟随。
    second.requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      tester.binding.hasScheduledFrame,
      isTrue,
      reason: '焦点变化后必须重新跟随（否则焦点框会停在旧位置）',
    );
  });
}
