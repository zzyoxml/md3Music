import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/player/full_player_route.dart';

/// MiniPlayer 上滑松手展开判定（需求 5/6/7/8）单测：
/// - 距离 ≥ 20% 屏高 → 展开（需求 5）
/// - 距离不足 20% 且速度/加速度未达标 → 收起（需求 6）
/// - 速度 / 加速度超阈值 → 即使距离不足也展开（需求 7）
/// - 松手瞬间向下回拉（加速度向下）→ 即使距离 ≥ 20% 也不展开（需求 8）
void main() {
  group('shouldExpandPlayer 松手展开判定', () {
    const screenHeight = 800.0;

    test('距离达到 20% 屏高 → 展开', () {
      expect(
        shouldExpandPlayer(
          dragDistance: 160,
          screenHeight: screenHeight,
          velocity: 0,
          acceleration: 0,
        ),
        isTrue,
      );
      // 超过阈值同样展开
      expect(
        shouldExpandPlayer(
          dragDistance: 400,
          screenHeight: screenHeight,
          velocity: 0,
          acceleration: 0,
        ),
        isTrue,
      );
    });

    test('距离未达 20% 且速度/加速度均未达标 → 收起', () {
      expect(
        shouldExpandPlayer(
          dragDistance: 100,
          screenHeight: screenHeight,
          velocity: 500,
          acceleration: 2000,
        ),
        isFalse,
      );
    });

    test('距离未达 20% 但速度超阈值 → 展开', () {
      expect(
        shouldExpandPlayer(
          dragDistance: 50,
          screenHeight: screenHeight,
          velocity: 1000,
          acceleration: 0,
        ),
        isTrue,
      );
    });

    test('距离未达 20% 但加速度超阈值 → 展开', () {
      expect(
        shouldExpandPlayer(
          dragDistance: 50,
          screenHeight: screenHeight,
          velocity: 0,
          acceleration: 7000,
        ),
        isTrue,
      );
    });

    test('距离未达 20% 但末端减速（负加速度）超阈值 → 展开', () {
      // 快速甩动末端手指减速，加速度为负，取绝对值后同样判定展开
      expect(
        shouldExpandPlayer(
          dragDistance: 50,
          screenHeight: screenHeight,
          velocity: 0,
          acceleration: -7000,
        ),
        isTrue,
      );
    });

    test('速度/加速度恰等于阈值 → 不展开（严格大于）', () {
      expect(
        shouldExpandPlayer(
          dragDistance: 50,
          screenHeight: screenHeight,
          velocity: kPlayerFlingVelocityThreshold,
          acceleration: 0,
        ),
        isFalse,
      );
      expect(
        shouldExpandPlayer(
          dragDistance: 50,
          screenHeight: screenHeight,
          velocity: 0,
          acceleration: kPlayerAccelerationThreshold,
        ),
        isFalse,
      );
    });

    test('距离 ≥ 20% 但松手瞬间向下回拉 → 不展开（回拉否决）', () {
      // 上滑超过 20% 后往回拉：松手时速度向下（负值）、加速度向下，
      // 视为取消展开，即使累计距离达标也不进入 FullPlayer
      expect(
        shouldExpandPlayer(
          dragDistance: 200,
          screenHeight: screenHeight,
          velocity: -500,
          acceleration: -7000,
        ),
        isFalse,
      );
      // 回拉但距离未达标：同样不展开
      expect(
        shouldExpandPlayer(
          dragDistance: 50,
          screenHeight: screenHeight,
          velocity: -500,
          acceleration: 0,
        ),
        isFalse,
      );
    });

    test('距离 ≥ 20% 且松手时速度向上/静止 → 展开（回拉否决不生效）', () {
      expect(
        shouldExpandPlayer(
          dragDistance: 200,
          screenHeight: screenHeight,
          velocity: 200,
          acceleration: 0,
        ),
        isTrue,
      );
      expect(
        shouldExpandPlayer(
          dragDistance: 200,
          screenHeight: screenHeight,
          velocity: 0,
          acceleration: 0,
        ),
        isTrue,
      );
    });

    test('轻微向下抖动未达回拉阈值 → 距离达标仍展开', () {
      // -50 px/s 未超过 100 的回拉阈值，视为保持位置而非回拉
      expect(
        shouldExpandPlayer(
          dragDistance: 200,
          screenHeight: screenHeight,
          velocity: -50,
          acceleration: 0,
        ),
        isTrue,
      );
    });

    test('距离 ≥ 20% 但回拉否决优先于速度/加速度达标 → 不展开', () {
      // 即便向上甩动速度/加速度超阈值，只要松手瞬间在向下回拉即否决
      expect(
        shouldExpandPlayer(
          dragDistance: 200,
          screenHeight: screenHeight,
          velocity: -900,
          acceleration: 7000,
        ),
        isFalse,
      );
    });
  });
}
