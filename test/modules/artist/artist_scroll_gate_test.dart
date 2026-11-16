import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/artist/artist_scroll_gate.dart';

void main() {
  const bannerH = 330.0; // 260~430 之间的典型值；kToolbarHeight 56
  const fadeTop = bannerH - 56.0 - 60.0; // 214：appBar 淡入窗口起点
  const titleTop = bannerH - 56.0; // 274：标题淡入窗口起点

  test('首次滚动允许重建', () {
    final gate = ArtistScrollGate();
    expect(gate.shouldRebuild(1.0, bannerHeight: bannerH), isTrue);
  });

  test('淡入窗口内按步长放行，不再 1px 一放行', () {
    final gate = ArtistScrollGate();
    var allowed = 0;
    for (var o = fadeTop; o <= titleTop + 60; o += 1.0) {
      if (gate.shouldRebuild(o, bannerHeight: bannerH)) allowed++;
    }
    // 121 个采样点：旧阈值（>1px）会全部放行 121 次。
    // 新闸门 = fade 60px/2px 档（30 次）+ title 60px/12px 档（5 次）+ 可见性翻转（1 次）≈ 36 次。
    expect(allowed, lessThanOrEqualTo(60), reason: '淡入区应量化放行');
    expect(allowed, greaterThanOrEqualTo(20), reason: '淡入效果必须保留，不能变成不重建');
  });

  test('越过淡入窗口后连续滚动零重建（核心回归）', () {
    final gate = ArtistScrollGate();
    gate.shouldRebuild(bannerH + 100, bannerHeight: bannerH);
    var allowed = 0;
    for (var o = bannerH + 120.0; o < 40000.0; o += 25.0) {
      if (gate.shouldRebuild(o, bannerHeight: bannerH)) allowed++;
    }
    expect(allowed, 0, reason: '淡入已饱和、banner 已出屏，滚动不该再重建整页');
  });

  test('回到淡入窗口内重新放行', () {
    final gate = ArtistScrollGate();
    gate.shouldRebuild(4000.0, bannerHeight: bannerH);
    expect(gate.shouldRebuild(fadeTop + 10, bannerHeight: bannerH), isTrue);
  });

  test('bannerHeight 变化（旋转/尺寸改变）时重新评估', () {
    final gate = ArtistScrollGate();
    gate.shouldRebuild(500.0, bannerHeight: 330.0);
    expect(gate.shouldRebuild(500.0, bannerHeight: 420.0), isTrue);
  });
}
