import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart' show compute;

/// 本地歌词加载器：内嵌歌词优先，其次读取同目录同名歌词文件。
///
/// 本地音乐歌词来源（参考 Lyrico 歌词文件约定）：
/// 1. 音频内嵌歌词（ID3 USLT / SYLT、Vorbis LYRICS、MP4 ©lyr）—— 最高优先；
/// 2. 音频同目录同名歌词文件（.lrc / .ttml / .txt，按此顺序查找）。
class LocalLyricLoader {
  LocalLyricLoader._();

  /// 支持的本地歌词文件扩展名（按优先级排列）。
  static const List<String> lyricExtensions = ['.lrc', '.ttml', '.txt'];

  /// 仅从音频头部读取元数据的最大字节数。
  ///
  /// FLAC 的 VORBIS_COMMENT、MP3 的 ID3v2、MP4 的 ©lyr 均位于文件起始区域，
  /// 逐块随机读取即可拿到内嵌 LRC。限制头部读取量可避免把整首高码率大文件
  /// 一次性读入内存（播放大体积内嵌歌词歌曲时可能被系统判定 OOM/无响应而崩溃）。
  /// 若头部区域内未发现歌词标签，则按"无内嵌歌词"处理，回退到同名歌词文件。
  static const int _maxEmbeddedReadBytes = 16 * 1024 * 1024;

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

  /// 异步版本：把内嵌歌词的元数据读取与侧车歌词文件读取整体移入后台 isolate
  /// 执行，并带超时兜底。任何耗时/异常/超时都不会阻塞主隔离区（避免在切歌/播放
  /// 瞬间拖垮 UI 甚至被判定为无响应而崩溃）；返回 null 时由调用方回退到酷狗接口。
  static Future<String?> loadForAudioAsync(String filePath) async {
    final path = filePath.startsWith('file://')
        ? Uri.parse(filePath).toFilePath()
        : filePath;
    if (path.isEmpty) return null;
    try {
      return await compute(_loadForAudioInIsolate, path)
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      return null;
    }
  }

  /// 读取音频内嵌歌词（ID3 USLT / SYLT / Vorbis LYRICS / MP4 ©lyr）。
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
    String? metadataLyrics;
    try {
      final file = File(filePath);
      if (!file.existsSync()) return null;
      // 超大文件不做整读（避免主隔离区一次性读入大文件导致 OOM/ANR），
      // 直接视为无内嵌歌词，回退到同目录同名歌词文件。
      if (file.lengthSync() > _maxEmbeddedReadBytes) return null;
      final metadata = readMetadata(file, getImage: false);
      metadataLyrics = metadata.lyrics;
    } catch (_) {}

    // 保持现有 USLT / Vorbis / MP4 读取优先级；只有通用元数据读取不到歌词时，
    // 才补读 MP3 ID3v2 的 SYLT（同步歌词）帧。这样不会改变 AM 现有歌词路径，
    // 只会让此前读不到的本地内嵌同步歌词多一个普通时间轴文本的兜底来源。
    final existingLyrics = metadataLyrics;
    if (existingLyrics != null && existingLyrics.isNotEmpty) {
      return existingLyrics;
    }
    if (filePath.toLowerCase().endsWith('.mp3')) {
      return _readMp3SyncedLyrics(filePath);
    }
    return null;
  }

  /// 读取 MP3 ID3v2 SYLT（Synchronized lyric/text）帧。
  ///
  /// SYLT 的每条文本都带一个毫秒时间戳，但不同写入器可能按整行或按词写入。
  /// 这里把每条记录转换成普通 LRC 行，目标是保证 MD3/AM 至少能正常显示歌词文本；
  /// 不在本地读取层改变现有 AppleLyricsView 的逐字渲染逻辑。
  static String? _readMp3SyncedLyrics(String filePath) {
    RandomAccessFile? rf;
    try {
      final file = File(filePath);
      if (!file.existsSync()) return null;
      rf = file.openSync();
      final fileLength = rf.lengthSync();
      if (fileLength < 10) return null;

      final header = rf.readSync(10);
      if (header.length < 10 ||
          header[0] != 0x49 ||
          header[1] != 0x44 ||
          header[2] != 0x33) {
        return null;
      }

      final version = header[3];
      if (version != 3 && version != 4) return null;
      final tagSize = _readSynchsafeInt(header, 6);
      if (tagSize <= 0 || tagSize > _maxEmbeddedReadBytes) return null;

      final available = fileLength - 10;
      final readLength = tagSize < available ? tagSize : available;
      if (readLength <= 0) return null;
      final List<int> tagBytes = rf.readSync(readLength);
      var tag = tagBytes;

      // ID3 unsynchronisation is applied to the tag payload, so remove it before
      // reading frame sizes and frame contents.
      if ((header[5] & 0x80) != 0) {
        tag = _removeId3Unsynchronization(tag);
      }

      var offset = 0;
      if ((header[5] & 0x40) != 0) {
        final skipped = _skipId3ExtendedHeader(tag, version);
        if (skipped < 0 || skipped > tag.length) return null;
        offset = skipped;
      }

      while (offset + 10 <= tag.length) {
        final frameId = String.fromCharCodes(tag.sublist(offset, offset + 4));
        if (frameId.codeUnits.every((c) => c == 0)) break;

        final frameSize = version == 4
            ? _readSynchsafeInt(tag, offset + 4)
            : _readUint32Be(tag, offset + 4);
        final frameStart = offset + 10;
        final frameEnd = frameStart + frameSize;
        if (frameSize <= 0 || frameEnd > tag.length) break;

        if (frameId == 'SYLT') {
          final entries = _parseSylt(tag.sublist(frameStart, frameEnd));
          final lyrics = _formatSyltAsLrc(entries);
          if (lyrics != null && lyrics.isNotEmpty) return lyrics;
        }
        offset = frameEnd;
      }
    } catch (_) {
      return null;
    } finally {
      rf?.closeSync();
    }
    return null;
  }

  static int _readSynchsafeInt(List<int> bytes, int offset) {
    if (offset < 0 || offset + 4 > bytes.length) return 0;
    return ((bytes[offset] & 0x7F) << 21) |
        ((bytes[offset + 1] & 0x7F) << 14) |
        ((bytes[offset + 2] & 0x7F) << 7) |
        (bytes[offset + 3] & 0x7F);
  }

  static int _readUint32Be(List<int> bytes, int offset) {
    if (offset < 0 || offset + 4 > bytes.length) return 0;
    return (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
  }

  static int _skipId3ExtendedHeader(List<int> bytes, int version) {
    if (bytes.length < 4) return -1;
    final size = version == 4
        ? _readSynchsafeInt(bytes, 0)
        : _readUint32Be(bytes, 0);
    final total = version == 3 ? size + 4 : size;
    return total > 0 && total <= bytes.length ? total : -1;
  }

  static List<int> _removeId3Unsynchronization(List<int> bytes) {
    final result = <int>[];
    for (var i = 0; i < bytes.length; i++) {
      result.add(bytes[i]);
      if (bytes[i] == 0xFF && i + 1 < bytes.length && bytes[i + 1] == 0x00) {
        i++;
      }
    }
    return result;
  }

  static List<_SyltEntry> _parseSylt(List<int> payload) {
    if (payload.length < 7) return const [];
    final encoding = payload[0];
    if (encoding > 3) return const [];
    // SYLT timestamp format 2 is milliseconds. MPEG-frame timestamps cannot be
    // converted without the audio stream's frame rate, so leave them untouched.
    if (payload[4] != 2) return const [];

    var offset = 1 + 3 + 1 + 1;
    final descriptionEnd = _findSyltTerminator(payload, offset, encoding);
    if (descriptionEnd < 0) return const [];
    offset = descriptionEnd + _syltTerminatorLength(encoding);

    final entries = <_SyltEntry>[];
    while (offset < payload.length) {
      final textEnd = _findSyltTerminator(payload, offset, encoding);
      if (textEnd < 0 ||
          textEnd + _syltTerminatorLength(encoding) + 4 > payload.length) {
        break;
      }
      final text = _decodeSyltText(payload, offset, textEnd, encoding).trim();
      offset = textEnd + _syltTerminatorLength(encoding);
      final timestamp = _readUint32Be(payload, offset);
      offset += 4;
      if (text.isNotEmpty) entries.add(_SyltEntry(text, timestamp));
    }
    return entries;
  }

  static int _syltTerminatorLength(int encoding) =>
      encoding == 1 || encoding == 2 ? 2 : 1;

  static int _findSyltTerminator(List<int> bytes, int start, int encoding) {
    final length = _syltTerminatorLength(encoding);
    if (length == 1) {
      for (var i = start; i < bytes.length; i++) {
        if (bytes[i] == 0) return i;
      }
      return -1;
    }
    for (var i = start; i + 1 < bytes.length; i += 2) {
      if (bytes[i] == 0 && bytes[i + 1] == 0) return i;
    }
    return -1;
  }

  static String _decodeSyltText(
    List<int> bytes,
    int start,
    int end,
    int encoding,
  ) {
    final value = bytes.sublist(start, end);
    switch (encoding) {
      case 0:
        return latin1.decode(value);
      case 3:
        return utf8.decode(value, allowMalformed: true);
      case 1:
      case 2:
        return _decodeUtf16(value, littleEndian: encoding == 1);
      default:
        return '';
    }
  }

  static String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
    var start = 0;
    var little = littleEndian;
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      little = true;
      start = 2;
    } else if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      little = false;
      start = 2;
    }
    final codeUnits = <int>[];
    for (var i = start; i + 1 < bytes.length; i += 2) {
      codeUnits.add(
        little
            ? bytes[i] | (bytes[i + 1] << 8)
            : (bytes[i] << 8) | bytes[i + 1],
      );
    }
    return String.fromCharCodes(codeUnits);
  }

  static String? _formatSyltAsLrc(List<_SyltEntry> entries) {
    if (entries.isEmpty) return null;
    entries.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final buffer = StringBuffer();
    for (final entry in entries) {
      final minutes = entry.timestamp ~/ 60000;
      final seconds = (entry.timestamp % 60000) ~/ 1000;
      final milliseconds = entry.timestamp % 1000;
      final text = entry.text.replaceAll(RegExp(r'\r?\n'), ' ').trim();
      if (text.isEmpty) continue;
      buffer
        ..write('[')
        ..write(minutes.toString().padLeft(2, '0'))
        ..write(':')
        ..write(seconds.toString().padLeft(2, '0'))
        ..write('.')
        ..write(milliseconds.toString().padLeft(3, '0'))
        ..write(']')
        ..writeln(text);
    }
    final result = buffer.toString().trimRight();
    return result.isEmpty ? null : result;
  }

  /// 手动解析 FLAC 的 Vorbis comment，读取 LYRICS 标签完整值。
  ///
  /// FLAC metadata block：1 字节头（last 标志 + block type）+ 3 字节大端长度；
  /// block type 4 = VORBIS_COMMENT，内部为小端长度 + UTF-8 字符串的序列。
  static String? _readFlacLyrics(String filePath) {
    RandomAccessFile? rf;
    try {
      final file = File(filePath);
      if (!file.existsSync()) return null;
      // 只读起始 metadata 区域，避免一次性读入整首大文件（FLAC metadata block
      // 总在音频帧之前），播放大体积内嵌歌词歌曲时不会触发 OOM/ANR。
      rf = file.openSync();
      final fileLen = rf.lengthSync();
      final bytes = rf.readSync(
        fileLen > _maxEmbeddedReadBytes ? _maxEmbeddedReadBytes : fileLen,
      );
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
    finally {
      rf?.closeSync();
    }
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

/// compute isolate 的工作函数：在后台 isolate 中同步执行完整歌词加载。
String? _loadForAudioInIsolate(String path) => LocalLyricLoader.loadForAudio(path);

class _SyltEntry {
  final String text;
  final int timestamp;

  const _SyltEntry(this.text, this.timestamp);
}
