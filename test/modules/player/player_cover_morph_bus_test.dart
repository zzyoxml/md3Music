import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/player/player_cover_morph.dart';

void main() {
  test('coverSuppressed=true 时封面不画，文字判据不受影响', () {
    final bus = PlayerCoverMorphBus.instance;
    bus.coverSuppressed = false;
    bus.eligible = true;
    bus.miniRect = const Rect.fromLTWH(0, 0, 44, 44);
    bus.settledRect = const Rect.fromLTWH(40, 60, 300, 300);
    bus.miniTextRect = const Rect.fromLTWH(60, 10, 200, 30);
    bus.settledTextRect = const Rect.fromLTWH(40, 380, 300, 60);
    bus.textEligible = true;
    addTearDown(() {
      bus.coverSuppressed = false;
      bus.eligible = false;
      bus.textEligible = false;
      bus.miniRect = null;
      bus.settledRect = null;
      bus.miniTextRect = null;
      bus.settledTextRect = null;
    });

    expect(bus.layerWillDraw, isTrue);
    expect(bus.coverLayerWillDraw, isTrue);
    expect(bus.textWillDraw, isTrue);

    bus.coverSuppressed = true;
    expect(bus.coverLayerWillDraw, isFalse);
    // 文字形变保留（用户明确要求）
    expect(bus.textWillDraw, isTrue);
  });

  group('publishMini 的圆角 / 旋转上报（悬浮形态起点）', () {
    tearDown(PlayerCoverMorphBus.instance.reset);

    test('缺省 = 常驻条口径（6dp 圆角、0 旋转）', () {
      final bus = PlayerCoverMorphBus.instance;
      bus.publishMini(const Rect.fromLTWH(0, 0, 44, 44));
      expect(bus.miniCoverCornerRadius, kCoverMorphMiniRadius);
      expect(bus.miniCoverRotation, 0.0);
    });

    test('胶囊 / 圆盘：正圆半径与当前唱片角都进登记簿', () {
      final bus = PlayerCoverMorphBus.instance;
      bus.publishMini(
        const Rect.fromLTWH(19, 3, 58, 58),
        cornerRadius: 29,
        rotation: 1.234,
      );
      expect(bus.miniCoverCornerRadius, 29);
      expect(bus.miniCoverRotation, 1.234);
    });

    test('圆角/旋转参与变更判据（矩形不变也要 bump revision）', () {
      final bus = PlayerCoverMorphBus.instance;
      bus.publishMini(const Rect.fromLTWH(0, 0, 58, 58), cornerRadius: 29);
      final afterFirst = bus.revision.value;
      // 同矩形 + 同圆角：圆盘停转时逐帧 paint 上报，不该空转 revision
      bus.publishMini(const Rect.fromLTWH(0, 0, 58, 58), cornerRadius: 29);
      expect(bus.revision.value, afterFirst);
      // 同矩形 + 角度变了（唱片在转）：必须 bump，否则形变层停在旧角度
      bus.publishMini(
        const Rect.fromLTWH(0, 0, 58, 58),
        cornerRadius: 29,
        rotation: 0.5,
      );
      expect(bus.revision.value, afterFirst + 1);
    });

    test('非法值回退（NaN 圆角按缺省、NaN 角度按 0）', () {
      final bus = PlayerCoverMorphBus.instance;
      bus.publishMini(
        const Rect.fromLTWH(0, 0, 58, 58),
        cornerRadius: double.nan,
        rotation: double.infinity,
      );
      expect(bus.miniCoverCornerRadius, kCoverMorphMiniRadius);
      expect(bus.miniCoverRotation, 0.0);
    });

    test('reset() 把新字段也复位（跨用例不泄漏）', () {
      final bus = PlayerCoverMorphBus.instance;
      bus.publishMini(
        const Rect.fromLTWH(0, 0, 56, 56),
        cornerRadius: 28,
        rotation: 2.0,
      );
      bus.reset();
      expect(bus.miniCoverCornerRadius, kCoverMorphMiniRadius);
      expect(bus.miniCoverRotation, 0.0);
      expect(bus.miniRect, isNull);
    });
  });

  group('coverMorphLocalRadius 的起点参数化', () {
    test('startRadius=29（胶囊正圆）：屏幕上 t=0 恰为 29', () {
      // scale=1 时局部半径 == 屏幕半径
      expect(coverMorphLocalRadius(0, 1, startRadius: 29), closeTo(29, 1e-9));
      expect(coverMorphLocalRadius(0.5, 1, startRadius: 29), closeTo(22.5, 1e-9));
      expect(coverMorphLocalRadius(1, 1, startRadius: 29), closeTo(16, 1e-9));
    });

    test('scale≠1：屏幕半径 = 局部 × scale，仍从 startRadius 起', () {
      const scale = 0.25;
      expect(
        coverMorphLocalRadius(0, scale, startRadius: 29) * scale,
        closeTo(29, 1e-9),
      );
      expect(
        coverMorphLocalRadius(1, scale) * scale,
        closeTo(16, 1e-9),
      );
    });

    test('非法 startRadius 回退缺省 6（旧行为兜底）', () {
      expect(coverMorphLocalRadius(0, 1, startRadius: double.nan), 6.0);
      expect(coverMorphLocalRadius(0, 1, startRadius: -4), 6.0);
    });

    test('endRadius=圆盘半径（边长/2）：t=1 恰好是正圆', () {
      const discWidth = 336.0 * (1 - 2 * 0.12);
      expect(
        coverMorphLocalRadius(1, 1, endRadius: discWidth / 2),
        closeTo(discWidth / 2, 1e-9),
      );
      // 中途按同一进度插值，仍在两端之间
      final mid = coverMorphLocalRadius(0.5, 1, endRadius: discWidth / 2);
      expect(mid, greaterThan(kCoverMorphMiniRadius));
      expect(mid, lessThan(discWidth / 2));
    });
  });

  group('settledInsetRatio（频谱圆盘的终点内缩比例）', () {
    tearDown(PlayerCoverMorphBus.instance.reset);

    Rect publishInset(double inset) {
      final bus = PlayerCoverMorphBus.instance;
      bus.publishFull(
        measured: const Rect.fromLTWH(180, 400, 720, 720),
        logicalSize: const Size(720, 720),
        pageOffset: Offset.zero,
        songId: 's1',
        artworkUri: null,
        fallbackFilePath: null,
        iconSize: 48,
        placeholderColor: const Color(0xFF000000),
        eligible: true,
        settledArtworkScale: 1.0,
        settledArtworkAnchor: Alignment.center,
        settledInsetRatio: inset,
      );
      return bus.settledRect!;
    }

    test('缺省 0 = 方图路径，settledRect 仍是槽位盒', () {
      final bus = PlayerCoverMorphBus.instance;
      expect(publishInset(0), const Rect.fromLTWH(180, 400, 720, 720));
      expect(bus.settledInsetRatio, 0.0);
    });

    test('圆盘：上报 0.12 原样进登记簿；settledRect 保持盒矩形（内缩在绘制时施加）', () {
      final bus = PlayerCoverMorphBus.instance;
      final box = publishInset(0.12);
      expect(bus.settledInsetRatio, closeTo(0.12, 1e-12));
      expect(box, const Rect.fromLTWH(180, 400, 720, 720));
    });

    test('参与变更判据（方图↔圆盘切换必须 bump revision）', () {
      final bus = PlayerCoverMorphBus.instance;
      publishInset(0);
      final afterSquare = bus.revision.value;
      // 同矩形同其他参数、只有形状变了：必须 bump，否则形变层停在旧终点
      publishInset(0.12);
      expect(bus.revision.value, afterSquare + 1);
      // 重复上报同值：不空转
      publishInset(0.12);
      expect(bus.revision.value, afterSquare + 1);
    });

    test('非法值归零 / 越界钳制', () {
      final bus = PlayerCoverMorphBus.instance;
      publishInset(double.nan);
      expect(bus.settledInsetRatio, 0.0);
      publishInset(-1);
      expect(bus.settledInsetRatio, 0.0);
      publishInset(9);
      expect(bus.settledInsetRatio, closeTo(0.45, 1e-12));
    });

    test('reset() 归零', () {
      final bus = PlayerCoverMorphBus.instance;
      publishInset(0.12);
      bus.reset();
      expect(bus.settledInsetRatio, 0.0);
    });
  });

  group('唱片角插值（共享相位 → 单帧角度）', () {
    test('wrapPi 归一到 (-π, π]', () {
      expect(coverMorphWrapPi(0.3), closeTo(0.3, 1e-12));
      expect(coverMorphWrapPi(2 * math.pi + 0.3), closeTo(0.3, 1e-12));
      expect(coverMorphWrapPi(-2 * math.pi - 0.3), closeTo(-0.3, 1e-12));
      expect(coverMorphWrapPi(3 * math.pi / 2), closeTo(-math.pi / 2, 1e-12));
      // 非有限值按 0（clamp 对 NaN 比较不出大小）
      expect(coverMorphWrapPi(double.nan), 0.0);
      expect(coverMorphWrapPi(double.infinity), 0.0);
    });

    test('两端严格落在端点上：t=0 = 起点角，t=1 = 起点角 + 连续差', () {
      expect(coverMorphFlightAngle(start: 6.0, delta: 0.5, t: 0), closeTo(6.0, 1e-12));
      expect(
        coverMorphFlightAngle(start: 6.0, delta: 0.5, t: 1),
        closeTo(6.5, 1e-12),
      );
      // 方图路径 delta = −start → 与改动前的 start × (1 − t) 逐值相同
      final start = 5.5;
      for (final t in <double>[0, 0.25, 0.5, 0.75, 1]) {
        expect(
          coverMorphFlightAngle(start: start, delta: -start, t: t),
          closeTo(start * (1 - t), 1e-12),
        );
      }
    });

    test('非有限入参不放大成 NaN', () {
      expect(
        coverMorphFlightAngle(start: double.nan, delta: 1, t: 0.5),
        closeTo(0.5, 1e-12),
      );
      expect(
        coverMorphFlightAngle(start: 1, delta: double.nan, t: 0.5),
        closeTo(1.0, 1e-12),
      );
    });

    test('相位回绕跟踪：连续累加 wrapPi 不会在跨圈时跳变', () {
      // 模拟"相位从 6.2 转到 0.1（跨 2π）"，起点角 2.0：
      // 首帧取最短路径,之后逐帧并入，delta 连续、不出现 2π 的假跳
      const start = 2.0;
      double delta = coverMorphWrapPi(6.2 - start);
      final before = coverMorphFlightAngle(start: start, delta: delta, t: 1);
      // 相位回绕后（0.1 rad，实际又前进 0.1+2π−6.2 = 0.183 rad）
      final raw = 0.1 - start;
      delta = delta + coverMorphWrapPi(raw - delta);
      final after = coverMorphFlightAngle(start: start, delta: delta, t: 1);
      expect((after - before).abs(), lessThan(0.3), reason: '跨圈只应前进一小步');
      // 且与真身相位同余（mod 2π）
      expect((after - 0.1) % (2 * math.pi), closeTo(0, 1e-9));
    });
  });
}
