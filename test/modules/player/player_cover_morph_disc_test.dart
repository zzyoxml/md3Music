import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/spectrum_disc_spin.dart';
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/modules/player/player_cover_morph.dart';
import 'package:md3music/modules/player/player_cover_morph_layer.dart';
import 'package:md3music/widgets/player_artwork_image.dart';

/// 频谱圆盘（style 0/1）参与封面形变的回归测试。
///
/// 改动前，圆盘模式下**整个封面形变被资格关掉**（形变层只会画方图），观感是
/// 上滑展开时封面直接从迷你条切到圆盘。本轮把终点形状交给槽位上报
/// （`settledInsetRatio`）+ 共享唱片相位（`SpectrumDiscSpin`）描述，本文件钉住
/// 四件事：
/// 1. 终点矩形 = 槽位盒按比例内缩，而不是整盒（否则封面会比真身大一圈）；
/// 2. 落位帧圆角 = 终点矩形边长 / 2（正圆），与真身 `ClipOval` 重合；
/// 3. 落位帧唱片角 ≡ 共享相位（mod 2π）；方图路径仍是"从起点角归零"；
/// 4. 圆盘端**不画投影**（真身 SpectrumArtwork 无投影），方图端照旧画。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 与其它形变用例同一套几何：迷你条封面贴左下 44×44，播放页封面居中 720×720。
  const mini = Rect.fromLTWH(16, 1900, 44, 44);
  const box = Rect.fromLTWH(180, 400, 720, 720);
  const double insetRatio = 0.12;
  const double discWidth = 720 * (1 - 2 * insetRatio); // 547.2
  const double discLeft = 180 + 720 * insetRatio; // 266.4

  late PlayerCoverMorphBus bus;

  setUp(() {
    bus = PlayerCoverMorphBus.instance;
    bus.reset();
    // reset() 不清这两项（它们是"另一次写入"的状态），显式归位防跨用例污染。
    bus.coverSuppressed = false;
    playerCoverVisible.value = true;
    SpectrumDiscSpin.instance.reset();
    playerExpansion.value = 0.0;
  });

  tearDown(() {
    playerExpansion.value = 0.0;
    bus.reset();
    SpectrumDiscSpin.instance.reset();
  });

  /// 发布"播放页封面盒 + 终点形状"。`shadowColor` 给上才可能画投影。
  void publishFull({
    double settledInsetRatio = 0.0,
    Color? shadowColor,
  }) {
    bus.publishFull(
      measured: box,
      logicalSize: const Size(720, 720),
      pageOffset: Offset.zero,
      songId: 's1',
      artworkUri: null,
      fallbackFilePath: null,
      iconSize: 48,
      placeholderColor: const Color(0xFF000000),
      shadowColor: shadowColor,
      eligible: true,
      settledArtworkScale: 1.0,
      settledArtworkAnchor: Alignment.center,
      settledInsetRatio: settledInsetRatio,
    );
    bus.publishMini(mini);
  }

  Future<void> pumpLayer(WidgetTester tester, double expansion) async {
    playerExpansion.value = expansion;
    await tester.pumpWidget(
      const MaterialApp(home: Stack(children: [PlayerCoverMorphLayer()])),
    );
    await tester.pump();
  }

  Finder layerClip() => find.descendant(
        of: find.byType(PlayerCoverMorphLayer),
        matching: find.byType(ClipRRect),
      );

  double localRadius(WidgetTester tester) =>
      (tester.widget<ClipRRect>(layerClip()).borderRadius as BorderRadius)
          .topLeft
          .x;

  /// 飞行封面本帧的屏幕矩形宽（Transform 矩阵里没有独立尺寸，用子树 SizedBox）。
  Size coverBoxSize(WidgetTester tester) {
    final sized = tester.widget<SizedBox>(
      find
          .ancestor(
            of: find.descendant(
              of: find.byType(PlayerCoverMorphLayer),
              matching: find.byType(PlayerArtworkImage),
            ),
            matching: find.byType(SizedBox),
          )
          .last,
    );
    return Size(sized.width ?? 0, sized.height ?? 0);
  }

  /// 飞行封面的 z 轴旋转（矩阵里的旋转角，单位弧度）。
  double coverRotation(WidgetTester tester) {
    final transform = tester.widget<Transform>(
      find
          .ancestor(
            of: find.descendant(
              of: find.byType(PlayerCoverMorphLayer),
              matching: find.byType(PlayerArtworkImage),
            ),
            matching: find.byType(Transform),
          )
          .first,
    );
    final m = transform.transform;
    return math.atan2(m.entry(1, 0), m.entry(0, 0));
  }

  group('圆盘终点几何', () {
    testWidgets('飞行盒按上报比例内缩，不是整个槽位盒', (tester) async {
      publishFull(settledInsetRatio: insetRatio);
      await pumpLayer(tester, 0.5);

      final size = coverBoxSize(tester);
      expect(size.width, closeTo(discWidth, 1e-6));
      expect(size.height, closeTo(discWidth, 1e-6));
    });

    testWidgets('方图路径（比例 0）仍是整盒，行为不变', (tester) async {
      publishFull();
      await pumpLayer(tester, 0.5);

      final size = coverBoxSize(tester);
      expect(size.width, closeTo(720, 1e-6));
    });

    /// 屏幕上真正生效的圆角 = 局部半径 × scale（子树被 Transform 缩放）。
    /// 边长与圆角都按**平抛的加速项** q = t² 走（见 coverMorphFlightRect）。
    double screenRadiusAt(WidgetTester tester, double targetWidth) =>
        localRadius(tester) * (targetWidth / discWidth);

    testWidgets('落位帧圆角 → 正圆（= 当前飞行矩形边长 / 2）', (tester) async {
      publishFull(settledInsetRatio: insetRatio);
      // p=0.99：终点矩形已几乎到位，圆角应逼近"当前边长的一半"
      await pumpLayer(tester, 0.99);

      final q = 0.99 * 0.99;
      final targetWidth = 44 + (discWidth - 44) * q;
      // 圆角与边长同拍（都吃 q），因此半径/边长≈0.5；留 1.5dp 容差
      expect(
        screenRadiusAt(tester, targetWidth),
        closeTo(targetWidth / 2, 1.5),
      );
    });

    testWidgets('方图落位帧圆角仍是 16dp（未回归）', (tester) async {
      publishFull();
      await pumpLayer(tester, 0.99);

      final scale = (44 + (720 - 44) * 0.99 * 0.99) / 720;
      expect(localRadius(tester) * scale, closeTo(kCoverMorphFullRadius, 0.3));
    });
  });

  group('唱片角接手', () {
    testWidgets('圆盘：落位帧角度 ≡ 共享相位', (tester) async {
      SpectrumDiscSpin.instance.debugSetAngle(1.0);
      publishFull(settledInsetRatio: insetRatio);
      await pumpLayer(tester, 0.999);

      // 起点角 0（常驻条不旋转）→ 终点 1.0 rad；倾角 sin(π·t) 在端点附近可忽略
      expect(
        coverRotation(tester),
        closeTo(1.0 + coverMorphTilt(0.999), 0.02),
      );
    });

    testWidgets('圆盘：起点角来自 MiniPlayer 上报（悬浮圆盘自转）', (tester) async {
      SpectrumDiscSpin.instance.debugSetAngle(2.0);
      bus.publishFull(
        measured: box,
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
        settledInsetRatio: insetRatio,
      );
      bus.publishMini(mini, cornerRadius: 28, rotation: 1.5);

      await pumpLayer(tester, 0.5);
      // t=0.5 落在两端之间（1.5 → 2.0），而非从 0 起跳
      final mid = coverRotation(tester);
      expect(mid, greaterThan(1.4));
      expect(mid, lessThan(2.1));
    });

    testWidgets('方图：仍是从起点角连续归零（旧行为）', (tester) async {
      SpectrumDiscSpin.instance.debugSetAngle(2.0);
      bus.publishFull(
        measured: box,
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
      );
      bus.publishMini(mini, cornerRadius: 28, rotation: 1.0);

      await pumpLayer(tester, 0.5);
      // 1.0 × (1 − 0.5) + 飞行倾角，与共享相位无关
      expect(
        coverRotation(tester),
        closeTo(1.0 * (1 - 0.5) + coverMorphTilt(0.5), 0.02),
      );
    });

    testWidgets('相位跨圈不跳变：两帧之间角度只前进一小步', (tester) async {
      // 起点角 0，相位 6.2（wrapPi 后 −0.083）：第一帧就该是短路径
      SpectrumDiscSpin.instance.debugSetAngle(6.2);
      publishFull(settledInsetRatio: insetRatio);
      await pumpLayer(tester, 0.5);
      final first = coverRotation(tester);

      // 相位回绕到 0.1（实际又前进 0.183 rad），累计角只能小步变化
      SpectrumDiscSpin.instance.debugSetAngle(0.1);
      playerExpansion.value = 0.52;
      await tester.pump();
      final second = coverRotation(tester);

      expect((second - first).abs(), lessThan(0.3));
    });
  });

  group('圆盘不画投影', () {
    testWidgets('比例 > 0：即使上报了 shadowColor 也不铺投影', (tester) async {
      publishFull(
        settledInsetRatio: insetRatio,
        shadowColor: const Color(0xFF000000),
      );
      await pumpLayer(tester, 0.6);

      expect(
        find.descendant(
          of: find.byType(PlayerCoverMorphLayer),
          matching: find.byType(DecoratedBox),
        ),
        findsNothing,
        reason: '真身 SpectrumArtwork 没有 PlayerCoverShadow，飞行期画投影会在交接帧凭空多出/消失',
      );
    });

    testWidgets('比例 0：方图路径照旧铺投影（未回归）', (tester) async {
      publishFull(shadowColor: const Color(0xFF000000));
      await pumpLayer(tester, 0.6);

      expect(
        find.descendant(
          of: find.byType(PlayerCoverMorphLayer),
          matching: find.byType(DecoratedBox),
        ),
        findsWidgets,
      );
    });
  });

  testWidgets('终点矩形尚未上报时不画（沿用既有守卫，不抛 NaN）', (tester) async {
    // 只上报迷你端：settledRect 为空，形变层必须早退
    bus.publishMini(mini);
    await pumpLayer(tester, 0.5);
    expect(layerClip(), findsNothing);
  });
}
