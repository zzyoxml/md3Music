import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 歌词显示偏好设置（字号 + 行间距）。
///
/// 提供全局静态访问 + ChangeNotifier 通知，供 AppleLyricsView、
/// 设置页滑块、长按菜单共同读写。
///
/// 偏好通过 SharedPreferences 持久化。
///
/// 字号范围：[minFontSize] ~ [maxFontSize]，默认 [defaultFontSize]。
/// 行间距系数范围：[minLineSpacing] ~ [maxLineSpacing]，默认 [defaultLineSpacing]。
/// 实际行高 = (fontSize / defaultFontSize) * lineSpacing。
class LyricPreferences extends ChangeNotifier {
  LyricPreferences._();
  static final LyricPreferences instance = LyricPreferences._();

  // ============== 范围与默认值 ==============

  /// 字号最小值（px）
  static const double minFontSize = 12;

  /// 字号最大值（px）
  static const double maxFontSize = 30;

  /// 字号默认值（px）
  static const double defaultFontSize = 15;

  /// 行间距系数最小值
  ///
  /// 下限 0.5 允许把行间距压到比默认行高更紧（0.5×），用于紧凑排版偏好。
  static const double minLineSpacing = 0.5;

  /// 行间距系数最大值
  static const double maxLineSpacing = 2.0;

  /// 行间距系数默认值
  static const double defaultLineSpacing = 1.5;

  // ============== SharedPreferences keys ==============

  static const String _keyFontSize = 'lyric_font_size';
  static const String _keyLineSpacing = 'lyric_line_spacing';

  // ============== 当前值 ==============

  double _fontSize = defaultFontSize;
  double _lineSpacing = defaultLineSpacing;
  bool _loaded = false;

  double get fontSize => _fontSize;
  double get lineSpacing => _lineSpacing;

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
    _fontSize = prefs.getDouble(_keyFontSize) ?? defaultFontSize;
    _lineSpacing = prefs.getDouble(_keyLineSpacing) ?? defaultLineSpacing;
    _loaded = true;
    notifyListeners();
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

  /// 重置为默认值。
  Future<void> reset() async {
    _fontSize = defaultFontSize;
    _lineSpacing = defaultLineSpacing;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyFontSize, _fontSize);
    await prefs.setDouble(_keyLineSpacing, _lineSpacing);
  }
}
