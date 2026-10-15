/// PlayerProvider 位置发布闸门接线测试（方案 A）。
///
/// 覆盖：换源装载期间（闸门开启）丢弃"位置从 0 重新计数"的假回退，seek 落地
/// 关闭闸门后恢复正常的进度发布。回归对象是"暂停后歌词从头滚到当前行"
/// （见 docs/2026-09-11-pause-lyric-scroll-from-top-analysis.md）。
///
/// 注意：测试环境没有音频平台实现，真实 `seek()` 会挂在无实现的 MethodChannel
/// 上（既有 provider 测试也只做构造后首个同步调用）。因此这里用
/// `debugFeedPositionForTest` 直接驱动位置发布通道，只验证闸门接线本身。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('装载期间抑制回退采样，seek 落地后恢复真实进度', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final player = PlayerProvider();
    try {
      // 播放到 60s（正常发布）
      player.debugFeedPositionForTest(const Duration(seconds: 60));
      expect(player.position, const Duration(seconds: 60));
      expect(player.positionNotifier.value, const Duration(seconds: 60));

      // 模拟 _setUrlAndPlay：装载新源前开启闸门（目标位置 60s）
      player.positionRewindGateForTest.arm(const Duration(seconds: 60));
      expect(player.positionRewindGateForTest.armed, isTrue);

      // 换源副作用：播放器位置从 0 重新计数 → 不得发布
      player.debugFeedPositionForTest(Duration.zero);
      expect(player.position, const Duration(seconds: 60),
          reason: '装载期间不得把回退采样发布给 UI');
      expect(player.positionNotifier.value, const Duration(seconds: 60),
          reason: 'positionNotifier 同样不得回退（进度条/歌词订阅它）');

      // 装载中的其它小值同样抑制
      player.debugFeedPositionForTest(const Duration(seconds: 3));
      expect(player.position, const Duration(seconds: 60));

      // 到达目标后的真实采样照常发布（不误伤装载窗口后段）
      player.debugFeedPositionForTest(const Duration(seconds: 61));
      expect(player.position, const Duration(seconds: 61));

      // seek 落地：闸门关闭
      player.positionRewindGateForTest.disarm();
      expect(player.positionRewindGateForTest.armed, isFalse);

      // 装载结束后的合法回退（用户拖动进度条 seek 回 10s）必须生效
      player.debugFeedPositionForTest(const Duration(seconds: 10));
      expect(player.position, const Duration(seconds: 10),
          reason: '闸门关闭后不得拦截合法 seek');
    } finally {
      player.dispose();
      await tester.pump(const Duration(seconds: 5));
    }
  });

  testWidgets('无明确 seek 目标时不开启闸门（新歌确实从 0 开始）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final player = PlayerProvider();
    try {
      player.positionRewindGateForTest.arm(Duration.zero);
      expect(player.positionRewindGateForTest.armed, isFalse);

      player.debugFeedPositionForTest(const Duration(seconds: 5));
      expect(player.position, const Duration(seconds: 5));
      player.debugFeedPositionForTest(Duration.zero);
      expect(player.position, Duration.zero, reason: '0 是真实进度，应正常发布');
    } finally {
      player.dispose();
      await tester.pump(const Duration(seconds: 5));
    }
  });
}
