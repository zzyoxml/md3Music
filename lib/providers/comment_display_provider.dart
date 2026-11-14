import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 评论显示设置 Provider。
///
/// 集中管理评论区的字号、楼中楼缩进等视觉相关设置，避免污染
/// [ThemeProvider]（主题/UI 缩放）和其他领域 Provider。
///
/// 字号单位：物理像素（logical pixels），与 TextTheme 的 `fontSize` 一致。
/// 默认楼主 17.0，楼中楼回复自动比楼主小 1 号（16.0）。
class CommentDisplayProvider extends ChangeNotifier {
  /// SharedPreferences key
  static const String _keyCommentFontSize = 'comment_display_font_size';

  /// 楼主评论字号，单位 px，默认 17.0。
  /// 允许范围 [_minCommentFontSize] ~ 24.0（正文属主内容，下限 12）。
  double _commentFontSize = 17.0;

  /// 字号下限：可读性硬下限（正文类取 12）
  static const double _minCommentFontSize = 12.0;

  /// 字号上限
  static const double _maxCommentFontSize = 24.0;

  /// 楼主评论字号
  double get commentFontSize => _commentFontSize;

  /// 楼中楼回复字号 = 楼主字号 - 3.0，回复仍属正文，下限 12。
  double get commentReplyFontSize {
    final reply = _commentFontSize - 3.0;
    return reply < _minCommentFontSize ? _minCommentFontSize : reply;
  }

  late final Future<void> settingsReady;

  CommentDisplayProvider() {
    settingsReady = _loadCommentFontSize();
  }

  Future<void> reloadWindowsSettings() async {
    if (!Platform.isWindows) return;
    await settingsReady;
    final prefs = await SharedPreferences.getInstance();
    _commentFontSize = (prefs.getDouble(_keyCommentFontSize) ?? 17.0)
        .clamp(_minCommentFontSize, _maxCommentFontSize);
    notifyListeners();
  }

  Future<void> _loadCommentFontSize() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getDouble(_keyCommentFontSize);
    if (value != null) {
      _commentFontSize = value.clamp(_minCommentFontSize, _maxCommentFontSize);
      notifyListeners();
    }
  }

  /// 设置楼主评论字号（[_minCommentFontSize] ~ [_maxCommentFontSize] px），
  /// 楼中楼字号自动 = 楼主 - 3。
  /// 持久化到 SharedPreferences。
  Future<void> setCommentFontSize(double size) async {
    final clamped = size.clamp(_minCommentFontSize, _maxCommentFontSize);
    if ((_commentFontSize - clamped).abs() < 0.01) return;
    _commentFontSize = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyCommentFontSize, clamped);
  }

  /// 重置为默认值（楼主 17.0）。
  Future<void> resetToDefault() => setCommentFontSize(17.0);
}
