import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/widgets/playback_hint_pills.dart';
import 'package:md3music/widgets/player_seek_bar.dart';

/// 时间行提示：口径矩阵 + 组内布局/配色。
///
/// 「缓冲中」与「音频过渡中」可同时出现，各自包一层圆角矩形、作为一组整体居中；
/// 判定矩阵收在 [PlaybackHintState.resolve]，这里不依赖 Provider / 音频服务。

PlaybackHintState _resolve({
  bool streamBuffering = false,
  bool hasError = false,
  bool crossfading = false,
  bool accompanying = false,
  bool accompanyLoading = false,
}) => PlaybackHintState.resolve(
  streamBuffering: streamBuffering,
  hasError: hasError,
  crossfading: crossfading,
  accompanying: accompanying,
  accompanyLoading: accompanyLoading,
);

Widget _host(PlaybackHintState state, {bool amStyle = false}) => MaterialApp(
  home: Scaffold(
    body: Center(child: PlaybackHintPills(state: state, amStyle: amStyle)),
  ),
);

/// 胶囊本体（组内包文字的那层 Container）。
Finder _pillBoxes() => find.descendant(
  of: find.byType(PlaybackHintPills),
  matching: find.byType(Container),
);

void main() {
  group('PlaybackHintState.resolve', () {
    test('音频流在准备数据 → 缓冲中', () {
      expect(_resolve(streamBuffering: true).buffering, isTrue);
    });

    test('不看播放态：拖动后被暂停、但仍在为落点缓冲 → 照样显示', () {
      // 拖动进度条会 pauseForSeek()，此时 isPlaying 为 false，而平台仍在
      // loading/buffering。这条口径必须与播放态解耦，否则整段缓冲会被吞掉。
      expect(_resolve(streamBuffering: true).buffering, isTrue);
    });

    test('播完 / 停止（isStreamBuffering 已排除 completed/idle）→ 不显示', () {
      expect(_resolve(streamBuffering: false).buffering, isFalse);
    });

    test('有错误在展示 → 不报缓冲中（错误条才是当时的真话）', () {
      expect(_resolve(streamBuffering: true, hasError: true).buffering, isFalse);
    });

    test('交叉淡化进行中 → 音频过渡中', () {
      final state = _resolve(crossfading: true);
      expect(state.fading, isTrue);
      expect(state.buffering, isFalse);
    });

    test('两条可同时成立，任一成立即 visible', () {
      final both = _resolve(streamBuffering: true, crossfading: true);
      expect(both.buffering, isTrue);
      expect(both.fading, isTrue);
      expect(both.visible, isTrue);
      expect(_resolve().visible, isFalse);
    });

    test('伴唱开启 → 伴唱中', () {
      final state = _resolve(accompanying: true);
      expect(state.accompanying, isTrue);
      expect(state.visible, isTrue);
    });

    test('伴唱与缓冲/过渡可同时成立', () {
      final state = _resolve(
        streamBuffering: true,
        crossfading: true,
        accompanying: true,
      );
      expect(state.buffering, isTrue);
      expect(state.fading, isTrue);
      expect(state.accompanying, isTrue);
    });

    test('伴唱加载中 → visible，且与「伴唱中」互斥', () {
      final loading = _resolve(accompanyLoading: true);
      expect(loading.accompanyLoading, isTrue);
      expect(loading.accompanying, isFalse, reason: '加载中不显示「伴唱中」');
      expect(loading.visible, isTrue);

      final both = _resolve(accompanyLoading: true, accompanying: true);
      expect(both.accompanyLoading, isTrue);
      expect(both.accompanying, isFalse);
    });
  });

  group('PlaybackHintPills', () {
    testWidgets('只有缓冲中：单枚胶囊，文案精确', (tester) async {
      await tester.pumpWidget(_host(_resolve(streamBuffering: true)));

      expect(find.text(PlaybackHintPills.bufferingLabel), findsOneWidget);
      expect(find.text(PlaybackHintPills.transitionLabel), findsNothing);
      expect(_pillBoxes(), findsOneWidget);
    });

    testWidgets('只有音频过渡中：单枚胶囊，文案精确', (tester) async {
      await tester.pumpWidget(_host(_resolve(crossfading: true)));

      expect(find.text(PlaybackHintPills.transitionLabel), findsOneWidget);
      expect(find.text(PlaybackHintPills.bufferingLabel), findsNothing);
      expect(_pillBoxes(), findsOneWidget);
    });

    testWidgets('两条同时出现：分别包裹、缓冲中在左', (tester) async {
      await tester.pumpWidget(
        _host(_resolve(streamBuffering: true, crossfading: true)),
      );

      expect(find.text(PlaybackHintPills.bufferingLabel), findsOneWidget);
      expect(find.text(PlaybackHintPills.transitionLabel), findsOneWidget);
      expect(_pillBoxes(), findsNWidgets(2), reason: '各包一层圆角矩形，不合并成一枚');
      expect(
        tester.getCenter(find.text(PlaybackHintPills.bufferingLabel)).dx,
        lessThan(
          tester.getCenter(find.text(PlaybackHintPills.transitionLabel)).dx,
        ),
      );
    });

    testWidgets('胶囊是定高圆角矩形，高度与时间行一致', (tester) async {
      await tester.pumpWidget(_host(_resolve(streamBuffering: true)));

      final box = tester.widget<Container>(_pillBoxes());
      final decoration = box.decoration! as BoxDecoration;
      expect(decoration.borderRadius, isNotNull);
      expect(decoration.color, isNotNull);
      expect(
        tester.getSize(_pillBoxes()).height,
        PlayerSeekBar.labelRowHeight,
        reason: '定高＝时间行高，提示出现/消失不会改变进度条总高',
      );
    });

    testWidgets('AM 深色皮肤：胶囊用白色系底与白字', (tester) async {
      await tester.pumpWidget(_host(_resolve(streamBuffering: true), amStyle: true));

      final decoration =
          tester.widget<Container>(_pillBoxes()).decoration! as BoxDecoration;
      expect(decoration.color, Colors.white.withValues(alpha: 0.16));
      expect(
        tester.widget<Text>(find.text(PlaybackHintPills.bufferingLabel)).style?.color,
        Colors.white,
      );
    });

    testWidgets('两条都不显示时整组收缩为空', (tester) async {
      await tester.pumpWidget(_host(_resolve()));

      expect(find.text(PlaybackHintPills.bufferingLabel), findsNothing);
      expect(find.text(PlaybackHintPills.transitionLabel), findsNothing);
      expect(
        tester.getSize(find.byType(PlaybackHintPills)),
        Size.zero,
        reason: '无提示不应占位',
      );
    });

    testWidgets('伴唱中：单枚胶囊，文案精确', (tester) async {
      await tester.pumpWidget(_host(_resolve(accompanying: true)));

      expect(find.text(PlaybackHintPills.accompanyingLabel), findsOneWidget);
      expect(find.text(PlaybackHintPills.bufferingLabel), findsNothing);
      expect(find.text(PlaybackHintPills.transitionLabel), findsNothing);
      expect(_pillBoxes(), findsOneWidget);
    });

    testWidgets('伴唱中与缓冲中同时出现：各包一层', (tester) async {
      await tester.pumpWidget(
        _host(_resolve(streamBuffering: true, accompanying: true)),
      );

      expect(find.text(PlaybackHintPills.bufferingLabel), findsOneWidget);
      expect(find.text(PlaybackHintPills.accompanyingLabel), findsOneWidget);
      expect(_pillBoxes(), findsNWidgets(2));
    });

    testWidgets('伴唱加载中：单枚胶囊，文案精确', (tester) async {
      await tester.pumpWidget(_host(_resolve(accompanyLoading: true)));

      expect(find.text(PlaybackHintPills.accompanyLoadingLabel), findsOneWidget);
      expect(find.text(PlaybackHintPills.accompanyingLabel), findsNothing);
      expect(_pillBoxes(), findsOneWidget);
    });
  });
}
