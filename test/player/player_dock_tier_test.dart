// 常驻控制带分档判据的单测（计划 §2.3）。
//
// 这是 dock 唯一的形态开关，阈值判错不会崩溃、只会静默变成另一种布局，
// 所以钉成单测。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/player_dock/player_control_dock.dart';

void main() {
  PlayerDockTier tier({required double w, required double h}) =>
      resolvePlayerDockTier(paneWidth: w, paneHeight: h);

  group('resolvePlayerDockTier', () {
    test('平板横屏 / 折叠展开 → comfortable（尺+传输两行）', () {
      // 1280×800 的右栏：6:4 分栏 → 尺 768 宽
      expect(tier(w: 768, h: 744), PlayerDockTier.comfortable);
    });

    test('手机横屏 → standard（尺+传输两行）', () {
      // 800×360 的右栏
      expect(tier(w: 480, h: 304), PlayerDockTier.standard);
    });

    test('pane 窄于 400 → compact（尺与传输挤同一行，不缩传输按钮）', () {
      // 计划 R2：绝不为了塞内容而缩按钮；这一档把尺与传输并到同一条水平带。
      expect(tier(w: 384, h: 240), PlayerDockTier.compact);
    });

    test('可用高不足 236（极窄横屏 / 大字号）→ compact', () {
      expect(tier(w: 768, h: 235), PlayerDockTier.compact);
      expect(tier(w: 480, h: 236), PlayerDockTier.standard);
    });

    test('车机面板恒 compact，沿用既有窄屏语义', () {
      for (final size in <(double, double)>[(1400, 900), (768, 744)]) {
        expect(
          resolvePlayerDockTier(
            paneWidth: size.$1,
            paneHeight: size.$2,
            dockMode: true,
          ),
          PlayerDockTier.compact,
        );
      }
    });
  });

  test('detached 档不参与分档：它是「控制 = 一页」的既有形态', () {
    // resolve 永远不会返回 detached —— 它由用户开关决定，不由尺寸决定
    expect(
      resolvePlayerDockTier(paneWidth: 768, paneHeight: 744),
      isNot(PlayerDockTier.detached),
    );
    expect(
      resolvePlayerDockTier(paneWidth: 100, paneHeight: 100),
      isNot(PlayerDockTier.detached),
    );
  });
}
