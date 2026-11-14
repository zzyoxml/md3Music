import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// LyricPreferences「已播字上浮高度」参数的单元测试。
///
/// 锁定三件事：
/// 1. 默认值按平台生效（ForCurrentPlatform）；
/// 2. 越界输入被 clamp 到当前平台范围；
/// 3. setter 落盘到约定的 SharedPreferences key（改名会静默丢用户设置）。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    addTearDown(() => LyricPreferences.instance.reset());
  });

  group('① 已播字上浮高度 liftHeightPx', () {
    test('默认值按平台生效', () {
      expect(LyricPreferences.instance.liftHeightPx,
          equals(LyricPreferences.defaultLiftHeightPxForCurrentPlatform));
    });

    test('setter 生效并 clamp 到当前平台范围', () async {
      final mid = (LyricPreferences.minLiftHeightPxForCurrentPlatform +
              LyricPreferences.maxLiftHeightPxForCurrentPlatform) /
          2;
      await LyricPreferences.instance.setLiftHeightPx(mid);
      expect(LyricPreferences.instance.liftHeightPx, closeTo(mid, 1e-9));

      await LyricPreferences.instance.setLiftHeightPx(999);
      expect(LyricPreferences.instance.liftHeightPx,
          equals(LyricPreferences.maxLiftHeightPxForCurrentPlatform));

      await LyricPreferences.instance.setLiftHeightPx(-5);
      expect(LyricPreferences.instance.liftHeightPx,
          equals(LyricPreferences.minLiftHeightPxForCurrentPlatform));
    });

    test('持久化到 lyric_lift_height_px', () async {
      // 取上沿（不等于默认值），避免同值早退导致未落盘
      final target = LyricPreferences.maxLiftHeightPxForCurrentPlatform;
      await LyricPreferences.instance.setLiftHeightPx(target);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('lyric_lift_height_px'), closeTo(target, 1e-9));
    });

    test('reset 后回到默认值且 key 被移除', () async {
      await LyricPreferences.instance.setLiftHeightPx(
          LyricPreferences.maxLiftHeightPxForCurrentPlatform);

      await LyricPreferences.instance.reset();

      expect(LyricPreferences.instance.liftHeightPx,
          equals(LyricPreferences.defaultLiftHeightPxForCurrentPlatform));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('lyric_lift_height_px'), isNull);
    });
  });

  group('④ 级联错峰起点 staggerFromCurrentLine', () {
    test('默认 true（从当前行开始错峰）', () {
      expect(LyricPreferences.instance.staggerFromCurrentLine, isTrue);
      expect(LyricPreferences.instance.staggerFromCurrentLine,
          equals(LyricPreferences.defaultStaggerFromCurrentLine));
    });

    test('setter 落盘到 lyric_stagger_from_current', () async {
      await LyricPreferences.instance.setStaggerFromCurrentLine(false);
      expect(LyricPreferences.instance.staggerFromCurrentLine, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('lyric_stagger_from_current'), isFalse);
    });

    test('reset 后回到默认 true 且 key 被移除', () async {
      await LyricPreferences.instance.setStaggerFromCurrentLine(false);
      await LyricPreferences.instance.reset();
      expect(LyricPreferences.instance.staggerFromCurrentLine, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('lyric_stagger_from_current'), isNull);
    });
  });

  group('⑥ 预启动提前量微调 preStartBiasMs', () {
    test('默认 0（恰在边界释放，不引入额外提前）', () {
      expect(LyricPreferences.instance.preStartBiasMs,
          equals(LyricPreferences.defaultPreStartBiasMs));
      expect(LyricPreferences.instance.preStartBiasMs, equals(0.0));
    });

    test('setter 生效并 clamp 到 [0, 300]', () async {
      await LyricPreferences.instance.setPreStartBiasMs(120);
      expect(LyricPreferences.instance.preStartBiasMs, equals(120.0));

      await LyricPreferences.instance.setPreStartBiasMs(999);
      expect(LyricPreferences.instance.preStartBiasMs,
          equals(LyricPreferences.maxPreStartBiasMs));

      await LyricPreferences.instance.setPreStartBiasMs(-5);
      expect(LyricPreferences.instance.preStartBiasMs,
          equals(LyricPreferences.minPreStartBiasMs));
    });

    test('持久化到 lyric_prestart_bias_ms', () async {
      await LyricPreferences.instance.setPreStartBiasMs(80);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('lyric_prestart_bias_ms'), equals(80.0));
    });

    test('reset 后回到默认 0 且 key 被移除', () async {
      await LyricPreferences.instance.setPreStartBiasMs(150);
      await LyricPreferences.instance.reset();
      expect(LyricPreferences.instance.preStartBiasMs, equals(0.0));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('lyric_prestart_bias_ms'), isNull);
    });
  });

  /// 字内渐变模型（classic / sweep 二选一）：默认 sweep、可持久化、reset 复位。
  ///
  /// sweep 为 myune 扫光移植，现为默认观感；classic 为本仓原有宽过渡带。
  group('⑤ 字内渐变样式 fillMode', () {
    test('默认 sweep（扫光）', () {
      expect(LyricPreferences.instance.fillMode, LyricFillMode.sweep);
    });

    test('setFillMode 生效并 notifyListeners', () async {
      int notified = 0;
      void listener() => notified++;
      LyricPreferences.instance.addListener(listener);
      addTearDown(() => LyricPreferences.instance.removeListener(listener));

      await LyricPreferences.instance.setFillMode(LyricFillMode.classic);
      expect(LyricPreferences.instance.fillMode, LyricFillMode.classic);
      expect(notified, 1, reason: '值变化必须通知，歌词视图才能切到指定渐变模型');

      // 同值写入不再通知（沿用仓内 setter 的门控写法）
      await LyricPreferences.instance.setFillMode(LyricFillMode.classic);
      expect(notified, 1);
    });

    test('持久化到 lyric_fill_mode', () async {
      await LyricPreferences.instance.setFillMode(LyricFillMode.classic);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lyric_fill_mode'), 'classic');
    });

    test('load 读取已持久化的 lyric_fill_mode=sweep', () async {
      // 注意：LyricPreferences 是单例且 load() 有 _loaded 门控（同 isolate 只会
      // 真正读盘一次），故本文件只有这一处调用 load()；未知 / 缺失值回落 sweep
      // 由 `_fillModeFromName`（仅 'classic' → classic）保证。
      SharedPreferences.setMockInitialValues(<String, Object>{
        'lyric_fill_mode': 'sweep',
      });
      await LyricPreferences.instance.load();
      expect(LyricPreferences.instance.fillMode, LyricFillMode.sweep);
    });

    test('reset 置 sweep 且 key 被移除', () async {
      await LyricPreferences.instance.setFillMode(LyricFillMode.classic);
      await LyricPreferences.instance.reset();
      expect(LyricPreferences.instance.fillMode, LyricFillMode.sweep);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lyric_fill_mode'), isNull);
    });
  });

  /// 动态颜色混色比例：默认 0.15（= 历史 85% 白 + 15% 主色），可调 0~1。
  group('⑥ 动态颜色混色比例 dynamicColorMixRatio', () {
    test('默认 0.15（等于历史观感）', () {
      expect(LyricPreferences.instance.dynamicColorMixRatio,
          equals(LyricPreferences.defaultDynamicColorMixRatio));
      expect(LyricPreferences.instance.dynamicColorMixRatio, equals(0.15));
    });

    test('setter 生效并 clamp 到当前平台范围', () async {
      final hi = LyricPreferences.maxDynamicColorMixRatioForCurrentPlatform;
      final lo = LyricPreferences.minDynamicColorMixRatioForCurrentPlatform;
      await LyricPreferences.instance.setDynamicColorMixRatio(hi);
      expect(LyricPreferences.instance.dynamicColorMixRatio, equals(hi));

      await LyricPreferences.instance.setDynamicColorMixRatio(99);
      expect(LyricPreferences.instance.dynamicColorMixRatio, equals(hi));

      await LyricPreferences.instance.setDynamicColorMixRatio(-5);
      expect(LyricPreferences.instance.dynamicColorMixRatio, equals(lo));
    });

    test('持久化到 lyric_dynamic_color_mix_ratio', () async {
      final target =
          LyricPreferences.maxDynamicColorMixRatioForCurrentPlatform;
      await LyricPreferences.instance.setDynamicColorMixRatio(target);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('lyric_dynamic_color_mix_ratio'), equals(target));
    });

    test('reset 后回到默认值且 key 被移除', () async {
      await LyricPreferences.instance.setDynamicColorMixRatio(
          LyricPreferences.minDynamicColorMixRatioForCurrentPlatform);
      await LyricPreferences.instance.reset();
      expect(LyricPreferences.instance.dynamicColorMixRatio,
          equals(LyricPreferences.defaultDynamicColorMixRatioForCurrentPlatform));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('lyric_dynamic_color_mix_ratio'), isNull);
    });
  });

  /// 上方已播行跟随已播颜色：独立开关，默认关闭（= 历史白色背景行）。
  group('⑦ 上方行使用已播颜色 useAboveLinesPlayedColor', () {
    test('默认关闭', () {
      expect(LyricPreferences.instance.useAboveLinesPlayedColor, isFalse);
      expect(LyricPreferences.instance.useAboveLinesPlayedColor,
          equals(LyricPreferences.defaultUseAboveLinesPlayedColor));
    });

    test('setter 落盘到 lyric_above_lines_played_color', () async {
      await LyricPreferences.instance.setUseAboveLinesPlayedColor(true);
      expect(LyricPreferences.instance.useAboveLinesPlayedColor, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('lyric_above_lines_played_color'), isTrue);
    });

    test('reset 后回到默认关闭且 key 被移除', () async {
      await LyricPreferences.instance.setUseAboveLinesPlayedColor(true);
      await LyricPreferences.instance.reset();
      expect(LyricPreferences.instance.useAboveLinesPlayedColor, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('lyric_above_lines_played_color'), isNull);
    });
  });

  /// 间奏点（节奏点）自定义：水平起点 / 单点半径 / 点间距，均为 × 字号系数。
  ///
  /// 默认值 = 历史写死值（1.5 / 0.18 / 0.9），保证升级用户视觉不变；
  /// 渲染侧在 _LyricsPainter.paint 即时读取，setter 通知是拖滑块实时生效的前提。
  group('⑧ 间奏点自定义 interludeDots*', () {
    test('默认值为当前平台中轴值', () {
      expect(LyricPreferences.instance.interludeDotsStartX,
          equals(LyricPreferences.defaultInterludeDotsStartXForCurrentPlatform));
      expect(LyricPreferences.instance.interludeDotRadius,
          equals(LyricPreferences.defaultInterludeDotRadiusForCurrentPlatform));
      expect(LyricPreferences.instance.interludeDotSpacing,
          equals(LyricPreferences.defaultInterludeDotSpacingForCurrentPlatform));
      // 两平台默认值一致（1.5 / 0.18 / 0.9）
      expect(LyricPreferences.instance.interludeDotsStartX, equals(1.5));
      expect(LyricPreferences.instance.interludeDotRadius, equals(0.18));
      expect(LyricPreferences.instance.interludeDotSpacing, equals(0.9));
    });

    test('setter 生效并 clamp 到当前平台范围', () async {
      final hiX = LyricPreferences.maxInterludeDotsStartXForCurrentPlatform;
      final loX = LyricPreferences.minInterludeDotsStartXForCurrentPlatform;
      await LyricPreferences.instance.setInterludeDotsStartX(hiX);
      expect(LyricPreferences.instance.interludeDotsStartX, equals(hiX));
      await LyricPreferences.instance.setInterludeDotsStartX(99);
      expect(LyricPreferences.instance.interludeDotsStartX, equals(hiX));
      await LyricPreferences.instance.setInterludeDotsStartX(-1);
      expect(LyricPreferences.instance.interludeDotsStartX, equals(loX));

      final hiR = LyricPreferences.maxInterludeDotRadiusForCurrentPlatform;
      final loR = LyricPreferences.minInterludeDotRadiusForCurrentPlatform;
      await LyricPreferences.instance.setInterludeDotRadius(hiR);
      expect(LyricPreferences.instance.interludeDotRadius, equals(hiR));
      await LyricPreferences.instance.setInterludeDotRadius(99);
      expect(LyricPreferences.instance.interludeDotRadius, equals(hiR));
      await LyricPreferences.instance.setInterludeDotRadius(0);
      expect(LyricPreferences.instance.interludeDotRadius, equals(loR));

      final hiS = LyricPreferences.maxInterludeDotSpacingForCurrentPlatform;
      await LyricPreferences.instance.setInterludeDotSpacing(hiS);
      expect(LyricPreferences.instance.interludeDotSpacing, equals(hiS));
      await LyricPreferences.instance.setInterludeDotSpacing(99);
      expect(LyricPreferences.instance.interludeDotSpacing, equals(hiS));
      await LyricPreferences.instance.setInterludeDotSpacing(0);
      expect(LyricPreferences.instance.interludeDotSpacing,
          equals(LyricPreferences.minInterludeDotSpacing));
    });

    test('setter 值变化时 notifyListeners 且同值不重复通知', () async {
      int notified = 0;
      void listener() => notified++;
      LyricPreferences.instance.addListener(listener);
      addTearDown(() => LyricPreferences.instance.removeListener(listener));

      await LyricPreferences.instance.setInterludeDotRadius(0.25);
      expect(notified, 1,
          reason: '值变化必须通知，间奏点才能随滑块实时变化');

      await LyricPreferences.instance.setInterludeDotRadius(0.25);
      expect(notified, 1);
    });

    test('持久化到 lyric_interlude_dots_start_x / _dot_radius / _dot_spacing',
        () async {
      // 取非默认值（上沿附近），确保真正落盘
      await LyricPreferences.instance
          .setInterludeDotsStartX(2.25);
      await LyricPreferences.instance.setInterludeDotRadius(0.22);
      await LyricPreferences.instance.setInterludeDotSpacing(1.1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('lyric_interlude_dots_start_x'), equals(2.25));
      expect(prefs.getDouble('lyric_interlude_dot_radius'), equals(0.22));
      expect(prefs.getDouble('lyric_interlude_dot_spacing'), equals(1.1));
    });

    test('reset 后回到默认值且 key 被移除', () async {
      await LyricPreferences.instance
          .setInterludeDotsStartX(LyricPreferences.maxInterludeDotsStartXForCurrentPlatform);
      await LyricPreferences.instance.setInterludeDotRadius(
          LyricPreferences.maxInterludeDotRadiusForCurrentPlatform);
      await LyricPreferences.instance.setInterludeDotSpacing(
          LyricPreferences.maxInterludeDotSpacingForCurrentPlatform);

      await LyricPreferences.instance.reset();

      expect(LyricPreferences.instance.interludeDotsStartX,
          equals(LyricPreferences.defaultInterludeDotsStartXForCurrentPlatform));
      expect(LyricPreferences.instance.interludeDotRadius,
          equals(LyricPreferences.defaultInterludeDotRadiusForCurrentPlatform));
      expect(LyricPreferences.instance.interludeDotSpacing,
          equals(LyricPreferences.defaultInterludeDotSpacingForCurrentPlatform));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('lyric_interlude_dots_start_x'), isNull);
      expect(prefs.getDouble('lyric_interlude_dot_radius'), isNull);
      expect(prefs.getDouble('lyric_interlude_dot_spacing'), isNull);
    });
  });

  /// 已播 / 未播歌词透明度：满 factor 目标 alpha，默认复刻历史观感。
  group('⑨ 已播 / 未播歌词透明度 playedOpacity / unplayedOpacity', () {
    test('默认值为 100% / 40%，范围为 0~100%', () {
      expect(LyricPreferences.instance.playedOpacity, 1.0);
      expect(LyricPreferences.instance.unplayedOpacity, 0.4);
      expect(LyricPreferences.minPlayedOpacityForCurrentPlatform, 0.0);
      expect(LyricPreferences.maxPlayedOpacityForCurrentPlatform, 1.0);
      expect(LyricPreferences.minUnplayedOpacityForCurrentPlatform, 0.0);
      expect(LyricPreferences.maxUnplayedOpacityForCurrentPlatform, 1.0);
    });

    test('setter 生效并 clamp 到 [0, 1]', () async {
      await LyricPreferences.instance.setPlayedOpacity(0.37);
      expect(LyricPreferences.instance.playedOpacity, closeTo(0.37, 1e-9));
      await LyricPreferences.instance.setPlayedOpacity(999);
      expect(LyricPreferences.instance.playedOpacity, 1.0);
      await LyricPreferences.instance.setPlayedOpacity(-5);
      expect(LyricPreferences.instance.playedOpacity, 0.0);

      await LyricPreferences.instance.setUnplayedOpacity(-5);
      expect(LyricPreferences.instance.unplayedOpacity, 0.0);
      await LyricPreferences.instance.setUnplayedOpacity(999);
      expect(LyricPreferences.instance.unplayedOpacity, 1.0);
    });

    test('持久化到 lyric_played_opacity / lyric_unplayed_opacity', () async {
      await LyricPreferences.instance.setPlayedOpacity(0.37);
      await LyricPreferences.instance.setUnplayedOpacity(0.62);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('lyric_played_opacity'), closeTo(0.37, 1e-9));
      expect(prefs.getDouble('lyric_unplayed_opacity'), closeTo(0.62, 1e-9));
    });

    test('reset 后回到默认值且 key 被移除', () async {
      await LyricPreferences.instance.setPlayedOpacity(0.37);
      await LyricPreferences.instance.setUnplayedOpacity(0.62);
      await LyricPreferences.instance.reset();
      expect(LyricPreferences.instance.playedOpacity, 1.0);
      expect(LyricPreferences.instance.unplayedOpacity, 0.4);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('lyric_played_opacity'), isNull);
      expect(prefs.getDouble('lyric_unplayed_opacity'), isNull);
    });
  });
}
