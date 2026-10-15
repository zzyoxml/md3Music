import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/controllers/line_scale_controller.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_layout.dart';

/// LineScaleController 单元测试
///
/// 覆盖 spec.md "Requirement: 行缩放动画" 与 tasks.md Task 12 的全部子任务：
/// 1. 初始状态
/// 2. isActive=true 收敛到 1.0
/// 3. isActive=false 收敛到 0.97
/// 4. 背景行非活跃收敛到 0.75
/// 5. 背景行活跃收敛到 1.0
/// 6. enableScale=false 强制 1.0
/// 7. 对唱行 scaleOrigin 为 centerRight
/// 8. 非对唱行 scaleOrigin 为 centerLeft
/// 9. 行切换弹簧过渡
/// 10. isAnimating 运动中 true，稳定后 false
/// 11. tick 稳定后返回 false
/// 12. reset 后 scale=1.0
void main() {
  group('LineScaleController', () {
    test('1. 初始状态：currentScale = 1.0，isAnimating = false', () {
      final controller = LineScaleController();
      expect(controller.currentScale, equals(LyricLayout.activeScale));
      expect(controller.isAnimating, isFalse);
    });

    test('2. setLineState(isActive=true) 后 scale 收敛到 1.0', () {
      final controller = LineScaleController();
      controller.setLineState(isActive: true);

      // target 已为 1.0，与初始位置相同，应直接稳定
      expect(controller.currentScale, equals(LyricLayout.activeScale));

      // 多次 tick 后仍为 1.0
      for (int i = 0; i < 100; i++) {
        controller.tick(0.016);
      }
      expect(controller.currentScale, closeTo(1.0, 1e-3));
      expect(controller.isAnimating, isFalse);
    });

    test('3. setLineState(isActive=false) 后 scale 收敛到 0.97', () {
      final controller = LineScaleController();
      controller.setLineState(isActive: false);

      // 设定后应处于运动中
      expect(controller.isAnimating, isTrue);

      // 模拟 5 秒（每步 16ms），应收敛到 0.97
      for (int i = 0; i < 300; i++) {
        controller.tick(0.016);
      }
      expect(controller.currentScale, closeTo(LyricLayout.inactiveScale, 1e-3));
      expect(controller.isAnimating, isFalse);
    });

    test('4. 背景行 setLineState(isActive=false, isBackground=true) 收敛到 0.75',
        () {
      final controller = LineScaleController();
      controller.setLineState(isActive: false, isBackground: true);

      expect(controller.isAnimating, isTrue);

      for (int i = 0; i < 300; i++) {
        controller.tick(0.016);
      }
      expect(
        controller.currentScale,
        closeTo(LyricLayout.backgroundInactiveScale, 1e-3),
      );
      expect(controller.isAnimating, isFalse);
    });

    test('5. 背景行 setLineState(isActive=true, isBackground=true) 收敛到 1.0', () {
      final controller = LineScaleController();
      controller.setLineState(isActive: true, isBackground: true);

      // target=1.0 与初始位置相同，应稳定
      expect(controller.currentScale, equals(LyricLayout.backgroundActiveScale));

      for (int i = 0; i < 100; i++) {
        controller.tick(0.016);
      }
      expect(controller.currentScale, closeTo(1.0, 1e-3));
      expect(controller.isAnimating, isFalse);
    });

    test('6. enableScale=false：无论 isActive 如何 target=1.0', () {
      final controller = LineScaleController();

      // 先将 scale 弹到 0.97（非活跃主行）
      controller.setLineState(isActive: false);
      for (int i = 0; i < 300; i++) {
        controller.tick(0.016);
      }
      expect(controller.currentScale, closeTo(LyricLayout.inactiveScale, 1e-3));

      // 关闭缩放：即使 isActive=false，也应回到 1.0
      controller.setLineState(isActive: false, enableScale: false);
      expect(controller.isAnimating, isTrue);

      for (int i = 0; i < 300; i++) {
        controller.tick(0.016);
      }
      expect(controller.currentScale, closeTo(1.0, 1e-3));
      expect(controller.isAnimating, isFalse);
    });

    test('7. 对唱行 scaleOrigin 返回 Alignment.centerRight', () {
      final controller = LineScaleController();
      controller.setLineState(isActive: true, isDuet: true);
      expect(controller.scaleOrigin, equals(Alignment.centerRight));
    });

    test('8. 非对唱行 scaleOrigin 返回 Alignment.centerLeft', () {
      final controller = LineScaleController();
      controller.setLineState(isActive: true, isDuet: false);
      expect(controller.scaleOrigin, equals(Alignment.centerLeft));
    });

    test('9. 行切换：从 isActive=true 切到 isActive=false，scale 从 1.0 过渡到 0.97',
        () {
      final controller = LineScaleController();

      // 先设为活跃（已在 1.0）
      controller.setLineState(isActive: true);
      expect(controller.currentScale, equals(1.0));

      // 切换为非活跃
      controller.setLineState(isActive: false);
      expect(controller.isAnimating, isTrue);

      // 推进少量步数，scale 应在 (0.97, 1.0) 之间，尚未到达 0.97
      for (int i = 0; i < 10; i++) {
        controller.tick(0.016);
      }
      expect(controller.currentScale, lessThan(1.0));
      expect(controller.currentScale, greaterThan(LyricLayout.inactiveScale));

      // 继续推进至收敛
      for (int i = 0; i < 290; i++) {
        controller.tick(0.016);
      }
      expect(controller.currentScale, closeTo(LyricLayout.inactiveScale, 1e-3));
      expect(controller.isAnimating, isFalse);
    });

    test('10. isAnimating：运动中 true，稳定后 false', () {
      final controller = LineScaleController();

      // 触发运动
      controller.setLineState(isActive: false);
      expect(controller.isAnimating, isTrue);

      // 运动中
      controller.tick(0.016);
      expect(controller.isAnimating, isTrue);

      // 推进至稳定
      for (int i = 0; i < 300; i++) {
        controller.tick(0.016);
      }
      expect(controller.isAnimating, isFalse);
    });

    test('11. tick 在稳定后返回 false', () {
      final controller = LineScaleController();
      controller.setLineState(isActive: false);

      // 推进至稳定
      for (int i = 0; i < 300; i++) {
        controller.tick(0.016);
      }

      // 稳定后 tick 应返回 false
      final needsRepaint = controller.tick(0.016);
      expect(needsRepaint, isFalse);
    });

    test('12. reset() 后 scale=1.0', () {
      final controller = LineScaleController();

      // 先弹到 0.97
      controller.setLineState(isActive: false);
      for (int i = 0; i < 300; i++) {
        controller.tick(0.016);
      }
      expect(controller.currentScale, closeTo(LyricLayout.inactiveScale, 1e-3));

      // reset 后回到 1.0 且稳定
      controller.reset();
      expect(controller.currentScale, equals(LyricLayout.activeScale));
      expect(controller.isAnimating, isFalse);
    });
  });
}
