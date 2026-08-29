import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 歌词字体来源枚举（与全局 [FontSource] 解耦，允许歌词使用与 UI 不同的字体）。
///
/// - [LyricFontSource.system]：使用手机系统字体（默认，符合"优先展示用户手机字体"需求）
/// - [LyricFontSource.bundled]：使用内置打包的 SimHei
/// - [LyricFontSource.custom]：使用用户通过 SAF 选择的 TTF/OTF 文件
enum LyricFontSource { system, bundled, custom }

/// 歌词辅助行显示模式：翻译 or 罗马音。
///
/// - [LyricDisplayMode.translation]：显示中文翻译（默认）
/// - [LyricDisplayMode.roma]：显示罗马音/音译
///
/// 仅当 [LyricPreferences.showTranslation] 为 true 时副行才显示，
/// [displayMode] 决定显示哪个字段。
enum LyricDisplayMode { translation, roma }

/// 歌词显示偏好设置（字号 + 行间距 + 字体）。
///
/// 提供全局静态访问 + ChangeNotifier 通知，供 AppleLyricsView、
/// 设置页滑块、长按菜单共同读写。
///
/// 偏好通过 SharedPreferences 持久化。
///
/// 字号范围：[minFontSize] ~ [maxFontSize]，默认 [defaultFontSize]。
/// 行间距系数范围：[minLineSpacing] ~ [maxLineSpacing]，默认 [defaultLineSpacing]。
/// 实际行高 = (fontSize / defaultFontSize) * lineSpacing。
///
/// 字体来源（[fontSource]）独立于全局 ThemeProvider，允许歌词使用专属字体。
/// 自定义字体通过 Flutter [FontLoader] 动态注册，family 名固定为
/// [lyricCustomFontFamily]；切换为 system/bundled 时该 family 不会被使用。
class LyricPreferences extends ChangeNotifier {
  LyricPreferences._();
  static final LyricPreferences instance = LyricPreferences._();

  /// 歌词自定义字体注册到 Flutter 的 family 名（固定）
  static const String lyricCustomFontFamily = 'LyricUserCustomFont';

  // ============== 范围与默认值 ==============

  /// 字号最小值（px）
  static const double minFontSize = 12;

  /// 字号最大值（px）
  static const double maxFontSize = 50;

  /// 字号默认值（px）
  ///
  /// 这是公式 `(fontSize / defaultFontSize) * lineSpacing` 中的分母，
  /// 保持 15px 不变。改动此值会影响所有用户计算出的实际行高。
  static const double defaultFontSize = 15;

  /// 用户首选项的字号默认值（px）
  ///
  /// 新用户首次进入时歌词显示的字号。保持 22px 让初始实际行高为
  /// (22/15)*1.5 = 2.20×，更符合阅读习惯。
  static const double defaultUserFontSize = 22;

  /// 行间距系数最小值
  ///
  /// 下限 0.5 允许把行间距压到比默认行高更紧（0.5×），用于紧凑排版偏好。
  static const double minLineSpacing = 0.5;

  /// 行间距系数最大值
  static const double maxLineSpacing = 2.0;

  /// 行间距系数默认值
  static const double defaultLineSpacing = 1.5;

  /// 字重最小值（FontWeight.value，细体）
  static const int minFontWeight = 300;

  /// 字重最大值（FontWeight.value，黑体）
  static const int maxFontWeight = 900;

  /// 字重默认值（FontWeight.value，常规）
  ///
  /// 与当前未设置字重时的渲染外观（Flutter 默认 FontWeight.normal=400）一致。
  static const int defaultFontWeight = 400;

  /// 辉光触发阈值系数最小值
  ///
  /// 触发阈值 = 歌词字长中位数 × 该系数；系数越小越容易触发辉光。
  static const double minGlowThresholdFactor = 1.0;

  /// 辉光触发阈值系数最大值
  static const double maxGlowThresholdFactor = 2.0;

  /// 辉光触发阈值系数默认值
  static const double defaultGlowThresholdFactor = 1.4;

  // ============== 按设备类型的默认值（手机 / Pad） ==============

  /// 按设备类型的字号默认：手机 29px，Pad 40px。
  static double get _deviceDefaultFontSize => _isPadDevice() ? 40 : 29;

  /// 按设备类型的字重默认：手机半粗(w600)，Pad 黑体(w900)。
  static int get _deviceDefaultFontWeight => _isPadDevice() ? 900 : 600;

  /// 按设备类型的行间距默认：手机 1.4x，Pad 0.9x。
  static double get _deviceDefaultLineSpacing => _isPadDevice() ? 0.9 : 1.4;

  /// 是否 Pad 设备（物理屏幕最短边 >= 600dp），与 DeviceProvider 判断一致。
  /// 用于首次使用 / 重置时按设备类型提供差异化歌词默认值。
  static bool _isPadDevice() {
    final view = ui.PlatformDispatcher.instance.views.first;
    final size = view.physicalSize / view.devicePixelRatio;
    return size.shortestSide >= 600;
  }

  // ============== SharedPreferences keys ==============

  static const String _keyFontSize = 'lyric_font_size';
  static const String _keyLineSpacing = 'lyric_line_spacing';
  static const String _keyFontWeight = 'lyric_font_weight';
  static const String _keyUseGaussianBlur = 'lyric_use_gaussian_blur';
  static const String _keyUseGlowEffect = 'lyric_use_glow_effect';
  static const String _keyUseFlowingBackground = 'lyric_use_flowing_background';
  static const String _keyFontSource = 'lyric_font_source';
  static const String _keyCustomFontPath = 'lyric_custom_font_path';
  static const String _keyShowTranslation = 'lyric_show_translation';
  static const String _keyDisplayMode = 'lyric_display_mode';
  static const String _keyUseDuetLayout = 'lyric_use_duet_layout';
  static const String _keyEcoMode = 'lyric_eco_mode';
  static const String _keyUseDynamicLyricColor = 'lyric_dynamic_color';
  static const String _keyGlowThresholdFactor = 'lyric_glow_threshold_factor';

  // ============== 当前值 ==============

  double _fontSize = defaultUserFontSize;
  double _lineSpacing = defaultLineSpacing;
  int _fontWeight = defaultFontWeight;
  bool _useGaussianBlur = true;
  bool _useGlowEffect = true;
  bool _useFlowingBackground = false;
  bool _useDuetLayout = true;
  bool _showTranslation = true;
  LyricDisplayMode _displayMode = LyricDisplayMode.translation;
  LyricFontSource _fontSource = LyricFontSource.system;
  String? _customFontPath;
  // 歌词省电模式（默认开启）：开启后歌词界面锁定 60fps，用户上下滑动歌词时临时解锁
  bool _ecoMode = true;
  // 动态字体颜色（默认开启，仅 AM 播放器可用）：当前行歌词颜色按「70% 白 + 30% 封面提取色」混色
  bool _useDynamicLyricColor = true;
  // 辉光触发阈值系数（默认 1.4）：触发阈值 = 歌词字长中位数 × 该系数
  double _glowThresholdFactor = defaultGlowThresholdFactor;
  // 运行时加载成功后填充的 family（仅 custom 模式且加载成功时非 null）
  String? _loadedCustomFontFamily;
  bool _loaded = false;

  double get fontSize => _fontSize;
  double get lineSpacing => _lineSpacing;

  /// 歌词字重（FontWeight.value 数值，范围 [minFontWeight]~[maxFontWeight]）。
  int get fontWeightValue => _fontWeight;

  /// 歌词字重对应 [FontWeight]（供 TextStyle 使用）。
  FontWeight get fontWeight => FontWeight(_fontWeight);
  bool get useGaussianBlur => _useGaussianBlur;
  bool get useGlowEffect => _useGlowEffect;
  bool get useFlowingBackground => _useFlowingBackground;
  bool get useDuetLayout => _useDuetLayout;
  bool get showTranslation => _showTranslation;
  LyricDisplayMode get displayMode => _displayMode;
  LyricFontSource get fontSource => _fontSource;
  String? get customFontPath => _customFontPath;

  /// 歌词省电模式是否开启（默认开启）。
  bool get ecoMode => _ecoMode;

  /// 歌词动态字体颜色是否开启（默认开启，仅 AM 播放器生效）。
  bool get useDynamicLyricColor => _useDynamicLyricColor;

  /// 辉光触发阈值系数（范围 [minGlowThresholdFactor]~[maxGlowThresholdFactor]）。
  ///
  /// 触发阈值 = 歌词字长中位数 × 该系数；系数越小越容易触发辉光。
  double get glowThresholdFactor => _glowThresholdFactor;

  /// 当前生效的 fontFamily（传给 TextPainter 的 TextStyle）：
  /// - [LyricFontSource.system]：返回 null（让 Flutter 走系统字体链）
  /// - [LyricFontSource.bundled]：返回 'SimHei'
  /// - [LyricFontSource.custom]：返回 [_loadedCustomFontFamily]，
  ///   加载失败时为 null（实际降级为 system 行为）
  String? get effectiveFontFamily {
    switch (_fontSource) {
      case LyricFontSource.system:
        return null;
      case LyricFontSource.bundled:
        return 'SimHei';
      case LyricFontSource.custom:
        return _loadedCustomFontFamily;
    }
  }

  /// 计算实际行高系数。
  ///
  /// 公式：`actualLineHeight = (fontSize / defaultFontSize) * lineSpacing`
  /// 例如：
  /// - fontSize=15, lineSpacing=1.5 → (15/15)*1.5 = 1.5
  /// - fontSize=15, lineSpacing=1.0 → (15/15)*1.0 = 1.0
  /// - fontSize=20, lineSpacing=1.0 → (20/15)*1.0 ≈ 1.33
  double get lineHeightMultiplier =>
      (_fontSize / defaultFontSize) * _lineSpacing;

  /// 从 SharedPreferences 加载。App 启动时调用一次。
  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    // 首次使用（key 不存在）时按设备类型提供差异化默认：
    // 手机 29px/半粗(600)/1.4x；Pad 40px/黑体(900)/0.9x。
    // 用户后续手动调整后会持久化，届时尊重用户设置。
    _fontSize = prefs.getDouble(_keyFontSize) ?? _deviceDefaultFontSize;
    _lineSpacing = prefs.getDouble(_keyLineSpacing) ?? _deviceDefaultLineSpacing;
    _fontWeight =
        (prefs.getInt(_keyFontWeight) ?? _deviceDefaultFontWeight)
            .clamp(minFontWeight, maxFontWeight);
    _useGaussianBlur = prefs.getBool(_keyUseGaussianBlur) ?? true;
    _useGlowEffect = prefs.getBool(_keyUseGlowEffect) ?? true;
    _useFlowingBackground = prefs.getBool(_keyUseFlowingBackground) ?? false;
    _useDuetLayout = prefs.getBool(_keyUseDuetLayout) ?? true;
    _showTranslation = prefs.getBool(_keyShowTranslation) ?? true;
    _displayMode = _displayModeFromName(prefs.getString(_keyDisplayMode));
    _fontSource = _fontSourceFromName(prefs.getString(_keyFontSource));
    _customFontPath = prefs.getString(_keyCustomFontPath);
    _ecoMode = prefs.getBool(_keyEcoMode) ?? true;
    _useDynamicLyricColor = prefs.getBool(_keyUseDynamicLyricColor) ?? true;
    _glowThresholdFactor =
        (prefs.getDouble(_keyGlowThresholdFactor) ?? defaultGlowThresholdFactor)
            .clamp(minGlowThresholdFactor, maxGlowThresholdFactor);
    _loaded = true;
    notifyListeners();
    // 若已配置自定义字体，立即尝试加载（Fire-and-forget，加载完成后会 notifyListeners）
    if (_fontSource == LyricFontSource.custom) {
      await _tryLoadCustomFont();
    }
  }

  /// 设置字号并持久化。会触发 [notifyListeners]。
  Future<void> setFontSize(double size) async {
    final clamped = size.clamp(minFontSize, maxFontSize);
    if (clamped == _fontSize) return;
    _fontSize = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyFontSize, _fontSize);
  }

  /// 设置行间距系数并持久化。
  Future<void> setLineSpacing(double spacing) async {
    final clamped = spacing.clamp(minLineSpacing, maxLineSpacing);
    if (clamped == _lineSpacing) return;
    _lineSpacing = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyLineSpacing, _lineSpacing);
  }

  /// 设置字重并持久化。会触发 [notifyListeners]。
  Future<void> setFontWeight(int value) async {
    final clamped = value.clamp(minFontWeight, maxFontWeight);
    if (clamped == _fontWeight) return;
    _fontWeight = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyFontWeight, _fontWeight);
  }

  /// 设置高斯模糊开关并持久化。
  Future<void> setUseGaussianBlur(bool enabled) async {
    if (_useGaussianBlur == enabled) return;
    _useGaussianBlur = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyUseGaussianBlur, enabled);
  }

  /// 设置辉光效果开关并持久化。
  Future<void> setUseGlowEffect(bool enabled) async {
    if (_useGlowEffect == enabled) return;
    _useGlowEffect = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyUseGlowEffect, enabled);
  }

  /// 设置动态流光背景开关并持久化。
  Future<void> setUseFlowingBackground(bool enabled) async {
    if (_useFlowingBackground == enabled) return;
    _useFlowingBackground = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyUseFlowingBackground, enabled);
  }

  /// 设置男女对唱歌词优化开关并持久化。
  Future<void> setUseDuetLayout(bool enabled) async {
    if (_useDuetLayout == enabled) return;
    _useDuetLayout = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyUseDuetLayout, enabled);
  }

  /// 设置歌词省电模式开关并持久化。
  /// 开启后歌词界面锁定 60fps，用户上下滑动歌词时临时解锁帧率限制。
  Future<void> setEcoMode(bool enabled) async {
    if (_ecoMode == enabled) return;
    _ecoMode = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyEcoMode, enabled);
  }

  /// 设置歌词动态字体颜色开关并持久化。
  /// 开启后当前行歌词颜色按「70% 白 + 30% 封面提取色」混色（仅 AM 播放器生效）。
  Future<void> setUseDynamicLyricColor(bool enabled) async {
    if (_useDynamicLyricColor == enabled) return;
    _useDynamicLyricColor = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyUseDynamicLyricColor, enabled);
  }

  /// 设置辉光触发阈值系数并持久化。
  ///
  /// 触发阈值 = 歌词字长中位数 × 该系数，范围 [minGlowThresholdFactor]~
  /// [maxGlowThresholdFactor]（默认 [defaultGlowThresholdFactor]=1.4）。
  /// 系数越小越容易触发辉光。
  Future<void> setGlowThresholdFactor(double value) async {
    final clamped =
        value.clamp(minGlowThresholdFactor, maxGlowThresholdFactor);
    if (clamped == _glowThresholdFactor) return;
    _glowThresholdFactor = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyGlowThresholdFactor, _glowThresholdFactor);
  }

  /// 设置歌词翻译副行显示开关并持久化。
  Future<void> setShowTranslation(bool enabled) async {
    if (_showTranslation == enabled) return;
    _showTranslation = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyShowTranslation, enabled);
  }

  /// 设置辅助行显示模式（翻译/罗马音）并持久化。
  Future<void> setDisplayMode(LyricDisplayMode mode) async {
    if (_displayMode == mode) return;
    _displayMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDisplayMode, mode.name);
  }

  // ============== 歌词字体来源 ==============

  /// 设置字体来源并持久化。
  Future<void> setFontSource(LyricFontSource source) async {
    if (_fontSource == source) return;
    _fontSource = source;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyFontSource, source.name);
  }

  /// 设置自定义字体文件路径并立即尝试加载注册。
  /// 传 null 清除路径并卸载已加载的字体（实际效果降级到 system）。
  Future<void> setCustomFontPath(String? path) async {
    if (_customFontPath == path) return;
    _customFontPath = path;
    final prefs = await SharedPreferences.getInstance();
    if (path != null) {
      await prefs.setString(_keyCustomFontPath, path);
      await _tryLoadCustomFont();
    } else {
      await prefs.remove(_keyCustomFontPath);
      _loadedCustomFontFamily = null;
      notifyListeners();
    }
  }

  /// 内部：尝试用 FontLoader 加载 [_customFontPath] 指向的字体文件。
  /// 加载成功则填充 [_loadedCustomFontFamily] 并 notifyListeners。
  ///
  /// 注意：Flutter 的 FontLoader 不支持对同一 family name 重复调用 load()，
  /// 否则会抛异常。因此每次加载使用带计数器的唯一 family name。
  int _fontLoadCounter = 0;
  Future<void> _tryLoadCustomFont() async {
    final path = _customFontPath;
    if (path == null || path.isEmpty) {
      _loadedCustomFontFamily = null;
      return;
    }
    final file = File(path);
    if (!file.existsSync()) {
      print('[LyricPreferences] 字体文件不存在: $path');
      _loadedCustomFontFamily = null;
      return;
    }
    try {
      final bytes = await file.readAsBytes();
      // 每次使用唯一的 family name，避免 FontLoader 重复注册同一 family 抛异常
      _fontLoadCounter++;
      final familyName = '$lyricCustomFontFamily#$_fontLoadCounter';
      final loader = FontLoader(familyName);
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
      _loadedCustomFontFamily = familyName;
      notifyListeners();
    } catch (e) {
      print('[LyricPreferences] 字体加载失败: $e');
      _loadedCustomFontFamily = null;
      notifyListeners();
    }
  }

  static LyricFontSource _fontSourceFromName(String? name) {
    switch (name) {
      case 'bundled':
        return LyricFontSource.bundled;
      case 'custom':
        return LyricFontSource.custom;
      default:
        return LyricFontSource.system;
    }
  }

  static LyricDisplayMode _displayModeFromName(String? name) {
    return name == 'roma' ? LyricDisplayMode.roma : LyricDisplayMode.translation;
  }

  /// 重置为默认值（按设备类型：手机 / Pad 差异化默认）。
  Future<void> reset() async {
    _fontSize = _deviceDefaultFontSize;
    _lineSpacing = _deviceDefaultLineSpacing;
    _fontWeight = _deviceDefaultFontWeight;
    _useGaussianBlur = true;
    _useGlowEffect = true;
    _useFlowingBackground = false;
    _useDuetLayout = true;
    _showTranslation = true;
    _displayMode = LyricDisplayMode.translation;
    _fontSource = LyricFontSource.system;
    _customFontPath = null;
    _loadedCustomFontFamily = null;
    _ecoMode = true;
    _useDynamicLyricColor = true;
    _glowThresholdFactor = defaultGlowThresholdFactor;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyFontSize, _fontSize);
    await prefs.setDouble(_keyLineSpacing, _lineSpacing);
    await prefs.setInt(_keyFontWeight, _fontWeight);
    await prefs.setBool(_keyUseGaussianBlur, _useGaussianBlur);
    await prefs.setBool(_keyUseGlowEffect, _useGlowEffect);
    await prefs.setBool(_keyUseFlowingBackground, _useFlowingBackground);
    await prefs.setBool(_keyUseDuetLayout, _useDuetLayout);
    await prefs.setBool(_keyShowTranslation, _showTranslation);
    await prefs.setString(_keyDisplayMode, _displayMode.name);
    await prefs.remove(_keyEcoMode);
    await prefs.remove(_keyUseDynamicLyricColor);
    await prefs.remove(_keyGlowThresholdFactor);
    await prefs.remove(_keyFontSource);
    await prefs.remove(_keyCustomFontPath);
  }
}
