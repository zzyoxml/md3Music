# MD3Music - Material Design 3 音乐播放器

<div align="center">

基于酷狗音乐 API 的 Flutter 音乐播放器，采用 Material Design 3 设计规范，自带本地 Node.js 服务。
支持手机/平板自适应，提供 Apple Music 风格播放页与逐字歌词。

[![Flutter](https://img.shields.io/badge/Flutter-3.12+-02569B?logo=flutter)](https://flutter.dev)
[![Platform](https://img.shields.io/badge/Platform-Android-green)]()
[![Version](https://img.shields.io/badge/Version-3.6.0-blue)]()
[![License](https://img.shields.io/badge/License-MIT-yellow)](LICENSE)

</div>

---

## 📷 界面预览

### 手机 · Material Design 3

<p align="center">
  <img src="img/phone/md3/0f720b0e915226a9d5a8ea184e81a06d.jpg" width="220" alt="手机 MD3 界面 1" />
  <img src="img/phone/md3/58eddb6fd3ca614e60be7cb2fd4399d1.jpg" width="220" alt="手机 MD3 界面 2" />
  <img src="img/phone/md3/ade7e5ef5165adcf0fef302e2500c6db.jpg" width="220" alt="手机 MD3 界面 3" />
</p>

### 手机 · Apple Music 风格

<p align="center">
  <img src="img/phone/applemusic/Screenshot_2026-07-27-16-26-21-709_com.md3music.md3music_1785140818888edit.jpg" width="220" alt="手机 Apple Music 风格 1" />
  <img src="img/phone/applemusic/Screenshot_2026-07-27-16-26-24-328_com.md3music.md3music_1785140811076edit.jpg" width="220" alt="手机 Apple Music 风格 2" />
  <img src="img/phone/applemusic/Screenshot_2026-07-27-16-26-28-137_com.md3music.md3music_1785140802166edit.jpg" width="220" alt="手机 Apple Music 风格 3" />
</p>

### 手机 · 更多界面

<p align="center">
  <img src="img/phone/other/Screenshot_2026-07-27-12-11-55-256_com.md3music.md3music-edit.jpg" width="200" alt="手机更多界面 1" />
  <img src="img/phone/other/Screenshot_2026-07-27-12-12-09-452_com.md3music.md3music_1785125790967edit.jpg" width="200" alt="手机更多界面 2" />
  <img src="img/phone/other/Screenshot_2026-07-27-12-12-11-629_com.md3music.md3music_1785125804040edit.jpg" width="200" alt="手机更多界面 3" />
</p>
<p align="center">
  <img src="img/phone/other/Screenshot_2026-07-27-12-12-17-432_com.md3music.md3music_1785125828120edit.jpg" width="200" alt="手机更多界面 4" />
  <img src="img/phone/other/Screenshot_2026-07-27-12-12-29-360_com.md3music.md3music_1785125861447edit.jpg" width="200" alt="手机更多界面 5" />
  <img src="img/phone/other/Screenshot_2026-07-27-12-12-33-145_com.md3music.md3music_1785125869619edit.jpg" width="200" alt="手机更多界面 6" />
</p>
<p align="center">
  <img src="img/phone/other/Screenshot_2026-07-27-12-12-38-109_com.md3music.md3music_1785125883439edit.jpg" width="200" alt="手机更多界面 7" />
  <img src="img/phone/other/Screenshot_2026-07-27-12-12-44-567_com.md3music.md3music_1785125899909edit.jpg" width="200" alt="手机更多界面 8" />
  <img src="img/phone/other/Screenshot_2026-07-27-12-12-59-497_com.md3music.md3music_1785125915013edit.jpg" width="200" alt="手机更多界面 9" />
</p>
<p align="center">
  <img src="img/phone/other/Screenshot_2026-07-27-12-14-20-356_com.md3music.md3music_1785125983291edit.jpg" width="200" alt="手机更多界面 10" />
  <img src="img/phone/other/Screenshot_2026-07-27-12-14-31-085_com.md3music.md3music_1785125990804edit.jpg" width="200" alt="手机更多界面 11" />
  <img src="img/phone/other/Screenshot_2026-07-27-12-14-40-376_com.md3music.md3music_1785126001241edit.jpg" width="200" alt="手机更多界面 12" />
</p>

### 平板 · Apple Music 风格

<p align="center">
  <img src="img/pad/applemusic/5d27879361a4584d3a8118ae60d75d2a.jpg" width="420" alt="平板 Apple Music 风格 1" />
  <img src="img/pad/applemusic/00ce9bab6dfddd67b6d83918f57cfaae.jpg" width="420" alt="平板 Apple Music 风格 2" />
</p>


### 平板 · Material Design 3

<p align="center">
  <img src="img/pad/md3/919678959eeded94228d8cbc003409df.jpg" width="420" alt="平板 MD3 界面 1" />
  <img src="img/pad/md3/a57b3aa463c33dad0c450cb6d39e8030.jpg" width="420" alt="平板 MD3 界面 2" />
</p>

### 平板 · 更多界面

<p align="center">
  <img src="img/pad/other/mmexport1785140345418_1785140430976edit.jpg" width="560" alt="平板更多界面 1" />
</p>
<p align="center">
  <img src="img/pad/other/mmexport1785140349229_1785140392889edit.jpg" width="560" alt="平板更多界面 2" />
</p>
<p align="center">
  <img src="img/pad/other/mmexport1785140353053_1785140379593edit.jpg" width="560" alt="平板更多界面 3" />
</p>
<p align="center">
  <img src="img/pad/other/mmexport1785140356378_1785140371441edit.jpg" width="560" alt="平板更多界面 4" />
</p>

---

## ✨ 功能特性

### 🎵 在线音乐
- **音乐搜索** - 支持歌曲、专辑、歌单多维度搜索
- **每日推荐** - 个性化歌曲推荐
- **热门排行榜** - 多种排行榜实时更新，列表/网格双模式切换
- **私人 FM** - 猜你喜欢，无限畅听，支持红心/小众/速览模式
- **歌手详情** - 歌手歌曲浏览，支持搜索/定位/排序，关注/取消关注歌手
- **歌曲评论** - 歌单/专辑/歌曲评论查看，支持分页加载与头像展示
- **歌曲信息** - 自动剥离音频扩展名显示纯净标题

### 🎧 播放体验
- **多音质选择** - 标准(128k)、高质(320k)、无损(FLAC)、Hi-Res 无损（自动降级链：Hi-Res → FLAC → 320 → 128 → 试听）
- **循环模式** - 单曲循环、列表循环、随机播放
- **播放进度记忆** - 退出或被清理后恢复上次位置与列表，冷启动不会自动出声
- **异常恢复** - 播放异常结束时强制重新解析 URL 并从断点续播
- **进度条高潮标记** - 进度条上高亮副歌区间，便于快速跳转
- **拖动暂停** - 拖动进度条时自动暂停，松手后恢复，定位更准确
- **逐字歌词** - KRC/LRC/纯文本歌词解析与实时滚动显示，支持 offset
- **歌词辉光效果** - 智能触发逐字辉光动画，仅在 Apple Music 风格播放页可用
- **Lyricon 歌词** - 扩展歌词格式支持
- **桌面歌词** - 桌面悬浮歌词展示
- **蓝牙歌词** - 通过 MediaSession 元数据实现 AVRCP 蓝牙设备歌词显示
- **频谱动画** - 播放中动态频谱可视化标识
- **封面跳转** - 播放页点击歌名/作者/专辑可直接跳转专辑详情页
- **后台播放** - Android 后台播放通知与状态栏控制
- **音频焦点** - 耳机拔出、来电等场景自动暂停与恢复

### 📱 用户中心
- **VIP 签到** - 自动领取 VIP 特权，打卡日历可视化（签到勾选徽章 + 进度环统计）
- **我的收藏** - 本地收藏 + 云端同步，自建歌单支持批量多选删除
- **播放历史** - 自动记录播放记录
- **下载管理** - 后台下载、写入封面/歌词元数据、支持自定义目录、Hi-Res 音源下载

### ⚙️ 设置功能
- **一键清理缓存** - 快速清理应用缓存
- **深色模式** - 浅色/深色/跟随系统/OLED 纯黑
- **主题色选择** - 预设种子色面板，动态主题色切换
- **设备模式** - 自动/手机/平板手动切换，播放器与列表按模式适配
- **播放页样式** - Apple Music 风格开关、歌词高斯模糊、辉光效果、背景动态流光
- **歌词设置** - 歌词字体选择（仅 Apple Music 风格播放页可用）

### 🎨 设计风格
- **Material Design 3** - 最新 MD3 设计规范，全站统一 ColorScheme 色彩角色与 textTheme 文字层级
- **Apple Music 风格** - 模糊封面背景 + 弹簧动画 + 逐字歌词
- **动态颜色主题** - 基于 Seed Color 动态配色，支持莫奈色（Android 12+）
- **滚动感知 AppBar** - 页面滚动时顶栏渐变效果
- **响应式布局** - 手机/平板自适应，横屏沉浸播放
- **统一组件规范** - 卡片圆角、Elevation 层级、Chip/Tab 指示器全站一致

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

## 🔄 CI/CD

项目已配置 GitHub Actions 自动构建，推送 `v*` 标签即可触发：

- 自动构建 3 个架构的 APK
- 自动创建 GitHub Release 并上传产物
- 自动递增 versionCode 并生成 Changelog

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
│   │   ├── services/           # 平台服务（音频/桌面歌词/Lyricon/通知）
│   │   ├── theme/              # 主题配置
│   │   └── utils/              # 工具类
│   ├── data/                   # 数据层
│   │   ├── models/             # 数据模型
│   │   └── repositories/       # 数据仓库（设置/收藏/历史/下载）
│   ├── modules/                # 功能模块
│   │   ├── discover/           # 发现页
│   │   ├── charts/             # 排行榜
│   │   ├── player/             # 播放器（含评论视图）
│   │   ├── search/             # 搜索
│   │   ├── album/              # 专辑详情
│   │   ├── artist/             # 歌手详情
│   │   ├── personal_fm/        # 私人 FM
│   │   ├── user/               # 用户中心（签到/收藏/下载/历史）
│   │   ├── library/            # 音乐库
│   │   ├── settings/           # 设置
│   │   └── login/              # 登录
│   ├── providers/              # 状态管理
│   ├── services/               # API 服务（元数据写入/下载管理）
│   └── widgets/                # 公共组件
│       └── apple_lyrics/       # Apple Music 风格歌词
├── kugou_api_server/           # Node.js API 服务器源代码
│   ├── index.js                # 服务器入口
│   ├── module/                 # API 模块
│   └── package.json            # npm 依赖配置
├── img/                        # 界面预览截图（README 用）
│   ├── phone/                  # 手机：md3 / applemusic / other
│   └── pad/                    # 平板：md3 / applemusic / other
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
| **音频播放** | just_audio + just_audio_background |
| **网络请求** | Dio |
| **本地存储** | SharedPreferences + SQLite |
| **图片缓存** | cached_network_image |
| **嵌入式服务器** | nodejs-mobile (Node.js 18) |
| **服务器打包** | esbuild |
| **元数据写入** | JAudioTagger (MP3/FLAC/M4A) |
| **桌面歌词** | Lyricon Provider |
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
| Hi-Res | FLAC/MKV | ~2000+ kbps |

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
- [JAudioTagger](https://www.jthink.net/jaudiotagger/) - 音频元数据读写

---

## 📄 许可证

本项目采用 [MIT License](LICENSE) 许可证。

---

## ⭐ Star History

<div align="center">

<a href="https://star-history.com/#zzyoxml/md3Music&Date">
  <img src="img/star-history.svg" alt="Star History Chart" width="600" />
</a>

</div>

---

<div align="center">

**Made with ❤️ by zzyoxml and Little-White3110**

</div>
