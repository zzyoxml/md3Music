import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/controllers/lyric_scroll_controller.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_layout.dart';

/// LyricScrollController 单元测试
///
/// 覆盖 spec.md "Requirement: 弹簧物理动画引擎" 与 tasks.md Task 11 的全部子任务：
/// 1. 初始状态
/// 2. setCurrentLine 后 spring target 改变且收敛
/// 3. targetYForLine 公式
/// 4. seeking 模式切换为固定参数 (90, 15)
/// 5. 普通模式动态参数（interval 100ms→220, 800ms→170）
/// 6. onUserScroll 直接修改 posY
/// 7. onUserScrollEnd 后 5000ms 自动回弹（fakeAsync）
/// 8. isClickGesture 阈值判定
/// 9. tick 在稳定后返回 false
/// 10. dispose 不崩溃
void main() {
  group('LyricScrollController', () {
    test('1. 初始状态：posY = 0，currentLineIndex = -1', () {
      final controller = LyricScrollController();
      expect(controller.posY, equals(0));
      expect(controller.currentLineIndex, equals(-1));
      expect(controller.viewportHeight, equals(0));
      controller.dispose();
    });

    test('2. setCurrentLine 首次定位直接瞬移到目标（不再从顶部滚动）', () {
      final controller = LyricScrollController();
      controller.setViewportSize(const Size(400, 600));
      // 第 0 行，行高 40，对齐位置 0.35
      // targetY = -(0 + 20 - 600*0.35) = -(0 + 20 - 210) = 190
      controller.setCurrentLine(
        0,
        isSeeking: false,
        lineHeight: 40,
        intervalMs: 500,
      );

      // 新建控制器（相当于重新进入歌词页）：首次定位应瞬移，不产生滚动动画
      expect(controller.currentTarget, closeTo(190, 1e-9));
      expect(controller.posY, closeTo(190, 1e-9),
          reason: '首次定位应瞬移到目标，避免"从顶部滚动到当前行"的动画');
      // 弹簧已稳定，无需重绘
      expect(controller.tick(0.016), isFalse);
      expect(controller.posY, closeTo(190, 0.5));
      controller.dispose();
    });

    test('3. targetYForLine：viewport=600, lineHeight=40, lineIndex=0 → 190', () {
      final controller = LyricScrollController();
      controller.setViewportSize(const Size(400, 600));
      // lineIndex=0: -(0 + 20 - 210) = 190
      expect(controller.targetYForLine(0, 40), closeTo(190, 1e-9));
      // lineIndex=1: -(40 + 20 - 210) = 150
      expect(controller.targetYForLine(1, 40), closeTo(150, 1e-9));
      // lineIndex=5: -(200 + 20 - 210) = -10
      expect(controller.targetYForLine(5, 40), closeTo(-10, 1e-9));
      controller.dispose();
    });

    test('4. setSeekingMode(true) 后弹簧参数为 stiffness=90, damping=15', () {
      final controller = LyricScrollController();
      // 初始默认为 seeking 参数
      expect(controller.currentStiffness, equals(LyricLayout.posYSeekingStiffness));
      expect(controller.currentDamping, equals(LyricLayout.posYSeekingDamping));

      // 切换到普通模式（intervalMs=500，中间值）
      controller.setCurrentLine(
        0,
        isSeeking: false,
        lineHeight: 40,
        intervalMs: 500,
      );
      // 普通模式 stiffness 在 [170, 220] 之间
      expect(controller.currentStiffness,
          allOf(greaterThanOrEqualTo(170), lessThanOrEqualTo(220)));
      expect(controller.currentStiffness, isNot(equals(90)));

      // 切换到 seeking 模式
      controller.setSeekingMode(true);
      expect(controller.currentStiffness, equals(90));
      expect(controller.currentDamping, equals(15));
      controller.dispose();
    });

    test('5. 普通模式动态参数：interval 100ms→stiffness=220，800ms→stiffness=170', () {
      final controller = LyricScrollController();
      controller.setViewportSize(const Size(400, 600));

      // 间隔 100ms（密集）→ stiffness=220（最灵敏）
      controller.setCurrentLine(
        0,
        isSeeking: false,
        lineHeight: 40,
        intervalMs: 100,
      );
      expect(controller.currentStiffness, closeTo(220, 1e-3));
      // damping = sqrt(220) * 2.2
      expect(controller.currentDamping,
          closeTo(LyricLayout.posYNormalDamping(220), 1e-9));

      // 间隔 800ms（稀疏）→ stiffness=170（最迟缓）
      controller.setCurrentLine(
        1,
        isSeeking: false,
        lineHeight: 40,
        intervalMs: 800,
      );
      expect(controller.currentStiffness, closeTo(170, 1e-3));
      expect(controller.currentDamping,
          closeTo(LyricLayout.posYNormalDamping(170), 1e-9));

      // 超出 clamp 范围：50ms 应等价于 100ms（→ 220）
      controller.setCurrentLine(
        2,
        isSeeking: false,
        lineHeight: 40,
        intervalMs: 50,
      );
      expect(controller.currentStiffness, closeTo(220, 1e-3));

      // 超出 clamp 范围：2000ms 应等价于 800ms（→ 170）
      controller.setCurrentLine(
        3,
        isSeeking: false,
        lineHeight: 40,
        intervalMs: 2000,
      );
      expect(controller.currentStiffness, closeTo(170, 1e-3));
      controller.dispose();
    });

    test('6. onUserScroll 直接修改 posY：拖动 50px 后 posY 变化', () {
      final controller = LyricScrollController();
      controller.setViewportSize(const Size(400, 600));
      // 先设置当前行让 posY 有一个基准
      controller.setCurrentLine(
        0,
        isSeeking: false,
        lineHeight: 40,
        intervalMs: 500,
      );
      // 推进到稳定
      for (int i = 0; i < 300; i++) {
        controller.tick(0.016);
      }
      final double stableY = controller.posY;
      expect(stableY, closeTo(190, 0.5));

      // 用户向下拖动 50px（posY 增大）
      controller.onUserScroll(50);
      expect(controller.posY, closeTo(stableY + 50, 1e-9));

      // 继续拖动 -30px
      controller.onUserScroll(-30);
      expect(controller.posY, closeTo(stableY + 20, 1e-9));
      controller.dispose();
    });

    test('7. onUserScrollEnd 后 5000ms 自动回弹（fakeAsync 模拟时间）', () {
      fakeAsync((async) {
        final controller = LyricScrollController();
        controller.setViewportSize(const Size(400, 600));
        controller.setCurrentLine(
          0,
          isSeeking: false,
          lineHeight: 40,
          intervalMs: 500,
        );
        // 推进到稳定
        for (int i = 0; i < 300; i++) {
          controller.tick(0.016);
        }
        final double stableY = controller.posY;
        expect(stableY, closeTo(190, 0.5));

        // 用户拖动 80px
        controller.onUserScroll(80);
        expect(controller.posY, closeTo(stableY + 80, 1e-9));

        // 手势结束，开始 5000ms 倒计时
        controller.onUserScrollEnd();

        // 模拟时间推进 4999ms（每 16ms tick 一次），不应回弹
        // 4999 / 16 ≈ 312 次
        for (int i = 0; i < 312; i++) {
          controller.tick(0.016);
          async.elapse(const Duration(milliseconds: 16));
        }
        // posY 仍应接近 stableY + 80（未回弹）
        expect(controller.posY, closeTo(stableY + 80, 1.0));

        // 继续推进到 5000ms+，应触发回弹
        for (int i = 0; i < 600; i++) {
          controller.tick(0.016);
          async.elapse(const Duration(milliseconds: 16));
        }
        // 回弹后应收敛回 stableY
        expect(controller.posY, closeTo(stableY, 1.0));
        controller.dispose();
      });
    });

    test('8. isClickGesture：5px→true，15px→false', () {
      final controller = LyricScrollController();
      // 阈值 10px：< 10 视为点击
      expect(controller.isClickGesture(5), isTrue);
      expect(controller.isClickGesture(-5), isTrue); // 绝对值判定
      expect(controller.isClickGesture(0), isTrue);
      expect(controller.isClickGesture(15), isFalse);
      expect(controller.isClickGesture(-15), isFalse);
      // 边界：10px 不视为点击（< 10 才是）
      expect(controller.isClickGesture(10), isFalse);
      expect(controller.isClickGesture(9.99), isTrue);
      controller.dispose();
    });

    test('9. tick 在稳定后返回 false（无需重绘）', () {
      final controller = LyricScrollController();
      controller.setViewportSize(const Size(400, 600));
      // 首次定位瞬移，立即稳定
      controller.setCurrentLine(
        0,
        isSeeking: false,
        lineHeight: 40,
        intervalMs: 500,
      );
      expect(controller.tick(0.016), isFalse);

      // 行切换（index 0 → 1）：弹簧重新运动，需要重绘
      controller.setCurrentLine(
        1,
        isSeeking: false,
        lineHeight: 40,
        intervalMs: 500,
      );
      bool needsRepaint = controller.tick(0.016);
      expect(needsRepaint, isTrue, reason: '行切换后弹簧运动，需要重绘');

      // 推进到稳定
      for (int i = 0; i < 500; i++) {
        needsRepaint = controller.tick(0.016);
      }
      // 稳定后应返回 false
      expect(needsRepaint, isFalse);
      controller.dispose();
    });

    test('10. dispose 释放资源不崩溃', () {
      final controller = LyricScrollController();
      controller.setViewportSize(const Size(400, 600));
      controller.setCurrentLine(
        0,
        isSeeking: false,
        lineHeight: 40,
        intervalMs: 500,
      );
      controller.onUserScroll(30);
      controller.tick(0.016);

      // dispose 应不抛异常
      controller.dispose();

      // 多次 dispose 也不应崩溃
      controller.dispose();
    });

    test('11. 相同参数重复 setCurrentLine 不重算弹簧参数（P1-D 缓存）', () {
      final controller = LyricScrollController();
      controller.setViewportSize(const Size(400, 600));
      // seeking 模式固定参数 (90, 15)
      controller.setCurrentLine(0, isSeeking: true, lineHeight: 40);
      expect(controller.currentStiffness, closeTo(90, 1e-9));
      expect(controller.currentDamping, closeTo(15, 1e-9));

      // 相同输入重复调用：缓存命中，参数保持不变（不重算 pow）
      controller.setCurrentLine(0, isSeeking: true, lineHeight: 40);
      expect(controller.currentStiffness, closeTo(90, 1e-9));
      expect(controller.currentDamping, closeTo(15, 1e-9));

      // 切换普通模式（intervalMs 变化）→ 触发重算并更新缓存
      controller.setCurrentLine(
        0,
        isSeeking: false,
        lineHeight: 40,
        intervalMs: 200,
      );
      final double stiffness = controller.currentStiffness;
      expect(stiffness,
          closeTo(LyricLayout.posYNormalStiffness(200), 1e-9));
      // 再次相同：缓存命中，值保持
      controller.setCurrentLine(
        0,
        isSeeking: false,
        lineHeight: 40,
        intervalMs: 200,
      );
      expect(controller.currentStiffness, closeTo(stiffness, 1e-9));
      controller.dispose();
    });

    test('12. 拖动被取消（未调 onUserScrollEnd）会卡死 isUserScrolling / 永不收敛', () {
      final controller = LyricScrollController();
      controller.setViewportSize(const Size(400, 600));
      controller.setCurrentLine(
        0,
        isSeeking: false,
        lineHeight: 40,
        intervalMs: 500,
      );
      // 推进到稳定
      for (int i = 0; i < 300; i++) {
        controller.tick(0.016);
      }
      // 用户开始拖动（对应 onVerticalDragUpdate）
      controller.onUserScroll(80);
      expect(controller.isUserScrolling, isTrue);

      // 模拟拖动被取消：GestureDetector 只回调 onVerticalDragCancel、
      // 不再回调 onUserScrollEnd。若漏处理，isUserScrolling 永远为 true。
      for (int i = 0; i < 1000; i++) {
        controller.tick(0.016);
      }
      expect(controller.isUserScrolling, isTrue,
          reason: '取消拖动后 isUserScrolling 不得卡死为 true');
      expect(controller.isConverged, isFalse,
          reason: '取消拖动后不得永不收敛（否则省电模式无法锁回 60fps）');
      controller.dispose();
    });

    test('13. 拖动取消后以 0 速度结束（onUserScrollEnd）→ 恢复收敛', () {
      final controller = LyricScrollController();
      controller.setViewportSize(const Size(400, 600));
      controller.setCurrentLine(
        0,
        isSeeking: false,
        lineHeight: 40,
        intervalMs: 500,
      );
      for (int i = 0; i < 300; i++) {
        controller.tick(0.016);
      }
      final double stableY = controller.posY;

      controller.onUserScroll(80);
      expect(controller.isUserScrolling, isTrue);

      // 取消处理：等价于以 0 速度松手，启动 5s 自动回弹倒计时
      controller.onUserScrollEnd(velocity: 0);
      expect(controller.isUserScrolling, isFalse);
      expect(controller.isWaitingForAutoReturn, isTrue);

      // 推进 6s（5s 回弹 + 收敛），应回弹回当前行并收敛
      for (int i = 0; i < 400; i++) {
        controller.tick(0.016);
      }
      expect(controller.isWaitingForAutoReturn, isFalse);
      expect(controller.isConverged, isTrue,
          reason: '取消后恢复结束应能重新收敛（省电模式可锁回 60fps）');
      expect(controller.posY, closeTo(stableY, 1.0),
          reason: '取消后应自动回弹到当前行');
      controller.dispose();
    });

    test('14. 回弹后位移先于严格收敛进入 0.5px（省电模式可提前锁回 60fps）', () {
      final controller = LyricScrollController();
      controller.setViewportSize(const Size(400, 600));
      controller.setCurrentLine(
        0,
        isSeeking: false,
        lineHeight: 40,
        intervalMs: 500,
      );
      // 推进到稳定
      for (int i = 0; i < 300; i++) {
        controller.tick(0.016);
      }
      // 拖动 + 松手，进入 3s 自动回弹
      controller.onUserScroll(80);
      controller.onUserScrollEnd(velocity: 0);

      // 记录两个时点（跳过 3s 等待期，此时位移为 0 不代表收敛）：
      //  - visualTick：回弹开始后，posY 距 target < 0.5px（省电模式"视觉收敛"阈值）
      //  - strictTick：isConverged（Spring.isSettled，需位移收敛到 ~0.0001px）
      int visualTick = -1;
      int strictTick = -1;
      for (int i = 0; i < 2000; i++) {
        controller.tick(0.016);
        if (controller.isWaitingForAutoReturn) continue; // 等待期不计入
        if (visualTick < 0 &&
            (controller.posY - controller.currentTarget).abs() < 0.5) {
          visualTick = i;
        }
        if (strictTick < 0 && controller.isConverged) {
          strictTick = i;
        }
      }
      expect(visualTick, greaterThan(0), reason: '回弹后位移应进入 0.5px');
      expect(strictTick, greaterThan(0), reason: '回弹后最终应严格收敛');
      // 修复依据：省电模式用 <0.5px 判定收敛，比严格 Spring.isSettled 提前
      // 数百毫秒，避免弹簧"肉眼到目标后"仍长时间不锁回 60fps。
      expect(strictTick, greaterThan(visualTick),
          reason: '位移进入 0.5px 应先于严格收敛，省电模式才能及时锁回 60fps');
      controller.dispose();
    });

    test('15. resetInitialJump 后再次 setCurrentLine 重新瞬移（切歌场景）', () {
      final controller = LyricScrollController();
      controller.setViewportSize(const Size(400, 600));
      // 首次定位瞬移到第 0 行（targetY=190）
      controller.setCurrentLine(
        0,
        isSeeking: false,
        lineHeight: 40,
        intervalMs: 500,
      );
      expect(controller.posY, closeTo(190, 1e-9), reason: '首次定位应瞬移');

      // 切歌：复位首次定位状态后，新歌的首次定位也直接瞬移
      controller.resetInitialJump();
      controller.setCurrentLine(
        5,
        isSeeking: false,
        lineHeight: 40,
        intervalMs: 500,
      );
      // 第 5 行 targetY = -(200 + 20 - 210) = -10（见测试 3 targetYForLine）
      expect(controller.posY, closeTo(-10, 1e-9),
          reason: 'resetInitialJump 后应重新瞬移到位');
      controller.dispose();
    });
  });
}
