# MD3Music - Material Design 3 音乐播放器

<div align="center">

基于酷狗音乐 API 的 Flutter 音乐播放器，采用 Material Design 3 设计规范。
**内置 Node.js 服务器+云端 API (networkapi)**，。

[![Flutter](https://img.shields.io/badge/Flutter-3.12+-02569B?logo=flutter)](https://flutter.dev)
[![Platform](https://img.shields.io/badge/Platform-Android-green)]()
[![Version](https://img.shields.io/badge/Version-2.5.0-blue)]()
[![License](https://img.shields.io/badge/License-MIT-yellow)](LICENSE)

</div>

---

## ✨ 功能特性

### 🎵 在线音乐
- **音乐搜索** - 支持歌曲、专辑、歌单多维度搜索
- **每日推荐** - 个性化歌曲推荐
- **热门排行榜** - 多种排行榜实时更新
- **私人 FM** - 猜你喜欢，无限畅听

### 🎧 播放体验
- **多音质选择** - 标准(128k)、高质(320k)、无损(FLAC)
- **循环模式** - 单曲循环、列表循环、随机播放
- **歌词同步** - 实时滚动歌词显示
- **桌面歌词** - 桌面歌词展示功能
- **后台播放** - Android 后台播放通知
- **状态栏控制** - 上一曲/下一曲/播放暂停/进度拖动

### 📱 用户中心
- **VIP 签到** - 自动领取 VIP 特权
- **我的收藏** - 本地收藏 + 云端同步
- **播放历史** - 自动记录播放记录
- **下载管理** - 后台下载，离线播放

### ⚙️ 设置功能
- **一键清理缓存** - 快速清理应用缓存
- **深色模式** - 浅色/深色/跟随系统

### 🎨 设计风格
- **Material Design 3** - 最新 MD3 设计规范
- **动态颜色主题** - 基于 Seed Color 动态配色
- **响应式布局** - 手机/平板/桌面自适应

---

## 🏗️ 架构说明

### 本地 + 云端混合架构

```
┌─────────────────────────────────────────────────────────┐
│                    MD3Music App                         │
│  ┌─────────────────────┐  ┌────────────────────────┐  │
│  │   Flutter UI        │  │  嵌入式 Node.js 服务器 │  │
│  │   (Dart)           │  │  (127.0.0.1:8080)    │  │
│  └──────────┬──────────┘  └──────────┬─────────────┘  │
│             │                          │                  │
│             └──────────┬───────────────┘                  │
│                        │                                  │
│             ┌──────────▼───────────────┐                  │
│             │   本地数据 / 缓存         │                  │
│             └──────────────────────────┘                  │
└─────────────────────────────────────────────────────────┘
                           │
                           │ 仅登录/同步
                           ▼
              ┌────────────────────────────┐
              │   云端 API (networkapi)     │
              │   115.29.236.96:5621      │
              └────────────────────────────┘
```

### 核心特点

- **内置 Node.js 服务器**：App 启动时会自动启动本地 Node.js 服务器（127.0.0.1:8080），所有 API 请求都在本地处理
- **流量优化**：仅有登录和同步功能走云端，其他所有功能都在本地运行，月流量 < 100MB
- **无需外部服务器**：用户无需自行搭建 API 服务器
- **多架构支持**：支持 armeabi-v7a（32位）、arm64-v8a（64位）、x86_64（模拟器）

---

## 🚀 快速开始

### 前置要求

- **Flutter SDK** 3.12.0 或更高版本
- **Node.js** 18.0 或更高版本（用于构建服务器包）
- **Android Studio** / VS Code
- **Android NDK** (用于编译 nodejs-mobile)

### 1. 克隆项目

```bash
git clone https://github.com/zzyoxml/md3Music.git
cd md3Music
```

### 2. 下载 Native 依赖（必需）

本项目使用 `nodejs-mobile` 运行嵌入式 Node.js，预编译的 `libnode.so` 和 Node.js 头文件通过 GitHub Release 分发，未包含在 Git 仓库中。

运行以下命令自动下载并解压：

```bash
# Windows
.\setup_native.bat

# macOS / Linux
curl -L -o native-libs.zip "https://github.com/zzyoxml/md3Music/releases/latest/download/native-libs.zip"
unzip native-libs.zip
rm native-libs.zip
```

下载内容：
- `android/app/src/main/jniLibs/` — 3个架构的 `libnode.so`
- `android/app/src/main/cpp/include/` — Node.js v18 头文件

### 3. 安装 Flutter 依赖

```bash
flutter pub get
```

### 4. 构建 Node.js 服务器包（可选）

如果你修改了 `kugou_api_server/` 目录下的代码，需要重新构建服务器包：

```bash
cd scripts
.\build_nodejs_server.bat
```

这会执行以下操作：
1. 在 `kugou_api_server/` 目录安装 npm 依赖
2. 使用 esbuild 打包成 `server_bundle.js`
3. 复制到 `assets/nodejs-project/` 目录

> **注意**：项目已经包含了预构建的 `server_bundle.js`，如果不是修改服务器代码，可以跳过此步骤。

### 5. 运行应用（调试模式）

```bash
# 连接 Android 设备后执行
flutter run
```

### 6. 构建发布版 APK

```bash
# 构建三个架构的 APK（分拆包）
flutter build apk --release --split-per-abi

# 输出位置：
# build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk  (32位)
# build/app/outputs/flutter-apk/app-arm64-v8a-release.apk   (64位)
# build/app/outputs/flutter-apk/app-x86_64-release.apk      (模拟器)
```

---

## 📦 下载安装

从 [Releases](https://github.com/zzyoxml/md3Music/releases) 页面下载最新版本的 APK 安装包。

- **arm64-v8a**：大多数现代 Android 设备（推荐）
- **armeabi-v7a**：较旧的 32 位设备
- **x86_64**：Android 模拟器

---

## 📁 项目结构

```
md3Music/
├── lib/                        # Flutter 应用代码
│   ├── main.dart               # 应用入口
│   ├── app.dart                # 主应用组件
│   ├── core/                   # 核心模块
│   │   ├── layout/             # 响应式布局
│   │   ├── services/           # 平台服务
│   │   ├── theme/              # 主题配置
│   │   └── utils/              # 工具类
│   ├── data/                   # 数据层
│   │   ├── models/             # 数据模型
│   │   └── repositories/       # 数据仓库
│   ├── modules/                # 功能模块
│   │   ├── discover/           # 发现页
│   │   ├── charts/             # 排行榜
│   │   ├── player/             # 播放器
│   │   ├── search/             # 搜索
│   │   ├── user/               # 用户中心
│   │   └── settings/           # 设置
│   ├── providers/              # 状态管理
│   ├── services/               # API 服务
│   └── widgets/                # 公共组件
├── kugou_api_server/           # Node.js API 服务器源代码
│   ├── index.js                # 服务器入口
│   ├── module/                 # API 模块
│   └── package.json            # npm 依赖配置
├── assets/                     # 资源文件
│   ├── images/                 # 图片资源
│   ├── fonts/                  # 字体文件
│   └── nodejs-project/        # 嵌入式 Node.js 服务器包
│       └── server_bundle.js    # 打包后的服务器代码
├── scripts/                    # 构建和工具脚本
│   └── build_nodejs_server.bat # 构建服务器包脚本
├── android/                    # Android 平台配置
│   └── app/src/main/
│       ├── kotlin/.../        # NodeJsService（启动本地服务器）
│       └── jniLibs/           # libnode.so（三个架构）
├── networkapi/                 # 云端登录 API（Node.js）
└── pubspec.yaml                # Flutter 配置
```

---

## 🛠️ 技术栈

| 类别 | 技术 |
|------|------|
| **UI 框架** | Flutter 3.12+ |
| **状态管理** | Provider |
| **音频播放** | just_audio |
| **网络请求** | Dio |
| **本地存储** | SharedPreferences + SQLite |
| **图片缓存** | cached_network_image |
| **嵌入式服务器** | nodejs-mobile (Node.js 18) |
| **服务器打包** | esbuild |
| **音乐源** | 酷狗音乐 API |
| **云端登录** | networkapi (Node.js) |

---

## ⚙️ 配置说明

### 嵌入式服务器

应用启动时会自动启动本地 Node.js 服务器，监听 `127.0.0.1:8080`。无需任何配置。

### 云端登录 API

登录功能需要连接云端 API 服务器（`115.29.236.96:5621`）。如果有自己的部署，可以在代码中修改地址。

### 音质设置

| 音质 | 格式 | 比特率 |
|------|------|--------|
| 标准 | MP3 | 128 kbps |
| 高质 | MP3 | 320 kbps |
| 无损 | FLAC | ~1000 kbps |

---

## 🔧 常见问题

### Q: 应用启动后无法搜索或播放音乐？

**A:** 检查日志确认 Node.js 服务器是否成功启动。可以在 Android Studio Logcat 中搜索 "NodeJsService" 查看启动日志。

### Q: 登录功能无法使用？

**A:** 登录功能需要连接云端 API。请确保设备可以访问 `115.29.236.96:5621`。

### Q: 如何修改 API 服务器代码？

**A:**
1. 修改 `kugou_api_server/` 目录下的代码
2. 运行 `scripts/build_nodejs_server.bat` 重新构建
3. 重新编译 App

### Q: 为什么不包含 x86 (32位) 支持？

**A:** x86 (32位) 模拟器已经非常罕见，且 `nodejs-mobile` 的预编译库也不包含 x86 版本。如果需要，可以自行编译 `nodejs-mobile` 的 x86 版本。

---

## 📝 开发说明

### 修改嵌入式服务器代码

1. 修改 `kugou_api_server/` 目录下的源代码
2. 运行构建脚本：
   ```bash
   cd scripts
   .\build_nodejs_server.bat
   ```
3. 重新编译 App

### 添加新架构支持

1. 获取对应架构的 `libnode.so`
2. 放入 `android/app/src/main/jniLibs/<abi>/`
3. 修改 `android/app/build.gradle.kts` 中的 CMake 配置
4. 重新编译

### 调试 Node.js 服务器

如果想在本地调试 API 服务器（不嵌入 App）：

```bash
cd kugou_api_server
npm install
node index.js
```

然后修改 App 代码中的 API 地址为 `http://127.0.0.1:3000`（本地服务器默认端口）。

---

## 🙏 致谢

感谢以下项目的支持：

- [EchoMusic](https://github.com/hoowhoami/EchoMusic) - UI 设计和架构参考
- [KuGouMusicApi](https://github.com/MakcRe/KuGouMusicApi) - API 代理服务
- [nodejs-mobile](https://github.com/janeasystems/nodejs-mobile) - 嵌入式 Node.js 框架

---

## 📄 许可证

本项目采用 [MIT License](LICENSE) 许可证。

---

<div align="center">

**Made with ❤️ by zzyoxml**

</div>
