import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/modules/player/player_page_role.dart';

/// `PlayerPageRole` 的身份判定契约。
///
/// 本步只是把原先散在两个播放页里的
/// `ModalRoute.of(context) == null && playerDragActive.value` 收成一处，
/// 并允许挂载点显式声明身份，**行为必须逐位不变**——下面几条兜底用例就是那条「不变」的证据。
void main() {
  tearDown(() => playerDragActive.value = false);

  testWidgets('显式 scope 优先：三种身份各自读出', (tester) async {
    for (final role in PlayerPageRole.values) {
      PlayerPageRole? read;
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPageRoleScope(
            role: role,
            child: Builder(
              builder: (context) {
                read = PlayerPageRole.of(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      expect(read, role, reason: 'scope 写了 $role 就必须读出 $role');
    }
  });

  testWidgets('Navigator 之外、拖拽已激活 → dragOverlay（覆盖层的真实位置）', (
    tester,
  ) async {
    // 必须挂在**没有 Navigator** 的树里：`MaterialApp(home: …)` 自己就会造一条路由，
    // 那样读到 route 是对的，测不出兜底。跟手覆盖层正是挂在 Navigator 之上
    // （`app.dart` 的 Stack），所以旧推导成立的位置就是这里。
    playerDragActive.value = true;
    PlayerPageRole? read;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (context) {
            read = PlayerPageRole.of(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(
      read,
      PlayerPageRole.dragOverlay,
      reason: '这正是改动前 `_isDragOverlay` 为真的条件，兜底必须给出同一身份',
    );
  });

  testWidgets('Navigator 之外、拖拽未激活 → route（车机 dock 那类挂载点）', (
    tester,
  ) async {
    playerDragActive.value = false;
    PlayerPageRole? read;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (context) {
            read = PlayerPageRole.of(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(
      read,
      PlayerPageRole.route,
      reason: 'car_mode_panel 的 dockMode 播页走这一路：不该被当成覆盖层而漏掉副作用',
    );
  });

  testWidgets('在路由里读到 route，且与是否拖拽无关', (tester) async {
    playerDragActive.value = true;
    PlayerPageRole? read;
    await tester.pumpWidget(
      MaterialApp(
        home: Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (context) {
              read = PlayerPageRole.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      read,
      PlayerPageRole.route,
      reason: '有 ModalRoute 时即使拖拽激活也判 route，与改动前那条 && 逐位一致',
    );
  });

  test('updateShouldNotify 只在 role 变化时为真', () {
    // 通知语义没法靠 pumpWidget 测：换 role 时 child 也是新实例，
    // Builder 因父级重建而重建，读数与是否通知无关（我第一版就被这个假信号骗过）。
    // 直接测方法本身。
    Widget leaf() => const SizedBox.shrink();
    final route = PlayerPageRoleScope(role: PlayerPageRole.route, child: leaf());
    final sameRole = PlayerPageRoleScope(
      role: PlayerPageRole.route,
      child: leaf(),
    );
    final dormant = PlayerPageRoleScope(
      role: PlayerPageRole.dormant,
      child: leaf(),
    );

    expect(route.updateShouldNotify(sameRole), isFalse);
    expect(route.updateShouldNotify(dormant), isTrue);
  });
}
