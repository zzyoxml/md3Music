import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/layout/ui_density.dart';
import '../core/services/custom_font_loader.dart';
import '../core/theme/app_theme.dart';

class ThemeProvider extends ChangeNotifier {
  static const String _key = 'theme_mode';
  static const String _dynamicKey = 'use_dynamic_color';
  static const String _coverDynamicKey = 'use_cover_dynamic_color';
  static const String _amStylePlayerKey = 'use_am_style_player';
  static const String _manualSeedKey = 'manual_seed_color';
  static const String _oledBlackKey = 'use_oled_black';
  // 「显示大小」档位（安卓系统同名设置的语义，见 core/layout/ui_density.dart）
  static const String _displayScaleKey = 'ui_display_scale';
  // 已废弃的逐元素缩放键，加载时清理（见 _loadDisplayScale）
  static const String _legacyUiScaleKey = 'ui_scale';
  // 底部导航栏文字显示行为：始终显示 / 仅当前页 / 始终不显示
  static const String _navLabelBehaviorKey = 'nav_label_behavior';
  static const String _fontSourceKey = 'font_source';
  static const String _customFontPathKey = 'custom_font_path';
  static const String _artistPhotoBgKey = 'use_artist_photo_background';
  static const String _artistPhotoIntervalKey = 'artist_photo_interval';
  static const String _artistPhotoOpacityKey = 'artist_photo_opacity';
  static const String _lyricDoubleTapToJumpKey = 'lyric_double_tap_to_jump';
  // 自定义背景图片（全局界面背景）
  static const String _bgImageEnabledKey = 'use_background_image';
  static const String _bgImagePathKey = 'background_image_path';
  static const String _bgBlurKey = 'background_blur';
  static const String _bgOpacityKey = 'background_opacity';
  // 按背景图莫奈取色开关（默认开启）
  static const String _bgMonetKey = 'use_background_monet';
  // 文字阴影开关（默认开启，仅在启用自定义背景图片时生效）
  static const String _textShadowKey = 'use_text_shadow';
  static const String _textShadowBlurKey = 'text_shadow_blur';

  ThemeMode _themeMode = ThemeMode.system;
  bool _useDynamicColor = false;
  Color? _systemSeedColor;
  // 封面动态取色：根据当前播放歌曲封面颜色动态改变全局主题色。
  // 开启且提取成功时优先级高于系统壁纸色（见 effectiveSeedColor）。
  bool _useCoverSeedColor = false;
  Color? _coverSeedColor;
  bool _useAmStylePlayer = false;
  Color? _manualSeedColor;
  bool _useOledBlack = false;
  double _displayScale = kDefaultDisplayScale;
  // 底部导航栏文字显示行为（默认始终不显示）
  NavigationDestinationLabelBehavior _navLabelBehavior =
      NavigationDestinationLabelBehavior.alwaysHide;
  // 字体来源（system / bundled / custom）
  FontSource _fontSource = FontSource.system;
  // 用户选择的字体文件路径（原生端拷贝到 filesDir 后的真实路径）
  String? _customFontPath;
  // 运行时加载成功后填充的 fontFamily（仅在 custom 模式且加载成功时非 null）
  String? _loadedCustomFontFamily;
  bool _useArtistPhotoBackground = false;
  int _artistPhotoInterval = 15;
  double _artistPhotoOpacity = 0.55;
  // AM 风格播放器歌词双击跳转开关（默认关闭，开启后需双击歌词才能跳转位置）
  bool _lyricDoubleTapToJump = false;
  // 自定义背景图片（全局界面背景）；默认开启，未选择图片时回落到内置默认壁纸
  bool _useBackgroundImage = true;
  String? _backgroundImagePath;
  double _backgroundBlur = 20.0;
  double _backgroundOpacity = 0.4;
  // 按背景图莫奈取色（默认开启；关闭后背景图仍显示但不参与主题色）
  bool _useBackgroundMonet = true;
  // 文字阴影（默认关闭）：给全局文字加轮廓阴影，改善背景图上的可读性。
  // 仅在 _useBackgroundImage 为 true 时生效（见 [useTextShadowEffective]）。
  bool _useTextShadow = false;
  // 文字阴影磅数（阴影模糊半径，用户可调）
  double _textShadowBlur = AppTheme.defaultTextShadowBlur;
  // 从背景图片提取的主色（运行时，作为莫奈取色种子）
  Color? _backgroundSeedColor;

  ThemeMode get themeMode => _themeMode;
  bool get useDynamicColor => _useDynamicColor;
  Color? get systemSeedColor => _systemSeedColor;
  bool get useCoverSeedColor => _useCoverSeedColor;
  Color? get coverSeedColor => _coverSeedColor;
  bool get useAmStylePlayer => _useAmStylePlayer;
  Color? get manualSeedColor => _manualSeedColor;
  bool get useOledBlack => _useOledBlack;
  double get displayScale => _displayScale;
  NavigationDestinationLabelBehavior get navLabelBehavior => _navLabelBehavior;
  FontSource get fontSource => _fontSource;
  String? get customFontPath => _customFontPath;
  bool get useArtistPhotoBackground => _useArtistPhotoBackground;
  int get artistPhotoInterval => _artistPhotoInterval;
  double get artistPhotoOpacity => _artistPhotoOpacity;
  bool get lyricDoubleTapToJump => _lyricDoubleTapToJump;
  bool get useBackgroundImage => _useBackgroundImage;
  String? get backgroundImagePath => _backgroundImagePath;
  double get backgroundBlur => _backgroundBlur;
  double get backgroundOpacity => _backgroundOpacity;
  bool get useBackgroundMonet => _useBackgroundMonet;
  bool get useTextShadow => _useTextShadow;
  double get textShadowBlur => _textShadowBlur;
  Color? get backgroundSeedColor => _backgroundSeedColor;

  /// 文字阴影是否实际生效：开关本身开启 **且** 已启用自定义背景图片。
  /// 未启用背景图时纯色主题自带足够对比度，阴影只会让文字发虚，故不生效。
  bool get useTextShadowEffective => _useBackgroundImage && _useTextShadow;

  /// 当前生效的种子色优先级：
  /// 1. 启用封面动态取色且提取成功 → 歌曲封面主色（可叠加系统主题色，封面优先）
  /// 2. 启用自定义背景图片且开启莫奈取色并取色成功 → 背景图片主色
  /// 3. 启用系统主题色且成功取到 → 系统主色
  /// 4. 用户手动选择非 null → 手动色
  /// 5. 默认蓝色种子（[AppTheme.defaultSeedColor]）
  ///
  /// 封面取色开启但提取失败（[_coverSeedColor] 为 null，如无封面/本地图损坏）
  /// 时自然回落到后续级别，完成兜底。
  Color get effectiveSeedColor {
    if (_useCoverSeedColor && _coverSeedColor != null) {
      return _coverSeedColor!;
    }
    if (_useBackgroundImage && _useBackgroundMonet && _backgroundSeedColor != null) {
      return _backgroundSeedColor!;
    }
    if (_useDynamicColor && _systemSeedColor != null) {
      return _systemSeedColor!;
    }
    return _manualSeedColor ?? AppTheme.defaultSeedColor;
  }

  /// 当前生效的 fontFamily（传给 AppTheme）：
  /// - [FontSource.system]：返回 null（让 Flutter 走系统字体链）
  /// - [FontSource.bundled]：返回 'SimHei'
  /// - [FontSource.custom]：返回 [_loadedCustomFontFamily]，
  ///   加载失败时为 null（实际降级为 system 行为）
  String? get effectiveFontFamily {
    switch (_fontSource) {
      case FontSource.system:
        return null;
      case FontSource.bundled:
        return 'SimHei';
      case FontSource.custom:
        return _loadedCustomFontFamily;
    }
  }

  ThemeProvider() {
    _loadThemeMode();
    _loadDynamicColor();
    _loadUseCoverSeedColor();
    _loadAmStylePlayer();
    _loadManualSeedColor();
    _loadOledBlack();
    _loadDisplayScale();
    _loadNavLabelBehavior();
    _loadFontSource();
    _loadArtistPhotoBackground();
    _loadLyricDoubleTapToJump();
    _loadBackgroundImage();
  }

  Future<void> _loadThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    final savedIndex = prefs.getInt(_key);
    if (savedIndex != null && savedIndex >= 0 && savedIndex < ThemeMode.values.length) {
      _themeMode = ThemeMode.values[savedIndex];
      notifyListeners();
    }
  }

  Future<void> _saveThemeMode(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key, mode.index);
  }

  /// 加载「使用系统主题色」开关持久化值，若开启则同步提取系统主色。
  Future<void> _loadDynamicColor() async {
    final prefs = await SharedPreferences.getInstance();
    _useDynamicColor = prefs.getBool(_dynamicKey) ?? false;
    if (_useDynamicColor) {
      await _loadSystemColor();
    }
    notifyListeners();
  }

  /// 优化版系统色提取（HCT 多点评分）：
  /// 1. 取系统 palette.primary 的 5 个 tone（30/35/40/45/50）作为候选
  /// 2. 用 [Score.score] 在 HCT 色彩空间评分候选，按适合度降序排列
  ///    （参考 MaterialKolor 的 Score 评分流程）
  /// 3. 选分最高者作为种子色
  /// 失败时降级为 [CorePalette.primary.get(40)]（与改造前行为一致）。
  ///
  /// 参考：https://github.com/jordond/MaterialKolor
  /// Flutter 端等价包：material_color_utilities（Google 官方 Dart 端口）
  ///
  /// 注意：MaterialKolor 原流程是 QuantizerCelebi + Score，但 QuantizerCelebi
  /// 内部基于 QuantizerWu（为图片像素设计），对 5 个候选 tone 的少量输入不稳定。
  /// 这里直接调 Score.score 评分候选 tone，更稳定且符合「HCT 评分选最佳」的核心思想。
  Future<void> _loadSystemColor() async {
    try {
      final palette = await DynamicColorPlugin.getCorePalette();
      if (palette == null) {
        _systemSeedColor = null;
        return;
      }

      // 候选 tone 列表：覆盖 M3 primary 的典型取值范围（默认 tone=40，向上下扩展）
      const candidateTones = [30, 35, 40, 45, 50];
      // 构造 population map：每个候选 tone 等权重出现 1 次
      // Score.score 内部会根据 HCT 色彩空间评分（chroma / proportion / 过滤），按适合度降序
      final colorsToPopulation = <int, int>{
        for (final tone in candidateTones) palette.primary.get(tone): 1,
      };

      // Score 评分并选最佳（返回按适合度降序排列的 ARGB 列表）
      // desired 设为候选数，确保返回尽可能多的候选；fallbackColorARGB 用默认紫色
      final scored = Score.score(
        colorsToPopulation,
        desired: candidateTones.length,
        fallbackColorARGB: AppTheme.defaultSeedColor.toARGB32(),
      );
      if (scored.isEmpty) {
        // 评分失败降级到原 get(40) 行为
        _systemSeedColor = Color(palette.primary.get(40));
        return;
      }
      _systemSeedColor = Color(scored.first);
    } catch (_) {
      _systemSeedColor = null;
    }
  }

  /// 切换「使用系统主题色」开关。
  Future<void> setUseDynamicColor(bool enabled) async {
    if (_useDynamicColor == enabled) return;
    _useDynamicColor = enabled;
    if (enabled) {
      await _loadSystemColor();
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_dynamicKey, enabled);
  }

  /// 加载「封面动态取色」开关持久化值，默认关闭。
  Future<void> _loadUseCoverSeedColor() async {
    final prefs = await SharedPreferences.getInstance();
    _useCoverSeedColor = prefs.getBool(_coverDynamicKey) ?? false;
    notifyListeners();
  }

  /// 切换「封面动态取色」开关。
  ///
  /// 与「使用系统主题色」相互独立、可叠加；都开启时封面取色优先
  /// （见 [effectiveSeedColor]）。关闭时不立即清空 [_coverSeedColor]，
  /// 由优先级链天然忽略；切歌桥接仍会持续更新缓存色。
  Future<void> setUseCoverSeedColor(bool enabled) async {
    if (_useCoverSeedColor == enabled) return;
    _useCoverSeedColor = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_coverDynamicKey, enabled);
  }

  /// 更新封面提取色（由切歌桥接调用）。
  ///
  /// 仅运行时保存、不落盘（颜色随歌曲变化）；传 null 表示提取失败/无封面，
  /// effectiveSeedColor 自动回落到系统壁纸色/手动色/默认紫。
  void setCoverSeedColor(Color? color) {
    if (_coverSeedColor == color) return;
    _coverSeedColor = color;
    notifyListeners();
  }

  /// 加载「Apple Music 风格播放页」开关持久化值，默认关闭。
  Future<void> _loadAmStylePlayer() async {
    final prefs = await SharedPreferences.getInstance();
    _useAmStylePlayer = prefs.getBool(_amStylePlayerKey) ?? false;
    notifyListeners();
  }

  /// 切换「Apple Music 风格播放页」开关。
  /// - 开启：用 AM 风格 FullPlayer（模糊封面背景 + 弹簧动画 + KRC 逐字歌词）
  /// - 关闭：用原版 MD3 FullPlayer（标准主题色 + LRC 行级歌词）
  /// 切换后已打开的 FullPlayer 不会立即换 widget，下次 push 时才走新分支。
  Future<void> setUseAmStylePlayer(bool enabled) async {
    if (_useAmStylePlayer == enabled) return;
    _useAmStylePlayer = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_amStylePlayerKey, enabled);
  }

  /// 加载「歌词双击跳转」开关持久化值，默认关闭。
  Future<void> _loadLyricDoubleTapToJump() async {
    final prefs = await SharedPreferences.getInstance();
    _lyricDoubleTapToJump = prefs.getBool(_lyricDoubleTapToJumpKey) ?? false;
    notifyListeners();
  }

  /// 切换「歌词双击跳转」开关。
  /// - 开启：需双击歌词行才能跳转播放位置
  /// - 关闭：单击即可跳转（默认行为）
  Future<void> setLyricDoubleTapToJump(bool enabled) async {
    if (_lyricDoubleTapToJump == enabled) return;
    _lyricDoubleTapToJump = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_lyricDoubleTapToJumpKey, enabled);
  }

  /// 加载「歌手写真背景轮播」开关 + 轮播间隔持久化值，默认关闭 / 15 秒。
  Future<void> _loadArtistPhotoBackground() async {
    final prefs = await SharedPreferences.getInstance();
    _useArtistPhotoBackground = prefs.getBool(_artistPhotoBgKey) ?? false;
    _artistPhotoInterval = prefs.getInt(_artistPhotoIntervalKey) ?? 15;
    _artistPhotoOpacity = prefs.getDouble(_artistPhotoOpacityKey) ?? 0.55;
    notifyListeners();
  }

  /// 切换「歌手写真背景轮播」开关（仅 MD3 风格播放页生效）。
  Future<void> setUseArtistPhotoBackground(bool enabled) async {
    if (_useArtistPhotoBackground == enabled) return;
    _useArtistPhotoBackground = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_artistPhotoBgKey, enabled);
  }

  /// 设置写真轮播间隔（秒），限定 5~60。
  Future<void> setArtistPhotoInterval(int seconds) async {
    final clamped = seconds.clamp(5, 60);
    if (_artistPhotoInterval == clamped) return;
    _artistPhotoInterval = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_artistPhotoIntervalKey, clamped);
  }

  /// 设置写真背景遮罩透明度（0.0=全透看不清文字 ~ 1.0=全遮看不到写真），限定 0.0~0.95。
  Future<void> setArtistPhotoOpacity(double opacity) async {
    final clamped = opacity.clamp(0.0, 0.95);
    if (_artistPhotoOpacity == clamped) return;
    _artistPhotoOpacity = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_artistPhotoOpacityKey, clamped);
  }

  /// 加载用户手动选择的种子色持久化值。
  Future<void> _loadManualSeedColor() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getInt(_manualSeedKey);
    if (value != null) {
      _manualSeedColor = Color(value);
      notifyListeners();
    }
  }

  /// 设置手动种子色。传 null 清除（回退默认紫色）。
  Future<void> setManualSeedColor(Color? color) async {
    if (_manualSeedColor == color) return;
    _manualSeedColor = color;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (color != null) {
      await prefs.setInt(_manualSeedKey, color.toARGB32());
    } else {
      await prefs.remove(_manualSeedKey);
    }
  }

  /// 加载「OLED 纯黑深色模式」开关持久化值，默认关闭。
  Future<void> _loadOledBlack() async {
    final prefs = await SharedPreferences.getInstance();
    _useOledBlack = prefs.getBool(_oledBlackKey) ?? false;
    notifyListeners();
  }

  /// 切换「OLED 纯黑深色模式」开关。
  /// 开启时 darkTheme 的 surface 系列覆盖为纯黑（仅深色模式生效）。
  Future<void> setUseOledBlack(bool enabled) async {
    if (_useOledBlack == enabled) return;
    _useOledBlack = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_oledBlackKey, enabled);
  }

  /// 加载「显示大小」档位，默认 [kDefaultDisplayScale]（设备真实 dp）。
  ///
  /// 顺带清掉旧键 `ui_scale`：那是已删除的逐元素缩放实现留下的，值域 0.5~5.0，
  /// 沿用会让存了 3.0 的用户拿到 131dp 宽的视口。不做值迁移，一律从 1.00 起。
  Future<void> _loadDisplayScale() async {
    final prefs = await SharedPreferences.getInstance();
    _displayScale = (prefs.getDouble(_displayScaleKey) ?? kDefaultDisplayScale)
        .clamp(kMinDisplayScale, kMaxDisplayScale);
    notifyListeners();
    await prefs.remove(_legacyUiScaleKey);
  }

  /// 设置「显示大小」档位（[kMinDisplayScale] ~ [kMaxDisplayScale]）。
  Future<void> setDisplayScale(double scale) async {
    final clamped = scale.clamp(kMinDisplayScale, kMaxDisplayScale);
    if (_displayScale == clamped) return;
    _displayScale = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_displayScaleKey, clamped);
  }

  /// 加载底部导航栏文字显示行为的持久化值，默认始终不显示。
  Future<void> _loadNavLabelBehavior() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_navLabelBehaviorKey);
    if (index != null &&
        index >= 0 &&
        index < NavigationDestinationLabelBehavior.values.length) {
      _navLabelBehavior = NavigationDestinationLabelBehavior.values[index];
    }
    notifyListeners();
  }

  /// 设置底部导航栏文字显示行为并持久化。
  Future<void> setNavLabelBehavior(NavigationDestinationLabelBehavior value) async {
    if (_navLabelBehavior == value) return;
    _navLabelBehavior = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_navLabelBehaviorKey, value.index);
  }

  void toggleTheme() {
    switch (_themeMode) {
      case ThemeMode.light:
        setThemeMode(ThemeMode.dark);
        break;
      case ThemeMode.dark:
        setThemeMode(ThemeMode.system);
        break;
      case ThemeMode.system:
        setThemeMode(ThemeMode.light);
        break;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
    await _saveThemeMode(mode);
  }

  // ============== 字体来源 ==============

  /// 加载持久化的字体来源与自定义字体路径。
  /// 读完后若为 custom 模式，自动触发 FontLoader 注册（异步，不阻塞构造）。
  Future<void> _loadFontSource() async {
    final prefs = await SharedPreferences.getInstance();
    _fontSource = CustomFontLoader.fromName(prefs.getString(_fontSourceKey));
    _customFontPath = prefs.getString(_customFontPathKey);
    notifyListeners();
    // 若已配置自定义字体，立即尝试加载（Fire-and-forget，加载完成后会 notifyListeners）
    if (_fontSource == FontSource.custom) {
      await _tryLoadCustomFont();
    }
  }

  /// 设置字体来源并持久化。
  /// 切换到 custom 时若 [_loadedCustomFontFamily] 仍为 null（未加载成功），
  /// 调用方应同时调用 [setCustomFontPath] 触发加载流程。
  Future<void> setFontSource(FontSource source) async {
    if (_fontSource == source) return;
    _fontSource = source;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_fontSourceKey, source.name);
  }

  /// 设置自定义字体文件路径并立即尝试加载注册。
  /// 传 null 清除路径并卸载已加载的字体（实际效果降级到 system）。
  Future<void> setCustomFontPath(String? path) async {
    if (_customFontPath == path) return;
    _customFontPath = path;
    final prefs = await SharedPreferences.getInstance();
    if (path != null) {
      await prefs.setString(_customFontPathKey, path);
      // 立即尝试加载（路径变化时重新注册）
      await _tryLoadCustomFont();
    } else {
      await prefs.remove(_customFontPathKey);
      _loadedCustomFontFamily = null;
      notifyListeners();
    }
  }

  /// 启动时调用：若 fontSource == custom 且 path 存在，尝试加载注册。
  /// 失败时静默降级（不修改持久化值，UI 表现等同 system）。
  Future<void> loadCustomFontOnStartup() async {
    if (_fontSource != FontSource.custom) return;
    await _tryLoadCustomFont();
  }

  /// 内部：尝试用 FontLoader 加载 [_customFontPath] 指向的字体文件。
  /// 加载成功则填充 [_loadedCustomFontFamily] 并 notifyListeners。
  /// 失败时 [_loadedCustomFontFamily] 置 null，UI 自然降级为 system 行为。
  Future<void> _tryLoadCustomFont() async {
    final path = _customFontPath;
    final family = await CustomFontLoader.loadIfAvailable(path);
    final changed = family != _loadedCustomFontFamily;
    _loadedCustomFontFamily = family;
    if (changed) notifyListeners();
  }

  // ============== 自定义背景图片 ==============

  /// 加载背景图片相关持久化值（开关 / 路径 / 模糊 / 透明度 / 莫奈取色 / 文字阴影），
  /// 默认开启（无用户图片时用内置默认壁纸）/ 莫奈取色默认开启 / 文字阴影默认开启。
  Future<void> _loadBackgroundImage() async {
    final prefs = await SharedPreferences.getInstance();
    _useBackgroundImage = prefs.getBool(_bgImageEnabledKey) ?? true;
    _backgroundImagePath = prefs.getString(_bgImagePathKey);
    _backgroundBlur = prefs.getDouble(_bgBlurKey) ?? 20.0;
    _backgroundOpacity = prefs.getDouble(_bgOpacityKey) ?? 0.4;
    _useBackgroundMonet = prefs.getBool(_bgMonetKey) ?? true;
    _useTextShadow = prefs.getBool(_textShadowKey) ?? false;
    _textShadowBlur =
        prefs.getDouble(_textShadowBlurKey) ?? AppTheme.defaultTextShadowBlur;
    notifyListeners();
  }

  /// 切换「自定义背景图片」开关。
  Future<void> setUseBackgroundImage(bool enabled) async {
    if (_useBackgroundImage == enabled) return;
    _useBackgroundImage = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_bgImageEnabledKey, enabled);
  }

  /// 切换「按背景图莫奈取色」开关（默认开启）。
  /// 关闭后背景图仍正常显示，但不参与主题种子色（回落到系统/手动/默认色）。
  Future<void> setUseBackgroundMonet(bool enabled) async {
    if (_useBackgroundMonet == enabled) return;
    _useBackgroundMonet = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_bgMonetKey, enabled);
  }

  /// 切换「文字阴影」开关（默认开启）。
  ///
  /// 开关值独立持久化，但只在启用自定义背景图片时才实际影响渲染
  /// （见 [useTextShadowEffective]）：关闭背景图时设置项保留用户选择，
  /// 重新开启背景图后沿用。
  Future<void> setUseTextShadow(bool enabled) async {
    if (_useTextShadow == enabled) return;
    _useTextShadow = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_textShadowKey, enabled);
  }

  /// 设置文字阴影磅数（阴影模糊半径，见 [AppTheme.textShadowsFor]）。
  ///
  /// 与开关一样只在启用背景图 + 阴影时影响渲染，值本身独立持久化。
  Future<void> setTextShadowBlur(double blur) async {
    final clamped = blur.clamp(
      AppTheme.minTextShadowBlur,
      AppTheme.maxTextShadowBlur,
    );
    if (_textShadowBlur == clamped) return;
    _textShadowBlur = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_textShadowBlurKey, clamped);
  }

  /// 设置背景图片路径（原生端拷贝到 filesDir 后的真实路径）。
  ///
  /// 路径变化时清空旧取色结果，由 app.dart 桥接异步重新提取并调用
  /// [setBackgroundSeedColor]。传 null 表示清除背景图。
  Future<void> setBackgroundImagePath(String? path) async {
    if (_backgroundImagePath == path) return;
    _backgroundImagePath = path;
    _backgroundSeedColor = null;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (path != null) {
      await prefs.setString(_bgImagePathKey, path);
    } else {
      await prefs.remove(_bgImagePathKey);
    }
  }

  /// 设置背景图片模糊程度（高斯模糊 sigma，0~30）。
  Future<void> setBackgroundBlur(double blur) async {
    final clamped = blur.clamp(0.0, 30.0);
    if (_backgroundBlur == clamped) return;
    _backgroundBlur = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_bgBlurKey, clamped);
  }

  /// 设置背景图片透明度（0.2~1.0，1.0 完全显示图片）。
  Future<void> setBackgroundOpacity(double opacity) async {
    final clamped = opacity.clamp(0.2, 1.0);
    if (_backgroundOpacity == clamped) return;
    _backgroundOpacity = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_bgOpacityKey, clamped);
  }

  /// 更新背景图片提取的主色（由 app.dart 桥接在路径变化后调用）。
  ///
  /// 仅运行时保存、不落盘（颜色随背景图变化）；传 null 表示提取失败，
  /// effectiveSeedColor 自动回落到系统壁纸色/手动色/默认色。
  void setBackgroundSeedColor(Color? color) {
    if (_backgroundSeedColor == color) return;
    _backgroundSeedColor = color;
    notifyListeners();
  }
}
