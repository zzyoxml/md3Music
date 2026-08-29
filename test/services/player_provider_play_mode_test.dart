import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/providers/player_provider.dart';

/// 合并后的播放模式单键循环。
///
/// 播放器底部原先是 shuffle + loop 两个按钮，现在合成一个循环按钮：
/// 不循环 → 列表循环 → 单曲循环 → 随机播放 → 不循环。
///
/// 覆盖范围说明：每个 PlayerProvider 实例只能断言一次切换。
/// `_applyLoopMode` / `toggleShuffle` 会 await just_audio 的平台调用，
/// 而 `_audioService` 在构造后的首个异步间隙才装配好——于是同一实例上的
/// 第二次切换会一直挂在没有平台实现的 channel 上（既有的 `toggleLoopMode`
/// 也是同样的性质）。要覆盖完整的四段循环需要给 AudioService 做测试替身，
/// 那属于另一件事，这里只钉住第一段跃迁。
void main() {
  testWidgets('默认态（不循环）切一次进入列表循环，且不打开随机', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final player = PlayerProvider();
    try {
      expect(player.loopMode, AppLoopMode.off, reason: '初始为不循环');
      expect(player.shuffleEnabled, isFalse);

      await player.cyclePlayMode();

      expect(player.loopMode, AppLoopMode.all, reason: '第 1 段 → 列表循环');
      expect(player.shuffleEnabled, isFalse, reason: '列表循环不应带上随机');
    } finally {
      player.dispose();
      await tester.pump(const Duration(seconds: 5));
    }
  });
}
