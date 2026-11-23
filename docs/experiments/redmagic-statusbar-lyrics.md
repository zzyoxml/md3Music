# 红魔 11 Pro+：酷狗式状态栏歌词（实验模式）

## 验证边界

依据用户上传的 `kugou_windows_on(1).txt` / `kugou_windows_off(1).txt`，普通酷狗音乐在红魔 11 Pro+ 上通过类型 2038 (`TYPE_APPLICATION_OVERLAY`) 的独立窗口，把歌词画到与系统状态栏相同的**屏幕坐标**。参考窗口为 `(x=425, y=28, w=363, h=58)`、`alpha=0.8`；状态栏窗口为 `0..107px`，独立悬浮窗在系统状态栏以下的窗口层级。它不是任意 ROM 都能使用的 SystemUI API。

APK 静态分析显示酷狗主歌词使用 `FixLineLyricView` 自定义绘图，字号列表 `[12,14,16,18,22]`，默认索引 1，数值按 density 转换。*确切*长句平移动画曲线尚无证据，因此本实验使用原创的播放进度跟随和 LRC 单向滚动近似方案。

## 新增内容

- `android/.../StatusBarLyricView.kt`：原生 `Canvas` 透明单行歌词、KRC 部分高亮、平滑横移、无 KRC 时单向滚动、暂停冻结。
- `FloatingLyricService.kt`：同一个前台服务内，桌面模式与顶部模式互斥；顶部模式窗口 `APPLICATION_OVERLAY`、竖屏/横屏两套独立可调宽度（屏幕占比 15%–90%，默认 30%/55%）、透明度 0.8、`fitInsetsTypes` 不包括 `statusBars()`、点击穿透、显示范围随屏幕旋转更新。
- `MainActivity.kt` / `AudioPlaybackService.kt`：设置模式、启动时传递模式及字号、兼容原有 MethodChannel 和 headless FlutterEngine。
- Flutter `DesktopLyricService` / `SettingsRepository` / 桌面歌词设置面板：持久化模式、字号以及竖/横屏宽度，提供实验模式开关、五档字体以及原服务启停按钮。

## 使用

1. 构建安装 MD3Music Android 应用，授予“显示在其他应用上层”的权限。
2. 打开“设置 → 歌词 → 设备歌词 → 桌面歌词”：开启“酷狗式状态栏歌词（实验性）”；再打开“启用悬浮歌词”。如果已启用悬浮歌词，切换模式立即生效。
3. 播放带 KRC 或 LRC 的歌曲，切到桌面/其他应用观察顶部歌词。调整字号为 12/14/16/18/22。竖屏宽度与横屏宽度分别使用 15%–90% 滑块，松手保存并更新当前悬浮窗；屏幕旋转后自动切换对应宽度。
4. 不适配的机型可关闭“酷狗式状态栏歌词”，回到原桌面歌词。魅族原有 `FlymeLyricBridge` 未修改。

## 实际结果与限制

- 本次完成的是**源码级改造**：没有安装到用户红魔手机，也没有验证具体像素、顶部层级是否对所有 App 都可见。
- 该模式**替代**桌面歌词窗口，并非两个悬浮窗可同时显示。两个模式仍由同一个“启用悬浮歌词”开关控制。蓝牙/魅族状态栏等其余通道保持独立。
- 完整 APK 编译需 Flutter SDK、Android SDK 与项目依赖；本环境没有 Flutter/Android SDK，因此不能宣称已经编译 APK 或真机验证。
- 录屏/动态分析缺失，长句滚动算法不是酷狗的逐指令复刻。
- 不建议禁用系统安全权限策略或修改 SystemUI；此方案只使用普通悬浮窗权限。

## 真机验证命令（PowerShell）

```powershell
.\adb shell dumpsys window windows > md3music_status_on.txt
Select-String -Path .\md3music_status_on.txt -Pattern 'com.md3music.md3music|APPLICATION_OVERLAY|fitTypes'
```

检查是否出现 MD3Music `APPLICATION_OVERLAY`（2038）、frame 是否处于顶部，并对照酷狗的窗口截图。还应测试宽度 15%/30%/55%/90%、竖横屏自动切换、重启后设置保持、后台切歌、暂停/继续、无歌词、锁屏、完整通知栏下拉和全屏游戏。宽度设置仅改变绘制区域，不代表可以强行覆盖系统图标：大宽度可能导致内容被系统时钟/信号等遮挡；某些横屏游戏隐藏整个状态栏时，普通悬浮窗也未必可见。
