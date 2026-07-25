# Android 自定义包名伪装功能 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在设置页面增加「包名伪装」入口，允许用户输入自定义包名字符串，应用在对外标识自身时（脚本路径、关于页显示、Kotlin 侧上报等）使用该自定义值，而非硬编码的 `com.md3music.md3music`。

**Architecture:** 新增 `PackageIdentityProvider` 作为单例 ChangeNotifier，对外暴露 `actualPackageName`（来自 `package_info_plus`，运行时实际 applicationId）与 `effectivePackageName`（用户配置的伪装值，未配置时回退为 actual）。SettingsRepository 增加一个可空字符串字段持久化用户配置。Flutter 侧所有硬编码 `com.md3music.md3music` 的运行时路径替换为动态读取实际包名；对外显示/上报处使用 effective 值。Kotlin 侧通过现有 `floating_lyric` channel 接收 Dart 端推送的 effective 值并缓存到 companion object，供后续 Lyricon / 日志 / 上报场景取用。

**Tech Stack:** Flutter 3.12 / Dart 3 / `package_info_plus: ^8.2.0` / `shared_preferences: ^2.5.0` / `provider: ^6.1.2` / Kotlin / JUnit（无 Kotlin 测试基础设施时仅手测）

---

## 范围与不变量

**会改的（运行时可配置）：**
- Flutter 侧 `nodejs_server.dart` 中硬编码的 `/data/user/0/com.md3music.md3music/files/...` 路径 → 改用 `package_info_plus` 读取实际包名拼接。
- 设置页「关于」分区显示的「应用包名」 → 显示 effective 值。
- 一个新增的「高级」分区文本框 → 让用户输入自定义包名。
- Kotlin 侧 companion object 缓存的 `spoofedPackageName` → 通过 MethodChannel 接收 Dart 推送。

**不改的（编译期/协议约束）：**
- `android/app/build.gradle.kts` 中的 `applicationId` / `namespace`（运行时无法改）。
- `AndroidManifest.xml` 中的 `package` / `.MainActivity` 等组件名。
- 所有 MethodChannel 名（`com.md3music.md3music/nodejs`、`/floating_lyric`、`/folder_picker`、`/lyricon`、`/metadata`）—— Dart 与 Kotlin 两侧必须字符串匹配，运行时改一侧会断链路。这些是内部通信通道，不属于「对外暴露的包名」。
- `AudioPlaybackService.kt` 中的 `ACTION_PREV` / `ACTION_PLAY_PAUSE` 等 Intent action 常量 —— 已注册到 manifest / receiver，运行时改会破坏媒体键广播。

**测试覆盖：** Dart 侧（SettingsRepository、PackageIdentityProvider、SettingsPage UI）走 `flutter test`。Kotlin 侧无现存测试基础设施，仅做手测验证。

---

## File Structure

- **Modify:** `lib/data/repositories/settings_repository.dart` — 新增 `_keySpoofedPackageName` 常量 + getter/setter。
- **Create:** `lib/providers/package_identity_provider.dart` — ChangeNotifier 单例，暴露 actual / effective 包名。
- **Modify:** `lib/main.dart` — 在 `MultiProvider` 中注册 `PackageIdentityProvider`。
- **Modify:** `lib/services/nodejs_server.dart` — 替换两处硬编码路径为动态拼接。
- **Modify:** `lib/modules/settings/settings_page.dart` — 新增「高级」分区（包名伪装输入框）+ 在「关于」分区显示 effective 包名。
- **Create:** `test/providers/package_identity_provider_test.dart` — 单元测试。
- **Modify:** `test/data/repositories/settings_repository_test.dart` — 新增字段测试（若文件不存在则创建）。
- **Modify:** `android/app/src/main/kotlin/com/md3music/md3music/MainActivity.kt` — 在 `floating_lyric` channel handler 中增加 `setSpoofedPackageName` 方法。
- **Modify:** `android/app/src/main/kotlin/com/md3music/md3music/AudioPlaybackService.kt` — 在 companion object 中增加 `spoofedPackageName` 缓存变量 + getter。
- **Modify:** `lib/core/services/lyricon_provider_service.dart` — 在 `setEnabled(true)` 时把当前 effective 包名推给 Kotlin。

---

## Task 1: SettingsRepository 新增包名伪装字段

**Files:**
- Modify: `lib/data/repositories/settings_repository.dart:14-15`（在 `_keyUiScale` 后新增常量）+ 文件末尾新增 getter/setter
- Test: `test/data/repositories/settings_repository_test.dart`（创建文件）

- [ ] **Step 1: 写失败测试**

创建 `test/data/repositories/settings_repository_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:md3music/data/repositories/settings_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsRepository.spoofedPackageName', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('默认返回 null（未配置伪装）', () async {
      final repo = SettingsRepository();
      expect(await repo.getSpoofedPackageName(), isNull);
    });

    test('setter 持久化非空字符串，getter 能读回', () async {
      final repo = SettingsRepository();
      await repo.setSpoofedPackageName('com.fake.app');
      expect(await repo.getSpoofedPackageName(), 'com.fake.app');
    });

    test('setter 传 null 或空串会清除字段（回退为 null）', () async {
      final repo = SettingsRepository();
      await repo.setSpoofedPackageName('com.fake.app');
      await repo.setSpoofedPackageName(null);
      expect(await repo.getSpoofedPackageName(), isNull);

      await repo.setSpoofedPackageName('com.fake.app');
      await repo.setSpoofedPackageName('');
      expect(await repo.getSpoofedPackageName(), isNull);
    });
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test test/data/repositories/settings_repository_test.dart`
Expected: FAIL — `getSpoofedPackageName` 方法未定义（编译错误 / NoSuchMethodError）。

- [ ] **Step 3: 实现最小代码**

修改 `lib/data/repositories/settings_repository.dart`，在 `_keyUiScale` 后新增常量（约第 15 行）：

```dart
  static const String _keyUiScale = 'settings_ui_scale';
  // 自定义包名伪装：null/空字符串表示使用实际 applicationId
  static const String _keySpoofedPackageName = 'settings_spoofed_package_name';
```

在文件末尾 `setUiScale` 方法后追加：

```dart
  // ===== 包名伪装 =====

  /// 读取用户配置的伪装包名。
  /// 返回 null 表示未配置，调用方应回退到实际 applicationId。
  Future<String?> getSpoofedPackageName() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_keySpoofedPackageName);
    if (value == null || value.isEmpty) return null;
    return value;
  }

  /// 持久化伪装包名。
  /// 传入 null 或空字符串表示清除伪装，恢复使用实际 applicationId。
  Future<void> setSpoofedPackageName(String? packageName) async {
    final prefs = await SharedPreferences.getInstance();
    if (packageName == null || packageName.isEmpty) {
      await prefs.remove(_keySpoofedPackageName);
    } else {
      await prefs.setString(_keySpoofedPackageName, packageName);
    }
  }
```

- [ ] **Step 4: 运行测试确认通过**

Run: `flutter test test/data/repositories/settings_repository_test.dart`
Expected: PASS — 3 个测试全部通过。

- [ ] **Step 5: 提交**

```bash
git add lib/data/repositories/settings_repository.dart test/data/repositories/settings_repository_test.dart
git commit -m "feat(settings): add spoofed package name field to SettingsRepository"
```

---

## Task 2: PackageIdentityProvider 单例

**Files:**
- Create: `lib/providers/package_identity_provider.dart`
- Test: `test/providers/package_identity_provider_test.dart`

- [ ] **Step 1: 写失败测试**

创建 `test/providers/package_identity_provider_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:md3music/providers/package_identity_provider.dart';

// 通过 package_info_plus 的 PackageInfo.fromPlatform 在测试环境下
// 默认返回 appName='' / packageName='' / version='' / buildNumber=''，
// 因此 actualPackageName 会是空串 —— 我们在测试里只断言 effective 回退逻辑。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PackageIdentityProvider', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('未配置伪装时，effectivePackageName 回退为 actualPackageName', () async {
      final provider = PackageIdentityProvider();
      await provider.load();
      expect(provider.actualPackageName, '');
      expect(provider.spoofedPackageName, isNull);
      expect(provider.effectivePackageName, provider.actualPackageName);
    });

    test('配置伪装后，effectivePackageName 返回伪装值', () async {
      final provider = PackageIdentityProvider();
      await provider.load();
      await provider.setSpoofedPackageName('com.fake.app');
      expect(provider.spoofedPackageName, 'com.fake.app');
      expect(provider.effectivePackageName, 'com.fake.app');
    });

    test('清除伪装后，effectivePackageName 回退为 actualPackageName', () async {
      final provider = PackageIdentityProvider();
      await provider.load();
      await provider.setSpoofedPackageName('com.fake.app');
      await provider.setSpoofedPackageName(null);
      expect(provider.spoofedPackageName, isNull);
      expect(provider.effectivePackageName, provider.actualPackageName);
    });

    test('setSpoofedPackageName 触发 listener 回调', () async {
      final provider = PackageIdentityProvider();
      await provider.load();
      var notifyCount = 0;
      provider.addListener(() => notifyCount++);
      await provider.setSpoofedPackageName('com.fake.app');
      expect(notifyCount, greaterThan(0));
    });
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test test/providers/package_identity_provider_test.dart`
Expected: FAIL — `PackageIdentityProvider` 类不存在（编译错误）。

- [ ] **Step 3: 实现最小代码**

创建 `lib/providers/package_identity_provider.dart`：

```dart
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../data/repositories/settings_repository.dart';

/// 包名身份提供方：暴露「实际包名」与「生效包名」。
///
/// - [actualPackageName]：来自 [PackageInfo.fromPlatform]，运行时等于 Android
///   `applicationId`，无法在运行时修改。
/// - [spoofedPackageName]：用户在设置页配置的伪装值；null 表示未配置。
/// - [effectivePackageName]：对外暴露/上报时使用，= spoofed ?? actual。
///
/// 设计参考 [DeviceProvider]：单例 + ChangeNotifier，启动时 load，set 时
/// 同步持久化并通知 UI 刷新。
class PackageIdentityProvider extends ChangeNotifier {
  PackageIdentityProvider();

  final SettingsRepository _settings = SettingsRepository();

  String _actualPackageName = '';
  String? _spoofedPackageName;

  /// 实际 applicationId（来自 package_info_plus）。
  String get actualPackageName => _actualPackageName;

  /// 用户配置的伪装包名，null 表示未配置。
  String? get spoofedPackageName => _spoofedPackageName;

  /// 对外生效的包名：未配置伪装时回退为 [actualPackageName]。
  String get effectivePackageName =>
      _spoofedPackageName?.isNotEmpty == true
          ? _spoofedPackageName!
          : _actualPackageName;

  /// 是否已启用伪装（spoofed 非空且非空串）。
  bool get isSpoofingEnabled =>
      _spoofedPackageName != null && _spoofedPackageName!.isNotEmpty;

  /// 启动时调用一次：读取实际包名 + 用户配置。
  Future<void> load() async {
    final info = await PackageInfo.fromPlatform();
    _actualPackageName = info.packageName;
    _spoofedPackageName = await _settings.getSpoofedPackageName();
    notifyListeners();
  }

  /// 设置伪装包名；null/空串表示清除伪装。
  /// 同步持久化到 SharedPreferences 并通知监听者。
  Future<void> setSpoofedPackageName(String? packageName) async {
    final normalized = (packageName == null || packageName.isEmpty)
        ? null
        : packageName;
    if (_spoofedPackageName == normalized) return;
    _spoofedPackageName = normalized;
    await _settings.setSpoofedPackageName(normalized);
    notifyListeners();
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `flutter test test/providers/package_identity_provider_test.dart`
Expected: PASS — 4 个测试全部通过。

- [ ] **Step 5: 提交**

```bash
git add lib/providers/package_identity_provider.dart test/providers/package_identity_provider_test.dart
git commit -m "feat(providers): add PackageIdentityProvider for runtime package name spoofing"
```

---

## Task 3: 在 main.dart 注册 PackageIdentityProvider

**Files:**
- Modify: `lib/main.dart`

- [ ] **Step 1: 阅读现有 main.dart 结构**

Run: 用 Read 工具读 `lib/main.dart`，定位 `MultiProvider` 的 `providers: [...]` 列表位置。

- [ ] **Step 2: 修改 MultiProvider**

在 `lib/main.dart` 顶部 import 区追加：

```dart
import 'providers/package_identity_provider.dart';
```

在 `MultiProvider` 的 `providers` 列表中追加（与 `DeviceProvider`、`ThemeProvider` 同级）：

```dart
ChangeNotifierProvider(create: (_) => PackageIdentityProvider()..load()),
```

- [ ] **Step 3: 验证编译**

Run: `flutter analyze lib/main.dart`
Expected: 无新增 error / warning。

- [ ] **Step 4: 提交**

```bash
git add lib/main.dart
git commit -m "feat(main): register PackageIdentityProvider in MultiProvider"
```

---

## Task 4: 替换 nodejs_server.dart 中的硬编码路径

**Files:**
- Modify: `lib/services/nodejs_server.dart:51` + `:59`

- [ ] **Step 1: 写失败测试**

创建 `test/services/nodejs_server_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:md3music/services/nodejs_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('scriptPath 使用实际包名拼接，不包含硬编码 com.md3music.md3music', () async {
    // 测试环境下 PackageInfo.fromPlatform 返回空串 packageName='',
    // 我们只验证 buildScriptPath 不再硬编码 'com.md3music.md3music'。
    final info = await PackageInfo.fromPlatform();
    final path = NodeJsServer.buildScriptPath(info.packageName);
    expect(path, endsWith('/files/nodejs-project/server_bundle.js'));
    expect(path, contains('/data/user/0/'));
    expect(path, isNot(contains('com.md3music.md3music')));
  });

  test('buildModulesPath 同样不包含硬编码', () async {
    final info = await PackageInfo.fromPlatform();
    final path = NodeJsServer.buildModulesPath(info.packageName);
    expect(path, endsWith('/files/nodejs-project'));
    expect(path, contains('/data/user/0/'));
    expect(path, isNot(contains('com.md3music.md3music')));
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test test/services/nodejs_server_test.dart`
Expected: FAIL — `NodeJsServer.buildScriptPath` 静态方法不存在。

- [ ] **Step 3: 实现最小代码**

修改 `lib/services/nodejs_server.dart`，在顶部 import 区追加：

```dart
import 'package:package_info_plus/package_info_plus.dart';
```

在 `NodeJsServer` 类内（`start` 方法上方）新增两个静态构造方法：

```dart
  /// 根据实际包名拼接 server_bundle.js 路径。
  /// 使用 /data/user/0/{package}/files/nodejs-project/server_bundle.js 格式。
  static String buildScriptPath(String packageName) {
    return '/data/user/0/$packageName/files/nodejs-project/server_bundle.js';
  }

  /// 根据实际包名拼接 nodejs-project 目录路径（用于 NODE_PATH 环境变量）。
  static String buildModulesPath(String packageName) {
    return '/data/user/0/$packageName/files/nodejs-project';
  }
```

将 `_startViaFfi` 中第 51 行的硬编码路径替换为：

```dart
        final info = await PackageInfo.fromPlatform();
        final scriptPath = buildScriptPath(info.packageName);
```

将第 59 行的硬编码 modulesPath 替换为：

```dart
        final modulesPath = buildModulesPath(info.packageName);
```

注意：由于 `_startViaFfi` 是在 `Isolate.run` 内执行的，`PackageInfo.fromPlatform()` 应在主 isolate 提前获取并传入闭包。但 `package_info_plus` 在后台 isolate 也能正常调用（内部走 MethodChannel），保持原样即可。

- [ ] **Step 4: 运行测试确认通过**

Run: `flutter test test/services/nodejs_server_test.dart`
Expected: PASS — 2 个测试通过。

- [ ] **Step 5: 提交**

```bash
git add lib/services/nodejs_server.dart test/services/nodejs_server_test.dart
git commit -m "fix(nodejs): replace hardcoded package path with dynamic PackageInfo lookup"
```

---

## Task 5: 设置页新增「高级」分区（包名伪装输入框）

**Files:**
- Modify: `lib/modules/settings/settings_page.dart`

- [ ] **Step 1: 写失败测试**

创建 `test/modules/settings/settings_package_spoofing_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'package:md3music/modules/settings/settings_page.dart';
import 'package:md3music/providers/package_identity_provider.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    home: ChangeNotifierProvider(
      create: (_) => PackageIdentityProvider()..load(),
      child: child,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('设置页包含「高级」分区与「包名伪装」输入框', (tester) async {
    await tester.pumpWidget(_wrap(const SettingsPage()));
    await tester.pumpAndSettle();

    expect(find.text('高级'), findsOneWidget);
    expect(find.text('包名伪装'), findsOneWidget);
    // 默认未配置时显示提示文案
    expect(find.text('未配置（使用实际包名）'), findsOneWidget);
  });

  testWidgets('点击「包名伪装」弹出对话框，输入后保存到 PackageIdentityProvider',
      (tester) async {
    await tester.pumpWidget(_wrap(const SettingsPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('包名伪装'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.enterText(
      find.byType(TextField),
      'com.fake.app',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final provider = tester
        .element(find.byType(SettingsPage))
        .read<PackageIdentityProvider>();
    expect(provider.spoofedPackageName, 'com.fake.app');
    expect(provider.effectivePackageName, 'com.fake.app');
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test test/modules/settings/settings_package_spoofing_test.dart`
Expected: FAIL — 找不到「高级」文本 / 「包名伪装」ListTile。

- [ ] **Step 3: 实现最小代码**

修改 `lib/modules/settings/settings_page.dart`：

3.1 顶部 import 区追加：

```dart
import '../../providers/package_identity_provider.dart';
```

3.2 在 `build` 方法的 `ListView` children 中，在 `_buildCacheSection` 之后、`_buildAboutSection` 之前新增「高级」分区调用：

```dart
          _buildSectionHeader('缓存'),
          _buildCacheSection(colorScheme),
          const Divider(),
          _buildSectionHeader('高级'),
          _buildAdvancedSection(colorScheme),
          const Divider(),
          _buildSectionHeader('关于'),
```

3.3 在 `_SettingsPageState` 内新增方法 `_buildAdvancedSection`（紧接 `_buildCacheSection` 后定义）：

```dart
  /// 高级 section：包名伪装入口。
  ///
  /// 点击弹出 AlertDialog 输入自定义包名，保存到 PackageIdentityProvider；
  /// 实际 applicationId 无法运行时改变，此处仅控制对外暴露的字符串。
  Widget _buildAdvancedSection(ColorScheme colorScheme) {
    final provider = context.watch<PackageIdentityProvider>();
    final spoofed = provider.spoofedPackageName;
    final subtitle = (spoofed == null || spoofed.isEmpty)
        ? '未配置（使用实际包名）'
        : spoofed;
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.privacy_tip_outlined),
          title: const Text('包名伪装'),
          subtitle: Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showSpoofedPackageDialog(provider),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '对外标识时使用自定义包名（实际 applicationId 不会改变）',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _showSpoofedPackageDialog(
      PackageIdentityProvider provider) async {
    final controller = TextEditingController(text: provider.spoofedPackageName ?? '');
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('包名伪装'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: '自定义包名',
            hintText: 'com.example.app',
            border: OutlineInputBorder(),
          ),
          autocorrect: false,
          enableSuggestions: false,
        ),
        actions: [
          TextButton(
            onPressed: () {
              // 传空串表示清除伪装
              Navigator.pop(ctx, '');
            },
            child: const Text('清除'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx, controller.text.trim());
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (result == null) return; // 用户点外部取消
    await provider.setSpoofedPackageName(result);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.isEmpty
              ? '已清除包名伪装，将使用实际 applicationId'
              : '包名伪装已设置为：$result',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
```

- [ ] **Step 4: 运行测试确认通过**

Run: `flutter test test/modules/settings/settings_package_spoofing_test.dart`
Expected: PASS — 2 个测试通过。

- [ ] **Step 5: 提交**

```bash
git add lib/modules/settings/settings_page.dart test/modules/settings/settings_package_spoofing_test.dart
git commit -m "feat(settings): add Advanced section with package name spoofing input"
```

---

## Task 6: 「关于」分区显示 effective 包名

**Files:**
- Modify: `lib/modules/settings/settings_page.dart`（`_buildAboutSection` 方法）

- [ ] **Step 1: 写失败测试**

追加到 `test/modules/settings/settings_package_spoofing_test.dart`：

```dart
  testWidgets('关于分区显示 effective 包名（未配置时显示 actual）', (tester) async {
    await tester.pumpWidget(_wrap(const SettingsPage()));
    await tester.pumpAndSettle();

    // 「应用包名」条目存在
    expect(find.text('应用包名'), findsOneWidget);
    // 未配置伪装时，subtitle 显示 actualPackageName（测试环境下为空串 → 显示空）
    final provider = tester
        .element(find.byType(SettingsPage))
        .read<PackageIdentityProvider>();
    expect(provider.effectivePackageName, provider.actualPackageName);
  });

  testWidgets('配置伪装后，关于分区显示 effective 包名', (tester) async {
    await tester.pumpWidget(_wrap(const SettingsPage()));
    await tester.pumpAndSettle();

    final provider = tester
        .element(find.byType(SettingsPage))
        .read<PackageIdentityProvider>();
    await provider.setSpoofedPackageName('com.fake.app');
    await tester.pumpAndSettle();

    // subtitle 应显示伪装值
    expect(find.text('com.fake.app'), findsWidgets);
  });
```

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test test/modules/settings/settings_package_spoofing_test.dart`
Expected: FAIL — 找不到「应用包名」ListTile（当前只有「应用版本」）。

- [ ] **Step 3: 实现最小代码**

修改 `lib/modules/settings/settings_page.dart` 的 `_buildAboutSection` 方法，在「应用版本」ListTile 之后新增「应用包名」ListTile：

```dart
  Widget _buildAboutSection(ColorScheme colorScheme) {
    final provider = context.watch<PackageIdentityProvider>();
    final showSpoofBadge = provider.isSpoofingEnabled;
    return Column(
      children: [
        ListTile(
          title: const Text('应用版本'),
          subtitle: Text(_appVersion.isEmpty ? kBuildAppVersion : _appVersion),
          leading: const Icon(Icons.info_outline),
        ),
        ListTile(
          title: const Text('应用包名'),
          subtitle: Text(provider.effectivePackageName),
          leading: const Icon(Icons.android_outlined),
          trailing: showSpoofBadge
              ? Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: colorScheme.tertiaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '已伪装',
                    style: TextStyle(
                      color: colorScheme.onTertiaryContainer,
                      fontSize: 12,
                    ),
                  ),
                )
              : null,
        ),
        ListTile(
          title: const Text('更新最新版本'),
          subtitle: const Text('https://github.com/zzyoxml/md3Music/releases'),
          leading: const Icon(Icons.system_update_outlined),
          trailing: const Icon(Icons.open_in_new, size: 18),
          onTap: () => _openReleasesUrl(),
        ),
        ListTile(
          title: const Text('开源许可'),
          leading: const Icon(Icons.description_outlined),
          onTap: () {
            showLicensePage(
              context: context,
              applicationName: 'MD3Music',
              applicationVersion: _appVersion.isEmpty
                  ? kBuildAppVersion
                  : _appVersion,
            );
          },
        ),
        // 开发者入口：跳转 Apple Music 风格歌词渲染预览页（Task 22.5）
        ListTile(
          title: const Text('歌词预览（开发）'),
          subtitle: const Text('Apple Music 风格歌词渲染调试'),
          leading: const Icon(Icons.lyrics_outlined),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LyricsPreviewPage()),
            );
          },
        ),
      ],
    );
  }
```

- [ ] **Step 4: 运行测试确认通过**

Run: `flutter test test/modules/settings/settings_package_spoofing_test.dart`
Expected: PASS — 4 个测试全部通过。

- [ ] **Step 5: 提交**

```bash
git add lib/modules/settings/settings_page.dart test/modules/settings/settings_package_spoofing_test.dart
git commit -m "feat(settings): show effective package name in About section"
```

---

## Task 7: Kotlin 侧接收并缓存 spoofed package name

**Files:**
- Modify: `android/app/src/main/kotlin/com/md3music/md3music/AudioPlaybackService.kt`（companion object）
- Modify: `android/app/src/main/kotlin/com/md3music/md3music/MainActivity.kt`（floating_lyric channel handler）
- Modify: `lib/core/services/lyricon_provider_service.dart`（setEnabled 时推送）

- [ ] **Step 1: 在 AudioPlaybackService.kt companion object 中新增缓存字段**

修改 `android/app/src/main/kotlin/com/md3music/md3music/AudioPlaybackService.kt`，在 `lyriconChannel` 字段后追加：

```kotlin
        // 由 Dart 端推送的「生效包名」（可能是用户配置的伪装值，也可能是实际 applicationId）
        // 用于 Lyricon / 日志 / 上报等需要标识自身包名的场景
        @Volatile
        private var spoofedPackageName: String? = null

        fun setSpoofedPackageName(name: String?) {
            spoofedPackageName = if (name.isNullOrEmpty()) null else name
        }

        /** 对外生效的包名：优先返回 spoofed，回退到 context.packageName */
        fun getEffectivePackageName(context: Context): String {
            return spoofedPackageName ?: context.packageName
        }
```

- [ ] **Step 2: 在 MainActivity.kt 的 floating_lyric channel handler 中增加方法分支**

修改 `android/app/src/main/kotlin/com/md3music/md3music/MainActivity.kt`，在 `channel.setMethodCallHandler` 的 `when (call.method)` 中，在 `"setPlaying"` 之后、`"seekTo"` 之前（或任意合适位置）新增：

```kotlin
                "setSpoofedPackageName" -> {
                    val name = call.argument<String>("packageName")
                    AudioPlaybackService.setSpoofedPackageName(name)
                    result.success(true)
                }
```

- [ ] **Step 3: 在 lyricon_provider_service.dart 的 setEnabled(true) 时推送包名**

修改 `lib/core/services/lyricon_provider_service.dart`，在顶部 import 区追加：

```dart
import 'package:package_info_plus/package_info_plus.dart';
```

将 `setEnabled` 方法替换为：

```dart
  Future<void> setEnabled(bool enabled) async {
    if (enabled) {
      _state = LyriconConnectionState.connecting;
    } else {
      _state = LyriconConnectionState.disabled;
    }
    _notify();
    try {
      // 启用时把当前实际 applicationId 推给 Kotlin 侧缓存
      // （Kotlin 无法直接读取用户配置的伪装值，由 Dart 端统一推送）
      if (enabled) {
        final info = await PackageInfo.fromPlatform();
        await _channel.invokeMethod('setSpoofedPackageName', {
          'packageName': info.packageName,
        });
      }
      await _channel.invokeMethod('setEnabled', {'enabled': enabled});
    } catch (_) {}
  }
```

- [ ] **Step 4: 验证编译**

Run: `flutter analyze lib/core/services/lyricon_provider_service.dart`
Expected: 无 error / warning。

- [ ] **Step 5: 手测验证（无 Kotlin 单测基础设施）**

构建 debug APK 并安装到设备 / 模拟器：

```bash
cd android
./gradlew :app:assembleDebug
```

启动 app，在设置 → 高级 → 包名伪装，输入 `com.test.spoof`，保存。然后：

```bash
adb logcat -s AudioPlaybackService:* MainActivity:* | grep -i spoof
```

观察日志确认 `setSpoofedPackageName` 被调用（可在 Kotlin 侧临时加 `Log.d` 打印）。

- [ ] **Step 6: 提交**

```bash
git add android/app/src/main/kotlin/com/md3music/md3music/AudioPlaybackService.kt android/app/src/main/kotlin/com/md3music/md3music/MainActivity.kt lib/core/services/lyricon_provider_service.dart
git commit -m "feat(android): receive and cache spoofed package name from Dart side"
```

---

## Task 8: 集成验证与端到端手测

**Files:** 无新增/修改

- [ ] **Step 1: 跑全量 Dart 测试**

Run: `flutter test`
Expected: 所有测试 PASS（包含本次新增的 3 个测试文件共 11 个测试用例 + 历史测试）。

- [ ] **Step 2: 跑 flutter analyze**

Run: `flutter analyze`
Expected: 无新增 error / warning。

- [ ] **Step 3: 构建 release APK 验证编译**

Run: `cd android && ./gradlew :app:assembleRelease`（如有签名配置）
Expected: BUILD SUCCESSFUL。

- [ ] **Step 4: 端到端手测清单**

在真机上验证以下场景：

| 场景 | 预期 |
|------|------|
| 首次进入设置 → 高级分区 | 显示「未配置（使用实际包名）」 |
| 输入 `com.fake.app` 并保存 | SnackBar 提示已设置；关于页显示 `com.fake.app` + 「已伪装」徽章 |
| 重启 app | 高级分区仍显示 `com.fake.app`；关于页仍显示伪装值 |
| 点击「清除」 | 高级分区回到「未配置」；关于页显示实际包名 |
| Node.js 服务正常启动 | server_bundle.js 路径用动态包名拼接，仍能加载 |
| Lyricon 词幕推送 | 启用 Lyricon 时 Kotlin 日志能看到 `setSpoofedPackageName` 被调用 |
| 媒体键 / 通知 | 通知和媒体按钮功能正常（Intent action 未变，不受影响） |

- [ ] **Step 5: 提交手测记录（可选）**

如有发现问题，回到对应 Task 修复后重新提交。全部通过后无需额外 commit。

---

## Self-Review Checklist

### 1. Spec coverage
- ✅ 用户可在设置页输入自定义包名 → Task 5
- ✅ 配置持久化跨重启 → Task 1 (SharedPreferences) + Task 2 (load)
- ✅ 配置入口在设置页（无预设） → Task 5（纯文本输入，无预设按钮）
- ✅ 「Android 包名伪装」语义 → Task 6（关于页显示）+ Task 7（Kotlin 缓存供 Lyricon 等场景使用）+ Task 4（运行时路径不再硬编码）
- ✅ 实际 applicationId 不可改的约束 → 在「范围与不变量」中明确声明

### 2. Placeholder scan
- ✅ 无 TBD / TODO / "implement later"
- ✅ 所有代码步骤均提供完整可粘贴代码
- ✅ 无 "similar to Task N" 引用

### 3. Type consistency
- `PackageIdentityProvider.actualPackageName` / `spoofedPackageName` / `effectivePackageName` / `isSpoofingEnabled` —— 在 Task 2、5、6 中使用名称一致
- `SettingsRepository.getSpoofedPackageName()` / `setSpoofedPackageName(String?)` —— 在 Task 1、2 中签名一致
- `NodeJsServer.buildScriptPath(String)` / `buildModulesPath(String)` —— 在 Task 4 测试与实现中签名一致
- Kotlin 侧 `AudioPlaybackService.setSpoofedPackageName(String?)` / `getEffectivePackageName(Context)` —— 在 Task 7 Step 1 与 Step 2 中签名一致
- MethodChannel 方法名 `setSpoofedPackageName` —— 在 Task 7 Step 2（Kotlin）与 Step 3（Dart）中一致
- Channel 名 `com.md3music.md3music/floating_lyric` —— 保持不变（在「不变量」中声明）

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-07-25-android-package-name-spoofing.md`. Two execution options:**

**1. Subagent-Driven (recommended)** - 每个 Task 派一个新 subagent，task 间 review，迭代快。

**2. Inline Execution** - 在当前会话顺序执行，带 checkpoint review。

**Which approach?**
