import 'dart:typed_data';

import 'package:md3_download_cache/md3_download_cache.dart';

import '../data/models/song.dart';
import '../providers/kugou_provider.dart';
import '../providers/player_provider.dart';
import '../services/kugou_api/kugou_models.dart';
import '../widgets/smart_artwork_image.dart';
import 'private_settings.dart';

/// 私有接线层：把公开基类的「中性扩展点」接到包内下载/缓存引擎上。
///
/// 本文件仅存在于私有构建（导出公开版本时整体排除），
/// 因此这里可以自由 import 包类型与主工程类型（Song / KugouLyric /
/// PrivateSettings），在调用边界做 DTO 适配。

/// 安装全部缓存相关钩子。由 lib/private/main_private.dart 在 runApp 前调用。
void installCacheHooks() {
  // 缓存上限读取：注入私有设置读写器（未注入时包内跳过按上限清理）
  StreamCacheManager.cacheLimitMbProvider = () =>
      PrivateSettings().getStreamCacheLimitMb();

  // 预热缓存索引：供歌单/历史页的同步筛选读取（内存索引，微秒级）
  // ignore: discarded_futures
  StreamCacheManager.instance.ensureInitialized();

  // —— 播放链路 ——
  PlayerProvider.resolveLocalAudioPath = _resolveLocalAudioPath;
  PlayerProvider.resolveLocalArtworkPath = _resolveLocalArtworkPath;
  PlayerProvider.onPlaybackSourceStarted = _onPlaybackSourceStarted;
  PlayerProvider.onPlaybackSourceStopped = (hash) {
    StreamCacheManager.instance.cancelAudioDownload(hash);
  };
  PlayerProvider.extractEmbeddedArtwork = (hash, audioUrl) =>
      StreamCacheManager.instance.cacheEmbeddedArtwork(hash, audioUrl);

  // —— 歌词 ——
  KugouProvider.restoreLyric = _restoreLyric;
  KugouProvider.storeLyric = _storeLyric;

  // —— 封面 ——
  SmartArtworkImage.localArtworkReader = _readLocalArtwork;
}

Future<bool> _streamCacheEnabled() async {
  try {
    return await PrivateSettings().getStreamCacheEnabled();
  } catch (_) {
    return false;
  }
}

Future<String?> _resolveLocalAudioPath(String hash, String quality) async {
  if (!await _streamCacheEnabled()) return null;
  await StreamCacheManager.instance.ensureInitialized();
  return StreamCacheManager.instance.getCachedAudioPath(hash, quality);
}

Future<String?> _resolveLocalArtworkPath(String hash) async {
  if (!await _streamCacheEnabled()) return null;
  await StreamCacheManager.instance.ensureInitialized();
  return StreamCacheManager.instance.getCachedArtworkPath(hash);
}

void _onPlaybackSourceStarted(Song song, String quality, String url) {
  // fire-and-forget，不阻塞播放主流程
  Future<void>.delayed(Duration.zero, () async {
    if (!await _streamCacheEnabled()) return;
    await StreamCacheManager.instance.ensureInitialized();
    await StreamCacheManager.instance.cacheAudio(
      _toSongMetadata(song),
      quality,
      url,
    );
    if (song.artworkUri != null && song.artworkUri!.isNotEmpty) {
      await StreamCacheManager.instance.cacheArtwork(song.id, song.artworkUri!);
    }
    await StreamCacheManager.instance.cacheSongMetadata(_toSongMetadata(song));
  });
}

Future<Uint8List?> _readLocalArtwork(String songId) async {
  await StreamCacheManager.instance.ensureInitialized();
  return StreamCacheManager.instance.getCachedArtwork(songId);
}

Future<KugouLyric?> _restoreLyric(String hash) async {
  if (!await _streamCacheEnabled()) return null;
  await StreamCacheManager.instance.ensureInitialized();
  final data = await StreamCacheManager.instance.getCachedLyric(hash);
  return data == null ? null : _toKugouLyric(data);
}

void _storeLyric(String hash, KugouLyric lyric) {
  // fire-and-forget
  Future<void>.delayed(Duration.zero, () async {
    if (!await _streamCacheEnabled()) return;
    await StreamCacheManager.instance.ensureInitialized();
    await StreamCacheManager.instance.cacheLyric(hash, _toLyricData(lyric));
  });
}

/// Song → SongMetadata（包内最小结构）
SongMetadata _toSongMetadata(Song song) {
  return SongMetadata(
    id: song.id,
    title: song.title,
    artist: song.artist,
    album: song.album,
    durationMs: song.duration.inMilliseconds,
    albumId: song.albumId,
    artistId: song.artistId,
    albumAudioId: song.albumAudioId,
    climaxStart: song.climaxStart,
    climaxEnd: song.climaxEnd,
    artworkUri: song.artworkUri,
  );
}

/// LyricData → KugouLyric
KugouLyric _toKugouLyric(LyricData d) {
  return KugouLyric(
    content: d.content,
    decodedContent: d.decodedContent,
    decodedKrcContent: d.decodedKrcContent,
    translatedContent: d.translatedContent,
    romaContent: d.romaContent,
  );
}

/// KugouLyric → LyricData
LyricData _toLyricData(KugouLyric l) {
  return LyricData(
    content: l.content,
    decodedContent: l.decodedContent,
    decodedKrcContent: l.decodedKrcContent,
    translatedContent: l.translatedContent,
    romaContent: l.romaContent,
  );
}
