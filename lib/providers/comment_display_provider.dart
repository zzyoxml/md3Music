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
  /// 允许范围 10.0 ~ 24.0。
  double _commentFontSize = 17.0;

  /// 楼主评论字号
  double get commentFontSize => _commentFontSize;

  /// 楼中楼回复字号 = 楼主字号 - 3.0，最小 10.0（避免过小无法阅读）。
  double get commentReplyFontSize {
    final reply = _commentFontSize - 3.0;
    return reply < 10.0 ? 10.0 : reply;
  }

  CommentDisplayProvider() {
    _loadCommentFontSize();
  }

  Future<void> _loadCommentFontSize() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getDouble(_keyCommentFontSize);
    if (value != null) {
      _commentFontSize = value.clamp(10.0, 24.0);
      notifyListeners();
    }
  }

  /// 设置楼主评论字号（10.0 ~ 24.0 px），楼中楼字号自动 = 楼主 - 3。
  /// 持久化到 SharedPreferences。
  Future<void> setCommentFontSize(double size) async {
    final clamped = size.clamp(10.0, 24.0);
    if ((_commentFontSize - clamped).abs() < 0.01) return;
    _commentFontSize = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyCommentFontSize, clamped);
  }

  /// 重置为默认值（楼主 17.0）。
  Future<void> resetToDefault() => setCommentFontSize(17.0);
}
