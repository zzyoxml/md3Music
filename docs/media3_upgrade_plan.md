# 媒体会话架构根治计划：统一到单一媒体3 会话

## 1. 背景与根因（2026-08-28 已坐实）

App 同时存在两个 MediaSession：
1. `AudioPlaybackService` 的自定义 `MediaSessionCompat`（带封面/标题，由通知 MediaStyle 关联）——承载展示层。
2. just_audio 本地 fork 创建的 `androidx.media3.session.MediaSession`（原无元数据，仅作 audioSessionId/焦点关联，fork 注释明确「不请求焦点、不绑定通知栏」）。

**两个会话并存是"封面被覆盖/顶层切换" bug 的根源**：
- 播放推进时 SystemUI（小米控制中心）把「顶层媒体」切到正在播放的媒体3 会话；它无元数据 → 控制中心被覆盖成无封面（日志 `MainPanelItemViewHolder: art null → setCover: bitmap is null`，按媒体3 约 5s 刷新节奏循环）。
- 且「切歌不同步」：控制中心/耳机/自动播放直接推进 just_audio 队列时，自定义会话仍停在上一首。

两会话在架构上并非必需，是历史演进的结果，各自承担了互不重叠的职责，并存才产生竞争。

## 2. 三层可选路线（按根治程度排序）

| 路线 | 做法 | 根治程度 | 成本/风险 |
|------|------|---------|----------|
| **A. 现状缓解（已落地）** | 保留双会话：给媒体3 会话运行时注入标题/封面（`Player.replaceMediaItem`），并在 Flutter 端用 `sequenceStateStream` 把 just_audio 切歌同步到自定义会话 | 缓解 | 低，已可用 |
| **B. 统一单一媒体3 会话（推荐，根治）** | **取消自定义 `MediaSessionCompat`**，把通知栏/封面/歌词/桌面歌词/小组件全部迁移到 just_audio 媒体3 会话 | **根治**（竞争天然消失） | 中高，一次重构 |
| **C. 升级 media3（可选辅助）** | 升级 vendor 到更高版本以获取更多 API | 不直接解决 | 高（fork 全量迁移） |

> 重要结论：**升级 media3 并非必需**。经 `javap` 确认 `media3-common 1.4.1` 的 `Player` 接口已含 `Player.replaceMediaItem(int, MediaItem)`，官方确认「同 URI 替换只更新 metadata、不打断播放」，因此给媒体3 会话运行时注入封面/标题在现有版本即可完成（路线 A 已验证）。「单一会话」才是能根治双会话竞争的正道（路线 B）。

## 3. 根治方案 B：统一到单一媒体3 会话

### 3.1 目标架构

系统的媒体展示与播放全部收敛到 just_audio 媒体3 会话（ExoPlayer + `MediaSession`），不再自建 `MediaSessionCompat`：

- **播放/控制**：just_audio（ExoPlayer）承担，媒体3 会话注册系统媒体控制。
- **通知栏**：由媒体3 会话/`MediaSessionService` 的 now playing 通知承载，替换现有 MediaStyle 通知。
- **封面/歌词/桌面歌词/小组件/锁屏歌词**：全部改消费/更新媒体3 会话的元数据。

### 3.2 现状职责盘点（迁移需覆盖的部分）

| 能力 | 现行所属（需迁移） | 迁移目标 |
|------|------|------|
| 通知栏卡片（MediaStyle，绑定自定义 token） | AudioPlaybackService | 媒体3 now playing 通知 |
| 封面链路（下载→缓存→降采样→`METADATA_KEY_ART`） | AudioPlaybackService | 媒体3 `MediaMetadata.artworkData` / `BitmapLoader` |
| 蓝牙歌词按句 AVRCP、`LyricInfo` extras、锁屏歌词 | AudioPlaybackService | 媒体3 `MediaMetadata` 动态更新 |
| 桌面歌词开关、收藏定制 action | AudioPlaybackService | 媒体3 自定义 command / `MediaSession.extras` |
| 桌面小组件封面同步 | AudioPlaybackService（`MusicWidgetProvider.cachedArtwork`） | 媒体3 会话封面回调 |
| Flutter→原生同步通道（`MediaNotificationService`） | AudioPlaybackService | 改接入媒体3 会话 |
| 焦点三模式、固定 audioSessionId、USB 独占 | just_audio fork（播放器层） | 保留不动（已是播放器层） |

### 3.3 迁移清单

1. **播放器层（不变）**：保留 just_audio fork 的焦点三模式、固定 `audioSessionId`、USB 独占、ObserverRenderer。这些不随展示层迁移。
2. **建立媒体3 承载**：启用 `MediaSessionService` / `MediaNotification`，让媒体3 会话拥有 now playing 通知栏，作为唯一对外通知。
3. **封面注入**：复用已验证的 `replaceMediaItem`（或给 `MediaSession` 配 `BitmapLoader`），把本地缓存封面作为 `MEDIA_KEY_ART` 位图提供。
4. **歌词迁移**：把蓝牙歌词逐句、`LyricInfo`、锁屏歌词从自定义会话改到媒体3 会话的 `MediaMetadata`（AVRCP 读取统一）。
5. **自研 action 迁移**：桌面歌词开关、收藏等用媒体3 的自定义 Command 承载。
6. **小组件/锁屏歌词 Activity**：改读取媒体3 会话 token / 封面回调。
7. **同步通道重构**：Flutter 端 `MediaNotificationService.updateNotification` 不再 push 给自定义会话，改为更新媒体3 会话 metadata（或由媒体3 的 sequence/state 自动反映）。
8. **移除**：`AudioPlaybackService` 的 `MediaSessionCompat` 及其 MediaStyle 通知、相关回调与 MethodChannel 分支。

### 3.4 分阶段步骤（每步有验收）

- **阶段 0：基线备份**：git 打 tag / 独立分支，保留路线 A 的可用态。
- **阶段 1：媒体3 通知栏上线**：`MediaSessionService` + now playing 通知，验证通知栏可见、可控制播放。
- **阶段 2：封面接入媒体3**：本地缓存封面包 `MEDIA_KEY_ART`，验证控制中心/锁屏封面稳定（对比路线 A 效果）。
- **阶段 3：歌词迁移**：蓝牙歌词/`LyricInfo`/锁屏歌词改走媒体3 会话，验证车机 & 锁屏歌词一致。
- **阶段 4：自研 action + 小组件迁移**：桌面歌词/收藏、桌面小组件封面，验证各端不回归。
- **阶段 5：移除自定义会话**：删除 `MediaSessionCompat` 及媒体样式通知、相关通道。验证全链路（播放/切歌/封面/歌词/暂停）无回归。
- **阶段 6：全量回归**：本地/在线/云盘、USB、均衡器、歌词、锁屏歌词、小组件、DLNA。

### 3.5 收益
- 双会话竞争（顶层切换、封面被覆盖、切歌不同步）**根治**。
- 封面/标题/歌词各端天然一致，架构单一干净。
- 后续维护点收敛，不再维护两套 Metadata/通知逻辑。

### 3.6 风险与回滚
- 风险集中在「把自研展示/歌词能力迁到媒体3」这一层，涉及面广、需完整回归；歌词/锁屏 AVRCP 各家 ROM 仍有不确定性。
- 每阶段独立分支可回滚；阶段 0 基线随时可退回路线 A。
- ⚠️ 前置验证：先做一个最小 demo 确认 SystemUI 控制中心确实消费媒体3 会话的 `METADATA_KEY_ART` 位图，再投入整体迁移（经验教训：不能假设）。

## 4. 备选/辅助：升级 media3（说明）

- **非必需**：`replaceMediaItem` 在 1.4.1 已可用于运行时 metadata 更新（已实证），因此本次目标不再依赖升级。
- 仅当后续需要更高版本 API（或不含 `replaceMediaItem` 语义的某行为）时才考虑升级；届时按如下分散步骤 + 上表 fork patch 逐项迁移：
  1. 目标版本先用 `javap` 验证所需接口存在，再用最小 demo 确认控制中心消费 ART 位图。
  2. 阶段①纯源码替换编译通过 → ②AudioFocusManager fork → ③USB 独占 → ④固定 audioSessionId/会话关联 → ⑤封面落地 → ⑥回归。
- 升级依赖 fig：maven 模块统一为目标版本；`media3-exoplayer/session` 为 vendored 本地源码需整体替换。

## 5. 决策建议

- **短期**：维持路线 A（双会话 + `replaceMediaItem` 注入 + sequence 同步），功能可用、封面稳定。
- **根治**：推进路线 B（统一单一媒体3 会话），**本计划的核心目标**；先做 §3.6 的前置验证，再按阶段落地。
- 路线 B 完成后，双会话竞争、封面覆盖、切歌不同步三问题一并消除。