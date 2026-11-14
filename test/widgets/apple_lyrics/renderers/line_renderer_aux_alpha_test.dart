import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/widgets/apple_lyrics/layout/lyric_layout.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/renderers/line_renderer.dart';

/// 副行 alpha 必须跟随「已播 / 未播歌词透明度」。
///
/// **背景（用户实测）**：副行 alpha 原本是固定的 `translationOpacity × 进度`，
/// 与 `playedOpacity / unplayedOpacity` 完全脱钩——拖透明度滑块时主行变了、
/// 副行纹丝不动。修法是让副行以「该行的档位 alpha」为基准再乘
/// `translationOpacity`，于是三层语义统一：
/// - 当前行：`playedOpacity × translationOpacity`
/// - 上方已播行（开关开启）：`aboveLineAlpha × translationOpacity`
/// - 下方未播行：`darkAlphaFor(factor) × translationOpacity`
///
/// 本文件钉的是 renderer 侧的 `_auxBaseAlpha`（副行 alpha 的唯一来源），
/// 它与 `blurBakedAlpha / blurAuxBakedAlpha` 的 2:1 关系共同保证「模糊态
/// 与清晰态里，副行都比主行暗一半」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() async {
    await LyricPreferences.instance.reset();
  });

  LineRenderer newRenderer() => LineRenderer();

  test('当前行档位 = playedOpacity（副行随之变化）', () async {
    final r = newRenderer();
    r.setLineState(
      isActive: true,
      scale: LyricLayout.activeScale,
      blurFade: 0,
      blurActive: false,
    );
    expect(
      r.auxBaseAlpha,
      closeTo(LyricLayout.playedOpacity, 1e-9),
      reason: '当前行满亮档位就是 playedOpacity',
    );

    await LyricPreferences.instance.setPlayedOpacity(
      LyricPreferences.minPlayedOpacityForCurrentPlatform,
    );
    r.setLineState(
      isActive: true,
      scale: LyricLayout.activeScale,
      blurFade: 0,
      blurActive: false,
    );
    expect(
      r.auxBaseAlpha,
      closeTo(LyricPreferences.minPlayedOpacityForCurrentPlatform, 1e-9),
      reason: '调低已播透明度后，当前行副行必须同步变暗',
    );
  });

  test('未播行档位跟随 unplayedOpacity（而非固定值）', () async {
    final r = newRenderer();
    r.setLineState(
      isActive: false,
      scale: LyricLayout.inactiveScale,
      blurFade: 0,
      blurActive: false,
    );
    final double before = r.auxBaseAlpha;

    await LyricPreferences.instance.setUnplayedOpacity(
      LyricPreferences.maxUnplayedOpacityForCurrentPlatform,
    );
    r.setLineState(
      isActive: false,
      scale: LyricLayout.inactiveScale,
      blurFade: 0,
      blurActive: false,
    );
    expect(
      r.auxBaseAlpha,
      isNot(closeTo(before, 1e-6)),
      reason: '未播透明度变化必须反映到副行档位',
    );
  });

  test('上方已播行档位 = aboveLineAlpha（开关语义）', () {
    final r = newRenderer();
    r.setLineState(
      isActive: false,
      scale: LyricLayout.inactiveScale,
      blurFade: 0,
      blurActive: false,
      isAboveCurrent: true,
    );
    expect(r.auxBaseAlpha, closeTo(LyricLayout.aboveLineAlpha, 1e-9));
  });

  test('档位 alpha 不含模糊淡出：blurFade 变化不改副行基准', () {
    final r = newRenderer();
    r.setLineState(
      isActive: false,
      scale: LyricLayout.inactiveScale,
      blurFade: 0,
      blurActive: false,
    );
    final double noFade = r.auxBaseAlpha;
    r.setLineState(
      isActive: false,
      scale: LyricLayout.inactiveScale,
      blurFade: 1,
      blurActive: true,
    );
    expect(
      r.auxBaseAlpha,
      closeTo(noFade, 1e-9),
      reason: '副行基准不能跟 blurFade 走，否则切行时副行模糊图未就绪会整行闪空',
    );
    // 但主行目标 alpha 必须被模糊淡出压到 0（清晰层由模糊层接管）
    expect(r.targetAlpha, closeTo(0, 1e-6));
  });

  test('模糊烘焙 alpha：副行是主行的一半', () {
    expect(LyricLayout.blurBakedAlpha, 0.5);
    expect(
      LyricLayout.blurAuxBakedAlpha,
      closeTo(LyricLayout.blurBakedAlpha * LyricLayout.translationOpacity, 1e-9),
    );
    expect(
      LyricLayout.blurAuxBakedAlpha,
      lessThan(LyricLayout.blurBakedAlpha),
      reason: '模糊态下副行必须比主行暗，否则调透明度时层次错乱',
    );
  });
}
