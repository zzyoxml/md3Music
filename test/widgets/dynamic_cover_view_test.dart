import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/dynamic_cover_view.dart';

void main() {
  // 回归背景：暂停状态下息屏再解锁，ExoPlayer 的渲染表面已失效而暂停的视频不会
  // 渲染新帧 → 留下黑屏盖住静态封面（表现为「没有兜底」）。策略是真正进入后台时
  // 释放视频层，回前台重建；这两条用例把策略钉住。
  group('shouldReleaseVideoOnLifecycle', () {
    test('真正进入后台 → 必须释放视频层', () {
      expect(shouldReleaseVideoOnLifecycle(AppLifecycleState.paused), isTrue);
      expect(shouldReleaseVideoOnLifecycle(AppLifecycleState.hidden), isTrue);
      expect(shouldReleaseVideoOnLifecycle(AppLifecycleState.detached), isTrue);
    });

    test('前台与临时失焦（下拉通知栏 / 权限弹窗）→ 不释放，避免反复重建闪烁', () {
      expect(shouldReleaseVideoOnLifecycle(AppLifecycleState.resumed), isFalse);
      expect(shouldReleaseVideoOnLifecycle(AppLifecycleState.inactive), isFalse);
    });
  });
}
