import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/repositories/settings_repository.dart';
import '../../data/repositories/song_match_repository.dart';
import '../../data/models/song.dart';
import '../../main.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/lyric_request_lifecycle.dart';
import '../../providers/theme_provider.dart';
import '../../core/layout/ui_density.dart';
import '../../core/utils/app_toast.dart';
import '../../core/utils/artwork_color_extractor.dart';
import '../../core/utils/local_lyric_loader.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import '../../widgets/apple_lyrics/layout/lyric_preferences.dart';
import '../../widgets/apple_lyrics/parsers/lyric_parser_chain.dart';
import '../../widgets/apple_lyrics/utils/lyric_credit_filter.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../services/kugou_api/lyric_lookup_result.dart';
import 'media_notification_service.dart';
import 'lyric_info_json_builder.dart';

/// 解析歌词文本，超过 32KB 时移入 isolate。
///
/// KRC + 翻译 + 罗马音整曲可达上百 KB，主 isolate 解析会在切歌瞬间
/// 掉帧；小文本直接解析（isolate spawn 本身有开销，不划算）。
Future<List<LyricLine>> parseLyricOffMainThread(
  String text, {
  String? translationText,
  String? romaText,
}) async {
  if (text.length <= 32 * 1024) {
    return LyricParserChain.parse(
      text,
      translationText: translationText,
      romaText: romaText,
    );
  }
  return compute(_parseInIsolate, (text, translationText, romaText));
}

List<LyricLine> _parseInIsolate((String, String?, String?) input) {
  return LyricParserChain.parse(
    input.$1,
    translationText: input.$2,
    romaText: input.$3,
  );
}

/// 锁屏歌词轻量进度节流：整包推送会重置基线；播放状态变化立即推送，
/// 常规进度最多每 500ms 一次。
class LockScreenProgressPushGate {
  int _lastPushMs = 0;
  bool? _lastIsPlaying;

  void markFullPush({required int nowMs, required bool isPlaying}) {
    _lastPushMs = nowMs;
    _lastIsPlaying = isPlaying;
  }

  void reset() {
    _lastPushMs = 0;
    _lastIsPlaying = null;
  }

  bool shouldPush({required int nowMs, required bool isPlaying}) {
    if (_lastIsPlaying == isPlaying && nowMs - _lastPushMs < 500) {
      return false;
    }
    _lastPushMs = nowMs;
    _lastIsPlaying = isPlaying;
    return true;
  }
}

/// 桌面歌词服务：管理开关、解析歌词（KRC/LRC/纯文本）、按播放位置同步到原生悬浮窗。
///
/// **关键修复**：之前用 `displayLyric`（KRC 优先）+ LRC 正则解析，导致 KRC 文本
/// 解析全部失败、悬浮窗永远显示「暂无歌词」。现改用 [LyricParserChain.parse]
/// 自动识别 KRC/LRC/纯文本，输出统一 [LyricLine] 列表。
///
/// **逐字支持**：KRC 解析后每行携带 [LyricWord] 字级时间戳，逐字时间戳随行切换
/// 整行一次下发（words + positionMs），原生按本地时钟自驱动逐字推进。
/// LRC/纯文本无字时间戳时 words 为空，原生侧走整行渐变色（保持原行为）。
///
/// 桌面平台（Windows / macOS / Linux）没有 Android 那套"悬浮窗授权"概念，
/// 提示文案与失败原因都不同，故用 [defaultTargetPlatform] 判定而不引 `dart:io`，
/// 保持本文件的 Web 可编译性。
bool get _isDesktopPlatform {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;
}

class DesktopLyricService {
  static final DesktopLyricService instance = DesktopLyricService._();
  DesktopLyricService._() {
    // AM 歌词偏好变化（字号/行距/字重/字体/副行/动态取色）→ 锁屏歌词跟随重推
    LyricPreferences.instance.addListener(_onLyricPrefsChangedForLockScreen);
    // md3 fork（#147 恢复链第二环）：巡检「原生窗口在跑而 Dart 侧认为关」，
    // 任何入口开的悬浮窗都能在 5s 内自动接上歌词推送（见 _probeNativeWindow）。
    _startNativeSyncProbe();
  }

  PlayerProvider? _player;
  KugouProvider? _kugou;
  // 「显示大小」：悬浮窗是原生 overlay、不在 Flutter 树里，DisplayScaleScope
  // 够不到它，所以把档位随配置下发给原生，由它乘在歌词字号上。
  ThemeProvider? _theme;
  final SettingsRepository _settings = SettingsRepository();

  bool _enabled = false;
  bool get enabled => _enabled;

  // 蓝牙歌词开关：独立于悬浮窗。ColorOS SystemUI 与 AVRCP 共用 MediaSession，
  // 4.0 接入后原生端必须保持稳定 title/artist，因此不再用该通道改写会话身份。
  bool _bluetoothLyricEnabled = false;
  bool get bluetoothLyricEnabled => _bluetoothLyricEnabled;

  // LyricInfo 歌词转发开关：通过 MediaSession extras.lyricInfo 发布整首歌词
  // （LRC/ELRC），供 ColorOS 桌面歌词 / LyricInfo 模块等第三方系统读取。
  // 复用本服务的定时器与歌词解析管线，歌词加载完成后构造 JSON 推送一次。
  bool _lyricInfoEnabled = false;
  bool get lyricInfoEnabled => _lyricInfoEnabled;
  // 当前歌曲是否已推送过 lyricInfo（避免每 250ms tick 重复推送）
  bool _lyricInfoPushed = false;
  // ColorOS Bridge 兼容模式：开启后 lyricInfo JSON 输出 lyric=纯 LRC +
  // rawLyric=ELRC 逐字（插件据此启用逐字高亮等增强）；关闭保持 ELRC+format 格式
  bool _lyricInfoColorOs = true;
  bool get lyricInfoColorOs => _lyricInfoColorOs;

  // 锁屏歌词开关：独立于悬浮窗/蓝牙歌词/LyricInfo。开启时定时器运行，
  // 推送整首歌词到原生 LockScreenLyricActivity（锁屏全屏滚动歌词列表，
  // 与 AM 播放页 Zen 沉浸模式视觉对齐；样式全部跟随 AM 歌词偏好）。
  bool _lockScreenLyricEnabled = false;
  bool get lockScreenLyricEnabled => _lockScreenLyricEnabled;

  // 锁屏歌词推送状态（新协议：全量数据 + 轻量进度分离）
  // - 全量脏标记：切歌 / 歌词加载完成 / AM 歌词偏好变化时置位，下个推送点整包重推
  bool _lockFullDirty = false;
  // - 无歌词列表时的占位文本（歌词加载中.../暂无歌词/歌词加载失败）
  String _lockPlaceholder = '';
  // - 进度节流：上次轻量进度推送时刻与播放态（播放态翻转时立即推）
  final LockScreenProgressPushGate _lockProgressPushGate =
      LockScreenProgressPushGate();
  // - 封面主色提取令牌：切歌自增，异步结果回来时校验避免串歌
  int _lockAccentToken = 0;
  // - 收藏态回流基线（歌 id + 值）：锁屏卡片红心与 App 内/通知栏同源，
  //   只在实际翻转时推一次轻量通道，避免连续 notifyListeners 打出无谓通道调用
  String? _lockFavoriteSongId;
  bool? _lockFavoriteValue;
  // - FavoritesProvider 绑定（惰性绑一次，换实例才重绑）
  FavoritesProvider? _favorites;

  // SuperLyric 歌词推送开关：基于 Binder 的系统级实时歌词 API。
  // 复用本服务的定时器与歌词解析管线，在切歌 / 歌词行变化时推送当前行
  // （text/words/翻译/副歌词 + title/artist）；播放/暂停由 SuperLyric 自动
  // 监听 App 的 MediaSession 处理（sendStop），本服务不手动发送停止事件。
  bool _superLyricEnabled = false;
  bool get superLyricEnabled => _superLyricEnabled;

  // 魅族 Flyme 状态栏歌词：复用本服务的定时器与解析管线，仅在 LRC 行切换时把当前行
  // 文本推给原生，由原生贴到 Media3 媒体通知的 tickerText 上（Flyme 私有 flag 渲染）。
  // 只发行级文本，绝不下发 KRC 字级时间戳 —— notify() 有系统级限流，逐字刷会被封闭。
  bool _flymeStatusBarLyricEnabled = false;
  bool get flymeStatusBarLyricEnabled => _flymeStatusBarLyricEnabled;

  /// 魅族状态栏歌词「提前量」（ms，>=0）：用「播放位置 + 提前量」来选行，
  /// 让这一路比音频略早翻行。
  ///
  /// 为什么需要：状态栏歌词是"通知驱动"的，一条歌词从 Dart 决定翻行到真正画出来，
  /// 要经过 MethodChannel → notify() → SystemUI 取通知并重绘，这段延迟在 100ms 量级
  /// 且不在我们掌控内；再叠加 LRC 时间戳普遍标在"字已出声"之后，合起来就是
  /// 肉眼看到的"唱出来了字才出现"。提前量用来把这段固定损耗抵掉。
  ///
  /// 为什么单独一套索引/迟滞/Timer，而不是改 _currentLineIndex 或 posMs：
  /// 那个索引与迟滞时间戳是悬浮窗、蓝牙、SuperLyric、锁屏等所有通道共用的，
  /// 改它会把这些通道一起提前；而 posMs 还喂给 _pushLyric(positionMs:) 和进度节流。
  int _flymeAdvanceMs = 0;
  int get flymeAdvanceMs => _flymeAdvanceMs;
  int _flymeLineIndex = -1;
  Timer? _flymeLineTimer;
  DateTime? _flymeLastSwitchAt;

  /// 上一次观测到的播放位置（ms），-1 表示尚未采样。
  /// 只用来判定"位置真的往回走了"，见 [_tickFlymeAdvance]。
  int _flymePrevPosMs = -1;
  // 共用偏好（设置页三种推送协议共用一份）：
  // - 翻译歌词开关：是否推送翻译（影响 SuperLyric 与 LyricInfo）
  bool _pushTranslation = true;
  // - 罗马音歌词开关：是否推送罗马音（影响 SuperLyric）
  bool _pushRoma = false;
  // - 同时存在翻译和罗马音时是否优先推送翻译（参照 Lyricon preferTranslation）。
  //   开启：保留 translation、丢弃 roma；关闭：保留 roma、丢弃 translation。
  //   SuperLyric 接收端对同时携带两字段的数据会优先显示 secondary(roma)，故需在 Dart 侧过滤。
  bool _superLyricPreferTranslation = true;

  String? _currentSongId;
  // 解析后的歌词行列表（统一模型，KRC 含 words，LRC/纯文本 words 为空）
  // 注：本列表是**经「屏蔽歌词作者信息」过滤后**的显示口径，推送链
  // （悬浮窗 / 锁屏 / LyricInfo / SuperLyric / Flyme）全部读它。
  List<LyricLine> _lines = const [];
  // 未经过滤的完整解析结果：过滤开关/正则变化时由此即时重派生 _lines。
  List<LyricLine> _rawLines = const [];
  // 上次派生 _lines 时的过滤开关/正则快照：无关偏好通知不重复重派生。
  bool _derivedFilterEnabled = false;
  String _derivedFilterPattern = '';
  int _currentLineIndex = -1;
  // 行切换迟滞时间戳：position 抖动时抑制行来回跳变、重复推送（蓝牙歌词高频刷新根因之一）
  DateTime? _lastLineSwitchAt;
  Timer? _ticker;
  // 播放中 250ms（行检测+逐字调度精度）；暂停后 1s（仅剩对账与切歌检测）
  static const int _tickIntervalPlayingMs = 250;
  static const int _tickIntervalPausedMs = 1000;
  int _tickIntervalMs = _tickIntervalPlayingMs;
  // 行边界预测 Timer：行提交后安排一次性触发，让切行不受 250ms 轮询相位限制
  Timer? _lineTimer;
  bool _awaitingLyric = false;
  int _lyricFetchToken = 0;
  int _sessionGeneration = 0;
  bool _lastPushedPlaying = false;
  // 歌词拉取退避：临时失败按 250ms→10s 指数退避，确认无词按5分钟冷却，
  // 防止播放期间重复请求；错误状态分别显示给歌词消费者。
  String? _lyricFailedKey;
  int _lyricFailCount = 0;
  DateTime? _lyricNextRetryAt;
  // 屏幕亮灭（FloatingLyricService SCREEN_OFF/ON 转发）：熄屏且未开锁屏歌词时 tick 休眠
  bool _screenOn = true;

  // 当前配置缓存
  double _fontSize = Platform.isWindows ? 40.0 : 18.0;
  bool _doubleLine = false;
  int _opacity = 50;
  int _gradientStart = 0xFF00E5FF;
  int _gradientEnd = 0xFFFF00FF;
  int _unplayedColor = 0xFFFFFFFF;
  bool _locked = false;
  bool _allowHorizontalMove = true;
  /// 配色模式：0 = 预设配色，1 = 自调颜色。持久化，重启后保持。
  int _colorMode = kColorModePreset;
  /// 最近一次选中的预设下标。进入自调颜色后**保留**，
  /// 切回预设配色时据此还原（见 [setColorMode]）。
  int _activePreset = 0;
  /// 自定义配色槽位。「自调颜色」写这里，**不写** [_gradientStart] 那份 ——
  /// 预设色是常量不能被拖坏，第 5 个「自定义」色块读的就是这份。
  int _customStart = 0xFF00E5FF;
  int _customEnd = 0xFFFF00FF;
  int _customUnplayed = 0xFFFFFFFF;

  /// 悬浮窗是否锁定（锁定后原生端加 FLAG_NOT_TOUCHABLE 点击穿透，
  /// 悬浮窗自身无法再点击，只能从设置页/通知栏等外部入口解锁）。
  bool get locked => _locked;
  bool get allowHorizontalMove => _allowHorizontalMove;

  // ===== 外观配置：六项配置的唯一数据源 ======================================
  //
  // Flutter 设置页（lib/modules/settings/desktop_lyric_settings_panel.dart）与
  // 原生悬浮窗内的面板（FloatingLyricService.createSettingsPanel）**必须共用
  // 这里的状态**：两端各写各的会互相覆盖。链路是
  //   本服务字段 ← → SharedPreferences ← → 原生 push/回灌
  // 原生面板的改动经 desktopLyricConfigChanged 回灌到 _onNativeConfigChanged，
  // Flutter 侧的改动经 _pushConfig 下发到原生，两侧因此始终一致。
  //
  // [persist] 语义：拖动过程中应以 false 调用（只更新内存 + 推送原生预览），
  // 松手时再以 true 调一次写盘。原生 SeekBar 也是同样处理
  // （onStopTrackingTouch 才 sendConfigUpdate），避免每移动一像素就写一次盘。

  double get fontSize => _fontSize;
  bool get doubleLine => _doubleLine;
  int get opacity => _opacity;
  int get gradientStart => _gradientStart;
  int get gradientEnd => _gradientEnd;
  int get unplayedColor => _unplayedColor;
  int get colorMode => _colorMode;
  int get activePreset => _activePreset;
  int get customStart => _customStart;
  int get customEnd => _customEnd;
  int get customUnplayed => _customUnplayed;

  /// 当前渐变**实际等于**自定义槽位吗（第 5 个「自定义」色块的选中环）。
  bool get isCustomGradient =>
      _gradientStart == _customStart && _gradientEnd == _customEnd;

  /// 当前渐变**实际等于**哪一组预设；都不等（即自定义配色）时返回 -1。
  ///
  /// 面板上的预设选中环一律以这个值为准，两端（Flutter 设置页 / 悬浮窗）都用它：
  /// 少写一个独立的"选中态"字段，就少一处和真实颜色对不上的机会 ——
  /// 之前原生用自己那份 `activePreset` 记选中态，Dart 侧改了颜色它也照旧亮着。
  int get matchedPresetIndex => gradientPresets.indexWhere(
        (p) => p.$1 == _gradientStart && p.$2 == _gradientEnd,
      );

  /// 字号上下限，与原生 A−/A+ 的 clamp 保持一致（12f … 32f sp）。
  static const double minFontSize = 12.0;
  static const double maxFontSize = 32.0;
  static double get fontSizeMin => Platform.isWindows ? 10.0 : minFontSize;
  static double get fontSizeMax => Platform.isWindows ? 100.0 : maxFontSize;

  static double stepFontSize(double value, {required bool increase}) {
    if (!Platform.isWindows) {
      return (value + (increase ? 2 : -2)).clamp(fontSizeMin, fontSizeMax).toDouble();
    }
    final next = increase
        ? ((value / 10).floor() + 1) * 10
        : ((value / 10).ceil() - 1) * 10;
    return next.clamp(fontSizeMin, fontSizeMax).toDouble();
  }

  /// 背景不透明度上下限（%）；原生换算是 `bgAlpha = opacity * 255 / 100`。
  static const int minOpacity = 0;
  static const int maxOpacity = 100;

  /// 与原生 FloatingLyricService.Companion.PRESETS 逐项一致的预设渐变。
  static const List<(int, int)> gradientPresets = [
    (0xFF00E5FF, 0xFFFF00FF), // 青 → 洋红（默认）
    (0xFFFF4081, 0xFFFFC400), // 粉 → 琥珀
    (0xFF00E676, 0xFF00B0FF), // 绿 → 天蓝
    (0xFFFFFFFF, 0xFFFFFFFF), // 纯白（起止同色，退化为单色）
  ];

  /// 配色模式取值，与原生 `FloatingLyricService.colorMode` 一一对应。
  static const int kColorModePreset = 0;
  static const int kColorModeCustom = 1;

  /// 预设自带的未唱色。卡拉OK二分色里"未唱"就该是白的，否则和已唱分不开 ——
  /// 选任何预设都会把未唱色重置回这个值（用户要求：预设的未唱为白色）。
  static const int kPresetUnplayedColor = 0xFFFFFFFF;

  /// 设置歌词字号。
  Future<void> setFontSize(double v, {bool persist = true}) async {
    final value = v.clamp(fontSizeMin, fontSizeMax);
    _fontSize = value;
    if (persist) await _settings.setDesktopLyricFontSize(value);
    await _pushConfig();
    _notify();
  }

  /// 设置是否同时显示下一行。
  Future<void> setDoubleLine(bool v, {bool persist = true}) async {
    _doubleLine = v;
    if (persist) await _settings.setDesktopLyricDoubleLine(v);
    await _pushConfig();
    _notify();
  }

  /// 设置悬浮窗黑色圆角底的不透明度（0–100）。
  Future<void> setOpacity(int v, {bool persist = true}) async {
    final value = v.clamp(minOpacity, maxOpacity);
    _opacity = value;
    if (persist) await _settings.setDesktopLyricOpacity(value);
    await _pushConfig();
    _notify();
  }

  Future<void> setAllowHorizontalMove(bool value) async {
    _allowHorizontalMove = value;
    await _settings.setDesktopLyricAllowHorizontalMove(value);
    await _pushConfig();
    _notify();
  }

  /// 设置已唱部分的渐变两端。两端同值即退化为单色。
  ///
  /// 这是「自调颜色」的写入口：写的是**自定义槽位**，同时把当前生效的渐变
  /// 也改成它（否则拖动时看不到效果）；模式切到 [kColorModeCustom]。
  /// 预设的四组渐变是常量，永远不会被这里改到。
  Future<void> setGradient({
    required int start,
    required int end,
    bool persist = true,
  }) async {
    _customStart = start;
    _customEnd = end;
    _gradientStart = start;
    _gradientEnd = end;
    _colorMode = kColorModeCustom;
    if (persist) {
      await _settings.setDesktopLyricCustomGradStart(start);
      await _settings.setDesktopLyricCustomGradEnd(end);
      await _settings.setDesktopLyricGradientStart(start);
      await _settings.setDesktopLyricGradientEnd(end);
      await _settings.setDesktopLyricColorMode(kColorModeCustom);
    }
    await _pushConfig();
    _notify();
  }

  /// 选中一组预设渐变：未唱色一并重置为白色，同时把配色模式切回「预设配色」。
  ///
  /// 预设是**常量**（用户要求：预设色不能改），自调的产物只进自定义槽位；
  /// 「未唱为白」也是预设的一部分 —— 卡拉OK二分色里未唱就该是白的，否则
  /// 已唱/未唱对比不出来。
  Future<void> selectGradientPreset(int index) async {
    if (index < 0 || index >= gradientPresets.length) return;
    final p = gradientPresets[index];
    _activePreset = index;
    _colorMode = kColorModePreset;
    _gradientStart = p.$1;
    _gradientEnd = p.$2;
    _unplayedColor = kPresetUnplayedColor;
    await _settings.setDesktopLyricPresetIndex(index);
    await _settings.setDesktopLyricColorMode(kColorModePreset);
    await _settings.setDesktopLyricGradientStart(p.$1);
    await _settings.setDesktopLyricGradientEnd(p.$2);
    await _settings.setDesktopLyricUnplayedColor(kPresetUnplayedColor);
    await _pushConfig();
    _notify();
  }

  /// 应用自定义槽位（第 5 个「自定义」色块 / 切回自调颜色模式）。
  Future<void> selectCustomGradient() async {
    _colorMode = kColorModeCustom;
    _gradientStart = _customStart;
    _gradientEnd = _customEnd;
    _unplayedColor = _customUnplayed;
    await _settings.setDesktopLyricColorMode(kColorModeCustom);
    await _settings.setDesktopLyricGradientStart(_customStart);
    await _settings.setDesktopLyricGradientEnd(_customEnd);
    await _settings.setDesktopLyricUnplayedColor(_customUnplayed);
    await _pushConfig();
    _notify();
  }

  /// 切换配色模式。
  ///
  /// 「预设配色」→ 恢复 [_activePreset] 那一组（未唱 = 白）；
  /// 「自调颜色」→ 恢复自定义槽位。两个方向都可逆，且都不产生"模式显示 A、
  /// 颜色却是 B"的错位。
  Future<void> setColorMode(int mode) async {
    final m = mode == kColorModeCustom ? kColorModeCustom : kColorModePreset;
    _colorMode = m;
    if (m == kColorModePreset) {
      final p = gradientPresets[_activePreset.clamp(0, gradientPresets.length - 1)];
      _gradientStart = p.$1;
      _gradientEnd = p.$2;
      _unplayedColor = kPresetUnplayedColor;
      await _settings.setDesktopLyricGradientStart(p.$1);
      await _settings.setDesktopLyricGradientEnd(p.$2);
      await _settings.setDesktopLyricUnplayedColor(kPresetUnplayedColor);
    } else {
      _gradientStart = _customStart;
      _gradientEnd = _customEnd;
      _unplayedColor = _customUnplayed;
      await _settings.setDesktopLyricGradientStart(_customStart);
      await _settings.setDesktopLyricGradientEnd(_customEnd);
      await _settings.setDesktopLyricUnplayedColor(_customUnplayed);
    }
    await _settings.setDesktopLyricColorMode(m);
    await _pushConfig();
    _notify();
  }

  /// 设置未唱部分的颜色。
  ///
  /// 同样写进自定义槽位：未唱色是自调的一部分，预设模式下的未唱固定为白
  /// （见 [kPresetUnplayedColor]），拖这个滑块就意味着进入自调颜色。
  Future<void> setUnplayedColor(int v, {bool persist = true}) async {
    _customUnplayed = v;
    _unplayedColor = v;
    _colorMode = kColorModeCustom;
    if (persist) {
      await _settings.setDesktopLyricCustomUnplayed(v);
      await _settings.setDesktopLyricUnplayedColor(v);
      await _settings.setDesktopLyricColorMode(kColorModeCustom);
    }
    await _pushConfig();
    _notify();
  }

  /// 解锁桌面歌词悬浮窗（锁定时悬浮窗点击穿透，需从外部解锁）。
  Future<void> unlock() async {
    if (!_locked) return;
    _locked = false;
    await _settings.setDesktopLyricLocked(false);
    _pushConfig(); // 推送原生端解除 FLAG_NOT_TOUCHABLE
    _notify();
  }

  /// 锁定桌面歌词悬浮窗：原生端加 FLAG_NOT_TOUCHABLE，点击可穿透到下层界面。
  ///
  /// **代价**：锁定后悬浮窗自身不再接收触摸，面板会被收起，只能从
  /// 设置页（DesktopLyricSettingsPanel 的锁定行）或通知栏解锁 —— 调用方
  /// 必须把这个后果告知用户。
  Future<void> lock() async {
    if (_locked) return;
    _locked = true;
    await _settings.setDesktopLyricLocked(true);
    _pushConfig();
    _notify();
  }

  // 通知外部状态变化（让 mini_player 等可以监听刷新）
  final List<VoidCallback> _listeners = [];
  void addListener(VoidCallback cb) => _listeners.add(cb);
  void removeListener(VoidCallback cb) => _listeners.remove(cb);
  void _notify() {
    for (final cb in List.of(_listeners)) {
      cb();
    }
  }

  /// 在 app 启动时（main 中）调用：注册原生回调
  void registerNativeCallbacks() {
    MediaNotificationService.onToggleDesktopLyric = () {
      toggle();
    };
    MediaNotificationService.onDesktopLyricAction = (action) {
      _handleFloatingAction(action);
    };
    MediaNotificationService.onPrevious = () {
      _player?.previous();
    };
    MediaNotificationService.onNext = () {
      _player?.next();
    };
    MediaNotificationService.onTogglePlayPause = () {
      if (_player == null) return;
      if (_player!.isPlaying) {
        _player!.pause();
      } else {
        _player!.resume();
      }
    };
    MediaNotificationService.onToggleFavorite = () {
      _handleToggleFavorite();
    };
    MediaNotificationService.onSeekForward = () {
      final player = _player;
      if (player == null) return;
      player.seek(player.position + const Duration(seconds: 10));
    };
    MediaNotificationService.onSeekBack = () {
      final player = _player;
      if (player == null) return;
      final target = player.position - const Duration(seconds: 10);
      player.seek(target < Duration.zero ? Duration.zero : target);
    };
    MediaNotificationService.onConfigChanged = (config) {
      _onNativeConfigChanged(config);
    };
    MediaNotificationService.onScreenStateChanged = (on) {
      _screenOn = on;
      _syncNativeSyncProbeInterval();
      if (!on && !_lockScreenLyricEnabled) {
        // 熄屏且未开锁屏歌词：停表前先清掉预测调度，否则它们仍会到点唤醒
        _cancelLineTimer();
        _cancelFlymeLineTimer();
      }
      _updateTicker();
      if (on) {
        // 点亮屏幕立即补一拍：熄屏期间行提交与进度推送已暂停，需对齐漂移
        _onTick();
      }
    };
  }

  Future<void> _handleToggleFavorite() async {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) return;
    try {
      final player = ctx.read<PlayerProvider>();
      final favorites = ctx.read<FavoritesProvider>();
      final song = player.currentSong;
      if (song != null) {
        await favorites.toggleFavorite(song);
        // Refresh notification after toggle completes to update heart icon
        player.refreshNotification();
        // 锁屏歌词卡片只增量同步红心态：整包重推会重置原生侧进度外推基线，
        // 表现为锁屏进度条回跳。
        _pushLockScreenFavorite(song.id, favorites.isFavorite(song.id));
      }
    } catch (_) {}
  }

  /// 当前歌曲是否已收藏（锁屏歌词卡片红心态）。
  ///
  /// 读不到 Navigator 上下文或 provider 未装配时按未收藏处理：收藏态只影响
  /// 一个图标的填充与否，不值得让整包推送失败。
  bool _isCurrentSongFavorited(String? songId) {
    if (songId == null || songId.isEmpty) return false;
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) return false;
    try {
      return ctx.read<FavoritesProvider>().isFavorite(songId);
    } catch (_) {
      return false;
    }
  }

  /// 收藏态增量推送（按歌 + 值去重）。
  ///
  /// 三个入口共用这一处：锁屏卡片点红心、通知栏红心、App 内任意页面的收藏。
  /// 只在实际翻转时推一次轻量通道——收藏面板/云端同步会连续 notifyListeners，
  /// 不去重会打出一批无谓的通道调用。
  void _pushLockScreenFavorite(String songId, bool favorited) {
    if (!_lockScreenLyricEnabled) return;
    if (_lockFavoriteSongId == songId && _lockFavoriteValue == favorited) return;
    _lockFavoriteSongId = songId;
    _lockFavoriteValue = favorited;
    // ignore: discarded_futures
    MediaNotificationService.updateLockScreenFavorite(isFavorited: favorited);
  }

  /// 收藏 provider 变化回调：把当前歌的收藏态回流到锁屏卡片。
  void _onFavoritesChangedForLockScreen() {
    if (!_lockScreenLyricEnabled) return;
    final song = _player?.currentSong;
    if (song == null) return;
    _pushLockScreenFavorite(song.id, _favorites?.isFavorite(song.id) ?? false);
  }

  void _handleFloatingAction(String action) {
    switch (action) {
      case 'lock':
        _locked = !_locked;
        _settings.setDesktopLyricLocked(_locked);
        _pushConfig();
        break;
      case 'previous':
        _player?.previous();
        break;
      case 'play':
        if (_player != null) {
          if (_player!.isPlaying) {
            _player!.pause();
          } else {
            _player!.resume();
          }
        }
        break;
      case 'next':
        _player?.next();
        break;
      case 'settings':
        // 设置面板内嵌在 native 浮窗，无需 Dart 处理
        break;
    }
  }

  /// 原生浮窗内修改配置后回传，Dart 负责持久化
  Future<void> _onNativeConfigChanged(Map<dynamic, dynamic> config) async {
    // 颜色一律 toUnsigned(32) 兜底：修复前的版本原生回灌过负数 Kotlin Int
    // （ARGB 的最高位是 alpha=FF，作为 Int32 是负的），盘里可能还残留着负值。
    final fontSize = (config['fontSize'] as num?)?.toDouble();
    final doubleLine = config['doubleLine'] as bool?;
    final opacity = config['opacity'] as int?;
    final locked = config['locked'] as bool?;
    final gradientStart =
        (config['gradientStart'] as int?)?.toUnsigned(32);
    final gradientEnd = (config['gradientEnd'] as int?)?.toUnsigned(32);
    final unplayedColor =
        (config['unplayedColor'] as int?)?.toUnsigned(32);
    final colorMode = config['colorMode'] as int?;
    final activePreset = config['activePreset'] as int?;
    final customStart = (config['customStart'] as int?)?.toUnsigned(32);
    final customEnd = (config['customEnd'] as int?)?.toUnsigned(32);
    final customUnplayed =
        (config['customUnplayed'] as int?)?.toUnsigned(32);

    if (fontSize != null) {
      _fontSize = fontSize;
      await _settings.setDesktopLyricFontSize(fontSize);
    }
    if (doubleLine != null) {
      _doubleLine = doubleLine;
      await _settings.setDesktopLyricDoubleLine(doubleLine);
    }
    if (opacity != null) {
      _opacity = opacity;
      await _settings.setDesktopLyricOpacity(opacity);
    }
    if (locked != null) {
      _locked = locked;
      await _settings.setDesktopLyricLocked(locked);
    }
    if (gradientStart != null) {
      _gradientStart = gradientStart;
      await _settings.setDesktopLyricGradientStart(gradientStart);
    }
    if (gradientEnd != null) {
      _gradientEnd = gradientEnd;
      await _settings.setDesktopLyricGradientEnd(gradientEnd);
    }
    if (unplayedColor != null) {
      _unplayedColor = unplayedColor;
      await _settings.setDesktopLyricUnplayedColor(unplayedColor);
    }
    if (colorMode != null) {
      _colorMode =
          colorMode == kColorModeCustom ? kColorModeCustom : kColorModePreset;
      await _settings.setDesktopLyricColorMode(_colorMode);
    }
    if (activePreset != null) {
      _activePreset = activePreset.clamp(0, gradientPresets.length - 1);
      await _settings.setDesktopLyricPresetIndex(_activePreset);
    }
    if (customStart != null) {
      _customStart = customStart;
      await _settings.setDesktopLyricCustomGradStart(customStart);
    }
    if (customEnd != null) {
      _customEnd = customEnd;
      await _settings.setDesktopLyricCustomGradEnd(customEnd);
    }
    if (customUnplayed != null) {
      _customUnplayed = customUnplayed;
      await _settings.setDesktopLyricCustomUnplayed(customUnplayed);
    }
    _notify();
  }

  /// 切换桌面歌词开关（mini_player / 通知栏按钮通用）
  Future<void> toggle() async {
    if (_enabled) {
      await disable();
    } else {
      await enable();
    }
  }

  Future<void> enable() async {
    if (_enabled) return;
    // 权限是独立于 provider 的系统设置检查，放最前：无权限时也走
    // startFloatingLyric（原生 MainActivity 检测到无权限会跳系统授权页
    // 并返回 false），并保持 _enabled=false，mini_player 等开关 UI 依据
    // enabled 自动回弹，不出现"假开启"。旧实现把 provider 绑定放在
    // 权限检查之前，provider 未就绪时连授权页都不会弹出。
    final hasPermission = await MediaNotificationService.hasOverlayPermission();
    if (!hasPermission) {
      try {
        await MediaNotificationService.startFloatingLyric(lyric: '', title: '');
      } catch (_) {}
      // 无权限时原生端会跳系统授权页；Windows 端没有"授权页"这回事，
      // 若这里不提示，用户只会看到开关"弹回去"而没有任何原因。
      if (!_isDesktopPlatform) {
        showToast('请先授予悬浮窗权限后再开启桌面歌词', long: true);
      }
      return;
    }
    _bindProvidersFromContext();
    if (_player == null || _kugou == null) {
      // 静默 return 会让开关"弹回去"且毫无解释，Windows 端尤其明显
      // （该平台无 toast 时用户完全无从判断）。
      showToast('播放器尚未就绪，请稍后再试', long: true);
      return;
    }
    // startFloatingLyric 返回 false（权限竞态撤销/BadTokenException/显示层拒绝）
    // 时保持开关为关（原生端会回填真实 addView 结果），避免悬浮窗未出现但按钮
    // 显示已开启的"假开启"状态，并提示用户授权悬浮窗权限后重试。
    // 新建原生窗口时就带上当前行，避免先空白、等下一句才刷新。
    await _loadConfig();
    final song = _player!.currentSong;
    final sameSong = song != null && song.id == _currentSongId;
    final index = sameSong ? _findLineIndex(_player!.position.inMilliseconds) : -1;
    final initialLyric = sameSong && _lines.isNotEmpty
        ? (index >= 0 ? _lines[index].text : '')
        : (song == null ? '' : '歌词加载中...');
    final started = await MediaNotificationService.startFloatingLyric(
      lyric: initialLyric,
      title: song?.title ?? '',
    );
    if (!started) {
      showToast(
        _isDesktopPlatform ? '桌面歌词开启失败（窗口创建失败）' : '桌面歌词开启失败，请检查并开启悬浮窗权限后重试',
        long: true,
      );
      return;
    }
    _enabled = true;
    await _pushConfig();
    _syncCurrentFromPlayer();
    _updateTicker();
    _notify();
  }

  /// Windows 还原设置时同时关闭旧歌词窗并刷新面板使用的配置缓存。
  Future<void> reloadWindowsSettings() async {
    if (!Platform.isWindows) return;
    await disable();
    await _loadConfig();
    _notify();
  }

  Future<void> disable() async {
    if (!_enabled) return;
    _enabled = false;
    // 记录主动关闭时刻：原生 stop 反映到 isRunning 有延迟，
    // 巡检用它避开「刚关窗又被误判成待恢复」的竞态窗口。
    _lastDisabledAt = DateTime.now();
    _updateTicker();
    _cancelLineTimer();
    _cancelFlymeLineTimer();
    try {
      await MediaNotificationService.stopFloatingLyric();
    } catch (_) {}
    _notify();
  }

  /// 引擎被系统杀死后，从原生窗口实况恢复悬浮窗推送。
  ///
  /// 原生悬浮窗（服务 + overlay View）随进程存活：vivo 等机型常杀 Dart 引擎而
  /// 留下进程与窗口，屏幕上黑框原封不动，但 Dart 侧 `_enabled` 归 false →
  /// `_pushLyric/_pushProgress/_pushPlaying` 全部早退——表现为黑框还在、永远没字。
  /// 其它歌词通道（蓝牙/锁屏/Flyme/LyricInfo）在 main.dart 的
  /// `_restoreLyricPushPref` 各有恢复，桌面歌词此前唯独没有恢复路径；引擎启动
  /// 时（runBootstrap，providers 未就绪也可）调用本方法补齐。以原生实况为
  /// 用户意图的判据：关窗走 stopFloatingLyric（服务必停 → 查询为 false），
  /// 查到窗口在显示就按开启恢复。失败静默：下一次引擎重启仍会重试。
  Future<void> restoreFloatingFromNative() async {
    if (_enabled) return;
    final running = await MediaNotificationService.isFloatingLyricWindowRunning();
    if (!running) return;
    _enabled = true;
    // 行索引与推送基线全部复位：下一拍（或 provider 绑定成功后那一拍）按
    // 常规路径重推当前行/进度/播放态，幂等去重保证不产生额外重绘。
    _currentLineIndex = -2;
    _lastLineSwitchAt = null;
    _lastPushedPlaying = false;
    _lastPushedPosMs = null;
    _syncCurrentFromPlayer();
    _updateTicker();
    _notify();
  }

  // ── 原生窗口巡检（md3 fork：#147 恢复链第二环）──
  //
  // 启动悬浮窗的入口不止 Dart 的 toggle()：通知栏按钮、悬浮窗原生面板、
  // 无头引擎路径等都可能把窗口开起来，而它们不经过 enable() 抬起
  // _enabled——表现为「窗口在、永远没词」。这里 5s 一检：发现「原生窗口
  // 在显示而 Dart 侧认为关」就走 [restoreFloatingFromNative] 把推送链
  // 续上，任何入口 5s 内自愈，与具体入口解耦。
  //
  // 窗口不在时本探测只是一次返回 bool 的通道调用，代价可忽略；平台无
  // 该方法（如 Windows 某些宿主）时入口抛 MissingPluginException 被
  // 吞掉，探测退化为空操作。
  Timer? _nativeSyncProbe;
  int _nativeSyncProbeIntervalSeconds = 5;
  DateTime? _lastDisabledAt;

  void _startNativeSyncProbe() {
    _syncNativeSyncProbeInterval();
  }

  void _syncNativeSyncProbeInterval([bool? playing]) {
    final seconds = (playing ?? _player?.isPlaying ?? false) || _screenOn
        ? 5
        : 30;
    if (_nativeSyncProbe != null && seconds == _nativeSyncProbeIntervalSeconds) {
      return;
    }
    _nativeSyncProbe?.cancel();
    _nativeSyncProbeIntervalSeconds = seconds;
    _nativeSyncProbe = Timer.periodic(
      Duration(seconds: seconds),
      (_) => _probeNativeWindow(),
    );
  }

  Future<void> _probeNativeWindow() async {
    if (_enabled) return;
    final last = _lastDisabledAt;
    if (last != null && DateTime.now().difference(last).inSeconds < 3) {
      return;
    }
    try {
      if (await MediaNotificationService.isFloatingLyricWindowRunning()) {
        await restoreFloatingFromNative();
      }
    } catch (_) {}
  }

  /// 蓝牙歌词开关：独立于悬浮窗。开启后定时器运行以获取当前歌词行，
  /// 但不弹出悬浮窗；关闭后若悬浮窗也未开启则停止定时器。
  Future<void> setBluetoothLyricEnabled(bool enabled) async {
    if (_bluetoothLyricEnabled == enabled) return;
    _bluetoothLyricEnabled = enabled;
    _bindProvidersFromContext();
    _updateTicker();
    if (enabled) {
      // 启用时重置切歌检测状态，让下个 tick 重新拉取歌词并推送。
      // 解决 app 启动时调用本方法、但原生 service 尚未就绪导致的首次播放不推送问题。
      _currentSongId = null;
      _setParsedLines(const []);
      _currentLineIndex = -1;
      _awaitingLyric = false;
    } else {
      // 关闭时清空蓝牙歌词，让原生端恢复原始 title/artist
      await MediaNotificationService.updateBluetoothLyric('');
    }
  }

  /// LyricInfo 歌词转发开关：独立于悬浮窗/蓝牙歌词。开启后定时器运行以获取
  /// 当前歌词并构造 JSON 推送（写入 MediaSession extras）；关闭时移除 lyricInfo。
  Future<void> setLyricInfoEnabled(bool enabled) async {
    if (_lyricInfoEnabled == enabled) return;
    _lyricInfoEnabled = enabled;
    _bindProvidersFromContext();
    if (enabled) {
      _lyricInfoPushed = false;
      _updateTicker();
      // 启用时若已有歌词立即推送一次（无需等下一个 tick）
      if (_lines.isNotEmpty) {
        _maybePushLyricInfo();
      }
    } else {
      _lyricInfoPushed = false;
      _updateTicker();
      // 关闭时移除 lyricInfo，让原生端元数据不再携带
      try {
        await MediaNotificationService.removeLyricInfo();
      } catch (_) {}
    }
    _notify();
  }

  /// ColorOS Bridge 兼容模式开关：改值后若 LyricInfo 已启用，重置去重标志并
  /// 立即按新模式重推当前歌曲（与 setLyricInfoEnabled 的即时推送行为一致）。
  Future<void> setLyricInfoColorOs(bool enabled) async {
    if (_lyricInfoColorOs == enabled) return;
    _lyricInfoColorOs = enabled;
    if (_lyricInfoEnabled) {
      _lyricInfoPushed = false;
      _maybePushLyricInfo();
    }
    _notify();
  }

  /// 魅族 Flyme 状态栏歌词开关。开启后立即回灌当前行，避免要等到下一句才显示；
  /// 关闭时推一次空串，让原生摘掉 ticker 并清掉那两个 Flyme flag。
  Future<void> setFlymeStatusBarLyricEnabled(bool enabled) async {
    if (_flymeStatusBarLyricEnabled == enabled) return;
    _flymeStatusBarLyricEnabled = enabled;
    _bindProvidersFromContext();
    _updateTicker();
    try {
      await _flymeChannel.invokeMethod(
          'setFlymeStatusBarLyricEnabled', {'enabled': enabled});
    } catch (_) {}
    if (enabled) {
      // 回灌走"提前量之后"的时间轴，否则刚打开时显示的还是原始时间轴的那一行，
      // 要等到下一次翻行才看得出提前效果。索引先归零，避免被去重吞掉。
      _flymeLineIndex = -1;
      _flymeLastSwitchAt = null;
      _flymePrevPosMs = -1;
      final p = _player;
      if (p != null && _lines.isNotEmpty) {
        _tickFlymeAdvance(p.position.inMilliseconds);
      } else if (_currentLineIndex >= 0 && _currentLineIndex < _lines.length) {
        await _pushFlymeLine(_lines[_currentLineIndex].text);
      }
    } else {
      await _pushFlymeLine('');
      _cancelFlymeLineTimer();
      _flymeLineIndex = -1;
      _flymeLastSwitchAt = null;
      _flymePrevPosMs = -1;
    }
    _notify();
  }

  /// 只发行级纯文本。原生侧对空串做清空处理。
  Future<void> _pushFlymeLine(String text) async {
    try {
      await _flymeChannel
          .invokeMethod('updateFlymeStatusBarLyric', {'lyric': text.trim()});
    } catch (_) {}
  }

  /// SuperLyric 歌词推送开关：独立于悬浮窗/蓝牙歌词/LyricInfo。
  /// 开启后定时器运行以在切歌/行变化时推送当前行；关闭时推一次空歌词清空。
  Future<void> setSuperLyricEnabled(bool enabled) async {
    if (_superLyricEnabled == enabled) return;
    _superLyricEnabled = enabled;
    _bindProvidersFromContext();
    _updateTicker();
    if (enabled) {
      // 开启时若已有当前行立即推送一次（无需等下一个 tick）
      if (_currentLineIndex >= 0 && _currentLineIndex < _lines.length) {
        _pushSuperLyricLine(_lines[_currentLineIndex]);
      } else {
        _pushSuperLyricLine(null);
      }
    } else {
      // 关闭时推一次「仅 title/artist」清空当前歌词
      _pushSuperLyricLine(null);
    }
    _notify();
  }

  /// 锁屏歌词开关：独立于悬浮窗/蓝牙歌词/LyricInfo/SuperLyric。
  /// 开启后定时器运行，推送整首歌词与样式到原生锁屏歌词界面
  /// （LockScreenLyricActivity，锁屏全屏滚动歌词列表）；关闭时关闭该界面。
  Future<void> setLockScreenLyricEnabled(bool enabled) async {
    if (_lockScreenLyricEnabled == enabled) return;
    _lockScreenLyricEnabled = enabled;
    _bindProvidersFromContext();
    _updateTicker();
    if (enabled) {
      // 启用时重置切歌检测状态，让下个 tick 立即拉取歌词并推送
      _currentSongId = null;
      _setParsedLines(const []);
      _currentLineIndex = -1;
      _awaitingLyric = false;
      // 锁屏推送状态全部重置，下个 tick 整包重推
      _lockFullDirty = true;
      _lockPlaceholder = '';
      _lockProgressPushGate.reset();
      _lockAccentToken++;
      // 收藏回流基线复位：下次整包推送会重新写入，期间 FavoritesProvider 的
      // 启动加载通知不会误推一轮“假翻转”
      _lockFavoriteSongId = null;
      _lockFavoriteValue = null;
      // 通知原生端开关已开启（原生端后续由 ACTION_SCREEN_OFF 广播拉起界面）
      try {
        await MediaNotificationService.showLockScreenLyric();
      } catch (_) {}
    } else {
      // 关闭时关闭锁屏歌词界面
      try {
        await MediaNotificationService.hideLockScreenLyric();
      } catch (_) {}
    }
    _notify();
  }

  /// AM 歌词偏好变化回调：锁屏歌词样式全部跟随 AM 歌词设置
  /// （字号/行距/字重/字体来源/副行模式/动态取色），偏好一变即整包重推，
  /// 锁屏显示中调整播放页歌词设置即时生效。
  ///
  /// 同时承担「屏蔽歌词作者信息」开关/正则变化：从 [_rawLines] 即时重派生
  /// [_lines] 并复位当前行定位，让悬浮窗/锁屏/LyricInfo 全部走新过滤口径。
  void _onLyricPrefsChangedForLockScreen() {
    _refilterDisplayLines();
    if (!_lockScreenLyricEnabled) return;
    _lockFullDirty = true;
    _pushLockScreenFullData();
  }

  /// 写入解析结果：raw 与过滤后的显示列表同源更新，并记录过滤快照。
  ///
  /// 供两个取词入口（本地内嵌 / 在线拉取）与清场路径共用，避免漏存 raw
  /// 导致开关变化时无行可派生。
  void _setParsedLines(List<LyricLine> raw) {
    _rawLines = raw;
    _lines = LyricCreditFilter.filterLines(raw);
    _derivedFilterEnabled = LyricCreditFilter.enabled;
    _derivedFilterPattern = LyricPreferences.instance.creditPattern;
  }

  /// 从 [_rawLines] 重派生过滤后的显示列表（仅开关/正则真正变化时执行）。
  ///
  /// 派生后**行索引整体可能位移**（名单行被抽走），因此所有以索引为坐标的状态
  /// 都要复位，否则会把旧索引当成「已推送过的行」而漏推或倒着跳：
  /// - [_currentLineIndex] = -2（与切歌同款口径）→ 下个 tick 重定位当前行；
  /// - [_flymeLineIndex] = -1 → 魅族时间轴禁止倒退的守卫会挡住位移后的新目标行，
  ///   必须归零（口径同 [setFlymeAdvanceMs]）；
  /// - 行边界预测 Timer → 它记的是旧索引的起始时刻，取消后由下个 tick 重排；
  /// - [_lyricInfoPushed] = false → 整包歌词内容变了，去重标志必须清才会重推。
  /// filterLines 在无命中/关闭时返回原引用，派生是 O(n) 纯扫描，成本可忽略。
  void _refilterDisplayLines() {
    final filterEnabled = LyricCreditFilter.enabled;
    final filterPattern = LyricPreferences.instance.creditPattern;
    if (filterEnabled == _derivedFilterEnabled &&
        filterPattern == _derivedFilterPattern) {
      return;
    }
    _derivedFilterEnabled = filterEnabled;
    _derivedFilterPattern = filterPattern;
    _lines = LyricCreditFilter.filterLines(_rawLines);
    _currentLineIndex = -2;
    _lastLineSwitchAt = null;
    _cancelLineTimer();
    _flymeLineIndex = -1;
    _flymeLastSwitchAt = null;
    _flymePrevPosMs = -1;
    _lyricInfoPushed = false;
    _maybePushLyricInfo();
  }

  /// 推送整首歌词 + 样式到原生锁屏界面（切歌 / 歌词就绪 / 偏好变化时调用）。
  ///
  /// 样式字段取自 [LyricPreferences]（与 AM 播放页 Zen 沉浸模式同源）；
  /// 推送后重置进度节流基线，并异步提取封面主色用于当前行混色。
  void _pushLockScreenFullData() {
    if (!_lockScreenLyricEnabled) return;
    _lockFullDirty = false;
    final prefs = LyricPreferences.instance;
    final player = _player;
    final song = player?.currentSong;
    final displayRoma = prefs.displayMode == LyricDisplayMode.roma;
    final lines = <Map<String, Object?>>[
      for (final line in _lines)
        {
          'text': line.text,
          'start': line.startTime,
          'duration': line.duration,
          'words': line.words.map((w) => w.text).toList(),
          'wordStarts': line.words.map((w) => w.startTime).toList(),
          'wordDurations': line.words.map((w) => w.duration).toList(),
          'sub': displayRoma ? line.roma : line.translation,
        },
    ];
    final favorited = _isCurrentSongFavorited(song?.id);
    // 整包已带上收藏态：同步回流基线，避免紧接着的 FavoritesProvider 通知再推一次同一值
    _lockFavoriteSongId = song?.id;
    _lockFavoriteValue = favorited;
    MediaNotificationService.updateLockScreenLyricData(
      lines: lines,
      placeholder: _lockPlaceholder,
      currentPositionMs: player?.position.inMilliseconds ?? 0,
      durationMs: player?.duration?.inMilliseconds ?? 0,
      isPlaying: player?.isPlaying ?? false,
      title: song?.displayName ?? '',
      artist: song?.artist ?? '',
      isFavorited: favorited,
      artUrl: song?.artworkUri,
      fallbackFilePath: song?.localPath,
      fontSize: prefs.fontSize,
      fontWeight: prefs.fontWeightValue,
      lineHeightMultiplier: prefs.lineHeightMultiplier,
      fontSource: prefs.fontSource.index,
      customFontPath: prefs.customFontPath,
      showTranslation: prefs.showTranslation,
      displayMode: prefs.displayMode.index,
      useDynamicColor: prefs.useDynamicLyricColor,
    );
    _lockProgressPushGate.markFullPush(
      nowMs: DateTime.now().millisecondsSinceEpoch,
      isPlaying: player?.isPlaying ?? false,
    );
    _pushLockScreenAccent(song?.artworkUri, prefs.useDynamicLyricColor);
  }

  /// 异步提取封面主色并推送到原生锁屏界面（当前行「85% 白 + 15% 主色」混色）。
  ///
  /// 动态取色关闭或无封面时推 0（原生侧用纯白）。提取结果带令牌校验，
  /// 切歌后回来的旧结果直接丢弃。
  void _pushLockScreenAccent(String? artUrl, bool useDynamic) {
    final token = ++_lockAccentToken;
    if (!useDynamic || artUrl == null || artUrl.isEmpty) {
      MediaNotificationService.updateLockScreenAccent(0);
      return;
    }
    ArtworkColorExtractor.extract(artUrl)
        .then((color) {
          if (token != _lockAccentToken || !_lockScreenLyricEnabled) return;
          MediaNotificationService.updateLockScreenAccent(
            color?.toARGB32() ?? 0,
          );
        })
        .catchError((_) {});
  }

  /// 锁屏歌词每 tick 推送入口：全量脏 → 整包重推；否则 500ms 节流轻量进度。
  void _pushLockScreenTick() {
    if (!_lockScreenLyricEnabled) return;
    if (_lockFullDirty) {
      _pushLockScreenFullData();
      return;
    }
    final player = _player;
    if (player == null) return;
    if (player.currentSong == null) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final isPlaying = player.isPlaying;
    if (_lockProgressPushGate.shouldPush(nowMs: nowMs, isPlaying: isPlaying)) {
      MediaNotificationService.updateLockScreenProgress(
        currentPositionMs: player.position.inMilliseconds,
        durationMs: player.duration?.inMilliseconds ?? 0,
        isPlaying: isPlaying,
      );
    }
  }

  /// 歌曲元数据（标题/歌手/封面）晚到并被回写后，让各推送渠道立即刷新。
  ///
  /// 场景：一起听跟随端起播时只有 hash 身份，`RoomSong.toSong()` 把空标题
  /// 兜底成「未知歌曲」，各渠道先把它推了出去；随后元数据富化回写当前歌
  /// （`PlayerProvider.updateCurrentSongMetadata`，**id 保持不变**），
  /// 但各渠道都按 song.id 去重 → 真实标题永远推不出去。
  ///
  /// 因此这里在元数据变化时**显式**补推一次，而不是放宽各渠道的去重键：
  /// 去重本意是防高频 tick 重复推送，放宽会破坏该保护。
  ///
  /// 覆盖三条「不重推就永远停在占位标题」的渠道：
  /// - SuperLyric：重推当前行（含 title/artist）
  /// - LyricInfo：复位 once-per-song 标志后重建整首 JSON（含 songName）
  /// - 锁屏歌词：整包重推（含 title/artist）
  /// 注：Lyricon 由 `PlayerProvider._handleLyriconSongChange` 的元数据签名处理。
  Future<void> notifySongMetadataChanged() async {
    if (_superLyricEnabled) {
      if (_currentLineIndex >= 0 && _currentLineIndex < _lines.length) {
        await _pushSuperLyricLine(_lines[_currentLineIndex]);
      } else {
        await _pushSuperLyricLine(null);
      }
    }
    if (_lyricInfoEnabled) {
      _lyricInfoPushed = false;
      _maybePushLyricInfo();
    }
    if (_lockScreenLyricEnabled) {
      _pushLockScreenFullData();
    }
  }

  /// 设置共用的推送偏好（翻译/罗马音/优先翻译），并让过滤立即生效：
  /// - SuperLyric：重推当前行
  /// - LyricInfo：重建并重推整首歌词 JSON
  /// （参照 Lyricon repushLastSong 的做法）。
  Future<void> setLyricPushPreferences({
    required bool translation,
    required bool roma,
    required bool preferTranslation,
  }) async {
    final changed =
        _pushTranslation != translation ||
        _pushRoma != roma ||
        _superLyricPreferTranslation != preferTranslation;
    _pushTranslation = translation;
    _pushRoma = roma;
    _superLyricPreferTranslation = preferTranslation;
    if (!changed) return;
    if (_superLyricEnabled) {
      if (_currentLineIndex >= 0 && _currentLineIndex < _lines.length) {
        await _pushSuperLyricLine(_lines[_currentLineIndex]);
      } else {
        await _pushSuperLyricLine(null);
      }
    }
    if (_lyricInfoEnabled) {
      _lyricInfoPushed = false;
      _maybePushLyricInfo();
    }
  }

  /// 定时器是否需要运行：悬浮窗、蓝牙歌词、LyricInfo、SuperLyric 或锁屏歌词任一开启即需运行
  bool _shouldTick() =>
      _enabled ||
      _bluetoothLyricEnabled ||
      _lyricInfoEnabled ||
      _superLyricEnabled ||
      _flymeStatusBarLyricEnabled ||
      _lockScreenLyricEnabled;

  /// 除「有通道开启」外，还需亮屏、或开了锁屏歌词。
  ///
  /// 熄屏且未开锁屏歌词时悬浮窗不可见，tick 纯耗电——必须真的停表，
  /// 而不是在 [_onTick] 里早退：早退省不掉定时器对 CPU 的周期性唤醒（§10.4.6）。
  bool _tickNeeded() => _shouldTick() && (_screenOn || _lockScreenLyricEnabled);

  /// 根据开关与屏幕状态启停定时器（250ms tick：逐行歌词足够检测切行）
  void _updateTicker() {
    if (_tickNeeded()) {
      _syncTickInterval(_player?.isPlaying ?? false);
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  /// 按播放状态同步 tick 周期：周期未变化时不重建
  void _syncTickInterval(bool playing) {
    if (!_tickNeeded()) {
      _ticker?.cancel();
      _ticker = null;
      return;
    }
    final target = playing ? _tickIntervalPlayingMs : _tickIntervalPausedMs;
    if (_ticker != null && _tickIntervalMs == target) return;
    _tickIntervalMs = target;
    _ticker?.cancel();
    _ticker = Timer.periodic(Duration(milliseconds: target), (_) => _onTick());
  }

  /// 行提交后安排一次性 Timer 在下一行起始时刻触发 _onTick，
  /// 让行切换不受 250ms 轮询相位限制。仅播放中调度（暂停时下一行
  /// 永不到来，避免空转；恢复播放后由 250ms tick 兜底提交并重新调度）。
  void _scheduleLineBoundary(int nextIndex) {
    _lineTimer?.cancel();
    _lineTimer = null;
    final player = _player;
    if (player == null || !player.isPlaying) return;
    if (nextIndex >= _lines.length) return;
    final delayMs =
        _lines[nextIndex].startTime - player.position.inMilliseconds;
    if (delayMs <= 0) return;
    _lineTimer = Timer(Duration(milliseconds: delayMs), _onTick);
  }

  void _cancelLineTimer() {
    _lineTimer?.cancel();
    _lineTimer = null;
  }

  /// 设置状态栏歌词提前量（ms）。改完立刻按新值重算当前该显示哪一行，
  /// 并把提前量回灌原生 —— 否则要等到下一行才生效。
  Future<void> setFlymeAdvanceMs(int ms) async {
    final v = ms < 0 ? 0 : (ms > 600 ? 600 : ms);
    if (_flymeAdvanceMs == v) return;
    _flymeAdvanceMs = v;
    _notify();
    if (!_flymeStatusBarLyricEnabled) return;
    final player = _player;
    if (player == null || _lines.isEmpty) return;
    _flymeLastSwitchAt = null; // 手动调档视为用户意图，不该被迟滞挡住
    // 索引也要归零：调小提前量会让目标行倒退，而正常翻行是禁止倒退的（见
    // _tickFlymeAdvance），不归零就会卡在调整前的那一句。
    _flymeLineIndex = -1;
    _tickFlymeAdvance(player.position.inMilliseconds);
  }

  /// 用「位置 + 提前量」选行并推送。独立于共享的 `_currentLineIndex` 提交路径，
  /// 所以其它歌词通道仍严格按原始时间轴走。
  ///
  /// 只允许索引前进：状态栏是一条只往未来走的时间轴，而真机日志实测位置源抖动
  /// 会让行号在相邻两行间来回跳。原来只有 300ms 迟滞，它只是把回跳推迟、隔几百
  /// 毫秒放行一次，结果是"刚换到下一句又翻回上一句"——用户看到的正是同一句反复
  /// 滚动。改成禁止倒退后抖动被彻底挡住；位置真实回退（拖进度条/重播）仍要跟上，
  /// 故以「比上一次采样早 1.5s 以上」作为真回退的判据（抖动幅度远小于一个行间隔）。
  void _tickFlymeAdvance(int posMs) {
    final idx = _findLineIndex(posMs + _flymeAdvanceMs);
    final rewound = _flymePrevPosMs - posMs > 1500;
    _flymePrevPosMs = posMs;
    if (idx == _flymeLineIndex) return;
    if (idx < _flymeLineIndex && !rewound) return;
    // 前进要迟滞：一次抖动可能连跨两行，或换行恰好撞上 notify 限流窗口。
    // 真回退例外：它同时绕过后面的索引判定，若此处再被吞掉，_flymePrevPosMs
    // 已经是回退后的位置，之后再也判不出回退，状态栏会钉在后面那句直到播放追平。
    final now = DateTime.now();
    if (!rewound &&
        _flymeLastSwitchAt != null &&
        now.difference(_flymeLastSwitchAt!).inMilliseconds < 300) {
      return;
    }
    _flymeLastSwitchAt = now;
    _flymeLineIndex = idx;
    _pushFlymeLine(idx >= 0 ? _lines[idx].text : '');
    _scheduleFlymeBoundary(idx + 1);
  }

  /// 为"提前后的下一个行边界"安排一次性触发，避免只能等 250ms 轮询兜底。
  void _scheduleFlymeBoundary(int nextIndex) {
    _flymeLineTimer?.cancel();
    _flymeLineTimer = null;
    final player = _player;
    if (player == null || !player.isPlaying) return;
    if (nextIndex >= _lines.length) return;
    final delayMs =
        _lines[nextIndex].startTime - _flymeAdvanceMs - player.position.inMilliseconds;
    if (delayMs <= 0) return; // 已经错过，交给下一次 tick 收敛
    _flymeLineTimer = Timer(Duration(milliseconds: delayMs), () {
      final p = _player;
      if (p != null && _flymeStatusBarLyricEnabled) {
        _tickFlymeAdvance(p.position.inMilliseconds);
      }
    });
  }

  void _cancelFlymeLineTimer() {
    _flymeLineTimer?.cancel();
    _flymeLineTimer = null;
  }

  // 上一次下发给原生的「显示大小」档位，用于过滤 ThemeProvider 的其他通知
  // （主题色、背景图等每次变更都会 notify，不必重推悬浮窗配置）。
  double _lastDisplayScale = kDefaultDisplayScale;

  /// 「显示大小」变更 → 重新下发配置，让已显示的悬浮窗歌词立即跟随。
  void _onThemeChanged() {
    final scale = _theme?.displayScale ?? kDefaultDisplayScale;
    if (scale == _lastDisplayScale) return;
    _lastDisplayScale = scale;
    if (!_enabled) return;
    // ignore: discarded_futures
    _pushConfig();
  }

  /// 惰性绑定全局 provider。
  ///
  /// 每个 provider 各自 try/catch：测试替身或部分 provider 缺失时，不能因为
  /// 其中一个 read 抛异常就跳过其余绑定（历史上整段包在同一个 try 里，
  /// 新增一个 provider 就可能悄悄改变原有绑定行为）。
  void _bindProvidersFromContext() {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) return;
    try {
      // 玩家监听：仅换实例时重绑，避免每次绑定都重复 addListener
      final player = ctx.read<PlayerProvider>();
      if (player != _player) {
        _player?.removeListener(_onPlayerChanged);
        _player = player;
        player.addListener(_onPlayerChanged);
      }
    } catch (_) {}
    try {
      _kugou = ctx.read<KugouProvider>();
    } catch (_) {}
    try {
      // 收藏 provider：锁屏卡片红心态要与 App 内/通知栏同源，任一入口翻转都能回流。
      // 只加监听，推送本身按（歌 id + 值）去重，见 _pushLockScreenFavorite。
      final favorites = ctx.read<FavoritesProvider>();
      if (favorites != _favorites) {
        _favorites?.removeListener(_onFavoritesChangedForLockScreen);
        _favorites = favorites;
        favorites.addListener(_onFavoritesChangedForLockScreen);
      }
    } catch (_) {}
    try {
      final theme = ctx.read<ThemeProvider>();
      if (theme != _theme) {
        _theme?.removeListener(_onThemeChanged);
        _theme = theme;
        _lastDisplayScale = theme.displayScale;
        theme.addListener(_onThemeChanged);
      }
    } catch (_) {}
  }

  // 播放状态翻转 → 推送原生（卡拉OK暂停冻结/恢复续跑的信号源）。
  // 仅翻转时推送，position 刷新触发的 notifyListeners 不受影响。
  // 基线由 _pushPlaying 成功后更新：失败时 tick 自愈会在下个周期重试。
  void _onPlayerChanged() {
    final playing = _player?.isPlaying ?? false;
    if (playing == _lastPushedPlaying) return;
    // ignore: discarded_futures
    _pushPlaying(playing);
    if (playing) {
      // 恢复播放：暂停期 tick 已降频至 1s，立即补一拍对齐当前行与预测调度
      _onTick();
    }
  }

  Future<void> _loadConfig() async {
    _fontSize = await _settings.getDesktopLyricFontSize();
    _doubleLine = await _settings.getDesktopLyricDoubleLine();
    _opacity = await _settings.getDesktopLyricOpacity();
    _allowHorizontalMove =
        await _settings.getDesktopLyricAllowHorizontalMove();
    _gradientStart = await _settings.getDesktopLyricGradientStart();
    _gradientEnd = await _settings.getDesktopLyricGradientEnd();
    _unplayedColor = await _settings.getDesktopLyricUnplayedColor();
    _locked = await _settings.getDesktopLyricLocked();
    _colorMode = await _settings.getDesktopLyricColorMode();
    // 预设下标可能落在越界位置（旧版本数据 / 预设表被改短），clamp 兜底
    _activePreset = (await _settings.getDesktopLyricPresetIndex())
        .clamp(0, gradientPresets.length - 1);
    _customStart = await _settings.getDesktopLyricCustomGradStart();
    _customEnd = await _settings.getDesktopLyricCustomGradEnd();
    _customUnplayed = await _settings.getDesktopLyricCustomUnplayed();
  }

  Future<void> _pushConfig() async {
    try {
      await _channel.invokeMethod('setDesktopLyricConfig', {
        'fontSize': _fontSize,
        'displayScale': _theme?.displayScale ?? kDefaultDisplayScale,
        'doubleLine': _doubleLine,
        'opacity': _opacity,
        'locked': _locked,
        'allowHorizontalMove': _allowHorizontalMove,
        'gradientStart': _gradientStart,
        'gradientEnd': _gradientEnd,
        'unplayedColor': _unplayedColor,
        'colorMode': _colorMode,
        'activePreset': _activePreset,
        'customStart': _customStart,
        'customEnd': _customEnd,
        'customUnplayed': _customUnplayed,
      });
    } catch (_) {}
  }

  static const _channel = MethodChannel('com.md3music.md3music/floating_lyric');
  static const _superLyricChannel = MethodChannel(
    'com.md3music.md3music/super_lyric',
  );
  // 通道名与原生 FlymeLyricBridge.CHANNEL_NAME 必须逐字一致
  static const _flymeChannel =
      MethodChannel('com.md3music.md3music/flyme_status_bar_lyric');

  void _syncCurrentFromPlayer() {
    if (_player == null) return;
    final song = _player!.currentSong;
    if (song != null) {
      // 切歌状态由 _onTick 统一重置；不要提前写 songId 绕过重置、锁死旧请求。
      // 同曲重开也要重发当前行（新窗口没有之前的内容），不受去重/迟滞限制。
      _currentLineIndex = -2;
      _lastLineSwitchAt = null;
      _pushProgress(_player!.position, _player!.duration ?? Duration.zero);
      _pushPlaying(_player!.isPlaying);
    }
    _onTick();
  }

  Future<void> _pushProgress(Duration pos, Duration dur) async {
    // 仅悬浮窗开启时推送：蓝牙歌词不需要 position/duration（通过 MediaSession 获取），
    // 且避免 startService 触发 FloatingLyricService.onCreate 显示悬浮窗通知
    if (!_enabled) return;
    try {
      await _channel.invokeMethod('updateProgress', {
        'position': pos.inMilliseconds,
        'duration': dur.inMilliseconds,
      });
    } catch (_) {}
  }

  Future<void> _pushPlaying(bool playing) async {
    _syncNativeSyncProbeInterval(playing);
    // 同 _pushProgress：仅悬浮窗开启时推送。
    // 推送成功才更新基线：失败时基线保持旧值，让 tick 自愈机制
    // 在下个周期重试（否则失败后永远不再推送，暂停冻结失效）。
    if (!_enabled) return;
    try {
      await _channel.invokeMethod('setPlaying', {'isPlaying': playing});
      _lastPushedPlaying = playing;
    } catch (_) {}
  }

  void _onTick() {
    if (!_shouldTick()) return;
    // 熄屏且未开锁屏歌词：悬浮窗不可见，tick 纯耗电，直接休眠
    // （点亮屏幕时由 screenStateChanged 回调补一拍对齐漂移）
    if (!_screenOn && !_lockScreenLyricEnabled) {
      _cancelLineTimer();
      _cancelFlymeLineTimer();
      return;
    }
    // provider 未绑定时（如 app 启动早期 context 未就绪）尝试重新绑定，
    // 绑定成功后下个 tick 即可正常推送；仍失败则跳过本次
    if (_player == null || _kugou == null) {
      _bindProvidersFromContext();
      if (_player == null || _kugou == null) return;
    }
    // 播放状态自愈：事件驱动的 setPlaying 若曾丢失（channel 异常被吞、
    // 时序竞争），原生 isPlayingFlag 停在 true → 逐字暂停后仍狂奔。
    // 每 tick 与 PlayerProvider 对账，不一致即重推（幂等，开销可忽略）。
    final tickPlaying = _player!.isPlaying;
    if (tickPlaying != _lastPushedPlaying) {
      // ignore: discarded_futures
      _pushPlaying(tickPlaying);
    }
    // 暂停时下一行永不到来：取消预测调度；tick 周期同步降频
    if (!tickPlaying) {
      _cancelLineTimer();
      _cancelFlymeLineTimer();
    }
    _syncTickInterval(tickPlaying);
    final song = _player!.currentSong;
    if (song == null) {
      if (_currentSongId != null) _lyricFetchToken++;
      _currentSongId = null;
      _awaitingLyric = false;
      _setParsedLines(const []);
      _currentLineIndex = -1;
      _flymeLineIndex = -1;
      _flymeLastSwitchAt = null;
      _flymePrevPosMs = -1;
      _cancelLineTimer();
      _cancelFlymeLineTimer();
      // 锁屏歌词：清空界面，避免残留上一首歌词
      _markLockLyricLoaded('');
      return;
    }

    // 切歌检测
    if (song.id != _currentSongId) {
      _currentSongId = song.id;
      _sessionGeneration++;
      _lyricFetchToken++;
      _setParsedLines(const []);
      _currentLineIndex = -1;
      _lastLineSwitchAt = null;
      _awaitingLyric = false;
      _lastPushedPosMs = null;
      // 新歌立即尝试拉取：清除上一首的失败退避状态
      _lyricFailedKey = null;
      _lyricFailCount = 0;
      _lyricNextRetryAt = null;
      _pushPlaying(_player!.isPlaying);
      _pushLyric('歌词加载中...', '', placeholder: '歌词加载中...');
      // SuperLyric：切歌时立即更新 title/artist（清空上一首歌词）
      if (_superLyricEnabled) {
        _pushSuperLyricLine(null);
      }
      // 魅族状态栏歌词：切歌时必须立即清空，否则上一首最后一句会一直挂在状态栏，
      // 直到新歌第一句歌词到来；若新歌没有歌词则永久残留。
      // 索引与迟滞一起归零：原生按"文本没变就不重发"去重，不清索引的话
      // 新歌若首句恰好与旧歌末句相同，会被当成重复推送吞掉。
      if (_flymeStatusBarLyricEnabled) {
        _pushFlymeLine('');
      }
      _flymeLineIndex = -1;
      _flymeLastSwitchAt = null;
      _flymePrevPosMs = -1;
      // LyricInfo：切歌时立即移除上一首的 lyricInfo，避免旧歌词短暂匹配到新歌
      if (_lyricInfoEnabled) {
        _lyricInfoPushed = false;
        MediaNotificationService.removeLyricInfo(
          songId: song.id,
          sessionGeneration: _sessionGeneration,
        );
      }
      // 锁屏歌词：切歌时推占位全量数据，避免残留上一首歌词
      _markLockLyricLoaded('歌词加载中...');
      _cancelLineTimer();
      _cancelFlymeLineTimer();
      _fetchLyricFor(song);
      return;
    }

    // 歌词加载只由带 token 的请求提交结果，不能直接读取 KugouProvider 的共享
    // current lyric；后者可能正被播放器页或 Lyricon 的另一首请求更新。
    // 判据用**未过滤**的 _rawLines：整首歌只有名单行被过滤掉时 _lines 为空，
    // 若按其判空会每 tick 重复发起取词（拉取成功→仍判空→再拉的无限循环）。
    if (!_awaitingLyric && _rawLines.isEmpty) {
      // 失败退避：同一首歌上次拉取失败且尚未到退避时限时跳过本轮
      if (_lyricNextRetryAt != null &&
          _lyricFailedKey == song.id &&
          DateTime.now().isBefore(_lyricNextRetryAt!)) {
        return;
      }
      _fetchLyricFor(song);
      return;
    }

    // LyricInfo：歌词加载完成后推送一次整首歌词（_lyricInfoPushed 去重）
    _maybePushLyricInfo();

    // Sync progress (500ms throttle)
    final pos = _player!.position;
    final dur = _player!.duration ?? Duration.zero;
    final posMs = pos.inMilliseconds;
    if (_lastPushedPosMs == null || (posMs - _lastPushedPosMs!).abs() > 500) {
      _lastPushedPosMs = posMs;
      _pushProgress(pos, dur);
    }

    // Find current line
    if (_lines.isEmpty) return;
    final newIndex = _findLineIndex(posMs);

    // 魅族状态栏歌词：走自己的提前量时间轴，与上面的共享索引互不影响
    if (_flymeStatusBarLyricEnabled) {
      _tickFlymeAdvance(posMs);
    }

    // 行变化时推送（逐行模式：每行只在进入时推一次，不高频刷字色）
    if (newIndex != _currentLineIndex) {
      // P0: 行切换 300ms 迟滞：position 抖动（MediaSession/just_audio 位置源相位差）
      // 会导致行在相邻行间来回跳变、同一行被重复推送（日志实测同一行被推 3~16 次）。
      // 迟滞窗口内保持当前行，稳定后才切换，消除无效推送。
      final now = DateTime.now();
      if (_lastLineSwitchAt != null &&
          now.difference(_lastLineSwitchAt!).inMilliseconds < 300) {
        // 迟滞窗口内：保持当前行，下个 tick 再判定
      } else {
        _lastLineSwitchAt = now;
        _currentLineIndex = newIndex;
        final line = newIndex >= 0 ? _lines[newIndex] : null;
        final current = line?.text ?? '';
        final next = (_doubleLine && newIndex + 1 < _lines.length)
            ? _lines[newIndex + 1].text
            : '';
        // KRC 逐字：行切换时一次推送整行字级时间戳 + 当时的播放位置，
        // 原生按本地时钟自驱动逐字推进（每字边界一次 invalidate），
        // Dart 不再做 100ms 高频推送；LRC/纯文本行 words 为空走整行渐变色
        // （显式标注类型：三元分支与 const [] 的 LUB 是 List<dynamic>，需上下文类型）
        final List<Map<String, Object?>> words =
            (line != null && line.words.isNotEmpty)
            ? [
                for (final w in line.words)
                  {'t': w.text, 's': w.startTime, 'd': w.duration},
              ]
            : const [];
        _pushLyric(current, next, words: words, positionMs: posMs);
        // SuperLyric：行变化时推送当前行（含逐字 words、翻译、副歌词）
        if (_superLyricEnabled) {
          _pushSuperLyricLine(line);
        }
        // 魅族状态栏歌词不在此处推：它有自己的提前量与迟滞，见 _tickFlymeAdvance。
        // 预测调度：下一行起始时刻精确触发，切行延迟从最坏 250ms 降到 Timer 精度
        if (newIndex + 1 < _lines.length) {
          _scheduleLineBoundary(newIndex + 1);
        }
      }
    }

    // 锁屏歌词：每 tick 入口（全量脏 → 整包重推；否则 500ms 节流轻量进度）
    _pushLockScreenTick();
  }

  Future<void> _fetchLyricFor(Song song) async {
    if (_awaitingLyric) return;
    final requestedSongId = song.id;
    final token = ++_lyricFetchToken;
    _awaitingLyric = true;
    try {
      // 这首歌自己的匹配记录：hash 精确检索 + 单曲偏好「使用在线歌词」
      await SongMatchRepository().ensureLoaded();
      final matchInfo =
          song.isOnline ? null : SongMatchRepository().get(song.id);
      final preferOnlineLyrics = matchInfo?.preferOnlineLyrics == true;

      if (!song.isOnline && !preferOnlineLyrics) {
        final localPath = song.localPath;
        if (localPath != null && localPath.isNotEmpty) {
          String filePath = localPath;
          if (filePath.startsWith('file://')) {
            filePath = Uri.parse(filePath).toFilePath();
          }
          final embedded = await LocalLyricLoader.loadForAudioAsync(filePath);
          if (embedded != null && embedded.isNotEmpty) {
            if (!_isCurrentLyricRequest(token, requestedSongId)) return;
            final lines = await parseLyricOffMainThread(embedded);
            // isolate 解析期间可能已切歌：迟到结果直接丢弃
            if (!_isCurrentLyricRequest(token, requestedSongId)) return;
            _setParsedLines(lines);
            // 占位判据用**未过滤**的 _rawLines：整首歌只有名单行被过滤时，
            // 显示侧为空是「按用户偏好隐藏」，不是「这首歌没有歌词」，
            // 推「暂无歌词」会让用户误以为取词失败。
            if (_rawLines.isEmpty) {
              _pushLyric('暂无歌词', '', placeholder: '暂无歌词');
            }
            _markLockLyricLoaded(_rawLines.isEmpty ? '暂无歌词' : '');
            _currentLineIndex = -2;
            _lastLineSwitchAt = null;
            _onTick();
            return;
          }
        }
      }

      // 用 isUnknownArtist 而非比较单一字面量：一起听跟随端的占位值是
      // 「未知歌手」、本地侧是「未知艺术家」，只比一个会漏判，
      // 导致把「未知歌曲 未知歌手」当检索词去搜。
      final searchName = !isUnknownArtist(song.artist)
          ? '${song.title} ${song.artist}'
          : song.title;
      // 本地歌曲：命中匹配记忆时用在线 hash 精确检索；未命中退化为按歌名搜索
      final matchedHash =
          (matchInfo != null && matchInfo.isMatched) ? matchInfo.hash : null;
      // 首份 LRC 先显示，不等待补充逐字歌词；串行解析防止迟到的初稿覆盖终稿。
      Future<void> progressCommit = Future<void>.value();
      final result = await _kugou!.getLyricResult(
        matchedHash ?? (song.isOnline ? song.id : ''),
        songName: searchName,
        fmt: 'lrc',
        localIdentity: song.isOnline ? null : song.localPath,
        onProgress: (lyric) {
          if (!_isCurrentLyricRequest(token, requestedSongId) ||
              lyric.displayLyric.isEmpty) {
            return;
          }
          progressCommit = progressCommit.then((_) async {
            if (!_isCurrentLyricRequest(token, requestedSongId)) return;
            await _commitFetchedLyric(lyric, token, requestedSongId);
          });
        },
      );
      await progressCommit;
      if (!_isCurrentLyricRequest(token, requestedSongId)) return;
      switch (result.status) {
        case LyricLookupStatus.found:
          if (await _commitFetchedLyric(
            result.lyric!,
            token,
            requestedSongId,
          )) {
            _clearLyricRetryState();
          }
          break;
        case LyricLookupStatus.notFound:
          if (_rawLines.isNotEmpty) break;
          _commitNoLyrics(requestedSongId);
          break;
        case LyricLookupStatus.transientFailure:
          if (_rawLines.isNotEmpty) break;
          _recordLyricFailure(requestedSongId, '歌词加载失败', result.status);
          break;
        case LyricLookupStatus.invalidData:
          if (_rawLines.isNotEmpty) break;
          _recordLyricFailure(requestedSongId, '歌词数据无效', result.status);
          break;
        case LyricLookupStatus.canceled:
          return;
      }
    } catch (_) {
      if (_isCurrentLyricRequest(token, requestedSongId) &&
          _rawLines.isEmpty) {
        _recordLyricFailure(
          requestedSongId,
          '歌词加载失败',
          LyricLookupStatus.transientFailure,
        );
      }
    } finally {
      // 旧请求完成不能把新请求的 awaiting 状态清掉。
      if (token == _lyricFetchToken) _awaitingLyric = false;
    }
  }

  bool _isCurrentLyricRequest(int token, String songId) =>
      token == _lyricFetchToken &&
      _currentSongId == songId &&
      _player?.currentSong?.id == songId;

  Future<bool> _commitFetchedLyric(
    KugouLyric lyric,
    int token,
    String requestedSongId,
  ) async {
    if (lyric.displayLyric.isEmpty) {
      if (_rawLines.isEmpty) _commitNoLyrics(requestedSongId);
      return false;
    }
    late final List<LyricLine> lines;
    try {
      lines = await parseLyricOffMainThread(
        lyric.displayLyric,
        translationText: lyric.translatedContent,
        romaText: lyric.romaContent,
      );
    } catch (_) {
      if (_isCurrentLyricRequest(token, requestedSongId) &&
          _rawLines.isEmpty) {
        _recordLyricFailure(
          requestedSongId,
          '歌词解析失败',
          LyricLookupStatus.invalidData,
        );
      }
      return false;
    }
    // isolate 解析期间可能已切歌：迟到结果直接丢弃
    if (!_isCurrentLyricRequest(token, requestedSongId)) return false;
    if (lines.isEmpty) {
      if (_rawLines.isNotEmpty) return false;
      _recordLyricFailure(
        requestedSongId,
        '歌词解析失败',
        LyricLookupStatus.invalidData,
      );
      return false;
    }
    _setParsedLines(lines);
    _lyricInfoPushed = false;
    _currentLineIndex = -2;
    _lastLineSwitchAt = null;
    _clearLyricRetryState();
    _markLockLyricLoaded('');
    _onTick();
    debugPrint('[DesktopLyric] lyrics ready: lines=${lines.length}');
    return true;
  }

  void _commitNoLyrics(String songId) {
    _pushLyric('暂无歌词', '', placeholder: '暂无歌词');
    _markLockLyricLoaded('暂无歌词');
    _lyricFailedKey = songId;
    _lyricFailCount = 0;
    _lyricNextRetryAt = DateTime.now().add(
      LyricRetryPolicy.delayFor(LyricLookupStatus.notFound, 0),
    );
  }

  void _recordLyricFailure(
    String songId,
    String placeholder,
    LyricLookupStatus status,
  ) {
    _pushLyric(placeholder, '', placeholder: placeholder);
    _markLockLyricLoaded(placeholder);
    _lyricFailCount = _lyricFailedKey == songId ? _lyricFailCount + 1 : 1;
    _lyricFailedKey = songId;
    _lyricNextRetryAt = DateTime.now().add(
      LyricRetryPolicy.delayFor(status, _lyricFailCount),
    );
  }

  void _clearLyricRetryState() {
    _lyricFailedKey = null;
    _lyricFailCount = 0;
    _lyricNextRetryAt = null;
  }

  int? _lastPushedPosMs;

  /// 推送当前行文本到原生悬浮窗。
  ///
  /// - [placeholder] 非空时原生显示占位文案（歌词加载中.../暂无歌词/歌词加载失败）；
  ///   空串表示正常行：间奏期 current 为空串时原生显示空白，不再误显"加载中"。
  /// - 蓝牙歌词分支保持既有占位过滤行为不变。
  Future<void> _pushLyric(
    String current,
    String next, {
    String placeholder = '',
    List<Map<String, Object?>> words = const [],
    int positionMs = 0,
  }) async {
    if (_enabled) {
      try {
        await _channel.invokeMethod('updateLyric', {
          'lyric': current,
          'nextLyric': next,
          'placeholder': placeholder,
          'words': words,
          'positionMs': positionMs,
        });
      } catch (_) {}
    }
    if (_bluetoothLyricEnabled) {
      final btText = (placeholder.isNotEmpty) ? '' : current;
      try {
        await MediaNotificationService.updateBluetoothLyric(btText);
      } catch (_) {}
    }
  }

  /// 推送当前歌词行到 SuperLyric（基于 Binder 的系统级实时歌词 API）。
  ///
  /// [line] 为 null 时只发 title/artist（清空当前歌词，用于切歌/关闭开关）。
  /// 核心字段映射：
  /// - title/artist：取当前歌曲的 displayName（剥后缀）与 artist
  /// - 主行：text + words（逐字）+ startTime/endTime
  /// - translation：翻译（SuperLyricData.setTranslation）
  /// - roma：副歌词（SuperLyricData.setSecondary）
  /// 播放/暂停由 SuperLyric 自动监听 App 的 MediaSession 处理，这里不推停止事件。
  Future<void> _pushSuperLyricLine(LyricLine? line) async {
    if (_player == null) return;
    final song = _player!.currentSong;
    if (song == null) return;

    final Map<String, dynamic> args = {
      'title': song.displayName,
      'artist': song.artist,
    };
    if (line != null) {
      final text = line.text.trim();
      if (text.isNotEmpty) {
        final int startTime = line.startTime;
        // endTime 兜底：LRC duration=0 时 endTime==startTime，补一个合法 end（参照 Lyricon）
        final int endTime = line.endTime > startTime
            ? line.endTime
            : startTime + 5000;
        // 同时存在翻译和罗马音时按偏好二选一（参照 Lyricon preferTranslation），
        // 避免 SuperLyric 接收端优先显示 secondary(roma) 导致"总是罗马音"。
        // 翻译/罗马音还受共用开关 _pushTranslation / _pushRoma 控制。
        final hasTranslation =
            _pushTranslation &&
            line.translation != null &&
            line.translation!.isNotEmpty;
        final hasRoma = _pushRoma && line.roma != null && line.roma!.isNotEmpty;
        final translationValue =
            hasTranslation && hasRoma && !_superLyricPreferTranslation
            ? null
            : line.translation;
        final romaValue =
            hasRoma && hasTranslation && _superLyricPreferTranslation
            ? null
            : line.roma;
        args.addAll({
          'text': text,
          'startTime': startTime,
          'endTime': endTime,
          'words': line.words
              .map(
                (w) => <String, dynamic>{
                  'text': w.text,
                  'start': w.startTime,
                  'end': w.startTime + w.duration,
                },
              )
              .toList(),
          if (translationValue != null && translationValue.isNotEmpty)
            'translation': translationValue,
          if (romaValue != null && romaValue.isNotEmpty) 'roma': romaValue,
        });
      }
    }
    try {
      await _superLyricChannel.invokeMethod('sendLyric', args);
    } catch (_) {}
  }

  /// 歌词加载结果已落入 [_lines]：更新锁屏占位状态并立即整包重推。
  ///
  /// [placeholder] 非空时无歌词列表、锁屏居中显示占位文本
  /// （歌词加载中.../暂无歌词/歌词加载失败）；空串表示正常显示列表。
  void _markLockLyricLoaded(String placeholder) {
    if (!_lockScreenLyricEnabled) return;
    _lockPlaceholder = placeholder;
    _lockFullDirty = true;
    _pushLockScreenFullData();
  }

  /// LyricInfo：歌词就绪后推送一次整首歌词（_lyricInfoPushed 去重，每首歌 1 次）。
  /// 仅在 [_pushLyricInfo] 真正完成推送后才置位去重标志：若中途因无歌/空行等提前
  /// 返回，则保持 false 让后续 tick 重试，避免该曲 lyricInfo 永久丢失。
  void _maybePushLyricInfo() {
    if (!_lyricInfoEnabled || _lyricInfoPushed) return;
    if (_lines.isEmpty) return;
    if (_pushLyricInfo()) {
      _lyricInfoPushed = true;
    }
  }

  /// 构造并推送 lyricInfo JSON。
  ///
  /// colorOsMode=false：lidesheng LyricInfo 规范（HyperLyric 等），
  /// lyric=原文逐行 LRC + rawLyric=原文增强 + translation/roma 独立 lane；
  /// colorOsMode=true（默认）：兼容 ColorOS-Live-Lyrics-Bridge 开放协议，
  /// lyric=纯 LRC + rawLyric=ELRC 逐字，解锁插件逐字高亮等增强。
  /// 翻译/罗马音 lane 受共用开关 [_pushTranslation] / [_pushRoma] 控制
  /// （与 ColorOS 模式共用归一化规则，原生侧 hasTranslation 能力位口径一致）。
  /// 返回是否真正发起了推送（供 _maybePushLyricInfo 决定是否置位去重标志）。
  bool _pushLyricInfo() {
    if (!_lyricInfoEnabled || _player == null) return false;
    final song = _player!.currentSong;
    if (song == null) return false;

    final json = buildLyricInfoJson(
      songName: song.displayName,
      artist: song.artist,
      songId: song.id,
      album: song.album,
      trackKey:
          '${song.id}|${song.displayName}|${song.artist}|${song.duration.inSeconds}',
      sessionGeneration: _sessionGeneration,
      lines: _lines,
      includeTranslation: _pushTranslation,
      includeRoma: _pushRoma,
      colorOsMode: _lyricInfoColorOs,
    );
    if (json.isEmpty) return false; // 无有效歌词行：不推送（保持移除状态）

    MediaNotificationService.updateLyricInfo(
      jsonEncode(json),
      songId: song.id,
      sessionGeneration: _sessionGeneration,
      hasTranslation: hasPushableTranslation(
        _lines,
        includeTranslation: _pushTranslation,
      ),
    );
    return true;
  }

  /// 二分查找当前播放位置对应的歌词行 index。
  ///
  /// _lines 已按 startTime 升序排列（LyricParserChain 保证），
  /// 找到最后一个 startTime <= posMs 的行。
  int _findLineIndex(int posMs) {
    int lo = 0;
    int hi = _lines.length - 1;
    int idx = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (_lines[mid].startTime <= posMs) {
        idx = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return idx;
  }
}
