import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/providers/player_provider.dart';

/// Windows 本地音乐播放 URL 构造回归。
///
/// **背景**：`PlayerProvider._resolvePlaybackUrlImpl` 旧实现只用
/// `raw.startsWith('/')` 判断"是不是绝对路径"，而 Windows 绝对路径形如
/// `C:\Music\a.mp3`，**不以 `/` 开头** → 裸盘符路径被原样丢给
/// `just_audio.setUrl`，WinRT MediaPlayer 解析不了 → 本地音乐全部打不开。
void main() {
  group('Windows 绝对路径识别', () {
    test('识别盘符 + 反斜杠', () {
      expect(
        looksLikeWindowsAbsolutePath(r'C:\Music\a.mp3'),
        isTrue,
      );
    });

    test('识别盘符 + 正斜杠', () {
      expect(
        looksLikeWindowsAbsolutePath('D:/Music/a.flac'),
        isTrue,
      );
    });

    test('识别小写盘符', () {
      expect(
        looksLikeWindowsAbsolutePath(r'e:\music\a.mp3'),
        isTrue,
      );
    });

    test('识别 UNC 路径', () {
      expect(
        looksLikeWindowsAbsolutePath(r'\\server\share\a.mp3'),
        isTrue,
      );
    });

    test('Android 绝对路径不算 Windows 路径', () {
      // 关键：不能把 Android 路径误判后走错分支（虽然结果都是Uri.file，
      // 但保持判定语义单一，避免后续维护踩坑）。
      expect(
        looksLikeWindowsAbsolutePath(
          '/storage/emulated/0/Music/a.mp3',
        ),
        isFalse,
      );
    });

    test('相对路径不算 Windows 绝对路径', () {
      expect(
        looksLikeWindowsAbsolutePath('Music/a.mp3'),
        isFalse,
      );
    });

    test('http(s) URL 不算 Windows 绝对路径', () {
      expect(
        looksLikeWindowsAbsolutePath('https://x.com/a.mp3'),
        isFalse,
      );
    });

    test('盘符后必须跟分隔符，C:开头不算', () {
      expect(looksLikeWindowsAbsolutePath('C:a.mp3'), isFalse);
    });
  });

  group('Uri.file 转换结果', () {
    test('Windows 路径转成可播放的 file URI', () {
      final uri = Uri.file(r'C:\Music\a.mp3').toString();
      expect(uri, 'file:///C:/Music/a.mp3');
      // just_audio_windows 需要带 scheme 的完整 URI。
      expect(uri.startsWith('file:///'), isTrue);
    });
  });
}