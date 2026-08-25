# AGENTS.md — MD3Music 项目约定

> 本文件供 AI Agent 和开发者快速了解项目结构、模块边界、构建流程与已知陷阱。

> **适用范围**：全文描述当前分支 `rust-local-two`（Rust 架构，唯一活跃主线）。
> 旧 Node.js 架构分支 `arch-local-first` 已弃用，仅存于上游供对照，其说明以该分支自带的 AGENTS.md 为准；远端与架构对照见[第 7 节](#7-git-分支与远端约定)。

---

## 0. 核心工作准则（必读）

1. **判断功能/Bug 状态必须基于日志，不能只凭截图。**
   真机排查时，以 `adb logcat` 等日志输出为准（关键路径已带 `[RomaToggle]`、`[LyriconDebug]` 等调试标签）。
   截图只能作为补充参考，**不能**作为"功能是否生效 / Bug 是否存在"的判定依据；涉及状态判断时先确认日志证据。

2. **临时调试/测试产物一律放 `tmp/` 目录（已被 .gitignore 忽略，永不提交）。**
   调试截图、临时脚本、测试数据、日志导出文件、验证用的临时 APK 等，禁止散落在项目根或其他目录；
   `tmp/` 之外的临时文件在提交前必须清理或移入 `tmp/`。

3. **添加/改名/删除设置项后必须运行设置搜索索引生成脚本。**

   ```powershell
   dart run scripts/tools/gen_settings_search_index.dart
   ```

   产物 `lib/modules/settings/settings_search_index.g.dart` 需与源码改动一起提交（禁止手改产物）。
   `scripts/md3.ps1 commit / android / windows` 会在流程开始时静默跑一次并在产物有变化时提示，
   但不要依赖它兜底：改完设置项就手动跑一遍，索引不一致会被
   `test/modules/settings/settings_search_index_test.dart` 判为失败。详见 3.3。

---

## 1. 项目架构概览

MD3Music 是一款 Android 音乐播放器（当前版本 `pubspec: 5.0.0+17`），采用 **Flutter 前端 + 嵌入式 Rust API 服务器** 的混合架构：

- **Flutter 前端**（Dart）：负责 UI、播放控制、本地数据管理
- **嵌入式 Rust 服务器**（Rust）：App 启动时通过 `libkugou_server.so`（JNI/MethodChannel，`dart:ffi` 兜底）在进程内启动一个 `tiny_http` HTTP 服务器，监听 `127.0.0.1` 上的**随机端口**（`[10000, 60000]`，被占用则 1s 后换下一个，最多 10 次），实际端口通过 MethodChannel/FFI 返回给 Dart 写入 `KugouEndpoints.baseUrl`。处理所有酷狗音乐 API 请求。Rust 实现取代了旧的 `libnode.so` + `server_bundle.js`（Express）方案，行为与酷狗云端等价。
- **登录接口同样走本地 Rust 服务器**：`/login/*`（11 个）、`/captcha/sent`、`/register/dev` 共 13 个登录端点由 Rust `login.rs`/`misc.rs` 用本地设备身份（dfid/mid）直连酷狗上游（`login-user.kugou.com` / `loginserviceretry.kugou.com` / `login.user.kugou.com` / `gateway.kugou.com` 等），不再依赖第三方云端（旧 `networkapi/` 已退役，仅作 JS 参考）。

核心设计理念：所有音乐搜索、歌词、排行榜、登录等 API 请求都走本地 Rust 服务器转发，避免直接暴露 API 密钥在客户端。

---

## 2. 模块边界

```
md3Music/
├── lib/                          # Dart 前端（Flutter）
│   ├── main.dart                 # 公开入口：runBootstrap() → runApp（下载/缓存无关）
│   ├── app.dart                  # MaterialApp 配置、主题、导航、Tab 布局（MyApp.extraProviders 扩展点）
│   ├── core/                     # 核心层：services/（桌面歌词、均衡器、Lyricon、USB 音频、DLNA、频谱等）、
│   │                             #   theme/、layout/、utils/、widgets/
│   ├── data/                     # 数据层：models/、repositories/（settings_repository 等）
│   ├── modules/                  # 功能模块（20+ 个，按功能域分组）：discover / home / charts / channel /
│   │                             #   personal_fm（浏览发现）、player（播放）、search（检索）、
│   │                             #   library / playlist / album / artist（曲库）、login / user / settings（账户）、
│   │                             #   audiobook（听书）、recognition（听歌识曲）、scene / coverflow / ip 等
│   ├── providers/                # 状态管理：PlayerProvider、KugouProvider、ThemeProvider...
│   ├── services/                 # 服务层：kugou_server.dart（MethodChannel + dart:ffi 启动服务器）、kugou_api/
│   ├── utils/                    # 通用工具：data_migration_tool、landscape_immersive
│   ├── widgets/                  # 共享 UI 组件（歌词 apple_lyrics/、播放器控件等）
│   └── private/                  # 【私有层，导出公开版本时整体排除】下载/缓存钩子注入、
│                                 #   downloads_provider、downloads_page、私有入口 main_private.dart
│
├── packages/
│   └── md3_download_cache/       # 【私有功能包，导出公开时整体排除】下载/缓存引擎（path 依赖，
│                                 #   自包含，不依赖主工程类型：Song→SongMetadata、KugouLyric→LyricData）
│
├── kugou_api_server/             # 本地 API 服务器（Rust，编译为 cdylib 打包进 APK）
│   ├── rust/                     # Rust crate（crate 名 kugou_server）
│   │   ├── src/
│   │   │   ├── lib.rs            # 对外 FFI/JNI 符号：start_server/stop_server/is_server_running/
│   │   │   │                     #   get_server_port + Java_com_md3music_..._native*
│   │   │   ├── server.rs         # tiny_http 服务器：CORS、cookie、body 解析、apicache、路由分发
│   │   │   ├── modules/          # 按端点分组的 38 个 API 模块（search.rs、audio.rs、lyric.rs、
│   │   │   │                     #   playlist.rs、user.rs、youth.rs、song_url.rs...），
│   │   │   │                     #   mod.rs 的 register() 汇总注册 170 个路由
│   │   │   ├── crypto.rs         # MD5/SHA1/AES/RSA（与 JS CryptoJS 行为对齐）
│   │   │   ├── request.rs        # 上游转发（ureq）、签名、响应组装
│   │   │   ├── device.rs         # dfid/mid 设备信息持久化（device_info.json）
│   │   │   ├── cache.rs / config.rs / helper.rs / util.rs / simulate.rs
│   │   │   └── ...
│   │   ├── tests/smoke.rs        # 本地冒烟测试（不依赖外网）
│   │   ├── .cargo/               # 可选的 Android 交叉编译 linker/CC 配置
│   │   └── Cargo.toml            # crate-type = ["cdylib", "rlib"]
│   ├── module/                   # 旧 JS 模块（200+，已被 Rust 取代，仅作参考/对照）
│   ├── util/                     # 旧 JS 工具（仅供 networkapi 参考）
│   └── server.js / bundled_entry.js / server_bundle.js   # 旧 Node 方案遗留，不再打包
│
├── networkapi/                   # 旧公网登录服务器（Node.js，已退役，仅作 JS 参考）
│   ├── server.js                 # 精简版 Express，只加载登录相关模块
│   ├── module/                   # 登录、注册、验证码等模块
│   └── util/                     # 独立的工具函数副本（与 Rust 端已分家，见 4.6）
│
├── android/                      # Android 原生层
│   ├── app/src/main/jniLibs/     # libkugou_server.so（4 ABI，x86 那份已陈旧；口径见 4.7）
│   ├── app/src/main/kotlin/      # Kotlin 原生代码（MediaSession、KugouApiService、桌面歌词、
│   │                             #   UsbAudio*、MetadataWriterPlugin、miuix Compose 页等）
│   └── app/src/main/cpp/         # USB 独占输出（usb-audio-output.cpp，UAC1 DAC 直写 usbdevfs ISO URB）
│                                 #   经 CMake 编译（externalNativeBuild 仍启用，见 4.7）
│
├── assets/
│   ├── fonts/                    # 内置字体（simhei.ttf）
│   ├── images/                   # 应用图标
│   └── web/                      # 内置 web 资源
│
├── windows/                      # 【私有版】Windows 桌面工程（公开导出时整体排除，见 9.4）
├── third_party/just_audio/       # just_audio 本地 fork（注入可拦截 AudioSink 的 RenderersFactory）
├── docs/                         # 文档：public_private_workflow.md（双仓库工作流权威手册，见第 9 节）等
│
└── scripts/                      # 构建/导出/提交脚本（统一入口 md3.ps1，无参数进交互界面）
    ├── md3.ps1                   # 总入口：android / windows / verify / export / commit
    ├── lib/common.ps1            # 公共库：输出/外部命令/Rust 改动检测/否认清单闸门/参数解析/自动代理
    ├── lib/ui.ps1                # 终端 UI：鼠标+键盘的菜单 / 参数面板 / 勾选列表
    ├── lib/ui.tests.ps1          # ui.ps1 事件解码回归测试（不需要真实控制台）
    ├── tasks/android.ps1         # Rust 交叉编译 + Flutter 打包（默认私有入口）
    ├── tasks/windows.ps1         # Windows 桌面构建（便携版 zip）
    ├── tasks/export_public.ps1   # 导出公开版本（过滤 + 否认清单闸门 + 可选推送/PR）
    ├── tasks/verify_public.ps1   # 公开树洁净度校验（lib/ 否认清单零命中）
    ├── tasks/commit.ps1          # 一键提交（TUI 勾选改动 → 闸门 → 提交 → 推送 → PR/合并）
    ├── tasks/token.ps1           # GitHub token 管理（DPAPI 加密存 %LOCALAPPDATA%，不入库）
    ├── public_deny.txt           # 否认清单（export/verify 共用，见 8.2）
    └── test_api.ps1              # API 测试脚本
```

### 关键边界规则

| 边界 | 说明 |
|------|------|
| `lib/` ↔ `kugou_api_server/rust/` | Dart 前端通过 HTTP `127.0.0.1:<随机端口>` 调用 API（端口由 `startServer`/`start_server` 返回，写入 `KugouEndpoints.baseUrl`）；启动/停止走 `KugouApiService` 的 MethodChannel（`com.md3music.md3music/kugou_api`：startServer/isRunning/stopServer），`dart:ffi` 直连 `start_server` 作为兜底 |
| `kugou_api_server/rust/` ↔ `networkapi/` | 两者代码完全独立，不再共享 util；networkapi 已退役（登录已改由 Rust 直连酷狗），仅作 JS 参考 |
| `kugou_api_server/module/` 等 JS 文件 | 旧 Node 方案遗留，已被 Rust 取代，**不要**再修改 JS 版模块或重新打包 |
| `android/app/src/main/jniLibs/` | 原生库目录，`libkugou_server.so` **已提交进 Git**（从 `rust/target/*/release/` 复制），无需下载；4 个 ABI 目录中 **x86 那份已陈旧**，ABI 口径见 4.7 |
| `android/app/src/main/cpp/` + `kotlin/.../md3music/UsbAudio*.kt` + `third_party/just_audio` | **USB 独占输出**：绕过 AudioFlinger，经 usbdevfs ISO URB 直写 UAC1 DAC（参考 [decent-player](https://github.com/Ma145/decent-player) 的 bit-perfect 驱动思路）。该目录由 **CMake/`externalNativeBuild` 编译（仍启用，见 4.7）**；释放恢复见 4.10 |
| `assets/nodejs-project/` | 已从 `pubspec.yaml` 移除，不再打包；旧 `server_bundle.js` 仅作参考 |
| `lib/`（公开树） ↔ `packages/md3_download_cache/` + `lib/private/`（私有内容） | **下载/缓存隔离**：公开树 `lib/`（不含 `lib/private/`）**零下载/缓存符号**；引擎与私有层只在私有构建存在。公开类通过**中性静态钩子**扩展（见 2.1）；公开版本由 `scripts/md3.ps1 export` 过滤导出（排除 `packages/`、`lib/private/`、`pubspec.lock`，剥离私有依赖，否认清单闸门），详见[第 8 节](#8-下载缓存功能隔离私有功能包--公开导出) |
| `lib/main.dart` ↔ `lib/private/main_private.dart` | 双入口：公开入口 `lib/main.dart`（干净树）；私有入口 `-t lib/private/main_private.dart`（装配下载/缓存）。`md3.ps1 android` 默认构建私有入口 |

### 2.1 下载/缓存隔离：公开类中性钩子速查

> 公开树不 import 任何下载/缓存符号。需要下载/缓存能力时，公开类暴露**语义中性的静态扩展点**，由 `lib/private/` 的 `installCacheHooks()` / `installUiHooks()` 在私有入口 `main_private.dart` 中注入实现。**新增功能若依赖这两块，一律在 `lib/private/` 或包内实现，不得向公开类 import 私有符号。**

| 公开类（文件） | 中性扩展点 | 私有注入内容 |
|------|------|------|
| `PlayerProvider` | `resolveLocalAudioPath` / `resolveLocalArtworkPath` / `onPlaybackSourceStarted` / `onPlaybackSourceStopped` / `extractEmbeddedArtwork` | 播放前查本地持久化音频/封面、播放后异步缓存、停止取消下载、云盘内嵌封面提取 |
| `KugouProvider` | `restoreLyric` / `storeLyric` | 歌词读取/存储旁路 |
| `SmartArtworkImage` | `localArtworkReader` | 按 songId 读本地持久化封面字节 |
| `SongListItem` | `extraMenuTilesBuilder` | 更多菜单的「下载 / 删除下载」条目 |
| `FullPlayer` / `AmStyleFullPlayer` | `coverLongPressCallback` | 封面长按 → 下载音质选择对话框 |
| `SettingsPage` | `extraCategories` / `extraSearchIndexEntries` | 「边听边存」「下载」两个设置分类 + 其搜索索引关键词 |
| `UserCenterPage` | `extraActionItemsBuilder` | 快捷操作网格的「下载」入口 |
| `PlaylistPage` / `PlayHistoryPage` | `songFilterHook` / `songFilterListenable` / `extraAppBarActionsBuilder` | 可播放（已本地持久化）筛选：公开类只剩 `List→List` 变换插槽 + 重建信号，筛选状态/按钮/查询全部在私有层 |
| `MyApp`（app.dart） | `extraProviders` | 注册 `DownloadsProvider` |

---

## 3. 构建流程

### 3.1 完整构建顺序（Windows 本机 / CI）

> **Windows 本机（推荐）**：本机未装 MSVC（缺 `link.exe`），用 GNU toolchain + MinGW 作为 host 编译器。一键脚本 `scripts/md3.ps1 android` 已封装全部流程。

```
步骤 1: 构建 Rust 服务器 cdylib（修改 rust/src 后必须执行）
   └── 一键脚本（推荐，Windows 本机用 PowerShell 脚本）：
           .\scripts\md3.ps1 android
           # 参数：-ForceRust 强制重编；-SkipFlutter 只更新 .so 不打 APK；-NdkPath 手动指定 NDK
       脚本会自动：
           1. 检测 Rust 代码是否有改动（git status + .so 时间戳比对）
           2. 有改动 → 交叉编译 3 个 ABI（arm64-v8a / armeabi-v7a / x86_64，**不含 x86**；x86 那份 `.so` 因此陈旧，ABI 口径见 4.7）
           3. 覆盖 android/app/src/main/jniLibs/
           4. 无改动 → 跳过 Rust 编译，直接打包

步骤 2: Flutter 构建（由脚本自动执行，或手动）
   └── scripts/md3.ps1 android 默认构建【私有入口】（含下载/缓存）：
           flutter build apk --release --split-per-abi --target-platform android-arm64,android-arm,android-x64 -t lib/private/main_private.dart
       → build/app/outputs/flutter-apk/app-{abi}-release.apk
   公开版本构建入口为 lib/main.dart（见 3.5 导出流程）。
```

> **CI（Ubuntu GitHub Actions）**：使用 `kugou_api_server/rust/build_android.sh`（Linux shell 版，4 ABI），环境见 3.4。

### 3.2 开发时快速迭代（Windows 本机）

```powershell
# 只修改了 rust/src/ 下的代码时：
# 本机无 MSVC，需用 GNU toolchain 验证编译：
$env:CC_x86_64_pc_windows_gnu = "C:\Program Files (x86)\Dev-Cpp\MinGW64\bin\gcc.exe"
$env:AR_x86_64_pc_windows_gnu = "C:\Program Files (x86)\Dev-Cpp\MinGW64\bin\ar.exe"
cd kugou_api_server/rust && cargo +stable-x86_64-pc-windows-gnu check --release
# 或：cargo +stable-x86_64-pc-windows-gnu build --release（产出 host 版 .so）

# 交叉编译并覆盖 jniLibs 后，再运行：
flutter run

# 只改 Dart/Android/Kotlin 代码时：
flutter run
```

### 3.3 测试

```powershell
cd kugou_api_server/rust
$env:CC_x86_64_pc_windows_gnu = "C:\Program Files (x86)\Dev-Cpp\MinGW64\bin\gcc.exe"
$env:AR_x86_64_pc_windows_gnu = "C:\Program Files (x86)\Dev-Cpp\MinGW64\bin\ar.exe"
cargo +stable-x86_64-pc-windows-gnu test        # 本地冒烟：404/CORS/RSA 常量解析 + 路由 dispatch 断言
cargo +stable-x86_64-pc-windows-gnu clippy      # 静态检查（勿引入新 error）
```

Dart 侧：`flutter test`（`test/` 下 30 个测试文件）。**注意有预存失败基线**，见 8.3 末条——判断回归前先对照。

设置页搜索索引由源码生成，改动设置项（新增/改名/删除 tile）后**必须**重新生成（见 0 节第 3 条），
否则 `test/modules/settings/settings_search_index_test.dart` 会失败：

```powershell
dart run scripts/tools/gen_settings_search_index.dart   # 产出 lib/modules/settings/settings_search_index.g.dart
```

补充同义词写在 tile 上方注释 `// search: 别名1 别名2`；没有标题文本的控件
（纯图标滑块等）用 `// search-item: 标签 | 别名1 别名2` 手写声明；`// search: -` 排除。

`scripts/md3.ps1 commit / android / windows`（含直接调用 `scripts/tasks/*.ps1`）在流程开始时
会通过 `Sync-SettingsSearchIndex`（`scripts/lib/common.ps1`）静默跑一次生成器：无变化不输出，
有变化提示一行提醒一并提交；dart 缺失或生成失败只告警、不拦断构建与提交。

### 3.4 CI 流程（`.github/workflows/`）

`ci.yml`（主 CI）：

- 触发条件：push 或 pull_request 到 main/master，或手动 workflow_dispatch
- 环境：Ubuntu + Java 17 + Flutter stable + Android SDK `platforms;android-36` / `build-tools;36.0.0` + `ndk;28.2.13676358` + `cmake;3.22.1`（cmake 供 `cpp/` 的 USB 独占输出驱动，见 4.7）
- 旧 Node 流程（下载 libnode、esbuild 打包）**已从 CI 移除**；`libkugou_server.so` 已入库，Flutter 构建直接可用
- 签名：从仓库 `keystore` release 拉 `release.keystore`，拉取失败时回落 debug 签名
- 产物：三个 ABI 的 APK（arm64-v8a、armeabi-v7a、x86_64），并自动创建 `ci-<sha>` GitHub Release

其他工作流：`main.yml`（按 tag 正式发版）、`debug-build.yml`（手动指定 build_type 的调试构建）、`build-windows.yml`（Windows portable zip，私有版专用，**导出公开树时会被排除**，见 9.4）。

### 3.5 脚本入口与交互界面（鼠标 + 键盘）

`scripts/md3.ps1` 是所有构建/导出/提交任务的统一入口，**不带参数运行即进入交互界面**，双击运行也可用。

- **鼠标**：单击选中、双击执行/看 diff、点击 `[ 执行 ] [ 参数 ] [ 全选 ] [ 取消 ]` 等按钮、滚轮滚动列表
- **键盘**（等价可用）：`↑↓`/`jk` 移动，`Enter` 执行，`空格` 勾选/输入，`Esc` 返回，`q` 退出，勾选列表另有 `a` 全选 / `n` 全不选 / `i` 反选 / `d` 看 diff / `PgUp PgDn Home End`
- 任务列表上 `Enter` 或双击 = **直接用默认参数执行**；要改参数才需要 `空格` 或点 `[ 参数 ]` 进参数页
- 任务执行期间自动关掉鼠标模式（恢复 QuickEdit），构建日志仍可用鼠标选中复制

界面实现在 `scripts/lib/ui.ps1`（`ReadConsoleInput` + `ENABLE_MOUSE_INPUT`，定点重绘不闪屏）。
终端不支持鼠标时自动退回纯键盘，底部提示行会写明当前是哪种模式；输入/输出被重定向时（管道、CI、
被其他脚本调用）跳过界面并打印文本帮助，不会阻塞。事件解码有回归测试：
`powershell -File scripts\lib\ui.tests.ps1`。

```powershell
.\scripts\md3.ps1            # 交互界面
.\scripts\md3.ps1 help       # 文本帮助（子命令列表）
.\scripts\md3.ps1 <子命令> [参数...]   # 直接执行，参数按目标脚本的参数表解析后透传
```

### 3.5.1 公开版本导出（一条命令，见第 8 节）

```powershell
.\scripts\md3.ps1 verify                                  # 校验公开树 lib/ 否认清单零命中
.\scripts\md3.ps1 export                                  # 导出到 .public_export/（过滤 + 闸门）
.\scripts\md3.ps1 export -PublicRemote <公开仓库URL>       # 导出并推送到公开仓库（-f 覆盖）
.\scripts\md3.ps1 export -PublicRemote <URL> -AsPr        # 导出并在公开仓库开 PR（保留历史，可审阅差异）
# 公开树独立构建：cd .public_export && flutter pub get && flutter build apk --debug（入口 lib/main.dart）
```

### 3.6 一键提交（`md3.ps1 commit`）

TUI 勾选改动 → 否认清单闸门 → 提交 → 推送 → 可选开 PR，覆盖大部分 GitHub Desktop 场景。
未勾选的文件只是本次不提交，仍留在工作区（不写任何忽略文件）；**确认后按勾选结果重置暂存区**。

```powershell
.\scripts\md3.ps1 commit                                  # 交互：点击/空格 勾选，双击/d 看 diff，点 [提交所选] 或 Enter
.\scripts\md3.ps1 commit -All -Message "fix(player): ..."  # 非交互：全选 + 指定信息
.\scripts\md3.ps1 commit -Pr                              # 提交推送后向 upstream 开 PR（不合并）
.\scripts\md3.ps1 commit -PrMerge                         # 开 PR 并直接合并到 upstream，再拉回同步 origin
.\scripts\md3.ps1 commit -PublicPr                        # 提交后导出公开版并在公开仓库开 PR
```

- 不传 `-Message` 时按改动路径生成 `type(scope): 描述` 候选，回车接受或直接改写（描述必须人工确认）
- PR 创建优先用 `gh` CLI；未安装则构造 GitHub compare 链接并打开浏览器（标题/正文预填）
- 闸门与 `md3.ps1 verify` 同一实现（`lib/common.ps1` 的 `Invoke-DenyGate`），命中私有符号即中止提交

#### `-PrMerge`：向源仓库开 PR 并直接合并

`origin`（个人 fork）→ `upstream`（源私有仓库）的完整闭环，走 GitHub REST API（curl，与 git 共用同一套代理）：

1. 查已存在的同 head open PR，有则复用，没有才创建（避免重复开 PR）
2. 轮询等 GitHub 算出 `mergeable`（PR 刚建出来是 `null`，此时直接合并会被拒）
3. 用 **merge commit** 策略合并（与仓库既有 `Merge pull request #NN` 历史一致）
4. 合并成功后 `git fetch upstream <base>` → 合并到本地 → 推 `origin`，三方同步（`-NoSyncBack` 可跳过）

失败会给出确切原因并让退出码为 1：`403` 无合并权限、`405` 分支保护要求评审/CI、`409` head 已变化、
`mergeable=false` 有冲突。网络/5xx 抖动由 `Invoke-WithRetry` 重试，权限与冲突类错误不重试。

需要一个对 upstream 有写权限的 PAT，用 `md3.ps1 token` 管理：

```powershell
.\scripts\md3.ps1 token            # 交互管理（查看 / 设置 / 验证 / 删除）
.\scripts\md3.ps1 token -Show
.\scripts\md3.ps1 token -Set       # 输入时可选「永久保存」或「仅本次运行」
.\scripts\md3.ps1 token -Test      # 调 /user 验证
.\scripts\md3.ps1 token -Remove
```

取用顺序 `GH_TOKEN` → `GITHUB_TOKEN` → 本机保存。永久保存走 Windows DPAPI 加密，落在
`%LOCALAPPDATA%\md3music\github_token.dat`（**不在仓库内**，换用户或换机器都解不开）；
选「仅本次运行」则只写当前进程的 `$env:GH_TOKEN`，不落盘。
`-Yes` 或非控制台环境下不会弹输入提示（`Read-Host` 在重定向下会阻塞），而是直接报「没有可用的 token」。

### 3.7 GitHub 网络操作的自动代理（没开 TUN 也能推）

推送 / 克隆 / 开 PR 前会自动调用 `Enable-AutoProxy`（`lib/common.ps1`），判定顺序：

1. 环境里已有 `HTTPS_PROXY` / `ALL_PROXY` → 原样沿用，不干预
2. 直连 `github.com` 能通（TUN 模式开着）→ 不用代理
3. 否则逐个探测常见本地代理端口 `7890 / 7897 / 10809 / 7891 / 10808 / 1080 / 8889 / 2080`：
   先做 SOCKS5 握手 + 对 `github.com:443` 真实 CONNECT，通过则用 `socks5h://`；
   否则识别是否为 HTTP 代理并用 .NET 发一次 HTTPS HEAD 验证，通过则用 `http://`
4. 都没有 → 只警告，不阻断（自己开代理或设 `$env:HTTPS_PROXY` 后重试）

**只设置当前进程的 `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY`**，不写 `git config`，
不影响 GitHub Desktop 等其他工具；结果在本次运行内缓存，子脚本（如 commit 串联 export）
会沿用同一份而不重复探测。

> 优先 SOCKS5 是因为它的验证是对 `github.com:443` 的真实 CONNECT，比一次 HTTPS HEAD 更硬。
> 另外经代理访问 GitHub 时链路会**偶发抖动**（实测 `git ls-remote` 约 1/5 概率报
> `schannel: failed to receive handshake`，换 `http.sslBackend=openssl` 同样会失败，
> 说明不是 TLS 后端问题），所以推送 / 克隆 / 开 PR 都套了 `Invoke-WithRetry`（默认 3 次，间隔 2s）。

---

## 4. 已知陷阱和注意事项

### 4.1 Android 交叉编译（ring / ureq TLS）

**问题**：`ureq` 的 TLS 依赖 `ring`，其 build script 按裸命令名找 C 编译器（`aarch64-linux-android-clang`），而 NDK 只提供带 API 级别的 `aarch64-linux-android21-clang`；且它是以 shell 包装脚本形式存在，**不能**被 symlink 到别的目录（脚本用 `dirname $0` 定位 `clang`）。

**解决（Windows 本机，以 `scripts/md3.ps1 android` 为准）**：通过环境变量显式指定 CC/AR/链接器为 NDK 完整路径。注意：

- **linker 统一用 `clang.exe`** + `RUSTFLAGS` 的 `--target` 带 API 级别，而非把 per-ABI clang 直接当 linker（旧版 AGENTS.md 此处有误）。
- **CC_<target> 的是 `.cmd` 包装脚本**（如 `aarch64-linux-android21-clang.cmd`），不是 clang.exe 本身。
- **交叉编译 3 个 ABI**（不含 `i686-linux-android`；ABI 口径与 x86 陈旧说明见 4.7），mapping 如下：

```powershell
# 以 arm64-v8a 为例，完整逻辑见 scripts/md3.ps1 android 的 $ABIs 定义与第 4 步交叉编译循环。
# NDK 路径由脚本自动探测（ANDROID_NDK_HOME / ANDROID_NDK / 常见 SDK 路径），也可 -NdkPath 手动指定：
$NDK = $env:ANDROID_NDK_HOME   # 例如 <SDK>\ndk\28.2.13676358
$BIN = "$NDK\toolchains\llvm\prebuilt\windows-x86_64\bin"
$env:CC_aarch64_linux_android = "$BIN\aarch64-linux-android21-clang.cmd"  # .cmd 包装
$env:AR_aarch64_linux_android = "$BIN\llvm-ar.exe"
$env:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER = "$BIN\clang.exe"         # 统一 clang.exe
$env:RUSTFLAGS = "-C link-arg=--target=aarch64-linux-android21 -C link-arg=-fuse-ld=lld"
cargo +stable-x86_64-pc-windows-gnu build --target aarch64-linux-android --release
```

- CC/AR 用小写目标名（cc-rs 读取 `CC_<target>`，target 用下划线）；cargo 的 linker 变量**必须大写**（`CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER`），小写会被静默忽略。
- 各 target 对应的 clang 前缀：`aarch64-linux-android21-clang` / `armv7a-linux-androideabi21-clang` / `x86_64-linux-android21-clang`，AR 统一用 `llvm-ar.exe`。
- 验证产物：`file target/{target}/release/libkugou_server.so` 应为 `for Android 21`。
- 导出符号核对：`llvm-nm -D --defined-only libkugou_server.so` 应含 `start_server`/`stop_server`/`is_server_running`/`get_server_port`（Dart `dart:ffi` 实际使用的就是这几个）+ 3 个 JNI 符号。**注意 JNI 符号当前仍是旧包名** `Java_com_md3music_premium_KugouApiService_*`，与 Kotlin 的 `com.md3music.md3music` 不匹配——详见 4.5。

### 4.2 RSA PEM 常量必须能被 rsa crate 解析

**问题**：`PUBLIC_LITE_RAS_KEY`/`PUBLIC_RAS_KEY` 是单行长 base64；`rsa` crate 底层 pem-rfc7468 要求每行 ≤64 字符，直接 `from_public_key_pem` 会 panic（`Pem(Base64(InvalidEncoding))`），导致登录/注册 RSA 路径崩溃。

**解决**：`crypto.rs` 内 `rsa_raw_encrypt`/`rsa_pkcs1v15_encrypt`/`rsa_oaep_sha256_encrypt` 先经 `normalize_pem()` 按 64 字符折行。`tests/smoke.rs::rsa_keys_parse` 为回归测试。新增 RSA 使用点也必须走这几个函数。

**附加坑（SSA simulate 公钥）**：`simulate.rs` 的 `PUBLIC_KEY`（RSA-OAEP，来自 WASM 反作弊）曾把 `MIIBIjANBgkqhkiG9w0…` 误抄成 `…G09w0…`（多了个 `0`），导致 SSA 重试路径一触发就 panic。该常量虽是标准多行 PEM，但内容 corrupted，`normalize_pem` 只能折行、无法修复内容。**拷贝任何 PEM 常量后必须用 `openssl rsa -pubin -in <(echo "$PEM") -text` 或对照 JS 原串逐字符比对**；`tests/smoke.rs::simulate_rsa_key_parses` 为回归测试。

### 4.3 服务器启动时序

**问题**：Flutter UI 渲染后发现页立即请求 API，如果本地服务器还没启动完毕，请求全部失败。

**解决**：`main.dart` 中 `await KugouApiServer.start()` 在 `runApp()` 之前执行；`_waitForReady()` 会轮询实际端口最多 30 秒。冷启动时 MethodChannel 可能尚未注册（3 次重试失败），此时 `dart:ffi` 兜底直接 `start_server(0, dataDir)` 也可启动（`0` 表示随机端口），`server::start` 会检测已在运行并返回当前端口，幂等。

### 4.4 随机端口与端口冲突

**问题**：旧方案固定 8080，退出 App 时如果没有正确关停服务器，下次冷启动端口被占用导致启动失败（`Server::http` 返回 Err → `start_server` 返回 0）。

**解决**：Rust 启动时改用**随机端口**（`server::start(0, dir)` 在 `[10000, 60000]` 内随机，被占用则 sleep 1s 换下一个，最多 10 次），成功返回实际端口，`start_server`/`nativeStartNode` 以端口为返回值（0=失败），Kotlin MethodChannel `startServer` 与 dart:ffi 兜底都会把端口回传给 Dart 写入 `KugouEndpoints.baseUrl`（`KugouApiClient.updateBaseUrl`）。退出流程仍必须 `await KugouApiServer.stop()` + 等待 300ms + `exit(0)`；`MainActivity.onDestroy`/`onTrimMemory` 也会调用 `KugouApiService.stopServer()`（`nativeStopNode`）。`SystemNavigator.pop()` 不够可靠。设置页「在线音乐 → 本地数据接口」点击可确认重启服务器（`KugouApiServer.restart()`，停服→重新随机端口→`KugouEndpoints.baseUrl` 更新，dfid/mid 因 device_info.json 持久化保持不变）。

### 4.5 JNI 签名必须与 Rust 导出一致

**问题**：Rust `lib.rs` 导出的 JNI 函数签名是 `nativeStartNode(jint port, jstring dataDir)`，旧 Kotlin 声明的是 `nativeStartNode(Array<String>, String)`，参数不匹配会崩溃/调用异常。

**解决**：`KugouApiService.kt` 的 `external` 声明必须与 Rust 侧一致（见 lib.rs），改了任一侧都要同步更新另一侧，并重打包验证。

**⚠️ 当前已知不一致（技术债，勿误判为 Bug 而擅自"修复"运行链路）**：

- Rust `lib.rs` 导出的 JNI 符号仍是**旧包名**：`Java_com_md3music_premium_KugouApiService_{nativeStartNode,nativeIsNodeRunning,nativeStopNode}`；而 Kotlin `KugouApiService.kt` 已迁至 `package com.md3music.md3music`（包名统一见 9.1），且 Rust 侧**没有** `RegisterNatives`/`JNI_OnLoad` 动态注册。
- 后果：**静态 JNI 绑定名对不上**，Kotlin 的 `nativeStartNode` / `nativeIsNodeRunning` / `nativeStopNode` 这三个 `external` 方法实际无法解析（调用会 `UnsatisfiedLinkError`）。
- **服务器仍能正常启动的原因**：Dart 侧 `dart:ffi` 兜底直接 `lookup` C 符号 `start_server` / `stop_server` / `is_server_running`（`lib.rs` 中 `#[no_mangle] pub extern "C"`，与包名无关，正确无误）。即 4.3 所述的"兜底"路径当前是**事实上的主路径**。
- 若要恢复 Kotlin MethodChannel 的 native 路径：把 `lib.rs` 三个 `Java_com_md3music_premium_*` 改名为 `Java_com_md3music_md3music_*`，并**重新交叉编译并覆盖 jniLibs**（ABI 口径见 4.7）。改动前先确认 `.so` 与 Kotlin 包名两侧同步。

### 4.6 networkapi 与 kugou_api_server 已分家

**问题**：旧架构中两处 `util/` 各自维护副本，容易失同步。Rust 化后 kugou_api_server 已是 Rust，networkapi 仍是 Node.js。

**解决**：修改 Rust 端工具函数只影响 `rust/src/`；如需同步登录行为，以 Rust 实现为准，networkapi 单点修改即可，不再有跨目录拷贝。

### 4.6.1 登录已全部本地化，networkapi 已退役

- 登录端点（`/login/*`、`/captcha/sent`、`/register/dev` 等）已由 Rust `login.rs`/`misc.rs` **直连酷狗上游**，不再转发到第三方云端 `networkapi/`；`networkapi/` 仅作 JS 参考，云端服务器可下线。
- **为什么不能再转发到云端**：酷狗登录的 QR key / token 绑定**申请它的设备**（dfid/mid）。Rust 本地设备（dfid）≠ 云端设备，本地→云端转发 `/login/qr/check` 必然返回 `20010`→502。
- Rust 各登录端点的上游目标以旧 `networkapi/module/*.js` 为准：`/login/qr/key`→`login-user.kugou.com/v2/qrcode`、`/login/qr/check`→`login-user.kugou.com/v2/get_userinfo_qrcode`、`/login/token`→`login.user.kugou.com/v5/login_by_token`、`/login/cellphone`→`loginserviceretry.kugou.com/v7/login_by_verifycode`、`/captcha/sent`→`login.user.kugou.com/v7/send_mobile_code`。
- Dart 端 `kugou_api_client.dart` 曾把登录路径硬编码到 `http://115.29.236.96:5621`（`_loginPaths`），已移除——全部请求统一走本地 `KugouEndpoints.baseUrl`。

### 4.7 Android 构建配置与 ABI 口径（权威）

- `compileSdk = 36`，`targetSdk = 35`，`ndkVersion = "28.2.13676358"`；`isShrinkResources = true`，Compose 已启用（`buildFeatures.compose`，供 miuix 原生页）
- **CMake/`externalNativeBuild` 仍启用**：`android/app/src/main/cpp/`（`CMakeLists.txt` + `usb-audio-output.cpp/.h`）编译 USB 独占输出 UAC1 驱动（见 4.10），`build.gradle.kts` 的 `externalNativeBuild.cmake` 与 `abiFilters("arm64-v8a","armeabi-v7a","x86_64","x86")` 均在。**Rust 的 JNI/FFI 符号来自 `libkugou_server.so`，与 CMake 编译的 C++ 原生库并存**——二者是两套独立原生库，勿混为一谈。
- **ABI 口径（全文档唯一权威处，其他章节引用此处）**：
  - `jniLibs/` 提交 **4 个 ABI 目录**（arm64-v8a / armeabi-v7a / x86_64 / **x86**）。其中 **x86 那份 `libkugou_server.so` 已陈旧**（本机 `md3.ps1 android` 默认只交叉编译 3 ABI，不含 x86；CI 的 `build_android.sh` 才覆盖 4 ABI）。
  - **发布打包排除 x86**：`flutter build apk --split-per-abi --target-platform android-arm64,android-arm,android-x64`，产物为 arm64-v8a / armeabi-v7a / x86_64 三个 APK（x86_64 供模拟器）。
  - 因此"入库 4 ABI"与"发布 3 ABI"并不矛盾：前者是原生库目录，后者是 APK 分包策略。需要刷新 x86 的 `.so` 时用 `build_android.sh` 或手动交叉编译 `i686-linux-android`。
- Release 构建启用 R8 混淆（`isMinifyEnabled = true`），原生库不参与混淆；修改 JNI 后检查 `proguard-rules.pro`
- 无 `keystore.properties` 时自动使用 debug 签名

### 4.8 Dart 分析规则

- 使用 `package:flutter_lints/flutter.yaml`
- `avoid_print` 默认开启，但项目中大量使用 `print()` 做调试日志（如服务器启动日志），通过 `// ignore: avoid_print` 抑制
- 部分 `discarded_futures` 也通过 ignore 注释处理

### 4.9 `kugou_server` crate 的 release 构建参数

- `crate-type = ["cdylib", "rlib"]`，cdylib 用于导出 FFI/JNI 符号，rlib 用于测试
- `[profile.release]`：`opt-level = "s"`（体积优先）、`lto = true`、`panic = "abort"`（Android 端 panic 即崩溃，务必避免在请求线程 panic——4.2 曾踩坑）

### 4.10 USB 独占输出（UAC1 DAC 直写）

**功能**：设置页「USB 独占输出」开启后，绕过 AudioFlinger/AudioTrack/AAudio/ALSA，直接经 `usbdevfs` ISO URB 把 PCM 写入 UAC1 DAC（思路参考 [decent-player](https://github.com/Ma145/decent-player) 的 bit-perfect USB Audio 驱动）。实现横跨三层：`cpp/usb-audio-output.cpp`（原生 URB 写入）、`kotlin/.../md3music/UsbAudio*.kt`（设备枚举/claim/config 控制）、`third_party/just_audio` fork（`UsbAudioSinkController` 拦截音频流）。

**释放路径（关闭独占后恢复系统声音）的关键实测结论**：

1. **USBDEVFS_CONNECT 内核未实现**：头文件有定义但 devio.c 从未实现该分支 → 永远 ENOTTY(errno=25)。无法靠它恢复被 force-claim 断开的驱动。
2. **USBDEVFS_RESET 不可用**：会让设备从 Android USB host 栈移除（`Removed device` 后无 `Added`），廉价 UAC1 DAC 不重新枚举，只能物理拔插。
3. **唯一可靠恢复路径 = SETCONFIGURATION(0→current)**：先解配置（dev->config=NULL），再重配置 → USB core 为所有接口重新匹配驱动（snd-usb-audio 自动重绑）。设备全程不离开 host 栈，可再次开启独占。
4. **SETCONFIGURATION(0) 会 EBUSY（errno=16）**：若设备存在未 claim 的接口（如 Highscreen 有 ifno 0/1/2/3，只 claim 了 0/1），**必须先对全部 8 个接口 USBDEVFS_DISCONNECT 再 config 切换**，否则驱动 busy。EBUSY 偶发时重试（5 次×500ms）。
5. **读取当前 config**：UsbDeviceConnection 无 getConfiguration()，用标准控制请求 GET_CONFIGURATION（USBDEVFS_CONTROL，bRequestType=0x80, bRequest=0x08, wLength=1）。
6. **disableExclusive 必须后台线程 + 互斥锁**：RESET/config 切换会阻塞；RESET 断开设备瞬间 Android 发 USB_DEVICE_DETACHED 广播会并发再调一次 disable（曾导致重复释放 + RESET FAILED errno=19）。拔插广播路径与 MethodChannel 路径共用 exclusiveLock + isEnabled 守卫。

**其他已修坑**：设备扫描 5s TTL 缓存（UsbManager.getDeviceList 反复枚举廉价 DAC 每秒"滋"声）；enable 时勿 setPreferredDevice 强制路由；reconfigStream 锁内先置 NULL 再释放旧流（防 double-release UAF）；独占时 delegate 静音 + 音量透传，释放顺序：stop→drain→release→closeDevice→onUsbReleased。

**独占时音量控制**：音频绕过 AudioFlinger，系统媒体音量键（STREAM_MUSIC）与播放器 setVolume 都需应用侧自行同步。DAC 音量% = 系统媒体音量% × 播放器音量，系统音量用 500ms 轮询，播放器音量经 `UsbAudioSinkController.setVolumeListener` 回调（setVolume 需同值节流）。硬件音量可用性需先 GET_CUR 逐声道探测（master/左/右，STALL 即不支持），软件音量必须同时覆盖 float `write()` 与整数 PCM 直写 `writeRaw()` 两条路径。

---

## 5. 技术栈速查

| 层 | 技术 | 版本要求 |
|----|------|----------|
| 前端框架 | Flutter | SDK ^3.12.0 |
| 状态管理 | Provider (ChangeNotifier) | ^6.1.2 |
| 音频播放 | just_audio（`third_party/` 本地 fork）+ just_audio_background | fork 0.10.6（path 依赖，注入 USB 独占 AudioSink）/ ^0.0.1-beta.11 |
| 本地存储 | sqflite + shared_preferences | 2.3.3+1 / ^2.5.0 |
| 网络请求 | dio + http | ^5.4.0 / ^1.2.1 |
| 下载/缓存引擎（私有） | `md3_download_cache` 本地包（dio/path_provider/shared_preferences/audio_metadata_reader） | path 依赖，见第 8 节 |
| 主题 | dynamic_color + material_color_utilities | MD3 动态取色 |
| 嵌入式 API 服务器 | Rust（cdylib） + tiny_http + ureq | Rust 2021 / tiny_http 0.12 / ureq 2 |
| 加密 | rsa / aes / md-5 / sha1 / sha2 / base64（CBC + PKCS7 手动实现） | rsa 0.9 / aes 0.8；与 JS CryptoJS 行为对齐 |
| 原生桥接 | dart:ffi（实际主路径）+ JNI | NDK 28；JNI 符号现状见 4.5 |
| 构建工具 | Gradle (Kotlin DSL) + CMake（`cpp/` USB 驱动） | Java 17 / cmake 3.22.1 |
| Windows 桌面（私有版） | `windows/` + just_audio_windows / video_player_win | 公开导出时剥离（见 9.4） |
| 公网服务器 | 已退役（原 networkapi 为 Node.js + Express，登录已改由 Rust 本地直连） | — |

---

## 6. 常用命令

```powershell
# Rust 服务器构建 / 测试（本机无 MSVC，需用 GNU toolchain）
cd kugou_api_server/rust
$env:CC_x86_64_pc_windows_gnu = "C:\Program Files (x86)\Dev-Cpp\MinGW64\bin\gcc.exe"
$env:AR_x86_64_pc_windows_gnu = "C:\Program Files (x86)\Dev-Cpp\MinGW64\bin\ar.exe"
cargo +stable-x86_64-pc-windows-gnu check              # 编译检查
cargo +stable-x86_64-pc-windows-gnu test                # 本地冒烟测试
cargo +stable-x86_64-pc-windows-gnu clippy              # 静态检查
cargo +stable-x86_64-pc-windows-gnu build --release     # 主机 release cdylib

# 交叉编译 + 打包（一键脚本，推荐）
.\scripts\md3.ps1 android                             # 智能检测 + 打包
.\scripts\md3.ps1 android -ForceRust                  # 强制重编 Rust + 打包
.\scripts\md3.ps1 android -SkipFlutter                # 只更新 .so

# 日常开发
flutter run                               # 调试运行
flutter build apk --release --split-per-abi --target-platform android-arm64,android-arm,android-x64  # 发布构建（排除 x86）

# 测试 API（需先启动 App / 本地服务器）
powershell -File scripts\test_api.ps1     # 测试本地 API 接口

# 代码检查
flutter analyze                           # Dart 静态分析

# 公开版本导出（下载/缓存隔离，见第 8 节）
.\scripts\md3.ps1 verify         # 公开树 lib/ 否认清单零命中校验
.\scripts\md3.ps1 export                # 过滤导出公开树（默认 .public_export/）
.\scripts\md3.ps1 export -PublicRemote <URL>   # 导出并推送公开仓库
```

---

## 7. Git 分支与远端约定

> 本仓库采用 **fork → PR 回上游** 的协作模型。当前所在分支 `rust-local-two` 是 **Rust 架构主线**，本文档正文（1~6 节）描述的即此分支。
> AGENTS.md 不在公开导出白名单内（见 8.1），只在私有上游流转，不会外泄到公开仓库。

### 7.1 远端布局

| 远端 | 指向 | 用途 |
|------|------|------|
| `origin` | 贡献者各自的 fork（**因人而异**，勿硬记某个具体地址） | 日常推送、开 PR 的源 |
| `upstream` | `zzyoxml/private_md3music` | **PR 合入目标**（私有单一源）；含 `rust-local-two`、`arch-local-first`、`dac1`、`dac2`、`main` 等分支 |

> ⚠️ **勿与公开镜像混淆**：第 8/9 节涉及的公开仓库是 **`zzyoxml/md3Music`**（导出快照，由 `md3.ps1 export -PublicRemote` 推送）；本节的 `upstream` 是 **`zzyoxml/private_md3music`**（私有源）。两者同属 zzyoxml 但**是不同仓库**，用途不可互换。

- **同步私有上游**：`git fetch upstream` → `cherry-pick` 或 rebase 到 `upstream/rust-local-two`。
- **提 PR**：从 `origin` 的特性分支 → `upstream/rust-local-two`。
- **从公开镜像回捡改动**：属另一条链路，见 9.3 场景 C（`git fetch <公开远端>` → cherry-pick）。
- 远端实际取值以 `git remote -v` 为准；分支存在性以 `git branch -a` 为准，**勿依赖本文档记录的分支快照**。

### 7.2 架构对照（Rust 现行 vs Node.js 历史）

`rust-local-two`（当前主线）与 `arch-local-first`（**已弃用**的旧 Node.js 架构，仅存于 `upstream` 供对照）曾在早期并行演进：

| 维度 | `rust-local-two`（当前主线） | `arch-local-first`（已弃用，仅对照） |
|------|------|------|
| 本地 API 服务器 | Rust（`libkugou_server.so` + tiny_http + ureq） | Node.js（`libnode.so` + Express） |
| Dart 服务类 | `KugouApiServer`（`kugou_server.dart`） | `NodeJsServer`（`nodejs_server.dart`） |
| Kotlin 服务 | `KugouApiService` | `NodeJsService` |
| 服务器构建入口 | `md3.ps1 android`（本机）/ `build_android.sh`（CI），cargo 交叉编译 | `build_nodejs_server.bat`（esbuild，脚本已随该分支弃用一并删除） |
| jniLibs | `libkugou_server.so`（ABI 口径见 4.7） | `libnode.so`（需 `setup_native.bat` 下载解压） |
| CMake / `cpp/` | 仍启用，但**只承载 USB 独占输出驱动**（见 4.7、4.10） | CMake + `cpp/` 作 libnode JNI 桥接 |
| 对应文档 | 本文档正文（1~6 节） | 该分支自带版本的 AGENTS.md（Node.js 说明） |

> **本地只检出 `rust-local-two`**，`arch-local-first` 本地不存在——**勿执行 `git log ... --not arch-local-first`**（无此 ref 会直接报错）。需对照时先 `git fetch upstream arch-local-first`。

### 7.3 Rust 化改造要点（本分支架构由来）

**定位**：Rust 化改造主线（发端于 PR #35，作者 LyonHyrik），用嵌入式 Rust API 服务器替换 Node.js 方案。

**关键提交锚点**：`b86ec67`（引入嵌入式 Rust 服务器替换 Node.js）、`ed96df0`（合并 PR #35）。
此后本分支已叠加数百次提交，**不再逐条列举独有提交**——查最新状态用 `git log`，查与上游差异用 `git log HEAD --not upstream/arch-local-first`（需先 fetch）。

**核心变更内容**：

- 新增 `kugou_api_server/rust/` crate（tiny_http + ureq），编译为 `libkugou_server.so` cdylib，38 个模块注册 170 个酷狗 API 路由端点
- 修复 AES-192/256 CBC 密文错误（cbc crate 输出异常，改为在 `BlockEncrypt`/`BlockDecrypt` 上手动实现 CBC + PKCS7，与 JS CryptoJS 逐字节一致）；新增 smoke 测试中的 AES-CBC 对照回归
- 修复关注/取消关注歌手 userid 读取（`param_or_cookie_num`），Rust 与旧 Node 行为对齐
- Kotlin：`NodeJsService` → `KugouApiService`；Dart：`nodejs_server` → `kugou_server`（MethodChannel `com.md3music.md3music/kugou_api` + dart:ffi 兜底，当前实际主路径见 4.5）
- jniLibs 提交 4 ABI 的 `libkugou_server.so`；原 libnode 的 CMake 桥接已移除（`cpp/` 现仅剩 USB 独占输出驱动，见 4.7）
- 新增一键交叉编译脚本 `scripts/md3.ps1 android`（Windows 本机 PowerShell 版，自动检测改动、探测 NDK、交叉编译 3 ABI 并打包；`kugou_api_server/rust/build_android.sh` 为 Linux/CI 版，覆盖 4 ABI）
- 附带前端改动：`apple_lyrics_view.dart` / `word_renderer.dart` 重构、`full_player.dart` 精简、登录页/收藏页小改

**相关命令**：见本文档 3、6 节；新增 API 模块统一在 `kugou_api_server/rust/src/modules/` 下实现并在 `mod.rs` 的 `register()` 注册（**勿再改 `module/` 下旧 JS 模块**）。

### 7.4 协作注意

- **历史分叉点**：Rust 与 Node.js 两架构早期并行演进，具体 base 以 `git merge-base HEAD upstream/arch-local-first` 实测为准（**勿硬记短哈希**，历史已因多次合流变化）。
- **`upstream` 其他分支**：`main`（旧主线，Node.js，无本文档）、`dac1` / `dac2`（DAC / USB 音频相关）；`feat-*` / `fix-*` 为一次性特性/修复分支。
- **跨架构切换提示**：Rust 分支用 `libkugou_server.so`，Node 分支用 `libnode.so`；跨架构切换时另一套 `.so` 可能以 untracked 文件残留在工作区，按需清理。
- **上游前端分叉**：`arch-local-first` 上的 `apple_lyrics_view.dart` / `word_renderer.dart` 与本分支实现已各自独立重构，若要回捡其歌词性能优化需手动合并。

---

## 8. 下载/缓存功能隔离（私有功能包 + 公开导出）

> 本仓库是**私有单一代码源**。公开版本 ≠ 另一套代码，而是由本仓库**过滤导出的干净树**。
> 目的：向公开仓库同步新功能时，不再手工搬运「下载」「缓存」两块；公开仓库源码中完全不含这两块的任何符号。

### 8.1 架构与文件职责

```
本仓库（私有单一源）
├── packages/md3_download_cache/     # 【私有功能包】下载/缓存引擎，path 依赖，自包含
│   ├── lib/download/                #   DownloadManager + DownloadTask + DownloadsRepository
│   └── lib/cache/                   #   StreamCacheManager + StreamCacheRepository + LyricData(DTO)
├── lib/private/                     # 【私有层】下载/缓存与主工程的接线
│   ├── cache_bridge.dart            #   installCacheHooks()：播放/歌词/封面中性钩子 → 包内引擎
│   ├── enhanced_ui.dart             #   installUiHooks()：下载/缓存 UI 钩子（菜单/长按/设置/筛选/批量下载）
│   ├── downloads_provider.dart      #   下载编排（KugouApiClient/MetadataWriter）
│   ├── downloads_page.dart          #   下载管理页
│   ├── private_settings.dart        #   私有设置读写器（边听边存/下载设置，key 兼容存量）
│   ├── metadata_writer.dart         #   元数据写入客户端（MethodChannel → 原生 JAudioTagger 嵌入标签）
│   └── main_private.dart            #   私有入口：runBootstrap() + 安装钩子 + MyApp(extraProviders)
├── lib/…                            # 公开树：不 import 任何下载/缓存符号，仅保留中性静态钩子（见 2.1）
├── scripts/tasks/export_public.ps1  # 导出公开树：白名单拷贝 → 排除 lib/private/、私有工具链、pubspec.lock
│                                    #   → 剥离 pubspec 私有依赖（md3_download_cache / Windows 依赖）
│                                    #   → README 清理私有功能宣传 → 否认清单闸门 →（可选）推送/开 PR
└── scripts/public_deny.txt          # 否认清单（UTF-8，英文符号 + 中文特征短语），export/verify 共用

公开仓库（由 md3.ps1 export 导出，含 lib/main.dart 入口，无下载/缓存）
```

### 8.2 硬性规则（AI Agent 必读）

1. **公开树零符号**：`lib/`（不含 `lib/private/`）与根 `pubspec.yaml` 不得出现否认清单中的任何符号。**否认清单外置于 `scripts/public_deny.txt`**（UTF-8，含英文符号与中文特征短语，如 `StreamCacheManager`、`getStreamCacheEnabled`、`getDownloadDir`、`md3_download_cache`、`metadata_writer`、`边听边存`、`仅显示已缓存`）。新增私有特征时**必须同步追加到该文件**——否则闸门形同虚设（曾漏掉 settings_repository 的私有设置 API，以及 lib/services/ 下漏放的 metadata_writer.dart，后者已迁入 lib/private/ 并补 deny 符号）。
2. **新增下载/缓存代码的落点**：引擎/持久化 → `packages/md3_download_cache/`（只收 DTO/原始值，不 import 主工程类型）；编排/UI/私有设置读写 → `lib/private/`（含 `PrivateSettings`，可自由 import 主工程类型与包）；公开类需要能力时先加**中性静态钩子**（见 2.1），不要在公开类里直接写私有逻辑。
3. **双入口**：私有构建 `-t lib/private/main_private.dart`（`md3.ps1 android` 默认）；公开构建 `lib/main.dart`。两个入口共用 `runBootstrap()`（`main.dart` 中抽出的启动引导）。
4. **包不反向依赖主工程**：Dart 禁止循环包依赖（主工程 path 依赖包，包不能 extends 主工程类）——这是钩子采用「公开类静态字段 + 私有注入」而非子类化的原因。
5. **导出后自检**：改动涉及下载/缓存后，`scripts/md3.ps1 verify` 必须零命中；`md3.ps1 export` 内置同一闸门，命中即拒绝导出。
6. **包版本**：`packages/md3_download_cache/pubspec.yaml` 按 semver 递增；改动包后主工程锁 `pubspec.lock` 会更新，需一并提交。

### 8.3 已知坑

- **PowerShell 5.1 编码**：`Set-Content` 默认 ANSI 会破坏含中文的 UTF-8 pubspec；脚本统一用 .NET `[System.IO.File]` + `UTF8Encoding($false)` 读写；`public_deny.txt` 用 `[System.IO.File]::ReadAllLines($path, $utf8)` 读取（脚本本体保持纯 ASCII）。
- **安全删除钩子**：本机环境拦截 `Remove-Item`/`rm -rf`（>50 文件需确认）；脚本内删除统一走 `[System.IO.Directory]::Delete` 旁路。
- **正则贪婪**：剥离 pubspec 依赖块时锚定注释行 `^  # private feature package`，勿用裸 `.*md3_download_cache`（会从首个 `# ` 注释行开始误删中间依赖）。
- **deny 词粒度**：勿用裸「缓存/下载」作 deny 词（会误伤公开版合法的封面/歌单/本地音乐缓存功能）；用特征级符号与短语（`边听边存`、`仅显示已缓存`、`settings_download_dir` 等）。
- **预存测试失败**：`test/providers/kugou_provider_test.dart` 的「多账号管理」有 **4 个用例预存失败**（logout×2 / savedAccounts / switchAccount，其余 5 个通过），根因是测试环境 `flutter_secure_storage` 插件不可用（`MissingPluginException: No implementation found for method read/write on channel plugins.it_nomads.com/flutter_secure_storage`），与下载/缓存改动无关。判断自己的改动是否引入回归时，以**这 4 个为已知基线**。

---

## 9. 维护手册功能与触发时机

> 双仓库工作流（私有单一源码 + 公开过滤导出）的**完整操作手册**在 `docs/public_private_workflow.md`（486 行，权威细节）。本节是它的功能速查与触发时机——**遇到下列场景时，先读对应小节再动手**。

### 9.1 当前基线

- **包名统一**：`com.md3music.md3music`（与公开版一致；此前为 `com.md3music.premium`，已全量替换：gradle/manifest/kotlin+java 包声明/Dart MethodChannel）。**例外**：Rust 侧 JNI 符号仍是 `premium` 旧名，见 4.5。
- **公开版功能已全量迁移**（15 项特性：最热评论/文字阴影/默认壁纸/显示大小/私人FM区块/MD3E 组件/edgeToEdge/双击返回/楼中楼算法等），私有下载/缓存能力通过中性钩子保留
- **迁移已合入主干**：原 `migrate-public-features` 分支的成果（`bae2b5f`…`ad8ed49` 等）已全部在 `rust-local-two` 历史中，该分支已不存在，无需再合并

### 9.2 维护手册功能清单

| 功能 | 手册位置 | 一句话说明 |
|------|---------|-----------|
| 架构理解（数据流/代码区域/双入口/钩子） | §1.1~1.4 | 新代码往哪放、公开树↔私有层怎么通信 |
| 三个远端角色（origin / upstream / public） | §1.5 | fork 树下 origin 因人而异；upstream 与公开镜像是两个仓库（对应本文档 7.1） |
| 两条铁律 | §2 | 公开树零私有符号；下载/缓存代码只有两个落点 |
| 场景 A：私有库开发普通功能 | §4.1 | 日常主路径，直接开发→验证→提交 |
| 场景 B：私有库开发下载/缓存功能 | §4.2 | 代码进包/进私有层→加钩子→同步 deny 列表 |
| 场景 C：公开库新功能同步回私有库 | §4.3 | `git fetch zzyoxml` → `cherry-pick` → 验证 |
| 场景 D：发布公开版本 | §4.4 | `md3.ps1 verify` → `md3.ps1 export -PublicRemote` |
| 场景 E：给公开类新增私有能力（钩子全流程） | §4.5 | 加中性静态钩子→私有层注入→deny 追加 |
| 场景 F：导出白名单维护 | §4.6 | 新增顶层文件/目录时判断该不该公开 |

### 9.3 触发时机速查

| 触发场景 | 应做动作 | 查哪里 |
|---------|---------|--------|
| 要开发**普通**新功能 | 直接写 `lib/`（公开树），无需特殊处理 | §4.1 |
| 要开发**下载/缓存/边听边存**相关功能 | 代码进 `packages/md3_download_cache/` 或 `lib/private/`，公开类加中性钩子，**deny 列表同步追加新符号** | §4.2 + §4.5 |
| 公开类需要**调用私有能力**（下载、缓存封面、本地音频） | 给该公开类加**中性静态钩子**（参考 §2.1 钩子表），私有层 `installCacheHooks/installUiHooks` 注入 | §4.5 + 本文档 §2.1 |
| 改动涉及下载/缓存/新增私有符号 | 提交前跑 `scripts/md3.ps1 verify`（必须零命中） | §4.4 步骤 1 |
| 要**发布公开版本** | `md3.ps1 export`（自动：白名单拷贝→排除私有→剥离依赖→README 清理→闸门→可选推送）；导出后抽查导出树 analyze + 构建 | §4.4 |
| **公开仓库**有新功能要带回私有库 | 拉取 → 挑 commit → `cherry-pick` → 冲突时保留私有依赖块 → 验证 | §4.3 |
| 新增**顶层目录/文件**（如 docs/、新脚本） | 判断该不该公开 → 需要则加进导出白名单 `$whitelist`；**导出工具链（tasks/export_public、tasks/verify_public、tasks/commit、public_deny）与 CHANGELOG 永不导出** | §4.6 |
| 新功能涉及 **Windows 桌面** 或 **README 功能宣传** | Windows 依赖需在导出脚本剥离、README 私有功能条目需清理、build-windows.yml 需排除（导出自动处理，但新增时确认覆盖） | §4.6 + 本文档 §8.1 |

### 9.4 导出脚本职责（改脚本前先看这）

`scripts/md3.ps1 export` 一次完成：白名单拷贝（当前 15 项顶层）→ 排除 `lib/private/`、`pubspec.lock`、导出工具链 3 件、`build-windows.yml` → 剥离 pubspec 私有依赖（`md3_download_cache` 块 + `just_audio_windows`/`video_player_win`）→ README 删除「边听边存」条目 → deny 闸门（40 条）→ 可选 force push。**导出树应有且仅有：公开功能 + Android 平台**（无 `windows/`、无 CHANGELOG——公开仓库自行维护）。
