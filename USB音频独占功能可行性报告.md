# USB 音频独占功能可行性报告

> 适用分支：`rust-local-two`（当前分支，Rust 架构）
> 日期：2026-08-08
> 结论速览：**可行，但"独占"存在三个层次，官方不提供真正意义的硬件独占；建议分阶段落地，v1 用系统路由（改动小、风险低），v2 上采样率匹配准直通，v3 才需要自研 UAC 直写（工作量大）。**

---

## 0. 决策记录（2026-08-08 用户确认）

| 决策项 | 结论 |
|--------|------|
| 目标层次 | **L1 采样率直通**（非 root 下的"准独占"：以 DAC 原生采样率输出、规避系统 SRC；不做 L2 UAC 直写） |
| DSD 支持 | **不需要**（排除 L2/root 路线的全部诉求，ExoPlayer 不支持的 DSD 不在范围内） |
| fork just_audio | **接受 fork**（L1 需要暴露 just_audio 原生层的路由/采样率钩子，fork 是既定路径） |

由此确定实施范围：**Phase 0（L0 路由基建）+ Phase 1（L1 采样率直通，fork just_audio）**；L2/root 路线移出本期范围，仅在远期备忘。

---

## 1. 需求定义：先厘清"独占"指什么

Android 系统层面**不存在**公开 API 让普通应用对 USB DAC 实现"硬件独占"（绕过系统混音器 AudioFlinger 直写设备）。因此不同播放器宣称的"USB 独占"实际指三个层次，必须先行对齐目标：

| 层次 | 含义 | 代表产品 |
|------|------|----------|
| **L0 路由独占** | 音频只从 USB DAC 输出，同时系统把 DAC 识别为媒体输出设备 | 所有音乐 App 的默认行为 |
| **L1 采样率直通（准独占）** | 以 DAC 原生采样率/位深输出，避免系统重采样（SRC），但数据仍过 mixer | Poweramp「Hi-Res」模式、多数国产播放器非独占档 |
| **L2 真独占** | App 通过 USB 音频类（UAC）协议直接向 DAC 写 PCM/DSD，绕过 Android 音频栈 | USB Audio Player PRO、海贝、FiiO、Neutron 的"USB 独占"档 |

> **关键认知**：L2 在**非 root** 下也是可行的（UAPP/海贝就是如此），不需要 root；root 只是另一条实现路径（直连 `/dev/snd`）。但 L2 需要自研 USB 驱动，工程量与风险都远高于 L0/L1。

---

## 2. 项目现状分析

### 2.1 当前音频播放链路

```
Flutter (Dart)
  └─ just_audio 0.10.6（pubspec.yaml 确认）
       └─ Android 侧 = Media3 / ExoPlayer
            └─ DefaultAudioSink → 系统 AudioTrack
                 └─ AudioFlinger mixer（混音 + 可能的重采样 SRC）
                      └─ usb_audio HAL → USB DAC / 内置扬声器等输出设备
```

关键事实（**本机实证**，`just_audio-0.10.6` 源码）：

- [AudioPlayer.java](file:///c:/Users/32732/AppData/Local/Pub/Cache/hosted/pub.dev/just_audio-0.10.6/android/src/main/java/com/ryanheise/just_audio/AudioPlayer.java) 仅调用 `ExoPlayer.setAudioAttributes(contentType/flags/usage)`，**没有**自定义 `AudioSink`、没有 `setPreferredDevice`、没有任何 USB 相关钩子。
- [audio_service_io.dart](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/core/services/audio_service_io.dart#L75-L78) 使用 `AudioSessionConfiguration.music()`（Media3 属性：usage=MEDIA, contentType=MUSIC）。
- 结论：**当前链路没有 USB 直通能力**，要改造必须先找到注入点（见 §4）。

### 2.2 项目已有的可复用基建（这是本报告认为"可行"的重要前提）

| 基建 | 位置 | 对 USB 功能的复用价值 |
|------|------|----------------------|
| 自定义原生插件范式 | [EqualizerPlugin.kt](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/android/app/src/main/kotlin/com/md3music/premium/EqualizerPlugin.kt)：MethodChannel 绑定 `androidAudioSessionId` 做原生音频控制 | 新插件 `UsbAudioPlugin` 可直接照此模式 |
| Kotlin 原生层 | `com.md3music.premium` 包，已有 Service/插件/小部件 | 加 USB 检测与路由逻辑 |
| Rust cdylib + JNI 工程 | `kugou_api_server/rust`（`libkugou_server.so`） | 若走 L2，UAC 驱动可放进 Rust crate 用 JNI 导出，与项目架构一致 |
| 设置页开关范式 | 设置页已有多种开关（蓝牙歌词等） | "USB 独占"开关直接复用 |

### 2.3 内容源特点（影响需求定位）

- **在线音乐**（酷狗）：AAC/MP3，44.1kHz 有损，**USB 独占价值低**——重采样对听感影响可忽略。
- **本地音乐**：可能含 FLAC/WAV 高解析，**这才是 USB 独占的核心价值场景**。
- DSD：ExoPlayer 不支持解码，L0/L1 方案完全无法覆盖 DSD，只有 L2 才可能（DoP/原生）。

> 建议：若目标是"发烧友本地高解析播放"，L2 才有意义；若只是"插上 DAC 声音更干净"，L0/L1 足够。

---

## 3. 技术背景：Android USB 音频事实核查

（以下为公开技术事实，标注"待真机验证"的项需在目标设备上实测确认）

1. **系统级支持**：Android 5.0 起支持 USB 音频类 1.0（UAC1），6.0 起支持 2.0（UAC2）。插上 USB DAC 后系统自动将其枚举为音频输出设备，媒体声音默认自动切换过去。
2. **无公开独占 API**：`AudioTrack`/`AAudio` 最终都过 mixer。`AUDIO_OUTPUT_FLAG_DIRECT`（真正直通 flag）**仅系统可用**，应用无法设置。
3. **AAudio 的 `AAUDIO_SHARING_MODE_EXCLUSIVE` 是误区**：它独占的是一条"快速混音线程"，不是 USB 设备，也不保证位完美——不能用它实现独占。
4. **采样率重采样（SRC）是核心质量损失点**：mixer 通常把 track 采样率转成输出设备当前采样率（默认 48kHz）。44.1kHz 内容 → 48kHz 输出 = 一次 SRC。
5. **准直通的理论基础（待真机验证）**：AOSP `usb_audio` HAL 支持随打开的 stream 动态切换 DAC 采样率（44.1/48kHz 家族）。部分机型上，以 44.1kHz 打开 AudioTrack 时 HAL 会把 DAC 切到 44.1kHz → 无 SRC。**此行为由 OEM 固件决定，非官方保证**，Poweramp 等正是赌这条路径。
6. **路由 API**：`AudioTrack.setPreferredDevice()`（API 23+）、`AudioManager.getDevices()` 可查询 DAC（`TYPE_USB_DEVICE/HEADSET/ACCESSORY`）、`AudioDeviceInfo.getSampleRates()` 可读 DAC 原生采样率、Android 12+ 有 `AudioManager.setCommunicationDevice()`。
7. **L2 的技术路径**：`UsbManager` 枚举 → 授权（系统弹窗）→ claim 音频 interface → UAC 控制请求切换采样率 → 独立线程向 isochronous OUT endpoint 写 PCM/DSD。**主流发烧播放器均为此路线**；root 机器另有 `/dev/snd` ALSA 直连路线。
8. **Flutter 生态现状（本机实证）**：pub.dev 上 `flutter_usb_audio`、`usb_audio` **均不存在**（API 返回 404）。Flutter 生态**没有可用的现成 USB DAC 输出插件**——L2 只能自研，或参考开源实现自行移植。

---

## 4. 方案对比与可行性评估

### 方案 A：L0 系统路由 + 独占开关（v1，强烈建议先做）

**做法**：新增 `UsbAudioPlugin`（MethodChannel）：
- 监听 USB 设备插拔（`UsbManager.ACTION_USB_DEVICE_ATTACHED/DETACHED` + `ACTION_AUDIO_BECOMING_NOISY`），并轮询 `AudioManager.getDevices()` 识别 DAC；
- 展示 DAC 信息（名称/采样率/位深）到设置页；
- "USB 独占"开关：开启后强制媒体路由到 DAC（`setPreferredDevice` / `setCommunicationDevice`），并在拔插时给出提示/暂停处理。

**可行性：高**。改动集中在 Kotlin 插件 + 设置页 Dart，与现有 EqualizerPlugin 模式完全一致，不触碰播放链路。

**局限**：无 bit-perfect 保证，SRC 仍可能发生。但可以诚实宣传为"USB 输出优先"。

### 方案 B：L1 采样率匹配准直通（v2，本期已定）

**做法**：在 A 基础上，播放前读取 DAC 原生采样率，设法让输出以该采样率进行，规避 SRC。**本方案已确定为实施目标**，fork 路径已确认。

**技术要点（fork just_audio 后要做的三件事）**：
1. **暴露路由钩子**：在 fork 的 `AudioPlayer.java` 中对 ExoPlayer 的 `AudioTrack` 做 `setPreferredDevice()`（just_audio 上游未实现该能力，这是 fork 的核心动机）——保证媒体音频稳定路由到 USB DAC；
2. **输出采样率跟随源**：ExoPlayer 的 `DefaultAudioSink` 本就以解码器输出格式（如 44.1kHz）创建 AudioTrack，无需改采样率——关键在于真机验证 usb_audio HAL 是否随 track 采样率切换 DAC（见风险 2）；如个别机型不切换，再考虑自定义 `AudioSink` 强制匹配 DAC 采样率；
3. **DAC 信息通道**：fork 中暴露当前输出设备/采样率状态，供设置页展示与调试（对齐 `dumpsys media.audio_flinger`）。

**可行性：中**。核心不确定项仍是 **OEM 固件是否走无 SRC 路径**，需真机矩阵验证；fork 只解决"路由与信息暴露"，不改变 HAL 行为。

### 方案 C：L2 UAC 直写真独占（v3，非 root 完全体）

**做法**：自研 UAC1/UAC2 驱动：
- Kotlin 侧：`UsbManager` 枚举/授权/claim interface；
- 传输层：控制请求（SET_CUR 采样率）+ isochronous OUT endpoint 写帧 + 时钟/背压控制；
- 数据来源：与播放链路对接是最大难点——
  - 路径 C1：**fork just_audio，自定义 Media3 `AudioSink` 把 PCM 送入 UAC 通道**（保留 just_audio 的解码/缓冲/进度体系）；可行但维护成本高（fork 要长期跟进上游）。
  - 路径 C2：**独立自研解码→PCM 通道**：`MediaCodec` 解码本地 FLAC/WAV → PCM → JNI/Rust → UAC。绕开 just_audio，独占模式与普通模式两套播放器并存，切换逻辑复杂。
  - 路径 C3：Rust 侧实现 UAC 驱动（复用 `libkugou_server.so` 的 JNI 工程模式），Dart 只做搬运。

**可行性：低~中**。参考实现均为闭源商业产品（UAPP/海贝），无成熟开源库可抄；工程量大（预计是 B 的 3~5 倍），且要处理与系统 usb_audio HAL 抢占 DAC 的冲突（部分机型系统提示音会打断独占输出）。

### 方案 D：L2 root 直连 ALSA（v3 的 root 变体）

**做法**：root 下以原生代码打开 `/dev/snd/pcmC*D*p`，ioctl 配置 HW params 后直接写帧，绕过整个 Android 音频栈，天然位完美，可支持 DSD。

**可行性：中**（技术上最干净），但**受众极窄**（需 root），不建议作为主路线，可作远期彩蛋。

### 对比总表

| 维度 | A（路由独占） | B（采样率直通） | C（UAC 直写） | D（root ALSA） |
|------|--------------|----------------|--------------|----------------|
| 是否真独占 | 否 | 否（准直通） | 是 | 是 |
| Bit-perfect 保证 | 无 | OEM 相关 | 有 | 有 |
| DSD 支持 | 无 | 无 | 可支持(DoP) | 可支持 |
| 改动范围 | 小（插件+设置页） | 中（需 fork just_audio 或自建播放路径） | 大（自研驱动+播放链路改造） | 大 + root |
| 主要风险 | 低 | 效果因 OEM 而异 | 工程量大、抢占冲突 | 受众窄 |
| 建议 | **v1 实施** | **v2 评估后再定** | v3 远期 | 不推荐 |

---

## 5. 关键技术风险清单

| # | 风险 | 影响 | 缓解 |
|---|------|------|------|
| 1 | just_audio 无路由/采样率钩子（已实证） | B 需 fork 或自建播放路径 | **已决策：fork just_audio 0.10.6**，暴露 setPreferredDevice/状态；长期跟随上游 |
| 2 | 无 SRC 直通依赖 OEM 固件 | B 效果不达预期 | 真机矩阵验证；如实宣传"尽力直通" |
| 3 | 与系统 usb_audio HAL 抢占 DAC | C 中系统提示音打断/冲突 | 授权引导 + 失败重连 + 提示音期间降级 |
| 4 | USB 授权弹窗打断体验 | 首次连接体验差 | 引导页说明 + 记住授权 |
| 5 | UAC 高采样率背压/时钟不稳 | C 中爆音、overrun | 帧计数 + 系统时钟节流 |
| 6 | 均衡器/音量/音频焦点交互 | 独占模式与现有 Equalizer 冲突（audiofx 绑 session） | L2 独占时禁用均衡器并提示 |
| 7 | 插件长期维护 | Flutter 生态无现成方案，自研即长期负债 | 架构上把 UAC 层独立为可替换模块 |

---

## 6. 建议路线图（分阶段，每阶段可独立验收、可回退）

> 遵循"最小改动先落地"原则：先让用户用上 USB 输出增强（A），再按需升级。

**Phase 0 — 方案 A（v1，L1 的前置基建）**
- 新增 Kotlin `UsbAudioPlugin`：DAC 检测 + 信息展示 + 路由独占开关 + 拔插提示；
- 设置页新增「USB 音频」分组；
- 验收：插上 DAC 后设置页显示设备名/采样率；开关生效后媒体声音仅从 DAC 出；拔插时播放不崩溃、有提示。

**Phase 1 — 方案 B（v2，本期已定，fork just_audio）**
- fork just_audio（0.10.6）为本地依赖，在 `AudioPlayer.java` 暴露 `setPreferredDevice` + 输出设备/采样率状态；
- 真机实测（3~5 台主流机型，44.1/48kHz FLAC 经 DAC 输出，用 `dumpsys media.audio_flinger` 验证是否发生 SRC）；
- 若个别机型 HAL 不切换采样率，评估自定义 `AudioSink` 强制匹配 DAC 采样率的补救；
- 验收：`dumpsys media.audio_flinger` 可观测到输出采样率 = DAC 原生采样率（或明确记录机型差异表）；与普通输出对照听感无劣化。

**Phase 2 — 方案 C/D（远期备忘，本期不做）**
- 用户已确认本期不做 L2 UAC 直写与 DSD；若未来有发烧需求，再以技术预研 spike 立项。

---

## 7. 涉及模块与工作量粗估

| 模块 | 文件 | 改动 |
|------|------|------|
| Kotlin 插件 | 新增 `UsbAudioPlugin.kt`；改 `MainActivity.kt` 注册 | A：~300 行 |
| fork just_audio（L1） | pubspec 指向本地 fork；`AudioPlayer.java` 暴露 setPreferredDevice/状态 | 原生 + Dart API 少量，长期跟随上游 |
| Dart 服务 | 新增 `usb_audio_service.dart`（照 `equalizer_service.dart` 模式） | A：~200 行 |
| 设置页 | 设置页相关 Dart | A：~150 行 |

> 不做时间承诺；A 为最小可行增量，B/C 需按 Phase 1/2 的实测结论再定。

---

## 8. 验收标准（对每个 Phase 可验证）

- **A**：DAC 插拔被检测并正确展示；开关状态持久化；拔插不崩溃；`AudioManager.getDevices()` 结果与设置页一致。
- **B**：`dumpsys media.audio_flinger` 可观测到输出采样率 = DAC 原生采样率；与 A 对照听感无劣化。
- **C**：独占播放期间系统音量/提示音不影响 DAC 输出（或明确降级提示）；DSD 文件可播放（DoP）；拔插热切换无爆音。

---

## 9. 结论

1. **已确认实施 L1 采样率直通（非 root 准独占）**：以 DAC 原生采样率输出、规避系统 SRC；不做 DSD、不做 L2 UAC 直写。
2. **推荐路径（按决策收敛）**：**Phase 0（方案 A：DAC 检测 + 路由 + 开关）先行**，它是 Phase 1 的检测/路由基建；**Phase 1（方案 B：fork just_audio 暴露 setPreferredDevice + 采样率状态）**是本期主体。
3. **本期最大不确定项**：L1 的"无 SRC"效果最终由 **OEM 固件**决定，fork 只解决路由与信息暴露、不改变 HAL 行为——Phase 1 必须以真机矩阵实测（`dumpsys media.audio_flinger`）为验收准绳，如实呈现机型差异。
4. **Fork 是既定路径**（用户已确认）：just_audio 上游无 setPreferredDevice 能力（已实证），fork 0.10.6 是唯一低破坏的接入方式；需接受长期跟随上游的维护成本。
5. Flutter 生态无现成插件（已实证 pub.dev 上不存在），不存在"捡现成"选项。

---

## 附：本报告的事实来源与置信度

| 事实 | 置信度 | 来源 |
|------|--------|------|
| just_audio 仅 setAudioAttributes、无 USB 钩子 | 高（本机读源码实证） | `just_audio-0.10.6` 源码 |
| flutter_usb_audio / usb_audio 包不存在 | 高（本机 API 实证） | pub.dev API 返回 404 |
| 项目插件范式/音频链路 | 高（本机读代码实证） | 仓库 `lib/`、`android/` |
| Android 无公开独占 API；AAudio EXCLUSIVE 语义 | 中（知识库，待联网复核） | developer.android.com AAudio/AudioTrack 文档 |
| UAPP/海贝等走 UsbManager+UAC（非 root） | 中（知识库） | 各厂商官网 FAQ |
| AOSP usb_audio HAL 动态采样率切换 | 中（知识库） | source.android.com/docs/core/audio/usb |
| 采样率直通效果随 OEM 变化 | 高（行业共识） | XDA/Head-Fi 讨论 |

> 报告中"待真机验证"的项，建议 Phase 0 完成后用 3~5 台设备实测再定 Phase 1。
