import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/utils/local_media_path.dart';

/// [normalizeLocalMediaPath] 的单测。
///
/// 这条线的回归价值：本地歌曲的 `localPath` 在播放解析后被回写成 `file://`
/// URI（中文/空格还会 percent 编码），而封面读取链路（`LocalArtworkCache`
/// → `readArtworkInIsolate` → `File()`）原先把它当裸磁盘路径用，于是
/// `existsSync()` 恒为 false → 播放页封面恒为占位符（列表用曲库对象、路径
/// 未经回写，所以正常）。下面钉住的就是「同一文件的各种写法归一后同一条路径」。
void main() {
  group('裸路径', () {
    test('原样返回', () {
      expect(
        normalizeLocalMediaPath('/storage/emulated/0/Music/a.mp3'),
        '/storage/emulated/0/Music/a.mp3',
      );
    });

    test('不 percent 解码（文件名可含字面 %）', () {
      // 裸路径里 `%` 是合法文件名字符，解码会误伤（同 local_http_server 取舍）
      expect(
        normalizeLocalMediaPath('/music/100% pure.mp3'),
        '/music/100% pure.mp3',
      );
    });

    test('首尾空白被裁掉', () {
      expect(normalizeLocalMediaPath('  /music/a.mp3  '), '/music/a.mp3');
    });
  });

  group('local://（库内内嵌封面标识）', () {
    test('去前缀后得到裸路径', () {
      expect(normalizeLocalMediaPath('local:///music/a.mp3'), '/music/a.mp3');
    });

    test('嵌套 file:// 也会继续归一', () {
      expect(
        _posixPath(normalizeLocalMediaPath('local://file:///music/a%20b.mp3')),
        '/music/a b.mp3',
      );
    });
  });

  group('file://（播放解析后的回写形态）', () {
    test('无编码：还原为绝对路径', () {
      final path = normalizeLocalMediaPath('file:///storage/a.mp3');
      expect(_posixPath(path), '/storage/a.mp3');
    });

    test('percent 编码还原（含中文）', () {
      // Uri.file('/music/晴天.mp3').toString() == file:///music/%E6%99%B4%E5%A4%A9.mp3
      final path = normalizeLocalMediaPath(
        'file:///music/%E6%99%B4%E5%A4%A9.mp3',
      );
      expect(_posixPath(path), '/music/晴天.mp3');
    });

    test('空格编码还原', () {
      final path = normalizeLocalMediaPath('file:///music/a%20b.mp3');
      expect(_posixPath(path), '/music/a b.mp3');
    });

    test('与 Uri.file 往返一致（真机回写的真实形态）', () {
      // 关键性质：Uri.file(裸路径) → normalize → 得到同一文件的可用路径。
      // 中文 + 空格同时覆盖 percent 编码与 UTF-8 两条解码路径。
      final raw =
          Platform.isWindows ? r'C:\Music\晴天 a.mp3' : '/music/晴天 a.mp3';
      final fileUri = Uri.file(raw).toString();
      final normalized = normalizeLocalMediaPath(fileUri);
      expect(normalized, isNotNull);
      expect(
        normalized!.contains('%'),
        isFalse,
        reason: '归一后不应残留 percent 编码（残留即 File() 打不开）',
      );
      // 归一结果与原始裸路径指向同一个文件
      expect(File(normalized).path, File(raw).path);
    });
  });

  group('非本地形态原样返回（由调用方决定语义）', () {
    test('content://', () {
      expect(
        normalizeLocalMediaPath('content://media/external/audio/albumart/1'),
        'content://media/external/audio/albumart/1',
      );
    });

    test('http(s)://', () {
      expect(
        normalizeLocalMediaPath('https://img.example.com/a.jpg'),
        'https://img.example.com/a.jpg',
      );
    });
  });

  group('不可用时返回 null', () {
    test('null / 空串 / 纯空白', () {
      expect(normalizeLocalMediaPath(null), isNull);
      expect(normalizeLocalMediaPath(''), isNull);
      expect(normalizeLocalMediaPath('   '), isNull);
    });

    test('file:// 无路径部分', () {
      expect(normalizeLocalMediaPath('file://'), isNull);
      expect(normalizeLocalMediaPath('local://'), isNull);
    });
  });
}

/// 平台无关的路径形态比较：Windows 上 `toFilePath` 会输出 `\` 分隔，
/// 断言统一按 `/` 比较，避免测试只在某一平台通过。
String? _posixPath(String? path) => path?.replaceAll(r'\', '/');
