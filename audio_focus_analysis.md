# MD3Music 音频焦点实现分析报告

> 分析时间：2026-08-15 ｜ 分支：`rust-local-two`（Rust 架构）

## 1. 结论先行

MD3Music 的音频焦点（Audio Focus）**不是由 `just_audio`（Media3/ExoPlayer）内部管理**，而是**完全委托给独立的 `audio_session` 插件**负责申请与释放，`just_audio` 的 ExoPlayer 被显式关闭了自动焦点处理（`handleAudioFocus = false`）。Dart 侧再通过 `audio_session` 的 `interruptionEventStream` / `becomingNoisyEventStream` 订阅焦点事件，自行实现"暂停/恢复/duck"策略。

核心设计是一套**"被动中断暂停"标志位（`_pausedByInterruption`）**，用来区分"音频焦点丢失导致的暂停"和"用户主动暂停"，从而在焦点恢复时**只自动恢复被中断打断的播放，绝不覆盖用户主动暂停**。

---

## 2. 依赖与架构

| 依赖 | 版本 | 角色 |
|------|------|------|
| `audio_session` | `^0.1.18` | **焦点管理方**：Android 端 `AudioSession` 负责 `requestAudioFocus` / `abandonAudioFocus`，并把打断事件上抛给 Dart |
| `just_audio`（本地 fork） | `0.10.6` | 播放引擎：ExoPlayer 被 `handleAudioFocus=false` 关闭自动焦点，只管出声 |
| `just_audio_background` | `^0.0.1-beta.11` | 媒体通知/后台服务，与焦点无直接耦合 |

**数据流**：

```
AudioSessionConfiguration.music()  (configure)
        │
        ▼
audio_session(Android AudioSession)  ── requestAudioFocus(AUDIOFOCUS_GAIN)
        │                              ── abandonAudioFocus(pause/stop)
        │  interruptionEventStream / becomingNoisyEventStream
        ▼
lib/core/services/audio_service_io.dart  AudioService
        │  依据 _pausedByInterruption 标志决定 pause / play
        ▼
just_audio(media3 ExoPlayer, handleAudioFocus=false)
```

关键接线点：

- [pubspec.yaml](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/pubspec.yaml#L15-L18)：`just_audio` 为本地 fork（`path: third_party/just_audio`），`audio_session` 为 pub 依赖。
- [AudioPlayer.java](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/third_party/just_audio/android/src/main/java/com/ryanheise/just_audio/AudioPlayer.java#L850-L864)：`player.setAudioAttributes(audioAttributes, false)` —— 第二个参数 `false` 即关闭 ExoPlayer 自动焦点。just_audio 只负责把 `AndroidAudioAttributes`（contentType/usage）设给 ExoPlayer，焦点申请完全交给 `audio_session`。

---

## 3. 核心实现 —— `AudioService`

文件：[audio_service_io.dart](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/core/services/audio_service_io.dart)

### 3.1 会话配置

[audio_service_io.dart#L75-L79](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/core/services/audio_service_io.dart#L75-L79)：`init()` 时调用 `AudioSession.instance.configure(AudioSessionConfiguration.music())`。

`AudioSessionConfiguration.music()` 会设置 `usage = media`、`contentType = music`，对应 Android 端申请 `AUDIOFOCUS_GAIN`（正常音乐播放的焦点，与来电/闹钟等独占焦点冲突时会被打断）。

### 3.2 焦点丢失/恢复处理（`interruptionEventStream`）

[audio_service_io.dart#L79-L109](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/core/services/audio_service_io.dart#L79-L109)：

**打断开始（`event.begin == true`）：**

| 中断类型 | 行为 |
|----------|------|
| `duck` | **忽略**（不降音量）。注释：修复荣耀平板 V8 Pro 音量忽高忽低，避免频繁 duck/unduck 造成波动 |
| `pause` | 若正在播放 → 置 `_pausedByInterruption = true` 并 `pause()` |
| `unknown` | 同上，按暂停处理 |

**打断结束（`event.begin == false`）：**

| 中断类型 | 行为 |
|----------|------|
| `duck` | **忽略**（不恢复音量，保持 1.0） |
| `pause` | 调 `tryResumeAfterFocusLoss()` 尝试自动恢复 |
| `unknown` | 忽略 |

### 3.3 拔耳机 / 蓝牙断开（`becomingNoisyEventStream`）

[audio_service_io.dart#L112-L117](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/core/services/audio_service_io.dart#L112-L117)：拔耳机/蓝牙断开会触发 `becomingNoisy`，此时同样置 `_pausedByInterruption = true` 并 `pause()`，复用与焦点丢失相同的恢复逻辑。

### 3.4 被动暂停标志位 `_pausedByInterruption`

[audio_service_io.dart#L67-L68](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/core/services/audio_service_io.dart#L67-L68)：

- **置位**：仅在两处 —— 焦点丢失（pause/unknown）和拔设备（becomingNoisy），表示"播放是被系统打断的"。
- **清除**：`play()`（[L137-L142](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/core/services/audio_service_io.dart#L137-L142)）、`stop()`（[L150-L153](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/core/services/audio_service_io.dart#L150-L153)）、以及 `tryResumeAfterFocusLoss()` 判定后。
- **不被修改**：外部主动调用 `pause()`（[L144-L148](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/core/services/audio_service_io.dart#L144-L148)）**不会**设置该标志。

### 3.5 自动恢复 `tryResumeAfterFocusLoss()`

[audio_service_io.dart#L127-L135](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/core/services/audio_service_io.dart#L127-L135)：仅当同时满足

1. `_pausedByInterruption == true`（是被动打断的）
2. `processingState == ready`（播放器已就绪）

才调用 `play()` 自动恢复。若播放器未 ready，则保留标志位等待后续 `playingStream` 变化再试。这样**用户手动暂停的歌曲在焦点事件来回时不会被"复活"**。

### 3.6 初始化入口

- [player_provider.dart#L200-L234](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/providers/player_provider.dart#L200-L234)：`PlayerProvider` 构造时 `_initAudioService()`，加载 `AudioService` 并 `init()`（内部 `configure` 音频会话、订阅焦点流）。
- [full_player.dart#L571](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/modules/player/full_player.dart#L571) / [full_player_am.dart#L293](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/modules/player/full_player_am.dart#L293)：两套播放页都用 `AudioService().androidAudioSessionId` 绑定均衡器等。

---

## 4. 特殊场景：歌曲识别页（采集系统音频）

文件：[song_recognition_page.dart#L106-L118](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/modules/recognition/song_recognition_page.dart#L106-L118)

悬浮窗听歌识曲 / 页内识曲启动时，把音频会话临时切为：

- `avAudioSessionCategory: playAndRecord`
- `androidAudioAttributes: (contentType: music, usage: media)`
- `androidWillPauseWhenDucked: false`

这是配合 `AudioPlaybackCapture + MediaProjection` 采集系统正在播放的音频（[L151-L170](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/modules/recognition/song_recognition_page.dart#L151-L170)，`audioSource: unprocessed`），与音频焦点无直接冲突，但会短暂改变全局会话配置。

---

## 5. USB 独占输出与音频焦点的关系

USB 独占输出（UAC1 DAC 直写，绕过 AudioFlinger）**没有单独处理音频焦点**，但焦点机制依然生效：

- 由于 `just_audio` 仍通过 `UsbAudioSinkController` 走 `play()` 流程，`audio_session` 在播放时照样申请 `AUDIOFOCUS_GAIN`。
- 来电等 `pause` 中断仍会触发 `_pausedByInterruption` 暂停恢复逻辑。
- `duck` 在全局被忽略（不降音量），因此 USB 独占模式下外部 duck 也不会压低音量。

相关文件：[usb_audio_service.dart](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/core/services/usb_audio_service.dart)、[usb_exclusive_section.dart](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/widgets/usb_exclusive_section.dart)。

---

## 6. 潜在问题与改进建议

1. **`duck` 被完全忽略**：全局不响应 duck 压低音量，虽然修复了荣耀平板音量波动，但会失去"导航提示音/语音助手播报时压低音乐"的体验。建议做成可配置开关，或仅对部分机型关闭。
2. **`unknown` 结束不恢复**：`begin=unknown` 会暂停，但 `end=unknown` 分支为空（[L105-L106](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/core/services/audio_service_io.dart#L105-L106)），理论上存在"被打断后无法自动恢复"的边界。
3. **焦点申请时机**：`AudioSessionConfiguration.music()` 由 `audio_session` 在播放状态切换时自动申请/释放，但本实现并**未显式调用** `AudioSession.beginInterruption` / `endInterruption` 这类精细化 API，策略完全依赖事件流，可读性尚可但控制粒度较粗。
4. **识别页与会话切换**：识别页 `configure` 会把全局会话切走，结束识别后需确认主播放器会话是否被正确恢复（[L287](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/modules/recognition/song_recognition_page.dart#L287) 有 `AudioSessionConfiguration.music()`，但需验证执行时序）。

---

## 7. 相关文件速查

| 文件 | 职责 |
|------|------|
| [audio_service_io.dart](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/core/services/audio_service_io.dart) | 焦点会话配置、中断事件处理、`_pausedByInterruption` 标志、自动恢复 |
| [player_provider.dart](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/providers/player_provider.dart#L200-L234) | 音频服务初始化入口 |
| [AudioPlayer.java](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/third_party/just_audio/android/src/main/java/com/ryanheise/just_audio/AudioPlayer.java#L850-L864) | ExoPlayer `handleAudioFocus=false`，关闭内部焦点 |
| [song_recognition_page.dart](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/modules/recognition/song_recognition_page.dart#L106-L118) | 识别页临时会话配置（playAndRecord） |
| [usb_audio_service.dart](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/core/services/usb_audio_service.dart) | USB 独占输出（焦点机制仍全局生效） |