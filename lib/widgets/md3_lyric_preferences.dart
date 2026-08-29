import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// MD3 风格播放页歌词字体来源枚举。
///
/// 与 Apple Music 风格播放页的 [LyricFontSource] 解耦，持久化到独立的
/// SharedPreferences key，允许两种播放页独立设置歌词字体。
enum Md3LyricFontSource { system, bundled, custom }

/// MD3 风格播放页的歌词显示偏好（字号 + 行间距 + 字体）。
///
/// 与 `LyricPreferences`（Apple Music 风格播放页）完全独立的另一份配置：
/// - 独立的 SharedPreferences key 前缀（`md3_lyric_*`）
/// - 独立的 static instance
/// - 独立的字段默认值
///
/// 这样两种播放页的歌词设置互不影响，用户在一种播放页中修改
/// 字号/行间距/字体不会污染另一种播放页。
class Md3LyricPreferences extends ChangeNotifier {
  Md3LyricPreferences._();
  static final Md3LyricPreferences instance = Md3LyricPreferences._();

  /// MD3 歌词自定义字体注册到 Flutter 的 family 名（固定前缀）。
  ///
  /// 与 [CustomFontLoader.customFontFamily] / [LyricPreferences.lyricCustomFontFamily]
  /// 都不同，避免家族名冲突。
  static const String md3LyricCustomFontFamily = 'Md3LyricUserCustomFont';

  // ============== 范围与默认值 ==============

  /// 字号最小值（px）
  static const double minFontSize = 12;

  /// 字号最大值（px）
  static const double maxFontSize = 50;

  /// 字号默认值（px）— 未持久化时新用户使用的字号。
  static const double defaultUserFontSize = 22;

  /// 行间距系数最小值
  static const double minLineSpacing = 0.8;

  /// 行间距系数最大值
  static const double maxLineSpacing = 2.4;

  /// 行间距系数默认值
  static const double defaultLineSpacing = 2.0;

  /// 字重最小值（FontWeight.value，细体）
  static const int minFontWeight = 300;

  /// 字重最大值（FontWeight.value，黑体）
  static const int maxFontWeight = 900;

  /// 字重默认值（FontWeight.value，常规）
  ///
  /// 作为当前行字重；非当前行自动细两档（下限 [minFontWeight]）。
  static const int defaultFontWeight = 600;

  // ============== SharedPreferences keys（独立于 Apple Music 版本） ==============

  static const String _keyFontSize = 'md3_lyric_font_size';
  static const String _keyLineSpacing = 'md3_lyric_line_spacing';
  static const String _keyFontWeight = 'md3_lyric_font_weight';
  static const String _keyFontSource = 'md3_lyric_font_source';
  static const String _keyCustomFontPath = 'md3_lyric_custom_font_path';

  // ============== 当前值 ==============

  double _fontSize = defaultUserFontSize;
  double _lineSpacing = defaultLineSpacing;
  int _fontWeight = defaultFontWeight;
  Md3LyricFontSource _fontSource = Md3LyricFontSource.system;
  String? _customFontPath;
  // 运行时加载成功后填充的 family（仅 custom 模式且加载成功时非 null）
  String? _loadedCustomFontFamily;
  bool _loaded = false;

  double get fontSize => _fontSize;
  double get lineSpacing => _lineSpacing;

  /// 当前行字重（FontWeight.value 数值，范围 [minFontWeight]~[maxFontWeight]）。
  int get fontWeightValue => _fontWeight;

  /// 当前行字重对应 [FontWeight]（供 TextStyle 使用）。
  FontWeight get fontWeight => FontWeight(_fontWeight);

  /// 非当前行字重：当前行字重细两档（下限 [minFontWeight]），保留主次对比。
  FontWeight get otherFontWeight =>
      FontWeight((_fontWeight - 200).clamp(minFontWeight, maxFontWeight));
  Md3LyricFontSource get fontSource => _fontSource;
  String? get customFontPath => _customFontPath;

  /// 当前生效的 fontFamily（传给 TextPainter 的 TextStyle）：
  /// - [Md3LyricFontSource.system]：返回 null（让 Flutter 走系统字体链）
  /// - [Md3LyricFontSource.bundled]：返回 'SimHei'
  /// - [Md3LyricFontSource.custom]：返回 [_loadedCustomFontFamily]，
  ///   加载失败时为 null（实际降级为 system 行为）
  String? get effectiveFontFamily {
    switch (_fontSource) {
      case Md3LyricFontSource.system:
        return null;
      case Md3LyricFontSource.bundled:
        return 'SimHei';
      case Md3LyricFontSource.custom:
        return _loadedCustomFontFamily;
    }
  }

  /// 实际行高系数，供 LyricsView 计算 line height。
  /// 与 Apple Music 的公式一致：fontSize 直接作为行高像素基准，
  /// lineSpacing 作为倍数。
  double get lineHeightMultiplier => _lineSpacing;

  /// 从 SharedPreferences 加载。App 启动时调用一次。
  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _fontSize = prefs.getDouble(_keyFontSize) ?? defaultUserFontSize;
    _lineSpacing = prefs.getDouble(_keyLineSpacing) ?? defaultLineSpacing;
    _fontWeight =
        (prefs.getInt(_keyFontWeight) ?? defaultFontWeight)
            .clamp(minFontWeight, maxFontWeight);
    _fontSource = _fontSourceFromName(prefs.getString(_keyFontSource));
    _customFontPath = prefs.getString(_keyCustomFontPath);
    _loaded = true;
    notifyListeners();
    // 若已配置自定义字体，立即尝试加载
    if (_fontSource == Md3LyricFontSource.custom) {
      await _tryLoadCustomFont();
    }
  }

  /// 设置字号并持久化。
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

  /// 设置字体来源并持久化。
  Future<void> setFontSource(Md3LyricFontSource source) async {
    if (_fontSource == source) return;
    _fontSource = source;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyFontSource, source.name);
  }

  /// 设置自定义字体文件路径并立即尝试加载注册。
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

  /// 重置为默认值（不影响 Apple Music 风格的设置）。
  Future<void> reset() async {
    _fontSize = defaultUserFontSize;
    _lineSpacing = defaultLineSpacing;
    _fontWeight = defaultFontWeight;
    _fontSource = Md3LyricFontSource.system;
    _customFontPath = null;
    _loadedCustomFontFamily = null;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyFontSize, _fontSize);
    await prefs.setDouble(_keyLineSpacing, _lineSpacing);
    await prefs.remove(_keyFontWeight);
    await prefs.remove(_keyFontSource);
    await prefs.remove(_keyCustomFontPath);
  }

  /// 内部：尝试用 FontLoader 加载 [_customFontPath] 指向的字体文件。
  ///
  /// 注意：Flutter 的 FontLoader 不支持对同一 family name 重复调用 load()，
  /// 因此每次加载使用带计数器的唯一 family name。
  int _fontLoadCounter = 0;
  Future<void> _tryLoadCustomFont() async {
    final path = _customFontPath;
    if (path == null || path.isEmpty) {
      _loadedCustomFontFamily = null;
      return;
    }
    final file = File(path);
    if (!file.existsSync()) {
      print('[Md3LyricPreferences] 字体文件不存在: $path');
      _loadedCustomFontFamily = null;
      return;
    }
    try {
      final bytes = await file.readAsBytes();
      _fontLoadCounter++;
      final familyName = '$md3LyricCustomFontFamily#$_fontLoadCounter';
      final loader = FontLoader(familyName);
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
      _loadedCustomFontFamily = familyName;
      notifyListeners();
    } catch (e) {
      print('[Md3LyricPreferences] 字体加载失败: $e');
      _loadedCustomFontFamily = null;
      notifyListeners();
    }
  }

  static Md3LyricFontSource _fontSourceFromName(String? name) {
    switch (name) {
      case 'bundled':
        return Md3LyricFontSource.bundled;
      case 'custom':
        return Md3LyricFontSource.custom;
      default:
        return Md3LyricFontSource.system;
    }
  }
}
