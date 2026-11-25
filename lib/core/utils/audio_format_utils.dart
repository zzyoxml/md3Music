import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// 音频格式展示工具：源文件编码名、文件头位深解析、Media3 编码常量与格式化。
///
/// 供 USB 独占格式链（源文件/播放流/DAC 端点）与歌曲信息页共用，保证两处展示一致。
class AudioFormatUtils {
  AudioFormatUtils._();

  /// Media3 编码常量 → 位深（bit）。
  static int encodingBits(int encoding) {
    switch (encoding) {
      case 4: // C.ENCODING_PCM_FLOAT
        return 32;
      case 2: // C.ENCODING_PCM_16BIT
        return 16;
      case 0x15: // C.ENCODING_PCM_24BIT
        return 24;
      case 0x16: // C.ENCODING_PCM_32BIT
        return 32;
      default:
        return 16;
    }
  }

  /// 采样率格式化：48000 → "48 kHz"，44100 → "44.1 kHz"；<=0 返回 "—"。
  static String formatRate(int rate) {
    if (rate <= 0) return '—';
    if (rate % 1000 == 0) return '${rate ~/ 1000} kHz';
    return '${(rate / 1000).toStringAsFixed(1)} kHz';
  }

  /// 声道数格式化：1 → "1 ch"，2 → "2 ch"，与参考图风格一致；<=0 返回 "—"。
  static String formatCh(int ch) {
    if (ch <= 0) return '—';
    return '$ch ch';
  }

  /// 位深格式化：24 → "24-bit"；<=0 返回 "—"。
  static String formatBits(int bits) {
    if (bits <= 0) return '—';
    return '$bits-bit';
  }

  /// 有损编码集合（此类格式源文件行不展示位深，位深概念仅存在于解码后 PCM）。
  static const Set<String> lossyCodecs = {'MP3', 'AAC', 'OPUS', 'OGG', 'AMR'};

  /// sampleMimeType（Media3）→ 编码短名（FLAC/MP3/AAC/…）。无法识别返回 null。
  /// [codecs] 为 Format.codecs 字符串，用于 OGG 容器内区分 Opus/Vorbis。
  static String? codecLabelFromMime(String? mime, {String? codecs}) {
    if (mime == null || mime.isEmpty) return null;
    final m = mime.toLowerCase();
    final cs = (codecs ?? '').toLowerCase();
    if (m.contains('flac')) return 'FLAC';
    if (m.contains('mpeg') || m.contains('mp3')) return 'MP3';
    if (m.contains('mp4a') || m.contains('aac')) return 'AAC';
    if (m.contains('opus')) return 'OPUS';
    if (m.contains('vorbis') || m == 'audio/ogg' || m.contains('application/ogg')) {
      return cs.contains('opus') ? 'OPUS' : 'OGG';
    }
    if (m.contains('alac')) return 'ALAC';
    if (m.contains('ape') || m.contains('monkey')) return 'APE';
    if (m.contains('wav') || m.contains('wave') || m.contains('pcm')) return 'WAV';
    if (m.contains('ac3') || m.contains('e-ac3') || m.contains('ec3')) return 'AC3';
    if (m.contains('amr')) return 'AMR';
    if (m.contains('dff') || m.contains('dsd') || m.contains('dsf')) return 'DSD';
    if (m.contains('mqa')) return 'MQA';
    return null;
  }

  /// 从文件路径/URL 扩展名推断编码短名（mime 缺失时兜底）。无法识别返回 null。
  static String? codecLabelFromPath(String? url, String? localPath) {
    String? ext;
    for (final p in [localPath, url]) {
      if (p == null || p.isEmpty) continue;
      final q = p.split('?').first;
      final idx = q.lastIndexOf('.');
      if (idx >= 0 && idx < q.length - 1) {
        ext = q.substring(idx + 1).toLowerCase();
        break;
      }
    }
    if (ext == null || ext.isEmpty) return null;
    const map = {
      'flac': 'FLAC',
      'mp3': 'MP3',
      'm4a': 'AAC',
      'aac': 'AAC',
      'opus': 'OPUS',
      'ogg': 'OGG',
      'oga': 'OGG',
      'wav': 'WAV',
      'ape': 'APE',
      'alac': 'ALAC',
      'ac3': 'AC3',
      'amr': 'AMR',
      'dff': 'DSD',
      'dsf': 'DSD',
      'dsd': 'DSD',
    };
    return map[ext] ?? ext.toUpperCase();
  }

  /// 把应用内的路径形态解析为磁盘文件：裸路径 / `file://` / `local://`。
  /// 本地歌曲的 artwork/播放地址常用 `local://<绝对路径>` 形态（缺省盘符斜杠需补全）。
  static Future<File?> _resolveLocalFile(String p) async {
    if (p.isEmpty) return null;
    final direct = File(p);
    if (await direct.exists()) return direct;
    final uri = Uri.tryParse(p);
    if (uri != null && uri.scheme == 'file') {
      final f = File(uri.toFilePath());
      if (await f.exists()) return f;
    }
    if (p.startsWith('local://')) {
      final path = p.substring('local://'.length);
      final f = File(path.startsWith('/') ? path : '/$path');
      if (await f.exists()) return f;
    }
    return null;
  }

  /// 仅供单元测试（test/core/utils/audio_format_utils_test.dart）调用：
  /// WAV 位深解析（RIFF chunk 遍历）。生产路径请走 [parseAudioBitDepth]。
  static int? parseWavBitsForTest(Uint8List head) =>
      _parseWavBitsPerSample(head);

  /// WAV/RF64：沿 RIFF chunk 链定位 "fmt " 并读取 wBitsPerSample。
  /// 兼容 fmt 前有 JUNK/LIST/bext 等非规范 chunk、fmt 18/40 字节
  /// （WAVE_FORMAT_EXTENSIBLE）与 IEEE float（formatTag=3）布局。
  /// [head] 为文件头前若干字节（建议 ≥4KB）。
  static int? _parseWavBitsPerSample(Uint8List head) {
    if (head.length < 12) return null;
    // WAVE / WAVE(=RF64 变体)：offset 8..11 应为 "WAVE"
    if (head[8] != 0x57 || head[9] != 0x41 || head[10] != 0x56 || head[11] != 0x45) {
      return null;
    }
    var pos = 12;
    while (pos + 8 <= head.length) {
      final id = String.fromCharCodes([
        head[pos], head[pos + 1], head[pos + 2], head[pos + 3],
      ]);
      final size = (head[pos + 4] & 0xFF) |
          ((head[pos + 5] & 0xFF) << 8) |
          ((head[pos + 6] & 0xFF) << 16) |
          ((head[pos + 7] & 0xFF) << 24);
      final body = pos + 8;
      if (id == 'fmt ') {
        if (body + 16 > head.length) return null;
        final bits = (head[body + 14] & 0xFF) | ((head[body + 15] & 0xFF) << 8);
        return (bits > 0 && bits <= 32) ? bits : null;
      }
      if (size <= 0) return null; // 非法 chunk，放弃
      // chunk 按 2 字节对齐（奇数长度补 1）
      pos = body + size + (size & 1);
    }
    return null;
  }

  /// 解析音频文件头（FLAC STREAMINFO / WAV fmt chunk）获取原始位深。
  /// 本地文件直接读，网络 URL 用 Range 请求前 4KB。解析失败返回 null。
  static Future<int?> parseAudioBitDepth(String? url, String? localPath) async {
    try {
      Uint8List head;
      // 路径形态兼容：裸路径 / file:// / local://（本地歌曲常用形态，此前不支持导致
      // USB 独占格式链「源文件」行缺位深 —— 歌曲信息页同参数可解析，两处需一致）
      final localFile = await _resolveLocalFile(localPath ?? '') ??
          await _resolveLocalFile(url ?? '');
      if (localFile != null) {
        final raf = await localFile.open();
        head = await raf.read(4096);
        await raf.close();
      } else if (url != null &&
          (url.startsWith('http://') || url.startsWith('https://'))) {
        final resp = await http
            .get(Uri.parse(url), headers: {'Range': 'bytes=0-4095'})
            .timeout(const Duration(seconds: 5));
        if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
        head = resp.bodyBytes;
      } else {
        return null;
      }

      if (head.length < 32) return null;

      // FLAC: "fLaC" + STREAMINFO 块，采样参数在 offset 8+10=18（8 字节）
      if (head[0] == 0x66 && head[1] == 0x4C && head[2] == 0x61 && head[3] == 0x43) {
        const off = 18;
        if (head.length < off + 4) return null;
        final bps = (((head[off + 2] & 0x01) << 4) | ((head[off + 3] >> 4) & 0x0F)) + 1;
        if (bps > 0 && bps <= 32) return bps;
      }

      // WAV/RF64: 走 RIFF chunk 链定位 "fmt "（2026-09-14 修复：旧实现硬编码
      // bitsPerSample@34，仅对「RIFF 后紧跟 16 字节 fmt」的规范布局成立；
      // fmt 前有 JUNK/LIST/bext、fmt 为 18/40 字节（WAVE_FORMAT_EXTENSIBLE）、
      // 或 IEEE float(tag=3) 的实际产物都会解析失败 → 源文件行缺位深）。
      final magic = String.fromCharCodes([head[0], head[1], head[2], head[3]]);
      if (magic == 'RIFF' || magic == 'RF64') {
        return _parseWavBitsPerSample(head);
      }
    } catch (_) {
      // 网络/文件解析失败静默处理
    }
    return null;
  }
}
