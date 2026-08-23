# AGENTS.md — MD3Music 项目约定

> 本文件供 AI Agent 和开发者快速了解项目结构、模块边界、构建流程与已知陷阱。

> **分支适用说明**：本仓库存在两个并行开发分支，正文 1~6 节与第 8 节（下载/缓存隔离）全部内容仅描述当前分支 `rust-local-two`（Rust 架构）。
> 切换到 `arch-local-first`（Node.js 架构）时，请以其自带版本的 AGENTS.md 为准；两分支内容对比与切换注意事项见[第 7 节](#7-git-分支约定)。

---

## 0. 核心工作准则（必读）

1. **判断功能/Bug 状态必须基于日志，不能只凭截图。**
   真机排查时，以 `adb logcat` 等日志输出为准（关键路径已带 `[RomaToggle]`、`[LyriconDebug]` 等调试标签）。
   截图只能作为补充参考，**不能**作为"功能是否生效 / Bug 是否存在"的判定依据；涉及状态判断时先确认日志证据。

2. **临时调试/测试产物一律放 `tmp/` 目录（已被 .gitignore 忽略，永不提交）。**
   调试截图、临时脚本、测试数据、日志导出文件、验证用的临时 APK 等，禁止散落在项目根或其他目录；
   `tmp/` 之外的临时文件在提交前必须清理或移入 `tmp/`。

---

## 1. 项目架构概览

MD3Music 是一款 Android 音乐播放器，采用 **Flutter 前端 + 嵌入式 Rust API 服务器** 的混合架构：

- **Flutter 前端**（Dart）：负责 UI、播放控制、本地数据管理
- **嵌入式 Rust 服务器**（Rust）：App 启动时通过 `libkugou_server.so`（JNI/MethodChannel，`dart:ffi` 兜底）在进程内启动一个 `tiny_http` HTTP 服务器，监听 `127.0.0.1` 上的**随机端口**（`[10000, 60000]`，被占用则 1s 后换下一个，最多 10 次），实际端口通过 MethodChannel/FFI 返回给 Dart 写入 `KugouEndpoints.baseUrl`。处理所有酷狗音乐 API 请求。Rust 实现取代了旧的 `libnode.so` + `server_bundle.js`（Express）方案，行为与酷狗云端等价。
- **登录接口同样走本地 Rust 服务器**：`/login/*`、`/captcha/sent`、`/register/dev` 等 16 个登录端点由 Rust `login.rs`/`misc.rs` 用本地设备身份（dfid/mid）直连酷狗上游（`login-user.kugou.com` / `loginserviceretry.kugou.com` / `login.user.kugou.com` / `gateway.kugou.com` 等），不再依赖第三方云端（旧 `networkapi/` 已退役，仅作 JS 参考）。

核心设计理念：所有音乐搜索、歌词、排行榜、登录等 API 请求都走本地 Rust 服务器转发，避免直接暴露 API 密钥在客户端。

---

## 2. 模块边界

```
md3Music/
├── lib/                          # Dart 前端（Flutter）
│   ├── main.dart                 # 公开入口：runBootstrap() → runApp（下载/缓存无关）
│   ├── app.dart                  # MaterialApp 配置、主题、导航、Tab 布局（MyApp.extraProviders 扩展点）
│   ├── core/                     # 核心层：主题、布局、服务（桌面歌词、均衡器、Lyricon）
│   ├── data/                     # 数据层：模型、仓库（settings_repository 等）
│   ├── modules/                  # 功能模块：discover、player、search、library、login...
│   ├── providers/                # 状态管理：PlayerProvider、KugouProvider、ThemeProvider...
│   ├── services/                 # 服务层：kugou_server.dart（MethodChannel + dart:ffi 启动服务器）
│   ├── widgets/                  # 共享 UI 组件（歌词、播放器控件等）
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
│   │   │   ├── modules/          # 按端点分组的 160+ 个 API 模块（search.rs、audio.rs、lyric.rs、
│   │   │   │                     #   playlist.rs、user.rs、youth.rs、song_url.rs...）
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
│   ├── app/src/main/jniLibs/     # libkugou_server.so（arm64-v8a、armeabi-v7a、x86_64、x86）
│   ├── app/src/main/kotlin/      # Kotlin 原生代码（MediaSession、KugouApiService、桌面歌词等）
│   └── app/src/main/cpp/         # USB 独占输出（usb-audio-output.cpp，UAC1 DAC 直写 usbdevfs ISO URB）
│
├── assets/
│   ├── fonts/                    # 内置字体（simhei.ttf）
│   └── images/                   # 应用图标
│
└── scripts/                      # 构建脚本
    ├── build_android.ps1         # Rust 交叉编译 + Flutter 打包（默认私有入口）
    ├── export_public.ps1         # 导出公开版本（过滤 + 否认清单闸门）
    ├── verify_public_clean.ps1   # 公开树洁净度校验（lib/ 否认清单零命中）
    └── test_api.ps1              # API 测试脚本
```

### 关键边界规则

| 边界 | 说明 |
|------|------|
| `lib/` ↔ `kugou_api_server/rust/` | Dart 前端通过 HTTP `127.0.0.1:<随机端口>` 调用 API（端口由 `startServer`/`start_server` 返回，写入 `KugouEndpoints.baseUrl`）；启动/停止走 `KugouApiService` 的 MethodChannel（`com.md3music.md3music/kugou_api`：startServer/isRunning/stopServer），`dart:ffi` 直连 `start_server` 作为兜底 |
| `kugou_api_server/rust/` ↔ `networkapi/` | 两者代码完全独立，不再共享 util；networkapi 已退役（登录已改由 Rust 直连酷狗），仅作 JS 参考 |
| `kugou_api_server/module/` 等 JS 文件 | 旧 Node 方案遗留，已被 Rust 取代，**不要**再修改 JS 版模块或重新打包 |
| `android/app/src/main/jniLibs/` | 原生库目录，`libkugou_server.so` **已提交进 Git**（从 `rust/target/*/release/` 复制），无需下载 |
| `android/app/src/main/cpp/` + `kotlin/.../md3music/UsbAudio*.kt` + `third_party/just_audio` | **USB 独占输出**：绕过 AudioFlinger，经 usbdevfs ISO URB 直写 UAC1 DAC（参考 [decent-player](https://github.com/Ma145/decent-player) 的 bit-perfect 驱动思路）；释放恢复见 4.10 |
| `assets/nodejs-project/` | 已从 `pubspec.yaml` 移除，不再打包；旧 `server_bundle.js` 仅作参考 |
| `lib/`（公开树） ↔ `packages/md3_download_cache/` + `lib/private/`（私有内容） | **下载/缓存隔离**：公开树 `lib/`（不含 `lib/private/`）**零下载/缓存符号**；引擎与私有层只在私有构建存在。公开类通过**中性静态钩子**扩展（见 2.1）；公开版本由 `scripts/export_public.ps1` 过滤导出（排除 `packages/`、`lib/private/`、`pubspec.lock`，剥离私有依赖，否认清单闸门），详见[第 8 节](#8-下载缓存功能隔离私有功能包--公开导出) |
| `lib/main.dart` ↔ `lib/private/main_private.dart` | 双入口：公开入口 `lib/main.dart`（干净树）；私有入口 `-t lib/private/main_private.dart`（装配下载/缓存）。`build_android.ps1` 默认构建私有入口 |

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

> **Windows 本机（推荐）**：本机未装 MSVC（缺 `link.exe`），用 GNU toolchain + MinGW 作为 host 编译器。一键脚本 `scripts/build_android.ps1` 已封装全部流程。

```
步骤 1: 构建 Rust 服务器 cdylib（修改 rust/src 后必须执行）
   └── 一键脚本（推荐，Windows 本机用 PowerShell 脚本）：
           .\scripts\build_android.ps1
           # 参数：-ForceRust 强制重编；-SkipFlutter 只更新 .so 不打 APK；-NdkPath 手动指定 NDK
       脚本会自动：
           1. 检测 Rust 代码是否有改动（git status + .so 时间戳比对）
           2. 有改动 → 交叉编译 3 个 ABI（arm64-v8a / armeabi-v7a / x86_64，不含 x86）
           3. 覆盖 android/app/src/main/jniLibs/
           4. 无改动 → 跳过 Rust 编译，直接打包

步骤 2: Flutter 构建（由脚本自动执行，或手动）
   └── scripts/build_android.ps1 默认构建【私有入口】（含下载/缓存）：
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

### 3.4 CI 流程（`.github/workflows/ci.yml`）

- 触发条件：push 到 main/master，或手动 workflow_dispatch
- 环境：Ubuntu + Java 17 + Flutter stable + Android SDK 36 + NDK 28
- 注意：CI 中旧 Node 流程（下载 libnode、esbuild 打包）已冗余但不会失败；`libkugou_server.so` 已入库，Flutter 构建直接可用
- 产物：三个 ABI 的 APK（arm64-v8a、armeabi-v7a、x86_64），自动创建 GitHub Release

### 3.5 公开版本导出（一条命令，见第 8 节）

```powershell
.\scripts\verify_public_clean.ps1                          # 校验公开树 lib/ 否认清单零命中
.\scripts\export_public.ps1                                 # 导出到 .public_export/（过滤 + 闸门）
.\scripts\export_public.ps1 -PublicRemote <公开仓库URL>      # 导出并推送到公开仓库（-f 覆盖）
# 公开树独立构建：cd .public_export && flutter pub get && flutter build apk --debug（入口 lib/main.dart）
```

---

## 4. 已知陷阱和注意事项

### 4.1 Android 交叉编译（ring / ureq TLS）

**问题**：`ureq` 的 TLS 依赖 `ring`，其 build script 按裸命令名找 C 编译器（`aarch64-linux-android-clang`），而 NDK 只提供带 API 级别的 `aarch64-linux-android21-clang`；且它是以 shell 包装脚本形式存在，**不能**被 symlink 到别的目录（脚本用 `dirname $0` 定位 `clang`）。

**解决（Windows 本机，以 `scripts/build_android.ps1` 为准）**：通过环境变量显式指定 CC/AR/链接器为 NDK 完整路径。注意：

- **linker 统一用 `clang.exe`** + `RUSTFLAGS` 的 `--target` 带 API 级别，而非把 per-ABI clang 直接当 linker（旧版 AGENTS.md 此处有误）。
- **CC_<target> 的是 `.cmd` 包装脚本**（如 `aarch64-linux-android21-clang.cmd`），不是 clang.exe 本身。
- **交叉编译 3 个 ABI**（不含 `i686-linux-android`），mapping 如下：

```powershell
# 以 arm64-v8a 为例，完整逻辑见 scripts/build_android.ps1 L141-148：
$NDK = "C:\Users\32732\AppData\Local\Android\Sdk\ndk\28.2.13676358"
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
- 导出符号核对：`llvm-nm -D --defined-only libkugou_server.so` 应含 `start_server`/`stop_server`/`is_server_running`/`get_server_port` + 3 个 `Java_com_md3music_md3music_KugouApiService_*`。

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

### 4.6 networkapi 与 kugou_api_server 已分家

**问题**：旧架构中两处 `util/` 各自维护副本，容易失同步。Rust 化后 kugou_api_server 已是 Rust，networkapi 仍是 Node.js。

**解决**：修改 Rust 端工具函数只影响 `rust/src/`；如需同步登录行为，以 Rust 实现为准，networkapi 单点修改即可，不再有跨目录拷贝。

### 4.6.1 登录已全部本地化，networkapi 已退役

- 登录端点（`/login/*`、`/captcha/sent`、`/register/dev` 等）已由 Rust `login.rs`/`misc.rs` **直连酷狗上游**，不再转发到第三方云端 `networkapi/`；`networkapi/` 仅作 JS 参考，云端服务器可下线。
- **为什么不能再转发到云端**：酷狗登录的 QR key / token 绑定**申请它的设备**（dfid/mid）。Rust 本地设备（dfid）≠ 云端设备，本地→云端转发 `/login/qr/check` 必然返回 `20010`→502。
- Rust 各登录端点的上游目标以旧 `networkapi/module/*.js` 为准：`/login/qr/key`→`login-user.kugou.com/v2/qrcode`、`/login/qr/check`→`login-user.kugou.com/v2/get_userinfo_qrcode`、`/login/token`→`login.user.kugou.com/v5/login_by_token`、`/login/cellphone`→`loginserviceretry.kugou.com/v7/login_by_verifycode`、`/captcha/sent`→`login.user.kugou.com/v7/send_mobile_code`。
- Dart 端 `kugou_api_client.dart` 曾把登录路径硬编码到 `http://115.29.236.96:5621`（`_loginPaths`），已移除——全部请求统一走本地 `KugouEndpoints.baseUrl`。

### 4.7 Android 构建配置

- `compileSdk = 36`，`targetSdk = 35`，`ndkVersion = "28.2.13676358"`
- 已移除 CMake/`externalNativeBuild`（`cpp/` 目录删除）；JNI 符号直接来自 `libkugou_server.so`
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
| 音频播放 | just_audio + just_audio_background | ^0.9.34 |
| 本地存储 | sqflite + shared_preferences | 2.3.3+1 / ^2.5.0 |
| 网络请求 | dio + http | ^5.4.0 / ^1.2.1 |
| 下载/缓存引擎（私有） | `md3_download_cache` 本地包（dio/path_provider/shared_preferences/audio_metadata_reader） | path 依赖，见第 8 节 |
| 主题 | dynamic_color + material_color_utilities | MD3 动态取色 |
| 嵌入式 API 服务器 | Rust（cdylib） + tiny_http + ureq | Rust 2021 / tiny_http 0.12 / ureq 2 |
| 加密 | rsa / aes / md-5 / sha1 / sha2 / base64（CBC + PKCS7 手动实现） | 与 JS CryptoJS 行为对齐 |
| 原生桥接 | JNI + dart:ffi | NDK 28 |
| 构建工具 | Gradle (Kotlin DSL) | Java 17 |
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
.\scripts\build_android.ps1                             # 智能检测 + 打包
.\scripts\build_android.ps1 -ForceRust                  # 强制重编 Rust + 打包
.\scripts\build_android.ps1 -SkipFlutter                # 只更新 .so

# 日常开发
flutter run                               # 调试运行
flutter build apk --release --split-per-abi --target-platform android-arm64,android-arm,android-x64  # 发布构建（排除 x86）

# 测试 API（需先启动 App / 本地服务器）
powershell -File scripts\test_api.ps1     # 测试本地 API 接口

# 代码检查
flutter analyze                           # Dart 静态分析

# 公开版本导出（下载/缓存隔离，见第 8 节）
.\scripts\verify_public_clean.ps1         # 公开树 lib/ 否认清单零命中校验
.\scripts\export_public.ps1                # 过滤导出公开树（默认 .public_export/）
.\scripts\export_public.ps1 -PublicRemote <URL>   # 导出并推送公开仓库
```

---

## 7. Git 分支约定

> 本仓库的 `arch-local-first` 与 `rust-local-two` 是基于 `c7ec59b` 并行分叉的两个开发分支，各自独立演进（见 7.3）。
> **切换分支时注意**：不同分支的 AGENTS.md 内容不同（`arch-local-first` 上描述的是 Node.js 架构，`rust-local-two` 上是 Rust 架构），请以当前分支的文件为准。

**两分支快速对照**：

| 维度 | `rust-local-two`（当前） | `arch-local-first` |
|------|------|------|
| 本地 API 服务器 | Rust（`libkugou_server.so` + tiny_http + ureq） | Node.js（`libnode.so` + Express） |
| Dart 服务类 | `KugouApiServer`（`kugou_server.dart`） | `NodeJsServer`（`nodejs_server.dart`） |
| Kotlin 服务 | `KugouApiService` | `NodeJsService` |
| 服务器构建入口 | `build_android.sh`（cargo 交叉编译） | `build_nodejs_server.bat`（esbuild） |
| jniLibs | `libkugou_server.so`（4 ABI，已提交进 Git） | `libnode.so`（需 `setup_native.bat` 下载解压） |
| 原生层 | 无 CMake（JNI 符号来自 .so） | CMake + `cpp/` 桥接目录 |
| 前端独有变更 | apple_lyrics 重构（渲染实现改动） | apple_lyrics 性能优化、搜索结果去重等 |
| 对应文档 | 本文档正文（1~6 节） | 该分支自带版本的 AGENTS.md |

### 7.1 `rust-local-two`（Rust 化改造分支，当前所在分支）

**定位**：Rust 化改造主线（PR #35，作者 LyonHyrik）。用嵌入式 Rust API 服务器替换 Node.js 方案，本文档 1~6 节描述的即为该分支架构。

**独有提交**（`git log rust-local-two --not arch-local-first`）：

| 提交 | 说明 |
|------|------|
| `b86ec67` | feat: 用嵌入式 Rust API 服务器替换 Node.js 方案（核心变更，见下） |
| `ed96df0` | Merge pull request #35 from LyonHyrik/rust-local-two |

**核心变更内容**：

- 新增 `kugou_api_server/rust/` crate（tiny_http + ureq），编译为 `libkugou_server.so` cdylib，覆盖 160+ 酷狗 API 端点
- 修复 AES-192/256 CBC 密文错误（cbc crate 输出异常，改为在 `BlockEncrypt`/`BlockDecrypt` 上手动实现 CBC + PKCS7，与 JS CryptoJS 逐字节一致）；新增 smoke 测试中的 AES-CBC 对照回归
- 修复关注/取消关注歌手 userid 读取（`param_or_cookie_num`），Rust 与旧 Node 行为对齐
- Kotlin：`NodeJsService` → `KugouApiService`；Dart：`nodejs_server` → `kugou_server`（MethodChannel `com.md3music.md3music/kugou_api` + dart:ffi 兜底）
- jniLibs 提交 4 ABI（arm64-v8a、armeabi-v7a、x86、x86_64）的 `libkugou_server.so`；移除 `cpp/` CMake 原生构建
- 新增一键交叉编译脚本 `scripts/build_android.ps1`（Windows 本机 PowerShell 版，自动检测改动、定位 NDK、交叉编译 3 ABI 并打包；`kugou_api_server/rust/build_android.sh` 为 Linux/CI 版）
- 附带前端改动：`apple_lyrics_view.dart` / `word_renderer.dart` 重构、`full_player.dart` 精简、登录页/收藏页小改

**相关命令**：见本文档 3、6 节；新增 API 模块统一在 `kugou_api_server/rust/src/modules/` 下实现（勿再改 `module/` 下旧 JS 模块）。

### 7.2 `arch-local-first`（Node.js 架构 + 前端优化分支）

**定位**：并行开发分支。保持 Node.js 旧架构（`libnode.so` + Express `server_bundle.js`）不变，叠加来自 zzyoxml 的前端功能与性能优化。该分支上的 AGENTS.md 是 Node.js 方案说明（构建需 `build_nodejs_server.bat`）。

**独有提交**（`git log arch-local-first --not rust-local-two`）：

| 提交 | 说明 |
|------|------|
| `384e80b` | perf(apple_lyrics): 优化上浮动画功耗与平滑度 |
| `1fa6010` | perf(apple_lyrics): 字内渐变改为行级 maskX 模型，扩大渐变范围 |
| `cb3ff95` | perf(apple_lyrics): 修复真正的卡顿瓶颈 |
| `f82f589` | revert(lyrics): 还原被禁用的文字上浮动画 |
| `1492588` | perf(lyrics): 复用辉光层 Paint 对象，消除每帧分配 |
| `fd100db` | fix(ui): 搜索结果去重 + 进度条拖动自动暂停 |
| `59aa692` | Merge branch 'zzyoxml:arch-local-first' into arch-local-first |

**核心变更内容**：

- **apple_lyrics 性能优化**：修复歌词卡顿瓶颈、字内渐变改为行级 `maskX` 模型、上浮动画功耗与平滑度优化、辉光层 `Paint` 对象复用消除每帧分配、还原被禁用的文字上浮动画
- **UI 修复**：搜索结果去重、进度条拖动自动暂停

**注意**：该分支的 `apple_lyrics_view.dart` / `word_renderer.dart` 与 7.1 分支的实现已分叉（各自独立重构），后续合流需手动合并。

### 7.3 分支关系与切换

- **remote**：`origin = https://github.com/Little-White3110/md3Music`
- **分叉点**：两分支基于 `c7ec59b` 并行分叉，后端架构（Rust vs Node.js）与前端功能各自演进；后续合流需手动处理 AGENTS.md、构建脚本、jniLibs 及歌词渲染代码的差异
- **切换分支的坑**：两分支 jniLibs 下的 `.so` 不同（`libkugou_server.so` vs `libnode.so`）；切回旧架构分支时，残留的 `libnode.so` 会以 untracked 文件形式留在工作区，可手动删除
- **其他分支**：`main`（旧主线，无 AGENTS.md，Node.js）；`feat-*` / `fix-*`（一次性功能/修复分支）；`pr/update-md3music-content`（内容更新 PR 分支）

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
├── scripts/export_public.ps1        # 导出公开树：白名单拷贝 → 排除 lib/private/、导出工具链、pubspec.lock
│                                    #   → 剥离 pubspec 私有依赖（md3_download_cache / Windows 依赖）
│                                    #   → README 清理私有功能宣传 → 否认清单闸门 →（可选）推送
└── scripts/public_deny.txt          # 否认清单（UTF-8，英文符号 + 中文特征短语），export/verify 共用

公开仓库（由 export_public.ps1 导出，含 lib/main.dart 入口，无下载/缓存）
```

### 8.2 硬性规则（AI Agent 必读）

1. **公开树零符号**：`lib/`（不含 `lib/private/`）与根 `pubspec.yaml` 不得出现否认清单中的任何符号。**否认清单外置于 `scripts/public_deny.txt`**（UTF-8，含英文符号与中文特征短语，如 `StreamCacheManager`、`getStreamCacheEnabled`、`getDownloadDir`、`md3_download_cache`、`metadata_writer`、`边听边存`、`仅显示已缓存`）。新增私有特征时**必须同步追加到该文件**——否则闸门形同虚设（曾漏掉 settings_repository 的私有设置 API，以及 lib/services/ 下漏放的 metadata_writer.dart，后者已迁入 lib/private/ 并补 deny 符号）。
2. **新增下载/缓存代码的落点**：引擎/持久化 → `packages/md3_download_cache/`（只收 DTO/原始值，不 import 主工程类型）；编排/UI/私有设置读写 → `lib/private/`（含 `PrivateSettings`，可自由 import 主工程类型与包）；公开类需要能力时先加**中性静态钩子**（见 2.1），不要在公开类里直接写私有逻辑。
3. **双入口**：私有构建 `-t lib/private/main_private.dart`（`build_android.ps1` 默认）；公开构建 `lib/main.dart`。两个入口共用 `runBootstrap()`（`main.dart` 中抽出的启动引导）。
4. **包不反向依赖主工程**：Dart 禁止循环包依赖（主工程 path 依赖包，包不能 extends 主工程类）——这是钩子采用「公开类静态字段 + 私有注入」而非子类化的原因。
5. **导出后自检**：改动涉及下载/缓存后，`scripts/verify_public_clean.ps1` 必须零命中；`export_public.ps1` 内置同一闸门，命中即拒绝导出。
6. **包版本**：`packages/md3_download_cache/pubspec.yaml` 按 semver 递增；改动包后主工程锁 `pubspec.lock` 会更新，需一并提交。

### 8.3 已知坑

- **PowerShell 5.1 编码**：`Set-Content` 默认 ANSI 会破坏含中文的 UTF-8 pubspec；脚本统一用 .NET `[System.IO.File]` + `UTF8Encoding($false)` 读写；`public_deny.txt` 用 `[System.IO.File]::ReadAllLines($path, $utf8)` 读取（脚本本体保持纯 ASCII）。
- **安全删除钩子**：本机环境拦截 `Remove-Item`/`rm -rf`（>50 文件需确认）；脚本内删除统一走 `[System.IO.Directory]::Delete` 旁路。
- **正则贪婪**：剥离 pubspec 依赖块时锚定注释行 `^  # private feature package`，勿用裸 `.*md3_download_cache`（会从首个 `# ` 注释行开始误删中间依赖）。
- **deny 词粒度**：勿用裸「缓存/下载」作 deny 词（会误伤公开版合法的封面/歌单/本地音乐缓存功能）；用特征级符号与短语（`边听边存`、`仅显示已缓存`、`settings_download_dir` 等）。
- **预存测试失败**：`flutter test` 有 19 个 `kugou_provider_test.dart` 多账号测试失败，根因是测试环境 shared_preferences 插件不可用（MissingPluginException），与下载/缓存改动无关。

---

## 9. 维护手册功能与触发时机

> 双仓库工作流（私有单一源码 + 公开过滤导出）的**完整操作手册**在 `docs/public_private_workflow.md`（470 行，权威细节）。本节是它的功能速查与触发时机——**遇到下列场景时，先读对应小节再动手**。

### 9.1 当前基线（2026-08 迁移后）

- **包名统一**：`com.md3music.md3music`（与公开版一致；此前为 `com.md3music.premium`，已全量替换：gradle/manifest/kotlin+java 包声明/Dart MethodChannel）
- **公开版功能已全量迁移**（15 项特性：最热评论/文字阴影/默认壁纸/显示大小/私人FM区块/MD3E 组件/edgeToEdge/双击返回/楼中楼算法等），私有下载/缓存能力通过中性钩子保留
- **分支**：`migrate-public-features`（基于 `rust-local-two`，迁移成果，待合并回主干）

### 9.2 维护手册功能清单

| 功能 | 手册位置 | 一句话说明 |
|------|---------|-----------|
| 架构理解（数据流/代码区域/双入口/钩子） | §1.1~1.5 | 新代码往哪放、公开树↔私有层怎么通信 |
| 两条铁律 | §2 | 公开树零私有符号；下载/缓存代码只有两个落点 |
| 场景 A：私有库开发普通功能 | §4.1 | 日常主路径，直接开发→验证→提交 |
| 场景 B：私有库开发下载/缓存功能 | §4.2 | 代码进包/进私有层→加钩子→同步 deny 列表 |
| 场景 C：公开库新功能同步回私有库 | §4.3 | `git fetch zzyoxml` → `cherry-pick` → 验证 |
| 场景 D：发布公开版本 | §4.4 | `verify_public_clean` → `export_public.ps1 -PublicRemote` |
| 场景 E：给公开类新增私有能力（钩子全流程） | §4.5 | 加中性静态钩子→私有层注入→deny 追加 |
| 场景 F：导出白名单维护 | §4.6 | 新增顶层文件/目录时判断该不该公开 |

### 9.3 触发时机速查

| 触发场景 | 应做动作 | 查哪里 |
|---------|---------|--------|
| 要开发**普通**新功能 | 直接写 `lib/`（公开树），无需特殊处理 | §4.1 |
| 要开发**下载/缓存/边听边存**相关功能 | 代码进 `packages/md3_download_cache/` 或 `lib/private/`，公开类加中性钩子，**deny 列表同步追加新符号** | §4.2 + §4.5 |
| 公开类需要**调用私有能力**（下载、缓存封面、本地音频） | 给该公开类加**中性静态钩子**（参考 §2.1 钩子表），私有层 `installCacheHooks/installUiHooks` 注入 | §4.5 + 本文档 §2.1 |
| 改动涉及下载/缓存/新增私有符号 | 提交前跑 `scripts/verify_public_clean.ps1`（必须零命中） | §4.4 步骤 1 |
| 要**发布公开版本** | `export_public.ps1`（自动：白名单拷贝→排除私有→剥离依赖→README 清理→闸门→可选推送）；导出后抽查导出树 analyze + 构建 | §4.4 |
| **公开仓库**有新功能要带回私有库 | 拉取 → 挑 commit → `cherry-pick` → 冲突时保留私有依赖块 → 验证 | §4.3 |
| 新增**顶层目录/文件**（如 docs/、新脚本） | 判断该不该公开 → 需要则加进导出白名单 `$whitelist`；**导出工具链（export_public/verify_public_clean/public_deny）与 CHANGELOG 永不导出** | §4.6 |
| 新功能涉及 **Windows 桌面** 或 **README 功能宣传** | Windows 依赖需在导出脚本剥离、README 私有功能条目需清理、build-windows.yml 需排除（导出自动处理，但新增时确认覆盖） | §4.6 + 本文档 §8.1 |

### 9.4 导出脚本职责（改脚本前先看这）

`scripts/export_public.ps1` 一次完成：白名单拷贝（当前 15 项顶层）→ 排除 `lib/private/`、`pubspec.lock`、导出工具链 3 件、`build-windows.yml` → 剥离 pubspec 私有依赖（`md3_download_cache` 块 + `just_audio_windows`/`video_player_win`）→ README 删除「边听边存」条目 → deny 闸门（40 条）→ 可选 force push。**导出树应有且仅有：公开功能 + Android 平台**（无 `windows/`、无 CHANGELOG——公开仓库自行维护）。
