import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/player/mini_player.dart';

MediaQueryData _mq({
  required double viewPaddingBottom,
  BorderRadius? cornerRadii,
}) {
  return MediaQueryData(
    size: const Size(1080, 2400),
    viewPadding: EdgeInsets.only(bottom: viewPaddingBottom),
    displayCornerRadii: cornerRadii,
  );
}

void main() {
  group('resolveMiniPlayerCornerClearance', () {
    test('本机实测组合 R=58 / inset=20 → 底 20、左右 15', () {
      final c = resolveMiniPlayerCornerClearance(
        _mq(viewPaddingBottom: 20, cornerRadii: BorderRadius.circular(58)),
      );
      expect(c.bottom, closeTo(20.0, 0.001));
      expect(c.horizontal, closeTo(15.0, 0.001));
    });

    test('inset 为 0 时底部由下限 12 托底，左右随之增大到 23', () {
      final c = resolveMiniPlayerCornerClearance(
        _mq(viewPaddingBottom: 0, cornerRadii: BorderRadius.circular(58)),
      );
      expect(c.bottom, closeTo(12.0, 0.001));
      expect(c.horizontal, closeTo(23.0, 0.001));
    });

    test('中等圆角 R=30 → 左右 6', () {
      final c = resolveMiniPlayerCornerClearance(
        _mq(viewPaddingBottom: 0, cornerRadii: BorderRadius.circular(30)),
      );
      expect(c.bottom, closeTo(12.0, 0.001));
      expect(c.horizontal, closeTo(6.0, 0.001));
    });

    test('小圆角 R=20 → 左右取基础值 4（反解值不足 4）', () {
      final c = resolveMiniPlayerCornerClearance(
        _mq(viewPaddingBottom: 0, cornerRadii: BorderRadius.circular(20)),
      );
      expect(c.horizontal, closeTo(4.0, 0.001));
    });

    test('圆角未上报时用兜底半径 28 → 左右 6', () {
      final c = resolveMiniPlayerCornerClearance(_mq(viewPaddingBottom: 0));
      expect(c.bottom, closeTo(12.0, 0.001));
      expect(c.horizontal, closeTo(6.0, 0.001));
    });

    test('三按钮导航 inset=48 时底部不被压缩，左右回到基础值 4', () {
      final c = resolveMiniPlayerCornerClearance(
        _mq(viewPaddingBottom: 48, cornerRadii: BorderRadius.circular(58)),
      );
      expect(c.bottom, closeTo(48.0, 0.001));
      expect(c.horizontal, closeTo(4.0, 0.001));
    });

    test('异常大圆角被上限 24 截断', () {
      final c = resolveMiniPlayerCornerClearance(
        _mq(viewPaddingBottom: 12, cornerRadii: BorderRadius.circular(200)),
      );
      expect(c.horizontal, closeTo(24.0, 0.001));
    });

    test('直角屏（R=0）→ 底部走下限、左右走基础值', () {
      final c = resolveMiniPlayerCornerClearance(
        _mq(viewPaddingBottom: 0, cornerRadii: BorderRadius.zero),
      );
      expect(c.bottom, closeTo(12.0, 0.001));
      expect(c.horizontal, closeTo(4.0, 0.001));
    });

    test('圆角极小（R=2）不产生负数/NaN', () {
      final c = resolveMiniPlayerCornerClearance(
        _mq(viewPaddingBottom: 0, cornerRadii: BorderRadius.circular(2)),
      );
      expect(c.horizontal, closeTo(4.0, 0.001));
    });

    test('左右下角不对称时取较大一侧', () {
      final c = resolveMiniPlayerCornerClearance(
        _mq(
          viewPaddingBottom: 20,
          cornerRadii: const BorderRadius.only(
            bottomLeft: Radius.circular(20),
            bottomRight: Radius.circular(58),
          ),
        ),
      );
      expect(c.horizontal, closeTo(15.0, 0.001));
    });
  });
}
