import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/layout/responsive_layout.dart';

/// 「封面连贯过渡」与「预测性返回手势」互斥的裁决。
///
/// 为什么要互斥（真机实测）：两者同开时，pop 期间预测性返回会在飞行途中改写被弹出
/// 路由的动画/尺寸，而框架 Hero 给飞行封面的盒子按起飞那一刻的 navigatorSize 冻结
/// 换算，中途变的尺寸只能整体拉伸封面 → 退场「抽搐一下」。
///
/// 互斥在两个地方执行，都必须过这个纯函数：设置页两个开关的 onChanged、
/// `lib/app.dart` 的冷启动载入（纠正存量同开状态并写回持久化）。
void main() {
  group('resolveCoverBackExclusivity', () {
    test('两个都想要时只保留封面连贯过渡（封面优先）', () {
      final r = resolveCoverBackExclusivity(
        coverTransition: true,
        predictiveBack: true,
      );
      expect(r.coverTransition, isTrue);
      expect(r.predictiveBack, isFalse);
    });

    test('用户只要预测性返回时原样保留（不反向抢开封面）', () {
      // 设置页把「本次开关动作」映射到对应参数：开预测性返回时传进来的
      // coverTransition 已是当前持久化值，两者不会同时为 true。
      final r = resolveCoverBackExclusivity(
        coverTransition: false,
        predictiveBack: true,
      );
      expect(r.predictiveBack, isTrue);
      expect(r.coverTransition, isFalse);
    });

    test('两个都关时原样返回（不擅自开任何一个）', () {
      final r = resolveCoverBackExclusivity(
        coverTransition: false,
        predictiveBack: false,
      );
      expect(r.coverTransition, isFalse);
      expect(r.predictiveBack, isFalse);
    });

    test('结果永不同时为开（互斥不变量）', () {
      for (final c in [true, false]) {
        for (final p in [true, false]) {
          final r = resolveCoverBackExclusivity(
            coverTransition: c,
            predictiveBack: p,
          );
          expect(
            r.coverTransition && r.predictiveBack,
            isFalse,
            reason: 'coverTransition=$c predictiveBack=$p 仍解析为同开',
          );
        }
      }
    });
  });
}
