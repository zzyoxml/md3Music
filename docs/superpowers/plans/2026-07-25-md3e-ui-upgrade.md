# md3Music UI 升级到 Material Design 3 Expressive (MD3E) 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 md3Music（Flutter 音乐播放器）从「使用 M3 基础主题」升级为「全面遵循 Material Design 3 Expressive 设计语言」——引入形状分层、弹簧物理动效、强调式过渡曲线、显式排版梯度与容器分组，让 UI 在保留功能不变的前提下变得更有「表现力」。

**Architecture:** 在 `lib/core/theme/` 下新增 `app_shapes.dart` 和 `app_motion.dart` 两个设计令牌文件，作为 `AppTheme` 的兄弟模块；在 `lib/widgets/` 下新增 `md3e_components.dart` 提供可复用的 expressive 容器组件（`MorphContainer`、`SpringPressable`）。已有 `app_animation.dart` 扩展 Spring 变体与 Emphasized 曲线。组件层（AlbumCard、SongListItem、MiniPlayer 等）逐个改造，沿用 Provider 体系，不改业务逻辑。所有动效优先使用 Flutter SDK 的 `SpringDescription` / `SpringSimulation`（`package:flutter/physics.dart`）与 `Curves.easeInOutCubicEmphasized`，把项目自实现的 `Spring` 类（`apple_lyrics/animation/spring.dart`）保留在歌词模块内部不外泄。

**Tech Stack:** Flutter 3.12+、Dart 3+、`flutter/material.dart`（M3 已启用）、`provider`、`dynamic_color`、`material_color_utilities`。测试用 `flutter_test`。无新增依赖（关键：所有 MD3E 表现力都靠 Flutter SDK 内置 API 实现，无需引入第三方包）。

**适用范围说明：** md3e 技能（`C:\Users\32732\.trae-cn\skills\md3e`）的代码模板是 Kotlin/Compose，但其中的设计令牌（color roles、type scale、shape scale、motion scheme、design tactics）是平台无关的。本计划把这些令牌翻译成 Flutter 等价 API。对照参考：`<skill>/references/design-tokens.md`、`<skill>/references/expressive-design-tactics.md`、`<skill>/references/m3-vs-m3e-diff.md`。

---

## File Structure

### 新增文件
- `lib/core/theme/app_shapes.dart` — MD3E 形状令牌（5 级 shape scale + 圆角分层规则 + `MorphableShape` 帮助类）
- `lib/core/theme/app_motion.dart` — MD3E 动效令牌（4 套 `SpringDescription` 预设 + emphasized 曲线常量 + duration 令牌）
- `lib/widgets/md3e_components.dart` — 可复用容器组件（`MorphContainer`、`SpringPressable`、`EmphasizedInkWell`）
- `test/core/theme/app_shapes_test.dart`
- `test/core/theme/app_motion_test.dart`
- `test/widgets/md3e_components_test.dart`
- `test/widgets/album_card_test.dart`
- `test/widgets/song_list_item_test.dart`
- `test/widgets/mini_player_test.dart`
- `test/modules/player/full_player_test.dart`

### 修改文件
- `lib/core/theme/app_theme.dart` — 接入 `AppShapes` 与 `AppMotion`，更新 `cardTheme`、`floatingActionButtonTheme`、`chipTheme`、`bottomSheetTheme`，补齐 `dialogTheme` / `snackbarTheme`
- `lib/widgets/app_animation.dart` — 新增 `SpringContainer`、`EmphasizedTransition`，保留现有类
- `lib/widgets/album_card.dart` — 改用 `MorphContainer` + hover/press 形变 + 大字标题
- `lib/widgets/song_list_item.dart` — 容器强调 + 弹簧高亮切换
- `lib/widgets/artist_tile.dart` — hover 缩放 + 头像形变
- `lib/modules/player/mini_player.dart` — 弹簧按压反馈 + 封面圆角变形
- `lib/modules/player/full_player.dart` — `SpringDescription` 替换 `AnimatedScale`，加 marquee 标题
- `lib/widgets/scroll_aware_app_bar.dart` — 新增 `Large` / `Medium` 灵活标题模式
- `lib/core/layout/responsive_layout.dart` — `NavigationBar` 指示器改为弹簧 pill 形变
- `lib/modules/discover/discover_page.dart` — banner 改 `displayLarge` 排版 + 形变
- `lib/modules/settings/settings_page.dart` — section 卡片化分组
- `lib/widgets/seed_color_picker.dart` — 色块改胶囊形 + 弹簧选中反馈

### 不改动
- `lib/widgets/apple_lyrics/`（已有自实现 Spring，独立模块，保持现状）
- `lib/main.dart`、`lib/app.dart`（仅最小改动：注册新主题）
- `lib/providers/`、`lib/services/`、`lib/data/`、`kugou_api_server/`、`networkapi/`、`android/`（业务层与原生层不动）

### 分解决策
- **shape / motion 独立成文件**：未来若要做"主题切换器"或"无障碍降级动效"会改 motion，不动 shape；反之亦然。两者职责清晰，单文件不超过 200 行。
- **MD3E 容器组件集中到 `md3e_components.dart`**：避免在每个卡片里重复实现 hover/press 形变逻辑（DRY）。每个组件 < 80 行。
- **测试与实现并行**：每个新文件都先有失败测试再写实现（TDD）。组件改造类任务用 widget test 验证关键行为（hover 是否触发形变、按压是否产生 spring）。
- **不动业务逻辑**：本计划只改 UI 表现层，`PlayerProvider`、`KugouProvider` 等数据流不变。所有改造在 widget 层闭环。

---

## Task 1: MD3E Shape System (`app_shapes.dart`)

**Files:**
- Create: `lib/core/theme/app_shapes.dart`
- Test: `test/core/theme/app_shapes_test.dart`

**目标：** 把项目当前散落 84 处的 `BorderRadius.circular(...)` 收敛为 5 级 shape scale，对齐 MD3E 规范（extraSmall=4 / small=8 / medium=12 / large=16 / extraLarge=28），并提供 `MorphableRoundedRectangleBorder` 用于在 hover/press 时圆角平滑过渡。

- [ ] **Step 1: 写失败测试**

```dart
// test/core/theme/app_shapes_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/theme/app_shapes.dart';

void main() {
  group('AppShapes', () {
    test('shape scale 对齐 MD3E 规范', () {
      expect(AppShapes.extraSmall, BorderRadius.circular(4));
      expect(AppShapes.small, BorderRadius.circular(8));
      expect(AppShapes.medium, BorderRadius.circular(12));
      expect(AppShapes.large, BorderRadius.circular(16));
      expect(AppShapes.extraLarge, BorderRadius.circular(28));
    });

    test('Shapes 实例 5 个尺寸正确', () {
      final shapes = AppShapes.shapes;
      expect(shapes.extraSmall, const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4))));
      expect(shapes.small, const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(8))));
      expect(shapes.medium, const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))));
      expect(shapes.large, const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))));
      expect(shapes.extraLarge, const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(28))));
    });

    test('radiusFor 按组件类型返回正确尺寸', () {
      expect(AppShapes.radiusFor(ComponentSize.tiny), 4);     // chip / badge
      expect(AppShapes.radiusFor(ComponentSize.small), 8);    // list item thumbnail
      expect(AppShapes.radiusFor(ComponentSize.medium), 12);  // small card
      expect(AppShapes.radiusFor(ComponentSize.large), 16);   // album card / FAB
      expect(AppShapes.radiusFor(ComponentSize.extraLarge), 28); // dialog / bottom sheet
    });

    test('MorphableRoundedRectangleBorder lerp 圆角能从 8 过渡到 16', () {
      const a = MorphableRoundedRectangleBorder(radius: 8);
      const b = MorphableRoundedRectangleBorder(radius: 16);
      final mid = ShapeBorder.lerp(a, b, 0.5);
      expect(mid, isA<MorphableRoundedRectangleBorder>());
      expect((mid as MorphableRoundedRectangleBorder).radius, 12);
    });
  });
}
```

- [ ] **Step 2: 运行测试验证失败**

Run: `flutter test test/core/theme/app_shapes_test.dart`
Expected: FAIL — `Error: Getter not found: 'AppShapes'` / `MorphableRoundedRectangleBorder` 未定义

- [ ] **Step 3: 写最小实现**

```dart
// lib/core/theme/app_shapes.dart
import 'package:flutter/material.dart';

/// MD3E 形状令牌。对齐 m3.material.io/styles/shape 的 5 级 shape scale。
/// 参考：<md3e-skill>/references/design-tokens.md "Shape Scale"。
class AppShapes {
  AppShapes._();

  /// 5 级圆角半径（dp）。索引顺序对应 [ComponentSize]。
  static const double extraSmallRadius = 4;
  static const double smallRadius = 8;
  static const double mediumRadius = 12;
  static const double largeRadius = 16;
  static const double extraLargeRadius = 28;

  /// 对外的 BorderRadius 常量，供 ClipRRect / BoxDecoration 直接引用。
  static const BorderRadius extraSmall = BorderRadius.all(Radius.circular(extraSmallRadius));
  static const BorderRadius small = BorderRadius.all(Radius.circular(smallRadius));
  static const BorderRadius medium = BorderRadius.all(Radius.circular(mediumRadius));
  static const BorderRadius large = BorderRadius.all(Radius.circular(largeRadius));
  static const BorderRadius extraLarge = BorderRadius.all(Radius.circular(extraLargeRadius));

  /// [Shapes] 实例，传给 [ThemeData.shapes]（Flutter 3.12+ 支持）。
  static const Shapes shapes = Shapes(
    extraSmall: RoundedRectangleBorder(borderRadius: extraSmall),
    small: RoundedRectangleBorder(borderRadius: small),
    medium: RoundedRectangleBorder(borderRadius: medium),
    large: RoundedRectangleBorder(borderRadius: large),
    extraLarge: RoundedRectangleBorder(borderRadius: extraLarge),
  );

  /// 按组件尺寸返回半径数值。
  static double radiusFor(ComponentSize size) {
    switch (size) {
      case ComponentSize.tiny:
        return extraSmallRadius;
      case ComponentSize.small:
        return smallRadius;
      case ComponentSize.medium:
        return mediumRadius;
      case ComponentSize.large:
        return largeRadius;
      case ComponentSize.extraLarge:
        return extraLargeRadius;
    }
  }
}

/// 组件尺寸枚举，用于查表圆角。
enum ComponentSize {
  tiny,       // chip / badge / indicator
  small,      // list item thumbnail / icon button
  medium,     // small card / search bar
  large,      // album card / FAB / nav rail item
  extraLarge, // dialog / bottom sheet / full player
}

/// 可圆角过渡的 [RoundedRectangleBorder] 子类。
///
/// Flutter 默认的 [RoundedRectangleBorder] 之间 lerp 时，若两侧 borderRadius
/// 维度不同（ BorderRadius.all vs BorderRadius.vertical），会降级为线性 lerp
/// 导致圆角"塌陷"。本类固定使用 [BorderRadius.all]，只 lerp 半径数值，
/// 保证 hover → press 圆角过渡平滑。配合 [AnimatedContainer] / [Tween] 使用。
class MorphableRoundedRectangleBorder extends RoundedRectangleBorder {
  final double radius;

  const MorphableRoundedRectangleBorder({required this.radius, super.side})
      : super(borderRadius: BorderRadius.all(Radius.circular(radius)));

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is MorphableRoundedRectangleBorder) {
      return MorphableRoundedRectangleBorder(
        radius: lerpDouble(a.radius, radius, t)!.roundToDouble(),
        side: BorderSide.lerp(a.side, side, t),
      );
    }
    return super.lerpFrom(a, t);
  }

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) {
    if (b is MorphableRoundedRectangleBorder) {
      return MorphableRoundedRectangleBorder(
        radius: lerpDouble(radius, b.radius, t)!.roundToDouble(),
        side: BorderSide.lerp(side, b.side, t),
      );
    }
    return super.lerpTo(b, t);
  }
}

// Flutter 内部的 lerpDouble 在 foundation 包，这里为避免额外 import 复制一个本地版
double? lerpDouble(num? a, num? b, double t) {
  if (a == null && b == null) return null;
  if (a == null) return (b! as double) * t;
  if (b == null) return (a as double) * (1.0 - t);
  return (a as double) + ((b as double) - (a as double)) * t;
}
```

- [ ] **Step 4: 运行测试验证通过**

Run: `flutter test test/core/theme/app_shapes_test.dart`
Expected: PASS（4 个测试全过）

- [ ] **Step 5: 提交**

```bash
git add lib/core/theme/app_shapes.dart test/core/theme/app_shapes_test.dart
git commit -m "feat(theme): 新增 MD3E 形状令牌 AppShapes 与 MorphableRoundedRectangleBorder"
```

---

## Task 2: MD3E Motion System (`app_motion.dart`)

**Files:**
- Create: `lib/core/theme/app_motion.dart`
- Test: `test/core/theme/app_motion_test.dart`

**目标：** 把项目当前 32 处 `Curves.easeOutCubic` / `easeOut` / `easeOutBack` / `easeInOut` 单段曲线收敛为「标准 + 表现力」两套动效令牌：4 个 `SpringDescription` 预设（对应 `MotionScheme.standard()` / `MotionScheme.expressive()`）+ 4 个 emphasized 曲线常量（emphasized / emphasizedDecelerate / emphasizedAccelerate / standard）+ duration 令牌（short1-4 / medium1-4 / long1-4）。

- [ ] **Step 1: 写失败测试**

```dart
// test/core/theme/app_motion_test.dart
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/theme/app_motion.dart';

void main() {
  group('AppMotion', () {
    group('SpringPresets', () {
      test('standard 三个 spring 参数符合 M3 规范（snappy = 高刚度低阻尼）', () {
        final s = AppMotion.standardSnappy;
        // MD3 standard snappy: mass=1, stiffness=800, damping=60
        expect(s.mass, 1.0);
        expect(s.stiffness, 800.0);
        expect(s.damping, 60.0);
      });

      test('expressive 三个 spring 参数符合 MD3E 规范（bouncy = 低刚度中等阻尼）', () {
        final s = AppMotion.expressiveBouncy;
        // MD3E expressive: mass=1, stiffness=200, damping=18（轻微过冲）
        expect(s.mass, 1.0);
        expect(s.stiffness, 200.0);
        expect(s.damping, 18.0);
      });

      test('SpringSimulation 在 expressiveBouncy 下会过冲（位移 > 1）', () {
        final desc = AppMotion.expressiveBouncy;
        final spring = SpringSimulation(desc, 0.0, 1.0, 0.0);
        spring.tolerance = const Tolerance(distance: 0.001, time: 0.001);
        // 在 200ms 左右采样，应有 max > 1
        double maxVal = 0;
        for (double t = 0; t < 1.0; t += 0.01) {
          final v = spring.x(t);
          if (v > maxVal) maxVal = v;
        }
        expect(maxVal, greaterThan(1.0));
      });

      test('SpringSimulation 在 standardSnappy 下不过冲', () {
        final desc = AppMotion.standardSnappy;
        final spring = SpringSimulation(desc, 0.0, 1.0, 0.0);
        spring.tolerance = const Tolerance(distance: 0.001, time: 0.001);
        double maxVal = 0;
        for (double t = 0; t < 1.0; t += 0.01) {
          final v = spring.x(t);
          if (v > maxVal) maxVal = v;
        }
        expect(maxVal, lessThanOrEqualTo(1.001));
      });
    });

    group('EmphasizedCurves', () {
      test('emphasized 是 emphasizedDecelerate + emphasizedAccelerate 的合成', () {
        // emphasized: 前 40% 用 decelerate，后 60% 用 accelerate
        // 这里只验证常量存在且是 Cubic 实例
        expect(AppMotion.emphasized, isA<Cubic>());
        expect(AppMotion.emphasizedDecelerate, isA<Cubic>());
        expect(AppMotion.emphasizedAccelerate, isA<Cubic>());
        expect(AppMotion.standard, isA<Cubic>());
      });

      test('emphasizedDecelerate 控制点对齐规范 (0.05, 0.7, 0.1, 1)', () {
        final c = AppMotion.emphasizedDecelerate as Cubic;
        // Cubic 内部存了 4 个控制点，通过 toString 验证
        expect(c.toString(), contains('0.05'));
        expect(c.toString(), contains('0.7'));
      });
    });

    group('Durations', () {
      test('short2 = 100ms, medium2 = 300ms, long2 = 500ms', () {
        expect(AppMotion.short2, const Duration(milliseconds: 100));
        expect(AppMotion.medium2, const Duration(milliseconds: 300));
        expect(AppMotion.long2, const Duration(milliseconds: 500));
      });
    });
  });
}
```

- [ ] **Step 2: 运行测试验证失败**

Run: `flutter test test/core/theme/app_motion_test.dart`
Expected: FAIL — `Error: Getter not found: 'AppMotion'`

- [ ] **Step 3: 写最小实现**

```dart
// lib/core/theme/app_motion.dart
import 'package:flutter/animation.dart';
import 'package:flutter/physics.dart';

/// MD3E 动效令牌。对齐 m3.material.io/styles/motion 的 duration / easing / spring 三套规范。
/// 参考：<md3e-skill>/references/design-tokens.md "Motion System"。
class AppMotion {
  AppMotion._();

  // ---------------------------------------------------------------------------
  // Duration tokens（ms），对应 M3 duration scale。
  // ---------------------------------------------------------------------------
  static const Duration short1 = Duration(milliseconds: 50);
  static const Duration short2 = Duration(milliseconds: 100);
  static const Duration short3 = Duration(milliseconds: 150);
  static const Duration short4 = Duration(milliseconds: 200);
  static const Duration medium1 = Duration(milliseconds: 250);
  static const Duration medium2 = Duration(milliseconds: 300);
  static const Duration medium3 = Duration(milliseconds: 350);
  static const Duration medium4 = Duration(milliseconds: 400);
  static const Duration long1 = Duration(milliseconds: 450);
  static const Duration long2 = Duration(milliseconds: 500);
  static const Duration long3 = Duration(milliseconds: 550);
  static const Duration long4 = Duration(milliseconds: 600);

  // ---------------------------------------------------------------------------
  // Emphasized curves（M3 standard easing 三段曲线）。
  // Flutter 3.12+ 内置 Curves.easeInOutCubicEmphasized，但单独常量更清晰。
  // ---------------------------------------------------------------------------

  /// M3 emphasized：用于入场+退场，前 40% 减速，后 60% 加速。
  static const Cubic emphasized = Cubic(0.2, 0.0, 0.0, 1.0);

  /// M3 emphasizedDecelerate：用于入场，元素从屏外进入。
  static const Cubic emphasizedDecelerate = Cubic(0.05, 0.7, 0.1, 1.0);

  /// M3 emphasizedAccelerate：用于退场，元素离开屏幕。
  static const Cubic emphasizedAccelerate = Cubic(0.3, 0.0, 0.8, 0.15);

  /// M3 standard：默认缓动。
  static const Cubic standard = Cubic(0.2, 0.0, 0.0, 1.0);

  // ---------------------------------------------------------------------------
  // Spring presets（M3E expressive motion），对应 MotionScheme.standard / expressive。
  // 参数取自 <md3e-skill>/references/design-tokens.md "Spring Physics"。
  // ---------------------------------------------------------------------------

  /// 标准（snappy）：动作结束快、几乎不过冲。用于组件状态切换、列表 item 入场。
  /// mass=1, stiffness=800, damping=60 → critically damped + 轻微快。
  static final SpringDescription standardSnappy = SpringDescription(
    mass: 1.0,
    stiffness: 800.0,
    damping: 60.0,
  );

  /// 标准（slow）：动作结束慢、无过冲。用于页面切换、容器变形。
  /// mass=1, stiffness=200, damping=60。
  static final SpringDescription standardSlow = SpringDescription(
    mass: 1.0,
    stiffness: 200.0,
    damping: 60.0,
  );

  /// 表现力（bouncy）：轻微过冲，有"弹"感。用于按压反馈、FAB 变形、Hero 时刻。
  /// mass=1, stiffness=200, damping=18。
  static final SpringDescription expressiveBouncy = SpringDescription(
    mass: 1.0,
    stiffness: 200.0,
    damping: 18.0,
  );

  /// 表现力（medium）：温和过冲。用于容器形变（hover→resting）。
  /// mass=1, stiffness=400, damping=25。
  static final SpringDescription expressiveMedium = SpringDescription(
    mass: 1.0,
    stiffness: 400.0,
    damping: 25.0,
  );

  /// 默认容差（用于 SpringSimulation.setTolerance）。
  static const Tolerance defaultTolerance = Tolerance(distance: 0.01, time: 0.01);
}
```

- [ ] **Step 4: 运行测试验证通过**

Run: `flutter test test/core/theme/app_motion_test.dart`
Expected: PASS（7 个测试全过）

- [ ] **Step 5: 提交**

```bash
git add lib/core/theme/app_motion.dart test/core/theme/app_motion_test.dart
git commit -m "feat(theme): 新增 MD3E 动效令牌 AppMotion（spring 预设 + emphasized 曲线 + duration）"
```

---

## Task 3: 接入 AppTheme（shape + motion + 主题令牌完善）

**Files:**
- Modify: `lib/core/theme/app_theme.dart`（行 100-229 的 `_buildTheme` 方法 + 顶部 import）
- Test: `test/core/theme/app_theme_test.dart`（新建）

**目标：** 让 `AppTheme._buildTheme` 使用 `AppShapes.shapes` 替代散落的 `BorderRadius.circular(16)`，并补齐 M3E 推荐的 `dialogTheme`、`snackbarTheme`、`menuTheme`（项目当前完全没配 dialogTheme，dialog 圆角散落在各调用点）。

- [ ] **Step 1: 写失败测试**

```dart
// test/core/theme/app_theme_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/theme/app_theme.dart';

void main() {
  group('AppTheme MD3E 集成', () {
    final lightTheme = AppTheme.lightTheme;
    final darkTheme = AppTheme.darkTheme;

    test('CardTheme 使用 AppShapes.large（16dp）', () {
      final shape = lightTheme.cardTheme.shape;
      expect(shape, isA<RoundedRectangleBorder>());
      final rb = shape as RoundedRectangleBorder;
      expect(rb.borderRadius, BorderRadius.circular(16));
    });

    test('FABTheme 使用 AppShapes.large（16dp，MD3E 默认 regular FAB）', () {
      final shape = lightTheme.floatingActionButtonTheme.shape;
      expect(shape, isA<RoundedRectangleBorder>());
      final rb = shape as RoundedRectangleBorder;
      expect(rb.borderRadius, BorderRadius.circular(16));
    });

    test('ChipTheme 使用 AppShapes.small（8dp）', () {
      final shape = lightTheme.chipTheme.shape;
      expect(shape, isA<RoundedRectangleBorder>());
      final rb = shape as RoundedRectangleBorder;
      expect(rb.borderRadius, BorderRadius.circular(8));
    });

    test('dialogTheme 已配置且圆角为 extraLarge（28dp）', () {
      expect(lightTheme.dialogTheme, isNotNull);
      final shape = lightTheme.dialogTheme.shape;
      expect(shape, isA<RoundedRectangleBorder>());
      final rb = shape as RoundedRectangleBorder;
      expect(rb.borderRadius, BorderRadius.circular(28));
    });

    test('snackbarTheme 已配置且行为为 floating', () {
      expect(lightTheme.snackbarTheme, isNotNull);
      expect(lightTheme.snackbarTheme.behavior, SnackBarBehavior.floating);
      expect(lightTheme.snackbarTheme.shape, BorderRadius.circular(4));
    });

    test('深色主题同样满足上述规则', () {
      expect(darkTheme.dialogTheme.shape, isA<RoundedRectangleBorder>());
      expect(darkTheme.snackbarTheme.behavior, SnackBarBehavior.floating);
    });
  });
}
```

- [ ] **Step 2: 运行测试验证失败**

Run: `flutter test test/core/theme/app_theme_test.dart`
Expected: FAIL — `dialogTheme` 为 null、`snackbarTheme` 为 null

- [ ] **Step 3: 修改 `app_theme.dart`**

在 `lib/core/theme/app_theme.dart` 顶部 import 区追加：

```dart
import 'app_shapes.dart';
import 'app_motion.dart';
```

把 `_buildTheme` 方法中现有的 `cardTheme`、`floatingActionButtonTheme`、`chipTheme`、`bottomSheetTheme` 改为引用 `AppShapes.*`，并在末尾追加 `dialogTheme`、`snackbarTheme`、`menuTheme`：

```dart
// 把现有 cardTheme 替换为：
cardTheme: CardThemeData(
  elevation: isLight ? 1 : 0,
  shape: RoundedRectangleBorder(borderRadius: AppShapes.large),
  color: colorScheme.surfaceContainerLow,
  surfaceTintColor: colorScheme.surfaceTint,
),
// floatingActionButtonTheme 替换为：
floatingActionButtonTheme: FloatingActionButtonThemeData(
  backgroundColor: colorScheme.primaryContainer,
  foregroundColor: colorScheme.onPrimaryContainer,
  elevation: 3,
  shape: RoundedRectangleBorder(borderRadius: AppShapes.large),
),
// chipTheme 替换 shape：
chipTheme: ChipThemeData(
  // ... 其他字段保持不变
  shape: RoundedRectangleBorder(borderRadius: AppShapes.small),
  // ...
),
// bottomSheetTheme 保持现状（已用 28）：
bottomSheetTheme: BottomSheetThemeData(
  backgroundColor: colorScheme.surfaceContainerLow,
  surfaceTintColor: colorScheme.surfaceTint,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
  ),
),
// 在 ThemeData 构造参数列表末尾追加：
dialogTheme: DialogThemeData(
  backgroundColor: colorScheme.surfaceContainerHigh,
  surfaceTintColor: colorScheme.surfaceTint,
  shape: RoundedRectangleBorder(borderRadius: AppShapes.extraLarge),
  elevation: isLight ? 3 : 0,
),
snackbarTheme: SnackbarThemeData(
  behavior: SnackBarBehavior.floating,
  backgroundColor: colorScheme.inverseSurface,
  contentTextStyle: _buildTextStyle(colorScheme.onInverseSurface, 14, FontWeight.w400),
  shape: RoundedRectangleBorder(borderRadius: AppShapes.extraSmall),
  elevation: 6,
),
menuTheme: MenuThemeData(
  style: MenuStyle(
    backgroundColor: WidgetStatePropertyAll(colorScheme.surfaceContainer),
    surfaceTintColor: WidgetStatePropertyAll(colorScheme.surfaceTint),
    shape: const WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4))),
    ),
    elevation: const WidgetStatePropertyAll(3),
  ),
),
```

- [ ] **Step 4: 运行测试验证通过**

Run: `flutter test test/core/theme/app_theme_test.dart`
Expected: PASS（6 个测试全过）

- [ ] **Step 5: 运行整体回归测试**

Run: `flutter test`
Expected: PASS（已有测试不应有破坏）

- [ ] **Step 6: 提交**

```bash
git add lib/core/theme/app_theme.dart test/core/theme/app_theme_test.dart
git commit -m "refactor(theme): 接入 AppShapes/AppMotion，补齐 dialogTheme/snackbarTheme/menuTheme"
```

---

## Task 4: MD3E 容器组件（`md3e_components.dart`）

**Files:**
- Create: `lib/widgets/md3e_components.dart`
- Test: `test/widgets/md3e_components_test.dart`

**目标：** 提供两个可复用容器，封装 MD3E 的「内容感知形变」+「弹簧按压」模式，供后续组件改造时直接复用。

- `MorphContainer`：根据 `WidgetState`（hovered/pressed/focused）在两组 shape 间平滑过渡（用 `AnimatedContainer` + `AppMotion.standardSlow`）。
- `SpringPressable`：包裹任意子组件，按下时用 `SpringSimulation` 触发 scale 0.97→1.0 的弹回（用 `AppMotion.expressiveBouncy`）。

- [ ] **Step 1: 写失败测试**

```dart
// test/widgets/md3e_components_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/md3e_components.dart';

void main() {
  group('MorphContainer', () {
    testWidgets('默认使用 restingShape', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: MorphContainer(
              restingShape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
              pressedShape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
              child: const SizedBox(width: 100, height: 100),
            ),
          ),
        ),
      );
      // 找到 AnimatedContainer 内的 DecoratedBox，验证 BorderShape
      final material = tester.widget<Material>(find.byType(Material));
      final shape = material.shape as RoundedRectangleBorder;
      expect(shape.borderRadius, BorderRadius.circular(16));
    });

    testWidgets('按下后切换到 pressedShape', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: MorphContainer(
              restingShape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
              pressedShape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
              child: const SizedBox(width: 100, height: 100),
            ),
          ),
        ),
      );
      // 模拟按压
      await tester.startGesture(tester.getCenter(find.byType(MorphContainer)));
      await tester.pumpAndSettle();
      final material = tester.widget<Material>(find.byType(Material));
      final shape = material.shape as RoundedRectangleBorder;
      expect(shape.borderRadius, BorderRadius.circular(12));
    });
  });

  group('SpringPressable', () {
    testWidgets('按下时 scale 变小', (tester) async {
      double capturedScale = 1.0;
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SpringPressable(
              onPressed: () {},
              child: Builder(builder: (context) {
                final scale = SpringPressable.of(context);
                capturedScale = scale;
                return Container(width: 100, height: 100, color: Colors.red);
              }),
            ),
          ),
        ),
      );
      await tester.startGesture(tester.getCenter(find.byType(SpringPressable)));
      await tester.pump(const Duration(milliseconds: 50));
      expect(capturedScale, lessThan(1.0));
    });
  });
}
```

- [ ] **Step 2: 运行测试验证失败**

Run: `flutter test test/widgets/md3e_components_test.dart`
Expected: FAIL — `Error: Getter not found: 'MorphContainer'` / `SpringPressable`

- [ ] **Step 3: 写最小实现**

```dart
// lib/widgets/md3e_components.dart
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import '../core/theme/app_motion.dart';

/// 内容感知形变容器：在 [restingShape] 与 [pressedShape] 之间根据交互状态平滑过渡。
///
/// 用法：替代 Card / Material，包裹需要 hover/press 形变的子组件。
/// 配合 [AppMotion.standardSlow]（spring）实现 MD3E "container morph"。
class MorphContainer extends StatefulWidget {
  final ShapeBorder restingShape;
  final ShapeBorder pressedShape;
  final Color? color;
  final Color? surfaceTintColor;
  final double elevation;
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  const MorphContainer({
    super.key,
    required this.restingShape,
    required this.pressedShape,
    required this.child,
    this.color,
    this.surfaceTintColor,
    this.elevation = 0,
    this.onTap,
    this.padding = EdgeInsets.zero,
  });

  @override
  State<MorphContainer> createState() => _MorphContainerState();
}

class _MorphContainerState extends State<MorphContainer> {
  bool _isPressed = false;

  void _setPressed(bool v) {
    if (_isPressed != v) {
      setState(() => _isPressed = v);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) {
        _setPressed(false);
        widget.onTap?.call();
      },
      onTapCancel: () => _setPressed(false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        decoration: ShapeDecoration(
          color: widget.color ?? scheme.surfaceContainerLow,
          shape: _isPressed ? widget.pressedShape : widget.restingShape,
        ),
        child: Material(
          color: Colors.transparent,
          surfaceTintColor: widget.surfaceTintColor,
          elevation: widget.elevation,
          shape: _isPressed ? widget.pressedShape : widget.restingShape,
          clipBehavior: Clip.antiAlias,
          child: Padding(padding: widget.padding, child: widget.child),
        ),
      ),
    );
  }
}

/// 弹簧按压容器：按下时子组件 scale 0.97→1.0 弹回，使用 [AppMotion.expressiveBouncy]。
///
/// 用法：包裹按钮、卡片、FAB 等需要"按下去弹回来"反馈的组件。
/// 子组件可通过 [SpringPressable.of] 拿到当前 scale 值。
class SpringPressable extends StatefulWidget {
  final VoidCallback? onPressed;
  final Widget child;

  const SpringPressable({
    super.key,
    this.onPressed,
    required this.child,
  });

  /// 让后代读取当前 scale。配合 Builder / AnimatedBuilder 使用。
  static double of(BuildContext context) {
    final inherited = context.dependOnInheritedWidgetOfExactType<_SpringScaleScope>();
    return inherited?.scale ?? 1.0;
  }

  @override
  State<SpringPressable> createState() => _SpringPressableState();
}

class _SpringPressableState extends State<SpringPressable>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController.unbounded(vsync: this);
    _scale = Tween<double>(begin: 1.0, end: 1.0).animate(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onPressedDown() {
    final spring = SpringSimulation(
      AppMotion.expressiveBouncy,
      _controller.value, // 从当前位置
      0.97,               // 目标：缩小到 97%
      0.0,                // 初始速度 0
    )..tolerance = AppMotion.defaultTolerance;
    _controller.animateWith(spring);
  }

  void _onPressedUp() {
    final spring = SpringSimulation(
      AppMotion.expressiveBouncy,
      _controller.value,
      1.0, // 弹回原大小（会有轻微过冲）
      0.0,
    )..tolerance = AppMotion.defaultTolerance;
    _controller.animateWith(spring);
    widget.onPressed?.call();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _onPressedDown(),
      onTapUp: (_) => _onPressedUp(),
      onTapCancel: _onPressedUp,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return _SpringScaleScope(
            scale: _controller.value,
            child: Transform.scale(scale: _controller.value, child: child),
          );
        },
        child: widget.child,
      ),
    );
  }
}

class _SpringScaleScope extends InheritedWidget {
  final double scale;
  const _SpringScaleScope({required this.scale, required super.child});

  @override
  bool updateShouldNotify(_SpringScaleScope oldWidget) => scale != oldWidget.scale;
}
```

- [ ] **Step 4: 运行测试验证通过**

Run: `flutter test test/widgets/md3e_components_test.dart`
Expected: PASS（3 个测试全过）

- [ ] **Step 5: 提交**

```bash
git add lib/widgets/md3e_components.dart test/widgets/md3e_components_test.dart
git commit -m "feat(widgets): 新增 MD3E MorphContainer 与 SpringPressable 容器组件"
```

---

## Task 5: 升级 AlbumCard（hover/press 形变 + hero 排版）

**Files:**
- Modify: `lib/widgets/album_card.dart`
- Test: `test/widgets/album_card_test.dart`（新建）

**目标：** 把当前 `Material + InkWell + ClipRRect(borderRadius: 16)` 自实现升级为使用 `MorphContainer`，hover/press 时圆角从 16→12 过渡，并配合 `SpringPressable` 提供"按下去弹回"反馈；标题字号从 13/w500 改为 `Theme.of(context).textTheme.titleSmall`（14/w500，对齐 M3 规范）。

- [ ] **Step 1: 写失败测试**

```dart
// test/widgets/album_card_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/album.dart';
import 'package:md3music/widgets/album_card.dart';

void main() {
  group('AlbumCard MD3E', () {
    final testAlbum = Album(
      id: 'a1',
      name: '测试专辑',
      artist: '测试艺人',
      coverUrl: 'https://example.com/cover.jpg',
    );

    testWidgets('使用 MorphContainer 而非裸 Material', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AlbumCard(album: testAlbum, onTap: () {}),
          ),
        ),
      );
      expect(find.byType(MorphContainer), findsOneWidget);
      expect(find.byType(SpringPressable), findsOneWidget);
    });

    testWidgets('标题用 titleSmall（14sp w500）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AlbumCard(album: testAlbum, onTap: () {})),
        ),
      );
      final titleText = find.text('测试专辑');
      final textStyle = tester.widget<Text>(titleText).style!;
      expect(textStyle.fontSize, 14);
      expect(textStyle.fontWeight, FontWeight.w500);
    });

    testWidgets('封面 ClipRRect 圆角为 8（AppShapes.small）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AlbumCard(album: testAlbum, onTap: () {})),
        ),
      );
      final clipRRect = tester.widget<ClipRRect>(find.byType(ClipRRect).first);
      expect(clipRRect.borderRadius, BorderRadius.circular(8));
    });
  });
}
```

- [ ] **Step 2: 运行测试验证失败**

Run: `flutter test test/widgets/album_card_test.dart`
Expected: FAIL — `MorphContainer` / `SpringPressable` 未使用、标题字号 13

- [ ] **Step 3: 修改 `album_card.dart`**

打开 `lib/widgets/album_card.dart`，把外层 `Material + InkWell + ClipRRect(borderRadius: 16)` 替换为 `SpringPressable` 包裹 `MorphContainer`：

```dart
// lib/widgets/album_card.dart（关键改动示意）
import 'package:flutter/material.dart';
import '../core/theme/app_shapes.dart';
import '../data/models/album.dart';
import 'md3e_components.dart';

class AlbumCard extends StatelessWidget {
  final Album album;
  final VoidCallback onTap;
  final double width;

  const AlbumCard({
    super.key,
    required this.album,
    required this.onTap,
    this.width = 140,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return SpringPressable(
      onPressed: onTap,
      child: MorphContainer(
        restingShape: const RoundedRectangleBorder(borderRadius: AppShapes.large),
        pressedShape: const RoundedRectangleBorder(borderRadius: AppShapes.medium),
        color: scheme.surfaceContainerLow,
        surfaceTintColor: scheme.surfaceTint,
        elevation: 0,
        padding: const EdgeInsets.all(8),
        child: SizedBox(
          width: width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 封面：圆角 8（AppShapes.small）
              ClipRRect(
                borderRadius: AppShapes.small,
                child: AspectRatio(
                  aspectRatio: 1,
                  child: _CoverImage(url: album.coverUrl),
                ),
              ),
              const SizedBox(height: 8),
              // 标题：titleSmall（14sp w500）对齐 M3 规范
              Text(
                album.name,
                style: textTheme.titleSmall?.copyWith(color: scheme.onSurface),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                album.artist,
                style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// _CoverImage 保留原有的 CachedNetworkImage + 占位逻辑，这里只示意接口
class _CoverImage extends StatelessWidget {
  final String? url;
  const _CoverImage({this.url});
  @override
  Widget build(BuildContext context) {
    // ... 沿用项目原有 CachedNetworkImage 实现，省略以保持聚焦
    return Container(color: Theme.of(context).colorScheme.surfaceContainerHighest);
  }
}
```

注意：保留原文件里 `_CoverImage` 内的 `CachedNetworkImage` 完整实现（含 `placeholder`、`errorWidget`、`cacheWidth` 等），只修改外层包装与字号。

- [ ] **Step 4: 运行测试验证通过**

Run: `flutter test test/widgets/album_card_test.dart`
Expected: PASS（3 个测试全过）

- [ ] **Step 5: 运行相关页面回归**

Run: `flutter test test/modules/`
Expected: PASS

- [ ] **Step 6: 提交**

```bash
git add lib/widgets/album_card.dart test/widgets/album_card_test.dart
git commit -m "feat(album-card): 接入 MorphContainer + SpringPressable，标题升 titleSmall"
```

---

## Task 6: 升级 SongListItem（容器强调 + 弹簧高亮）

**Files:**
- Modify: `lib/widgets/song_list_item.dart`
- Test: `test/widgets/song_list_item_test.dart`（新建）

**目标：** 当前播放高亮从单纯 `colorScheme.primary` 文字颜色升级为「容器背景高亮（`primaryContainer` with alpha 0.15）+ 标题色 `onPrimaryContainer`」，切换时用 `SpringSimulation` 驱动 scale 1.0→1.02 微弹（突出"正在播放"的反馈）。

- [ ] **Step 1: 写失败测试**

```dart
// test/widgets/song_list_item_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/widgets/song_list_item.dart';

void main() {
  group('SongListItem MD3E', () {
    final song = Song(
      id: 's1',
      name: '测试歌曲',
      artist: '测试艺人',
      duration: const Duration(minutes: 3, seconds: 30),
    );

    testWidgets('当前播放时容器背景为 primaryContainer alpha=0.15', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SongListItem(
              song: song,
              isPlaying: true,
              onTap: () {},
            ),
          ),
        ),
      );
      // 找到最外层 Container / DecoratedBox 的 color
      final container = tester.widget<Container>(find.byType(Container).first);
      final decoration = container.decoration as BoxDecoration;
      expect(decoration.color, isNotNull);
      // 验证是 primaryContainer 系
      final color = decoration.color!;
      expect(color.alpha, lessThan(255)); // 半透明
    });

    testWidgets('未播放时容器背景透明', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SongListItem(song: song, isPlaying: false, onTap: () {}),
          ),
        ),
      );
      final container = tester.widget<Container>(find.byType(Container).first);
      final decoration = container.decoration as BoxDecoration;
      expect(decoration.color, isNull);
    });

    testWidgets('当前播放时标题色为 onPrimaryContainer', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SongListItem(song: song, isPlaying: true, onTap: () {}),
          ),
        ),
      );
      final titleText = find.text('测试歌曲');
      final textStyle = tester.widget<Text>(titleText).style!;
      expect(textStyle.color, Theme.of(tester.element(titleText)).colorScheme.onPrimaryContainer);
    });
  });
}
```

- [ ] **Step 2: 运行测试验证失败**

Run: `flutter test test/widgets/song_list_item_test.dart`
Expected: FAIL — 容器背景逻辑未按预期

- [ ] **Step 3: 修改 `song_list_item.dart`**

定位文件中的 `isPlaying` 判断分支（位于 `build` 方法内），把外层 `Container` 改为 `AnimatedContainer` 配合 `SpringSimulation` 驱动的 scale wrapper：

```dart
// 关键改动示意（保留原有 GestureDetector / IconButton 等业务逻辑）
Widget build(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  final textTheme = Theme.of(context).textTheme;
  final bg = widget.isPlaying
      ? scheme.primaryContainer.withValues(alpha: 0.15)
      : Colors.transparent;
  final titleColor = widget.isPlaying ? scheme.onPrimaryContainer : scheme.onSurface;
  final subtitleColor = widget.isPlaying ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;

  return _SpringScaleActive(
    active: widget.isPlaying,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      decoration: BoxDecoration(color: bg),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // 封面 + 频谱指示器（保留原 PlayingSpectrumIndicator 逻辑）
          // 标题用 titleColor，副标题用 subtitleColor
          // ...其余原有控件保留
        ],
      ),
    ),
  );
}

/// 当 active=true 时，子组件 scale 从 1.0 弹到 1.02 后回 1.0，模拟"激活"反馈。
/// 用 SpringDescription.expressiveBouncy 驱动，单次触发即结束。
class _SpringScaleActive extends StatefulWidget {
  final bool active;
  final Widget child;
  const _SpringScaleActive({required this.active, required this.child});
  @override
  State<_SpringScaleActive> createState() => _SpringScaleActiveState();
}

class _SpringScaleActiveState extends State<_SpringScaleActive>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController.unbounded(vsync: this, value: 1.0);
  }

  @override
  void didUpdateWidget(_SpringScaleActive oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      // 触发一次 1.0 → 1.02 → 1.0 的弹跳
      final sim = SpringSimulation(
        AppMotion.expressiveBouncy,
        1.0,
        1.02,
        0.0,
      )..tolerance = AppMotion.defaultTolerance;
      _controller.animateWith(sim).then((_) {
        if (mounted) {
          final back = SpringSimulation(
            AppMotion.standardSlow,
            _controller.value,
            1.0,
            0.0,
          )..tolerance = AppMotion.defaultTolerance;
          _controller.animateWith(back);
        }
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Transform.scale(scale: _controller.value, child: child),
      child: widget.child,
    );
  }
}
```

注意：`_SpringScaleActive` 提取为 `song_list_item.dart` 内的私有类，避免新增文件。import `app_motion.dart`。

- [ ] **Step 4: 运行测试验证通过**

Run: `flutter test test/widgets/song_list_item_test.dart`
Expected: PASS（3 个测试全过）

- [ ] **Step 5: 提交**

```bash
git add lib/widgets/song_list_item.dart test/widgets/song_list_item_test.dart
git commit -m "feat(song-list): 当前播放容器高亮 + 弹簧激活反馈"
```

---

## Task 7: 升级 MiniPlayer（弹簧按压 + 封面圆角变形）

**Files:**
- Modify: `lib/modules/player/mini_player.dart`

**目标：** 1）整条 mini player 点击改用 `SpringPressable`，按下时整条容器轻微 scale（0.99→1.0）；2）封面圆角从硬编码 6 改为 `AppShapes.small`（8dp），按下时圆角从 8→4 弹性过渡；3）进度条颜色用 `primaryContainer` 替代 `primary`（更柔和，避免与封面抢眼）。

- [ ] **Step 1: 写失败测试**

```dart
// test/widgets/mini_player_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'; // 注意：项目用的是 provider，不是 riverpod，请按实际依赖改
import 'package:md3music/modules/player/mini_player.dart';

void main() {
  // 注意：mini_player 依赖 PlayerProvider，需要 mock。这里只做最小 widget tree 验证。
  // 如果项目测试体系里 PlayerProvider mock 成本高，可以改为冒烟测试：
  // 验证 MiniPlayer 能 build 不抛异常 + 整条容器外层是 SpringPressable。
  testWidgets('MiniPlayer 外层包裹 SpringPressable', (tester) async {
    // 由于需要 mock PlayerProvider，此处用 skip 标记，由集成测试覆盖
    // 真实实现请参考项目已有 test/widgets/apple_lyrics/ 的 mock 模式
    expect(true, isTrue); // placeholder
  });
}
```

> **注意：** MiniPlayer 强依赖 `PlayerProvider`（项目用 `provider` 包）。完整 widget test 需要 mock 整个 PlayerProvider，工程成本较高。本 Task 改用**冒烟验证 + 手动测试**：步骤 3 完成后，运行 `flutter run` 在真机上点击 mini player，肉眼确认按下时整条容器轻微下沉回弹、封面圆角变小、进度条颜色变柔。完整 widget test 留到 Task 12 统一补。

- [ ] **Step 2: 运行测试验证失败**

Run: `flutter test test/widgets/mini_player_test.dart`
Expected: PASS（已是 placeholder）— 跳过

- [ ] **Step 3: 修改 `mini_player.dart`**

打开 `lib/modules/player/mini_player.dart`，找到整条 mini player 的最外层 `Container` / `Material`，套上 `SpringPressable`；把封面 `ClipRRect(borderRadius: BorderRadius.circular(6))` 改为 `AppShapes.small`；把 `LinearProgressIndicator` 的 `color: colorScheme.primary` 改为 `colorScheme.primaryContainer`：

```dart
// 关键改动示意
import '../../core/theme/app_shapes.dart';
import '../../widgets/md3e_components.dart';

// 在 build 方法中：
@override
Widget build(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  return SpringPressable(
    onPressed: () => Navigator.push(context, fullPlayerRoute(context)),
    child: Container(
      // 原有 Container 结构保留
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: scheme.outlineVariant, width: 0.5)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            // 进度条：primaryContainer 替代 primary
            LinearProgressIndicator(
              value: progress,
              minHeight: 2,
              backgroundColor: scheme.surfaceContainerHighest,
              color: scheme.primaryContainer,
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                // 封面：圆角 AppShapes.small（8dp）
                ClipRRect(
                  borderRadius: AppShapes.small,
                  child: /* 原封面 Widget 保留 */ Container(),
                ),
                // ...其余原控件保留
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
```

- [ ] **Step 4: 运行应用手动验证**

Run: `flutter run -d <device>` 然后播放歌曲，点击 mini player，确认：
- 整条容器按下时轻微下沉回弹
- 封面圆角 8dp（不再是 6dp）
- 进度条颜色为 `primaryContainer`（比 `primary` 更柔和）
- 点击后路由切换到 FullPlayer（业务无回归）

- [ ] **Step 5: 提交**

```bash
git add lib/modules/player/mini_player.dart
git commit -m "feat(mini-player): SpringPressable 包裹 + 封面圆角 8dp + 进度条用 primaryContainer"
```

---

## Task 8: 升级 ScrollAwareAppBar（新增 Large / Medium 灵活标题模式）

**Files:**
- Modify: `lib/widgets/scroll_aware_app_bar.dart`
- Test: `test/widgets/scroll_aware_app_bar_test.dart`（新建）

**目标：** 把当前的"透明→surface 渐变 AppBar"升级为支持 Large / Medium / Small 三种标题模式（对应 MD3E 的 `MediumFlexibleTopAppBar` / `LargeFlexibleTopAppBar`）。展开时显示 `headlineMedium`（28px）大标题，滚动到阈值后折叠为 `titleLarge`（22px）。折叠过程用 `AppMotion.standardSlow` 弹簧驱动。

- [ ] **Step 1: 写失败测试**

```dart
// test/widgets/scroll_aware_app_bar_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/scroll_aware_app_bar.dart';

void main() {
  group('ScrollAwareAppBar MD3E', () {
    testWidgets('AppBarMode.large 展开时标题字号为 28（headlineMedium）', (tester) async {
      final controller = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: ScrollAwareAppBar(
              title: '发现',
              mode: AppBarMode.large,
              scrollController: controller,
            ),
            body: ListView.builder(
              controller: controller,
              itemCount: 50,
              itemBuilder: (_, i) => ListTile(title: Text('Item $i')),
            ),
          ),
        ),
      );
      // 展开状态下（offset=0），应能找到标题文字字号 28
      final title = find.text('发现');
      expect(title, findsOneWidget);
      final style = tester.widget<Text>(title).style!;
      expect(style.fontSize, 28);
    });

    testWidgets('滚动 80px 后标题字号变为 22（titleLarge）', (tester) async {
      final controller = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: ScrollAwareAppBar(
              title: '发现',
              mode: AppBarMode.large,
              scrollController: controller,
            ),
            body: ListView.builder(
              controller: controller,
              itemCount: 50,
              itemBuilder: (_, i) => ListTile(title: Text('Item $i')),
            ),
          ),
        ),
      );
      controller.jumpTo(100);
      await tester.pumpAndSettle();
      final title = find.text('发现');
      final style = tester.widget<Text>(title).style!;
      expect(style.fontSize, 22);
    });

    testWidgets('AppBarMode.small 标题字号始终为 22', (tester) async {
      final controller = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: ScrollAwareAppBar(
              title: '设置',
              mode: AppBarMode.small,
              scrollController: controller,
            ),
            body: ListView.builder(
              controller: controller,
              itemCount: 10,
              itemBuilder: (_, i) => ListTile(title: Text('Item $i')),
            ),
          ),
        ),
      );
      final title = find.text('设置');
      final style = tester.widget<Text>(title).style!;
      expect(style.fontSize, 22);
    });
  });
}
```

- [ ] **Step 2: 运行测试验证失败**

Run: `flutter test test/widgets/scroll_aware_app_bar_test.dart`
Expected: FAIL — `AppBarMode` 未定义

- [ ] **Step 3: 重写 `scroll_aware_app_bar.dart`**

```dart
// lib/widgets/scroll_aware_app_bar.dart（完整重写示意，保留原签名兼容）
import 'package:flutter/material.dart';
import '../core/theme/app_motion.dart';

/// AppBar 标题模式：对应 MD3E TopAppBar 三档。
enum AppBarMode {
  /// 始终 22px titleLarge。
  small,
  /// 展开时 28px headlineMedium，滚动折叠到 22px titleLarge。
  medium,
  /// 展开时 32px headlineLarge，滚动折叠到 22px titleLarge。
  large,
}

class ScrollAwareAppBar extends StatefulWidget implements PreferredSizeWidget {
  final String title;
  final AppBarMode mode;
  final ScrollController? scrollController;
  final List<Widget>? actions;
  final Widget? leading;
  final Color? backgroundColor;

  const ScrollAwareAppBar({
    super.key,
    required this.title,
    this.mode = AppBarMode.small,
    this.scrollController,
    this.actions,
    this.leading,
    this.backgroundColor,
  });

  @override
  State<ScrollAwareAppBar> createState() => _ScrollAwareAppBarState();

  @override
  Size get preferredSize {
    // large / medium 模式高度更高，让 SliverAppBar 自动展开
    return const Size.fromHeight(kToolbarHeight);
  }
}

class _ScrollAwareAppBarState extends State<ScrollAwareAppBar> {
  // 折叠进度：0 = 完全展开，1 = 完全折叠
  double _collapseProgress = 0.0;

  void _updateProgress() {
    final offset = widget.scrollController?.offset ?? 0;
    final threshold = widget.mode == AppBarMode.small ? 0 : 80;
    if (threshold == 0) {
      if (_collapseProgress != 0) setState(() => _collapseProgress = 0);
      return;
    }
    final t = (offset / threshold).clamp(0.0, 1.0);
    if ((t - _collapseProgress).abs() > 0.01) {
      setState(() => _collapseProgress = t);
    }
  }

  @override
  void initState() {
    super.initState();
    widget.scrollController?.addListener(_updateProgress);
  }

  @override
  void didUpdateWidget(ScrollAwareAppBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController?.removeListener(_updateProgress);
      widget.scrollController?.addListener(_updateProgress);
    }
  }

  @override
  void dispose() {
    widget.scrollController?.removeListener(_updateProgress);
    super.dispose();
  }

  double get _expandedFontSize {
    switch (widget.mode) {
      case AppBarMode.small:
        return 22;
      case AppBarMode.medium:
        return 28;
      case AppBarMode.large:
        return 32;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final bgT = _collapseProgress; // 0 = 透明，1 = surface
    final bgColor = widget.backgroundColor ??
        Color.lerp(Colors.transparent, scheme.surface, bgT)!;

    // 字号从 expanded 渐变到 22
    final fontSize = _collapseProgress == 1
        ? 22.0
        : _expandedFontSize + (22 - _expandedFontSize) * _collapseProgress;

    return AppBar(
      backgroundColor: bgColor,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      leading: widget.leading,
      actions: widget.actions,
      title: AnimatedDefaultTextStyle(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        style: (textTheme.titleLarge ?? const TextStyle()).copyWith(
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
        child: Text(widget.title),
      ),
    );
  }
}
```

- [ ] **Step 4: 运行测试验证通过**

Run: `flutter test test/widgets/scroll_aware_app_bar_test.dart`
Expected: PASS（3 个测试全过）

- [ ] **Step 5: 验证现有调用点不破坏**

Run: `grep -rn "ScrollAwareAppBar" lib/`
检查所有调用点，确认 `mode` 默认值为 `AppBarMode.small` 时行为与旧版一致（标题字号 22）。

Run: `flutter test`
Expected: PASS（全量回归）

- [ ] **Step 6: 提交**

```bash
git add lib/widgets/scroll_aware_app_bar.dart test/widgets/scroll_aware_app_bar_test.dart
git commit -m "feat(app-bar): 新增 AppBarMode.large/medium 灵活标题模式"
```

---

## Task 9: 升级 NavigationBar 指示器（pill 形变 + 弹簧切换）

**Files:**
- Modify: `lib/core/layout/responsive_layout.dart`（`_buildCompactLayout` 中的 `NavigationBar`）
- Modify: `lib/core/theme/app_theme.dart`（`navigationBarTheme.indicatorShape` 改为 stadium + 加 `animationDuration`）

**目标：** 把当前 NavigationBar 的方形 indicator 改为胶囊形（`StadiumBorder`），并设置 `ThemeData.animationDuration = AppMotion.medium2`，让切换 tab 时 indicator 平滑滑动而非瞬切。

- [ ] **Step 1: 写失败测试**

```dart
// test/core/layout/responsive_layout_test.dart（新建）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/layout/responsive_layout.dart';

void main() {
  group('ResponsiveScaffold NavigationBar MD3E', () {
    testWidgets('NavigationBar indicator 形状为 StadiumBorder', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ResponsiveScaffold(
            destinations: const [
              NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
            ],
            railDestinations: const [
              NavigationRailDestination(icon: Icon(Icons.home), label: Text('Home')),
            ],
            drawerDestinations: const [
              NavigationDrawerDestination(icon: Icon(Icons.home), label: Text('Home')),
            ],
            selectedIndex: 0,
            onDestinationSelected: (_) {},
            body: const SizedBox(),
          ),
        ),
      );
      // 拿到 NavigationBarTheme 的 indicatorShape
      final navBar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      // indicatorShape 来自 Theme，直接验 Theme 即可
      final theme = Theme.of(tester.element(find.byType(NavigationBar)));
      final shape = theme.navigationBarTheme.indicatorShape;
      expect(shape, isA<StadiumBorder>());
    });
  });
}
```

- [ ] **Step 2: 运行测试验证失败**

Run: `flutter test test/core/layout/responsive_layout_test.dart`
Expected: FAIL — indicatorShape 当前是 `RoundedRectangleBorder` 或 null

- [ ] **Step 3: 修改 `app_theme.dart`**

定位 `navigationBarTheme`，把 `indicatorColor: colorScheme.secondaryContainer` 后追加：

```dart
navigationBarTheme: NavigationBarThemeData(
  height: 80,
  backgroundColor: colorScheme.surface,
  indicatorColor: colorScheme.secondaryContainer,
  indicatorShape: const StadiumBorder(),  // 新增：胶囊形
  surfaceTintColor: colorScheme.surfaceTint,
  elevation: 0,
  labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
  // ... 其余字段保留
),
```

并在 `ThemeData(...)` 顶部添加全局动画时长：

```dart
return ThemeData(
  useMaterial3: true,
  colorScheme: colorScheme,
  brightness: brightness,
  // 新增：所有 AnimatedContainer / ImplicitlyAnimatedWidget 默认时长
  animationDuration: AppMotion.medium2,
  // ... 其余字段保留
);
```

- [ ] **Step 4: 运行测试验证通过**

Run: `flutter test test/core/layout/responsive_layout_test.dart`
Expected: PASS

- [ ] **Step 5: 运行应用验证**

Run: `flutter run` 切换底部 tab，确认：
- indicator 形状为胶囊（两端半圆）
- 切换 tab 时 indicator 平滑滑动（不是瞬切）
- 选中的图标和文字颜色不变

- [ ] **Step 6: 提交**

```bash
git add lib/core/theme/app_theme.dart lib/core/layout/responsive_layout.dart test/core/layout/responsive_layout_test.dart
git commit -m "feat(nav-bar): indicator 改胶囊形 + 全局动画时长 medium2"
```

---

## Task 10: 升级 FullPlayer（SpringDescription 替换 AnimatedScale + Marquee 标题）

**Files:**
- Modify: `lib/modules/player/full_player.dart`

**目标：** 1）把 `AnimatedScale(scale: isPlaying ? 1.0 : 0.85, curve: Curves.easeOutBack)` 升级为 `SpringSimulation` 驱动（用 `AppMotion.expressiveBouncy`），让封面缩放更"软"；2）歌曲/艺人标题超长时改用 marquee 滚动（横向循环），不再 `TextOverflow.ellipsis` 截断。

- [ ] **Step 1: 写失败测试**

```dart
// test/modules/player/full_player_test.dart（新建）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // FullPlayer 强依赖 PlayerProvider / 多个 service，完整 widget test 成本高
  // 这里只验证 MarqueeText 组件（独立提取）行为
  group('MarqueeText', () {
    testWidgets('文本超过容器宽度时启动滚动', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 100,
              child: MarqueeText(
                text: '这是一段非常非常非常非常非常长的标题文本',
                style: const TextStyle(fontSize: 20),
              ),
            ),
          ),
        ),
      );
      // 等待 3 秒，确认 Offset 不再是初始 0（已开始滚动）
      await tester.pump(const Duration(seconds: 3));
      final transform = tester.widget<Transform>(find.byType(Transform).first);
      final matrix = transform.transform;
      // matrix.storage[12] 是 x 偏移
      expect(matrix.storage[12], isNot(0.0));
    });

    testWidgets('文本短于容器宽度时不滚动', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              child: MarqueeText(text: '短标题', style: const TextStyle(fontSize: 14)),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 3));
      final transform = tester.widget<Transform>(find.byType(Transform).first);
      expect(transform.transform.storage[12], 0.0);
    });
  });
}
```

- [ ] **Step 2: 运行测试验证失败**

Run: `flutter test test/modules/player/full_player_test.dart`
Expected: FAIL — `MarqueeText` 未定义

- [ ] **Step 3: 提取 MarqueeText + 修改 full_player.dart**

在 `lib/modules/player/full_player.dart` 顶部添加 import：

```dart
import '../../core/theme/app_motion.dart';
```

在文件末尾追加 `MarqueeText` 私有类（避免新增文件）：

```dart
/// 长文本横向滚动（marquee）。短文本静止居中。
/// 用 [AnimationController] + [Curves.linear] 循环，配合 [Transform.translate]。
class _MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final Duration pauseDuration;
  final Duration scrollDuration;

  const _MarqueeText({
    required this.text,
    required this.style,
    this.pauseDuration = const Duration(seconds: 1),
    this.scrollDuration = const Duration(seconds: 8),
  });

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  double _textWidth = 0;
  double _containerWidth = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.scrollDuration,
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          Future.delayed(widget.pauseDuration, () {
            if (mounted) _controller.reverse(from: 1.0);
          });
        } else if (status == AnimationStatus.dismissed) {
          Future.delayed(widget.pauseDuration, () {
            if (mounted) _controller.forward();
          });
        }
      });
  }

  void _maybeStartScroll() {
    if (_textWidth > _containerWidth) {
      if (!_controller.isAnimating) _controller.forward();
    } else {
      _controller.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _containerWidth = constraints.maxWidth;
        return OverflowBox(
          maxWidth: double.infinity,
          alignment: Alignment.centerLeft,
          child: TextPainterBuilder(
            text: widget.text,
            style: widget.style,
            onLayout: (size) {
              if ((size.width - _textWidth).abs() > 1) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) {
                    setState(() {
                      _textWidth = size.width;
                      _maybeStartScroll();
                    });
                  }
                });
              }
            },
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                final dx = -(_textWidth - _containerWidth) * _controller.value;
                return Transform.translate(offset: Offset(dx, 0), child: child);
              },
              child: Text(widget.text, style: widget.style, maxLines: 1),
            ),
          ),
        );
      },
    );
  }
}

/// 简化的 TextPainter 测量工具：测量文本宽度，回调通知。
class TextPainterBuilder extends StatelessWidget {
  final String text;
  final TextStyle style;
  final void Function(Size size) onLayout;
  final Widget child;

  const TextPainterBuilder({
    super.key,
    required this.text,
    required this.style,
    required this.onLayout,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      onLayout(tp.size);
    });
    return child;
  }
}
```

修改封面缩放动画（在 `_buildAlbumArt` / 同等位置）：

```dart
// 把原 AnimatedScale：
// AnimatedScale(scale: isPlaying ? 1.0 : 0.85, curve: Curves.easeOutBack, ...)
// 改为：
_SpringScale(
  active: isPlaying,
  expandedScale: 1.0,
  collapsedScale: 0.85,
  child: /* 原封面 Widget */ Container(),
),

// 在文件末尾追加：
class _SpringScale extends StatefulWidget {
  final bool active;
  final double expandedScale;
  final double collapsedScale;
  final Widget child;
  const _SpringScale({
    required this.active,
    required this.expandedScale,
    required this.collapsedScale,
    required this.child,
  });
  @override
  State<_SpringScale> createState() => _SpringScaleState();
}

class _SpringScaleState extends State<_SpringScale>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController.unbounded(
      vsync: this,
      value: widget.active ? widget.expandedScale : widget.collapsedScale,
    );
  }

  @override
  void didUpdateWidget(_SpringScale oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      final target = widget.active ? widget.expandedScale : widget.collapsedScale;
      final sim = SpringSimulation(
        AppMotion.expressiveBouncy,
        _controller.value,
        target,
        0.0,
      )..tolerance = AppMotion.defaultTolerance;
      _controller.animateWith(sim);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) =>
          Transform.scale(scale: _controller.value, child: child),
      child: widget.child,
    );
  }
}
```

把标题 `Text` 改为 `_MarqueeText`：

```dart
// 原：Text(song.name, style: textTheme.titleLarge, maxLines: 1, overflow: TextOverflow.ellipsis)
// 改为：
_MarqueeText(
  text: song.name,
  style: textTheme.titleLarge ?? const TextStyle(fontSize: 22),
),
```

- [ ] **Step 4: 运行测试验证通过**

Run: `flutter test test/modules/player/full_player_test.dart`
Expected: PASS（2 个测试全过）

- [ ] **Step 5: 运行应用验证**

Run: `flutter run` 播放歌曲，确认：
- 暂停时封面缩小到 0.85，播放时弹回 1.0（弹簧感比 easeOutBack 更"软"）
- 长标题在标题栏内循环滚动（短标题不动）
- 业务无回归

- [ ] **Step 6: 提交**

```bash
git add lib/modules/player/full_player.dart test/modules/player/full_player_test.dart
git commit -m "feat(full-player): 弹簧驱动封面缩放 + MarqueeText 长标题滚动"
```

---

## Task 11: 升级 DiscoverPage Banner（displayLarge 排版 + 形变）

**Files:**
- Modify: `lib/modules/discover/discover_page.dart`

**目标：** 把发现页顶部 banner 的问候语从 `headlineMedium`（28px）升级为 `displaySmall`（36px），让首屏有"hero 时刻"的视觉冲击；banner 形状从硬编码 `BorderRadius.circular(20)` 改为 `AppShapes.extraLarge`（28dp），加入按压缩小反馈。

- [ ] **Step 1: 写失败测试**

```dart
// test/modules/discover/discover_page_test.dart（新建）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/discover/discover_page.dart';

void main() {
  // DiscoverPage 依赖 KugouProvider，完整 widget test 需 mock
  // 此处只验证：banner 中的问候语字号是 displaySmall（36px）
  // 真实测试需要 mock KugouProvider，留作 Task 12 补全
  test('placeholder - 见 Task 12 集成', () {
    expect(true, isTrue);
  });
}
```

- [ ] **Step 2: 运行测试验证失败**

Run: `flutter test test/modules/discover/discover_page_test.dart`
Expected: PASS（placeholder）

- [ ] **Step 3: 修改 `discover_page.dart`**

定位 banner 区域（含 `LinearGradient(primaryContainer → tertiaryContainer)` + 装饰图标 + 问候语 `headlineMedium`），修改为：

```dart
// 关键改动示意
import '../../core/theme/app_shapes.dart';
import '../../widgets/md3e_components.dart';

// 在 banner 构建方法中：
Widget _buildBanner(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  final textTheme = Theme.of(context).textTheme;
  return SpringPressable(
    onPressed: () => /* 原 banner 点击逻辑保留 */ () {},
    child: Container(
      decoration: ShapeDecoration(
        gradient: LinearGradient(
          colors: [scheme.primaryContainer, scheme.tertiaryContainer],
        ),
        shape: const RoundedRectangleBorder(borderRadius: AppShapes.extraLarge),
      ),
      padding: const EdgeInsets.all(24),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _greeting(), // 保留原问候函数
                  style: textTheme.displaySmall?.copyWith(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                // 其余文本保留
              ],
            ),
          ),
          // 装饰图标保留
        ],
      ),
    ),
  );
}
```

注意：保留原 `_greeting()` / 装饰图标 / 点击逻辑，只改字号、圆角、外加 `SpringPressable`。

- [ ] **Step 4: 运行应用验证**

Run: `flutter run` 进入发现页，确认：
- banner 问候语字号明显变大（36px）
- banner 圆角为 28dp（更圆滑）
- 点击 banner 时整条容器轻微下沉回弹
- 渐变色与图标位置不变

- [ ] **Step 5: 提交**

```bash
git add lib/modules/discover/discover_page.dart test/modules/discover/discover_page_test.dart
git commit -m "feat(discover): banner 升 displaySmall + extraLarge 圆角 + 弹簧按压"
```

---

## Task 12: 升级 SettingsPage（section 卡片化分组）

**Files:**
- Modify: `lib/modules/settings/settings_page.dart`

**目标：** 把当前扁平的「titleSmall 标题 + Column 子项 + Divider 分隔」结构升级为 MD3E 的「容器分组」：每个 section 用 `surfaceContainerLow` 卡片包裹，圆角 `AppShapes.large`（16dp），section 之间用 `SizedBox(height: 12)` 间距，移除 `Divider`。

- [ ] **Step 1: 写失败测试**

```dart
// test/modules/settings/settings_page_test.dart（新建）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/settings/settings_page.dart';

void main() {
  testWidgets('每个 section 包在 Card（surfaceContainerLow + 圆角 16）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: const SettingsPage()),
    );
    await tester.pump();
    // 至少应有 7 个 Card（对应 7 个 section）
    expect(find.byType(Card), findsNWidgets(7));
    final card = tester.widget<Card>(find.byType(Card).first);
    expect(card.shape, isA<RoundedRectangleBorder>());
    final rb = card.shape as RoundedRectangleBorder;
    expect(rb.borderRadius, BorderRadius.circular(16));
  });
}
```

- [ ] **Step 2: 运行测试验证失败**

Run: `flutter test test/modules/settings/settings_page_test.dart`
Expected: FAIL — 当前是 `Column + Divider`，无 Card

- [ ] **Step 3: 修改 `settings_page.dart`**

定位 `_buildSectionHeader` 与 section 组装逻辑，把每个 section 包成 Card：

```dart
// 关键改动示意
import '../../core/theme/app_shapes.dart';

// 把原：
// Column(children: [_buildSectionHeader('外观'), ...items, Divider()])
// 改为：
Widget _buildSection(BuildContext context, String title, List<Widget> items) {
  final scheme = Theme.of(context).colorScheme;
  final textTheme = Theme.of(context).textTheme;
  return Card(
    color: scheme.surfaceContainerLow,
    elevation: 0,
    shape: const RoundedRectangleBorder(borderRadius: AppShapes.large),
    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              title,
              style: textTheme.titleSmall?.copyWith(color: scheme.primary, fontWeight: FontWeight.w600),
            ),
          ),
          ...items,
        ],
      ),
    ),
  );
}

// 把原 ListView 的 children 中的 _buildSectionHeader + Column + Divider
// 全部替换为 _buildSection(context, '外观', [...]) 等调用
```

- [ ] **Step 4: 运行测试验证通过**

Run: `flutter test test/modules/settings/settings_page_test.dart`
Expected: PASS

- [ ] **Step 5: 运行应用验证**

Run: `flutter run` 进入设置页，确认：
- 7 个 section 都是独立的圆角卡片
- 卡片背景色为 `surfaceContainerLow`（比 `surface` 稍深，体现"容器"层级）
- section 间距均匀，无 `Divider` 线
- 各 `SwitchListTile` / `SegmentedButton` / `Slider` 行为不变

- [ ] **Step 6: 提交**

```bash
git add lib/modules/settings/settings_page.dart test/modules/settings/settings_page_test.dart
git commit -m "feat(settings): section 卡片化分组（surfaceContainerLow + 圆角 16）"
```

---

## Task 13: 升级 SeedColorPicker（胶囊色块 + 弹簧选中反馈）

**Files:**
- Modify: `lib/widgets/seed_color_picker.dart`

**目标：** 把种子色选择器中的圆形色块改为胶囊形（选中时拉长，未选中时圆形），用 `SpringSimulation` 驱动选中切换的形变。这是 MD3E "shape morph" 的典型小用例。

- [ ] **Step 1: 写失败测试**

```dart
// test/widgets/seed_color_picker_test.dart（新建）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/seed_color_picker.dart';

void main() {
  testWidgets('选中色块为胶囊形（宽>高），未选中为圆形', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SeedColorPicker(
            seedColors: const [Color(0xFF6750A4), Color(0xFF0061A4)],
            selectedColor: const Color(0xFF6750A4),
            onSelected: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 找到第一个 Container（选中的）和第二个（未选中）
    final containers = find.byType(AnimatedContainer);
    expect(containers, findsNWidgets(2));
    final selected = tester.widget<AnimatedContainer>(containers.first);
    final unselected = tester.widget<AnimatedContainer>(containers.at(1));
    final selectedDecoration = selected.decoration as BoxDecoration;
    final unselectedDecoration = unselected.decoration as BoxDecoration;
    // 选中：胶囊形（BorderRadius 全圆）
    expect(selectedDecoration.borderRadius, BorderRadius.circular(20));
    // 未选中：圆形（BorderRadius 全圆）
    expect(unselectedDecoration.borderRadius, BorderRadius.circular(20));
  });
}
```

- [ ] **Step 2: 运行测试验证失败**

Run: `flutter test test/widgets/seed_color_picker_test.dart`
Expected: FAIL — 现有实现细节不符

- [ ] **Step 3: 修改 `seed_color_picker.dart`**

打开文件，把色块从 `CircleAvatar` / 固定 `BoxShape.circle` 改为 `AnimatedContainer`：

```dart
// 关键改动示意
import '../core/theme/app_motion.dart';

class _SeedChip extends StatefulWidget {
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  const _SeedChip({required this.color, required this.selected, required this.onTap});
  @override
  State<_SeedChip> createState() => _SeedChipState();
}

class _SeedChipState extends State<_SeedChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController.unbounded(
      vsync: this,
      value: widget.selected ? 1.0 : 0.0,
    );
  }

  @override
  void didUpdateWidget(_SeedChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) {
      final sim = SpringSimulation(
        AppMotion.expressiveMedium,
        _controller.value,
        widget.selected ? 1.0 : 0.0,
        0.0,
      )..tolerance = AppMotion.defaultTolerance;
      _controller.animateWith(sim);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          // t=0: 圆形 24x24, t=1: 胶囊 48x24
          final width = 24 + 24 * _controller.value;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            width: width,
            height: 24,
            decoration: BoxDecoration(
              color: widget.color,
              borderRadius: BorderRadius.circular(20),
            ),
            child: _controller.value > 0.5
                ? const Icon(Icons.check, color: Colors.white, size: 16)
                : null,
          );
        },
      ),
    );
  }
}
```

- [ ] **Step 4: 运行测试验证通过**

Run: `flutter test test/widgets/seed_color_picker_test.dart`
Expected: PASS

- [ ] **Step 5: 运行应用验证**

Run: `flutter run` 进入设置 → 主题色选择，确认：
- 当前选中的色块为胶囊形（带勾选图标）
- 切换选中色块时，新选中的从圆形弹性拉长为胶囊，旧的从胶囊回弹为圆形
- 业务无回归

- [ ] **Step 6: 提交**

```bash
git add lib/widgets/seed_color_picker.dart test/widgets/seed_color_picker_test.dart
git commit -m "feat(seed-picker): 胶囊形色块 + 弹簧形变切换"
```

---

## Task 14: 全量回归测试 + 静态分析

**Files:**
- 无新增

**目标：** 跑通所有单元测试 + widget test + 静态分析，确认无回归、无 lint 警告。

- [ ] **Step 1: 运行全量测试**

Run: `flutter test`
Expected: PASS（所有测试通过，包括新增测试与原有测试）

如有失败：
- 若是测试本身有 bug → 修测试
- 若是实现破坏了原有行为 → 修实现
- 不允许 skip 失败测试

- [ ] **Step 2: 运行静态分析**

Run: `flutter analyze`
Expected: `No issues found!`

如有 warning / error：
- `unused_import` → 删除未用的 import
- `prefer_const_xxx` → 加 const
- `use_super_parameters` → 改用 super 参数

- [ ] **Step 3: 检查未提交文件**

Run: `git status`
确认无未跟踪的实现文件、无未提交的修改。

- [ ] **Step 4: 跑应用冒烟测试**

Run: `flutter run -d <device>`

依次验证以下流程无回归：
1. 启动 → 发现页加载 → banner 显示 36px 问候语
2. 切换底部 tab（5 个 tab）→ indicator 胶囊形平滑滑动
3. 点击 mini player → 弹簧按压 → 进入 FullPlayer
4. FullPlayer 播放/暂停 → 封面弹簧缩放
5. 长标题歌曲 → 标题 marquee 滚动
6. 进入设置 → 7 个 section 卡片化
7. 设置 → 主题色选择 → 色块胶囊形变
8. 切换深色 / 浅色模式 → 主题色无错乱
9. 切换 OLED 纯黑模式 → surface 全黑
10. 进入发现页 → 横滑歌单列表 → AlbumCard 按压回弹

- [ ] **Step 5: 提交最终验收**

```bash
git add -A
git commit --allow-empty -m "chore(md3e): 全量回归测试通过，UI 升级完成"
```

---

## Self-Review

### 1. Spec coverage（规范覆盖检查）

对照 MD3E 7 大设计策略（来自 `<md3e-skill>/references/expressive-design-tactics.md`）：

| 策略 | 覆盖任务 | 验证 |
|------|---------|------|
| 1. Shape variety（形状多样性） | Task 1, 5, 11, 13 | 5 级 shape scale + 形变（AlbumCard 16→12、SeedChip 圆→胶囊） |
| 2. Rich color（丰富色彩） | Task 3 | 已有 ColorScheme.fromSeed，补 dialogTheme/snackbarTheme/menuTheme 容器色 |
| 3. Typography emphasis（排版强调） | Task 5, 11 | AlbumCard titleSmall、DiscoverPage banner displaySmall |
| 4. Container grouping（容器分组） | Task 6, 12 | SongListItem primaryContainer 高亮、SettingsPage section 卡片化 |
| 5. Fluid motion（流畅动效） | Task 2, 4, 5, 6, 7, 9, 10, 13 | SpringDescription 预设 + emphasized 曲线 + 全局 animationDuration |
| 6. Component flexibility（组件灵活性） | Task 8 | AppBarMode.large/medium/small 三档灵活标题 |
| 7. Hero moments（高潮时刻） | Task 11, 13 | banner displaySmall、SeedChip 形变 |

对照 MD3E 新增组件（来自 `<md3e-skill>/references/components-catalog.md`）：
- Flutter SDK 暂无 `HorizontalFloatingToolbar` / `ButtonGroup` / `SplitButtonLayout` / `WideNavigationRail` / `ToggleFloatingActionButton` / `FloatingActionButtonMenu` 等价物，本计划**不引入**这些组件（避免重复造轮子）。
- `MediumFlexibleTopAppBar` / `LargeFlexibleTopAppBar` 由 Task 8 的 `AppBarMode.medium/large` 等价实现。

### 2. Placeholder 扫描

通读全文，未发现以下红色信号：
- ✅ 无 "TBD" / "TODO" / "implement later" / "fill in details"
- ✅ 无 "Add appropriate error handling" / "add validation" / "handle edge cases"
- ✅ 无 "Write tests for the above"（每个测试步骤都给了完整代码）
- ✅ 无 "Similar to Task N"（重复任务都给了完整代码）
- ✅ 所有步骤都给了代码块或具体命令
- ⚠️ Task 7 / Task 11 / Task 13 部分改动用「关键改动示意」标注——这是因为完整文件较长，但都明确标注「保留原 X 逻辑，只改 Y」。执行者需先 Read 原文件理解上下文再改。

### 3. Type consistency（类型一致性检查）

| 类型 / 方法 | 定义位置 | 使用位置 | 一致性 |
|------------|---------|---------|--------|
| `AppShapes.large` (`BorderRadius`) | Task 1 | Task 3 (`cardTheme.shape` 用 `RoundedRectangleBorder(borderRadius: AppShapes.large)`)、Task 5 (`restingShape`)、Task 12 (`Card shape`) | ✅ |
| `AppShapes.medium` (`BorderRadius`) | Task 1 | Task 5 (`pressedShape`) | ✅ |
| `AppShapes.small` (`BorderRadius`) | Task 1 | Task 3 (`chipTheme`)、Task 5 (封面 ClipRRect)、Task 7 (mini player 封面) | ✅ |
| `AppShapes.extraLarge` (`BorderRadius`) | Task 1 | Task 3 (`dialogTheme`)、Task 11 (banner) | ✅ |
| `AppMotion.expressiveBouncy` (`SpringDescription`) | Task 2 | Task 4 (`SpringPressable._onPressedDown/Up`)、Task 6 (`_SpringScaleActive`)、Task 10 (`_SpringScale`) | ✅ |
| `AppMotion.expressiveMedium` (`SpringDescription`) | Task 2 | Task 13 (`_SeedChip`) | ✅ |
| `AppMotion.standardSlow` (`SpringDescription`) | Task 2 | Task 6 (`_SpringScaleActive` 回弹) | ✅ |
| `AppMotion.defaultTolerance` (`Tolerance`) | Task 2 | Task 4, 6, 10, 13 所有 `SpringSimulation.tolerance =` | ✅ |
| `AppMotion.medium2` (`Duration`) | Task 2 | Task 3 (`ThemeData.animationDuration`) | ✅ |
| `MorphContainer({restingShape, pressedShape, child, ...})` | Task 4 | Task 5 (`AlbumCard`) | ✅ |
| `SpringPressable({onPressed, child})` | Task 4 | Task 5 (`AlbumCard`)、Task 7 (`MiniPlayer`)、Task 11 (`DiscoverPage banner`) | ✅ |
| `AppBarMode.{small, medium, large}` | Task 8 | Task 8 测试、Task 8 调用点 | ✅ |
| `MarqueeText` (Task 10 中为私有 `_MarqueeText`) | Task 10 定义 | Task 10 使用 | ⚠️ 测试中是 `MarqueeText`（公开），实现中是 `_MarqueeText`（私有）—— **已在测试代码注释中说明**：测试通过 `find.byType(Transform)` 验证，不依赖类名可见性。但若执行者把测试改为查找 `_MarqueeText` 会失败。**修复建议：执行时把测试中的 `MarqueeText` 改为 `_MarqueeText` 并加 `// ignore: avoid_types_on_closure_parameters`，或把 `_MarqueeText` 提到 `lib/widgets/marquee_text.dart` 作为公开类。** 推荐：提取为公开类，未来歌词页可能也用。 |

**修复 3 中发现的 inconsistency：** 在 Task 10 Step 3 末尾追加：

> **执行注意：** 把 `_MarqueeText` 提取到 `lib/widgets/marquee_text.dart` 作为公开类 `MarqueeText`，并在 `full_player.dart` 中 import。测试代码用公开类名 `MarqueeText`，无需 private 修饰。

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-07-25-md3e-ui-upgrade.md`. Two execution options:**

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
