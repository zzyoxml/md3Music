import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/providers/player_provider.dart';

/// 播放器「用户 seek」通告接线。
///
/// 背景：一起听的房主需要把拖动进度上报给房间（`player_operation action=2`），
/// 成员需要据此立刻复同步。全仓 `PlayerProvider.seek()` 的调用者只有 UI（8 处）
/// 与内部复位（4 处），因此内部复位必须显式抑制，不能被当作用户操作上报。
///
/// 注意：测试环境没有音频平台实现，`seek()` 内部的平台 await 会挂在无实现的
/// channel 上，所以**不能 await 整个 seek**；通告发生在 await 之前的同步前缀，
/// 用 `unawaited` 触发后立刻断言即可。
void main() {
  testWidgets('用户 seek 通告毫秒位置', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final player = PlayerProvider();
    final reported = <int>[];
    player.onSeekedByUser = reported.add;
    try {
      unawaited(player.seek(const Duration(seconds: 30)));
      expect(reported, [30000]);
    } finally {
      player.dispose();
      await tester.pump(const Duration(seconds: 5));
    }
  });

  testWidgets('抑制窗口内的 seek 不上报（远端纠偏不得被当成用户操作）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final player = PlayerProvider();
    final reported = <int>[];
    player.onSeekedByUser = reported.add;
    try {
      unawaited(player.suppressPlaybackNotify(() => player.seek(const Duration(seconds: 45))));
      expect(reported, isEmpty);
    } finally {
      player.dispose();
      await tester.pump(const Duration(seconds: 5));
    }
  });

  testWidgets('未注册回调时不抛异常', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final player = PlayerProvider();
    try {
      unawaited(player.seek(const Duration(seconds: 5)));
    } finally {
      player.dispose();
      await tester.pump(const Duration(seconds: 5));
    }
  });
}
