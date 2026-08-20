# MD3Music 适配液态玻璃（Liquid Glass）UI 计划

> 状态：计划阶段（先做 Demo 验证，通过后再推广到核心界面）
> 日期：2026-08-16
> 分支范围：本文档适用于当前分支 `rust-local-two`；仅涉及 `lib/` 前端代码，不触碰 Rust 服务器与原生层。

---

## 1. 背景与目标

MD3Music 目前采用 Material Design 3 动态取色（`dynamic_color` + `material_color_utilities`）主题。
计划引入 iOS 26 风格的**液态玻璃（Liquid Glass）**视觉，为播放器营造「实时模糊 + 高光折射」的沉浸感。

本阶段**目标仅限 Demo 验证**：在 app 内新增一个独立演示页面，用真实组件跑通视觉与性能，形成取舍结论后，再决定是否推广到播放器核心界面。

**不做**（本阶段）：不修改任何现有页面、不动播放器核心 UI、不改主题系统。

---

## 2. 选型结论

选型基础：**`liquid_glass_widgets`**（作者 sdegenaar，pub.dev 最新 `0.29.5`，MIT）。

| 维度 | 结论 |
|------|------|
| 成熟度 | 703 commits、36+ 组件、6 大类，持续维护（2026-08 仍在发版） |
| 还原度 | 忠实实现 iOS 26 Liquid Glass：自定义 fragment shader 实时模糊 + 折射 + 色散 + 果冻动效 |
| 渲染路径 | Impeller 原生两遍高斯模糊 + shader 折射；Skia/Web 自动降级轻量 shader |
| 依赖 | **零第三方运行时依赖**，仅 Flutter SDK（对混合架构项目友好，不引入新原生库） |
| 无障碍 | 默认读取系统 Reduce Motion / Reduce Transparency，WCAG 友好 |
| 质量兜底 | `adaptiveQuality` 自动基准设备、质量自适应降级 |

**备选**（未采用）：`glassmorphic_ui`（组件也全，但还原度与活跃度略低）、`liquid_glass_easy`（聚焦实时透镜，组件面窄）、`liquid_glass_kit`（仅核心容器，过轻）。

---

## 3. 兼容性评估

| 检查项 | 项目现状 | 要求 | 结论 |
|--------|----------|------|------|
| Flutter 版本 | 本机 `3.44.7`（channel stable） | 包要求 `≥ 3.41.0`（推荐 3.41+ 获最佳 Impeller 效果） | ✅ 满足 |
| Dart SDK | 项目 `sdk: ^3.12.0`，本机 `3.12.2` | 包要求 `Dart ≥ 3.5.0` | ✅ 满足 |
| Android 渲染 | 项目启用 Impeller（现代 Android 默认） | 包在 Impeller/Vulkan 效果最佳 | ✅ 预期良好 |
| 主题冲突 | 项目 MD3 动态取色 | 玻璃组件可独立 `theme` 配置，不强制覆盖 | ✅ 可共存 |
| 依赖冲突风险 | 历史上有 `meta ^1.18.0` 与 `flutter_test` 冲突（0.18.x 时代） | 最新版已配合 Flutter 3.41+ 修正约束 | ⚠️ 需 `flutter pub get` 实际验证 |

**结论**：本机 Flutter 3.44.7 满足最新版要求，可直接使用 `liquid_glass_widgets: ^0.29.5`。

---

## 4. 集成方式（Demo 落地）

### 4.1 添加依赖

```yaml
# pubspec.yaml dependencies
liquid_glass_widgets: ^0.29.5
```

### 4.2 全局初始化（main.dart）

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LiquidGlassWidgets.initialize(); // 预热 shader，消除首帧闪烁

  runApp(LiquidGlassWidgets.wrap(
    child: const MD3MusicApp(),
    brightnessResolver: Theme.maybeBrightnessOf, // 让玻璃跟随 MaterialApp 的 ThemeMode
    adaptiveQuality: true, // 低端机自动降级
  ));
}
```

> 注意：MD3Music 的入口在 `lib/main.dart`，需在现有「权限请求 → 启动 Rust 服务器 → runApp」流程中插入初始化。
> `initialize()` 放在服务器启动之前或之后均可，`wrap()` 只包 Widget 树，不影响服务器线程。

### 4.3 Demo 页面

新增 `lib/modules/demo/liquid_glass_demo_page.dart`（独立入口，不进主导航），集中验证：

| 组件 | 验证点 |
|------|--------|
| `GlassScaffold` / `GlassAppBar` / `GlassTabBar` | 页面背景 + 状态栏 + 顶部玻璃导航 |
| `GlassCard` / `GlassContainer` / `GlassListTile` | 浮层卡片在滚动内容上的实时背影模糊 |
| `GlassBottomBar` | 底部导航玻璃条（对播放器最相关） |
| `GlassButton` / `GlassSwitch` / `GlassChip` | 交互控件与 MD3 触感是否协调 |
| `GlassSheet` / `GlassDialog` | 播放器弹层 / 选项菜单替换潜力 |
| `GlassTextField` / `GlassSearchBar` | 搜索页替换潜力 |
| `GlassMotionScope` | 陀螺仪/传感器驱动高光（仅作效果演示） |

Demo 背景用一张本地图片（模拟播放器封面墙），验证「玻璃对动态背景的实时折射」。

---

## 5. 验证指标与通过标准

Demo 跑通后，按以下维度给出「是否推广」的结论：

| 维度 | 验证方式 | 通过标准 |
|------|----------|----------|
| 视觉观感 | 真机截图对比 MD3 原生 | 玻璃模糊/高光饱满，无「平板玻璃」感 |
| 性能 | Android Profiler / 帧率监控 | 普通页面不掉帧；低端机 `adaptiveQuality` 降级后仍流畅 |
| 主题协调 | 深/浅色模式各验证一次 | `brightnessResolver` 生效，玻璃随 ThemeMode 正确着色 |
| 无障碍 | 开启系统 Reduce Motion / Transparency | 玻璃静态化、无碍读屏 |
| 侵入性 | `git diff` 审查 | Demo 仅新增页面 + main.dart 两行初始化，零改动现有业务代码 |

---

## 6. 风险与已知问题

1. **iOS 引擎级 bug（仅物理 iPhone 高画质）**：`GlassBottomBar` 选中指示器在物理 iOS + Impeller 高画质下曾出现「不透明白块」（flutter/flutter#187820）。本机测试以 Android 为主，iOS 需在真机复测画质档位。
2. **深色模式着色**：必须传入 `brightnessResolver: Theme.maybeBrightnessOf`，否则系统深色下玻璃可能丢失阴影/描边。
3. **依赖解析**：历史上存在 `meta` 版本与 `flutter_test`/`flutter_lints` 的冲突，`pub get` 时需留意解析结果。
4. **性能上限**：Impeller 两遍高斯模糊在高分辨率大玻璃面上开销较大，Demo 需重点测「大玻璃 + 滚动 + 动态背景」组合。
5. **与 MD3 视觉语言差异**：液态玻璃偏 iOS 审美，与现有 MD3 组件并存时需评估一致性，避免「半套玻璃半套 MD3」割裂。

---

## 7. 后续推广路线（Demo 通过后）

> 仅作前瞻，不在本阶段执行。

1. **快赢**：底部导航栏 → 播放器弹层（`GlassSheet`）→ 搜索页（`GlassSearchBar`）。
2. **核心**：迷你播放条、全屏播放器（`GlassScaffold` + 封面背景折射）。
3. **主题打通**：把 `GlassThemeData` 与现有 `ThemeProvider`（MD3 动态取色）同步，让玻璃色板跟随 theme。
4. **回退方案**：若某页面风险高，可仅用 `GlassContainer`/`GlassCard` 做局部玻璃，不整页 `GlassScaffold`。

---

## 8. 任务清单

- [ ] `flutter pub add liquid_glass_widgets`，验证依赖解析无冲突（关注 `meta` 版本）
- [ ] `main.dart` 接入 `LiquidGlassWidgets.initialize()` + `wrap()` + `brightnessResolver`
- [ ] 编写 Demo 页面：`GlassScaffold` + 背景图 + 核心组件（Card/BottomBar/Button/Sheet/TextField）
- [ ] Android 真机跑通，深/浅色各截图
- [ ] 性能验证：滚动 + 动态背景下帧率，`adaptiveQuality` 降级效果
- [ ] iOS 真机复测画质档位（若手头有设备）
- [ ] 汇总结论文档：是否推广 + 组件取舍 + 风险应对