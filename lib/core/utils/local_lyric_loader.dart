import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';

/// 本地歌词加载器：内嵌歌词优先，其次读取同目录同名歌词文件。
///
/// 本地音乐歌词来源（参考 Lyrico 歌词文件约定）：
/// 1. 音频内嵌歌词（ID3 USLT / Vorbis LYRICS / MP4 ©lyr）—— 最高优先；
/// 2. 音频同目录同名歌词文件（.lrc / .ttml / .txt，按此顺序查找）。
class LocalLyricLoader {
  LocalLyricLoader._();

  /// 支持的本地歌词文件扩展名（按优先级排列）。
  static const List<String> lyricExtensions = ['.lrc', '.ttml', '.txt'];

  /// 加载本地歌曲歌词：先内嵌，无内嵌时查找同目录同名歌词文件。
  ///
  /// 兼容 file:// URI 与裸绝对路径。返回歌词文本，无则 null。
  static String? loadForAudio(String filePath) {
    final path = filePath.startsWith('file://')
        ? Uri.parse(filePath).toFilePath()
        : filePath;
    if (path.isEmpty) return null;

    final embedded = _readEmbeddedLyrics(path);
    if (embedded != null && embedded.isNotEmpty) return embedded;

    return _findSidecarLyric(path);
  }

  /// 读取音频内嵌歌词（ID3 USLT / Vorbis LYRICS / MP4 ©lyr）。
  ///
  /// FLAC 特殊处理：audio_metadata_reader 1.4.1 的 FlacParser 用
  /// `comment.split("=")[1]` 解析 Vorbis comment，含 `=` 的歌词值
  /// （如 TTML XML 声明的 `version="1.0"`）会被截断到第一个 `=`，
  /// 因此 FLAC 内嵌歌词改为手动解析 LYRICS 标签（取第一个 `=` 后完整值）。
  static String? _readEmbeddedLyrics(String filePath) {
    if (filePath.toLowerCase().endsWith('.flac')) {
      final flacLyrics = _readFlacLyrics(filePath);
      if (flacLyrics != null && flacLyrics.isNotEmpty) return flacLyrics;
    }
    try {
      final file = File(filePath);
      if (!file.existsSync()) return null;
      final metadata = readMetadata(file, getImage: false);
      return metadata.lyrics;
    } catch (_) {
      return null;
    }
  }

  /// 手动解析 FLAC 的 Vorbis comment，读取 LYRICS 标签完整值。
  ///
  /// FLAC metadata block：1 字节头（last 标志 + block type）+ 3 字节大端长度；
  /// block type 4 = VORBIS_COMMENT，内部为小端长度 + UTF-8 字符串的序列。
  static String? _readFlacLyrics(String filePath) {
    try {
      final bytes = File(filePath).readAsBytesSync();
      final data = ByteData.sublistView(bytes);
      if (bytes.length < 4 ||
          String.fromCharCodes(bytes.sublist(0, 4)) != 'fLaC') {
        return null;
      }

      var offset = 4;
      while (offset + 4 <= bytes.length) {
        final header = data.getUint8(offset);
        final isLast = (header & 0x80) != 0;
        final type = header & 0x7F;
        final blockLen = (data.getUint8(offset + 1) << 16) |
            (data.getUint8(offset + 2) << 8) |
            data.getUint8(offset + 3);
        offset += 4;

        if (type == 4) {
          // VORBIS_COMMENT：vendor length + vendor + comment count + comments
          if (offset + 4 > bytes.length) return null;
          final vendorLen = data.getUint32(offset, Endian.little);
          var p = offset + 4 + vendorLen;
          if (p + 4 > bytes.length) return null;
          final count = data.getUint32(p, Endian.little);
          p += 4;
          for (var i = 0; i < count; i++) {
            if (p + 4 > bytes.length) return null;
            final clen = data.getUint32(p, Endian.little);
            p += 4;
            if (p + clen > bytes.length) return null;
            final comment = utf8.decode(bytes.sublist(p, p + clen));
            p += clen;
            // 取第一个 `=` 之后的所有内容作为值（与 OGG 解析器一致）
            final eq = comment.indexOf('=');
            if (eq > 0 && comment.substring(0, eq).toUpperCase() == 'LYRICS') {
              return comment.substring(eq + 1);
            }
          }
          return null;
        }

        offset += blockLen;
        if (isLast) break;
      }
    } catch (_) {}
    return null;
  }

  /// 查找音频同目录下的同名歌词文件（.lrc / .ttml / .txt 优先级）。
  static String? _findSidecarLyric(String audioPath) {
    try {
      final audio = File(audioPath);
      if (!audio.existsSync()) return null;
      final dir = audio.parent;
      final baseName = audioPath.split(Platform.pathSeparator).last;
      final dot = baseName.lastIndexOf('.');
      final stem = dot > 0 ? baseName.substring(0, dot) : baseName;

      for (final ext in lyricExtensions) {
        final candidate =
            File('${dir.path}${Platform.pathSeparator}$stem$ext');
        if (candidate.existsSync()) {
          return candidate.readAsStringSync();
        }
      }
    } catch (_) {}
    return null;
  }
}
