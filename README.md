# Echo Music Player - md3Music

一个 Material Design 3 风格的音乐播放器

## 🚀 项目状态

本项目已成功修复以下问题:

✅ **Web 平台兼容性**
- 移除 `just_audio_background` 在 Web 上的初始化错误
- 修复 `Platform.isAndroid` 在 Web 上的不兼容问题
- 添加对 `on_audio_query` 在 Web 上的安全跳过
- 添加 `kIsWeb` 标记和 try-catch 保护

✅ **API 服务器集成**
- 从 EchoMusic 项目获取完整的 KuGou 音乐 API 服务器
- 所有模块已完整复制到项目中
- 依赖已安装成功

✅ **应用可以正常启动!**

## 📦 项目结构

```
md3Music/
├── lib/                   # Flutter 应用代码
│   ├── main.dart          # 应用入口
│   ├── app.dart           # 应用主组件
│   ├── providers/         # 状态管理
│   ├── services/          # API 服务
│   └── ...
├── kugou_api_server/      # KuGou API 代理服务器
│   ├── app.js            # 服务器入口
│   ├── server.js         # 服务器核心
│   ├── module/           # API 模块
│   └── ...
└── pubspec.yaml
```

## 🛠️ 运行项目

### 前置要求

1. **Node.js** 14.0 或更高版本
2. **Flutter** 3.0 或更高版本
3. **Chrome/Edge** 浏览器(Web 平台测试)

### 1. 启动 API 服务器

```bash
# 进入 API 服务器目录
cd kugou_api_server

# 安装依赖(首次运行需要)
npm install

# 启动服务器
node app.js
```

服务器将在 **http://localhost:8080** 启动!

### 2. 启动 Flutter 应用

打开一个新的终端窗口,在项目根目录运行:

```bash
# 同时启动 API 服务器和 Flutter 应用
npm run start:all

# 或者分别启动
npm run start:api    # 只启动 API 服务器
npm run start:flutter  # 只启动 Flutter 应用
```

### 3. 访问应用

浏览器会自动打开,或手动访问 **http://localhost:XXXX**

## 📋 功能说明

### 在线音乐功能

- ✅ 在线音乐搜索
- ✅ 每日推荐
- ✅ 歌单列表
- ✅ 热门音乐榜
- ✅ 新歌速递
- ✅ 在线播放

### 本地音乐功能

- ✅ 本地音乐扫描(仅限 Android/Windows 原生平台)
- ✅ 本地音乐播放
- ✅ 本地专辑/歌手分类

### 播放功能

- ✅ 音频播放控制
- ✅ 播放队列管理
- ✅ 歌词显示
- ✅ 播放历史记录

### 设计与布局

- ✅ Material Design 3
- ✅ 响应式布局
- ✅ 手机/平板/桌面自适应

## 🔧 常见问题

### 1. 看不到任何音乐

**解决:** 确保 API 服务器已在 **http://localhost:8080** 正常运行

### 2. 音乐无法播放

**解决:** 
- 检查网络连接
- 查看 API 服务器日志是否有错误
- 可能是版权限制导致特定歌曲无法获取

### 3. Web 上本地音乐不显示

**正常!** Web 平台不支持本地文件访问,这是安全限制。请在 Android 或 Windows 原生平台上使用本地音乐功能。

## 📄 API 服务器文档

访问 **http://localhost:8080/docs** 查看完整的 API 文档!

## 🎯 下一步开发计划

1. 添加更多音质选择
2. 优化 UI 动画效果
3. 添加更多排行榜
4. 实现歌曲收藏功能
5. 添加设置页面
6. 完善播放器功能

## 📝 技术栈

- **Flutter** - 跨平台 UI 框架
- **Provider** - 状态管理
- **just_audio** - 音频播放
- **on_audio_query** - 本地音乐扫描
- **Express** - API 代理服务器
- **KuGou Music API** - 音乐数据源

## 🙏 感谢

感谢以下项目的支持:
- [EchoMusic](https://github.com/hoowhoami/EchoMusic) - 提供了 UI 设计和架构参考
- [KuGouMusicApi](https://github.com/MakcRe/KuGouMusicApi) - 提供了完整的 API 代理服务

## 📄 许可证

MIT License
