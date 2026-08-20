# Miuix 发现页重设计（HyperOS 音乐页风格）— 设计文档

日期：2026-08-19
范围：仅原生 Kotlin 测试页 `MiuixDiscoverActivity.kt`，**不动 Dart / 数据模型 / 数据接口**。

## 背景

现状（第一版移植）的问题：
- 五个信息区块都是"整张全宽 Card"，视觉单一、拥挤（卡片水平 padding 仅 12dp）。
- 顶部问候横幅用大块 `primaryVariant` 纯色，色彩厚重、无封面视觉。
- 封面用 `RoundedCornerShape(16.dp)`，非 miuix 的连续圆角（squircle）审美。
- 字号大量硬编码（32sp/16sp/13sp/11sp），未用 `MiuixTheme.textStyles`。
- 图标使用文本符号（"♪"、"‹"），不够精致。

## 目标

按 HyperOS 音乐页 / miuix 设计哲学重做排版：
1. **Squircle 连续圆角**：自实现 `SquircleShape`（贝塞尔连续圆角），用于封面/卡片/磁贴/Hero。
2. **柔和配色**：全部使用 `MiuixTheme.colorScheme` token；primary 仅做点缀（播放键、数字、图标）。
3. **字阶规范**：使用 `MiuixTheme.textStyles`（title1/title3/subtitle/body2/footnote1 等）。
4. **留白节奏**：页面边距 16dp、卡片内边距 16dp、分区间距 8~16dp；分区标题用 `SmallTitle`。
5. **MIUI 风细线图标**：手绘 `ImageVector`（播放/音乐/歌单/排行榜/场景/搜索/更多/返回/chevron）。

## 页面结构（自上而下）

1. **TopAppBar**：largeTitle「发现」+ miuix 风格返回按钮（IconButton + 手绘返回箭头）。
2. **每日推荐 Hero 大卡**（squircle 24dp）：
   - 背景：每日推荐第一首封面（AsyncImage + 渐变遮罩，左上亮/右下暗，保证文字可读）。
   - 叠加：大号问候语（title1，如"早上好"）+「发现你喜欢的音乐」（footnote/body）+「共 N 首」。
   - 操作：primary 播放按钮（"播放全部"）。
   - 无封面时回退为 `primaryContainer` 柔和底色。
3. **每日推荐横滑歌曲条**：轻量条目（序号 + 歌名 + 歌手），点击行为保持测试页（无副作用/占位）。
4. **主题歌单**：`SmallTitle` + 横向 squircle 封面卡（名称 + 曲数）。
5. **场景音乐**：`SmallTitle` + 横向 squircle 图标磁贴。
6. **热门歌单**：`SmallTitle` + 横向封面卡（带曲数角标）。
7. **排行榜**：`SmallTitle` + 横向封面卡（排名数字角标）。

## 组件清单

- `SquircleShape`：自实现 Shape（贝塞尔连续圆角，radius 参数化）。
- `AppIcon`：手绘 MIUI 风细线 ImageVector 图标集。
- `HeroCard`：封面 + 渐变遮罩 + 问候 + 播放按钮。
- `SectionHeader`：SmallTitle + 可选"更多"链接。
- `CoverCard`：squircle 封面 + 角标（曲数/排名）+ 名称 + 副文案。
- `SceneTile`：squircle 图标磁贴。
- `SongStripItem`：每日推荐横滑轻量条目。

## 数据流 / 状态

- **完全复用** 现有 `DiscoverRepository`（五端点独立容错、端口来自 Intent extra）。
- 加载态：miuix `CircularProgressIndicator`。
- 错误态：精致化——图标 + 文案（含异常类名便于定位）+ `Button` 重试。

## 约束

- 不新增 Gradle 依赖（仅用 `miuix-android:0.8.8` 自带组件 + 纯 Compose）。
- 不动 Dart 端任何文件；测试入口仍是 设置 → 关于 → Miuix 发现页测试（开发）。
