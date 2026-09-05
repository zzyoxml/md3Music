import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../data/models/song.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_endpoints.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../player/full_player_route.dart';

// ===================== Rust 本地 PCM 前处理（P0 性能优化） =====================

/// 静音检测阈值（最大振幅低于此值判为静音，跳过识别）。
/// 录音使用 autoGain:false + unprocessed 原始信号源，振幅普遍偏小
/// （正常放歌约 167、静音约 60~90），原阈值 100 偏高会把弱信号误判静音，
/// 导致中间轮次不触发识别，故下调到 30。
const int kSilenceAmplitudeThreshold = 30;

/// Rust 前处理结果：处理后的 PCM 与静音检测用最大振幅。
class PcmProcessResult {
  /// 处理后的 16bit 小端 PCM（8000Hz mono），可直接用于 audioMatch。
  final Uint8List pcm;

  /// 未做增益前的最大振幅（静音检测用，语义与 [computeMaxAmplitude] 一致）。
  final int maxAmplitude;

  const PcmProcessResult({required this.pcm, required this.maxAmplitude});
}

/// 调用本地 Rust 服务器 `/extras/pcm-process` 完成 PCM 前处理：
/// WAV 解析（可选）→ 降采样 → 静音检测 → 增益归一化。
///
/// - [input]：完整 WAV 字节（自动解析采样率）或纯 PCM16 字节（采样率取 [fromHz]）
/// - [fromHz]/[toHz]：源/目标采样率（默认 8000）
///
/// 成功返回 [PcmProcessResult]；服务器不可用/失败返回 null，调用方降级到 Dart 实现。
/// 全程网络 IO + Rust 计算，不占用 UI isolate。
Future<PcmProcessResult?> processPcmWithRust({
  required Uint8List input,
  required int fromHz,
  required int toHz,
}) async {
  if (kIsWeb || input.isEmpty) return null;
  try {
    final url =
        '${KugouEndpoints.baseUrl}${KugouEndpoints.pcmProcess}?fromHz=$fromHz&toHz=$toHz';
    final resp = await http
        .post(
          Uri.parse(url),
          headers: const {
            'Content-Type': 'application/octet-stream',
            // 该端点结果依赖 body（每次不同），必须绕过 apicache 缓存
            'x-apicache-bypass': '1',
          },
          body: input,
        )
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) return null;
    final pcm = resp.bodyBytes;
    if (pcm.isEmpty) return null;
    final maxAmplitude =
        int.tryParse(resp.headers['x-max-amplitude'] ?? '') ?? 0;
    return PcmProcessResult(pcm: pcm, maxAmplitude: maxAmplitude);
  } catch (_) {
    return null;
  }
}

// ===================== PCM 处理（识曲公共链路，Dart 兜底实现） =====================

/// 计算 PCM 最大振幅（16bit 小端采样），用于静音检测。
int computeMaxAmplitude(Uint8List pcm) {
  int maxAmplitude = 0;
  for (int i = 0; i < pcm.length - 1; i += 2) {
    final sample = (pcm[i] | (pcm[i + 1] << 8)).toSigned(16);
    final abs = sample.abs();
    if (abs > maxAmplitude) maxAmplitude = abs;
  }
  return maxAmplitude;
}

/// 将 PCM 数据从 fromHz 降采样到 toHz。
/// 使用均值抗混叠滤波器（anti-aliasing filter），防止高于 toHz/2 的频率混叠。
Uint8List downsamplePcm(Uint8List input, int fromHz, int toHz) {
  if (fromHz == toHz) return input;

  final inputSamples = input.length ~/ 2;
  final ratio = fromHz / toHz;
  final outputSamples = (inputSamples * toHz / fromHz).round();
  final output = Uint8List(outputSamples * 2);

  // 抗混叠窗口大小：取 ratio 的向上取整
  // 对于 44100→8000，ratio≈5.51，窗口=6，半窗=3，每次平均 7 个采样点
  final windowSize = ratio.ceil();
  final halfWindow = windowSize ~/ 2;

  for (int i = 0; i < outputSamples; i++) {
    final centerSrcIdx = (i * ratio).floor();

    // 以 centerSrcIdx 为中心，对窗口内采样点取均值（低通滤波）
    int sum = 0;
    int count = 0;
    for (int j = -halfWindow; j <= halfWindow; j++) {
      final idx = centerSrcIdx + j;
      if (idx >= 0 && idx < inputSamples) {
        final byteIdx = idx * 2;
        final sample = (input[byteIdx] | (input[byteIdx + 1] << 8)).toSigned(16);
        sum += sample;
        count++;
      }
    }

    final avg = count > 0 ? sum ~/ count : 0;
    final clamped = avg.clamp(-32768, 32767);
    output[i * 2] = clamped & 0xFF;
    output[i * 2 + 1] = (clamped >> 8) & 0xFF;
  }

  return output;
}

/// 增益归一化：去除 DC 偏移并放大到目标振幅，提升指纹识别率。
Uint8List normalizeGain(Uint8List input, int currentMaxAmplitude,
    {int targetAmplitude = 25000}) {
  if (input.isEmpty || input.length < 2) return input;

  // 1. 计算 DC 偏移（直流分量）
  int sum = 0;
  int sampleCount = input.length ~/ 2;
  for (int i = 0; i < input.length - 1; i += 2) {
    final sample = (input[i] | (input[i + 1] << 8)).toSigned(16);
    sum += sample;
  }
  final dcOffset = sampleCount > 0 ? (sum / sampleCount).round() : 0;

  // 2. 去除 DC 偏移后重新计算最大振幅
  int adjustedMax = 0;
  for (int i = 0; i < input.length - 1; i += 2) {
    final sample =
        (input[i] | (input[i + 1] << 8)).toSigned(16) - dcOffset;
    final abs = sample.abs();
    if (abs > adjustedMax) adjustedMax = abs;
  }

  if (adjustedMax < 1) return input;

  // 3. 计算增益因子
  final gain = targetAmplitude / adjustedMax;
  if (gain <= 1.0) {
    print('[SongRecognition] gain=$gain (already loud enough, no boost)');
    return input;
  }

  print('[SongRecognition] applying gain=$gain (${adjustedMax} -> $targetAmplitude)');

  // 4. 应用增益
  final output = Uint8List(input.length);
  for (int i = 0; i < input.length - 1; i += 2) {
    final sample =
        (input[i] | (input[i + 1] << 8)).toSigned(16) - dcOffset;
    final amplified = (sample * gain).round().clamp(-32768, 32767);
    output[i] = amplified & 0xFF;
    output[i + 1] = (amplified >> 8) & 0xFF;
  }

  return output;
}

// ===================== 识别结果解析 =====================

/// 从识别响应中判断是否包含有效歌曲数据。
bool hasSongData(Map<String, dynamic> response) {
  final data = response['data'];
  if (data is List && data.isNotEmpty) {
    final first = data.first;
    if (first is Map) {
      final hasName = first.containsKey('songname') ||
          first.containsKey('song_name') ||
          first.containsKey('name') ||
          first.containsKey('SongName');
      final hasHash = first.containsKey('hash') ||
          first.containsKey('FileHash') ||
          first.containsKey('album_audio_id');
      return hasName || hasHash;
    }
  }
  if (data is Map) {
    final hasName = data.containsKey('songname') ||
        data.containsKey('song_name') ||
        data.containsKey('name');
    final hasHash = data.containsKey('hash') ||
        data.containsKey('FileHash') ||
        data.containsKey('album_audio_id');
    return hasName || hasHash;
  }
  return false;
}

/// 按候选 key 顺序提取字段值（取第一个非空值）。
String? extractField(Map<String, dynamic>? map, List<String> keys) {
  if (map == null) return null;
  for (final key in keys) {
    final value = map[key];
    if (value != null && value.toString().isNotEmpty) {
      return value.toString();
    }
  }
  return null;
}

/// 从识别结果中提取歌曲封面 URL（与播放逻辑中的字段顺序一致）。
/// union_cover 可能带 {size} 占位符，统一替换为 480。
String? extractCoverUrl(Map<String, dynamic>? map) {
  if (map == null) return null;
  for (final key in ['imgurl', 'sizable_cover', 'union_cover']) {
    final value = map[key];
    if (value != null && value.toString().isNotEmpty) {
      return value.toString().replaceAll('{size}', '480');
    }
  }
  return null;
}

// ===================== 播放识别结果 =====================

/// 播放识别结果：有 hash 直接播放；否则通过搜索获取 hash 播放。
///
/// - [openFullPlayer]：播放后是否打开全屏播放页（页面场景 true；悬浮窗场景 false）
/// - [onError]：错误回调（页面用它显示错误文案）
Future<void> playRecognizedSong(
  BuildContext context,
  Map<String, dynamic>? audioInfo, {
  bool openFullPlayer = false,
  void Function(String message)? onError,
}) async {
  if (audioInfo == null) return;
  final songName = extractField(audioInfo, ['songname', 'song_name', 'name', 'SongName']) ?? '';
  final singerName = extractField(audioInfo, ['singername', 'singer_name', 'SingerName', 'author_name']) ?? '';
  final albumAudioId = audioInfo['album_audio_id']?.toString() ??
      audioInfo['MixSongID']?.toString() ??
      audioInfo['mixsongid']?.toString();
  final hash = audioInfo['hash']?.toString() ??
      audioInfo['FileHash']?.toString() ??
      audioInfo['file_hash']?.toString();

  if (hash != null && hash.isNotEmpty) {
    // 有 hash，直接播放
    _playWithHash(
      context,
      hash,
      songName,
      singerName,
      albumAudioId,
      audioInfo,
      openFullPlayer: openFullPlayer,
    );
    return;
  }

  // 没有 hash（或只有 album_audio_id），通过歌曲名搜索获取 hash
  if (songName.isEmpty) {
    onError?.call('无法获取播放信息：缺少歌曲名');
    return;
  }
  try {
    final query = singerName.isNotEmpty ? '$singerName $songName' : songName;
    print('[SongRecognition] 搜索歌曲获取 hash: $query');
    final api = KugouApiClient();
    final result = await api.search(query, pagesize: 5);
    if (result == null || result.songs.isEmpty) {
      onError?.call('未找到可播放的歌曲源');
      return;
    }
    // 优先匹配 album_audio_id，否则取第一个结果
    KugouSongDetail? matched;
    if (albumAudioId != null) {
      for (final s in result.songs) {
        if (s.albumAudioId == albumAudioId) {
          matched = s;
          break;
        }
      }
    }
    matched ??= result.songs.first;
    print('[SongRecognition] 搜索到歌曲: ${matched.songName}, hash=${matched.hash}');

    final song = Song(
      id: matched.hash,
      title: songName,
      artist: singerName,
      album: matched.albumName ?? '',
      duration: Duration(milliseconds: matched.duration),
      artworkUri: matched.artworkUri ?? audioInfo['imgurl']?.toString(),
      albumAudioId: matched.albumAudioId ?? albumAudioId,
      albumId: matched.albumId,
      isOnline: true,
    );
    if (!context.mounted) return;
    context.read<PlayerProvider>().playOnlinePlaylist([song], 0);
    if (openFullPlayer) {
      Navigator.of(context).push(fullPlayerRoute(context));
    }
  } catch (e) {
    print('[SongRecognition] 搜索播放失败: $e');
    onError?.call('播放失败: $e');
  }
}

void _playWithHash(
  BuildContext context,
  String hash,
  String songName,
  String singerName,
  String? albumAudioId,
  Map<String, dynamic> audioInfo, {
  bool openFullPlayer = false,
}) {
  final song = Song(
    id: hash,
    title: songName,
    artist: singerName,
    album: '',
    duration: Duration.zero,
    artworkUri: audioInfo['imgurl']?.toString() ??
        audioInfo['sizable_cover']?.toString() ??
        audioInfo['union_cover']?.toString().replaceAll('{size}', '480'),
    albumAudioId: albumAudioId,
    isOnline: true,
  );
  if (!context.mounted) return;
  context.read<PlayerProvider>().playOnlinePlaylist([song], 0);
  if (openFullPlayer) {
    Navigator.of(context).push(fullPlayerRoute(context));
  }
}
