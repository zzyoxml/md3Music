import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show DeviceGestureSettings;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/layout/ui_density.dart';

/// 「显示大小」全局缩放（[applyDisplayScale] / [DisplayScaleScope]）单测。
///
/// 核心不变量：`size × devicePixelRatio` 恒等于真实物理像素 —— 页面里
/// "宽 × dpr = 解码宽度" 那类算法靠它保持正确。
void main() {
  const base = MediaQueryData(
    size: Size(800, 600),
    devicePixelRatio: 2.0,
    padding: EdgeInsets.only(top: 24, bottom: 16),
    viewPadding: EdgeInsets.only(top: 24, bottom: 16),
    viewInsets: EdgeInsets.only(bottom: 300),
    systemGestureInsets: EdgeInsets.only(left: 20, right: 20),
    gestureSettings: DeviceGestureSettings(touchSlop: 18),
  );

  group('applyDisplayScale', () {
    test('1.0 档原样返回，不产生新对象', () {
      expect(applyDisplayScale(base, kDefaultDisplayScale), same(base));
    });

    test('逻辑尺寸 ÷ s、密度 × s，物理像素守恒', () {
      final scaled = applyDisplayScale(base, 1.25);
      expect(scaled.size, const Size(640, 480));
      expect(scaled.devicePixelRatio, 2.5);
      // 物理像素守恒：640 × 2.5 == 800 × 2.0
      expect(
        scaled.size.width * scaled.devicePixelRatio,
        base.size.width * base.devicePixelRatio,
      );
      expect(
        scaled.size.height * scaled.devicePixelRatio,
        base.size.height * base.devicePixelRatio,
      );
    });

    test('缩小档同样守恒', () {
      final scaled = applyDisplayScale(base, 0.85);
      expect(scaled.size.width, closeTo(941.18, 0.01));
      expect(scaled.devicePixelRatio, closeTo(1.7, 0.0001));
      expect(
        scaled.size.width * scaled.devicePixelRatio,
        closeTo(base.size.width * base.devicePixelRatio, 0.0001),
      );
    });

    test('安全区 / 键盘 / 手势 inset 全部 ÷ s（留出的物理区域不变）', () {
      final scaled = applyDisplayScale(base, 1.25);
      expect(scaled.padding, const EdgeInsets.only(top: 19.2, bottom: 12.8));
      expect(scaled.viewPadding, const EdgeInsets.only(top: 19.2, bottom: 12.8));
      expect(scaled.viewInsets, const EdgeInsets.only(bottom: 240));
      expect(
        scaled.systemGestureInsets,
        const EdgeInsets.only(left: 16, right: 16),
      );
      // 物理留白守恒：19.2 × 2.5 == 24 × 2.0
      expect(
        scaled.padding.top * scaled.devicePixelRatio,
        base.padding.top * base.devicePixelRatio,
      );
    });

    test('touchSlop 刻意不缩放（dp 语义，与原生一致）', () {
      final scaled = applyDisplayScale(base, 1.25);
      expect(scaled.gestureSettings.touchSlop, 18);
    });

    test('折叠屏铰链区（displayFeatures）按 s 换算', () {
      final withHinge = base.copyWith(
        displayFeatures: const [
          ui.DisplayFeature(
            bounds: Rect.fromLTRB(390, 0, 410, 600),
            type: ui.DisplayFeatureType.hinge,
            state: ui.DisplayFeatureState.postureFlat,
          ),
        ],
      );
      final scaled = applyDisplayScale(withHinge, 1.25);
      expect(
        scaled.displayFeatures.single.bounds,
        const Rect.fromLTRB(312, 0, 328, 480),
      );
      expect(scaled.displayFeatures.single.type, ui.DisplayFeatureType.hinge);
    });
  });

  group('DisplayScaleScope', () {
    /// 探针：把它拿到的 MediaQueryData 抛给外部断言。
    Widget probe(void Function(MediaQueryData) onBuild, {Widget? child}) {
      return Builder(
        builder: (context) {
          onBuild(MediaQuery.of(context));
          return child ?? const SizedBox.shrink();
        },
      );
    }

    testWidgets('子树拿到设计像素坐标系，物理像素守恒', (tester) async {
      MediaQueryData? seen;
      await tester.pumpWidget(
        MediaQuery(
          data: base,
          child: DisplayScaleScope(
            scale: 1.25,
            child: probe((mq) => seen = mq),
          ),
        ),
      );
      expect(seen!.size, const Size(640, 480));
      expect(seen!.devicePixelRatio, 2.5);
      expect(seen!.padding.top, 19.2);
    });

    testWidgets('绘制与命中测试按 s 变换：100dp 方块占 125 物理逻辑像素', (tester) async {
      final key = GlobalKey();
      var tapped = false;
      await tester.pumpWidget(
        MediaQuery(
          data: base,
          child: DisplayScaleScope(
            scale: 1.25,
            child: Align(
              alignment: Alignment.topLeft,
              child: GestureDetector(
                key: key,
                onTap: () => tapped = true,
                child: Container(width: 100, height: 100, color: Colors.red),
              ),
            ),
          ),
        ),
      );
      // 自身尺寸仍是 100 设计像素
      expect(tester.getSize(find.byKey(key)), const Size(100, 100));
      // 映射到屏幕后占 125×125
      expect(tester.getRect(find.byKey(key)), const Rect.fromLTRB(0, 0, 125, 125));
      // (120,120) 在放大后的方块内、在未放大的 100×100 之外 → 变换生效才能命中
      await tester.tapAt(const Offset(120, 120));
      await tester.pump();
      expect(tapped, isTrue);
    });

    testWidgets('1.0 档不改坐标系，但元素树结构与其他档位一致', (tester) async {
      MediaQueryData? seen;
      await tester.pumpWidget(
        MediaQuery(
          data: base,
          child: DisplayScaleScope(
            scale: kDefaultDisplayScale,
            child: probe((mq) => seen = mq),
          ),
        ),
      );
      expect(seen!.size, const Size(800, 600));
      expect(seen!.devicePixelRatio, 2.0);
      // FittedBox / SizedBox 恒在：跨过 1.00 档时元素树不变，Navigator 不会重建
      expect(find.byType(FittedBox), findsOneWidget);
    });

    testWidgets('系统字号只压上限：<1.0 抬到 1.0，>1.3 压到 1.3', (tester) async {
      Future<double> effectiveScale(TextScaler system) async {
        MediaQueryData? seen;
        await tester.pumpWidget(
          MediaQuery(
            data: base.copyWith(textScaler: system),
            child: DisplayScaleScope(
              scale: kDefaultDisplayScale,
              child: probe((mq) => seen = mq),
            ),
          ),
        );
        return seen!.textScaler.scale(20) / 20;
      }

      expect(await effectiveScale(const TextScaler.linear(0.85)), 1.0);
      expect(await effectiveScale(TextScaler.noScaling), 1.0);
      expect(await effectiveScale(const TextScaler.linear(1.15)), 1.15);
      expect(
        await effectiveScale(const TextScaler.linear(2.0)),
        kMaxSystemTextScale,
      );
    });
  });
}
