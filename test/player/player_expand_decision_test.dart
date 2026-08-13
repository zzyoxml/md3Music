import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/player/full_player_route.dart';

/// MiniPlayer 上滑松手展开判定（需求 5/6/7）单测：
/// - 距离 ≥ 20% 屏高 → 展开（需求 5）
/// - 距离不足 20% 且速度/加速度未达标 → 收起（需求 6）
/// - 速度 / 加速度超阈值 → 即使距离不足也展开（需求 7）
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
  });
}
