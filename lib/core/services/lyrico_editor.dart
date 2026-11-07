import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 用 Lyrico 外部编辑本地歌曲的结果。
class LyricoLaunchResult {
  /// Lyrico 是否已安装（未安装时 [launched] 恒为 false）。
  final bool installed;

  /// 是否已成功拉起 Lyrico 编辑页。
  final bool launched;

  const LyricoLaunchResult({required this.installed, required this.launched});
}

/// 拉起 Lyrico 外部编辑客户端：通过 MethodChannel 调用原生实现，
/// 把本地音频文件经 FileProvider 授权交给 Lyrico（EDIT_TAG intent）编辑元数据/歌词。
///
/// 原生端实现见 MainActivity.kt 的 `handleLaunchLyricoEdit`，channel 名为
/// "com.md3music.md3music/external_editor"。
///
/// 调用方应在本地歌曲（[Song.localPath] 非空）的更多菜单点击后调用：
/// 未安装/启动失败返回对应结果，由调用方 Toast 提示，不抛异常。
class LyricoEditor {
  static const MethodChannel _channel = MethodChannel(
    'com.md3music.md3music/external_editor',
  );

  /// 将 [filePath] 指向的本地音频文件交给 Lyrico 编辑。
  ///
  /// 返回 [LyricoLaunchResult]；原生调用失败时视为未成功拉起
  /// （launched=false），不向调用方抛异常。
  static Future<LyricoLaunchResult> launchLyricoEdit(String filePath) async {
    try {
      debugPrint('[LyricoEditor] launchLyricoEdit: $filePath');
      final r = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'launchLyricoEdit',
        {'filePath': filePath},
      );
      final installed = r?['installed'] as bool? ?? false;
      // 原生仅在成功 startActivity 后返回 installed=true
      return LyricoLaunchResult(installed: installed, launched: installed);
    } on PlatformException catch (e) {
      debugPrint(
        '[LyricoEditor] PlatformException: code=${e.code}, '
        'message=${e.message}, details=${e.details}',
      );
      return const LyricoLaunchResult(installed: false, launched: false);
    } catch (e) {
      debugPrint('[LyricoEditor] unexpected error: $e');
      return const LyricoLaunchResult(installed: false, launched: false);
    }
  }
}
