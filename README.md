# MD3Music - Material Design 3 音乐播放器

<div align="center">

一个基于 KuGouMusicApi NodeJS 版 API代理服务，基于 Flutter 框架的 Material Design 3 设计规范的音乐播放器

[![Flutter](https://img.shields.io/badge/Flutter-3.12+-02569B?logo=flutter)](https://flutter.dev)
[![Platform](https://img.shields.io/badge/Platform-Android%20%7C%20Web-green)]()
[![Version](https://img.shields.io/badge/Version-2.0.0-blue)]()
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


## 🚀 快速开始

### 前置要求

- **Flutter SDK** 3.12.0 或更高版本
- **Node.js** 14.0 或更高版本（用于 API 服务器）
- **Android Studio** / VS Code

### 1. 克隆项目

```bash
git clone https://github.com/zzyoxml/md3Music.git
cd md3Music
```

### 2. 安装依赖

```bash
# Flutter 依赖
flutter pub get

# API 服务器依赖
cd kugou_api_server
npm install
cd ..
```

### 3. 启动 API 服务器

```bash
cd kugou_api_server
node app.js
```


### 4. 运行应用

```bash
# Android
flutter run

# Web
flutter run -d chrome
```

---

## 📦 下载安装

从 [Releases](https://github.com/zzyoxml/md3Music/releases) 页面下载最新版本的 APK 安装包。

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
├── kugou_api_server/           # API 代理服务器
│   ├── app.js                  # 服务器入口
│   ├── server.js               # 服务器核心
│   └── module/                 # API 模块
├── assets/                     # 资源文件
│   ├── images/                 # 图片资源
│   └── fonts/                  # 字体文件
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
| **API 服务** | Express.js |
| **音乐源** | 酷狗音乐 API |

---

## ⚙️ 配置说明

### API 服务器地址

在应用设置页面可以配置 API 服务器地址，默认为 `http://musicplayer.ccwu.cc`。

### 音质设置

| 音质 | 格式 | 比特率 |
|------|------|--------|
| 标准 | MP3 | 128 kbps |
| 高质 | MP3 | 320 kbps |
| 无损 | FLAC | ~1000 kbps |

---

## 🔧 常见问题

### Q: 看不到任何音乐内容？

**A:** 确保 API 服务器已正常启动并运行在配置的地址。

### Q: 音乐无法播放？

**A:** 
- 检查网络连接
- 查看 API 服务器日志
- 部分歌曲可能因版权限制无法获取

### Q: Web 平台本地音乐不显示？

**A:** Web 平台受安全限制无法访问本地文件，请在 Android 平台使用本地音乐功能。

---


## 🙏 致谢

感谢以下项目的支持：

- [EchoMusic](https://github.com/hoowhoami/EchoMusic) - UI 设计和架构参考
- [KuGouMusicApi](https://github.com/MakcRe/KuGouMusicApi) - API 代理服务

---

## 📄 许可证

本项目采用 [MIT License](LICENSE) 许可证。

---

<div align="center">

**Made with ❤️ by zzyoxml**

</div>