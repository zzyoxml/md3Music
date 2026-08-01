# AGENTS.md — MD3Music 项目约定

> 本文件供 AI Agent 和开发者快速了解项目结构、模块边界、构建流程与已知陷阱。

---

## 1. 项目架构概览

MD3Music 是一款 Android 音乐播放器，采用 **Flutter 前端 + 嵌入式 Node.js API 服务器** 的混合架构：

- **Flutter 前端**（Dart）：负责 UI、播放控制、本地数据管理
- **嵌入式 Node.js 服务器**（JavaScript）：App 启动时通过 `libnode.so`（FFI/MethodChannel）在进程内启动一个 Express HTTP 服务器，监听 `127.0.0.1:8080`，处理所有酷狗音乐 API 请求
- **公网 API 服务器**（可选）：仅处理登录相关接口，部署在云端，流量 <1MB/月

核心设计理念：所有音乐搜索、歌词、排行榜等 API 请求都走本地 Node.js 服务器转发，避免直接暴露 API 密钥在客户端。

---

## 2. 模块边界

```
md3Music/
├── lib/                          # Dart 前端（Flutter）
│   ├── main.dart                 # 入口：权限请求 → 启动 Node.js → runApp
│   ├── app.dart                  # MaterialApp 配置、主题、导航、Tab 布局
│   ├── core/                     # 核心层：主题、布局、服务（桌面歌词、均衡器、Lyricon）
│   ├── data/                     # 数据层：模型、仓库（settings_repository 等）
│   ├── modules/                  # 功能模块：discover、player、search、library、login...
│   ├── providers/                # 状态管理：PlayerProvider、KugouProvider、ThemeProvider...
│   ├── services/                 # 服务层：nodejs_server.dart（FFI 启动 Node.js）
│   └── widgets/                  # 共享 UI 组件（歌词、播放器控件等）
│
├── kugou_api_server/             # 本地 API 服务器（嵌入式，打包进 APK）
│   ├── server.js                 # Express 服务器核心，路由注册，CORS，Cookie 处理
│   ├── module/                   # 200+ 个 API 模块（search.js、audio.js、lyric.js...）
│   │                             #   路由规则：文件名下划线转斜杠，如 search_suggest.js → /search/suggest
│   ├── util/                     # 工具函数（crypto、request、apicache）
│   ├── bundled_entry.js          # 自动生成：静态 require 所有模块，供 esbuild 打包
│   └── server_bundle.js          # esbuild 输出产物，复制到 assets/nodejs-project/
│
├── networkapi/                   # 公网 API 服务器（云端部署，仅登录接口）
│   ├── server.js                 # 精简版 Express，只加载登录相关模块
│   ├── module/                   # 登录、注册、验证码等模块
│   └── util/                     # 与 kugou_api_server 共享的工具函数
│
├── android/                      # Android 原生层
│   ├── app/src/main/cpp/         # CMake + JNI 桥接（启动 libnode.so）
│   ├── app/src/main/jniLibs/     # libnode.so（arm64-v8a、armeabi-v7a、x86_64）
│   └── app/src/main/kotlin/      # Kotlin 原生代码（MediaSession、桌面歌词等）
│
├── assets/
│   ├── nodejs-project/           # server_bundle.js 存放处，Flutter 打包进 APK
│   ├── fonts/                    # 内置字体（simhei.ttf）
│   └── images/                   # 应用图标
│
└── scripts/                      # 构建脚本
    ├── build_nodejs_server.bat   # 一键构建 Node.js bundle
    ├── gen_node_bundle_entry.js  # 生成 bundled_entry.js
    ├── extract_nodejs.ps1        # 从 zip 提取 libnode.so
    └── test_api.ps1              # API 测试脚本
```

### 关键边界规则

| 边界 | 说明 |
|------|------|
| `lib/` ↔ `kugou_api_server/` | Dart 前端通过 HTTP `127.0.0.1:8080` 调用 API，不直接 require JS 模块 |
| `kugou_api_server/` ↔ `networkapi/` | 代码独立，共享 `util/` 结构；networkapi 只包含登录相关模块 |
| `assets/nodejs-project/` | 构建产物目录，**不要手动编辑** `server_bundle.js`，它由 esbuild 生成 |
| `android/app/src/main/jniLibs/` | 原生库目录，`libnode.so` 由 `setup_native.bat` 从 GitHub Releases 下载解压 |

---

## 3. 构建流程

### 3.1 完整构建顺序（CI / 手动发布）

```
步骤 1: 解压 native-libs（libnode.so + Node.js headers）
   └── setup_native.bat 或 CI 中 unzip native-libs.zip
       → android/app/src/main/jniLibs/{arm64-v8a,armeabi-v7a,x86_64}/libnode.so
       → android/app/src/main/cpp/include/node/*.h

步骤 2: 构建 Node.js 服务器 bundle
   └── scripts/build_nodejs_server.bat 依次执行：
       2a. node scripts/gen_node_bundle_entry.js
           → 生成 kugou_api_server/bundled_entry.js（静态 require 所有 module/*.js）
       2b. cd kugou_api_server && npx esbuild bundled_entry.js --bundle --minify
           → 输出 kugou_api_server/server_bundle.js
       2c. 复制 server_bundle.js → assets/nodejs-project/server_bundle.js

步骤 3: Flutter 构建
   └── flutter build apk --release --split-per-abi
       → build/app/outputs/flutter-apk/app-{abi}-release.apk
```

### 3.2 开发时快速迭代

```bash
# 只修改了 kugou_api_server/module/ 下的 JS 代码时：
scripts\build_nodejs_server.bat

# 然后重新安装到设备：
flutter run
# 或单独构建 APK：
flutter build apk --debug
```

### 3.3 CI 流程（`.github/workflows/ci.yml`）

- 触发条件：push 到 main/master，或手动 workflow_dispatch
- 环境：Ubuntu + Java 17 + Flutter stable + Node.js 18 + Android SDK 36 + NDK 28
- 产物：三个 ABI 的 APK（arm64-v8a、armeabi-v7a、x86_64），自动创建 GitHub Release

---

## 4. 已知陷阱和注意事项

### 4.1 esbuild 打包陷阱

**问题**：`server.js` 使用动态 `require('./module/' + name + '.js')` 加载模块，esbuild 无法静态分析，打出的包不含模块实现，所有 API 返回 404。

**解决**：必须先运行 `scripts/gen_node_bundle_entry.js` 生成 `bundled_entry.js`，里面是静态字面量 `require`，esbuild 才能内联所有模块。

**规则**：修改 `module/` 目录后，必须重新运行 `build_nodejs_server.bat`，否则 APK 内的 bundle 是旧的。

### 4.2 native-libs 缺失

**问题**：`libnode.so` 不在 Git 仓库中（太大），新 clone 后构建会因缺少 JNI 库而失败。

**解决**：首次构建前运行 `setup_native.bat`，从 GitHub Releases 下载 `native-libs.zip` 并解压。

### 4.3 Node.js 服务器启动时序

**问题**：Flutter UI 渲染后发现页立即请求 API，如果 Node.js 还没启动完毕，请求全部失败。

**解决**：`main.dart` 中 `await NodeJsServer.start()` 在 `runApp()` 之前执行；`_waitForReady()` 会轮询 `127.0.0.1:8080` 最多 30 秒。

### 4.4 端口 8080 冲突

**问题**：退出 App 时如果没有正确关停 Node.js，下次冷启动时端口被占用，服务器启动失败导致闪退。

**解决**：退出流程中必须 `await NodeJsServer.stop()` + 等待 300ms + `exit(0)`。`SystemNavigator.pop()` 不够可靠，可能残留进程。

### 4.5 bundled_entry.js 路由倒序

**问题**：Express 的 `app.use` 是前缀匹配，`/search` 会拦截 `/search/suggest`。

**解决**：`gen_node_bundle_entry.js` 对模块列表做了 `.reverse()` 排序，确保更具体的路由（如 `/search/suggest`）先于通用路由（如 `/search`）注册。**不要修改这个排序逻辑。**

### 4.6 networkapi 与 kugou_api_server 的 util 同步

**问题**：两个目录各自维护 `util/` 副本，修改一处不会自动同步到另一处。

**解决**：修改工具函数时，需要同时更新 `kugou_api_server/util/` 和 `networkapi/util/`。

### 4.7 Android 构建配置

- `compileSdk = 36`，`targetSdk = 35`，`ndkVersion = "28.2.13676358"`
- CMake 3.22.1 用于编译 JNI 桥接代码
- Release 构建启用 R8 混淆（`isMinifyEnabled = true`），修改原生接口后需检查 `proguard-rules.pro`
- 无 `keystore.properties` 时自动使用 debug 签名

### 4.8 Dart 分析规则

- 使用 `package:flutter_lints/flutter.yaml`
- `avoid_print` 默认开启，但项目中大量使用 `print()` 做调试日志（如 Node.js 启动日志），通过 `// ignore: avoid_print` 抑制
- 部分 `discarded_futures` 也通过 ignore 注释处理

---

## 5. 技术栈速查

| 层 | 技术 | 版本要求 |
|----|------|----------|
| 前端框架 | Flutter | SDK ^3.12.0 |
| 状态管理 | Provider (ChangeNotifier) | ^6.1.2 |
| 音频播放 | just_audio + just_audio_background | ^0.9.34 |
| 本地存储 | sqflite + shared_preferences | 2.3.3+1 / ^2.5.0 |
| 网络请求 | dio + http | ^5.4.0 / ^1.2.1 |
| 主题 | dynamic_color + material_color_utilities | MD3 动态取色 |
| 嵌入式 Node.js | libnode.so (nodejs-mobile) | Node 18 |
| API 服务器 | Express | ^4.18.2 |
| 打包工具 | esbuild | ^0.25.3 |
| 原生桥接 | JNI + CMake + dart:ffi | NDK 28 |
| 构建工具 | Gradle (Kotlin DSL) | Java 17 |

---

## 6. 常用命令

```bash
# 首次环境搭建
setup_native.bat                          # 下载解压 libnode.so
cd kugou_api_server && npm install        # 安装 Node.js 依赖

# 日常开发
scripts\build_nodejs_server.bat           # 重新构建 Node.js bundle
flutter run                               # 调试运行
flutter build apk --release --split-per-abi  # 发布构建

# 测试 API
powershell -File scripts\test_api.ps1     # 测试本地 API 接口

# 代码检查
flutter analyze                           # Dart 静态分析
```
