# 下载 / 缓存功能隔离与插件化实施计划

> **用途**：本文件为方案分析与分阶段落地计划，**仅描述架构、文件边界、改动范围与验证手段，不包含任何实现代码**。执行前请先通读第 1~3 节以确认方案方向。

**Goal（目标）**：本仓库即**私有主工程（单一代码源）**。将其中「下载」与「缓存」两类功能（引擎 + 模型 + 持久化 + UI）整体外置于本仓库内的**本地 Dart 包 `packages/md3_download_cache/`**，使其成为可独立版本化、可单独发布的完整功能单元；**公开版本则是由本仓库过滤导出的"干净树"**——不含该包目录、不含私有入口、不含任何下载/缓存符号。从而彻底消除每次向公开仓库同步新功能时都要手动搬运这两块代码的繁琐，并杜绝特征与引擎源码泄露。

**Architecture（架构）**：**本仓库 = 私有主工程（唯一代码源）**。下载/缓存作为完整功能（引擎 + 模型 + 持久化 + UI + 增强 Provider + 私有入口）整体外置于本仓库内的**本地包 `packages/md3_download_cache/`**（以 path 依赖引用）；**公开版本 ≠ 另一套代码，而是由本仓库过滤导出的子树**——导出时整体排除 `packages/md3_download_cache/` 与私有入口 `lib/main_private.dart`，经否认清单 grep 闸门校验后推送至公开仓库。公开仓库因此完全不含下载/缓存的任何引用（无接口、无 NoOp、无开关、无 UI）。公开构建与私有构建以不同 `-t` target 分离。

**Tech Stack（技术栈）**：Flutter/Dart、`provider`（现有状态管理）、`dio` / `path_provider` / `audio_metadata_reader`（引擎依赖）、Git（本仓库为单一源；`export_public` 过滤导出脚本负责生成公开树）、`flutter analyze` / `flutter test` / ADB 真机验证。

---

## 1. 现状诊断与痛点

### 1.1 当前代码分布（基于本仓库实测）

**下载功能（Download）**

- 引擎：`lib/services/download_manager.dart`（`DownloadManager` 单例，dio 下载 + 文件名规则 + magic bytes 扩展名修正）
- 编排：`lib/providers/downloads_provider.dart`（URL 获取、任务持久化、元数据嵌入）
- 持久化：`lib/data/repositories/downloads_repository.dart`（sqflite）
- 模型：`lib/data/models/download_task.dart`
- 调用/消费方：`app.dart`（Provider 注册）、`widgets/song_list_item.dart`、`modules/player/full_player.dart`(+`_am`)、`modules/playlist/playlist_page.dart`、`modules/user/downloads_page.dart`、`services/kugou_api/kugou_api_client.dart`

**缓存功能（Cache）**

- 引擎：`lib/services/stream_cache_manager.dart`（`StreamCacheManager` 单例，audio/lyrics/artwork 三类缓存 + LRU 清理）
- 持久化/索引：`lib/data/repositories/stream_cache_repository.dart`（`CacheEntry`/`AudioCacheInfo`/`LyricsCacheInfo`/`ArtworkCacheInfo`/`CacheStats`）
- 调用/消费方（**耦合极深**）：`providers/player_provider.dart`（约 20 处调用，处于播放主链路热路径）、`providers/kugou_provider.dart`（歌词缓存）、`widgets/smart_artwork_image.dart`（封面缓存）、`modules/user/play_history_page.dart`、`modules/playlist/playlist_page.dart`、`modules/settings/settings_page.dart`（统计 + 清空）

### 1.2 为什么每次迁移都很麻烦

1. **缓存功能与播放主链路强耦合**：`player_provider.dart` 直接以 `StreamCacheManager.instance.xxx(...)` 形式散落约 20 处。迁功能时只要动到播放相关代码，就必须把这一大块连同其依赖（`StreamCacheRepository`、索引模型、magic bytes 逻辑）一起搬运，否则编译不过。
2. **两功能横跨 3 层**：引擎（service）+ 持久化（repository）+ 模型（model）+ 编排（provider），且 provider 还交织了 `KugouApiClient`、`SettingsRepository`、原生 `MetadataWriter`。手动挑选"只搬这两块"极易漏文件或搬错版本。
3. **依赖可传递性**：缓存引擎直接 `import` 了 `Song`、`KugouLyric`、以及 `SettingsRepository().getStreamCacheLimitMb()`。一旦搬运，这些被依赖的公共类型/设置也被牵动，边界模糊，难以判断"哪些算缓存、哪些算公共"。

### 1.3 风险点

| 风险           | 说明                                                                   | 触发场景       |
| ------------ | -------------------------------------------------------------------- | ---------- |
| 公共代码被误带入公开仓库 | 手动 `git add` 时范围过宽，把 `kugou_api_client`（可能含签名/密钥/私有端点）或设置细节一并提交      | 赶进度、批量 add |
| 机密/配置泄露      | 下载/缓存本身虽不含密钥，但其相邻模块（`kugou_api`、server 配置）常含敏感信息，迁移时容易顺手带出           | 边界不清       |
| 版本漂移         | 公开仓库里的是"某次快照"，主工程已修复 bug，公开仓库仍是旧副本，行为不一致                             | 长期多分支并行    |
| 编译/回归遗漏      | 漏搬 `stream_cache_repository` 或模型，公开仓库 `flutter analyze` 报错，回补又引入更多耦合 | 缓存调用点分散    |
| 真机行为差异       | 搬运后缓存路径/清理策略变了，公开仓库构建的 APK 在设备上表现不同                                  | 未做等价验证     |

---

## 2. 隔离方案对比

> 评分维度：侵入性（对现有代码改动量）、迁移成本（每次向公开仓库同步的成本）、复用性、安全性（公开仓库是否接触引擎源码）、版本可控性。

| # | 方案                               | 优点                                                           | 缺点                                                             | 侵入性                          | 迁移成本                         | 适用场景                    |
| - | -------------------------------- | ------------------------------------------------------------ | -------------------------------------------------------------- | ---------------------------- | ---------------------------- | ----------------------- |
| A | **独立 Dart 包 + 接口契约 + 运行时开关**（推荐） | 引擎单点维护、独立 semver；公开仓库仅持接口+NoOp，绝不接触源码；通过 DI 单点接线；版本锁定 commit | 需做一次接口抽取与消费者改造（集中在 Phase 4）                                    | 中（主要在 player_provider 的机械替换） | **极低**（公开仓库只更新接口/开关，引擎随包版本走） | 既要复用、又要保密、且是 Flutter 工程 |
| B | Git Submodule（私有子仓库）             | 文件级共享，两个仓库看到的是同一份；原生 Git 支持                                  | 子模块 URL 若为私有，公开仓库 clone 会失败或泄露指向；merge/release 流程复杂；版本漂移需手动切指针 | 低-中                          | 低（但子模块指针易忘更新）                | 两仓库必须字节级共用同一份文件         |
| C | Git Subtree                      | 代码真正复制进公开仓库，无外部依赖                                            | **直接违背保密目标**——引擎源码进入公开仓库；同步需手动 `subtree pull`                  | 低                            | 中                            | 你确实想让两份代码都在公开仓库时        |
| D | Sparse Checkout                  | 从单一大仓只检出子集                                                   | 公开仓库仍持有引擎目录，仅"不显示"；并非真正隔离；保密性弱                                 | 低                            | 中                            | 单仓多子项目过滤                |
| E | Flutter Plugin（含平台通道）            | 可带原生代码、可发 pub                                                | 下载/缓存是纯 Dart 逻辑，引入 plugin 的 android/ios 原生模板属过度设计；构建复杂度上升      | 高                            | 中                            | 功能依赖原生平台 API 时          |
| F | 仅 Feature Flag + 空壳（不抽包）         | 改动最小                                                         | 引擎源码仍留在主工程，向公开仓库搬运时**仍需处理这些文件**，只是默认不启用——未解决"搬运"痛点             | 低                            | **高**（每次仍要小心排除这些文件）          | 只在单仓库内做功能开关             |

**结论**：方案 F 不解决核心痛点；C/D 直接违反保密诉求；B 在保密与协作上有硬伤；E 过度设计。方案 **A（独立私有包 + 接口契约 + 开关）** 在保密性、复用性、版本可控性、长期迁移成本四项上综合最优，且对 Flutter 工程是惯用做法。

---

## 3. 推荐方案与侵入性分析

### 3.1 推荐架构（已选路径 A：公开库为干净版）

核心原则：**公开库被推送的源码中，完全不存在对下载/缓存的引用**。因此公开库不再保留接口、NoOp、开关，也不再包含下载按钮、缓存设置等 UI。下载/缓存作为一个完整功能，**整体外置到私有包 `md3_download_cache`**，由私有构建使用；公开构建即为"无此功能"的干净版本——这同时彻底消除了你最初"每次都要搬运这两块"的痛点（根本不用搬了）。

```
本仓库 private_md3music（私有主工程 / 唯一代码源）
├── lib/
│   ├── main.dart                      # 公开入口：装配"干净"Provider 树（无下载/缓存）
│   ├── main_private.dart              # 【私有专属，导出公开时排除】入口：装配包内增强树
│   ├── providers/player_provider.dart # 基础播放，不含任何 cache 调用（公开/私有共用）
│   └── ...（其余与下载/缓存无关的业务）
├── packages/
│   └── md3_download_cache/            # 【本地包，导出公开时整体排除】
│       ├── lib/
│       │   ├── download/   # DownloadManager + 下载 UI（downloads_page / 下载按钮部件）
│       │   ├── cache/      # StreamCacheManager + StreamCacheRepository + CachedPlayerProvider
│       │   ├── augmented_providers.dart  # 组装"带下载/缓存"的 Provider 树
│       │   └── md3_download_cache.dart
│       └── pubspec.yaml    # name: md3_download_cache，独立版本号
└── pubspec.yaml                       # 含 md3_download_cache 的 path 依赖（导出公开时该依赖行被剥离）

公开仓库（由本仓库过滤导出的干净树，不含 packages/ 与 main_private.dart）
├── lib/main.dart + 干净 Provider 树 + 与下载/缓存无关的业务
└── pubspec.yaml    # 无 md3_download_cache 依赖
```

### 3.2 关键设计决策

- **公开库零引用**：下载/缓存相关的所有代码（引擎、模型、持久化、UI、Provider 增强、入口）都只在私有包与 `main_private.dart` 中。公开库 `player_provider` 是干净基础版，不 import 任何 cache 符号。
- **增强 Provider 模式（避免两份维护）**：公开 `PlayerProvider` 为基础类；私有包提供 `CachedPlayerProvider extends PlayerProvider`（或组合），仅在播放方法内追加 cache 调用。公开源码不含该子类。
- **下载 UI 外置**：下载按钮、下载页、缓存设置项等 UI 全部位于私有包；公开 `song_list_item` 等共享部件保持干净，私有包通过自己的部件/路由提供带下载入口的界面。
- **构建目标分离**：公开用 `flutter build -t lib/main.dart`；私有用 `flutter build -t lib/main_private.dart`。两个入口各自装配 Provider 树，互不污染。
- **包不反向依赖主工程模型**：包只收原始值/极简 DTO；原对 `SettingsRepository` 的依赖改为注入回调；包内不 import 任何主工程类型。

### 3.3 单一代码源与差异收敛

- **本仓库即唯一代码源**：下载/缓存功能以本地包 `packages/md3_download_cache/` 形式存在于本仓库，而非另一个仓库；公开版本不是独立维护的副本，而是本仓库的过滤导出树。
- 公开/私有的**唯一差异**收敛为三点，且全部在导出时自动剥离：(1) `packages/md3_download_cache/` 目录是否存在；(2) `lib/main_private.dart` 是否存在；(3) `pubspec.yaml` 中那一行 path 依赖。
- 注意：这三点在本仓库中**正常提交、不被 `.gitignore`**（因为本仓库是私有单一源，必须持有）；它们只在"导出公开"步骤被排除。
- 新功能在本仓库开发时，与下载/缓存完全无关，**无需搬运、无需开关、无需接口**；导出脚本自动产出干净公开树。

### 3.4 公开版本导出机制（消除搬运的核心）

- 编写过滤导出脚本（如 `scripts/export_public.*`；脚本本身不含任何 `download`/`cache` 语义，可随公开树安全发布），流程为：
  1. 以本仓库为源，生成过滤后的工作副本；
  2. **文件级排除** `packages/md3_download_cache/` 与 `lib/main_private.dart`；
  3. **改写 `pubspec.yaml`**：剥离 `md3_download_cache` 那一行 path 依赖；
  4. 对导出树运行**否认清单 grep 闸门**，零命中方可推送；
  5. 推送到公开仓库（如 `git push public <branch>`）。
- 该机制使"向公开同步新功能"收敛为**一条命令**，从根上消除原痛点——不再手工挑选/搬运文件，也不存在"漏搬/错搬"风险。
- 导出树即公开仓库内容：仅含 `lib/main.dart` + 干净 Provider 树 + 与下载/缓存无关的业务 + 无包依赖的 `pubspec.yaml`。

### 3.5 侵入性评估（路径 A）

| 区域                                      | 侵入程度       | 说明                                              |
| --------------------------------------- | ---------- | ----------------------------------------------- |
| 引擎/模型/持久化                               | 低          | 整体迁入本仓库内本地包 `packages/md3_download_cache/`，逻辑不变 |
| 公开 `player_provider.dart`               | 低          | 移除约 20 处 cache 调用，回归干净基础播放（本就是"删调用"而非"改调用"）     |
| 下载 UI / 设置项                             | 低（在本地包内新建） | 公开侧直接移除相关 UI 引用                                 |
| 新增 `main_private.dart` + 本地包增强 Provider | 中          | 私有侧一次性搭建，之后稳定                                   |
| 公开 `pubspec.yaml` / `app.dart`          | 低          | 移除 download/cache 相关 Provider 注册                |

**总体**：公开库是"减法"（移除引用），本地包是"整体承接"。符合外科手术式最小改动——公开侧只删不加。

---

## 4. 分阶段实施计划

> 每一阶段都给出"创建/修改文件""做什么""成功标准"。**不包含实现代码**。建议每阶段结束即提交一次（conventional commit：`refactor(download-cache): ...`）。

### 阶段 0 — 准备：在本仓库内建立本地包（承载完整功能）

- 在本仓库新建 `packages/md3_download_cache/`，初始化 `pubspec.yaml`（name: `md3_download_cache`，version: `0.1.0`），依赖 `dio` / `path_provider` / `audio_metadata_reader` / `provider`（如需）。
- 规划包内目录：`download/`（引擎 + 下载 UI）、`cache/`（引擎 + 增强 Provider）、`augmented_providers.dart`、`md3_download_cache.dart`。
- 本仓库根 `pubspec.yaml` 增加对该包的 **path 依赖**（`md3_download_cache: path: packages/md3_download_cache`）。
- **成功标准**：本仓库 `flutter pub get` 通过；现状不受影响（包内尚未有代码，仅骨架）。

### 阶段 1 — 将完整功能迁入本地包 + 私有入口

- 将 `download_manager.dart`、`stream_cache_manager.dart`、`stream_cache_repository.dart`、相关模型（`DownloadTask`、`CacheEntry` 系列、`CacheStats`）、下载 UI（`downloads_page`、`song_list_item` 中的下载按钮部件）、缓存设置项 UI 全部迁入 `packages/md3_download_cache/`。
- 在包内提供 `CachedPlayerProvider`（extends 公开 `PlayerProvider`），仅在该子类内追加 cache 调用（约 20 处）；公开 `PlayerProvider` 保持干净基础版、不被改动。
- 包内仅收原始值/极简 DTO；原对 `SettingsRepository` 的依赖改为注入回调；包不 import 主工程类型。
- 本仓库新增 `lib/main_private.dart`（装配包内增强树），该文件在导出公开时排除。
- **成功标准**：本仓库 `flutter analyze` 通过；私有入口 `flutter run -t lib/main_private.dart` / 打包后下载 + 边听边存 + 歌词/封面缓存行为等价于改造前（真机验证见阶段 5）。

### 阶段 2 — 公开树做"减法"（彻底移除引用）

- 从 `player_provider.dart` 移除全部 cache 调用（约 20 处），回归干净基础播放。
- 移除公开侧下载相关引用：`downloads_provider.dart` 注册、`widgets/song_list_item.dart` 的下载按钮、`modules/user/downloads_page.dart` 路由、`modules/settings/settings_page.dart` 的缓存统计/清空入口、`app.dart` 中 `DownloadsProvider` 注册。
- 删除已迁出的引擎文件（`download_manager.dart`、`stream_cache_manager.dart`、`stream_cache_repository.dart`、对应模型）。
- **成功标准（公开干净度断言）**：对 `lib/`（**不含 `packages/`**）运行否认清单 grep `StreamCacheManager\|DownloadManager\|downloads_provider\|getCachedAudioPath\|md3_download_cache` **零命中**；`flutter analyze` 与 `flutter test` 全绿。包内命中为预期、不计入。

### 阶段 3 — 双入口构建 + 过滤导出脚本（核心：自动产出公开树）

- 公开入口 `flutter build -t lib/main.dart`；私有入口 `flutter build -t lib/main_private.dart`。
- 编写 `scripts/export_public.*`（过滤导出脚本，不含 download/cache 语义，可随公开树安全发布）：排除 `packages/md3_download_cache/` 与 `lib/main_private.dart`；剥离根 `pubspec.yaml` 中包依赖行；对导出树跑否认清单 grep 闸门；推送公开仓库。
- **关键澄清**：`packages/` 与 `lib/main_private.dart` 在本仓库中**正常提交、不加入 `.gitignore`**（本仓库是私有单一源，必须持有它们）；它们只在"导出公开"步骤被排除，而非靠 gitignore 隐藏。
- **成功标准**：一条命令产出公开树并推送；公开树 `flutter analyze` + 否认清单零命中；两种 target 各自可构建。

### 阶段 4 — 版本管理与安全闸门

- **版本管理**：本地包按 semver（`packages/md3_download_cache/pubspec.yaml` 的 version 字段）；本仓库整体作为版本锁（commit / tag），导出公开时锁定该快照。
- **CI 泄漏闸门（核心防线）**：在导出脚本与公开仓库 CI / pre-push 中扫描导出树，命中否认清单（`download`、`cache`、`StreamCache`、`DownloadManager`、`DownloadsProvider`、`getCachedAudioPath`、`md3_download_cache`、`WITH_DOWNLOAD_CACHE` 等）即拒绝推送。
- **机密确认**：确认 API 签名/密钥/私有端点不出现在将被公开的文件中。
- **成功标准**：公开树推送前自动断言零命中；版本锁定可复现。

### 阶段 5 — 验证与回滚

- 私有：`flutter build apk`（或 `scripts/build_android.ps1`），`adb install` 到 `R52R30F3Q9Z` 真机：下载→本地文件 + 元数据嵌入；播放→边听边存命中；设置页缓存统计与清空正常。
- 公开：`flutter analyze` + `flutter test` 通过；导出树否认清单零命中。
- **回滚预案**：每阶段独立提交；若阶段 2 移除导致播放回归，单独 `git revert` 该阶段；保留原单例文件于 `backup/pre-isolation` 分支一周后再清理。
- **成功标准**：私有行为等价；公开零引用、可构建可测试。

---

## 5. 关键风险与缓解

| 风险                              | 缓解                                                   |
| ------------------------------- | ---------------------------------------------------- |
| 阶段 4 的 player_provider 改动量大导致回归 | 方法签名 1:1 对应，改造后优先做真机播放回归；保留 backup 分支                |
| 包依赖主工程模型导致循环依赖                  | 坚持"包只收 DTO/原始值"，适配器放主工程接线层                           |
| 公开/私有 wiring 漂移                 | 收敛为 2 个稳定文件（pubspec 依赖 + wiring），纳入 review checklist |
| 引擎行为在包内与历史不一致                   | 阶段 2 抽取单元测试覆盖下载/缓存/清理核心路径                            |
| 误将引擎推入公开仓库                      | 阶段 5 的 grep 断言 + CI 闸门                               |

---

## 7. 补充：如何彻底杜绝公开库"看到"接口（用户追问）

### 7.1 结论先行

按第 3 节原方案，**公开库会看到接口**。接口文件（`contracts.dart` / `noop_impl.dart` / `config.dart`）本身是公开仓库 push 出去的源码；方法名与 DTO 字段已经泄露"本 App 具备下载与边听边存能力"，`WITH_DOWNLOAD_CACHE` 开关更直白地宣告"此处有一个可开启的下载/缓存能力"。原方案解决的是**引擎实现不泄露**，但**特征的存在性仍泄露**。

### 7.2 根本约束

只要公开库的某段代码（UI 或逻辑）需要调用下载/缓存，就必然要按某个名字引用它们——要么按接口类型名，要么按注册 key。因此：

> **"彻底杜绝" ⇔ 公开库被推送的源码中完全不存在任何对这两块功能的引用。**

### 7.3 三条路径对比

| 路径                     | 做法                                                                                           | 能否彻底杜绝                           | 代价                                 |
| ---------------------- | -------------------------------------------------------------------------------------------- | -------------------------------- | ---------------------------------- |
| **A. 公开库 = 干净版**（最强保密） | 接口、NoOp、开关、相关 UI、调用**全部不进入公开库**；下载/缓存作为一个整体只存在于私有包 + 私有覆盖层。公开构建即"无此功能"的版本                    | ✅ 能                              | 公开库完全不能用下载/缓存（无按钮、无调用、无接口）         |
| **B. 功能可用、引擎私有**（原方案）  | 公开库保留接口 + NoOp + 开关以编译/运行                                                                    | ❌ 不能                             | 仅能以"不透明命名 + 语义词移入私有包 + CI 闸门"最小化泄露 |
| **C. 通用能力接缝**（折中）      | 公开库只留一个**语义中立**的能力注册表（按字符串/哈希 key 存取），具体能力在私有覆盖层以不透明 key 注册并接线；公开源码不出现 `download`/`cache` 等词 | ⚠️ 近似能（仅泄露"存在一个可插拔能力机制"，不泄露具体特征） | 失去类型安全；接线更脆弱                       |

### 7.4 推荐与对应修订（已确认采用路径 A）

- 用户已确认选 **A**：公开库为干净版，彻底不含下载/缓存（无接口、无 NoOp、无开关、无 UI）。**前提已明确为"本仓库即私有主工程（单一代码源）"**：第 3 节已改为"功能整体外置于本仓库内的本地包 `packages/md3_download_cache/` + 私有入口 `main_private.dart`，公开版本由本仓库过滤导出"的架构；第 4 节已改为"本仓库内建包 + 公开树减法 + 过滤导出脚本 + 双入口构建"的分阶段步骤。**导出公开不再是手工搬运，而是一条命令的过滤导出。**
- 该选择同时最彻底地解决了用户最初的痛点：新功能在公开仓库开发时与下载/缓存完全无关，根本无需搬运、无需开关、无需接口。
- 若未来公开库必须能调用这两块（只是引擎保密），可回退到 **B/C**，并接受接口这一最小泄露，配合 7.5 的 CI 闸门兜底。

### 7.5 通用兜底：CI 泄漏闸门

无论选哪条路径，都在公开仓库的 CI / pre-push 中加一道断言：扫描待推送源码，若命中**否认清单**（`download`、`cache`、`StreamCache`、`DownloadManager`、`CacheSongRef`、`LyricData`、`WITH_DOWNLOAD_CACHE` 等）则拒绝推送。这是对"误带"的最后防线。

> 本节为对原方案的安全性强化补充。具体采用 A/B/C 哪一种，需先确认"公开库是否需要实际具备该功能"，再据此修订第 3、4 节。

---

## 6. 自我核查（对照需求）

- [x] 第 1 节：诊断现状、痛点、风险点（含耦合与泄密风险）
- [x] 第 2 节：对比插件化 / 接口抽象 / 独立包 / submodule / subtree / sparse checkout 等方案优劣与迁移成本
- [x] 第 3 节：推荐方案 + 理由 + 侵入性量化
- [x] 第 4 节：分阶段落地（本仓库内建本地包 → 公开树减法 → 过滤导出脚本 → 双入口构建 → 版本与安全闸门）
- [x] 第 3.4 节：明确"公开版本 = 本仓库过滤导出树"机制，从根上消除手工搬运痛点
- [x] 全程未修改任何代码、未提供实现代码，仅方案与计划

---

## 8. 执行状态（2026-08-23 已按计划实施）

| 阶段 | 状态 | 说明 |
|------|------|------|
| 阶段 0 | ✅ 完成 | 本地包 `packages/md3_download_cache/`（引擎+DTO+barrel），根 `pubspec.yaml` path 依赖，`flutter pub get` 通过 |
| 阶段 1 | ✅ 完成 | 引擎迁入包（DTO 适配、缓存上限注入）；私有层 `lib/private/`（downloads_provider / downloads_page / cache_bridge / enhanced_ui / main_private）；`flutter analyze` 通过 |
| 阶段 2 | ✅ 完成 | 公开树减法：player_provider(4 钩子)、kugou_provider(2 钩子)、smart_artwork_image、song_list_item、full_player(+_am)、settings_page、user_center_page、playlist_page、play_history_page、app.dart(extraProviders)；`lib/`（不含 private）否认清单 grep **零命中**；删除 7 个旧引擎/下载文件 |
| 阶段 3 | ✅ 完成 | 双入口分离；`scripts/export_public.ps1` 过滤导出 + 否认清单闸门（一条命令）；导出树 `flutter pub get` + `flutter analyze` **零错误**；`build_android.ps1` 默认改走私有入口 |
| 阶段 4 | ✅ 完成 | 包版本 0.1.0；`scripts/verify_public_clean.ps1` 独立闸门（lib/ 命中即失败） |
| 阶段 5 | ⏳ 待办 | 真机验证：设备 `R52R30F3Q9Z` 接入后 `adb install`，验证下载/边听边存/缓存统计与清空；回滚预案见下 |

**实现要点（与计划的 2 处必要修正）**
1. **增强 Provider 不能进包**：Dart 禁止循环包依赖（主工程 path 依赖包，包不能再 extends 主工程 `PlayerProvider`）。改为**中性静态钩子**（如 `PlayerProvider.resolveLocalAudioPath`），公开基类零下载/缓存符号，私有层 `installCacheHooks()`/`installUiHooks()` 注入实现。
2. **私有入口在 `lib/private/main_private.dart`**（非 `lib/main_private.dart`），随 `lib/private/` 整体排除。

**二次迭代（2026-08-23 深夜）：残留清零（形态 B + 设置 API 迁移 + 闸门强化）**
- **问题 1（设置 API 泄露）**：`getStreamCache*`/`getDownloadDir` 等 8 个方法 + 4 个 key 从公开 `settings_repository.dart` 迁入 `lib/private/private_settings.dart`（key 不变兼容存量），公开树零私有设置 API。
- **问题 2（搜索索引）**：settings_page 搜索索引 5 条边听边存/下载关键词删除，改由 `extraSearchIndexEntries` 注入（私有侧随 extraCategories 注入）。
- **3c 形态 B（筛选功能移入私有层）**：playlist_page/play_history_page 删除筛选状态/按钮/文案，公开类只留 `songFilterHook`（`List→List` 纯函数插槽）+ `songFilterListenable`（重建信号）+ `extraAppBarActionsBuilder`（按钮注入）；筛选开关/查询/实时过滤全部在 `lib/private/enhanced_ui.dart`（按 pageKey 隔离状态）。
- **低危清理**：`_cachedArtworkPath`→`_localArtworkPath`、`_cachedArtworkBytes`→`_localArtworkBytes` 等字段/注释中性化。
- **问题 4（闸门强化）**：否认清单外置 `scripts/public_deny.txt`（UTF-8，英文符号 + 中文特征短语 `边听边存`/`仅显示已缓存` 等），`export_public.ps1` 与 `verify_public_clean.ps1` 共用读取（脚本本体保持纯 ASCII，防 PS5.1 编码坑）。
- **验证**：公开树特征残留 grep 零命中；analyze 零错误；test +345 无回归；导出树 analyze 零错误 + 闸门通过。

**回滚预案**：本阶段改动尚未提交。执行 `git checkout -- .` + `git clean -fd lib/private packages scripts/export_public.ps1 scripts/verify_public_clean.ps1 scripts/public_deny.txt` 可完整回到改动前；已确认通过后再按逻辑单元提交（引擎入包 / 公开树减法 / 残留清零 / 导出脚本各一个 commit）。

> 下一步：接入真机 `R52R30F3Q9Z` 执行阶段 5 真机验证（下载→本地文件+元数据嵌入；播放→边听边存命中；设置页缓存统计/清空；`flutter test` 全绿（预存 19 个插件依赖测试除外））。

