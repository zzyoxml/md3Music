# media3 升级迁移计划

## 1. 背景与目标

### 问题根因（2026-08-28 已坐实）
- App 同时存在两个 MediaSession：
  1. `AudioPlaybackService` 的自定义 `MediaSessionCompat`（带封面/标题，由通知 MediaStyle 关联）——封面链路正常。
  2. just_audio 本地 fork 创建的 `androidx.media3.session.MediaSession`（无任何元数据，只作 audioSessionId/焦点关联）。
- 播放推进时，SystemUI（小米控制中心）会把「顶层媒体」切到正在播放的媒体3 会话；因它无元数据，控制中心被覆盖成无封面（日志 `MainPanelItemViewHolder: art null → setCover: bitmap is null`，约按媒体3 的 5s 刷新节奏循环：先显示自定义封面 → 约 1s 后被 null 覆盖）。

### 已排除的注入路径（实证）
- 运行时 `Player.setMediaMetadata(...)`：`media3-common 1.4.1` 的 `Player` 接口**无此方法**（`javap` 确认，只有 `setMediaItem/setMediaItems`）。
- `MediaItem` 构建时注入：`tag` 未以 Map 下传到 native `decodeAudioSource`（`applyTagMetadata` 全程未命中日志），Dart `_toMessage` 的序列化与该 native 通路不一致。

### 结论
在**当前 media3 1.4.1 + 既有 fork 序列化**下，给媒体3 会话注入封面不可行。要真正解决，需升级 media3 到支持「运行时安全更新当前 MediaItem 的 MediaMetadata / 提供 ART 位图」的版本，升级后再落地封面注入。

## 2. 现状盘点

### 依赖（`third_party/just_audio/android/build.gradle.kts`）
- maven 版本统一为 `1.4.1`：
  `media3-common / container / database / datasource / decoder / extractor / exoplayer-dash / exoplayer-hls / exoplayer-smoothstreaming`
- 注意：`media3-exoplayer`、`media3-session` **未走 maven**，改为本地源码（`excludeLocalExoplayer`）。

### vendored 源码（`third_party/just_audio/android/src/main/java/androidx/media3/`）
- `exoplayer/**`（`AudioFocusManager`、`audio/AudioSink`、`ExoPlayer`、`ExoPlayerImpl`、`DefaultRenderersFactory` 等）
- `session/**`（`MediaSession`、`PlayerWrapper`、controllers、legacy 转换等）

## 3. fork patch 清单（升级时需逐项迁移）

| # | 位置 | 改动 | 说明 |
|---|------|------|------|
| 1 | `AudioPlayer.java::ensurePlayerInitialized` | 子类化 `DefaultRenderersFactory` 覆写 `buildAudioSink()` → `UsbAudioSinkController.wrap(...)` | USB 独占输出 |
| 2 | 同上 | `drf.setEnableAudioFloatOutput(false)` | 统一关闭 float，避免部分设备音高/速度异常 |
| 3 | 同上 | `RenderersFactory` 追加 `ObserverRenderer` | 频谱/线路 |
| 4 | 同上 | `player.setAudioSessionId(am.generateAudioSessionId())` 固定 id + 创建媒体3 `MediaSession` 关联 | 小米按 audioSessionId 判定可识别，避免自动 duck |
| 5 | 同上 | `player.setAudioAttributes(..., true)` | handleAudioFocus=true，焦点由 Media3 管理 |
| 6 | `exoplayer/AudioFocusManager.java` | package-private → public | 供 just_audio 注册焦点监听 |
| 7 | 同上 | 新增 add/remove relative 焦点事件监听、原始事件转发 | 三模式决策的事件源 |
| 8 | 同上 | `setForcedWillPauseWhenDucked / setIgnoreAudioFocus / setForceKeepPlaying` | 三模式标志，override/ignore 覆盖内置处理 |
| 9 | 同上 | 用 `AudioFocusRequestCompat`（自动带 ACCEPTS_DUCKING） | duck 兼容 |
| 10 | 同上 | 忽略/保持模式跳过内置自动处理，仅转发事件 | 避免二次 pause/duck |
| 11 | `com/ryanheise/just_audio/UsbAudioSinkController.java`、`UsbAudioSink.java` | fork 内新增类（对接 media3 `AudioSink` 接口） | 接口变化时需适配 |
| 12 | `exoplayer/ExoPlayerImpl.java::setAudioSessionId` | vendor 内已有方法 | 升级后若签名变化需同步 |

## 4. 目标版本选择（决策前置）

- 目标版本必须提供「运行时安全更新当前 MediaItem 元数据 / 给控制中心提供 ART 位图」的能力。**用 `javap` 在选定的 AAR 上先验证**对应 `Player`/`MediaSession` 接口存在所需方法，避免升级完仍无解。
- 候选：在当前 1.4.1 之后的稳定版中选取改动面与上面 patch 兼容性最好的一个；**优先选取可让现有 patch 最小改动的版本**，而非一味追新。
- ⚠️ 经验教训：即便拿到运行时 metadata 更新 API，也得确认 SystemUI 控制中心确实消费该位图（`METADATA_KEY_ART`）。建议升级前先用最小 demo 验证这一环，成本最低。

## 5. 迁移步骤（分阶段，每步有验收）

### 阶段 0：基线备份
- 在 `git` 给当前可用源码打 tag / 独立分支，保证可随时回退到"能跑、含首帧即带封面改进"的版本。

### 阶段 1：纯源码替换 + 编译通过（不迁 patch）
- vendored `exoplayer`/`session` 换为目标版本对应源码；maven 依赖统一到目标版本。
- 验收：`assembleDebug` 编译通过、App 能启动（此阶段 USB/焦点可能未接，仅验证编译与基础播放）。

### 阶段 2：迁移 AudioFocusManager fork
- 逐项迁移第 6–10 条。
- 验收：播放时三模式行为正常；小米专断中断（如 B 站视频）不会被强制自动 duck；忽略/保持播放语义正确。

### 阶段 3：迁移 USB 独占输出
- 迁移第 1–3、11 条。
- 验收：USB DAC 独占输出、均衡器、频谱/线路（ObserverRenderer）、静音播放正常。

### 阶段 4：迁移固定 audioSessionId + MediaSession 关联
- 迁移第 4–5、12 条。
- 验收：音频可识别（`hasUid`）、不自动 duck、焦点事件正常到达 AudioFocusManager；三模式仍生效。

### 阶段 5：落地封面注入（本 bug 的收尾）
- 用目标版本的运行时 metadata 更新 API：在 `AudioPlaybackService` 封面加载成功后，把 title/artist/ART 位图写入媒体3 会话（或给 `MediaSession` 配 `BitmapLoader` 以本地缓存封面提供 `MEDIA_KEY_ART`）。
- 验收：播放推进时控制中心/锁屏封面稳定，不再被无元数据的媒体3 会话覆盖成空。

### 阶段 6：全量回归
- 本地歌/在线歌/云盘、USB、均衡器、歌词、锁屏歌词、小组件、DLNA 等逐项验证后发布。

## 6. 风险与回滚点

- 全程在独立 git 分支进行，每个阶段可单独 revert / rebase 到阶段 0 基线。
- 最大风险：目标版本 API 变化大，patch 迁移冲突多。**务必按功能逐项迁移验收，避免一次性 big-bang。**
- 升级期间当前 debug 版保持可用（含已验证的"首帧即带封面"优化）。