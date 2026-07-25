import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme/app_theme.dart';

class ThemeProvider extends ChangeNotifier {
  static const String _key = 'theme_mode';
  static const String _dynamicKey = 'use_dynamic_color';
  static const String _amStylePlayerKey = 'use_am_style_player';
  static const String _manualSeedKey = 'manual_seed_color';
  static const String _oledBlackKey = 'use_oled_black';
  static const String _uiScaleKey = 'ui_scale';

  ThemeMode _themeMode = ThemeMode.system;
  bool _useDynamicColor = false;
  Color? _systemSeedColor;
  bool _useAmStylePlayer = false;
  Color? _manualSeedColor;
  bool _useOledBlack = false;
  double _uiScale = 1.0;

  ThemeMode get themeMode => _themeMode;
  bool get useDynamicColor => _useDynamicColor;
  Color? get systemSeedColor => _systemSeedColor;
  bool get useAmStylePlayer => _useAmStylePlayer;
  Color? get manualSeedColor => _manualSeedColor;
  bool get useOledBlack => _useOledBlack;
  double get uiScale => _uiScale;

  /// 当前生效的种子色优先级：
  /// 1. 启用系统主题色且成功取到 → 系统主色
  /// 2. 用户手动选择非 null → 手动色
  /// 3. 默认紫色种子（[AppTheme.defaultSeedColor]）
  Color get effectiveSeedColor =>
      _useDynamicColor && _systemSeedColor != null
          ? _systemSeedColor!
          : (_manualSeedColor ?? AppTheme.defaultSeedColor);

  ThemeProvider() {
    _loadThemeMode();
    _loadDynamicColor();
    _loadAmStylePlayer();
    _loadManualSeedColor();
    _loadOledBlack();
    _loadUiScale();
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
        fallbackColorARGB: AppTheme.defaultSeedColor.value,
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
      await prefs.setInt(_manualSeedKey, color.value);
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

  /// 加载 UI 缩放倍率持久化值，默认 1.0。
  Future<void> _loadUiScale() async {
    final prefs = await SharedPreferences.getInstance();
    _uiScale = prefs.getDouble(_uiScaleKey) ?? 1.0;
    notifyListeners();
  }

  /// 设置 UI 缩放倍率（0.5 ~ 2.0）。
  Future<void> setUiScale(double scale) async {
    final clamped = scale.clamp(0.5, 2.0);
    if (_uiScale == clamped) return;
    _uiScale = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_uiScaleKey, clamped);
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
}
