// MV 播放页 TV 遥控键位：可纯函数化的部分（seek 目标夹取）。
//
// 背景（见 lib/modules/player/mv_player_page.dart）：
//   - TV 全屏下左右键调进度（±10s），DpadFocusable.onDirection 接线；
//   - 目标位置必须夹取到 [0, duration]，否则 seekTo 传负值/越界时长。
// 键位映射本身在私有 State 的闭包里（onDirection/onSelect），整页 pump 需要
// VideoPlayerController 平台 mock（仓内无先例），故行为契约以真机验收为准
// （AGENTS §12.6），这里钉住可确定性的数学部分。

import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/modules/player/mv_player_page.dart';

void main() {
  group('mvTvSeekTarget 进度目标夹取', () {
    const duration = Duration(minutes: 4);

    test('中间位置正向步进：原样相加', () {
      expect(
        mvTvSeekTarget(const Duration(seconds: 60), duration, 10),
        const Duration(seconds: 70),
      );
    });

    test('中间位置反向步进：原样相减', () {
      expect(
        mvTvSeekTarget(const Duration(seconds: 60), duration, -10),
        const Duration(seconds: 50),
      );
    });

    test('反向越过起点：夹取到 0，不出现负值', () {
      expect(
        mvTvSeekTarget(const Duration(seconds: 3), duration, -10),
        Duration.zero,
      );
    });

    test('正向越过时长：夹取到 duration', () {
      expect(
        mvTvSeekTarget(const Duration(minutes: 3, seconds: 58), duration, 10),
        duration,
      );
    });

    test('恰好落在边界：0 与 duration 均不被推走', () {
      expect(
        mvTvSeekTarget(Duration.zero, duration, -10),
        Duration.zero,
      );
      expect(
        mvTvSeekTarget(duration, duration, 10),
        duration,
      );
    });

    test('时长为 0（控制器未上报）：只夹下界、不夹上界', () {
      expect(
        mvTvSeekTarget(const Duration(seconds: 5), Duration.zero, 10),
        const Duration(seconds: 15),
      );
      expect(
        mvTvSeekTarget(const Duration(seconds: 1), Duration.zero, -10),
        Duration.zero,
      );
    });
  });
}
