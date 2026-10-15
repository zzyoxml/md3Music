import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/player/playlist_swipe.dart';

void main() {
  group('playlistSwipeCrossAxisExceeded', () {
    test('纵向位移超过 48 即放弃，把纵向手势让给列表', () {
      expect(playlistSwipeCrossAxisExceeded(48.0), isFalse);
      expect(playlistSwipeCrossAxisExceeded(48.1), isTrue);
      expect(playlistSwipeCrossAxisExceeded(-48.1), isTrue);
    });
  });

  group('playlistSwipeIsForwardHorizontal', () {
    test('左滑且横向为主才成立', () {
      expect(playlistSwipeIsForwardHorizontal(-20, 2), isTrue);
    });

    test('斜向拖拽不成立（横向不足纵向的 1.6 倍）', () {
      expect(playlistSwipeIsForwardHorizontal(-20, 13), isFalse);
    });

    test('右滑留给滑动删除，一律不成立', () {
      expect(playlistSwipeIsForwardHorizontal(20, 0), isFalse);
      expect(playlistSwipeIsForwardHorizontal(20, 40), isFalse);
    });

    test('零位移不成立', () {
      expect(playlistSwipeIsForwardHorizontal(0, 0), isFalse);
    });
  });

  group('playlistSwipeProgressFromDx', () {
    test('整页左滑恰好 1.0', () {
      expect(playlistSwipeProgressFromDx(-400, 400), 1.0);
    });

    test('四分之一页 → 0.25', () {
      expect(playlistSwipeProgressFromDx(-100, 400), closeTo(0.25, 1e-9));
    });

    test('超出一页钳到 1.0，右滑钳到 0.0', () {
      expect(playlistSwipeProgressFromDx(-900, 400), 1.0);
      expect(playlistSwipeProgressFromDx(900, 400), 0.0);
    });

    test('面板宽度未测量时返回 0（不做除零）', () {
      expect(playlistSwipeProgressFromDx(-100, 0), 0.0);
    });
  });

  group('playlistSwipeSettleTarget', () {
    test('滑过一半（含正好一半）停在下一页', () {
      expect(
        playlistSwipeSettleTarget(
          progress: 0.6,
          velocityPxPerSec: 0,
          panelWidth: 400,
        ),
        1,
      );
      expect(
        playlistSwipeSettleTarget(
          progress: 0.5,
          velocityPxPerSec: 0,
          panelWidth: 400,
        ),
        1,
      );
    });

    test('不足一半且松手速度为 0 → 回播放列表', () {
      expect(
        playlistSwipeSettleTarget(
          progress: 0.49,
          velocityPxPerSec: 0,
          panelWidth: 400,
        ),
        0,
      );
    });

    test('快速轻扫：位移不足半页也翻页', () {
      // 0.2 + (3000 px/s ÷ 400 px/页) × 0.08s = 0.2 + 0.6 = 0.8 → 1
      expect(
        playlistSwipeSettleTarget(
          progress: 0.2,
          velocityPxPerSec: -3000,
          panelWidth: 400,
        ),
        1,
      );
    });

    test('反向轻扫（往回拖）不翻页', () {
      // 0.8 - 0.6 = 0.2 → 0
      expect(
        playlistSwipeSettleTarget(
          progress: 0.8,
          velocityPxPerSec: 3000,
          panelWidth: 400,
        ),
        0,
      );
    });

    test('面板宽度未测量：按纯位移取整，不抛异常', () {
      expect(
        playlistSwipeSettleTarget(
          progress: 0.7,
          velocityPxPerSec: -3000,
          panelWidth: 0,
        ),
        1,
      );
    });
  });
}