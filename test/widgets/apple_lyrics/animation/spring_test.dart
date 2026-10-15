import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/animation/spring.dart';

void main() {
  group('Spring', () {
    test('从 position=0 到 target=1 应收敛到 1', () {
      final spring = Spring(stiffness: 100, damping: 20, mass: 1);
      spring.setPosition(0, 0);
      spring.setTarget(1);

      // 默认参数下 discriminant=0 为临界阻尼，约 1.5s 内收敛
      for (int i = 0; i < 200; i++) {
        spring.tick(0.016);
      }

      expect(spring.position, closeTo(1, 0.01));
      expect(spring.isSettled, isTrue);
    });

    test('高 stiffness 收敛更快', () {
      // damping=20 时：低 stiffness(50) 进入过阻尼（20 > 2*sqrt(50)≈14.14）单调慢收敛；
      // 高 stiffness(400) 为欠阻尼（20 < 2*sqrt(400)=40）快速震荡收敛
      final soft = Spring(stiffness: 50, damping: 20, mass: 1);
      final stiff = Spring(stiffness: 400, damping: 20, mass: 1);
      soft.setPosition(0, 0);
      soft.setTarget(1);
      stiff.setPosition(0, 0);
      stiff.setTarget(1);

      // 模拟 0.32 秒（20 步）
      for (int i = 0; i < 20; i++) {
        soft.tick(0.016);
        stiff.tick(0.016);
      }

      // 高 stiffness 应更接近目标 1
      expect((1 - stiff.position).abs(),
          lessThan((1 - soft.position).abs()));
    });

    test('isSettled 在运动中返回 false，稳定后返回 true', () {
      final spring = Spring(stiffness: 100, damping: 20, mass: 1);
      spring.setPosition(0, 0);
      spring.setTarget(1);

      // 刚 setTarget，尚未 tick，处于待运动状态
      expect(spring.isSettled, isFalse);

      // tick 一次后仍在运动
      spring.tick(0.016);
      expect(spring.isSettled, isFalse);

      // 模拟足够长时间直到稳定
      for (int i = 0; i < 300; i++) {
        spring.tick(0.016);
      }
      expect(spring.isSettled, isTrue);
    });

    test('setTarget 在运动中改变目标能正常过渡', () {
      final spring = Spring(stiffness: 100, damping: 20, mass: 1);
      spring.setPosition(0, 0);
      spring.setTarget(1);

      // 运动 0.096 秒
      for (int i = 0; i < 6; i++) {
        spring.tick(0.016);
      }
      final double midPos = spring.position;
      expect(midPos, greaterThan(0));
      expect(midPos, lessThan(1));

      // 运动中改变目标到 2
      spring.setTarget(2);
      expect(spring.isSettled, isFalse);

      // 继续运动直到稳定
      for (int i = 0; i < 500; i++) {
        spring.tick(0.016);
      }
      expect(spring.position, closeTo(2, 0.01));
      expect(spring.isSettled, isTrue);
    });

    test('reset() 后回到 0', () {
      final spring = Spring(stiffness: 100, damping: 20, mass: 1);
      spring.setPosition(0, 0);
      spring.setTarget(1);
      for (int i = 0; i < 50; i++) {
        spring.tick(0.016);
      }
      expect(spring.position, isNot(equals(0)));

      spring.reset();
      expect(spring.position, equals(0));
      expect(spring.velocity, equals(0));
      expect(spring.target, equals(0));
      expect(spring.isSettled, isTrue);
    });

    test('大 dt 输入不导致数值发散', () {
      final spring = Spring(stiffness: 100, damping: 20, mass: 1);
      spring.setPosition(0, 0);
      spring.setTarget(1);

      // 一次性 tick 10 秒，子步进应保证不发散
      spring.tick(10.0);

      expect(spring.position, isNot(equals(double.infinity)));
      expect(spring.position.isNaN, isFalse);
      expect(spring.position, closeTo(1, 0.01));
      expect(spring.isSettled, isTrue);
    });

    test('setPosition 设置初始状态并标记为稳定', () {
      final spring = Spring();
      spring.setPosition(5, 0);
      expect(spring.position, equals(5));
      expect(spring.target, equals(5));
      expect(spring.isSettled, isTrue);

      // tick 后不应改变（已稳定）
      spring.tick(0.1);
      expect(spring.position, equals(5));
    });

    test('setParams 动态调整参数后能继续收敛', () {
      final spring = Spring(stiffness: 100, damping: 20, mass: 1);
      spring.setPosition(0, 0);
      spring.setTarget(1);

      // 运动 0.096 秒
      for (int i = 0; i < 6; i++) {
        spring.tick(0.016);
      }

      // 运动中改变参数
      spring.setParams(stiffness: 400, damping: 30);

      // 继续运动直到稳定
      for (int i = 0; i < 500; i++) {
        spring.tick(0.016);
      }
      expect(spring.position, closeTo(1, 0.01));
      expect(spring.isSettled, isTrue);
    });

    test('过阻尼情况稳定收敛不发散', () {
      // damping=30 > 2*sqrt(100)=20，过阻尼
      final spring = Spring(stiffness: 100, damping: 30, mass: 1);
      spring.setPosition(0, 0);
      spring.setTarget(1);

      for (int i = 0; i < 500; i++) {
        spring.tick(0.016);
      }

      expect(spring.position, isNot(equals(double.infinity)));
      expect(spring.position.isNaN, isFalse);
      expect(spring.position, closeTo(1, 0.01));
      expect(spring.isSettled, isTrue);
    });

    test('欠阻尼情况会震荡收敛', () {
      // damping=5 < 2*sqrt(100)=20，欠阻尼
      final spring = Spring(stiffness: 100, damping: 5, mass: 1);
      spring.setPosition(0, 0);
      spring.setTarget(1);

      double maxOvershoot = 0;
      for (int i = 0; i < 500; i++) {
        spring.tick(0.016);
        if (spring.position > maxOvershoot) {
          maxOvershoot = spring.position;
        }
      }

      // 欠阻尼应产生超调（超过目标值 1）
      expect(maxOvershoot, greaterThan(1));
      expect(spring.position, closeTo(1, 0.01));
      expect(spring.isSettled, isTrue);
    });

    test('tick(0) 与负 dt 不影响状态', () {
      final spring = Spring(stiffness: 100, damping: 20, mass: 1);
      spring.setPosition(0, 0);
      spring.setTarget(1);
      spring.tick(0);
      expect(spring.position, equals(0));
      spring.tick(-1);
      expect(spring.position, equals(0));
    });
  });
}
