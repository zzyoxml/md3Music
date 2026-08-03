# MD3Music - Material Design 3 音乐播放器

<div align="center">
  
基于酷狗音乐 API 的 Flutter 音乐播放器，采用 Material Design 3 设计规范，自带嵌入式 Rust API 服务器。
支持手机/平板自适应，提供 Apple Music 风格播放页与逐字歌词。
本项目仅供学习使用，请勿用于商业用途，详情请参阅 [免责声明](DISCLAIMER.md)。



[![Flutter](https://img.shields.io/badge/Flutter-3.12+-02569B?logo=flutter)](https://flutter.dev)
[![Platform](https://img.shields.io/badge/Platform-Android-green)]()
[![License](https://img.shields.io/badge/License-MIT-yellow)](LICENSE)

</div>

## ✨ 功能特性

### 🎵 在线音乐
- **音乐搜索** - 支持歌曲、专辑、歌单、云盘多维度搜索
- **每日推荐** - 个性化歌曲推荐，每日更新
- **热门排行榜** - 多种排行榜实时更新，列表/网格双模式切换
- **私人 FM** - 猜你喜欢，无限畅听，支持红心/小众/速览模式
- **歌手详情** - 歌手歌曲浏览，支持搜索/定位/排序，关注/取消关注歌手
- **歌曲评论** - 歌单/专辑/歌曲评论查看，支持分页加载与头像展示
- **云盘音乐** - 登录后浏览/搜索/播放/下载云盘歌曲

### 💿 本地音乐
- **文件夹浏览** - 按存储目录浏览本地音乐，专辑/艺术家/歌曲三种分类切换
- **嵌入封面与歌词** - 优先读取文件内嵌封面（ID3/APIC）和歌词（USLT/LYRICS），断网也能正常显示
- **本地收藏** - 与云端收藏分离管理，不依赖网络账号
- **音质智能识别** - 自动读取码率显示对应音质标签（128k/320k/FLAC）
- **排序优化** - 支持按时间倒序、文件名、歌手排序
- **扫描持久化** - 扫描结果自动缓存，退出后再次打开不必重新扫描

### 🎧 播放体验
- **多音质选择** - 标准(128k)、高质(320k)、无损(FLAC)、Hi-Res 无损，自动降级链
- **循环模式** - 单曲循环、列表循环、随机播放
- **播放进度记忆** - 退出后恢复上次位置与列表，冷启动不会自动出声
- **异常恢复** - 播放异常结束时强制重新解析 URL 并从断点续播
- **暂停淡入淡出** - 暂停/播放时音量平滑过渡
- **边听边存** - 自动缓存音频/歌词/封面，断网可播放已缓存版本，容量上限可调
- **进度条高潮标记** - 副歌区间高亮，快速跳转
- **逐字歌词** - KRC/LRC/纯文本多格式解析，本地逐字 LRC 支持
- **歌词辉光效果** - 智能触发逐字辉光动画（Apple Music 风格）
- **歌词高斯模糊** - 歌词背景模糊，支持透明度可调
- **翻译/罗马音** - 分离显示，支持优先翻译模式
- **男女对唱歌词优化** - 剔除标记，男左女右、合唱居中
- **桌面歌词** - 悬浮歌词展示，跟随主题颜色
- **蓝牙歌词** - 通过 MediaSession 向 AVRCP 蓝牙设备推送歌词
- **Lyricon 词幕推送** - 向第三方歌词硬件/应用推送歌词元数据
- **频谱动画** - 播放中动态频谱可视化
- **封面跳转** - 点击歌名/作者/专辑可跳转详情页
- **迷你播放器滑动切歌** - 左右滑动切换上/下一首
- **后台播放** - Android 通知栏控制与状态栏播放
- **音频焦点** - 来电/拔耳机等场景自动暂停与恢复

### 📱 用户中心
- **VIP 双签到** - 自动领取畅听 VIP + 升级概念版 VIP，签到日历可视化（进度环 + 徽章）
- **我的收藏** - 本地收藏 + 云端同步，自建歌单支持批量多选删除
- **播放历史** - 自动记录，支持筛选已缓存歌曲
- **下载管理** - 后台下载、写入封面/歌词元数据、自定义目录、Hi-Res 音源
- **听歌识曲** - 录音识别当前播放歌曲

### 🎨 设计与设置
- **Material Design 3** - 全站统一 ColorScheme 色彩角色与 textTheme 文字层级
- **Apple Music 风格** - 模糊封面背景 + 弹簧动画 + 逐字歌词，支持 MD3/AM 双风格切换
- **动态主题色** - 预设种子色面板 + 莫奈色（Android 12+）
- **深色模式** - 浅色/深色/跟随系统/OLED 纯黑
- **设备模式** - 自动/手机/平板手动切换
- **歌词设置** - 字体选择、高斯模糊、辉光、双击跳转、歌词字体自定义
- **歌手写真背景** - 播放页轮播歌手写真（仅在线歌曲）
- **背景动态流光** - 封面色彩流动效果
- **新手引导** - 首次安装弹出引导页，覆盖核心操作
- **长按图标快捷方式** - 快速进入收藏/听歌识曲/搜索

---

## 🏗️ 架构说明

### 本地 + 云端混合架构

```
┌─────────────────────────────────────────────────────────┐
│                    MD3Music App                         │
│  ┌─────────────────────┐  ┌────────────────────────       │
│  │   Flutter UI        │  │  嵌入式 Rust API 服务器  │  │
│  │   (Dart)            │   │  (127.0.0.1:8080)     │  │
│  └──────────┬──────────┘  └──────────┬─────────────┘  │
│             │                          │                  │
│             └──────────┬───────────────┘                  │
│                        │                                  │
│             ──────────▼───────────────┐                  │
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

- **嵌入式 Rust 服务器**：App 启动时通过 `libkugou_server.so`（JNI/MethodChannel）启动本地 tiny_http 服务器（127.0.0.1:8080），所有酷狗 API 请求都在本地处理
- **高性能低资源**：Rust 实现取代旧 Node.js 方案，内存占用更低，启动更快
- **流量优化**：仅有登录和同步功能走云端，其他所有功能都在本地运行，月流量 < 100MB
- **无需外部服务器**：用户无需自行搭建 API 服务器
- **多架构支持**：支持 armeabi-v7a（32位）、arm64-v8a（64位）、x86、x86_64（模拟器）

---

## 🔄 CI/CD

项目已配置 GitHub Actions 自动构建，推送 `v*` 标签即可触发：

- 自动构建 4 个架构的 APK（arm64-v8a、armeabi-v7a、x86、x86_64）
- 自动创建 GitHub Release 并上传产物
- 自动递增 versionCode 并生成 Changelog

---



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



## 🚀 快速开始

### 前置要求

- **Flutter SDK** 3.12.0 或更高版本
- **Rust** 1.70+（用于构建嵌入式 API 服务器）
- **Android Studio** / VS Code
- **Android NDK** 28（用于 Rust 交叉编译）

### 1. 克隆项目

```bash
git clone https://github.com/zzyoxml/md3Music.git
cd md3Music
```

### 2. 安装 Flutter 依赖

```bash
flutter pub get
```

### 3. 构建 Rust 服务器（可选）

`libkugou_server.so` 已提交进 Git 仓库，通常无需重新编译。如果你修改了 `kugou_api_server/rust/src/` 下的代码，需要重新构建：

```bash
# 主机编译验证
cd kugou_api_server/rust
cargo build --release

# 安卓交叉编译（3 个 ABI，需要 NDK）
./build_android.sh
```

> **注意**：`libkugou_server.so`（arm64-v8a、armeabi-v7a、x86、x86_64）已包含在仓库中，修改服务器代码才需要重新编译。

### 4. 运行应用（调试模式）

```bash
# 连接 Android 设备后执行
flutter run
```

### 5. 构建发布版 APK

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
- **x86**：32 位 Android 模拟器


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
│   │   ├── library/            # 音乐库（本地音乐/云盘）
│   │   ├── settings/           # 设置
│   │   ├── login/              # 登录
│   │   ├── onboarding/         # 新手引导
│   │   └── recognition/        # 听歌识曲
│   ├── providers/              # 状态管理
│   ├── services/               # API 服务（元数据写入/下载管理）
│   └── widgets/                # 公共组件
│       └── apple_lyrics/       # Apple Music 风格歌词
├── kugou_api_server/           # 嵌入式 Rust API 服务器
│   ├── rust/                   # Rust crate（tiny_http + ureq）
│   │   ├── src/
│   │   │   ├── lib.rs          # FFI/JNI 导出符号
│   │   │   ├── server.rs       # HTTP 服务器：路由分发、CORS、缓存
│   │   │   ├── modules/        # 160+ 个 API 模块
│   │   │   ├── crypto.rs       # MD5/SHA1/AES/RSA 加密
│   │   │   ├── request.rs      # 上游转发（ureq）
│   │   │   └── device.rs       # 设备信息持久化
│   │   ├── tests/smoke.rs      # 本地冒烟测试
│   │   ├── build_android.sh    # 一键交叉编译脚本
│   │   └── Cargo.toml
│   └── module/                 # 旧 JS 模块（已废弃，仅供参考）
── img/                        # 界面预览截图（README 用）
│   ├── phone/                  # 手机：md3 / applemusic / other
│   └── pad/                    # 平板：md3 / applemusic / other
├── assets/                     # 资源文件
│   ├── images/                 # 图片资源
│   └── fonts/                  # 字体文件
├── android/                    # Android 平台配置
│   └── app/src/main/
│       ├── kotlin/.../        # KugouApiService（启动本地服务器）
│       └── jniLibs/           # libkugou_server.so（四个架构）
├── networkapi/                 # 云端登录 API（Node.js，仅登录接口）
└── pubspec.yaml                # Flutter 配置
```

---

## 🛠️ 技术栈

| 类别 | 技术 |
|------|------|
| **UI 框架** | Flutter 3.12+ |
| **状态管理** | Provider |
| **音频播放** | just_audio + just_audio_background |
| **音频焦点** | audio_session |
| **网络请求** | Dio |
| **本地存储** | SharedPreferences + SQLite |
| **图片缓存** | cached_network_image |
| **嵌入式服务器** | Rust（tiny_http + ureq） |
| **加密** | rsa / aes / md-5 / sha1 / sha2 |
| **元数据写入** | JAudioTagger (MP3/FLAC/M4A) |
| **桌面歌词** | Lyricon Provider |
| **音频均衡器** | just_audio 平台均衡器 |
| **音乐源** | 酷狗音乐 API |
| **云端登录** | networkapi (Node.js，仅登录接口) |

---

## ⚙️ 配置说明

### 嵌入式服务器

应用启动时会自动启动本地 Rust 服务器（`libkugou_server.so`），监听 `127.0.0.1:8080`。无需任何配置。

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

**A:** 检查日志确认 Rust 服务器是否成功启动。可以在 Android Studio Logcat 中搜索 "KugouApiService" 查看启动日志。

### Q: 登录功能无法使用？

**A:** 登录功能需要连接云端 API。请确保设备可以访问 `115.29.236.96:5621`。

### Q: 如何修改 API 服务器代码？

**A:**
1. 修改 `kugou_api_server/rust/src/` 目录下的 Rust 代码
2. 运行 `cd kugou_api_server/rust && cargo build --release` 编译验证
3. 安卓侧需交叉编译：`./build_android.sh`
4. 重新编译 App

### Q: 为什么 Rust 服务器需要 NDK？

**A:** Rust 的 TLS 依赖（`ring` crate）需要交叉编译为 Android 平台的 `.so` 文件。NDK 提供了 `aarch64-linux-android-clang` 等交叉编译工具链。

---

## 📝 开发说明

### 修改嵌入式服务器代码

1. 修改 `kugou_api_server/rust/src/` 目录下的 Rust 源代码
2. 主机编译验证：
   ```bash
   cd kugou_api_server/rust
   cargo build --release
   cargo test        # 运行测试
   cargo clippy      # 静态检查
   ```
3. 安卓交叉编译（需要 NDK）：
   ```bash
   ./build_android.sh
   ```
4. 重新编译 App

### 添加新 API 模块

在 `kugou_api_server/rust/src/modules/` 下新建 `.rs` 文件，实现对应的 API 端点处理函数，然后在 `server.rs` 中注册路由即可。

### 调试 API 服务器

如果想在本地调试 API 服务器（不嵌入 App）：

```bash
cd kugou_api_server/rust
cargo test          # 本地测试（不依赖外网）
```

---

##  致谢

感谢以下项目的支持：

- [EchoMusic](https://github.com/hoowhoami/EchoMusic) - UI 设计和架构参考
- [KuGouMusicApi](https://github.com/MakcRe/KuGouMusicApi) - API 代理服务
- [tiny_http](https://github.com/tiny-http/tiny-http) - Rust HTTP 服务器
- [ureq](https://github.com/algesten/ureq) - Rust HTTP 客户端
- [JAudioTagger](https://www.jthink.net/jaudiotagger/) - 音频元数据读写

---

## 📄 许可证

本项目采用 [MIT License](LICENSE) 许可证。

---

</div>

---

<div align="center">

**Made with ❤️ by zzyoxml and Little-White3110**

</div>
