# MiniPlayer ↔ FullPlayer 拖拽过渡动画 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 MiniPlayer 与 FullPlayer 之间的切换添加完整的拖拽驱动过渡动画：从 MiniPlayer 向上拖拽抽屉式拉出 FullPlayer，从 FullPlayer 顶部把手向下拖拽收回到 MiniPlayer，过渡全程伴随与拖拽距离线性相关的淡入淡出动画。

**Architecture:** 引入一个全局 `ValueNotifier<double> playerExpansion`（0.0=mini，1.0=full）作为单一进度源。自定义 `DraggablePlayerRoute`（PageRoute 子类）持有手动可控的 `AnimationController`，其 `buildTransitions` 用进度驱动 FullPlayer 的 `Opacity + SlideTransition`；MiniPlayer 用 `1 - progress` 驱动自身淡出。MiniPlayer 与 FullPlayer 顶栏把手各自挂载垂直拖动手势，按下时 push 路由（若未存在），拖动时直接 set controller.value，释放时按阈值/速度 fling。释放后的剩余动画用 controller 自带 `fling`/`forward`/`reverse`，物理感更自然且无需额外 spring。删除 `AmStyleFullPlayer` 内部的 `_buildMiniBar`/`_expansionSpring`/`_dragDistance`（双重 mini bar bug 来源），由全局 MiniPlayer 独占 mini 状态。

**Tech Stack:** Flutter (Material)，`AnimationController` + `ValueNotifier`，现有 `lib/widgets/apple_lyrics/animation/spring.dart` 不再用于此处（改用 controller.fling 物理动画）。

---

## 文件结构

需要修改的文件：

- **修改** `lib/modules/player/full_player_route.dart`
  - 职责：定义 `DraggablePlayerRoute`（自定义 PageRoute）+ 全局 `playerExpansion` 进度 Notifier + `fullPlayerRoute` 工厂函数（返回新路由）。
  - 改动类型：重写文件，删除旧 `BottomSlideMaterialPageRoute` 与 `isFullPlayerOnTop` bool，替换为 double 进度。

- **修改** `lib/modules/player/mini_player.dart`
  - 职责：把 `MiniPlayer` 从 `StatelessWidget` 改为 `StatefulWidget`，添加垂直拖拽手势，opacity 跟随 `playerExpansion`。
  - 改动类型：重写 build 逻辑、新增 `_dragStartY`/`_route` 字段。

- **修改** `lib/modules/player/full_player_am.dart`
  - 职责：删除内部 `_buildMiniBar`/`_expansionSpring`/`_dragDistance`/`_springTicker` 等 Task 19 残留，改用 `ModalRoute.of(context).animation` 驱动；把手拖动手势改为驱动路由 controller。
  - 改动类型：大改 build 方法 + 删除若干私有方法/字段。

- **修改** `lib/modules/player/full_player.dart`
  - 职责：非 AM 风格 FullPlayer 顶部增加下拉把手，把手拖动手势驱动路由 controller；保留现有功能。
  - 改动类型：新增 `_buildTopBarWithDragHandle` 方法、`_dragStartY` 字段。

需要新建的文件：无（全部修改现有文件，遵循「不创建多余文件」原则）。

---

## 关键设计决策

### 1. 单一进度源 `playerExpansion`

全局 `ValueNotifier<double> playerExpansion`（0.0=mini，1.0=full）是单一来源：
- 路由 `buildTransitions` 在 controller.addListener 中同步值到 notifier
- MiniPlayer 用 `ValueListenableBuilder<double>` 监听，opacity = `1 - progress`
- FullPlayer 内部不需要监听（由路由 buildTransitions 外层包 `Opacity`/`SlideTransition`）

### 2. 路由控制器手动驱动模式

`DraggablePlayerRoute.createAnimationController` 返回一个普通 `AnimationController`（duration=300ms，lowerBound=0，upperBound=1）。在拖动期间：
- 调用 `controller.stop()` 暂停默认动画
- 调用 `controller.value = computedProgress` 直接设置进度
- 释放时调用 `controller.fling(velocity: v)` 或 `controller.forward()`/`controller.reverse()`
- `controller.value < 0.5` 时 reverse 完成后 pop；`>= 0.5` 时 forward 完成

### 3. 拖拽阈值与进度映射

- 拖拽距离阈值 `kDragThreshold = 220.0`（px）：拖动 220px 即达到全进度
- 进度计算：`progress = (dragDistance / kDragThreshold).clamp(0.0, 1.0)`
  - MiniPlayer 拖上：`dragDistance = -累计dy`（向上为正）
  - FullPlayer 把手拖下：`dragDistance = 累计dy`（向下为正），进度 = `1 - dragDistance/threshold`
- 释放阈值：进度 > 0.5 或速度方向一致 → 完成展开/收起；否则回退

### 4. 路由背景透明，不阻挡下层

`DraggablePlayerRoute.opaque = false`，`barrierColor = null`。这样：
- progress=0 时，FullPlayer opacity=0，下层 MiniPlayer 完全可见
- progress=0.5 时，两者各半透明（交叉淡入淡出）
- progress=1 时，FullPlayer opacity=1（其内部 Scaffold backgroundColor=Colors.black 已不透明），完全遮盖下层

### 5. 滑动距离

FullPlayer 在 `buildTransitions` 中被 `SlideTransition` 包裹：
- `begin: Offset(0, 0.15)`（向下偏 15% 屏幕高度）→ `end: Offset.zero`
- 让"抽屉拉出"的感觉更明显，但仍以淡入为主（用户要求"淡入淡出效果取决于拉动距离"，slide 只是辅助）

### 6. AM 风格 FullPlayer 简化

`AmStyleFullPlayer` 原有的内部 mini bar 与 spring 机制是路由不可见时为 mini 状态做的 fallback，现在路由全程透明、由全局 MiniPlayer 接管 mini 状态后，这套机制成为「双重 mini bar bug」的来源，全部删除。`AmStyleFullPlayer` 只负责构建 full layout。

---

## Task 1: 重写 `full_player_route.dart`，引入 `playerExpansion` + `DraggablePlayerRoute`

**Files:**
- Modify: `lib/modules/player/full_player_route.dart`（整体重写）

- [ ] **Step 1: 备份阅读现有文件**

读取 `lib/modules/player/full_player_route.dart` 全文，确认现有 `isFullPlayerOnTop`、`BottomSlideMaterialPageRoute`、`fullPlayerRoute` 三个符号的对外用途（被 `mini_player.dart` 与 `full_player_am.dart` 引用）。

Run: 用 Read 工具读取该文件
Expected: 看到当前 `isFullPlayerOnTop = ValueNotifier<bool>(false)`、`fullPlayerRoute()` 工厂、`BottomSlideMaterialPageRoute` 类

- [ ] **Step 2: 重写文件，替换为新的进度 Notifier 与路由**

用以下完整内容覆盖 `lib/modules/player/full_player_route.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/theme_provider.dart';
import 'full_player.dart';
import 'full_player_am.dart';

/// 全局过渡进度（0.0 = mini，1.0 = full）。
///
/// 由 [DraggablePlayerRoute] 内部的 AnimationController 同步驱动，
/// MiniPlayer 与 FullPlayer 通过 [ValueListenableBuilder] 监听此值，
/// 实现淡入淡出效果与拖拽距离线性绑定。
final ValueNotifier<double> playerExpansion = ValueNotifier<double>(0.0);

/// 拖拽距离阈值（px）：拖动该距离即达到全进度。
const double kPlayerDragThreshold = 220.0;

/// 兼容旧引用：返回 true 表示当前 FullPlayer 在栈顶。
/// 新代码应直接监听 [playerExpansion]。
bool get isFullPlayerOnTop => playerExpansion.value > 0.5;

/// 创建并返回可拖拽的 FullPlayer 路由。
///
/// 调用方应在拖拽手势 start 时调用：
/// ```dart
/// final route = fullPlayerRoute(context) as DraggablePlayerRoute<void>;
/// Navigator.of(context).push(route);
/// // route.controller 可在外部手动驱动
/// ```
DraggablePlayerRoute<void> fullPlayerRoute(BuildContext context) {
  final useAm = context.read<ThemeProvider>().useAmStylePlayer;
  return DraggablePlayerRoute<void>(
    builder: (_) => useAm ? const AmStyleFullPlayer() : const FullPlayer(),
  );
}

/// 可拖拽的 FullPlayer 路由。
///
/// - [opaque] = false：路由背景透明，下层 MiniPlayer 可见
/// - [buildTransitions]：用 [AnimationController.value] 驱动
///   `Opacity + SlideTransition`，实现淡入淡出 + 抽屉上滑
/// - [controller] 暴露给外部手势：拖动期间 `controller.stop()` + `controller.value = x`
///   释放时 `controller.fling(velocity: v)` / `forward()` / `reverse()`
class DraggablePlayerRoute<T> extends PageRoute<T> with _DraggablePlayerRouteMixin<T> {
  DraggablePlayerRoute({required this.builder});

  final WidgetBuilder builder;

  /// 由 [createAnimationController] 赋值，外部手势可读取此字段直接驱动。
  late AnimationController controller;

  @override
  AnimationController createAnimationController({required TickerProvider vsync}) {
    controller = AnimationController(
      vsync: vsync,
      duration: const Duration(milliseconds: 300),
      reverseDuration: const Duration(milliseconds: 250),
      lowerBound: 0.0,
      upperBound: 1.0,
    );
    return controller;
  }

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation) {
    return builder(context);
  }

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    // 同步 controller 值到全局 playerExpansion，
    // 让 MiniPlayer 等外部监听者感知进度
    if (animation.value != playerExpansion.value) {
      playerExpansion.value = animation.value;
    }

    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final progress = animation.value.clamp(0.0, 1.0);
        // 淡入：progress 0→1 时 opacity 0→1
        // 滑动：progress 0→1 时从 15% 屏幕高度下方位移滑到 0
        return Opacity(
          opacity: progress,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.15),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        );
      },
    );
  }

  // PageRoute 必需重写项
  @override
  bool get opaque => false;

  @override
  bool get barrierDismissible => false;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 250);
}

/// 为 [DraggablePlayerRoute] 提供 didPop 钩子，
/// 在 pop 触发时把进度归零，避免下次 push 时残留旧值。
mixin _DraggablePlayerRouteMixin<T> on PageRoute<T> {
  @override
  bool didPop(T? result) {
    // pop 时立即清零进度，让 MiniPlayer 立即恢复可见
    if (playerExpansion.value != 0.0) {
      playerExpansion.value = 0.0;
    }
    return super.didPop(result);
  }
}
```

- [ ] **Step 3: 验证文件能编译（不破坏现有引用）**

Run: `flutter analyze lib/modules/player/full_player_route.dart`
Expected: 无错误。若有 `isFullPlayerOnTop` 旧 bool 引用错误，先记录下来，下一步在调用方修复。

- [ ] **Step 4: 暂存改动，提交本任务**

```bash
git add lib/modules/player/full_player_route.dart
git commit -m "feat(player): 重写 full_player_route，引入 DraggablePlayerRoute 与 playerExpansion 进度 Notifier

- 新增全局 ValueNotifier<double> playerExpansion 作为单一进度源
- 新增 DraggablePlayerRoute（PageRoute 子类）暴露 AnimationController 供手势驱动
- buildTransitions 用 progress 驱动 Opacity + SlideTransition，实现淡入淡出 + 抽屉上滑
- 保留 isFullPlayerOnTop getter 兼容旧引用（基于 progress > 0.5）"
```

---

## Task 2: 改造 `mini_player.dart`，添加拖拽手势 + 进度驱动淡出

**Files:**
- Modify: `lib/modules/player/mini_player.dart`（整体改 StatefulWidget）

- [ ] **Step 1: 阅读现有文件，确认被引用的 API**

Run: 用 Read 工具读取 `lib/modules/player/mini_player.dart`
Expected: 确认 `class MiniPlayer extends StatelessWidget`、`const MiniPlayer({super.key})` 是对外 API，改为 StatefulWidget 时需保持构造函数签名一致。

- [ ] **Step 2: 用以下完整内容覆盖 `mini_player.dart`**

```dart
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/desktop_lyric_service.dart';
import '../../core/services/media_notification_service.dart';
import '../../providers/player_provider.dart';
import 'full_player_route.dart';

/// 底部常驻迷你播放条。
///
/// 支持两种方式展开为 FullPlayer：
/// 1. **点击**：调用 [fullPlayerRoute] push 路由，由路由自带 300ms 入场动画
/// 2. **向上拖拽**（抽屉式）：拖动期间手动驱动路由 AnimationController，
///    进度 = 累计上拖距离 / [kPlayerDragThreshold]，淡入淡出与拖拽距离线性绑定
///
/// 自身 opacity = `1 - playerExpansion`，由全局 [playerExpansion] Notifier 驱动，
/// FullPlayer 淡入时 mini bar 同步淡出，避免视觉打架。
class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key});

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  /// 拖拽起点的全局 y 坐标，用于计算累计位移。
  double _dragStartY = 0;

  /// 当前拖拽关联的路由（拖拽期间非空，结束后置空）。
  DraggablePlayerRoute<void>? _activeRoute;

  /// 拖拽是否已触发 push（避免重复 push）。
  bool _routePushed = false;

  @override
  Widget build(BuildContext context) {
    final playerProvider = context.watch<PlayerProvider>();
    final currentSong = playerProvider.currentSong;

    if (currentSong == null) return const SizedBox.shrink();

    final colorScheme = Theme.of(context).colorScheme;
    final duration = playerProvider.duration ?? Duration.zero;
    final position = playerProvider.position;
    final progress = duration.inMilliseconds > 0
        ? position.inMilliseconds / duration.inMilliseconds
        : 0.0;

    return ValueListenableBuilder<double>(
      valueListenable: playerExpansion,
      builder: (context, expansion, child) {
        // opacity 与拖拽进度线性绑定：progress=0 时完全可见，progress=1 时完全隐藏
        // IgnorePointer 防止淡出过程中拦截下层手势
        final opacity = (1.0 - expansion).clamp(0.0, 1.0);
        return IgnorePointer(
          ignoring: expansion > 0.5,
          child: Opacity(opacity: opacity, child: child),
        );
      },
      child: GestureDetector(
        // === 抽屉式向上拖拽展开 ===
        onVerticalDragStart: _onDragStart,
        onVerticalDragUpdate: _onDragUpdate,
        onVerticalDragEnd: _onDragEnd,
        // 点击展开（无拖拽场景）
        onTap: _onTap,
        behavior: HitTestBehavior.opaque,
        child: _buildContent(context, playerProvider, currentSong, colorScheme, progress),
      ),
    );
  }

  // === 拖拽手势回调 ===

  void _onDragStart(DragStartDetails details) {
    _dragStartY = details.globalPosition.dy;
    _routePushed = false;
    _activeRoute = null;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final dy = details.globalPosition.dy - _dragStartY;
    // 向上拖：dy < 0，dragDistance = -dy > 0
    final dragDistance = -dy;
    if (dragDistance <= 0) return; // 向下拖不触发

    // 首次有效拖动时 push 路由
    if (!_routePushed) {
      _activeRoute = fullPlayerRoute(context);
      Navigator.of(context).push(_activeRoute!);
      _routePushed = true;
      // 立即停止路由默认 forward 动画，改为手动控制
      _activeRoute!.controller.stop();
    }

    // 进度 = 拖拽距离 / 阈值，clamp 到 [0, 1]
    final progress = (dragDistance / kPlayerDragThreshold).clamp(0.0, 1.0);
    _activeRoute!.controller.value = progress;
  }

  void _onDragEnd(DragEndDetails details) {
    if (!_routePushed || _activeRoute == null) {
      // 未触发拖拽展开（仅点击），由 _onTap 处理
      return;
    }

    final route = _activeRoute!;
    final currentProgress = route.controller.value;
    // primaryVelocity < 0 表示向上甩动
    final velocity = details.primaryVelocity ?? 0;

    if (currentProgress > 0.5 || velocity < -300) {
      // 完成：forward 到 1.0
      route.controller.forward();
    } else {
      // 回退：reverse 到 0.0，然后 pop
      route.controller.reverse().then((_) {
        if (mounted) {
          Navigator.of(context).removeRoute(route);
        }
      });
    }

    _activeRoute = null;
    _routePushed = false;
  }

  void _onTap() {
    if (_routePushed) return; // 拖拽已触发，忽略 tap
    Navigator.of(context).push(fullPlayerRoute(context));
  }

  // === 原 StatelessWidget 的内容渲染逻辑（保持不变） ===

  Widget _buildContent(
    BuildContext context,
    PlayerProvider playerProvider,
    dynamic currentSong,
    ColorScheme colorScheme,
    double progress,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(color: colorScheme.outlineVariant, width: 0.5),
        ),
      ),
      child: SafeArea(
        top: false,
        bottom: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              minHeight: 2,
              backgroundColor: colorScheme.surfaceContainerHighest,
              color: colorScheme.primary,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: currentSong.artworkUri != null
                          ? CachedNetworkImage(
                              imageUrl: currentSong.artworkUri!,
                              fit: BoxFit.cover,
                              placeholder: (_, _) => Container(
                                color: colorScheme.surfaceContainerHighest,
                                child: Icon(Icons.music_note,
                                    size: 20, color: colorScheme.onSurfaceVariant),
                              ),
                              errorWidget: (_, _, _) => Container(
                                color: colorScheme.surfaceContainerHighest,
                                child: Icon(Icons.music_note,
                                    size: 20, color: colorScheme.onSurfaceVariant),
                              ),
                            )
                          : Container(
                              color: colorScheme.surfaceContainerHighest,
                              child: Icon(Icons.music_note,
                                  size: 20, color: colorScheme.onSurfaceVariant),
                            ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          currentSong.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        Text(
                          currentSong.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      playerProvider.isPlaying ? Icons.pause : Icons.play_arrow,
                    ),
                    onPressed: () {
                      if (playerProvider.isPlaying) {
                        playerProvider.pause();
                      } else {
                        playerProvider.resume();
                      }
                    },
                  ),
                  IconButton(
                    tooltip: DesktopLyricService.instance.enabled ? '关闭桌面歌词' : '开启桌面歌词',
                    icon: Icon(
                      DesktopLyricService.instance.enabled
                          ? Icons.lyrics
                          : Icons.lyrics_outlined,
                      color: DesktopLyricService.instance.enabled
                          ? colorScheme.primary
                          : null,
                    ),
                    onPressed: () async {
                      await DesktopLyricService.instance.toggle();
                      if (context.mounted) {
                        (context as Element).markNeedsBuild();
                        final player = context.read<PlayerProvider>();
                        final song = player.currentSong;
                        await MediaNotificationService.updateNotification(
                          title: song?.title ?? '',
                          artist: song?.artist ?? '',
                          artUrl: song?.artworkUri,
                          isPlaying: player.isPlaying,
                          position: player.position,
                          duration: player.duration ?? Duration.zero,
                          desktopLyricEnabled: DesktopLyricService.instance.enabled,
                        );
                      }
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_next),
                    onPressed: () => playerProvider.next(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 3: 运行静态分析**

Run: `flutter analyze lib/modules/player/mini_player.dart`
Expected: 无错误

- [ ] **Step 4: 提交本任务**

```bash
git add lib/modules/player/mini_player.dart
git commit -m "feat(player): MiniPlayer 改为 StatefulWidget，支持向上拖拽抽屉式展开 FullPlayer

- 监听全局 playerExpansion，opacity = 1 - progress，淡出与拖拽距离线性绑定
- onVerticalDragStart/Update/End 实现拖拽：首次有效拖动时 push 路由并 stop controller，后续手动 set value
- 释放时按进度/速度阈值决定 forward 或 reverse+pop
- 保留 onTap 直接 push 路由的快速展开路径"
```

---

## Task 3: 简化 `full_player_am.dart`，删除内部 mini bar 与 spring，把手拖拽改驱动路由 controller

**Files:**
- Modify: `lib/modules/player/full_player_am.dart`（大改）

- [ ] **Step 1: 完整阅读现有文件，记录所有需要删除的符号**

Run: 用 Read 工具读取 `lib/modules/player/full_player_am.dart` 全文
Expected: 记录以下符号需要删除或改造：
- 字段：`_isExpanded`, `_dragDistance`, `_expansionSpring`, `_springTicker`, `_lastTickElapsed`
- 方法：`_startSpringAnimation`, `_onSpringTick`, `_collapse`, `_expand`, `_buildMiniBar`
- build 方法中的 Stack+Opacity+IgnorePointer 双层结构（保留单层 _buildFullLayout）
- `_buildTopBar` 中把手的 `onVerticalDragUpdate`/`onVerticalDragEnd` 改为驱动路由 controller
- dispose 中 `_springTicker.dispose()` 删除

- [ ] **Step 2: 修改 import 与类声明**

打开 `lib/modules/player/full_player_am.dart`，定位 import 块（第 1-24 行），在末尾追加：

```dart
import 'full_player_route.dart';
```

即在第 24 行 `import 'comments_view.dart';` 后增加一行。

定位类体开头（约第 45-85 行的 State 类字段声明），删除以下字段：

```dart
  // === Task 19: 上滑展开 / 下拉收起手势 ===
  bool _isExpanded = true;
  double _dragDistance = 0;
  late final Spring _expansionSpring = Spring(...);
  late final Ticker _springTicker;
  Duration? _lastTickElapsed;
```

替换为：

```dart
  // === 拖拽收起手势：通过驱动路由 AnimationController 实现 ===
  double _dragStartY = 0;
```

- [ ] **Step 3: 改造 initState**

定位 `initState`（约第 87-112 行），删除以下两行：

```dart
    _springTicker = createTicker(_onSpringTick);
```

（在 `applyImmersiveForOrientation();` 之后那行）

并在 `WidgetsBinding.instance.addPostFrameCallback` 之前确保不引用 `_springTicker`。

- [ ] **Step 4: 改造 dispose**

定位 `dispose`（约第 193-205 行），删除：

```dart
    _springTicker.dispose();
```

- [ ] **Step 5: 删除 spring 相关私有方法**

定位并整段删除以下方法（约第 346-389 行）：

- `_startSpringAnimation()`
- `_onSpringTick(Duration elapsed)`
- `_collapse()`
- `_expand()`

替换为新的拖拽收起逻辑：

```dart
  // === 拖拽收起手势：直接驱动路由 AnimationController ===

  /// 获取当前路由的 AnimationController（来自 DraggablePlayerRoute）。
  /// 若当前路由不是 DraggablePlayerRoute（例如从其他入口 push），返回 null。
  AnimationController? get _routeController {
    final route = ModalRoute.of(context);
    if (route is DraggablePlayerRoute) {
      return route.controller;
    }
    return null;
  }

  /// 把手拖拽开始：记录起点 y。
  void _onHandleDragStart(DragStartDetails details) {
    _dragStartY = details.globalPosition.dy;
  }

  /// 把手拖拽更新：下拉距离 → controller 反向进度。
  void _onHandleDragUpdate(DragUpdateDetails details) {
    final controller = _routeController;
    if (controller == null) return;
    final dy = details.globalPosition.dy - _dragStartY;
    if (dy <= 0) return; // 上拉不触发收起
    final progress = 1.0 - (dy / kPlayerDragThreshold).clamp(0.0, 1.0);
    controller.stop();
    controller.value = progress;
  }

  /// 把手拖拽结束：按进度/速度决定完成收起或回退展开。
  void _onHandleDragEnd(DragEndDetails details) {
    final controller = _routeController;
    if (controller == null) return;
    final currentProgress = controller.value;
    final velocity = details.primaryVelocity ?? 0;

    if (currentProgress < 0.5 || velocity > 300) {
      // 收起：reverse 到 0，然后 pop
      controller.reverse().then((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
    } else {
      // 回退展开：forward 到 1.0
      controller.forward();
    }
  }

  /// 点击下拉按钮直接收起（保留原 _buildTopBar 的 IconButton 行为）。
  void _collapseByButton() {
    final controller = _routeController;
    if (controller == null) {
      Navigator.of(context).maybePop();
      return;
    }
    controller.reverse().then((_) {
      if (mounted) Navigator.of(context).maybePop();
    });
  }
```

- [ ] **Step 6: 改造 build 方法，删除 Stack+Opacity 双层结构**

定位 `build` 方法（约第 391-447 行），将整个方法体替换为：

```dart
  @override
  Widget build(BuildContext context) {
    final playerProvider = context.watch<PlayerProvider>();
    final currentSong = playerProvider.currentSong;
    final colorScheme = Theme.of(context).colorScheme;

    if (currentSong == null) {
      return Scaffold(
        backgroundColor: colorScheme.surface,
        appBar: AppBar(leading: const BackButton()),
        body: const Center(child: Text('暂无播放')),
      );
    }

    // 初始化封面 URL（首次进入或 null→有值）
    if (_previousArtworkUrl == null && currentSong.artworkUri != null) {
      _previousArtworkUrl = currentSong.artworkUri;
    }

    // 直接构建全屏布局，外层 Opacity + SlideTransition 由
    // DraggablePlayerRoute.buildTransitions 负责，此处不需要再包一层。
    return _buildFullLayout(playerProvider, currentSong, colorScheme);
  }
```

- [ ] **Step 7: 改造 `_buildTopBar` 的把手 GestureDetector**

定位 `_buildTopBar`（约第 981-1052 行），把顶部把手的 `GestureDetector` 替换为新的回调：

```dart
        // 顶部居中下拉手柄：拖拽时驱动路由 controller 反向
        GestureDetector(
          onVerticalDragStart: _onHandleDragStart,
          onVerticalDragUpdate: _onHandleDragUpdate,
          onVerticalDragEnd: _onHandleDragEnd,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 8),
            child: Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white54,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
```

并把下方 `IconButton`（下拉箭头）的 `onPressed` 从 `_collapse` 改为 `_collapseByButton`：

```dart
              IconButton(
                icon: const Icon(
                  Icons.keyboard_arrow_down,
                  color: Colors.white,
                ),
                onPressed: _collapseByButton,
              ),
```

- [ ] **Step 8: 删除 `_buildMiniBar` 方法整段**

定位 `_buildMiniBar`（约第 521-629 行），整段删除（连同上方文档注释）。

- [ ] **Step 9: 检查 import，移除不再使用的 Spring 引用**

定位 import 块，如果 `import '../../widgets/apple_lyrics/animation/spring.dart';` 不再被其他代码使用（grep 确认），删除该行。

Run: `grep -n "Spring" lib/modules/player/full_player_am.dart`
Expected: 仅 import 行（若无其他引用则删除）。

- [ ] **Step 10: 运行静态分析**

Run: `flutter analyze lib/modules/player/full_player_am.dart`
Expected: 无错误。常见问题：
- 未删除的 `_isExpanded`/`_dragDistance` 引用 → 全局搜索替换
- 未删除的 `_buildMiniBar` 调用 → 应在 build 中已被移除

- [ ] **Step 11: 提交本任务**

```bash
git add lib/modules/player/full_player_am.dart
git commit -m "refactor(player): AmStyleFullPlayer 简化，删除内部 mini bar 与 spring 机制

- 删除 _expansionSpring/_springTicker/_buildMiniBar 等 Task 19 残留
- mini 状态改由全局 MiniPlayer + 路由透明背景承担，避免双重 mini bar bug
- 把手拖拽手势改为直接驱动 DraggablePlayerRoute.controller
- 下拉按钮点击改为 reverse + pop 流程"
```

---

## Task 4: 为非 AM 风格 `full_player.dart` 添加下拉把手与拖拽收起手势

**Files:**
- Modify: `lib/modules/player/full_player.dart`

- [ ] **Step 1: 阅读现有 `_buildTopBar` 方法**

Run: 用 Read 工具读取 `lib/modules/player/full_player.dart` 第 617-646 行
Expected: 看到 `Padding(horizontal: 8, child: Row(children: [IconButton(keyboard_arrow_down), TabBar, IconButton(more_vert)]))` 结构。

- [ ] **Step 2: 在文件顶部添加 import**

定位第 17 行 `import '../../widgets/player_playlist_dialog.dart';`，在其后添加：

```dart
import 'full_player_route.dart';
```

- [ ] **Step 3: 在 `_FullPlayerState` 类内添加拖拽字段与方法**

定位第 57 行 `bool _wasPlayingBeforeDrag = false;`，在其后添加：

```dart
  // === 拖拽收起手势：通过驱动路由 AnimationController 实现 ===
  double _dragStartY = 0;

  /// 获取当前路由的 AnimationController。
  AnimationController? get _routeController {
    final route = ModalRoute.of(context);
    if (route is DraggablePlayerRoute) {
      return route.controller;
    }
    return null;
  }

  void _onHandleDragStart(DragStartDetails details) {
    _dragStartY = details.globalPosition.dy;
  }

  void _onHandleDragUpdate(DragUpdateDetails details) {
    final controller = _routeController;
    if (controller == null) return;
    final dy = details.globalPosition.dy - _dragStartY;
    if (dy <= 0) return;
    final progress = 1.0 - (dy / kPlayerDragThreshold).clamp(0.0, 1.0);
    controller.stop();
    controller.value = progress;
  }

  void _onHandleDragEnd(DragEndDetails details) {
    final controller = _routeController;
    if (controller == null) return;
    final currentProgress = controller.value;
    final velocity = details.primaryVelocity ?? 0;

    if (currentProgress < 0.5 || velocity > 300) {
      controller.reverse().then((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
    } else {
      controller.forward();
    }
  }

  void _collapseByButton() {
    final controller = _routeController;
    if (controller == null) {
      Navigator.of(context).maybePop();
      return;
    }
    controller.reverse().then((_) {
      if (mounted) Navigator.of(context).maybePop();
    });
  }
```

- [ ] **Step 4: 改造 `_buildTopBar`，在最外层包 Column + 把手 GestureDetector**

定位 `_buildTopBar` 方法（约第 617-646 行），整段替换为：

```dart
  Widget _buildTopBar() {
    final tabs = _isPadMode && !_isPhoneLandscape
        ? const [Tab(text: '歌词'), Tab(text: '评论')]
        : const [Tab(text: '封面'), Tab(text: '歌词'), Tab(text: '评论')];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 顶部下拉手柄：向下拖拽收起到 MiniPlayer
        GestureDetector(
          onVerticalDragStart: _onHandleDragStart,
          onVerticalDragUpdate: _onHandleDragUpdate,
          onVerticalDragEnd: _onHandleDragEnd,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 8),
            child: Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_down),
                onPressed: _collapseByButton,
              ),
              Expanded(
                child: TabBar(
                  controller: _tabController,
                  tabs: tabs,
                  labelStyle: Theme.of(context).textTheme.labelMedium,
                  indicatorSize: TabBarIndicatorSize.label,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.more_vert),
                onPressed: () => _showMoreMenu(context),
              ),
            ],
          ),
        ),
      ],
    );
  }
```

- [ ] **Step 5: 运行静态分析**

Run: `flutter analyze lib/modules/player/full_player.dart`
Expected: 无错误

- [ ] **Step 6: 提交本任务**

```bash
git add lib/modules/player/full_player.dart
git commit -m "feat(player): 非 AM 风格 FullPlayer 添加下拉把手与拖拽收起手势

- _buildTopBar 顶部增加 40x4 把手，绑定 onVerticalDragStart/Update/End
- 拖拽时直接驱动 DraggablePlayerRoute.controller，进度反向映射下拉距离
- 释放时按阈值决定 reverse+pop 或 forward 回展开
- 下拉按钮点击改为 reverse + pop 流程"
```

---

## Task 5: 全局回归测试与编译验证

**Files:**
- 无修改，仅运行验证

- [ ] **Step 1: 全工程静态分析**

Run: `flutter analyze lib/`
Expected: 无错误。若有以下问题需修复：
- `isFullPlayerOnTop` 旧 bool 引用：搜索 `grep -rn "isFullPlayerOnTop" lib/`，全部替换为 `playerExpansion.value > 0.5` 或直接监听 `playerExpansion`

- [ ] **Step 2: 搜索遗漏的旧符号引用**

Run: `grep -rn "_expansionSpring\|_springTicker\|_buildMiniBar\|_isExpanded" lib/modules/player/`
Expected: 无匹配（已全部删除）

Run: `grep -rn "BottomSlideMaterialPageRoute" lib/`
Expected: 无匹配（旧类已删除）

- [ ] **Step 3: 构建 Android Debug APK**

Run: `flutter build apk --debug`
Expected: BUILD SUCCESSFUL

- [ ] **Step 4: 在真机/模拟器上手动验证以下场景**

依次测试：

1. **点击 MiniPlayer**：应平滑淡入展开 FullPlayer（300ms）
2. **从 MiniPlayer 向上拖拽**：拖动过程中 FullPlayer 应跟随手指淡入+上滑，MiniPlayer 同步淡出；释放后按进度/速度完成或回退
3. **从 FullPlayer 把手向下拖拽**：拖动过程中 FullPlayer 应跟随手指淡出+下滑，MiniPlayer 同步淡入；释放后按进度/速度完成或回退
4. **点击 FullPlayer 顶部下拉箭头**：应平滑淡出收起到 MiniPlayer（250ms）
5. **系统返回手势/按钮**：应正常 pop，MiniPlayer 立即恢复可见
6. **AM 风格与非 AM 风格切换**：ThemeProvider 切换 `useAmStylePlayer` 后重新进入 FullPlayer，两种风格均应正常工作

- [ ] **Step 5: 提交回归验证完成的标记 commit（可选）**

```bash
git commit --allow-empty -m "test(player): 验证 MiniPlayer↔FullPlayer 拖拽过渡动画全部场景通过"
```

---

## Self-Review

### 1. Spec coverage

- ✅ 「从 minipalyer 拖拽抽屉拖出 fullpalyer」→ Task 2 `_onDragStart/Update/End` + 路由 push + 手动驱动 controller
- ✅ 「伴随淡入淡出动画」→ Task 1 `buildTransitions` 用 `Opacity(opacity: progress)` + `SlideTransition`
- ✅ 「fullplayer 界面也能通过把手向下拖动收回到 minipalyer」→ Task 3 (AM) + Task 4 (非 AM) 的把手 `onVerticalDrag*`
- ✅ 「也伴随淡入淡出动画」→ 同一 `buildTransitions`，reverse 时 controller 从 1→0，opacity 跟随
- ✅ 「淡入淡出的效果取决于拉动的距离」→ Task 2/3/4 中 `progress = dragDistance / kPlayerDragThreshold`，`controller.value = progress`，opacity = progress，线性绑定

### 2. Placeholder scan

- 无 "TBD"、"TODO" 等占位符
- 所有代码块均为完整可运行内容
- 所有命令均带 expected 输出

### 3. Type consistency

- `playerExpansion`：`ValueNotifier<double>`，全局唯一，Task 1 定义，Task 2 监听
- `DraggablePlayerRoute<T>`：Task 1 定义，Task 2/3/4 通过 `ModalRoute.of(context) is DraggablePlayerRoute` 访问 `controller`
- `kPlayerDragThreshold = 220.0`：Task 1 定义为 const，Task 2/3/4 引用
- `fullPlayerRoute()` 工厂：Task 1 定义，返回 `DraggablePlayerRoute<void>`，Task 2 调用并 push
- `_routeController` getter：Task 3 (AM) 与 Task 4 (非 AM) 同名同实现，访问 `DraggablePlayerRoute.controller`
- `_onHandleDragStart/Update/End` 方法签名：Task 3 与 Task 4 一致

无类型/命名不一致。

---

## 执行选择

**Plan complete and saved to `docs/superpowers/plans/2026-07-25-mini-to-full-player-drag-transition.md`. Two execution options:**

**1. Subagent-Driven (recommended)** - 每个 Task 派发独立 subagent 执行，任务间审查，迭代快

**2. Inline Execution** - 在当前会话按 Task 顺序执行，带检查点审查

**请选择执行方式。**
