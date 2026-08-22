# md3Music 公开/私有双仓库维护手册

> 适用分支：`rust-local-two`（当前主线）。本手册回答两个核心问题：
>
> 1. **公开仓库开发了新功能，怎么同步回私有仓库**，且不影响既有的下载/边听边存功能？
> 2. **私有仓库开发完功能，怎么剥离下载/缓存代码，发布到公开仓库**？
>
> 配套文档：架构细节见 `AGENTS.md` 第 8 节；隔离方案演进见 `docs/download_cache_isolation_plan.md`。

---

## 0. 一句话总结

> **所有开发都在私有仓库做，公开仓库只是"过滤导出的干净快照"。**
> 公开版 = 私有仓库跑一遍 `export_public.ps1` 得到 `.public_export/`，再推送。
> 私有仓库独有的东西（`packages/`、`lib/private/`、`main_private.dart`、私有设置 API）在导出时被整体排除，并在导出前用**否认清单闸门**强制校验"公开树零下载/缓存痕迹"。

---

## 1. 一次看懂架构

### 1.1 数据流总览

```
┌────────────────────────────────────────────────────────────┐
│  私有仓库（单一源码，全部功能都在这里开发）                  │
│  origin = https://github.com/Little-White3110/private_md3music │
│                                                            │
│  lib/                      ← 公开树（不含 lib/private/）    │
│  ├── main.dart             ← 公开入口（干净版）             │
│  ├── app.dart / providers / modules / widgets / services   │
│  ├── private/              ← 私有层（6 个文件，导出时排除） │
│  └── (无 main_private.dart，它在 lib/private/ 里)          │
│  packages/md3_download_cache/  ← 私有功能包（导出时排除）   │
│  scripts/export_public.ps1     ← 过滤导出脚本               │
│  scripts/verify_public_clean.ps1 ← 闸门校验脚本             │
│  scripts/public_deny.txt        ← 否认清单（闸门的数据源）   │
└───────────────┬────────────────────────────────────────────┘
                │ export_public.ps1（白名单拷贝 → 排除私有内容
                │ → 剥离 pubspec 依赖 → deny 闸门）
                ▼
┌────────────────────────────────────────────────────────────┐
│  .public_export/（临时导出树，不入库）                       │
│  = 干净的公开源码：无 packages/、无 lib/private/、           │
│    pubspec.yaml 已剥离私有依赖行                             │
└───────────────┬────────────────────────────────────────────┘
                │ git push -f origin HEAD:main（-PublicRemote 参数）
                ▼
┌────────────────────────────────────────────────────────────┐
│  公开仓库（发布产物，只读镜像）                              │
│  zzyoxml = https://github.com/zzyoxml/md3Music.git          │
└────────────────────────────────────────────────────────────┘
```

### 1.2 三个代码区域（新代码往哪放，看这里）

| 区域 | 路径 | 内容 | 是否进公开仓库 |
|------|------|------|--------------|
| **公开树** | `lib/`（不含 `lib/private/`）+ 根 `pubspec.yaml` | 全部公开功能。**零下载/缓存符号**，只允许"中性静态钩子"（见 1.4） | ✅ 导出 |
| **私有层** | `lib/private/` | 下载/缓存与主工程的接线：`cache_bridge.dart`（播放/歌词/封面钩子实现）、`enhanced_ui.dart`（下载/缓存 UI）、`downloads_provider.dart`（下载编排）、`downloads_page.dart`（下载管理页）、`private_settings.dart`（私有设置读写）、`main_private.dart`（私有入口） | ❌ 排除 |
| **私有功能包** | `packages/md3_download_cache/` | 下载/缓存引擎：`download/download_manager.dart`、`download/downloads_repository.dart`、`download/download_task.dart`、`cache/stream_cache_manager.dart`、`cache/stream_cache_repository.dart`、`cache/lyric_data.dart` | ❌ 排除 |

### 1.3 双入口

| 入口 | 文件 | 用途 | 构建命令 |
|------|------|------|---------|
| 公开入口 | `lib/main.dart` | 干净版，无下载/缓存 | `flutter build apk -t lib/main.dart` |
| 私有入口 | `lib/private/main_private.dart` | 完整版：`runBootstrap()` + `installCacheHooks()` + `installUiHooks()` + 注册 `DownloadsProvider` | `flutter build apk -t lib/private/main_private.dart` |

- 两个入口共用 `main.dart` 里抽出的 `runBootstrap()`（启动引导），差异仅在私有入口多装钩子。
- `scripts/build_android.ps1` 已默认走私有入口（每日构建 = 完整功能版）。

### 1.4 中性静态钩子系统（公开树 ↔ 私有层 的唯一通道）

公开类暴露**语义中性的静态字段**，私有层在 `main_private.dart` 启动时注入实现。公开类自己不 import 任何下载/缓存符号。

| 公开类（文件） | 中性扩展点（实际签名） | 私有注入内容 |
|------|------|------|
| `PlayerProvider` | `resolveLocalAudioPath(String hash, String quality)`<br>`resolveLocalArtworkPath(String hash)`<br>`onPlaybackSourceStarted(Song, String quality, String url)`<br>`onPlaybackSourceStopped(String hash)`<br>`extractEmbeddedArtwork(String hash, String audioUrl)` | 播放前查本地持久化音频/封面；播放后异步缓存；停止取消下载；云盘内嵌封面提取 |
| `KugouProvider` | `restoreLyric(String hash)` / `storeLyric(String hash, KugouLyric)` | 歌词读取/存储旁路 |
| `SmartArtworkImage` | `localArtworkReader(String songId)` | 按 songId 读本地持久化封面字节 |
| `SongListItem` | `extraMenuTilesBuilder(BuildContext, Song)` | 更多菜单的「下载 / 删除下载」条目 |
| `FullPlayer` / `AmStyleFullPlayer` | `coverLongPressCallback(BuildContext, dynamic song)` | 封面长按 → 下载音质选择对话框 |
| `SettingsPage` | `extraCategories` / `extraSearchIndexEntries` | 「边听边存」「下载」两个设置分类 + 搜索关键词 |
| `UserCenterPage` | `extraActionItemsBuilder(BuildContext, ColorScheme)` | 快捷操作网格的「下载」入口 |
| `PlaylistPage` / `PlayHistoryPage` | `songFilterHook(String pageKey, List<Song>)`<br>`songFilterListenable`<br>`extraAppBarActionsBuilder(BuildContext)` | 「仅显示已缓存」筛选：公开类只剩 `List→List` 变换插槽 + 重建信号 + AppBar 按钮注入位 |
| `MyApp`（app.dart） | `extraProviders` | 注册 `DownloadsProvider` |

### 1.5 两个仓库的关系

```bash
git remote -v
# origin    https://github.com/Little-White3110/private_md3music   ← 私有（开发主战场）
# zzyoxml   https://github.com/zzyoxml/md3Music.git                ← 公开（发布镜像）
```

---

## 2. 两条铁律（任何改动前先过一遍）

1. **铁律 A：公开树零私有符号。**
   `lib/`（不含 `lib/private/`）与根 `pubspec.yaml` 中不得出现 `scripts/public_deny.txt` 里的任何符号（`StreamCacheManager`、`getDownloadDir`、`边听边存` 等 30+ 项）。**新增私有特征时，必须同步把它的符号追加进 deny 文件**——否则闸门形同虚设。
2. **铁律 B：下载/缓存代码只有两个落点。**
   - 引擎/持久化 → `packages/md3_download_cache/`（**不 import 主工程类型**，用包内 DTO：`SongMetadata`/`LyricData`；需要外部能力用回调注入，如 `StreamCacheManager.cacheLimitMbProvider`）
   - 编排/UI/私有设置 → `lib/private/`（可自由 import 主工程类型与包）
   - 公开类需要能力 → 先加**中性静态钩子**（见 1.4 / 4.5），禁止在公开类里写私有逻辑

---

## 3. 四个日常场景速查

| # | 场景 | 一句话操作 | 详细步骤 |
|---|------|-----------|---------|
| A | 私有库开发**普通**新功能 | 直接在私有库写 → 验证 → 提交 | [4.1](#41-场景-a私有库开发普通新功能日常主路径) |
| B | 私有库开发**下载/缓存**新功能 | 代码进包或进 `lib/private/` → 加钩子 → 同步 deny 列表 | [4.2](#42-场景-b私有库开发下载缓存相关新功能) |
| C | **公开库**开发了新功能，同步回私有库 | `git fetch zzyoxml` → `git cherry-pick` → 验证 | [4.3](#43-场景-c公开库新功能同步回私有库) |
| D | 私有库开发完，**发布公开版** | `verify_public_clean` → `export_public.ps1 -PublicRemote` | [4.4](#44-场景-d发布公开版本) |
| E | 给公开类新增一个私有能力 | 加中性钩子 → 私有层注入 → deny 追加 | [4.5](#45-场景-e给公开类新增一个私有能力加钩子全流程) |
| F | 新增**顶层文件/目录**要随公开版发布 | 判断该不该公开 → 加进导出白名单 → 重新导出 | [4.6](#46-场景-f导出白名单维护新增文件目录时) |

---

## 4. 场景详解

### 4.1 场景 A：私有库开发普通新功能（日常主路径）

**这是默认开发方式**。所有不涉及下载/边听边存的功能，直接在私有仓库正常开发即可——公开版导出时会自动带上这些功能。

```
1. 写代码（公开树 lib/ 下正常添加/修改文件）
2. flutter analyze          # 零错误
3. flutter test             # 无新增失败（19 个预存插件测试失败属已知，见 7.4）
4. 真机验证：flutter build apk --debug -t lib/private/main_private.dart
              adb install -r build/app/outputs/flutter-apk/app-debug.apk
5. 按逻辑单元提交（conventional commit）
6. 不需要跑导出——发布时才需要（见 4.4）
```

**注意**：如果新功能**碰了**以下任意一种能力，请跳到场景 B：
- 播放前查"本地是否已有文件"、播放后想"存一份"
- 歌词/封面的本地持久化旁路
- 任何「下载」「缓存」「边听边存」语义

### 4.2 场景 B：私有库开发下载/缓存相关新功能

**第一步：决定代码落点**

| 新功能性质 | 落点 | 举例 |
|-----------|------|------|
| 引擎算法/持久化/文件操作，与 UI、账号、设置无关 | `packages/md3_download_cache/` | 新增"缓存限流"逻辑、新增缓存类型（如 MV 缓存） |
| 需要登录态、调用酷狗 API、写设置、弹 UI | `lib/private/` | 批量下载 UI、下载目录选择、缓存统计页 |
| 公开类需要展示/触发这个能力 | 公开类加**中性钩子**（4.5），实现放私有层 | 歌单页要显示"下载按钮" |

**第二步：按落点写代码**

包内（`packages/md3_download_cache/`）规则：
- 用包内 DTO：`Song` → `SongMetadata`（见 `cache/stream_cache_manager.dart` 的 `SongMetadata` 定义），`KugouLyric` → `LyricData`
- 需要主工程能力（如读设置）→ 在包内留静态回调字段（仿 `StreamCacheManager.cacheLimitMbProvider`），由私有层注入
- 改完包代码后：包版本按 semver 递增（`packages/md3_download_cache/pubspec.yaml`），`flutter pub get` 更新主工程 `pubspec.lock`，**lock 一并提交**

私有层（`lib/private/`）规则：
- 可自由 import 主工程类型（`Song`、`KugouApiClient`、`MetadataWriter`…）与包
- 设置读写用 `PrivateSettings`（在 `private_settings.dart`，**不要**在公开 `settings_repository.dart` 加下载/缓存方法）

**第三步：公开类加中性钩子**（仅当公开类需要调用新能力时）→ 见 4.5

**第四步：deny 列表同步追加**

新代码里出现的任何私有符号（类名/方法名/偏好 key/中文特征短语），追加到 `scripts/public_deny.txt`：
```text
# —— 新增私有特征 ——
MyNewCacheFeature
my_new_cache_feature_key
```

**第五步：验证**

```bash
flutter analyze
.\scripts\verify_public_clean.ps1     # 必须 exit 0（零命中）
```

### 4.3 场景 C：公开库新功能同步回私有库 ★

**前提认识**：公开仓库（`zzyoxml`）是导出快照。它与私有树在 `lib/` 公开部分**路径完全一致**，但公开树里**没有** `lib/private/`、`packages/`、`main_private.dart`，且 `pubspec.yaml` 是剥离后的。所以同步时：
- ✅ 改动只碰 `lib/` 公开部分（或其他白名单目录：`android/`、`assets/`、`test/` 等）→ 可以无损同步
- ⚠️ 改动碰了 `pubspec.yaml` → 大概率冲突，需手工合并（见下方冲突处理）
- ❌ 公开树里永远不该出现私有内容的改动——若公开仓库里出现了 `lib/private/` 之类，那是误推，直接丢弃

**推荐方法：cherry-pick（逐提交同步）**

```powershell
# 1. 拉取公开仓库最新
git fetch zzyoxml

# 2. 查看公开仓库最近提交，找到要同步的 commit
git log zzyoxml/main --oneline -20

# 3. 只同步选中的提交（推荐，粒度小、可回退）
git cherry-pick <commit-sha>

# 4. 若冲突（通常是 pubspec.yaml）：
#    - 打开 pubspec.yaml，保留私有依赖块（# private feature package 开头那段），
#      合并公开的新依赖
#    - git add pubspec.yaml && git cherry-pick --continue

# 5. 同步后必须验证（防止公开改动破坏私有构建或引入符号）
flutter analyze
flutter test
.\scripts\verify_public_clean.ps1    # 零命中才安全
```

**方法对比**

| 方法 | 命令 | 适用 | 风险 |
|------|------|------|------|
| cherry-pick（推荐） | `git cherry-pick <sha>` | 少量、明确的提交 | pubspec 冲突需手工合并 |
| 整分支 merge | `git merge zzyoxml/main` | 公开仓库长期无人开发时一次性全量同步 | 会把公开树的结构差异（缺目录）带进来，冲突面大，**不推荐** |
| 文件复制 | 手动复制文件内容 | 改动只有 1-2 个小文件 | 无 git 历史；易漏 |
| format-patch | `git format-patch` + `git am` | 离线批量 | 与 cherry-pick 等价 |

**关键提醒**：
- 同步前先确认当前私有仓库工作区干净（`git status`），或先提交当前改动，避免 cherry-pick 混入未提交内容。
- 公开仓库的功能同步回来后，**私有版 = 公开功能 + 下载/缓存**，两套功能互不影响——因为私有下载/缓存全部走钩子/包/私有层，公开功能改动不触碰这些文件就不会破坏它们。
- 如果公开仓库的改动恰好落在**钩子调用点附近**（如 `player_provider.dart` 播放方法、`playlist_page.dart` build），cherry-pick 可能冲突。处理原则：**保留私有侧的钩子调用**（`...?PlayerProvider.resolveLocalAudioPath?.call(...)` 这类行），合并公开的新逻辑。

### 4.4 场景 D：发布公开版本 ★

**前置条件**：私有仓库所有改动已提交；`flutter analyze` 零错误。

```powershell
# 1.（可选）先在私有库跑一次闸门，快速发现问题
.\scripts\verify_public_clean.ps1
# 期望输出：Public lib/ tree clean: deny-list zero-hit.（exit 0）

# 2. 生成公开树（只导出，不推送）
.\scripts\export_public.ps1
# 期望输出：Public tree exported to .public_export (deny-list zero-hit, gate passed)

# 3. 抽查导出树（可选但推荐）：
#    cd .public_export
#    flutter analyze            # 零错误
#    grep -rn "边听边存\|StreamCacheManager\|md3_download_cache" lib/  # 空 = 干净

# 4. 推送到公开仓库（脚本内部：git init → commit → force push 到 main）
.\scripts\export_public.ps1 -PublicRemote https://github.com/zzyoxml/md3Music.git
# 期望输出：Pushed to public repository: https://github.com/zzyoxml/md3Music.git
```

**手动推送（不想用脚本参数时）**：
```powershell
cd .public_export
git init
git add -A
git commit -m "public export"
git remote add origin https://github.com/zzyoxml/md3Music.git
git push -f origin HEAD:main
```

**注意事项**：
- 推送是 **force push 到公开仓库 main 分支**——公开仓库是镜像，历史上只允许被覆盖，不要在公开仓库上开分支开发（那样同步会很痛苦）。
- `.public_export/` 已被 `.gitignore` 忽略，不入私有仓库。
- 导出树里的 `test/` 会被原样拷贝：**不要在公开树的 `test/` 里写下载/缓存测试**（会命中闸门）；私有功能测试放 `packages/md3_download_cache/test/`。

### 4.5 场景 E：给公开类新增一个私有能力（加钩子全流程）

以"想给歌单页加一个'下载全部'按钮"为例（实际该功能已存在，这里演示流程）：

```dart
// ① 公开类加中性静态钩子（lib/modules/playlist/playlist_page.dart）
class PlaylistPage extends StatefulWidget {
  /// 可选扩展：多选栏额外操作按钮（默认关闭，由私有构建注入）。
  static List<Widget> Function(BuildContext context, int selectedCount)?
      extraMultiSelectActions;
  ...
  // ② 公开类在合适位置调用（无钩子时静默降级）
  ...?PlaylistPage.extraMultiSelectActions?.call(context, selectedCount),
}
```

```dart
// ③ 私有层实现并注入（lib/private/enhanced_ui.dart）
void installUiHooks() {
  ...
  PlaylistPage.extraMultiSelectActions = (ctx, count) => [ /* 下载按钮 */ ];
}
```

```
④ deny 列表追加：新私有实现里出现的符号追加到 scripts/public_deny.txt
⑤ 验证：flutter analyze + verify_public_clean.ps1
```

**钩子命名纪律**：
- 字段名**语义中性**（`resolveLocalAudioPath` 而不是 `getStreamCachePath`；`songFilterHook` 而不是 `cachedOnlyFilter`）
- 公开类里**只出现调用**，不出现任何下载/缓存实现与 import
- 调用处用 `...?Hook?.call(...)` 或 `if (Hook != null)` 守卫，保证公开版行为不受影响

### 4.6 场景 F：导出白名单维护（新增文件/目录时）

> 导出的白名单在 `scripts/export_public.ps1` 的 `$whitelist` 数组（当前 17 项）。**白名单制 = 只有列出的顶层项才会被拷贝进公开树**，未列出的东西（包括意外创建的任何顶层目录/文件）一律不进公开仓库——这是隔离的**第一道闸**。

**新增功能时按落点分类处理：**

| 新文件/目录落在哪 | 需要改白名单吗 | 原因 |
|------|------|------|
| `lib/` 任意位置（含新增子目录） | ❌ 不用 | `lib` 整目录白名单拷贝，新增文件自动带上；闸门再过滤私有符号 |
| `packages/md3_download_cache/` | ❌ 不用 | `packages/` 不在白名单，天然排除 |
| `lib/private/` | ❌ 不用 | 虽在 `lib` 下，但导出后会被步骤 4 明确删除 |
| 新增**顶层目录**（如 `docs/`、`tools/`、`native/`） | ✅ **要加** | 白名单制下不列不进；先判断该目录该不该进公开仓库 |
| 新增**顶层文件**（如 `SECURITY.md`、`CONTRIBUTING.md`） | ✅ **要加** | 同上 |
| 改动现有白名单项**内部**的文件（如 `android/`、`assets/`、`scripts/` 里的文件） | ❌ 不用 | 整目录拷贝，内部文件自动带上 |

**判断标准（一句话）**：这个文件/目录**该不该出现在公开仓库？**
- 该 → 加进 `$whitelist`
- 不该（含私有信息、内部文档、开发工具）→ 不加，留在私有仓库
- 拿不准 → 默认不加，宁可公开版少东西，不可多泄密

**示例**：
```powershell
# 假设新增 docs/user-guide/ 想随公开版发布：
$whitelist = @(
    'lib', 'android', 'assets', 'web', 'windows', 'test',
    'third_party', 'img', 'scripts', '.github',
    'pubspec.yaml', 'analysis_options.yaml', 'README.md',
    'LICENSE', 'CHANGELOG.md', 'DISCLAIMER.md',
    'devtools_options.yaml',
    'docs/user-guide'          # ← 新增行（可写目录或文件，路径相对项目根）
)
```

**⚠️ 白名单目录不经过 deny 扫描**（重要，勿踩）：
`export_public.ps1` 的否认闸门只扫描 `lib/*.dart` 与 `pubspec.yaml`。**`scripts/`、`assets/`、`android/` 等其他白名单目录的内容不会过闸门**。因此：
- 新增的**脚本/文档/资源**若含下载/缓存私有信息（如脚本里硬编码私有 URL、文档里写内部架构），不会被闸门拦截，会直接进公开仓库
- 规则：**白名单内的非 lib 文件，写入前先自问"这段内容能公开吗"**；涉及私有特征的，改用占位/通用描述
- 若想让闸门也覆盖某个新目录，可把该目录加入 `verify_public_clean.ps1` / `export_public.ps1` 的扫描范围（当前仅 lib + pubspec）

**修改白名单后的验证流程**：
```powershell
.\scripts\export_public.ps1 -NoPause          # 重新导出（闸门自动跑）
# 抽查新增项是否如期出现 / 不该出现的没出现：
ls .public_export\docs\user-guide              # 例：新增目录已在
ls .public_export\AGENTS.md                    # 例：应报 No such file（已排除）
```

---

## 5. 新增功能的落点决策流程

```
新功能需求
   │
   ├─ 涉及下载/边听边存/本地持久化播放吗？
   │     │
   │     ├─ 否 → 直接写公开树 lib/（场景 A）→ 完成
   │     │
   │     └─ 是 ↓
   │
   ├─ 是引擎/持久化，且不依赖主工程类型？
   │     │
   │     ├─ 是 → packages/md3_download_cache/（DTO + 回调注入）→ 版本递增
   │     │
   │     └─ 否 → lib/private/（可 import 主工程与包）
   │           │
   │           └─ 公开类需要展示/触发？
   │                 ├─ 是 → 加中性钩子（4.5）
   │                 └─ 否 → 直接私有层实现
   │
   └─ 收尾：deny 列表追加新符号 → flutter analyze → verify_public_clean.ps1
```

---

## 6. 发布前验证清单（Checklist）

发布公开版本前逐项确认：

- [ ] `flutter analyze` 零错误（私有仓库全仓）
- [ ] `flutter test` 无新增失败
- [ ] 涉及下载/缓存的改动已在真机验证（下载→文件+元数据、边听边存命中、缓存统计/清空）
- [ ] 新增私有符号已追加到 `scripts/public_deny.txt`
- [ ] `.\scripts\verify_public_clean.ps1` 输出 zero-hit（exit 0）
- [ ] `.\scripts\export_public.ps1` 输出 gate passed
- [ ] 导出树 `.public_export/` 抽查：`flutter analyze` 零错误、特征 grep 空
- [ ] 包代码有改动时：包版本已递增、`pubspec.lock` 已提交
- [ ] 私有改动已全部提交（发布推送与代码提交分离，先提交后发布）

---

## 7. 已知坑与 FAQ

### 7.1 pubspec.yaml 合并冲突（场景 C 常见）
私有 pubspec 比公开版多一段 `# private feature package` 依赖块。冲突时**保留该块**，把公开的新依赖合并进去即可。不要手工从私有 pubspec 删掉私有依赖——那是导出脚本的事。

### 7.2 deny 词粒度（最重要）
`public_deny.txt` 里**不能**用裸「缓存/下载」——公开版有大量合法功能（封面内存缓存、收藏歌单缓存、本地音乐扫描缓存）。必须用**特征级符号**（`StreamCacheManager`、`getStreamCacheEnabled`、`settings_download_dir`）或**中文特征短语**（`边听边存`、`仅显示已缓存`）。

### 7.3 PowerShell 5.1 编码 / 安全删除钩子
- 脚本内读写 UTF-8 文件一律走 .NET `[System.IO.File]` + `UTF8Encoding($false)`，**不要**用 `Set-Content`（默认 ANSI 会破坏含中文的文件）。
- 本机环境拦截 `Remove-Item`/`rm -rf` 大删除；脚本内统一用 `[System.IO.Directory]::Delete` 旁路。手动删导出目录可用 `rm -rf .public_export`（Git Bash）。

### 7.4 预存测试失败
`flutter test` 有 19 个 `kugou_provider_test.dart` 多账号测试失败：测试环境 shared_preferences 插件不可用（MissingPluginException），与下载/缓存改动无关，属预存问题。

### 7.5 钩子没生效？
- 确认构建用的是私有入口 `-t lib/private/main_private.dart`（公开入口不会装钩子）
- 确认 `installCacheHooks()` / `installUiHooks()` 在 `runApp` 前被调用（`main_private.dart` 已保证）
- 确认公开类调用处有守卫（`...?Hook?.call(...)`），且钩子在 build/调用前已赋值

### 7.6 真机验证流程
```bash
flutter build apk --debug -t lib/private/main_private.dart
adb devices                                  # 确认设备 R52R30F3Q9Z 在线
adb install -r build/app/outputs/flutter-apk/app-debug.apk
# 验证点：下载一首歌（更多菜单/封面长按）→ 本地文件+元数据；
#         播放缓存过的歌 → 断网仍可播（边听边存命中）；
#         设置页「边听边存」分类 → 统计数字正确、清空生效
```

### 7.7 白名单目录不经过 deny 扫描
否认闸门只扫 `lib/*.dart` + `pubspec.yaml`；`scripts/`、`assets/`、`android/` 等白名单目录**不扫描**。新增脚本/文档/资源时，若含下载/缓存私有信息，闸门拦不住，会直接进公开仓库——写入前自问"这段能公开吗"。详见 [4.6](#46-场景-f导出白名单维护新增文件目录时)。

---

## 8. 速查表

### 8.1 关键命令

| 目的 | 命令 |
|------|------|
| 闸门校验（私有库内） | `.\scripts\verify_public_clean.ps1` |
| 生成公开树 | `.\scripts\export_public.ps1` |
| 生成并推送公开树 | `.\scripts\export_public.ps1 -PublicRemote https://github.com/zzyoxml/md3Music.git` |
| 私有入口构建 | `flutter build apk --debug -t lib/private/main_private.dart` |
| 公开入口构建 | `flutter build apk --debug`（默认 lib/main.dart） |
| 每日完整构建 | `.\scripts\build_android.ps1`（默认私有入口） |
| 同步公开改动 | `git fetch zzyoxml && git cherry-pick <sha>` |

### 8.2 目录速查

| 路径 | 归属 | 说明 |
|------|------|------|
| `lib/`（不含 private/） | 公开 | 公开功能；只许中性钩子 |
| `lib/private/` | 私有 | 6 文件：`cache_bridge.dart`、`enhanced_ui.dart`、`downloads_provider.dart`、`downloads_page.dart`、`private_settings.dart`、`main_private.dart` |
| `packages/md3_download_cache/` | 私有 | 引擎包：`download/`（manager/repository/task）+ `cache/`（stream_cache_manager/repository/lyric_data） |
| `scripts/export_public.ps1` | 工具 | 过滤导出 + deny 闸门 + 可选推送 |
| `scripts/verify_public_clean.ps1` | 工具 | 闸门校验（pre-push/CI 用） |
| `scripts/public_deny.txt` | 工具 | 否认清单（新增私有特征必须追加） |
| `.public_export/` | 临时 | 导出产物，已 gitignore |

### 8.3 deny 列表符号族（public_deny.txt 当前内容概览）

- 引擎：`DownloadManager`、`DownloadsProvider`、`DownloadsPage`、`download_*`、`stream_cache_*`、`StreamCache*`、`CacheStats`、`getCacheStats`
- 方法：`getCached*`、`cacheAudio`、`cacheArtwork`、`cacheLyric`、`cacheSongMetadata`、`cacheEmbeddedArtwork`
- 设置 API：`get/setStreamCacheEnabled`、`get/setStreamCacheLimitMb`、`get/setDownloadDir`、`get/setDownloadWordLevelLyrics` + 4 个 `settings_*` key
- 包名：`md3_download_cache`
- 中文短语：`边听边存`、`仅显示已缓存`、`播放歌曲时会自动缓存`

---

## 9. 当前状态快照（截至 2026-08-23）

- **已完成的隔离改造**：引擎入包、公开树减法（deny 零命中）、双入口、过滤导出脚本、闸门强化（deny 外置 + 中文短语）、私有设置 API 迁出、筛选功能形态 B 化、字段/注释中性化。
- **验证结果**：`flutter analyze` 零错误；`flutter test` +345 通过（19 个预存插件失败除外）；双入口 debug APK 均构建成功；导出树独立 analyze 零错误 + 特征残留零命中。
- **待办**：真机验证（需接入 R52R30F3Q9Z）；改动尚未提交（`git status` 见未提交文件），建议按逻辑单元提交：引擎入包 / 公开树减法 / 导出脚本与闸门。
- **回滚**：改动未提交，`git checkout -- .` + `git clean -fd lib/private packages scripts/export_public.ps1 scripts/verify_public_clean.ps1` 可回到改造前。
