// 播放页音质选择弹窗测试。
//
// 回归点：SimpleDialog 列表 → 竖向 M3E 挤压按钮组（与设置页「深色模式」同款
// m3e_core 组件），并保持"选中即关弹窗 + 回调带正确音质值"的行为。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';

import 'package:md3music/modules/player/audio_quality_dialog.dart';
import 'package:md3music/providers/player_provider.dart' show AudioQuality;
import 'package:md3music/widgets/m3e_vertical_squish_group.dart';

void main() {
  Widget host({
    required AudioQuality selected,
    required ValueChanged<AudioQuality> onSelected,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showAudioQualityDialog(
                context: context,
                qualities: kPlayerAudioQualities,
                selected: selected,
                onSelected: onSelected,
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
  }

  test('短标签覆盖全部音质档位', () {
    for (final q in AudioQuality.values) {
      expect(audioQualityShortLabel(q), isNotEmpty);
    }
    expect(audioQualityShortLabel(AudioQuality.standard), '标准');
    expect(audioQualityShortLabel(AudioQuality.viper), '蝰蛇母带');
  });

  test('kPlayerAudioQualities 是 standard/high/flac/hires 四档', () {
    expect(kPlayerAudioQualities, [
      AudioQuality.standard,
      AudioQuality.high,
      AudioQuality.flac,
      AudioQuality.hires,
    ]);
  });

  testWidgets('渲染成竖向 m3e 按钮组而不是 SimpleDialog 列表', (tester) async {
    await tester.pumpWidget(host(selected: AudioQuality.flac, onSelected: (_) {}));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('音质选择'), findsOneWidget);
    expect(find.byType(M3EToggleButton), findsNWidgets(4));
    expect(find.byType(M3EVerticalSquishGroup), findsOneWidget);
    for (final label in ['标准', '高品质', '无损', 'Hi-Res']) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('点某档：回调该音质并关闭弹窗', (tester) async {
    final picked = <AudioQuality>[];
    await tester.pumpWidget(host(
      selected: AudioQuality.standard,
      onSelected: picked.add,
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('无损'));
    await tester.pumpAndSettle();

    expect(picked, [AudioQuality.flac]);
    expect(find.text('音质选择'), findsNothing);
  });
}
