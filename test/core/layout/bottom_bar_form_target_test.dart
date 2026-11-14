import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/layout/responsive_layout.dart';

/// 底栏形态目标 [resolveBottomBarFormTarget] 的三种输入组合（W5 纯函数）。
///
/// 判据来源：`secondary_mini_player.dart` 的 `_buildHost` / `_buildBottomBarFallback`
/// 分支 —— 只有「悬浮总开关开 + 一级页面退回常驻条 + 当前是一级导航页」这一组
/// 才落在常驻条（0）上，其余都落在悬浮胶囊（1）。
void main() {
  group('resolveBottomBarFormTarget', () {
    test('总开关关闭：两种页面都退回常驻条（0）', () {
      for (final onPrimary in [true, false]) {
        for (final primaryNav in [true, false]) {
          expect(
            resolveBottomBarFormTarget(
              floatingEnabled: false,
              onPrimaryPages: onPrimary,
              pageIsPrimaryNav: primaryNav,
            ),
            0.0,
            reason: 'floatingEnabled=false 时恒为 0（onPrimary=$onPrimary '
                'primaryNav=$primaryNav）',
          );
        }
      }
    });

    test('开启 + 一级页面退回常驻条：一级导航页 = 常驻条（0）', () {
      expect(
        resolveBottomBarFormTarget(
          floatingEnabled: true,
          onPrimaryPages: false,
          pageIsPrimaryNav: true,
        ),
        0.0,
      );
    });

    test('开启 + 一级页面退回常驻条：二级页面 / 标题居中 tab = 胶囊（1）', () {
      expect(
        resolveBottomBarFormTarget(
          floatingEnabled: true,
          onPrimaryPages: false,
          pageIsPrimaryNav: false,
        ),
        1.0,
      );
    });

    test('开启 + 一级页面也用悬浮条：一级导航页同样是胶囊（1）', () {
      expect(
        resolveBottomBarFormTarget(
          floatingEnabled: true,
          onPrimaryPages: true,
          pageIsPrimaryNav: true,
        ),
        1.0,
      );
      expect(
        resolveBottomBarFormTarget(
          floatingEnabled: true,
          onPrimaryPages: true,
          pageIsPrimaryNav: false,
        ),
        1.0,
      );
    });
  });

  test('kBottomBarFormProgress 默认落在常驻条端点（0）', () {
    expect(kBottomBarFormProgress.value, 0.0);
  });
}
