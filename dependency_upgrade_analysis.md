# MD3Music 依赖升级可行性分析

> 目标：评估 `flutter pub get` 提示的 32 个「有可用新版」依赖中，哪些可以安全升级且不影响现有功能。
> 分析依据：`pubspec.yaml` / `pubspec.lock` 约束、`third_party/just_audio` 本地 fork 的约束、Android 构建配置（AGP 9.0.1 / Kotlin 2.3.20 / compileSdk 36），以及仓库内对每个依赖的实际调用点。

---

## 0. 结论速览

| 结论 | 依赖 |
|------|------|
| ✅ **可安全升级**（minor/patch，API 兼容） | `flutter_cache_manager`、`dynamic_color`、`chewie`、`video_player`、`webview_flutter_android`、`permission_handler_apple`、`material_color_utilities`、`hooks`、`meta`、`matcher`、`test_api`、`vector_math` |
| ⚠️ **可升级但需回归验证**（major 或跨版本，API 大概率兼容） | `record`（+ 联邦）、`permission_handler`(+android)、`package_info_plus`(+platform_interface)、`sqflite`、`intl`、`audio_session`、`audio_metadata_reader`、`wakelock_plus`、`win32`、`xml` |
| ❌ **不建议升级 / 保持不动** | `just_audio`（本地 fork，USB 独占核心）、`just_audio_background`（beta，联动音频链路）、`palette_generator`（已 discontinued，无新版） |

**关键前提**：项目 Android 已用 **AGP 9.0.1 + Gradle 9 + Kotlin 2.3.20 + compileSdk 36**，满足 `record 7`、`package_info_plus 10`、`permission_handler 14` 等最新联邦插件的最低构建要求，这是它们能升级的硬性条件。

---

## 1. 本地 fork 约束（决定 audio_session 能否升级）

`just_audio`（本地 fork `third_party/just_audio`，0.10.6）与 `just_audio_background`（0.0.1-beta.17）对 `audio_session` 的约束均为：

```yaml
audio_session: ">=0.1.24 <0.3.0"
```

- `audio_session` 当前 **0.1.25** → 可用新版 **0.2.4**，**在约束范围内**，可解析升级。
- 但 0.1.x → 0.2.x 是**次版本提升**，属于类 major 变更，音频焦点是核心链路（见 §8），**必须回归**。

---

## 2. 各依赖逐一分析

### 2.1 可安全升级（低风险，建议直接升）

| 依赖 | 当前 | 可用 | 类型 | 说明 |
|------|------|------|------|------|
| `flutter_cache_manager` | 3.4.1 | 3.4.2 | patch | 纯 bugfix，无 API 变更 |
| `dynamic_color` | 1.8.1 | 1.9.0 | minor | [theme_provider.dart](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/providers/theme_provider.dart) 仅用 `DynamicColorBuilder`，1.9 保留该 API |
| `chewie` | 1.13.1 | 1.15.0 | minor | [mv_player_page.dart](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/modules/player/mv_player_page.dart) 用 `ChewieController`，接口稳定 |
| `video_player` | 2.13.0 | 2.14.0 | minor | 与 chewie 配套，2.14 为版本号修正，无破坏 |
| `webview_flutter_android` | 4.13.0 | 4.14.0 | minor | 主包 `webview_flutter` 保持 4.14.1，仅升 Android 实现子包 |
| `permission_handler_apple` | 9.5.0 | 9.6.1 | minor | iOS 端微调，随 `permission_handler` 一起升 |
| `material_color_utilities` | 0.13.0 | 0.13.1 | patch | 纯内部算法修正 |
| `hooks` | 2.0.2 | 2.1.0 | minor | 传递依赖，无直接调用 |
| `meta` | 1.18.0 | 1.19.0 | patch | Dart 核心注解包，全兼容 |
| `matcher` | 0.12.19 | 0.12.20 | patch | dev/传递依赖 |
| `test_api` | 0.7.11 | 0.7.13 | patch | dev/传递依赖 |
| `vector_math` | 2.2.0 | 2.4.2 | minor | 传递依赖，无直接调用 |

> 这些可直接执行 `flutter pub upgrade` 跟进，不影响现有功能。

### 2.2 可升级但需回归验证（谨慎升）

| 依赖 | 当前 | 可用 | 风险点 / 回归范围 |
|------|------|------|------|
| `record` | 6.2.1 | 7.1.1 | **major**。7.0 移除 Android 后台录音服务 + iOS 移除 `manageAudioSession` 配置。项目 [song_recognition_page.dart](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/modules/recognition/song_recognition_page.dart) 用**前台录音** + `AudioRecorder`/`RecordConfig`/`start`/`stop`/`hasPermission`，这些 API 在 7.x 保留。回归：**听歌识曲** |
| `record_android` | 1.5.2 | 2.1.2 | record 联邦插件，随 `record` 一起升 |
| `record_ios` | 1.2.1 | 2.1.1 | 同上 |
| `record_linux` | 1.3.1 | 2.1.1 | 同上 |
| `record_macos` | 1.2.2 | 2.1.1 | 同上 |
| `record_platform_interface` | 1.6.0 | 2.1.0 | 同上 |
| `record_use` | 0.6.0 | 1.1.0 | 同上 |
| `record_web` | 1.3.0 | 2.1.2 | 同上 |
| `record_windows` | 1.0.7 | 2.2.3 | 同上 |
| `permission_handler` | 12.0.3 | 13.0.1 | **major**。Android 权限处理重构（13.0 起需 AGP 8.12+，项目 9.0 满足）。项目用 `Permission.microphone/storage` 等，枚举保留。回归：**麦克风/存储权限弹窗** |
| `permission_handler_android` | 13.0.1 | 14.0.0 | 随 `permission_handler` 一起升 |
| `package_info_plus` | 8.3.1 | 10.2.1 | **跨两大版本**。10.0 起需 Flutter ≥3.41.6 / Dart ≥3.11（项目 3.12 满足），并升级 `win32 5→6`。[settings_page.dart](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/modules/settings/settings_page.dart) 用 `PackageInfo.fromPlatform()`，API 稳定。回归：**设置页版本号显示** |
| `package_info_plus_platform_interface` | 3.2.1 | 4.1.0 | 随 `package_info_plus` 一起升 |
| `sqflite` | 2.3.3+1 | 2.4.3 | **major**。注意 pubspec 中为**固定版本** `2.3.3+1`（非 `^`），需手动改约束。sqflite 2.4 底层基于 `sqflite_common`，API `openDatabase` 等保留。回归：**本地数据库（收藏/历史/设置/缓存）** |
| `intl` | 0.19.0 | 0.20.3 | **major**。0.20 调整 `DateFormat`/`NumberFormat` 解析行为。[main.dart](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/main.dart) 用 `date_symbol_data_local`，[user_center_page.dart](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/modules/user/user_center_page.dart) 用 `DateFormat`。回归：**日期/时间显示** |
| `audio_session` | 0.1.25 | 0.2.4 | 次版本提升（见 §8，音频焦点核心） |
| `audio_metadata_reader` | 1.4.1 | 1.7.1 | 跨版本。`readMetadata` API 保留，[audio_scanner.dart](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/core/utils/audio_scanner.dart) 等 4 处用 `readMetadata(file, getImage:)`。回归：**本地音频扫描/封面提取** |
| `wakelock_plus` | 1.3.3 | 1.7.0 | 传递依赖（经 just_audio 链路引入），无直接调用 |
| `win32` | 5.15.0 | 6.4.0 | 传递依赖，随 `package_info_plus` 10 自动升级 |
| `xml` | 6.6.1 | 7.0.1 | 传递依赖，无直接调用 |

### 2.3 不建议升级

| 依赖 | 当前 | 说明 |
|------|------|------|
| `just_audio` | 0.10.6（本地 fork） | **绝不能动**。fork 注入 `RenderersFactory` 拦截 AudioSink 以实现 USB 独占输出。升级会破坏核心功能 |
| `just_audio_background` | 0.0.1-beta.17 | beta 版本，与 `just_audio` fork + `audio_session` 强耦合，无必要不升 |
| `palette_generator` | 0.3.3+7 | 已 **discontinued**，无新版。保持现状即可 |

---

## 3. 建议的升级顺序

**第一步（无风险，直接做）**：12 个低风险包

```bash
flutter pub upgrade flutter_cache_manager dynamic_color chewie video_player webview_flutter_android permission_handler_apple material_color_utilities hooks meta matcher test_api vector_math
```

**第二步（先改约束再升级，每类单独做并回归）**

1. **音频链路**：`audio_session`（0.1.25 → 0.2.x）→ 回归音频焦点。**必须**验证 `audio_service_io.dart` 的 `interruptionEventStream` / `becomingNoisyEventStream` 逻辑。
2. **录音识曲**：`record` 6→7（含全部联邦子包）→ 回归听歌识曲。
3. **权限**：`permission_handler` 12→13（含 android/apple）→ 回归权限请求。
4. **包信息**：`package_info_plus` 8→10（含 platform_interface）→ 回归设置页版本号。
5. **数据库**：`sqflite`（改固定版本 `2.3.3+1` → `^2.4.3`）→ 回归收藏/历史/设置。
6. **本地化**：`intl` 0.19 → 0.20 → 回归日期显示。
7. **元数据**：`audio_metadata_reader` 1.4 → 1.7 → 回归扫描/封面。

> 每走完一步跑 `flutter analyze` + 真机回归对应功能，再走下一步，避免一次升级太多导致问题难定位。

---

## 4. 风险最高项详解：`audio_session` 0.2.x

- [audio_service_io.dart](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/core/services/audio_service_io.dart) 是音频焦点核心，直接使用 `AudioSession.instance`、`configure(AudioSessionConfiguration.music())`、`interruptionEventStream`、`becomingNoisyEventStream`、`AudioInterruptionType`。
- [song_recognition_page.dart](file:///c:/Users/32732/Desktop/TRAE%20SOLO/private_md3music/lib/modules/recognition/song_recognition_page.dart) 识曲时也 `configure` 音频会话。
- 0.2.x 若这些 API 有签名变化，会直接编译报错（可即时发现），但**运行时焦点行为**（duck/pause/unknown 恢复）需真机回归：来电中断、其他 App 抢焦点、拔耳机。

---

## 5. 附：`flutter pub outdated` 提示的 discontinued 包

- `palette_generator`（0.3.3+7）已 discontinued，无替代升级，保持现状。

---

## 6. 参考

- 依赖约束：`pubspec.yaml`、`pubspec.lock`
- 本地 fork 约束：`third_party/just_audio/pubspec.yaml`、pub 缓存 `just_audio_background-0.0.1-beta.17/pubspec.yaml`
- Android 构建：`android/settings.gradle.kts`（AGP 9.0.1 / Kotlin 2.3.20）、`android/app/build.gradle.kts`（compileSdk 36 / targetSdk 35 / ndk 28.2）
- 官方 changelog：record 7.0.0（移除后台录音服务 & manageAudioSession）、package_info_plus 10.0.0（win32 6、Flutter 3.41.6/Dart 3.11）