// tv: 遥控步进纯函数测试（进度钳制 + 切页钳制）。
//
// 这两个函数同时服务 MV 页与刷刷竖屏流：`onDirection` 返回 true 消费方向键，
// 一旦算出越界目标就会 seek 到负值/超时长，或把 PageController 甩到不存在页。
// 逻辑抽成纯函数按 AGENTS §3.3.1 的做法在此钉住，不依赖播放器状态。

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/remote/tv_seek_math.dart';

void main() {
  group('tvSeekTarget', () {
    test('正向步进落在时长内', () {
      expect(
        tvSeekTarget(const Duration(seconds: 30), const Duration(seconds: 100), 10),
        const Duration(seconds: 40),
      );
    });

    test('快进越过片尾时钳到 duration', () {
      expect(
        tvSeekTarget(const Duration(seconds: 95), const Duration(seconds: 100), 10),
        const Duration(seconds: 100),
      );
    });

    test('快退越过起点时钳到 0（不得为负）', () {
      expect(
        tvSeekTarget(const Duration(seconds: 3), const Duration(seconds: 100), -10),
        Duration.zero,
      );
    });

    test('时长未知（0）时只保证不为负', () {
      expect(
        tvSeekTarget(const Duration(seconds: 5), Duration.zero, -10),
        Duration.zero,
      );
      expect(
        tvSeekTarget(const Duration(seconds: 5), Duration.zero, 10),
        const Duration(seconds: 15),
      );
    });
  });

  group('tvPageTarget（刷刷上下键切视频）', () {
    test('中间页正常前进/后退', () {
      expect(tvPageTarget(3, 10, 1), 4);
      expect(tvPageTarget(3, 10, -1), 2);
    });

    test('首页按「上一个」停在 0', () {
      expect(tvPageTarget(0, 10, -1), 0);
    });

    test('末页按「下一个」停在末页（由调用方决定加载更多或提示）', () {
      expect(tvPageTarget(9, 10, 1), 9);
    });

    test('空列表不产生负下标', () {
      expect(tvPageTarget(0, 0, 1), 0);
      expect(tvPageTarget(0, 0, -1), 0);
    });
  });
}
