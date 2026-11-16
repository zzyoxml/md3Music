// 全屏播放器封面投影（PlayerCoverShadow）的规格测试。
//
// 钉住三件容易在后续改动里悄悄丢掉的事：
// 1. 阴影轮廓的圆角必须与封面裁剪同源（kCoverMorphFullRadius），否则四角露暗边；
// 2. 模糊/下移/内缩按封面边长取比例并夹在上限内 —— 同一档阴影要同时服务
//    窄横屏 ~82dp 与平板展开 ~464dp 的封面；
// 3. 取色一律由宿主传 ColorScheme.shadow（本仓卖点是动态取色，写死黑色在浅色
//    主题下会脏）；投影纯绘制，不得为阴影额外占位。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/player/player_cover_morph.dart';
import 'package:md3music/modules/player/player_cover_shadow.dart';

BoxDecoration _decoration(
  double side, {
  Color? shadowColor,
  double intensity = PlayerCoverShadow.defaultIntensity,
}) => PlayerCoverShadow.decoration(
  shadowColor: shadowColor ?? const Color(0xFF000000),
  side: side,
  intensity: intensity,
);

void main() {
  test('圆角与封面裁剪同源', () {
    final decoration = _decoration(200);
    // 两层：贴边的硬影 + 大范围弥散的环境影，单层出不来「浮起来」的层次
    expect(decoration.boxShadow, hasLength(2));
    expect(
      decoration.borderRadius,
      BorderRadius.circular(kCoverMorphFullRadius),
      reason: '阴影比封面圆角更方时，四角会露出一圈暗边',
    );
  });

  test('按封面边长取比例，并在两端夹住', () {
    final tiny = _decoration(40).boxShadow!;
    final mid = _decoration(200).boxShadow!;
    final huge = _decoration(460).boxShadow!;
    // 两层都随封面变大
    expect(mid[0].blurRadius, greaterThan(tiny[0].blurRadius));
    expect(huge[0].blurRadius, greaterThan(mid[0].blurRadius));
    expect(mid[1].blurRadius, greaterThan(tiny[1].blurRadius));
    expect(huge[1].blurRadius, greaterThan(mid[1].blurRadius));
    // 上下限：小封面不糊成一团，大封面不拖出脏边
    expect(tiny[0].blurRadius, 8.0);
    expect(huge[0].blurRadius, 30.0);
    expect(tiny[1].blurRadius, 16.0);
    expect(huge[1].blurRadius, 60.0);
    // 位移按强度缩放：低强度贴边，满强度才外拖到上限
    final hugeFull = _decoration(460, intensity: 1.0).boxShadow!;
    expect(tiny[0].offset.dy, 3.0);
    expect(huge[0].offset.dy, closeTo(460 * 0.06 * 0.7, 0.01));
    expect(hugeFull[0].offset.dy, 22.0);
    // 硬影带下移、环境影不偏移；两层都负扩散，否则会在封面轮廓外匀出一圈灰边
    for (final shadow in <BoxShadow>[...tiny, ...huge]) {
      expect(shadow.spreadRadius, lessThan(0));
    }
    expect(huge[1].offset, Offset.zero);
  });

  test('强度只缩放浓度与位移，0 等于关掉整层', () {
    final full = _decoration(200, intensity: 1.0).boxShadow!;
    final weak = _decoration(200, intensity: 0.3).boxShadow!;
    for (var i = 0; i < 2; i++) {
      expect(weak[i].color.a, lessThan(full[i].color.a));
    }
    // 浓度按线性缩放：alpha = 上限 × 强度
    expect(
      full[0].color,
      const Color(0xFF000000).withValues(alpha: 0.45),
      reason: '硬影浓度上限：0.45 × 强度 1.0',
    );
    expect(
      full[1].color.a,
      closeTo(0.28, 0.001),
      reason: '环境影浓度上限：0.28 × 强度 1.0',
    );
    expect(weak[0].color.a, closeTo(0.45 * 0.3, 0.001));
    // 位移也跟着强度走，低强度时贴边、不外拖
    expect(weak[0].offset.dy, lessThan(full[0].offset.dy));
  });

  test('取色跟随宿主传入的 shadow token', () {
    const token = Color(0xFF112233);
    // 满强度下浓度就是两层各自的上限，取色必须整体跟着 token 走（不写死黑）
    final shadows = _decoration(200, shadowColor: token, intensity: 1.0).boxShadow!;
    expect(shadows[0].color, token.withValues(alpha: 0.45));
    expect(shadows[1].color, token.withValues(alpha: 0.28));
  });

  testWidgets('wrap 纯绘制：不为阴影额外占位', (tester) async {
    const target = Key('coverBoxTarget');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              height: 200,
              child: PlayerCoverShadow.wrap(
                shadowColor: const Color(0xFF000000),
                child: const ColoredBox(key: target, color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.getRect(find.byKey(target)).size, const Size(200, 200));
    // Scaffold 自己也用 DecoratedBox，按祖先关系锁定投影那一层
    final decorated = tester.widget<DecoratedBox>(
      find.ancestor(
        of: find.byKey(target),
        matching: find.byType(DecoratedBox),
      ),
    );
    expect((decorated.decoration as BoxDecoration).boxShadow, hasLength(2));
    expect(
      tester.getRect(find.byKey(target)).size,
      const Size(200, 200),
      reason: '投影一旦为阴影留白，封面各处的几何断言就会漂',
    );
    expect(
      tester.getRect(
        find.ancestor(
          of: find.byKey(target),
          matching: find.byType(DecoratedBox),
        ),
      ).size,
      const Size(200, 200),
    );
  });

  testWidgets('强度 0 时整层投影不画（设置项关掉即完全退出）', (tester) async {
    final original = kCoverShadowIntensity.value;
    addTearDown(() => kCoverShadowIntensity.value = original);
    const target = Key('coverBoxZero');
    kCoverShadowIntensity.value = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              height: 200,
              child: PlayerCoverShadow.wrap(
                shadowColor: const Color(0xFF000000),
                child: const ColoredBox(key: target, color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    );
    expect(
      find.ancestor(
        of: find.byKey(target),
        matching: find.byType(DecoratedBox),
      ),
      findsNothing,
      reason: '0 强度下不该再挂任何投影层（连 LayoutBuilder 一并省掉）',
    );
    // 调回来立即生效：播放页订阅的是同一个 notifier
    kCoverShadowIntensity.value = 0.9;
    await tester.pump();
    expect(
      find.ancestor(
        of: find.byKey(target),
        matching: find.byType(DecoratedBox),
      ),
      findsOneWidget,
    );
  });
}
