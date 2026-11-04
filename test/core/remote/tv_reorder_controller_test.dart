// TvReorderController 行为契约测试（纯逻辑，不依赖 kTvBuild / Flutter 绑定，
// AGENTS §12 惯例同 tv_volume_stepper_test.dart：状态机必须落在普通构建同样
// 编译得到的类里才能被单测钉住）。

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/remote/tv_reorder.dart';

/// 记录 onReorder 调用与 Toast 文案。
class _Log {
  final List<(int, int)> reorders = <(int, int)>[];
  final List<String> toasts = <String>[];
  final List<bool> longFlags = <bool>[];

  /// onReorder 出口（两参 → record，签名须与 TvReorderController.onReorder 一致）。
  void reorder(int oldIndex, int newIndex) => reorders.add((oldIndex, newIndex));

  /// onToast 出口（签名须与 TvReorderController.onToast 一致：带命名参数 long）。
  void toast(String msg, {bool long = false}) {
    toasts.add(msg);
    longFlags.add(long);
  }
}

void main() {
  group('TvReorderController', () {
    test('左键拿起：置位 carriedIndex 并 Toast 提示含歌名与操作说明', () {
      final _Log log = _Log();
      final controller = TvReorderController(
        itemCount: () => 3,
        onReorder: log.reorder,
        labelOf: (i) => '歌曲$i',
        onToast: (msg, {long = false}) {
          log.toasts.add(msg);
          log.longFlags.add(long);
        },
      );
      addTearDown(controller.dispose);

      expect(controller.handleDirection(1, TraversalDirection.left), isTrue);
      expect(controller.isCarrying, isTrue);
      expect(controller.carriedIndex, 1);
      expect(log.toasts.single, contains('歌曲1'));
      expect(log.toasts.single, contains('上下键'));
      expect(log.longFlags.single, isTrue, reason: '拿起提示要长显');
      expect(log.reorders, isEmpty, reason: '拿起本身不重排');
    });

    test('拿起后上下键移动：onReorder 按 ReorderableListView 语义下发', () {
      final _Log log = _Log();
      final controller = TvReorderController(
        itemCount: () => 3,
        onReorder: log.reorder,
        labelOf: (i) => '歌曲$i',
        onToast: log.toast,
      );
      addTearDown(controller.dispose);
      controller.handleDirection(0, TraversalDirection.left);

      controller.handleDirection(0, TraversalDirection.down);
      expect(log.reorders.single, (0, 2),
          reason: '向下移动一格：插入位 = 目标位 + 1');
      expect(controller.carriedIndex, 1, reason: ' carriedIndex 跟随新位置');

      controller.handleDirection(1, TraversalDirection.up);
      expect(log.reorders.last, (1, 0));
      expect(controller.carriedIndex, 0);
    });

    test('顶/底边界是空操作，不调用 onReorder', () {
      final _Log log = _Log();
      final controller = TvReorderController(
        itemCount: () => 2,
        onReorder: log.reorder,
        labelOf: (i) => '歌曲$i',
        onToast: log.toast,
      );
      addTearDown(controller.dispose);
      controller.handleDirection(0, TraversalDirection.left);
      controller.handleDirection(0, TraversalDirection.up);
      expect(log.reorders, isEmpty, reason: '已在顶部');
      controller.handleDirection(0, TraversalDirection.down);
      controller.handleDirection(1, TraversalDirection.down);
      expect(log.reorders.length, 1, reason: '只有第一次有效');
    });

    test('OK/左键放下：清空 carriedIndex 并 Toast', () {
      final _Log log = _Log();
      final controller = TvReorderController(
        itemCount: () => 3,
        onReorder: log.reorder,
        labelOf: (i) => '歌曲$i',
        onToast: log.toast,
      );
      addTearDown(controller.dispose);
      controller.handleDirection(2, TraversalDirection.left);
      expect(controller.handleDirection(2, TraversalDirection.left), isTrue,
          reason: '拿起态再按左键 = 放下');
      expect(controller.isCarrying, isFalse);
      expect(log.toasts.last, contains('放下'));
      expect(log.toasts.last, contains('歌曲2'));
    });

    test('未拿起时：右键与上下键放行（返回 false），左键才拿起', () {
      final _Log log = _Log();
      final controller = TvReorderController(
        itemCount: () => 3,
        onReorder: log.reorder,
        labelOf: (i) => '歌曲$i',
        onToast: log.toast,
      );
      addTearDown(controller.dispose);

      expect(controller.handleDirection(1, TraversalDirection.right), isFalse);
      expect(controller.handleDirection(1, TraversalDirection.up), isFalse);
      expect(controller.handleDirection(1, TraversalDirection.down), isFalse);
      expect(controller.isCarrying, isFalse);
    });

    test('索引越界保护：itemCount 收缩后不抛', () {
      int count = 3;
      final _Log log = _Log();
      final controller = TvReorderController(
        itemCount: () => count,
        onReorder: log.reorder,
        labelOf: (i) => i < count ? '歌曲$i' : '?',
        onToast: log.toast,
      );
      addTearDown(controller.dispose);
      controller.handleDirection(2, TraversalDirection.left);
      count = 1; // 列表被外部删短，拿起行（下标 2）已不存在
      controller.handleDirection(2, TraversalDirection.down);
      expect(log.reorders, isEmpty, reason: '拿起行已不存在：静默收手，不下发重排');
      expect(controller.isCarrying, isFalse, reason: '越界即收起');
      controller.drop();
      expect(controller.isCarrying, isFalse);
    });
  });
}
